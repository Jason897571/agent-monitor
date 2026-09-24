import Foundation

/// Runs an `AgentManifest`: finds the agent's sessions, decides which are alive, and
/// turns each into an `AgentSession`.
public final class ManifestProvider: SessionProvider, @unchecked Sendable {

    public let manifest: AgentManifest
    public let home: URL
    public var agent: AgentKind { manifest.kind }
    /// Context use at which a session counts as critical.
    public var contextCriticalPercent: Double = 90

    /// How processes are found. Injectable so the matching can be tested without real
    /// agents running.
    struct ProcessView: Sendable {
        var list: @Sendable (Set<String>) -> [ProcessInspector.Info]
        var cwd: @Sendable (pid_t) -> String?
        var arguments: @Sendable (pid_t) -> [String]
        var exists: @Sendable (pid_t) -> Bool

        static let live = ProcessView(
            list: { ProcessInspector.processes(matching: $0) },
            cwd: { ProcessInspector.workingDirectory(of: $0) },
            arguments: { ProcessInspector.arguments(of: $0) },
            exists: { ProcessInspector.exists(pid: $0) }
        )
    }

    let processes: ProcessView

    public convenience init(manifest: AgentManifest, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(manifest: manifest, home: Self.resolveHome(manifest.home, environment: environment), processes: .live)
    }

    init(manifest: AgentManifest, home: URL, processes: ProcessView) {
        self.manifest = manifest
        self.home = home
        self.processes = processes
    }

