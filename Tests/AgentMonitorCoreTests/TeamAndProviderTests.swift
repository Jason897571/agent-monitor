import Foundation
import Testing

@testable import AgentMonitorCore

private func task(_ id: String, owner: String?, _ status: ClaudeTask.Status, blockedBy: [String] = [],
                  activeForm: String? = nil) -> ClaudeTask {
    ClaudeTask(id: id, subject: "task \(id)", activeForm: activeForm, owner: owner, status: status, blockedBy: blockedBy)
}

private let config = ClaudeTeams.TeamConfig(
    name: "build",
    leadSessionId: "lead-session",
    leadAgentId: "lead@build",
    members: [
        .init(agentId: "lead@build", name: "team-lead", agentType: "team-lead", backendType: "in-process", tmuxPaneId: "leader"),
        .init(agentId: "a@build", name: "researcher", agentType: nil, backendType: "tmux", tmuxPaneId: "%1"),
        .init(agentId: "b@build", name: "coder", agentType: nil, backendType: "tmux", tmuxPaneId: "%2"),
        .init(agentId: "c@build", name: "tester", agentType: nil, backendType: "tmux", tmuxPaneId: "%3"),
        .init(agentId: "d@build", name: "writer", agentType: nil, backendType: "tmux", tmuxPaneId: "%4"),
    ]
)

@Suite("agent teams")
struct TeamTests {

    @Test("teammate states come from the tasks they hold")
    func states() {
        let team = ClaudeTeams.build(config: config, tasks: [
            task("1", owner: "researcher", .completed),
            task("2", owner: "coder", .inProgress, blockedBy: ["1"], activeForm: "写接口"),
            task("3", owner: "tester", .pending, blockedBy: ["2"]),
            task("4", owner: "writer", .pending, blockedBy: ["1"]),
        ])
        let byName = Dictionary(uniqueKeysWithValues: team.members.map { ($0.name, $0) })
        #expect(byName["coder"]?.state == .working)
        #expect(byName["coder"]?.activity == "写接口")
        #expect(byName["tester"]?.state == .blocked)
        // Its only dependency is done, yet it is not working: the stalled worker.
        #expect(byName["writer"]?.state == .stalled)
        #expect(byName["researcher"]?.state == .idle)
        #expect(byName["team-lead"]?.isLead == true)
        #expect(team.stalled.map(\.name) == ["writer"])
    }

    @Test("depth follows the dependency chain and edges connect people")
    func topology() {
        let team = ClaudeTeams.build(config: config, tasks: [
            task("1", owner: "researcher", .inProgress),
            task("2", owner: "coder", .pending, blockedBy: ["1"]),
            task("3", owner: "tester", .pending, blockedBy: ["2"]),
        ])
        let depth = Dictionary(uniqueKeysWithValues: team.members.map { ($0.name, $0.depth) })
        #expect(depth["researcher"] == 0)
        #expect(depth["coder"] == 1)
        #expect(depth["tester"] == 2)
        #expect(team.edges == [AgentTeam.Edge(from: "coder", to: "tester"), AgentTeam.Edge(from: "researcher", to: "coder")])
    }

    @Test("the lead is never captioned with a teammate's work")
    func leadActivity() {
        let tasks = [
            task("1", owner: "coder", .inProgress, activeForm: "写接口"),
            task("2", owner: "", .inProgress, activeForm: "拆分任务"),
        ]
        #expect(ClaudeTeams.activity(in: tasks) == "拆分任务")
        #expect(ClaudeTeams.activity(in: [tasks[0]]) == nil)
        #expect(ClaudeTeams.activity(in: tasks, owner: "coder") == "写接口")
    }

    /// A malformed list must degrade to a flat layout, never hang the monitor.
    @Test("a dependency cycle does not hang")
    func cycle() {
        let team = ClaudeTeams.build(config: config, tasks: [
            task("1", owner: "coder", .pending, blockedBy: ["2"]),
            task("2", owner: "tester", .pending, blockedBy: ["1"]),
        ])
        #expect(team.members.count == 5)
    }

