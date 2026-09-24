import Foundation
import Testing

@testable import AgentMonitorCore

@Suite("transcript tail")
struct TranscriptTailTests {

    private func tail(_ lines: [String]) -> ClaudeTranscript.Tail {
        ClaudeTranscript.parse(lines: lines.map { ArraySlice(Array($0.utf8)) })
    }

    private func user(_ text: String, at time: String) -> String {
        #"{"type":"user","timestamp":"\#(time)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func toolResult(at time: String) -> String {
        #"{"type":"user","timestamp":"\#(time)","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
    }

    private func assistant(_ text: String, at time: String) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func apiError(_ kind: String, _ text: String, at time: String) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","error":"\#(kind)","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func recap(_ text: String, at time: String) -> String {
        #"{"type":"system","subtype":"away_summary","timestamp":"\#(time)","content":"\#(text) (disable recaps in /config)"}"#
    }

    @Test("a turn that ended on the assistant's word completed")
    func completed() {
        let result = tail([
            user("do it", at: "2026-09-24T01:00:00.000Z"),
            assistant("done", at: "2026-09-24T01:00:05.000Z"),
            #"{"type":"system","subtype":"turn_duration","durationMs":5000}"#,
        ])
        guard case .completed = result.ending else { Issue.record("expected completed, got \(String(describing: result.ending))"); return }
    }

    /// Captured from a real rate-limited session: the error is its own assistant line.
    @Test("an API error line is how a failed turn ends, and a 429 is its own state")
    func apiErrors() {
        let limited = tail([
            user("go", at: "2026-09-24T01:00:00.000Z"),
            apiError("rate_limit", "You've hit your session limit · resets 6:10am", at: "2026-09-24T01:00:01.000Z"),
        ])
        #expect(limited.ending == .apiError(kind: "rate_limit", message: "You've hit your session limit · resets 6:10am",
                                            at: ClaudeTranscript.parseTimestamp("2026-09-24T01:00:01.000Z")!))

        let failed = tail([
            assistant("working", at: "2026-09-24T01:00:00.000Z"),
            toolResult(at: "2026-09-24T01:00:01.000Z"),
            apiError("server_error", "API Error: Connection closed mid-response.", at: "2026-09-24T01:00:02.000Z"),
        ])
        guard case .apiError(let kind, _, _) = failed.ending else { Issue.record("expected an error"); return }
        #expect(kind == "server_error")
    }

    /// An idle session whose newest message is the user's was interrupted, not finished.
    @Test("a turn cut off by the user did not end")
    func interrupted() {
        #expect(tail([assistant("a", at: "2026-09-24T01:00:00.000Z"), user("[Request interrupted by user]", at: "2026-09-24T01:00:01.000Z")]).ending == nil)
        #expect(tail([assistant("a", at: "2026-09-24T01:00:00.000Z"), toolResult(at: "2026-09-24T01:00:01.000Z")]).ending == nil)
    }

    @Test("the recap loses its settings hint, and goes stale once the user is back")
    func recaps() {
        let fresh = tail([
            user("go", at: "2026-09-24T01:00:00.000Z"),
            assistant("ok", at: "2026-09-24T01:00:05.000Z"),
            recap("Goal is X; next step is Y.", at: "2026-09-24T02:00:00.000Z"),
        ])
        #expect(fresh.recap == "Goal is X; next step is Y.")

        let stale = tail([
            recap("Goal is X.", at: "2026-09-24T02:00:00.000Z"),
            user("next", at: "2026-09-24T02:05:00.000Z"),
            assistant("ok", at: "2026-09-24T02:05:05.000Z"),
        ])
        #expect(stale.recap == nil)
    }

    @Test("title and last prompt come from their own line types")
    func titleAndPrompt() {
        let result = tail([
            #"{"type":"ai-title","aiTitle":"Old"}"#,
            #"{"type":"last-prompt","lastPrompt":"  first  "}"#,
            #"{"type":"ai-title","aiTitle":"New title"}"#,
            #"{"type":"last-prompt","lastPrompt":"second"}"#,
        ])
        #expect(result.title == "New title")
        #expect(result.lastPrompt == "second")
    }

    @Test("subagent and meta lines do not decide how the main turn ended")
    func sidechainsIgnored() {
        let result = tail([
            assistant("main done", at: "2026-09-24T01:00:00.000Z"),
            #"{"type":"assistant","isSidechain":true,"timestamp":"2026-09-24T01:00:01.000Z","error":"server_error","isApiErrorMessage":true,"message":{"content":[]}}"#,
        ])
        guard case .completed = result.ending else { Issue.record("sidechain error leaked into the main session"); return }
    }
}
