import Foundation

/// The state of a single agent session.
///
/// The four cases below are Claude Code's own canonical enum, lifted verbatim from
/// the 2.1.220 binary (`IO_ = ["busy","shell","idle","waiting"]`). We deliberately
/// keep `shell` distinct rather than folding it into `idle` — every competing monitor
/// collapses the two, and they mean different things.
///
/// Richer states (awaitingPermission, compacting, doneError, rateLimited, ...) arrive
/// in P1 once the optional hook channel exists. See DESIGN.md §2 支点 B.
public enum SessionState: String, Sendable, Equatable, CaseIterable {
    /// The agent is working: thinking or running a tool.
    case busy
    /// The user has shelled out of the session.
    case shell
    /// The session is alive but the agent has nothing to do.
    case idle
    /// The agent is blocked on the human. `AgentSession.waitingFor` carries the detail.
    case waiting

    /// Parsed from the `status` field of a session file. Unknown values map to `nil`
    /// rather than a default, so a future Claude Code release that adds a state shows
    /// up as "unknown" instead of being silently mislabelled as idle.
    public init?(rawStatus: String?) {
        guard let rawStatus, let parsed = SessionState(rawValue: rawStatus) else { return nil }
        self = parsed
    }

    /// How much this state deserves the user's attention, ascending.
    /// Used to pick which session the pet mirrors when several are live.
    public var urgency: Int {
        switch self {
        case .shell: return 0
        case .idle: return 1
        case .busy: return 2
        case .waiting: return 3
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
        guard let most = sessions.max(by: { $0.state.urgency < $1.state.urgency }) else {
            self = .dormant
            return
        }
        self = .active(most.state)
    }

    public var isDormant: Bool { self == .dormant }
}
