import Foundation

/// One rung of a time-driven promotion: "after this long in the state, rise to this level".
public struct EscalationStep: Sendable, Equatable {
    public let after: TimeInterval
    public let level: AttentionLevel

    public init(after: TimeInterval, level: AttentionLevel) {
        self.after = after
        self.level = level
    }
}

/// What a single state is allowed to do to the user, and how that changes over time.
///
/// Steps may move the level **down** as well as up, and that is the important part.
/// A ladder that only climbs pins the display at its loudest rung forever: on the
/// machine this was built against, thirteen sessions had been idle for hours to
/// thirteen days, and a promote-only rule left every one of them — and therefore the
/// pet — permanently at `makeAware`. A signal that is always on is not a signal, and
/// interruptive systems that cry wolf get overridden 49–96% of the time.
///
/// So the shape to think in is a *window*: a state becomes glance-worthy shortly after
/// it is entered, and settles back down once it is clear you have seen it and chosen
/// not to act.
public struct EscalationRule: Sendable, Equatable {
    public let initial: AttentionLevel
    /// Transitions, kept sorted ascending by `after`. The last one whose deadline has
    /// passed wins, so later steps may lower the level. An empty list means the state
    /// never changes — a deliberate, load-bearing choice for several states.
    public let steps: [EscalationStep]

    public init(initial: AttentionLevel, steps: [EscalationStep] = []) {
        self.initial = initial
        self.steps = steps.sorted { $0.after < $1.after }
    }

    public func level(afterTimeInState elapsed: TimeInterval) -> AttentionLevel {
        var current = initial
        for step in steps where elapsed >= step.after {
            current = step.level
        }
        return current
    }

    /// How long until this rule would change the level again, in either direction,
    /// or `nil` if it never will.
    ///
    /// This is what lets the monitor sleep precisely until the next thing happens
    /// instead of polling — the difference between a timer that fires twice an hour
    /// and one that fires every second. See `SessionRegistry`.
    public func timeUntilNextChange(afterTimeInState elapsed: TimeInterval) -> TimeInterval? {
        let currentLevel = level(afterTimeInState: elapsed)
        for step in steps where step.after > elapsed && step.level != currentLevel {
            return step.after - elapsed
        }
        return nil
    }
}

/// The full escalation table: one rule per state, user-editable in principle.
///
/// Shipping this as data rather than as branching code is the point — DESIGN.md §2
/// 支点 C sells it as "the only agent monitor with a documented attention budget",
/// which is only true if the budget is inspectable and adjustable.
public struct AttentionPolicy: Sendable, Equatable {
    public var dormant: EscalationRule
    public var states: [SessionState: EscalationRule]

    public init(dormant: EscalationRule, states: [SessionState: EscalationRule]) {
        self.dormant = dormant
        self.states = states
    }

    public func rule(for state: SessionState) -> EscalationRule {
        // An unlisted state must not default to something loud.
        states[state] ?? EscalationRule(initial: .changeBlind)
    }

    /// The defaults from DESIGN.md §2 支点 C.
    ///
    /// Three of these are constraints rather than preferences:
    ///
    /// `dormant` never changes. There is nothing to report, and a pet that finds a
    /// reason to speak up when you are not using agents is the Clippy failure mode.
    ///
    /// `busy` sits at `ignore`. An agent working normally is not news; promoting it
    /// would mean the monitor is loudest exactly when everything is fine.
    ///
    /// Everything that rises also comes back down. The decay rungs are not politeness —
    /// without them a forgotten terminal tab holds the whole display hostage, which is
    /// the failure mode this policy exists to prevent.
    public static let `default` = AttentionPolicy(
        dormant: EscalationRule(initial: .ignore),
        states: [
            .busy: EscalationRule(initial: .ignore),
            .shell: EscalationRule(initial: .changeBlind),
            // An idle session is an agent waiting on *you*. It earns a glance once it
            // has settled, then stops asking: after half an hour you have either seen
            // it or decided it can wait, and either way repeating yourself is noise.
            .idle: EscalationRule(initial: .changeBlind, steps: [
                EscalationStep(after: 120, level: .makeAware),
                EscalationStep(after: 1800, level: .changeBlind),
            ]),
            // Blocked and user-resolvable — the one shape that earns an interrupt.
            // It still decays, an hour out: if shouting has not worked by then it is
            // not going to, and a session abandoned mid-prompt must not leave the pet
            // screaming for days. It stays visible, just no longer intrusive.
            .waiting: EscalationRule(initial: .makeAware, steps: [
                EscalationStep(after: 90, level: .interrupt),
                EscalationStep(after: 300, level: .demandAttention),
                EscalationStep(after: 3600, level: .makeAware),
            ]),
        ]
    )
}
