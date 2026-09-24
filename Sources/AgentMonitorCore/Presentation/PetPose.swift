import Foundation

/// What the character is doing, as a renderer needs to know it.
///
/// Poses are derived from agent state, never invented alongside it. The pet is a
/// mirror: every pose has to answer "what is actually true right now", which is also
/// what keeps it out of Clippy territory — there is no pose for offering advice.
public enum PetPose: String, Sendable, Equatable, CaseIterable {
    /// No sessions at all. Not "nothing is happening to report" — literally nothing
    /// to mirror, so the pet sleeps. The most common pose during a working day.
    case sleeping
    /// Coming out of `sleeping`. Deliberately its own pose: this is the transition the
    /// user sees most often, and it is where the character earns its keep.
    case waking
    /// An agent is working. Calm, rhythmic — this is the state where nothing is wrong.
    case working
    /// Awake, nothing in flight. An agent exists but is not asking for anything.
    case resting
    /// An agent has been idle long enough to be worth a glance.
    case attentive
    /// An agent is blocked on the human.
    case alert
}

/// Everything the renderer needs for one frame's worth of decisions.
public struct PetPresentation: Sendable, Equatable {
    public let pose: PetPose
    /// Target window alpha. Fading is a `dormant`-only behaviour; see `FadePolicy`.
    public let opacity: Double
    /// Target animation rate. `0` means the display link should be paused outright —
    /// the cheapest state, and deliberately also the most common one.
    public let framesPerSecond: Int

    public init(pose: PetPose, opacity: Double, framesPerSecond: Int) {
        self.pose = pose
        self.opacity = opacity
        self.framesPerSecond = framesPerSecond
    }

    public var isAnimating: Bool { framesPerSecond > 0 }
}

/// When and how far the pet fades while asleep.
///
/// Fading is not hiding. The pet stays exactly where it was, so waking it never means
/// hunting for it again — which is the whole difference between a desk pet and a
/// notification widget. See DESIGN.md §2 B.1.
public struct FadePolicy: Sendable, Equatable {
    public var isEnabled: Bool
    /// How long the pet must be asleep before it starts to fade.
    public var delay: TimeInterval
    /// Where it fades to. Never `0`: invisible is hiding, and hiding gives up the one
    /// advantage the pet form factor has over a bar.
    public var opacity: Double

    public init(isEnabled: Bool = true, delay: TimeInterval = 600, opacity: Double = 0.25) {
        self.isEnabled = isEnabled
        self.delay = delay
        self.opacity = max(0.05, min(1.0, opacity))
    }

    public static let `default` = FadePolicy()
    public static let never = FadePolicy(isEnabled: false)
}
