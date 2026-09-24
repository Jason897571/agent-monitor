import Foundation

/// Counts of sessions by state — what the docked bar renders.
///
/// The docked form factor is one-dimensional and degrades past about four items, so it
/// shows aggregate counts rather than a row per session. That is the honest trade: the
/// pet uses two dimensions of screen space and can hold a session each, the bar cannot,
/// and pretending otherwise is how a bar ends up unreadable at six agents.
public struct SessionSummary: Sendable, Equatable {

    public let counts: [SessionState: Int]
    public let total: Int

    public init(sessions: [AgentSession]) {
        var counts: [SessionState: Int] = [:]
        for session in sessions { counts[session.state, default: 0] += 1 }
        self.counts = counts
        self.total = sessions.count
    }

    public func count(_ state: SessionState) -> Int { counts[state] ?? 0 }

    public var isEmpty: Bool { total == 0 }

    /// What the bar badges, most urgent first: at most three families — blocked on
    /// you, in trouble, working — each labelled with its most urgent member state and
    /// counting the whole family.
    ///
    /// `shell`, `idle` and a quietly finished turn are deliberately excluded — a bar that
    /// always shows a number is a bar nobody reads. They appear only as part of the
    /// total. And thirteen states cannot each get a badge on a one-dimensional strip; the
    /// card is one hover away for the detail.
    public var badges: [(state: SessionState, count: Int)] {
        let families: [(SessionState) -> Bool] = [\.isBlockedOnUser, \.isTrouble, \.isWorking]
        return families.compactMap { belongs in
            let members = counts.filter { belongs($0.key) && $0.value > 0 }
            guard let top = members.keys.max(by: { $0.urgency < $1.urgency }) else { return nil }
            return (top, members.values.reduce(0, +))
        }
    }
}

extension Array where Element == AgentSession {

    /// The order a session list should be read in: whatever needs the user first.
    ///
    /// Most urgent state first, then within a state the most recently changed — a session
    /// that went idle a minute ago is more likely to be the one you are thinking about
    /// than one that has been idle for a week.
    public func orderedForDisplay() -> [AgentSession] {
        sorted { lhs, rhs in
            if lhs.state.urgency != rhs.state.urgency { return lhs.state.urgency > rhs.state.urgency }
            if lhs.stateChangedAt != rhs.stateChangedAt { return lhs.stateChangedAt > rhs.stateChangedAt }
            return lhs.id < rhs.id
        }
    }
}
