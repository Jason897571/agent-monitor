import Foundation
import Testing

@testable import AgentMonitorCore

private func session(
    _ state: SessionState,
    pid: pid_t = 1,
    stateChangedAt: Date,
    waitingFor: String? = nil
) -> AgentSession {
    AgentSession(
        id: "s\(pid)", agent: .claudeCode, pid: pid, cwd: "/tmp/p\(pid)",
        state: state, waitingFor: waitingFor, startedAt: stateChangedAt,
        stateChangedAt: stateChangedAt, updatedAt: stateChangedAt, name: "session-\(pid)"
    )
}

@Suite("escalation rule")
struct EscalationRuleTests {

    @Test("a rule with no steps never moves")
    func flatRuleNeverMoves() {
        let rule = EscalationRule(initial: .changeBlind)
        #expect(rule.level(afterTimeInState: 0) == .changeBlind)
        #expect(rule.level(afterTimeInState: 86_400) == .changeBlind)
        #expect(rule.timeUntilNextChange(afterTimeInState: 0) == nil)
    }

    @Test("steps apply in order as time passes")
    func stepsApplyInOrder() {
        let rule = EscalationRule(initial: .makeAware, steps: [
            EscalationStep(after: 90, level: .interrupt),
            EscalationStep(after: 300, level: .demandAttention),
        ])
        #expect(rule.level(afterTimeInState: 0) == .makeAware)
        #expect(rule.level(afterTimeInState: 89) == .makeAware)
        #expect(rule.level(afterTimeInState: 90) == .interrupt)
        #expect(rule.level(afterTimeInState: 299) == .interrupt)
        #expect(rule.level(afterTimeInState: 300) == .demandAttention)
    }

    @Test("steps are sorted regardless of the order they were written in")
    func stepsAreSorted() {
        let rule = EscalationRule(initial: .ignore, steps: [
            EscalationStep(after: 300, level: .demandAttention),
            EscalationStep(after: 90, level: .interrupt),
        ])
        #expect(rule.level(afterTimeInState: 100) == .interrupt)
    }

    /// The defect that only showed up against a real machine: a promote-only ladder
    /// leaves every long-lived session pinned at its loudest rung, so the display is
    /// permanently mildly alarmed and therefore says nothing at all.
    @Test("a later step may lower the level")
    func stepsMayDecay() {
        let rule = EscalationRule(initial: .changeBlind, steps: [
            EscalationStep(after: 120, level: .makeAware),
            EscalationStep(after: 1800, level: .changeBlind),
        ])
        #expect(rule.level(afterTimeInState: 60) == .changeBlind)
        #expect(rule.level(afterTimeInState: 200) == .makeAware)
        #expect(rule.level(afterTimeInState: 1799) == .makeAware)
        #expect(rule.level(afterTimeInState: 1801) == .changeBlind)
        #expect(rule.level(afterTimeInState: 13 * 86_400) == .changeBlind)
    }

    @Test("next change is reported for decay as well as escalation")
    func nextChangeCoversBothDirections() {
        let rule = EscalationRule(initial: .changeBlind, steps: [
            EscalationStep(after: 120, level: .makeAware),
            EscalationStep(after: 1800, level: .changeBlind),
        ])
        #expect(rule.timeUntilNextChange(afterTimeInState: 0) == 120)
        #expect(rule.timeUntilNextChange(afterTimeInState: 200) == 1600)
        #expect(rule.timeUntilNextChange(afterTimeInState: 2000) == nil)
    }

    /// A step that does not change the level must not schedule a pointless wake-up.
    @Test("a redundant step does not schedule a wake-up")
    func redundantStepIsNotScheduled() {
        let rule = EscalationRule(initial: .makeAware, steps: [
            EscalationStep(after: 60, level: .makeAware),
        ])
        #expect(rule.timeUntilNextChange(afterTimeInState: 0) == nil)
    }
}

@Suite("default policy")
struct DefaultPolicyTests {

    private let policy = AttentionPolicy.default

    /// Nothing to report, so nothing may be said — and no clock may be started.
    @Test("dormant never says anything")
    func dormantIsSilent() {
        #expect(policy.dormant.level(afterTimeInState: 0) == .ignore)
        #expect(policy.dormant.level(afterTimeInState: 86_400) == .ignore)
        #expect(policy.dormant.timeUntilNextChange(afterTimeInState: 0) == nil)
    }

    /// An agent working normally is not news. If busy escalated, the monitor would be
    /// loudest exactly when everything is fine.
    @Test("busy stays silent forever")
    func busyIsSilent() {
        let rule = policy.rule(for: .busy)
        #expect(rule.level(afterTimeInState: 0) == .ignore)
        #expect(rule.level(afterTimeInState: 6 * 3600) == .ignore)
    }

