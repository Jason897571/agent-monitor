import Foundation
import Testing

@testable import AgentMonitorCore

@Suite("power conditions")
struct PowerConditionsTests {

    @Test("an unconstrained machine gets the requested rate")
    func unconstrainedPassesThrough() {
        #expect(PowerConditions.unconstrained.cap(24) == 24)
        #expect(PowerConditions.unconstrained.cap(2) == 2)
    }

    /// A cap may only ever lower the rate. Being cool and idle is not permission to
    /// spend more than the pose asked for.
    @Test("a cap never raises a rate")
    func capNeverRaises() {
        for thermal in PowerConditions.ThermalPressure.allCases {
            for lowPower in [true, false] {
                let conditions = PowerConditions(isLowPower: lowPower, thermal: thermal)
                #expect(conditions.cap(2) <= 2)
                #expect(conditions.cap(24) <= 24)
            }
        }
    }

    @Test("nothing on screen means nothing spent")
    func occlusionStopsEverything() {
        #expect(PowerConditions(isOccluded: true).cap(24) == 0)
    }

    /// A mascot is not what the remaining thermal headroom is for.
    @Test("critical thermal pressure stops animation outright")
    func criticalThermalStops() {
        #expect(PowerConditions(thermal: .critical).cap(24) == 0)
    }

    @Test("pressure throttles progressively")
    func pressureThrottles() {
        #expect(PowerConditions(thermal: .serious).cap(24) == 4)
        #expect(PowerConditions(thermal: .fair).cap(24) == 12)
        #expect(PowerConditions(isLowPower: true).cap(24) == 12)
        #expect(PowerConditions(isLowPower: true, thermal: .fair).cap(24) == 6)
    }

    @Test("zero stays zero")
    func zeroStaysZero() {
        #expect(PowerConditions.unconstrained.cap(0) == 0)
        #expect(PowerConditions(thermal: .serious).cap(0) == 0)
    }

    @Test("the presenter applies the cap")
    func presenterAppliesCap() {
        var presenter = PetPresenter(fadePolicy: .never)
        presenter.observe(aggregate: .active(.busy), attention: .ignore, now: Date())
        let now = Date().addingTimeInterval(5)

        #expect(presenter.presentation(now: now).framesPerSecond == 24)
        presenter.power = PowerConditions(thermal: .serious)
        #expect(presenter.presentation(now: now).framesPerSecond == 4)
        presenter.power = PowerConditions(isOccluded: true)
        #expect(presenter.presentation(now: now).framesPerSecond == 0)
    }
}

@Suite("session summary")
struct SessionSummaryTests {

