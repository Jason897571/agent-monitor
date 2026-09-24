import Foundation
import Testing

@testable import AgentMonitorCore

private func event(_ name: String, session: String = "s1", tool: String? = nil, agent: String? = nil,
                   error: String? = nil, source: String? = nil, at seconds: TimeInterval = 0) -> HookEvent {
    HookEvent(name: name, sessionID: session, toolName: tool, agentID: agent, error: error,
              source: source, receivedAt: Date(timeIntervalSince1970: 10_000 + seconds))
}

private func session(_ state: SessionState, id: String = "s1") -> AgentSession {
    AgentSession(id: id, agent: .claudeCode, pid: 1, cwd: "/tmp", state: state,
                 startedAt: .distantPast, stateChangedAt: Date(timeIntervalSince1970: 9_000),
                 updatedAt: Date(timeIntervalSince1970: 9_000))
}

@Suite("hook event store")
struct HookEventStoreTests {

    private let now = Date(timeIntervalSince1970: 10_100)

    @Test("compaction shows while it runs, and only on a busy session")
    func compacting() {
        let store = HookEventStore()
        store.apply(event("PreCompact"))
        var busy = session(.busy)
        store.refine(&busy, now: now)
        #expect(busy.state == .compacting)

        var idle = session(.idle)
        store.refine(&idle, now: now)
        #expect(idle.state == .idle)

        store.apply(event("PostCompact", at: 30))
        var after = session(.busy)
        store.refine(&after, now: now)
        #expect(after.state == .busy)
    }

    /// A PostCompact the app missed must not leave a session "compacting" forever.
    @Test("a compaction that never reported its end times out")
    func compactionTimesOut() {
        let store = HookEventStore()
        store.apply(event("PreCompact"))
        var s = session(.busy)
        store.refine(&s, now: Date(timeIntervalSince1970: 10_000 + 3600))
        #expect(s.state == .busy)
    }

    @Test("two or more subagents make a swarm")
    func swarm() {
        let store = HookEventStore()
        store.apply(event("SubagentStart", agent: "a"))
        var one = session(.busy)
        store.refine(&one, now: now)
        #expect(one.state == .busy && one.subagents == 1)

        store.apply(event("SubagentStart", agent: "b"))
        var two = session(.busy)
        store.refine(&two, now: now)
        #expect(two.state == .subagentSwarm && two.subagents == 2)

        // The parent's turn ending does not end its subagents: they can run on in the
        // background, as observed against a real `claude -p` run.
        store.apply(event("Stop", at: 20))
        var afterStop = session(.busy)
        store.refine(&afterStop, now: now)
        #expect(afterStop.state == .subagentSwarm)

        store.apply(event("SubagentStop", agent: "a"))
        var back = session(.busy)
        store.refine(&back, now: now)
        #expect(back.state == .busy)
    }

    @Test("a subagent whose end was never seen stops counting eventually")
    func subagentTimeout() {
        let store = HookEventStore()
        store.apply(event("SubagentStart", agent: "a"))
        store.apply(event("SubagentStart", agent: "b"))
        var s = session(.busy)
        store.refine(&s, now: Date(timeIntervalSince1970: 10_000 + 3 * 3600))
        #expect(s.state == .busy && s.subagents == 0)
    }

    @Test("Stop and StopFailure say how the turn ended; a new prompt clears it")
    func endings() {
        let store = HookEventStore()
        store.apply(event("Stop", at: 50))
        var done = session(.idle)
        store.refine(&done, now: now)
        #expect(done.state == .doneSuccess)
        #expect(done.stateChangedAt == Date(timeIntervalSince1970: 10_050))

        store.apply(event("StopFailure", error: "rate_limit", at: 60))
        var limited = session(.idle)
        store.refine(&limited, now: now)
        #expect(limited.state == .rateLimited)

        store.apply(event("StopFailure", error: "server_error", at: 70))
        var failed = session(.idle)
        store.refine(&failed, now: now)
        #expect(failed.state == .doneError)

        store.apply(event("UserPromptSubmit", at: 80))
        var fresh = session(.idle)
        store.refine(&fresh, now: now)
        #expect(fresh.state == .idle)
    }

