import Foundation

/// How loudly a state is allowed to ask for the user's attention.
///
/// These are Matthews & Mankoff's five notification levels from the Peripheral Display
/// Toolkit, kept verbatim rather than invented, because the middle rung is the one
/// products habitually skip: `changeBlind` means the display genuinely changes but is
/// designed *not* to be noticed until you look at it. Without it you only have "silent"
/// and "shouting", which is how every competing monitor ends up firing the same alert
/// for "finished" and "needs you".
///
/// See DESIGN.md §2 支点 C.
public enum AttentionLevel: Int, Sendable, Equatable, Comparable, CaseIterable {
    /// Render nothing that could draw the eye.
    case ignore = 0
    /// Change the display, but below the threshold of peripheral detection.
    case changeBlind = 1
    /// Make it noticeable to a glance. Still silent.
    case makeAware = 2
    /// Actively break the user out of what they are doing.
    case interrupt = 3
    /// Escalate past interruption — the user has ignored it for a long time.
    case demandAttention = 4

    public static func < (lhs: AttentionLevel, rhs: AttentionLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Levels at or above this one are allowed to make noise or steal focus.
    /// Everything below must remain purely visual.
    public var isIntrusive: Bool { self >= .interrupt }
}
