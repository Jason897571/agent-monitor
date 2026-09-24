import Foundation

/// Which CLI a session belongs to. Codex and friends land in P1.
public enum AgentKind: String, Sendable, Equatable {
    case claudeCode
}

/// A single live agent session, normalised across agents.
///
/// This is the core's public currency: adapters produce these, renderers consume them,
/// and nothing downstream needs to know which agent's on-disk dialect produced it.
public struct AgentSession: Sendable, Equatable, Identifiable {
    /// The agent's own session UUID.
    public let id: String
    public let agent: AgentKind
    public let pid: pid_t
    public let cwd: String
    public let state: SessionState
    /// Free-text detail on *what* the agent is waiting for, when `state == .waiting`.
    /// Claude Code writes e.g. `"input needed"`. Nobody else surfaces this.
    public let waitingFor: String?
    public let startedAt: Date
    /// When `state` last actually changed.
    ///
    /// Claude Code only advances this on a real transition
    /// (`...e.status !== void 0 && { statusUpdatedAt: t }`), which makes it the correct
    /// clock for attention escalation — "waiting for 20 minutes" is measured from here,
    /// not from `updatedAt`.
    public let stateChangedAt: Date
    /// Last write of any kind. Note there is **no heartbeat**: an actively working
    /// session can leave this frozen for tens of minutes, so staleness carries no
    /// information about liveness. See DESIGN.md §7.1 trap #4.
    public let updatedAt: Date
    /// Session name derived by the agent, e.g. `agent-monitor-e8`.
    public let name: String?
    public let version: String?
    /// `cli` for interactive sessions, `sdk-cli` for headless/SDK ones.
    public let entrypoint: String?
    /// True when a Remote Control / claude.ai bridge is attached.
    public let isBridged: Bool
    /// The model-generated description of what this session is about, if one has been
    /// written yet. Best-effort and often absent early in a session — a label, never a
    /// dependency. `displayName` is the one that always works.
    public let title: String?

    public init(
        id: String,
        agent: AgentKind,
        pid: pid_t,
        cwd: String,
        state: SessionState,
        waitingFor: String? = nil,
        startedAt: Date,
        stateChangedAt: Date,
        updatedAt: Date,
        name: String? = nil,
        version: String? = nil,
        entrypoint: String? = nil,
        isBridged: Bool = false,
        title: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.state = state
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.stateChangedAt = stateChangedAt
        self.updatedAt = updatedAt
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.isBridged = isBridged
        self.title = title
    }

    /// Returns a copy carrying `title`. Used by the registry, which discovers titles
    /// separately from and more slowly than session state.
    public func withTitle(_ title: String?) -> AgentSession {
        AgentSession(
            id: id, agent: agent, pid: pid, cwd: cwd, state: state, waitingFor: waitingFor,
            startedAt: startedAt, stateChangedAt: stateChangedAt, updatedAt: updatedAt,
            name: name, version: version, entrypoint: entrypoint, isBridged: isBridged,
            title: title
        )
    }

    /// Label for a session card. Never derived from the project directory slug —
    /// that transform is lossy and irreversible. See DESIGN.md §7.1 trap #2.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? id.prefix(8).description : base
    }

    /// How long the session has been sitting in its current state.
    public func timeInState(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(stateChangedAt)
    }
}
