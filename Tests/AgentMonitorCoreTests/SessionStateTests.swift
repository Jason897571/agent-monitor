import Foundation
import Testing

@testable import AgentMonitorCore

@Suite("session state")
struct SessionStateTests {

    @Test("decodes Claude Code's four canonical statuses")
    func decodesCanonicalStatuses() {
        #expect(SessionState(rawStatus: "busy") == .busy)
        #expect(SessionState(rawStatus: "shell") == .shell)
        #expect(SessionState(rawStatus: "idle") == .idle)
        #expect(SessionState(rawStatus: "waiting") == .waiting)
    }

    /// An unrecognised status must not silently become `idle`. A future Claude Code
    /// release that adds a state should surface as unknown, not as "nothing happening".
    @Test("refuses to guess at unknown statuses")
    func refusesUnknownStatuses() {
        #expect(SessionState(rawStatus: "compacting") == nil)
        #expect(SessionState(rawStatus: nil) == nil)
        #expect(SessionState(rawStatus: "") == nil)
    }

    @Test("waiting outranks busy outranks idle outranks shell")
    func urgencyOrdering() {
        #expect(SessionState.waiting.urgency > SessionState.busy.urgency)
        #expect(SessionState.busy.urgency > SessionState.idle.urgency)
        #expect(SessionState.idle.urgency > SessionState.shell.urgency)
    }
}

@Suite("aggregate state")
struct AggregateStateTests {

    private func session(_ state: SessionState, pid: pid_t = 1) -> AgentSession {
        AgentSession(
            id: "s\(pid)", agent: .claudeCode, pid: pid, cwd: "/tmp",
            state: state, startedAt: .distantPast,
            stateChangedAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test("no sessions means dormant — the pet sleeps")
    func noSessionsIsDormant() {
        #expect(AggregateState(sessions: []) == .dormant)
        #expect(AggregateState(sessions: []).isDormant)
    }

    /// The distinction DESIGN.md §2 B.1 insists on: an idle session is an agent
    /// waiting on *you*, and must never be rendered as "you aren't using agents".
    /// Collapsing the two inverts the information the pet conveys.
    @Test("an idle session is active, not dormant")
    func idleSessionIsNotDormant() {
        let aggregate = AggregateState(sessions: [session(.idle)])
        #expect(aggregate == .active(.idle))
        #expect(aggregate.isDormant == false)
    }

    @Test("the most urgent session wins")
    func picksMostUrgent() {
        let sessions = [session(.idle, pid: 1), session(.waiting, pid: 2), session(.busy, pid: 3)]
        #expect(AggregateState(sessions: sessions) == .active(.waiting))
    }
}

@Suite("agent session")
struct AgentSessionTests {

    /// Never derive a label from the project-directory slug — that transform is lossy
    /// and irreversible. See DESIGN.md §7.1 trap #2.
    @Test("display name falls back to the cwd basename")
    func displayNameFallsBackToBasename() {
        let session = AgentSession(
            id: "abcdef12-0000", agent: .claudeCode, pid: 1,
            cwd: "/Users/someone/Desktop/pp/agent-monitor",
            state: .idle, startedAt: .distantPast,
            stateChangedAt: .distantPast, updatedAt: .distantPast, name: nil
        )
        #expect(session.displayName == "agent-monitor")
    }

    /// Real cwds on the development machine included `短剧生成工作流` and `pp worker`.
    /// Both survive here because the path comes from the session file verbatim; both
    /// would have been destroyed by un-slugging a project directory name.
    @Test("display name survives non-ASCII and spaced paths")
    func displayNameSurvivesAwkwardPaths() {
        let cjk = AgentSession(
            id: "a", agent: .claudeCode, pid: 1,
            cwd: "/Users/someone/Desktop/short_drama/短剧生成工作流",
            state: .idle, startedAt: .distantPast,
            stateChangedAt: .distantPast, updatedAt: .distantPast, name: nil
        )
        #expect(cjk.displayName == "短剧生成工作流")

        let spaced = AgentSession(
            id: "b", agent: .claudeCode, pid: 2, cwd: "/Users/someone/Desktop/pp worker",
            state: .idle, startedAt: .distantPast,
            stateChangedAt: .distantPast, updatedAt: .distantPast, name: nil
        )
        #expect(spaced.displayName == "pp worker")
    }

    @Test("display name prefers the agent-derived name")
    func displayNamePrefersAgentName() {
        let session = AgentSession(
            id: "abcdef12-0000", agent: .claudeCode, pid: 1, cwd: "/tmp/x",
            state: .idle, startedAt: .distantPast,
            stateChangedAt: .distantPast, updatedAt: .distantPast, name: "agent-monitor-e8"
        )
        #expect(session.displayName == "agent-monitor-e8")
    }

    /// The escalation clock reads from `stateChangedAt`, not `updatedAt` — Claude Code
    /// only advances the former on a real transition, which is what makes
    /// "waiting for 20 minutes" measurable at all.
    @Test("time in state measures from the last state change")
    func timeInStateMeasuresFromStateChange() {
        let changed = Date(timeIntervalSince1970: 1_000_000)
        let session = AgentSession(
            id: "a", agent: .claudeCode, pid: 1, cwd: "/tmp",
            state: .waiting, startedAt: .distantPast,
            stateChangedAt: changed, updatedAt: Date(timeIntervalSince1970: 1_000_500)
        )
        #expect(abs(session.timeInState(now: changed.addingTimeInterval(120)) - 120) < 0.001)
    }
}
