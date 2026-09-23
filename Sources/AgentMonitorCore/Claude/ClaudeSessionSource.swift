import Foundation

/// Turns `sessions/*.json` into live `AgentSession` values.
///
/// This is the whole P0 read path: one directory, no hooks installed, no TCC prompt,
/// no binary in the agent's tool-call hot path. See DESIGN.md §2 支点 A.
///
/// The hard part is liveness. There are routinely far more files than processes — they
/// are not swept — and a file's age tells you nothing: on this machine a 13-day-old
/// file belonged to a perfectly healthy idle session while the directory as a whole
/// held 15 files. So we verify three things, and a session must pass all three.
public struct ClaudeSessionSource: Sendable {

    /// Why a session file did not become a live session. Surfaced for diagnostics —
    /// silent drops make this layer impossible to debug against real machines.
    public enum Rejection: Sendable, Equatable {
        case unreadable(String)
        /// No process holds this pid.
        case processGone
        /// A process holds the pid but it is not `claude` — the pid was recycled.
        case commandMismatch(String)
        /// The pid is held by a `claude` that started at a different time — recycled
        /// into another session.
        case startTimeMismatch
        /// `status` was missing or is a value this build does not know.
        case unknownStatus(String?)
    }

    public struct Rejected: Sendable, Equatable {
        public let file: String
        public let reason: Rejection
    }

    public struct ScanResult: Sendable, Equatable {
        public let sessions: [AgentSession]
        public let rejected: [Rejected]

        public var aggregate: AggregateState { AggregateState(sessions: sessions) }
    }

    public let locator: ClaudeConfigLocator
    /// How liveness is checked. Injectable so the scan path can be exercised against
    /// synthetic session files without needing real processes to exist.
    let inspector: @Sendable (pid_t) -> ProcessInspector.Info?

    public init(locator: ClaudeConfigLocator = .resolve()) {
        self.init(locator: locator, inspector: { ProcessInspector.info(of: $0) })
    }

    init(locator: ClaudeConfigLocator, inspector: @escaping @Sendable (pid_t) -> ProcessInspector.Info?) {
        self.locator = locator
        self.inspector = inspector
    }

    public func scan(now: Date = Date()) -> ScanResult {
        let directory = locator.sessionsDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var sessions: [AgentSession] = []
        var rejected: [Rejected] = []

        for url in contents where url.pathExtension == "json" {
            let filename = url.lastPathComponent
            do {
                let file = try ClaudeSessionFile.decode(contentsOf: url)
                switch Self.makeSession(from: file, inspector: inspector) {
                case .success(let session):
                    sessions.append(session)
                case .failure(let reason):
                    rejected.append(Rejected(file: filename, reason: reason))
                }
            } catch {
                rejected.append(Rejected(file: filename, reason: .unreadable(error.localizedDescription)))
            }
        }

        // Most recently active first — a stable order the UI can rely on.
        sessions.sort { $0.stateChangedAt > $1.stateChangedAt }
        rejected.sort { $0.file < $1.file }
        return ScanResult(sessions: sessions, rejected: rejected)
    }

    // MARK: - Liveness

    enum SessionOutcome {
        case success(AgentSession)
        case failure(Rejection)
    }

    static func makeSession(
        from file: ClaudeSessionFile,
        inspector: (pid_t) -> ProcessInspector.Info? = { ProcessInspector.info(of: $0) }
    ) -> SessionOutcome {
        // 1. Does anything hold this pid?
        guard let process = inspector(file.pid) else {
            return .failure(.processGone)
        }

        // 2. Is it the *same* process that wrote this file?
        //
        //    Start time is the conclusive test: a recycled pid belongs to a process
        //    that started later, and `procStart` has one-second resolution. We compare
        //    against the kernel's own start time, parsing the recorded string as UTC —
        //    comparing the raw strings is the timezone bug in ProcStartParser.
        //
        //    The process *name* is only a fallback for files with no `procStart`,
        //    never a gate of its own: the executable is `claude.exe` on npm/Homebrew
        //    installs but `claude` on the native installer, and rejecting an install
        //    variant we have not enumerated would show an empty dashboard to a user
        //    with work in flight — the exact failure this layer exists to prevent.
        if let procStart = file.procStart {
            guard ProcStartParser.matches(procStart, actualStart: process.startTime) else {
                return .failure(.startTimeMismatch)
            }
        } else {
            guard ClaudeProcess.commandNames.contains(process.command) else {
                return .failure(.commandMismatch(process.command))
            }
        }

        guard let state = SessionState(rawStatus: file.status) else {
            return .failure(.unknownStatus(file.status))
        }

        return .success(AgentSession(
            id: file.sessionId,
            agent: .claudeCode,
            pid: file.pid,
            cwd: file.cwd,
            state: state,
            waitingFor: file.waitingFor,
            startedAt: file.startedAtDate,
            stateChangedAt: file.stateChangedAtDate,
            updatedAt: file.updatedAtDate,
            name: file.name,
            version: file.version,
            entrypoint: file.entrypoint,
            isBridged: file.bridgeSessionId != nil
        ))
    }
}
