import Foundation

/// What the whole fleet of sessions currently deserves, and when that could change.
public struct AttentionAssessment: Sendable, Equatable {
    public let level: AttentionLevel
    /// The session that earned the level, or `nil` when dormant.
    public let session: AgentSession?
    /// The instant at which some session's level would rise on its own. `nil` when
    /// nothing is on a timer — the monitor can then sleep until a file event wakes it.
    public let nextChange: Date?

    public init(level: AttentionLevel, session: AgentSession?, nextChange: Date?) {
        self.level = level
        self.session = session
        self.nextChange = nextChange
    }

    public static let dormant = AttentionAssessment(level: .ignore, session: nil, nextChange: nil)
}

/// Applies an `AttentionPolicy` to a set of live sessions.
///
/// Pure and synchronous on purpose: the escalation table is the part of this product
/// that has to be argued about and tuned, so it must be testable without a clock, a
/// filesystem, or a window.
public struct AttentionEscalator: Sendable {
    public let policy: AttentionPolicy

    public init(policy: AttentionPolicy = .default) {
        self.policy = policy
    }

    public func assess(sessions: [AgentSession], now: Date = Date()) -> AttentionAssessment {
        guard !sessions.isEmpty else {
            // Dormant. The pet sleeps, and nothing is scheduled — there is no clock
            // running because there is nothing that could become urgent on its own.
            return .dormant
        }

        var winner: (session: AgentSession, level: AttentionLevel)?
        var soonestChange: Date?

        for session in sessions {
            let elapsed = session.timeInState(now: now)
            let rule = policy.rule(for: session.state)
            let level = rule.level(afterTimeInState: elapsed)

            if let remaining = rule.timeUntilNextChange(afterTimeInState: elapsed) {
                let at = now.addingTimeInterval(remaining)
                soonestChange = soonestChange.map { Swift.min($0, at) } ?? at
            }

            if let current = winner {
                if level > current.level || (level == current.level && outranks(session, current.session, now: now)) {
                    winner = (session, level)
                }
            } else {
                winner = (session, level)
            }
        }

        guard let winner else { return .dormant }
        return AttentionAssessment(level: winner.level, session: winner.session, nextChange: soonestChange)
    }

    /// Tie-break when two sessions sit at the same level: prefer the more urgent state,
    /// then the one that has been stuck longest. Without a total order here the pet
    /// would flap between equally-ranked sessions on every scan.
    private func outranks(_ lhs: AgentSession, _ rhs: AgentSession, now: Date) -> Bool {
        if lhs.state.urgency != rhs.state.urgency {
            return lhs.state.urgency > rhs.state.urgency
        }
        if lhs.timeInState(now: now) != rhs.timeInState(now: now) {
            return lhs.timeInState(now: now) > rhs.timeInState(now: now)
        }
        // Last resort, so the result never depends on directory enumeration order.
        return lhs.id > rhs.id
    }
}