    @Test("only waiting is ever allowed to interrupt")
    func onlyWaitingInterrupts() {
        for state in SessionState.allCases where state != .waiting {
            let rule = policy.rule(for: state)
            let worst = stride(from: 0.0, through: 14 * 86_400, by: 600)
                .map { rule.level(afterTimeInState: $0) }
                .max() ?? .ignore
            #expect(worst.isIntrusive == false, "\(state) must never become intrusive")
        }
    }

    @Test("waiting climbs to demand-attention, then backs off")
    func waitingClimbsThenBacksOff() {
        let rule = policy.rule(for: .waiting)
        #expect(rule.level(afterTimeInState: 0) == .makeAware)
        #expect(rule.level(afterTimeInState: 120) == .interrupt)
        #expect(rule.level(afterTimeInState: 600) == .demandAttention)
        // Shouting for three days at a session abandoned mid-prompt helps nobody.
        #expect(rule.level(afterTimeInState: 3 * 86_400) == .makeAware)
    }

    /// The real-machine regression: thirteen sessions idle for hours to thirteen days
    /// must leave the display calm.
    @Test("long-idle sessions settle back to change-blind")
    func longIdleSettles() {
        let rule = policy.rule(for: .idle)
        #expect(rule.level(afterTimeInState: 300) == .makeAware)
        for days in [1.0, 3.0, 13.0] {
            #expect(rule.level(afterTimeInState: days * 86_400) == .changeBlind,
                    "a session idle for \(Int(days)) days must not hold the display")
        }
    }

    @Test("an unlisted state defaults to something quiet")
    func unlistedStateIsQuiet() {
        var policy = AttentionPolicy.default
        policy.states.removeValue(forKey: .waiting)
        #expect(policy.rule(for: .waiting).level(afterTimeInState: 0).isIntrusive == false)
    }
}

@Suite("escalator")
struct AttentionEscalatorTests {

    private let escalator = AttentionEscalator()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("no sessions is dormant, with no clock running")
    func noSessionsIsDormant() {
        let assessment = escalator.assess(sessions: [], now: now)
        #expect(assessment == .dormant)
        #expect(assessment.level == .ignore)
        #expect(assessment.session == nil)
        #expect(assessment.nextChange == nil)
    }

    @Test("the loudest session wins")
    func loudestWins() {
        let sessions = [
            session(.busy, pid: 1, stateChangedAt: now.addingTimeInterval(-10)),
            session(.waiting, pid: 2, stateChangedAt: now.addingTimeInterval(-120)),
            session(.idle, pid: 3, stateChangedAt: now.addingTimeInterval(-300)),
        ]
        let assessment = escalator.assess(sessions: sessions, now: now)
        #expect(assessment.level == .interrupt)
        #expect(assessment.session?.pid == 2)
    }

    /// Without a total order the pet would flap between equally-ranked sessions on
    /// every scan.
    @Test("ties break on state urgency, then on how long it has been stuck")
    func tiesBreakDeterministically() {
        let sessions = [
            session(.idle, pid: 1, stateChangedAt: now.addingTimeInterval(-200)),
            session(.idle, pid: 2, stateChangedAt: now.addingTimeInterval(-900)),
        ]
        let first = escalator.assess(sessions: sessions, now: now)
        let reversed = escalator.assess(sessions: sessions.reversed(), now: now)
        #expect(first.session?.pid == 2)
        #expect(first.session?.pid == reversed.session?.pid)
    }

    @Test("next change is the soonest across all sessions")
    func nextChangeIsSoonest() {
        let sessions = [
            // idle → make-aware at 120s, so 100s away
            session(.idle, pid: 1, stateChangedAt: now.addingTimeInterval(-20)),
            // waiting → interrupt at 90s, so 80s away
            session(.waiting, pid: 2, stateChangedAt: now.addingTimeInterval(-10)),
        ]
        let assessment = escalator.assess(sessions: sessions, now: now)
        let delay = assessment.nextChange?.timeIntervalSince(now)
        #expect(delay != nil)
        #expect(abs((delay ?? 0) - 80) < 0.001)
    }

    /// The power lever: when every session has settled, there is nothing to wake up
    /// for and the registry can sleep on the file watcher alone.
    @Test("settled sessions schedule nothing")
    func settledSessionsScheduleNothing() {
        let sessions = [
            session(.busy, pid: 1, stateChangedAt: now.addingTimeInterval(-3600)),
            session(.idle, pid: 2, stateChangedAt: now.addingTimeInterval(-13 * 86_400)),
        ]
        #expect(escalator.assess(sessions: sessions, now: now).nextChange == nil)
    }
}
