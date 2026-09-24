import Foundation
import Testing

@testable import AgentMonitorCore

/// A fake agent home with Codex-shaped rollouts in it.
private struct CodexSandbox {
    let home: URL

    init() throws {
        home = URL(fileURLWithPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-monitor-codex-\(UUID().uuidString)").path).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions/2026/09/24"),
                                                withIntermediateDirectories: true)
    }

    func rollout(_ id: String) -> URL {
        home.appendingPathComponent("sessions/2026/09/24/rollout-2026-09-24T01-00-00-\(id).jsonl")
    }

    func write(_ id: String, cwd: String, origin: String = "codex_exec", lines: [String]) throws {
        let header = #"{"timestamp":"2026-09-24T01:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","originator":"\#(origin)","timestamp":"2026-09-24T01:00:00.000Z"}}"#
        try ([header] + lines).joined(separator: "\n").appending("\n")
            .write(to: rollout(id), atomically: true, encoding: .utf8)
    }

    func append(_ id: String, _ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: rollout(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }
}

private func event(_ type: String, at second: Int, extra: String = "") -> String {
    #"{"timestamp":"2026-09-24T01:00:\#(String(format: "%02d", second)).000Z","type":"event_msg","payload":{"type":"\#(type)"\#(extra)}}"#
}

private let codex = try! AgentManifest.decode(Data(BuiltinManifests.codex.utf8))

private func provider(_ sandbox: CodexSandbox, processes: [(pid: pid_t, cwd: String, args: String)],
                      started: Date = Date(timeIntervalSince1970: 0)) -> ManifestProvider {
    let view = ManifestProvider.ProcessView(
        list: { _ in processes.map { ProcessInspector.Info(pid: $0.pid, command: "codex", startTime: started) } },
        cwd: { pid in processes.first { $0.pid == pid }?.cwd },
        arguments: { pid in (processes.first { $0.pid == pid }?.args ?? "").split(separator: " ").map(String.init) },
        exists: { pid in processes.contains { $0.pid == pid } }
    )
    return ManifestProvider(manifest: codex, home: sandbox.home, processes: view)
}

@Suite("agent manifests")
struct ManifestTests {

