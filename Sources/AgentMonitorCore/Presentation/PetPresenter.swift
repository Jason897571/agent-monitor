import Foundation

/// Turns agent state into what the character should look like.
///
/// Pure and time-injectable: the pose table, the fade window and the frame-rate budget
/// are the parts that get argued about, so none of them should require a window, a
/// clock or a running agent to test.
public struct PetPresenter: Sendable, Equatable {

    public var fadePolicy: FadePolicy
    /// How long the waking animation plays before settling into the real pose.
    public var wakeDuration: TimeInterval

    private var aggregate: AggregateState
    private var attention: AttentionLevel
    /// When the pet fell asleep, or `nil` if it is awake. Drives the fade clock.
    public private(set) var dormantSince: Date?
    /// When the pet last woke up, or `nil` if it has not woken since it was asleep.
    public private(set) var wokeAt: Date?

    public init(fadePolicy: FadePolicy = .default, wakeDuration: TimeInterval = 1.2) {
        self.fadePolicy = fadePolicy
        self.wakeDuration = wakeDuration
        self.aggregate = .dormant
        self.attention = .ignore
        self.dormantSince = nil
        self.wokeAt = nil
    }

    // MARK: - Input

    public mutating func observe(aggregate: AggregateState, attention: AttentionLevel, now: Date) {
        let wasDormant = self.aggregate.isDormant
        self.aggregate = aggregate
        self.attention = attention

        if aggregate.isDormant {
            if dormantSince == nil { dormantSince = now }
            wokeAt = nil
        } else {
            // Waking is the transition the user sees more than any other — it is what
            // makes the pet feel like it is reacting to them starting work, rather than
            // like a widget that changed colour.
            if wasDormant { wokeAt = now }
            dormantSince = nil
        }
    }

    // MARK: - Output

    public func presentation(now: Date, isHovered: Bool = false) -> PetPresentation {
        let pose = pose(now: now)
        let opacity = opacity(now: now, isHovered: isHovered)
        let faded = opacity < 1.0
        return PetPresentation(
            pose: pose,
            opacity: opacity,
            framesPerSecond: framesPerSecond(for: pose, faded: faded)
        )
    }

    /// When the presentation would change on its own — the fade deadline or the end of
    /// the waking animation. `nil` means nothing is pending and the renderer only needs
    /// to wake on new agent state. Same power lever as `AttentionAssessment.nextChange`.
    public func nextChange(now: Date) -> Date? {
        var candidates: [Date] = []
        if let wokeAt, now < wokeAt.addingTimeInterval(wakeDuration) {
            candidates.append(wokeAt.addingTimeInterval(wakeDuration))
        }
        if fadePolicy.isEnabled, let dormantSince {
            let deadline = dormantSince.addingTimeInterval(fadePolicy.delay)
            if now < deadline { candidates.append(deadline) }
        }
        return candidates.min()
    }

    // MARK: - Private

    private func pose(now: Date) -> PetPose {
        if let wokeAt, now < wokeAt.addingTimeInterval(wakeDuration) { return .waking }

        switch aggregate {
        case .dormant:
            return .sleeping
        case .active(let state):
            switch state {
            case .busy: return .working
            case .shell: return .resting
            case .waiting: return .alert
            case .idle:
                // An idle agent is waiting on you — but only worth looking at once the
                // ladder says so, and it settles back down again after a while.
                return attention >= .makeAware ? .attentive : .resting
            }
        }
    }

    private func opacity(now: Date, isHovered: Bool) -> Double {
        // Reaching for the pet always brings it fully back, immediately.
        if isHovered { return 1.0 }

        // THE RED LINE: only a dormant pet may fade.
        //
        // `idle` means an agent is waiting on *you*. Fading it would hide the one state
        // the user actually needs to see, which is the exact inverse of this product's
        // purpose. Test this on `aggregate`, never on the pose — a future pose that
        // happens to look sleepy must not inherit fading by accident.
        guard aggregate.isDormant, fadePolicy.isEnabled, let dormantSince else { return 1.0 }

        return now.timeIntervalSince(dormantSince) >= fadePolicy.delay ? fadePolicy.opacity : 1.0
    }

    private func framesPerSecond(for pose: PetPose, faded: Bool) -> Int {
        switch pose {
        case .sleeping:
            // Once faded there is nothing worth animating, so stop the display link
            // outright. This is the cheapest state and also the most common one —
            // which is exactly where an always-on utility wins or loses its energy
            // budget. See DESIGN.md §5.
            return faded ? 0 : 2
        case .waking: return 24
        case .working: return 24
        case .resting: return 8
        case .attentive: return 10
        case .alert: return 12
        }
    }
}
