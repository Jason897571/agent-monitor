import Foundation
import Testing

@testable import AgentMonitorCore

private func session(_ state: SessionState, id: String = "s", changed: Date = Date(timeIntervalSince1970: 1000)) -> AgentSession {
    AgentSession(id: id, agent: .claudeCode, pid: 1, cwd: "/tmp", state: state,
                 startedAt: .distantPast, stateChangedAt: changed, updatedAt: changed)
}

@Suite("state refinement")
struct RefinementTests {

    /// The invariant the whole 13-state model rests on: a secondary signal may sharpen
    /// the session file, never contradict it. A stale hook event must not turn a busy
    /// session into "done".
    @Test("a refinement never contradicts the session file")
    func neverContradicts() {
        for raw in [SessionState.busy, .shell, .idle, .waiting] {
            for refined in SessionState.allCases {
                var s = session(raw)
                s.refine(to: refined)
                #expect(s.state == raw || refined.refines(raw), "\(raw) must not become \(refined)")
                #expect(s.rawState == raw)
            }
        }
    }

    @Test("the most urgent valid refinement wins, whatever order they arrive in")
    func mostUrgentWins() {
        var a = session(.idle)
        a.refine(to: .doneSuccess)
        a.refine(to: .contextCritical)
        var b = session(.idle)
        b.refine(to: .contextCritical)
        b.refine(to: .doneSuccess)
        #expect(a.state == .contextCritical)
        #expect(b.state == .contextCritical)
    }

    @Test("a later refinement moves the escalation clock forward, never back")
    func refinementClock() {
        var s = session(.idle, changed: Date(timeIntervalSince1970: 1000))
        s.refine(to: .doneError, since: Date(timeIntervalSince1970: 5000))
        #expect(s.stateChangedAt == Date(timeIntervalSince1970: 5000))
        var t = session(.idle, changed: Date(timeIntervalSince1970: 1000))
        t.refine(to: .doneError, since: Date(timeIntervalSince1970: 10))
        #expect(t.stateChangedAt == Date(timeIntervalSince1970: 1000))
    }

    /// Claude Code fills `waitingFor` from a fixed table; the fallback for any permission
    /// dialog is "permission prompt". Distinguishing the two main waits needs no hook.
    @Test("waitingFor tells a permission prompt from a question")
    func waitingForRefinement() {
        #expect(ClaudeSessionSource.refinement(forWaitingFor: "permission prompt") == .awaitingPermission)
        #expect(ClaudeSessionSource.refinement(forWaitingFor: "sandbox request") == .awaitingPermission)
        #expect(ClaudeSessionSource.refinement(forWaitingFor: "input needed") == .awaitingAnswer)
        #expect(ClaudeSessionSource.refinement(forWaitingFor: "dialog open") == nil)
        #expect(ClaudeSessionSource.refinement(forWaitingFor: "something new") == nil)
        #expect(ClaudeSessionSource.refinement(forWaitingFor: nil) == nil)
    }

    @Test("blocked states outrank trouble, trouble outranks work, work outranks rest")
    func urgencyFamilies() {
        let blocked = SessionState.allCases.filter(\.isBlockedOnUser).map(\.urgency)
        let trouble: [SessionState] = [.doneError, .rateLimited, .contextCritical]
        let working = SessionState.allCases.filter(\.isWorking).map(\.urgency)
        #expect(blocked.min()! > trouble.map(\.urgency).max()!)
        #expect(trouble.map(\.urgency).min()! > working.max()!)
        #expect(working.min()! > SessionState.idle.urgency)
        #expect(working.min()! > SessionState.doneSuccess.urgency)
    }

    @Test("every state has an escalation rule of its own")
    func everyStateHasARule() {
        for state in SessionState.allCases {
            #expect(AttentionPolicy.default.states[state] != nil, "\(state) falls back to the default rule")
        }
    }

    /// DESIGN.md: done-success is make-aware and **never** interrupts.
    @Test("a finished turn is noticed but never interrupts")
    func doneNeverInterrupts() {
        let rule = AttentionPolicy.default.rule(for: .doneSuccess)
        #expect(rule.level(afterTimeInState: 0) == .makeAware)
        for t in stride(from: 0.0, through: 86_400, by: 60) {
            #expect(rule.level(afterTimeInState: t) < .interrupt)
        }
    }