    /// The embedded copy is what runs; the repo copy is what contributors read. They must
    /// not drift.
    @Test("the built-in Codex manifest matches manifests/codex.json")
    func builtinMatchesRepo() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("manifests/codex.json")
        let onDisk = try AgentManifest.decode(Data(contentsOf: repo))
        #expect(onDisk == codex)
    }

    @Test("an unknown schema version is refused, not half-understood")
    func refusesUnknownSchema() {
        let json = #"{"schema":2,"id":"x","displayName":"X","home":{"default":"~/.x"},"processNames":[]}"#
        #expect(throws: AgentManifest.LoadError.unsupportedSchema(2)) { try AgentManifest.decode(Data(json.utf8)) }
    }

    @Test("glob matches one component per star and nothing deeper")
    func glob() throws {
        let sandbox = try CodexSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("a", cwd: "/p", lines: [])
        try "x".write(to: sandbox.home.appendingPathComponent("sessions/2026/09/24/other.txt"), atomically: true, encoding: .utf8)
        let found = ManifestProvider.glob("sessions/*/*/*/rollout-*.jsonl", under: sandbox.home)
        #expect(found.map(\.lastPathComponent) == [sandbox.rollout("a").lastPathComponent])
    }

    @Test("a CLI process owns the log for its working directory, and the newest event sets the state")
    func cliSessionLifecycle() throws {
        let sandbox = try CodexSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("t1", cwd: "/work/app", lines: [event("task_started", at: 1)])
        let codexProvider = provider(sandbox, processes: [(42, "/work/app", "codex exec do it")])

        let busy = codexProvider.scan(now: Date())
        #expect(busy.sessions.count == 1)
        #expect(busy.sessions.first?.state == .busy)
        #expect(busy.sessions.first?.pid == 42)
        #expect(busy.sessions.first?.agent == .codex)

        // Only the appended bytes are read on the next scan.
        try sandbox.append("t1", [event("task_complete", at: 5, extra: #","last_agent_message":"ok""#)])
        let done = codexProvider.scan(now: Date())
        #expect(done.sessions.first?.state == .doneSuccess)
        #expect(done.sessions.first?.rawState == .idle)
    }

    @Test("a turn that completed with an error is doneError, with a one-line reason")
    func erroredTurn() throws {
        let sandbox = try CodexSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("t2", cwd: "/work/app", lines: [
            event("task_started", at: 1),
            event("task_complete", at: 3, extra: #","error":{"message":"unexpected status 403 Forbidden: <html>\n<head>"}"#),
        ])
        let session = provider(sandbox, processes: [(7, "/work/app", "codex")]).scan(now: Date()).sessions.first
        #expect(session?.state == .doneError)
        #expect(session?.problem == "unexpected status 403 Forbidden: <html>")
    }

    @Test("no process, no session — a finished run is not a live one")
    func deadIsGone() throws {
        let sandbox = try CodexSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("t3", cwd: "/work/app", lines: [event("task_started", at: 1)])
        #expect(provider(sandbox, processes: []).scan(now: Date()).sessions.isEmpty)
        // A process in another directory does not own it either.
        #expect(provider(sandbox, processes: [(9, "/elsewhere", "codex")]).scan(now: Date()).sessions.isEmpty)
    }

    /// A desktop app runs one app server for many threads. Recency stands in for
    /// liveness there — but only for threads the app itself started.
    @Test("a host process keeps its own recent threads alive, and only its own")
    func hostProcess() throws {
        let sandbox = try CodexSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("desk", cwd: "/a", origin: "Codex Desktop", lines: [event("task_started", at: 1)])
        try sandbox.write("cli", cwd: "/b", origin: "codex_exec", lines: [event("task_complete", at: 1)])
        let scan = provider(sandbox, processes: [(100, "/", "codex app-server --listen x")]).scan(now: Date())
        #expect(scan.sessions.map(\.id) == ["desk"])
        #expect(scan.sessions.first?.pid == 100)
    }

    @Test("context use and plan quota are read from token counts")
    func contextAndQuota() throws {
        let sandbox = try CodexSandbox()
        defer { sandbox.cleanUp() }
        let tokens = #","info":{"last_token_usage":{"input_tokens":240000},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":44.0,"window_minutes":43200,"resets_at":1790313057},"secondary":null}"#
        try sandbox.write("t4", cwd: "/w", lines: [event("task_started", at: 1), event("token_count", at: 2, extra: tokens)])
        let scan = provider(sandbox, processes: [(5, "/w", "codex")]).scan(now: Date())
        let session = try #require(scan.sessions.first)
        #expect(Int(session.contextUsedPercent ?? 0) == 92)
        #expect(session.state == .contextCritical)
        #expect(scan.quota?.windows == [QuotaWindow(label: "30d", usedPercent: 44, resetsAt: Date(timeIntervalSince1970: 1_790_313_057))])
    }

    @Test("titles come from the session index")
    func titles() throws {
        let sandbox = try CodexSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("t5", cwd: "/w", lines: [event("task_started", at: 1)])
        try """
        {"id":"t5","thread_name":"old name"}
        {"id":"t5","thread_name":"Review and suggest improvements"}
        """.write(to: sandbox.home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let session = provider(sandbox, processes: [(5, "/w", "codex")]).scan(now: Date()).sessions.first
        #expect(session?.title == "Review and suggest improvements")
    }

    /// The second shape: a JSON document per session with a pid, like Claude Code's own
    /// registry. Proves an agent of that shape needs no Swift either.
    @Test("a session-files manifest maps statuses and checks the pid")
    func sessionFiles() throws {
        let manifest = try AgentManifest.decode(Data("""
        {"schema":1,"id":"toy","displayName":"Toy","home":{"default":"/unused"},"processNames":["toy"],
         "sessionFiles":{"directory":"live","pid":"pid","id":"id","cwd":"dir","status":"phase",
                         "statusMap":{"thinking":"busy","asking":"awaitingPermission","resting":"idle"}}}
        """.utf8))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("toy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("live"), withIntermediateDirectories: true)
        for (pid, phase) in [(1, "thinking"), (2, "asking"), (3, "exploding"), (4, "resting")] {
            try #"{"pid":\#(pid),"id":"s\#(pid)","dir":"/p\#(pid)","phase":"\#(phase)"}"#
                .write(to: home.appendingPathComponent("live/\(pid).json"), atomically: true, encoding: .utf8)
        }
        let view = ManifestProvider.ProcessView(list: { _ in [] }, cwd: { _ in nil }, arguments: { _ in [] },
                                                exists: { $0 != 4 })
        let scan = ManifestProvider(manifest: manifest, home: home, processes: view).scan(now: Date())
        let states = Dictionary(uniqueKeysWithValues: scan.sessions.map { ($0.id, $0.state) })
        #expect(states == ["s1": .busy, "s2": .awaitingPermission])
        #expect(scan.rejected.map(\.reason).sorted() == ["process gone", "unknown status 'exploding'"])
    }
}