    @Test("the current tool becomes a caption while busy")
    func toolCaption() {
        let store = HookEventStore()
        store.apply(event("PreToolUse", tool: "Bash"))
        var s = session(.busy)
        store.refine(&s, now: now)
        #expect(s.activity == "运行命令")
        store.apply(event("PreToolUse", tool: "mcp__github__create_issue"))
        var t = session(.busy)
        store.refine(&t, now: now)
        #expect(t.activity == "调用 github")
    }

    @Test("SessionEnd forgets the session, and events are per session")
    func isolation() {
        let store = HookEventStore()
        store.apply(event("PreCompact", session: "a"))
        var other = session(.busy, id: "b")
        store.refine(&other, now: now)
        #expect(other.state == .busy)
        store.apply(event("SessionEnd", session: "a"))
        #expect(store.overlay(for: "a") == nil)
    }

    @Test("a real hook payload decodes, extra fields and all")
    func decodesRealPayload() throws {
        let json = #"""
        {"session_id":"a29155bd","transcript_path":"/x.jsonl","cwd":"/tmp","permission_mode":"default",
         "hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},
         "tool_use_id":"toolu_1","effort":"high","prompt_id":"p1"}
        """#
        let decoded = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(decoded.name == "PreToolUse")
        #expect(decoded.sessionID == "a29155bd")
        #expect(decoded.toolName == "Bash")
    }
}

@Suite("hook server")
struct HookServerTests {

    @Test("parses one POST with a body, and waits for the rest of a split one")
    func parsing() {
        let body = #"{"hook_event_name":"Stop","session_id":"s"}"#
        let request = "POST /agent-monitor/v1/Stop HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let parsed) = HTTPRequest.parse(Data(request.utf8)) else {
            Issue.record("did not parse"); return
        }
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/agent-monitor/v1/Stop")
        #expect(String(decoding: parsed.body, as: UTF8.self) == body)

        #expect(HTTPRequest.parse(Data(String(request.dropLast(5)).utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-".utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("garbage\r\n\r\n".utf8)) == .invalid)
    }

    /// End to end over a real socket, exactly as Claude Code's http hook calls it: the
    /// reply must be a 200 with an empty body, which Claude Code reads as "no decision".
    @Test("delivers a hook over loopback and answers with an empty 200")
    func endToEnd() async throws {
        let port = UInt16.random(in: 50_000...60_000)
        let received = Received()
        let server = HookServer(port: port) { event in received.append(event) }
        server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(HookServer.pathPrefix)PreToolUse")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hook_event_name":"PreToolUse","session_id":"abc","tool_name":"Read"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var response: (Data, URLResponse)?
        for _ in 0..<20 {  // the listener takes a moment to come up
            response = try? await URLSession.shared.data(for: request)
            if response != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let (data, urlResponse) = try #require(response)
        #expect((urlResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.isEmpty)
        #expect(received.events.first?.toolName == "Read")
        #expect(received.events.first?.sessionID == "abc")
    }

    @Test("rejects paths that are not hooks")
    func rejectsOtherPaths() async throws {
        let port = UInt16.random(in: 50_000...60_000)
        let received = Received()
        let server = HookServer(port: port) { received.append($0) }
        server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/somewhere-else")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8)
        var status: Int?
        for _ in 0..<20 {
            if let (_, response) = try? await URLSession.shared.data(for: request) {
                status = (response as? HTTPURLResponse)?.statusCode
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(status == 404)
        #expect(received.events.isEmpty)
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [HookEvent] = []
    var events: [HookEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func append(_ event: HookEvent) { lock.lock(); _events.append(event); lock.unlock() }
}
