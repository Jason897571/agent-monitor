import Foundation

/// The state of a single agent session.
///
/// The first four cases are Claude Code's own canonical enum, lifted verbatim from the
/// binary (`["busy","shell","idle","waiting"]`). We deliberately keep `shell` distinct
/// rather than folding it into `idle` — every competing monitor collapses the two, and
/// they mean different things.
///
/// The rest are *refinements*: each one is a more specific reading of one of those four,
/// recovered from a second signal — the `waitingFor` text, the transcript tail, the
/// optional hook channel, the statusline feed. A refinement may sharpen what the session
/// file says; it may never contradict it. See `SessionRefiner` and DESIGN.md §2 支点 B.
public enum SessionState: String, Sendable, Equatable, CaseIterable {
    /// The agent is working: thinking or running a tool.
    case busy
    /// The user has shelled out of the session.
    case shell
    /// The session is alive but the agent has nothing to do.
    case idle
    /// The agent is blocked on the human, for a reason none of the sharper cases below
    /// covers (a dialog, a goal proposal…). `AgentSession.waitingFor` carries the detail.
    case waiting

    /// Blocked on a permission prompt — allow or deny a tool, or a sandbox exception.
    case awaitingPermission
    /// Blocked on a question: `AskUserQuestion`, an MCP elicitation.
    case awaitingAnswer
    /// Summarising its own context. Busy, but not making progress on your task.
    case compacting
    /// Busy, with two or more subagents fanned out underneath it.
    case subagentSwarm
    /// Busy or idle with under 10% of the context window left.
    case contextCritical
    /// The last turn finished normally. A fresh `idle`.
    case doneSuccess
    /// The last turn ended on an API error.
    case doneError
    /// The last turn was refused for quota.
    case rateLimited
    /// The process died without cleaning up after itself — a crash, a `kill -9`, a
    /// closed terminal. Shown for a while, then dropped.
    case disconnected

    /// Parsed from the `status` field of a session file. Only Claude Code's own four
    /// values are accepted: unknown values map to `nil` rather than a default, so a
    /// future release that adds a state shows up as "unknown" instead of being silently
    /// mislabelled as idle — and a refinement name that happens to appear in the file is
    /// not mistaken for one we derived ourselves.
    public init?(rawStatus: String?) {
        switch rawStatus {
        case "busy": self = .busy
        case "shell": self = .shell
        case "idle": self = .idle
        case "waiting": self = .waiting
        default: return nil
        }
    }

    /// How much this state deserves the user's attention, ascending.
    /// Used to pick which session the pet mirrors when several are live.
    ///
    /// Blocked-on-you states sit on top; then states that went wrong and need you to
    /// decide what next; then work in flight; then rest.
    public var urgency: Int {
        switch self {
        case .shell: return 0
        case .idle: return 1
        case .disconnected: return 2
        case .doneSuccess: return 3
        case .busy: return 4
        case .compacting: return 5
        case .subagentSwarm: return 6
        case .contextCritical: return 7
        case .doneError: return 8
        case .rateLimited: return 9
        case .waiting: return 10
        case .awaitingAnswer: return 11
        case .awaitingPermission: return 12
        }
    }

    /// Whether this state is a legitimate sharper reading of a session file that says
    /// `raw`. Refinements may never contradict the file — that is the invariant that
    /// keeps a stale secondary signal (a hook event the app missed the end of, a
    /// statusline sample from an hour ago) from overriding what Claude Code wrote.
    public func refines(_ raw: SessionState) -> Bool {
        switch self {
        case .busy, .shell, .idle, .waiting: return self == raw
        case .compacting, .subagentSwarm: return raw == .busy
        case .contextCritical: return raw == .busy || raw == .idle
        case .doneSuccess, .doneError, .rateLimited: return raw == .idle
        case .awaitingPermission, .awaitingAnswer: return raw == .waiting
        // Not a reading of a live file at all: the process is gone.
        case .disconnected: return false
        }
    }

    /// The agent cannot go on until the human does something.
    public var isBlockedOnUser: Bool {
        switch self {
        case .waiting, .awaitingPermission, .awaitingAnswer: return true
        default: return false
        }
    }

    /// The agent is doing work right now.
    public var isWorking: Bool {
        switch self {
        case .busy, .compacting, .subagentSwarm: return true
        default: return false
        }
    }

    /// Something went wrong and the next move is the user's.
    public var isTrouble: Bool {
        switch self {
        case .doneError, .rateLimited, .disconnected, .contextCritical: return true
        default: return false
        }
    }
}

/// What the pet renders — derived from *all* live sessions, not from any one of them.
///
/// `dormant` and `.active(.idle)` are frequently conflated and mean opposite things:
/// `dormant` is "you are not using agents right now", `.active(.idle)` is "an agent is
/// waiting on you". Painting the second as the first inverts the information.
/// See DESIGN.md §2 B.1.
public enum AggregateState: Sendable, Equatable {
    /// No live sessions at all. The pet sleeps. Never escalates.
    case dormant
    /// At least one live session; the value is the most urgent one's state.
    case active(SessionState)

    public init(sessions: [AgentSession]) {
        // A `disconnected` session counts. It is only kept for a few minutes after the
        // crash, and a pet that slept straight through an agent dying mid-task would
        // make the crash silent — the one thing a monitor must not do.
        guard let most = sessions.max(by: { $0.state.urgency < $1.state.urgency }) else {
            self = .dormant
            return
        }
        self = .active(most.state)
    }

    public var isDormant: Bool { self == .dormant }
}