    static func resolveHome(_ home: AgentManifest.Home, environment: [String: String]) -> URL {
        let raw = home.env.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? home.default
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var watchedDirectories: [URL] {
        var directories: [URL] = []
        if let log = manifest.eventLog { directories.append(home.appendingPathComponent(log.watch, isDirectory: true)) }
        if let files = manifest.sessionFiles { directories.append(home.appendingPathComponent(files.directory, isDirectory: true)) }
        return directories
    }

    public func scan(now: Date) -> ProviderScan {
        if let log = manifest.eventLog { return scanEventLogs(log, now: now) }
        if let files = manifest.sessionFiles { return scanSessionFiles(files, now: now) }
        return ProviderScan()
    }

    // MARK: - Event logs

    /// What has been learned from one log so far. Logs are append-only, so after the
    /// first read only new bytes are ever parsed — an agent streaming a turn appends many
    /// times a second, and re-reading a quarter megabyte on each would be the most
    /// expensive thing this app did.
    struct LogState {
        var offset: UInt64 = 0
        var modified: Date = .distantPast
        var id: String?
        var cwd: String?
        var startedAt: Date?
        var origin: String?
        var state: SessionState?
        var stateAt: Date?
        var problem: String?
        var contextUsed: Double?
        var contextWindow: Double?
        var quota: [QuotaWindow] = []
        var quotaAt: Date?
    }

    private var logs: [String: LogState] = [:]
    private var titles: (modified: Date, values: [String: String]) = (.distantPast, [:])

    func scanEventLogs(_ log: AgentManifest.EventLog, now: Date) -> ProviderScan {
        let cutoff = now.addingTimeInterval(-log.maxAgeHours * 3600)
        let files = Self.glob(log.files, under: home).compactMap { url -> (URL, Date, UInt64)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified >= cutoff else { return nil }
            return (url, modified, UInt64(values.fileSize ?? 0))
        }

        var states: [(URL, LogState)] = []
        for (url, modified, size) in files {
            var state = logs[url.path] ?? LogState()
            if size < state.offset { state = LogState() }  // truncated or replaced
            if size > state.offset { read(url, log: log, into: &state, size: size) }
            state.modified = modified
            logs[url.path] = state
            states.append((url, state))
        }
        let present = Set(files.map(\.0.path))
        logs = logs.filter { present.contains($0.key) }

        let owners = assignOwners(states.map(\.1), now: now)
        let titles = loadTitles(log.title)

        var sessions: [AgentSession] = []
        for (index, (_, state)) in states.enumerated() {
            guard let pid = owners[index], let id = state.id else { continue }
            sessions.append(makeSession(id: id, pid: pid, state: state, title: titles[id], now: now))
        }

        let quota = states.map(\.1)
            .filter { !$0.quota.isEmpty }
            .max { ($0.quotaAt ?? .distantPast) < ($1.quotaAt ?? .distantPast) }
            .map { QuotaSnapshot(agent: agent, windows: $0.quota, sampledAt: $0.quotaAt ?? now) }

        return ProviderScan(sessions: sessions, quota: quota)
    }

    private func read(_ url: URL, log: AgentManifest.EventLog, into state: inout LogState, size: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        // The header is the first line. Read it on its own the first time, because the
        // tail window below usually starts long after it.
        if state.id == nil, state.offset == 0 {
            try? handle.seek(toOffset: 0)
            if let head = try? handle.read(upToCount: 64 * 1024),
               let first = head.split(separator: UInt8(ascii: "\n")).first,
               let object = try? JSONSerialization.jsonObject(with: Data(first)),
               JSONPath.matches(log.header.match, object) {
                state.id = JSONPath.string(log.header.id, in: object)
                state.cwd = JSONPath.string(log.header.cwd, in: object)
                state.startedAt = log.header.startedAt.flatMap { JSONPath.date($0, in: object) }
                state.origin = log.header.origin.flatMap { JSONPath.string($0, in: object) }
            }
        }

        let tailBytes = UInt64(log.tailBytes ?? 256 * 1024)
        var start = state.offset
        var skipFirstLine = false
        if state.offset == 0, size > tailBytes {
            start = size - tailBytes
            skipFirstLine = true
        }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty else { return }

        // Only consume complete lines; a line still being written is picked up next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        state.offset = start + UInt64(complete.count)

        var lines = [UInt8](complete).split(separator: UInt8(ascii: "\n"))
        if skipFirstLine, !lines.isEmpty { lines.removeFirst() }

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) else { continue }
            let at = JSONPath.date(log.timestamp, in: object)

            if let rule = log.states.first(where: { JSONPath.matches($0.match, object) }) {
                var raw = rule.state
                if let path = rule.ifPresent, JSONPath.value(path, in: object) != nil, let then = rule.then {
                    raw = then
                }
                if let parsed = SessionState(rawValue: raw) {
                    state.state = parsed
                    state.stateAt = at
                    state.problem = rule.problem.flatMap { JSONPath.string($0, in: object) }.map(Self.firstLine)
                }
            }
            if let rule = log.context, JSONPath.matches(rule.match, object),
               let used = JSONPath.double(rule.used, in: object),
               let window = JSONPath.double(rule.window, in: object), window > 0 {
                state.contextUsed = used
                state.contextWindow = window
            }
            if let rule = log.quota, JSONPath.matches(rule.match, object) {
                let windows = rule.windows.compactMap { window -> QuotaWindow? in
                    guard let used = JSONPath.double(window.usedPercent, in: object) else { return nil }
                    let label = window.label
                        ?? window.minutes.flatMap { JSONPath.double($0, in: object) }.map { QuotaWindow.label(forMinutes: Int($0)) }
                        ?? "quota"
                    return QuotaWindow(label: label, usedPercent: used,
                                       resetsAt: window.resetsAt.flatMap { JSONPath.date($0, in: object) })
                }
                if !windows.isEmpty {
                    state.quota = windows
                    state.quotaAt = at
                }
            }
        }
    }

    /// Error payloads can be whole HTML pages. A caption is one line.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// Which live process, if any, each log belongs to.
    ///
    /// A log alone cannot say whether its session is alive: the agent does not hold it
    /// open between writes, and a finished session looks exactly like an idle one. So
    /// liveness comes from processes, two ways:
    ///
    /// - A CLI process owns the most recently written log for its working directory.
    /// - A host process (an app server behind a desktop app) keeps every session it
    ///   touched recently alive — it cannot be tied to one log, so recency stands in.
    func assignOwners(_ states: [LogState], now: Date) -> [Int: pid_t] {
        guard let liveness = manifest.liveness else { return [:] }
        let running = processes.list(Set(manifest.processNames))
        var owners: [Int: pid_t] = [:]

        var hosts: [ProcessInspector.Info] = []
        var clients: [ProcessInspector.Info] = []
        for process in running {
            let arguments = processes.arguments(process.pid).joined(separator: " ")
            if let host = liveness.hostProcess, arguments.contains(host.argsContain) {
                hosts.append(process)
            } else {
                clients.append(process)
            }
        }

        if liveness.processCwd == true {
            for process in clients {
                guard let cwd = processes.cwd(process.pid).map(Self.canonical) else { continue }
                // Written since the process started: a log from an earlier run in the same
                // directory is history, not this process's session.
                let candidates = states.indices.filter { index in
                    owners[index] == nil
                        && states[index].cwd.map(Self.canonical) == cwd
                        && states[index].modified >= process.startTime.addingTimeInterval(-5)
                }
                if let newest = candidates.max(by: { states[$0].modified < states[$1].modified }) {
                    owners[newest] = process.pid
                }
            }
        }

        if let host = liveness.hostProcess, let process = hosts.max(by: { $0.startTime < $1.startTime }) {
            let since = max(process.startTime, now.addingTimeInterval(-host.activeWithinMinutes * 60))
            for index in states.indices where owners[index] == nil && states[index].modified >= since {
                if let origins = host.origins, !origins.contains(states[index].origin ?? "") { continue }
                owners[index] = process.pid
            }
        }
        return owners
    }

    /// `/tmp` and `/private/tmp` are the same place; a process reports one, a log the other.
    static func canonical(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasSuffix("/") && resolved.count > 1 ? String(resolved.dropLast()) : resolved
    }

    private func makeSession(id: String, pid: pid_t, state: LogState, title: String?, now: Date) -> AgentSession {
        let parsed = state.state ?? .idle
        var session = AgentSession(
            id: id,
            agent: agent,
            pid: pid,
            cwd: state.cwd ?? "",
            state: Self.rawState(for: parsed),
            startedAt: state.startedAt ?? state.modified,
            stateChangedAt: state.stateAt ?? state.startedAt ?? state.modified,
            updatedAt: state.modified,
            title: title
        )
        session.refine(to: parsed)
        if session.state == .doneError || session.state == .rateLimited { session.problem = state.problem }
        if let used = state.contextUsed, let window = state.contextWindow {
            session.contextUsedPercent = min(100, used / window * 100)
            if used / window * 100 >= contextCriticalPercent { session.refine(to: .contextCritical) }
        }
        return session
    }

    /// The plain state a manifest-declared state refines, so refinement rules hold for
    /// manifest agents exactly as they do for Claude Code.
    static func rawState(for state: SessionState) -> SessionState {
        switch state {
        case .busy, .compacting, .subagentSwarm, .contextCritical: return .busy
        case .shell: return .shell
        case .idle, .doneSuccess, .doneError, .rateLimited, .disconnected: return .idle
        case .waiting, .awaitingPermission, .awaitingAnswer: return .waiting
        }
    }

    private func loadTitles(_ rule: AgentManifest.TitleRule?) -> [String: String] {
        guard let rule else { return [:] }
        let url = home.appendingPathComponent(rule.index)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return [:] }
        if modified == titles.modified { return titles.values }

        var values: [String: String] = [:]
        if let data = try? Data(contentsOf: url) {
            for line in [UInt8](data).split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let id = JSONPath.string(rule.id, in: object),
                      let value = JSONPath.string(rule.value, in: object)?.trimmedNonEmpty else { continue }
                values[id] = value
            }
        }
        titles = (modified, values)
        return values
    }

    // MARK: - Session files

    func scanSessionFiles(_ spec: AgentManifest.SessionFiles, now: Date) -> ProviderScan {
        let directory = home.appendingPathComponent(spec.directory, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        var sessions: [AgentSession] = []
        var rejected: [RejectedSession] = []
        for url in files where url.pathExtension == "json" {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pidValue = JSONPath.double(spec.pid, in: object),
                  let id = JSONPath.string(spec.id, in: object) else {
                rejected.append(RejectedSession(agent: agent, file: name, reason: "unreadable"))
                continue
            }
            let pid = pid_t(pidValue)
            guard processes.exists(pid) else {
                rejected.append(RejectedSession(agent: agent, file: name, reason: "process gone"))
                continue
            }
            let status = JSONPath.string(spec.status, in: object)
            guard let mapped = status.flatMap({ spec.statusMap[$0] }).flatMap(SessionState.init(rawValue:)) else {
                rejected.append(RejectedSession(agent: agent, file: name, reason: "unknown status '\(status ?? "nil")'"))
                continue
            }
            let updated = spec.updatedAt.flatMap { JSONPath.date($0, in: object) } ?? now
            var session = AgentSession(
                id: id, agent: agent, pid: pid,
                cwd: JSONPath.string(spec.cwd, in: object) ?? "",
                state: Self.rawState(for: mapped),
                waitingFor: spec.waitingFor.flatMap { JSONPath.string($0, in: object) },
                startedAt: spec.startedAt.flatMap { JSONPath.date($0, in: object) } ?? updated,
                stateChangedAt: updated,
                updatedAt: updated,
                name: spec.name.flatMap { JSONPath.string($0, in: object) }
            )
            session.refine(to: mapped)
            sessions.append(session)
        }
        return ProviderScan(sessions: sessions, rejected: rejected)
    }

    // MARK: - Glob

    /// Expands `sessions/*/*/*/rollout-*.jsonl`. `*` matches within one component; there
    /// is no `**` on purpose — an unbounded recursive walk of an agent's home is exactly
    /// the cost this monitor exists to avoid.
    static func glob(_ pattern: String, under root: URL) -> [URL] {
        var frontier = [root]
        let components = pattern.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            var next: [URL] = []
            for directory in frontier {
                if !component.contains("*") {
                    let candidate = directory.appendingPathComponent(component, isDirectory: !isLast)
                    if FileManager.default.fileExists(atPath: candidate.path) { next.append(candidate) }
                    continue
                }
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                next += entries.filter { fnmatch(component, $0.lastPathComponent, 0) == 0 }
            }
            frontier = next
        }
        return frontier
    }
}
