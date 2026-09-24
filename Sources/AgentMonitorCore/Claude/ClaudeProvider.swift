import Foundation

/// The Claude Code adapter: the session files, plus everything that sharpens them.
///
/// `ClaudeSessionSource` answers "which sessions are alive, and busy/idle/waiting?" from
/// one directory. This layers the secondary signals on top, each optional and each only
/// ever allowed to *refine* that answer (see `SessionState.refines`):
///
/// | signal                       | gives                                            | needs      |
/// |------------------------------|--------------------------------------------------|------------|
/// | `waitingFor` text            | awaitingPermission / awaitingAnswer              | nothing    |
/// | transcript tail              | title, recap, doneSuccess / doneError / rateLimited | nothing |
/// | `tasks/<list>/*.json`        | what it is doing (`activeForm`), teams           | nothing    |
/// | session file left behind     | disconnected                                     | nothing    |
/// | hook channel                 | compacting, subagentSwarm, current tool          | opt-in     |
/// | statusline feed              | context use → contextCritical, plan quota        | opt-in     |
public final class ClaudeProvider: SessionProvider, @unchecked Sendable {

    public let agent = AgentKind.claudeCode
    public let source: ClaudeSessionSource
    public let hooks: HookEventStore
    public let statusline: StatuslineFeed?

    /// How long a crashed session stays on show before it is dropped.
    public var disconnectedGrace: TimeInterval = 600
    /// Context use at which a session counts as critical. DESIGN.md: under 10% left.
    public var contextCriticalPercent: Double = 90

    public var locator: ClaudeConfigLocator { source.locator }

    public init(source: ClaudeSessionSource = ClaudeSessionSource(),
                hooks: HookEventStore = HookEventStore(),
                statusline: StatuslineFeed? = StatuslineFeed()) {
        self.source = source
        self.hooks = hooks
        self.statusline = statusline
    }

    public var watchedDirectories: [URL] {
        var directories = [
            locator.sessionsDirectory,
            locator.directory.appendingPathComponent("tasks", isDirectory: true),
            locator.directory.appendingPathComponent("teams", isDirectory: true),
        ]
        if let statusline { directories.append(statusline.directory) }
        return directories
    }

    // MARK: - Scan

    public func scan(now: Date) -> ProviderScan {
        let result = source.scan(now: now)
        let teams = ClaudeTeams.teams(in: locator)
        let teamsByLead = Dictionary(
            teams.compactMap { team in team.leadSessionId.map { ($0, team) } },
            uniquingKeysWith: { first, _ in first }
        )

        var sessions = result.sessions.map { session -> AgentSession in
            var session = session
            enrichFromTranscript(&session, now: now)
            enrichFromTasks(&session, team: teamsByLead[session.id])
            hooks.refine(&session, now: now)
            enrichFromStatusline(&session)
            // Last resort for "what is it doing": what it was asked to do. After the
            // agent's own task caption and the tool it is running, in that order — and
            // quoted, because these are the user's words, not a description of work.
            if session.rawState == .busy, session.activity == nil,
               let prompt = transcripts[session.id]?.tail.lastPrompt {
                session.activity = "「\(Self.shorten(prompt))」"
            }
            return session
        }
        sessions.append(contentsOf: trackDisconnects(live: result.sessions, rejected: result.rejected, now: now))

        return ProviderScan(
            sessions: sessions,
            rejected: result.rejected.map { RejectedSession(agent: agent, file: $0.file, reason: $0.reason.description) },
            quota: statusline?.latestQuota(),
            teams: teams.filter { team in team.leadSessionId.map { id in sessions.contains { $0.id == id } } ?? false }
        )
    }

    // MARK: - Transcript

    /// Titles, recaps and turn endings live in transcripts, which are large, slugged
    /// under an irreversible directory name, and constantly appended to while a session
    /// works. So: find each one once, and re-read its tail only when it has grown — and
    /// even then not more than every few seconds, unless the session changed state.
    private struct TranscriptCache {
        var url: URL?
        var searchedAt: Date
        var size: UInt64 = 0
        var readAt: Date = .distantPast
        var readInState: SessionState?
        var tail = ClaudeTranscript.Tail()
        /// Kept across reads: the title can scroll out of the tail window.
        var title: String?
    }