    @Test("a permission prompt interrupts fastest")
    func permissionInterruptsFast() {
        let permission = AttentionPolicy.default.rule(for: .awaitingPermission)
        let waiting = AttentionPolicy.default.rule(for: .waiting)
        #expect(permission.level(afterTimeInState: 21) == .interrupt)
        #expect(waiting.level(afterTimeInState: 21) == .makeAware)
    }

    @Test("the docked bar badges families, not thirteen states")
    func badgesGroupFamilies() {
        let summary = SessionSummary(sessions: [
            session(.waiting, id: "a"), session(.idle, id: "b"),
            { var s = session(.waiting, id: "c"); s.refine(to: .awaitingPermission); return s }(),
            { var s = session(.busy, id: "d"); s.refine(to: .compacting); return s }(),
            session(.busy, id: "e"),
            { var s = session(.idle, id: "f"); s.refine(to: .doneError); return s }(),
        ])
        let badges = summary.badges
        #expect(badges.count == 3)
        #expect(badges[0].state == .awaitingPermission && badges[0].count == 2)
        #expect(badges[1].state == .doneError && badges[1].count == 1)
        #expect(badges[2].state == .compacting && badges[2].count == 2)
    }
}

@Suite("pet poses for the richer states")
struct RicherPoseTests {

    private func pose(_ state: SessionState, attention: AttentionLevel = .makeAware) -> PetPose {
        var presenter = PetPresenter(fadePolicy: .never, wakeDuration: 0)
        let now = Date()
        presenter.observe(aggregate: .active(state), attention: attention, now: now.addingTimeInterval(-10))
        return presenter.presentation(now: now).pose
    }

    @Test("each state family has its own pose")
    func poses() {
        #expect(pose(.compacting) == .digesting)
        #expect(pose(.subagentSwarm) == .swarming)
        #expect(pose(.awaitingPermission) == .alert)
        #expect(pose(.awaitingAnswer) == .alert)
        #expect(pose(.doneSuccess) == .done)
        #expect(pose(.doneSuccess, attention: .changeBlind) == .resting)
        #expect(pose(.doneError) == .troubled)
        #expect(pose(.rateLimited) == .troubled)
        #expect(pose(.disconnected, attention: .changeBlind) == .resting)
    }

    /// The fade red line, extended: every state that is not dormant stays fully visible.
    @Test("no awake state ever fades")
    func noAwakeStateFades() {
        for state in SessionState.allCases {
            var presenter = PetPresenter(fadePolicy: FadePolicy(delay: 0), wakeDuration: 0)
            let start = Date()
            presenter.observe(aggregate: .active(state), attention: .ignore, now: start)
            #expect(presenter.presentation(now: start.addingTimeInterval(86_400)).opacity == 1.0)
        }
    }
}

@Suite("quota notices")
struct QuotaTests {

    @Test("a window near its limit is announced once, and again after it resets")
    func announcedOncePerWindow() {
        var notifier = QuotaNotifier()
        let now = Date()
        let first = QuotaSnapshot(agent: .claudeCode, windows: [
            QuotaWindow(label: "5h", usedPercent: 92, resetsAt: now.addingTimeInterval(3600)),
            QuotaWindow(label: "7d", usedPercent: 40, resetsAt: now.addingTimeInterval(86_400)),
        ], sampledAt: now)
        #expect(notifier.newlyNearLimit(in: [first], now: now).count == 1)
        #expect(notifier.newlyNearLimit(in: [first], now: now).isEmpty)

        let nextWindow = QuotaSnapshot(agent: .claudeCode, windows: [
            QuotaWindow(label: "5h", usedPercent: 95, resetsAt: now.addingTimeInterval(5 * 3600)),
        ], sampledAt: now)
        #expect(notifier.newlyNearLimit(in: [nextWindow], now: now).count == 1)
    }

    @Test("a window whose reset has passed says nothing about now")
    func expiredWindowsIgnored() {
        let now = Date()
        let stale = QuotaSnapshot(agent: .codex, windows: [
            QuotaWindow(label: "5h", usedPercent: 99, resetsAt: now.addingTimeInterval(-60)),
        ], sampledAt: now.addingTimeInterval(-7200))
        #expect(stale.current(now: now).isEmpty)
    }

    @Test("window lengths get short labels")
    func labels() {
        #expect(QuotaWindow.label(forMinutes: 300) == "5h")
        #expect(QuotaWindow.label(forMinutes: 10080) == "7d")
        #expect(QuotaWindow.label(forMinutes: 43200) == "30d")
        #expect(QuotaWindow.label(forMinutes: 45) == "45m")
    }
}