    @Test("teams and task lists are read from the config directory")
    func readsFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("teams-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ClaudeConfigLocator(directory: root, source: .defaultPath)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("teams/build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tasks/build"), withIntermediateDirectories: true)
        try """
        {"name":"build","createdAt":1,"leadAgentId":"lead@build","leadSessionId":"S","members":[
          {"agentId":"lead@build","name":"team-lead","agentType":"team-lead","tmuxPaneId":"leader","backendType":"in-process","cwd":"/x","subscriptions":[]},
          {"agentId":"w@build","name":"worker","tmuxPaneId":"%9","backendType":"tmux","cwd":"/x","subscriptions":[],"color":"blue"}]}
        """.write(to: root.appendingPathComponent("teams/build/config.json"), atomically: true, encoding: .utf8)
        try #"{"id":"1","subject":"Do it","description":"","activeForm":"Doing it","owner":"worker","status":"in_progress","blocks":[],"blockedBy":[]}"#
            .write(to: root.appendingPathComponent("tasks/build/1.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("tasks/build/.lock"), atomically: true, encoding: .utf8)

        let teams = ClaudeTeams.teams(in: locator)
        #expect(teams.count == 1)
        #expect(teams.first?.leadSessionId == "S")
        #expect(teams.first?.members.first { $0.name == "worker" }?.state == .working)
        #expect(ClaudeTeams.activity(in: ClaudeTeams.tasks(list: "build", in: locator), owner: "worker") == "Doing it")
    }
}

@Suite("Claude provider")
struct ClaudeProviderTests {

    private final class Liveness: @unchecked Sendable {
        var alive = true
    }

    private func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-\(UUID().uuidString)").path).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, pid: Int, status: String, waitingFor: String? = nil) throws {
        let extra = waitingFor.map { #","waitingFor":"\#($0)""# } ?? ""
        try #"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/tmp/p","status":"\#(status)","statusUpdatedAt":1790000000000\#(extra)}"#
            .write(to: root.appendingPathComponent("sessions/\(pid).json"), atomically: true, encoding: .utf8)
    }

    /// A clean exit removes the file; a crash leaves it with a dead pid. For a session we
    /// saw alive, that difference is the only trace a crash leaves.
    @Test("a session that dies without cleaning up shows as disconnected, then goes")
    func disconnected() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11, status: "busy")
        let liveness = Liveness()
        let source = ClaudeSessionSource(
            locator: ClaudeConfigLocator(directory: root, source: .defaultPath),
            inspector: { pid in liveness.alive ? ProcessInspector.Info(pid: pid, command: "claude", startTime: .distantPast) : nil }
        )
        let provider = ClaudeProvider(source: source, statusline: nil)
        provider.disconnectedGrace = 600
        let start = Date()

        #expect(provider.scan(now: start).sessions.first?.state == .busy)
        liveness.alive = false
        let crashed = provider.scan(now: start.addingTimeInterval(5)).sessions
        #expect(crashed.map(\.state) == [.disconnected])
        #expect(provider.scan(now: start.addingTimeInterval(700)).sessions.isEmpty)
    }

    @Test("a clean exit is not a crash")
    func cleanExit() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 12, status: "idle")
        let source = ClaudeSessionSource(
            locator: ClaudeConfigLocator(directory: root, source: .defaultPath),
            inspector: { pid in ProcessInspector.Info(pid: pid, command: "claude", startTime: .distantPast) }
        )
        let provider = ClaudeProvider(source: source, statusline: nil)
        #expect(provider.scan(now: Date()).sessions.count == 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/12.json"))
        #expect(provider.scan(now: Date()).sessions.isEmpty)
    }

    /// Stale leftovers from before launch are not reported: nobody can say when they died.
    @Test("sessions already dead at launch are not reported as crashes")
    func preexistingLeftovers() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 13, status: "busy")
        let source = ClaudeSessionSource(locator: ClaudeConfigLocator(directory: root, source: .defaultPath),
                                         inspector: { _ in nil })
        #expect(ClaudeProvider(source: source, statusline: nil).scan(now: Date()).sessions.isEmpty)
    }

    @Test("a permission prompt in the session file is awaitingPermission with no hook installed")
    func passivePermission() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 14, status: "waiting", waitingFor: "permission prompt")
        let source = ClaudeSessionSource(
            locator: ClaudeConfigLocator(directory: root, source: .defaultPath),
            inspector: { pid in ProcessInspector.Info(pid: pid, command: "claude", startTime: .distantPast) }
        )
        #expect(ClaudeProvider(source: source, statusline: nil).scan(now: Date()).sessions.first?.state == .awaitingPermission)
    }
}
