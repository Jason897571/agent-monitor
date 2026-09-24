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

    /// States worth a badge, most urgent first.
    ///
    /// `shell` and `idle` are deliberately excluded when nothing else is happening —
    /// a bar that always shows a number is a bar nobody reads. They appear only as part
    /// of the total when something else is already drawing the eye.
    public var badges: [(state: SessionState, count: Int)] {
        SessionState.allCases
            .sorted { $0.urgency > $1.urgency }
            .compactMap { state in
                let count = self.count(state)
                guard count > 0 else { return nil }
                guard state == .waiting || state == .busy else { return nil }
                return (state, count)
            }
    }
}