    private var transcripts: [String: TranscriptCache] = [:]
    private let transcriptSearchInterval: TimeInterval = 120
    private let transcriptReadInterval: TimeInterval = 5

    private func enrichFromTranscript(_ session: inout AgentSession, now: Date) {
        var cache = transcripts[session.id] ?? TranscriptCache(searchedAt: .distantPast)

        if cache.url == nil, now.timeIntervalSince(cache.searchedAt) >= transcriptSearchInterval {
            cache.url = ClaudeTranscript.url(forSessionID: session.id, in: locator)
            cache.searchedAt = now
        }

        if let url = cache.url {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            let grew = size != cache.size
            let stateMoved = cache.readInState != session.rawState
            if (grew && now.timeIntervalSince(cache.readAt) >= transcriptReadInterval) || (grew && stateMoved)
                || cache.readInState == nil {
                if let tail = ClaudeTranscript.tail(of: url) {
                    cache.tail = tail
                    cache.title = tail.title ?? cache.title
                }
                cache.size = size
                cache.readAt = now
                cache.readInState = session.rawState
            }
        }
        transcripts[session.id] = cache
        if transcripts.count > 512 { transcripts = transcripts.filter { now.timeIntervalSince($0.value.readAt) < 86_400 } }

        session.title = cache.title
        if session.rawState == .idle { session.recap = cache.tail.recap }

        guard session.rawState == .idle, let ending = cache.tail.ending else { return }
        switch ending {
        case .completed:
            // The file's own idle transition is the right clock; the transcript line is
            // written a moment earlier and would only make the state look older.
            session.refine(to: .doneSuccess)
        case .apiError(let kind, let message, let at):
            session.refine(to: kind == "rate_limit" ? .rateLimited : .doneError, since: at)
            session.problem = message
        }
    }

    /// A prompt is a paragraph; a caption is a line.
    static func shorten(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    // MARK: - Tasks and teams

    private func enrichFromTasks(_ session: inout AgentSession, team: AgentTeam?) {
        session.team = team?.name
        guard session.rawState == .busy || session.rawState == .waiting else { return }
        let tasks = team?.tasks ?? ClaudeTeams.tasks(list: session.id, in: locator)
        // The agent's own words for what it is doing beat anything we could infer.
        if let caption = ClaudeTeams.activity(in: tasks) { session.activity = caption }
    }

    // MARK: - Status line

    private func enrichFromStatusline(_ session: inout AgentSession) {
        guard let sample = statusline?.sample(for: session.id), sample.sampledAt >= session.startedAt,
              let used = sample.contextUsedPercent else { return }
        session.contextUsedPercent = used
        if used >= contextCriticalPercent { session.refine(to: .contextCritical) }
    }

    // MARK: - Crashes

    private var lastLive: [pid_t: AgentSession] = [:]
    private var disconnected: [String: AgentSession] = [:]

    /// A clean exit removes the session file. A crash leaves it behind with a dead pid —
    /// which, for a session we saw alive a moment ago, is the only trace a crash leaves.
    /// Sessions that were already dead when the monitor started are not reported: there
    /// is no telling whether that happened a minute or a month ago.
    private func trackDisconnects(live: [AgentSession], rejected: [ClaudeSessionSource.Rejected],
                                  now: Date) -> [AgentSession] {
        let liveIDs = Set(live.map(\.id))
        let orphaned = Set(rejected.compactMap { entry -> pid_t? in
            guard entry.reason == .processGone else { return nil }
            return ClaudeSessionSource.pid(fromFileName: entry.file)
        })

        for (pid, session) in lastLive where !liveIDs.contains(session.id) && orphaned.contains(pid) {
            var dead = session
            dead.state = .disconnected
            dead.rawState = .disconnected
            dead.stateChangedAt = now
            dead.activity = nil
            dead.subagents = 0
            disconnected[session.id] = dead
        }
        disconnected = disconnected.filter { id, session in
            !liveIDs.contains(id)
                && orphaned.contains(session.pid)
                && now.timeIntervalSince(session.stateChangedAt) < disconnectedGrace
        }
        lastLive = Dictionary(live.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        return Array(disconnected.values)
    }
}
