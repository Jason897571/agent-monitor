import Foundation

/// How much of a plan's rate limit an agent has used, as the agent itself reported it.
///
/// Never fetched: no Keychain, no OAuth token, no call to anyone's API. Claude Code hands
/// these numbers to its statusline command and Codex writes them into its own rollout —
/// we only read what is already on disk. See the constraint in DESIGN.md §6 P1.
public struct QuotaSnapshot: Sendable, Equatable {
    public let agent: AgentKind
    public let windows: [QuotaWindow]
    /// When the agent reported it.
    public let sampledAt: Date

    public init(agent: AgentKind, windows: [QuotaWindow], sampledAt: Date) {
        self.agent = agent
        self.windows = windows
        self.sampledAt = sampledAt
    }

    /// Windows still describing the present: one whose reset time has passed says
    /// nothing about now.
    public func current(now: Date = Date()) -> [QuotaWindow] {
        windows.filter { window in
            guard let resetsAt = window.resetsAt else { return true }
            return resetsAt > now
        }
    }
}

public struct QuotaWindow: Sendable, Equatable {
    /// Short label: `5h`, `7d`, `30d`.
    public let label: String
    /// 0–100.
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// DESIGN.md §2 支点 C: above 90% the user hears about it, once.
    public var isNearLimit: Bool { usedPercent >= 90 }

    /// Identity for "already told you about this one": a window is the same window until
    /// it resets.
    public var noticeKey: String {
        "\(label)@\(Int(resetsAt?.timeIntervalSince1970 ?? 0))"
    }

    /// Label for a window length in minutes, the way Codex reports it.
    static func label(forMinutes minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

/// Decides when a quota deserves a one-time heads-up.
///
/// The rule from the escalation table: make-aware **once** per window, with the reset
/// countdown, and never again until the window resets. A quota at 93% that nags every
/// time it is looked at is noise; one that says nothing lets the user walk into the wall.
public struct QuotaNotifier: Sendable {
    private var notified: Set<String> = []

    public init() {}

    /// Windows that crossed the line and have not been announced yet. Calling this marks
    /// them announced.
    public mutating func newlyNearLimit(in snapshots: [QuotaSnapshot], now: Date = Date()) -> [(AgentKind, QuotaWindow)] {
        var fresh: [(AgentKind, QuotaWindow)] = []
        for snapshot in snapshots {
            for window in snapshot.current(now: now) where window.isNearLimit {
                let key = "\(snapshot.agent.rawValue)/\(window.noticeKey)"
                guard !notified.contains(key) else { continue }
                notified.insert(key)
                fresh.append((snapshot.agent, window))
            }
        }
        return fresh
    }
}
