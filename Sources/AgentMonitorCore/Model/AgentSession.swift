import Foundation

/// Which agent a session belongs to.
///
/// A string-backed struct rather than an enum because adapters are data: an agent
/// described by a manifest (see `AgentManifest`) brings its own id, and the core must
/// not need a code change to carry it.
public struct AgentKind: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    /// Human-facing name, e.g. "Claude Code".
    public let displayName: String

    public init(rawValue: String) {
        self.rawValue = rawValue
        self.displayName = rawValue
    }

    public init(_ rawValue: String, displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
    }

    public static let claudeCode = AgentKind("claude-code", displayName: "Claude Code")
    public static let codex = AgentKind("codex", displayName: "Codex")

    public var description: String { rawValue }

    public static func == (lhs: AgentKind, rhs: AgentKind) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

/// A single live agent session, normalised across agents.
///
/// This is the core's public currency: adapters produce these, renderers consume them,
/// and nothing downstream needs to know which agent's on-disk dialect produced it.
public struct AgentSession: Sendable, Equatable, Identifiable {
    /// The agent's own session UUID.
    public var id: String
    public var agent: AgentKind
    public var pid: pid_t
    public var cwd: String
    public var state: SessionState
    /// What the agent's own status record said, before any refinement. `state` may only
    /// ever be a sharper reading of this — see `SessionState.refines(_:)`.
    public var rawState: SessionState
    /// Free-text detail on *what* the agent is waiting for, when `state == .waiting`.
    /// Claude Code writes e.g. `"input needed"`. Nobody else surfaces this.
    public var waitingFor: String?
    public var startedAt: Date
    /// When `state` last actually changed.
    ///
    /// Claude Code only advances this on a real transition
    /// (`...e.status !== void 0 && { statusUpdatedAt: t }`), which makes it the correct
    /// clock for attention escalation — "waiting for 20 minutes" is measured from here,
    /// not from `updatedAt`.
    public var stateChangedAt: Date
    /// Last write of any kind. Note there is **no heartbeat**: an actively working
    /// session can leave this frozen for tens of minutes, so staleness carries no
    /// information about liveness. See DESIGN.md §7.1 trap #4.
    public var updatedAt: Date
    /// Session name derived by the agent, e.g. `agent-monitor-e8`.
    public var name: String?
    public var version: String?
    /// `cli` for interactive sessions, `sdk-cli` for headless/SDK ones.
    public var entrypoint: String?
    /// True when a Remote Control / claude.ai bridge is attached.
    public var isBridged: Bool
    /// The model-generated description of what this session is about, if one has been
    /// written yet. Best-effort and often absent early in a session — a label, never a
    /// dependency. `displayName` is the one that always works.
    public var title: String?

    // MARK: Detail — every field below is best-effort, and absent means "unknown".

    /// What the agent says it is doing, in its own words: the `activeForm` of its
    /// in-progress task (「对比方案」), or the tool it is running. Present tense.
    public var activity: String?
    /// The agent's own recap of the session, written for someone coming back to it
    /// (Claude Code's `away_summary`). Past tense; the useful line when it is idle.
    public var recap: String?
    /// Why the last turn failed, as the agent put it — "You've hit your session limit ·
    /// resets 6:10am". Only set in `doneError` / `rateLimited`.
    public var problem: String?
    /// Subagents currently running under this session.
    public var subagents: Int
    /// Share of the context window in use, 0–100, when something reported it.
    public var contextUsedPercent: Double?
    /// Name of the agent team this session leads, if it leads one.
    public var team: String?

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
        title: String? = nil,
        activity: String? = nil,
        recap: String? = nil,
        problem: String? = nil,
        subagents: Int = 0,
        contextUsedPercent: Double? = nil,
        team: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.state = state
        self.rawState = state
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.stateChangedAt = stateChangedAt
        self.updatedAt = updatedAt
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.isBridged = isBridged
        self.title = title
        self.activity = activity
        self.recap = recap
        self.problem = problem
        self.subagents = subagents
        self.contextUsedPercent = contextUsedPercent
        self.team = team
    }

    /// Returns a copy carrying `title`. Used by the registry, which discovers titles
    /// separately from and more slowly than session state.
    public func withTitle(_ title: String?) -> AgentSession {
        var copy = self
        copy.title = title
        return copy
    }

    /// Moves the session into a sharper state, if that is a legitimate reading of what
    /// the agent itself reported and more urgent than any refinement already applied.
    /// Several signals can each propose one — an error in the transcript, low context
    /// from the statusline — and the most urgent valid one wins regardless of the order
    /// they are applied in.
    ///
    /// `since` moves the escalation clock when the refinement began later than the file's
    /// own transition: a session that has been idle for an hour but errored a minute ago
    /// has been in `doneError` for a minute.
    public mutating func refine(to refined: SessionState, since: Date? = nil) {
        guard refined.refines(rawState) else { return }
        guard state == rawState || refined.urgency > state.urgency else { return }
        state = refined
        if let since, since > stateChangedAt { stateChangedAt = since }
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