    private func session(_ state: SessionState, pid: pid_t) -> AgentSession {
        AgentSession(
            id: "s\(pid)", agent: .claudeCode, pid: pid, cwd: "/tmp",
            state: state, startedAt: .distantPast,
            stateChangedAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test("counts by state")
    func countsByState() {
        let summary = SessionSummary(sessions: [
            session(.busy, pid: 1), session(.busy, pid: 2),
            session(.idle, pid: 3), session(.waiting, pid: 4),
        ])
        #expect(summary.total == 4)
        #expect(summary.count(.busy) == 2)
        #expect(summary.count(.idle) == 1)
        #expect(summary.count(.shell) == 0)
    }

    @Test("no sessions is empty")
    func emptyIsEmpty() {
        let summary = SessionSummary(sessions: [])
        #expect(summary.isEmpty)
        #expect(summary.badges.isEmpty)
    }

    /// The bar is one-dimensional and unreadable past a few items, so it badges only
    /// what is worth acting on and leaves the rest to the total.
    @Test("badges cover only the states worth acting on, most urgent first")
    func badgesAreSelectiveAndOrdered() {
        let summary = SessionSummary(sessions: [
            session(.idle, pid: 1), session(.shell, pid: 2),
            session(.busy, pid: 3), session(.waiting, pid: 4),
        ])
        let badges = summary.badges
        #expect(badges.count == 2)
        #expect(badges.first?.state == .waiting)
        #expect(badges.last?.state == .busy)
    }
}

@Suite("transcript titles")
struct ClaudeTranscriptTests {

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("reads the model-generated title")
    func readsTitle() throws {
        let url = try write([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"ai-title","aiTitle":"设计桌面宠物助手和任务监测系统","sessionId":"abc"}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeTranscript.latestTitle(in: url) == "设计桌面宠物助手和任务监测系统")
    }

    @Test("prefers the most recent title when a session is renamed")
    func prefersLatestTitle() throws {
        let url = try write([
            #"{"type":"ai-title","aiTitle":"First guess"}"#,
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"ai-title","aiTitle":"Better name"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeTranscript.latestTitle(in: url) == "Better name")
    }

    @Test("a transcript with no title yet yields nothing")
    func missingTitleIsNil() throws {
        let url = try write([#"{"type":"user","message":{"role":"user"}}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeTranscript.latestTitle(in: url) == nil)
    }

    @Test("a missing file yields nothing rather than throwing")
    func missingFileIsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).jsonl")
        #expect(ClaudeTranscript.latestTitle(in: url) == nil)
    }

    /// Only the tail is read, so a title buried behind megabytes of conversation is
    /// out of reach by design — `displayName` is the guaranteed label, this is a bonus.
    @Test("only the tail is read")
    func readsOnlyTheTail() throws {
        let filler = #"{"type":"assistant","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}"#
        var lines = [#"{"type":"ai-title","aiTitle":"Buried"}"#]
        lines.append(contentsOf: Array(repeating: filler, count: 8000))
        let url = try write(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        // ~600 KB of conversation sits between the title and the end of the file, so
        // the default window cannot reach it. Bounded by construction: a monitor that
        // watches one small directory must not start reading hundreds of megabytes of
        // transcript to recover a label.
        #expect(ClaudeTranscript.latestTitle(in: url) == nil)
        // The same file, read whole, does contain it.
        #expect(ClaudeTranscript.latestTitle(in: url, maxBytes: 4_000_000) == "Buried")
    }

    /// Seeking into the middle of a file lands mid-line; that fragment is not JSON and
    /// must not be parsed.
    @Test("a partial first line is discarded")
    func partialLineIsDiscarded() throws {
        let url = try write([
            String(repeating: "a", count: 5000),
            #"{"type":"ai-title","aiTitle":"Clean"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeTranscript.latestTitle(in: url, maxBytes: 2048) == "Clean")
    }

    @Test("an empty title is treated as absent")
    func emptyTitleIsAbsent() throws {
        let url = try write([#"{"type":"ai-title","aiTitle":"   "}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeTranscript.latestTitle(in: url) == nil)
    }
}

@Suite("display order")
struct DisplayOrderTests {

    private func session(_ state: SessionState, pid: pid_t, changed: TimeInterval) -> AgentSession {
        AgentSession(
            id: "s\(pid)", agent: .claudeCode, pid: pid, cwd: "/tmp", state: state,
            startedAt: .distantPast, stateChangedAt: Date(timeIntervalSince1970: changed),
            updatedAt: .distantPast
        )
    }

    @Test("blocked sessions first, then working, then recently idle before long idle")
    func ordersByUrgencyThenRecency() {
        let ordered = [
            session(.idle, pid: 1, changed: 100),
            session(.busy, pid: 2, changed: 50),
            session(.idle, pid: 3, changed: 900),
            session(.waiting, pid: 4, changed: 10),
            session(.shell, pid: 5, changed: 999),
        ].orderedForDisplay().map(\.pid)
        #expect(ordered == [4, 2, 3, 1, 5])
    }
}

@Suite("process ancestry")
struct ProcessAncestryTests {

    @Test("walks up to, but not including, launchd")
    func walksToLaunchd() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 1]
        #expect(ProcessInspector.ancestry(of: 500, parent: { parents[$0] }) == [500, 400, 300])
    }

    @Test("stops where the table stops")
    func stopsAtMissingParent() {
        let parents: [pid_t: pid_t] = [500: 400]
        #expect(ProcessInspector.ancestry(of: 500, parent: { parents[$0] }) == [500, 400])
    }

    /// A pid recycled mid-walk can make the table point back into itself.
    @Test("a cycle terminates instead of hanging")
    func cycleTerminates() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 500]
        #expect(ProcessInspector.ancestry(of: 500, parent: { parents[$0] }) == [500, 400])
    }

    @Test("the live process tree reaches this test runner's own ancestors")
    func liveTreeWorks() {
        let chain = ProcessInspector.ancestry(of: getpid())
        #expect(chain.first == getpid())
        #expect(chain.count >= 2)
    }
}
