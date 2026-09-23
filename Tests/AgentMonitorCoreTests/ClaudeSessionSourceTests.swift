import Foundation
import Testing

@testable import AgentMonitorCore

/// A verbatim `sessions/<pid>.json` captured from a real machine, including the
/// four-hour UTC/local skew between `procStart` and what `ps -o lstart=` reported
/// for the same process.
private let realSessionJSON = """
{
    "pid": 27435,
    "sessionId": "dd099179-0f6b-4986-a9f5-1a9fe5fae977",
    "cwd": "/Users/jason/Desktop/pp/agent-monitor",
    "startedAt": 1790154990896,
    "procStart": "Wed Sep 23 09:16:28 2026",
    "version": "2.1.220",
    "peerProtocol": 1,
    "kind": "interactive",
    "entrypoint": "cli",
    "name": "agent-monitor-e8",
    "nameSource": "derived",
    "status": "busy",
    "updatedAt": 1790175859515,
    "statusUpdatedAt": 1790175859515
}
"""

private func decode(_ json: String) throws -> ClaudeSessionFile {
    try JSONDecoder().decode(ClaudeSessionFile.self, from: Data(json.utf8))
}

private func decodeReal() throws -> ClaudeSessionFile { try decode(realSessionJSON) }

/// The instant `procStart` denotes: 2026-09-23 09:16:28 UTC.
private let realKernelStart = Date(timeIntervalSince1970: 1_790_154_988)

/// `claude.exe` — not `claude` — is what the kernel reports for a Homebrew/npm
/// install. See `ClaudeProcess.commandNames`.
private func inspector(
    command: String = "claude.exe",
    startTime: Date = realKernelStart
) -> (pid_t) -> ProcessInspector.Info? {
    { pid in ProcessInspector.Info(pid: pid, command: command, startTime: startTime) }
}

@Suite("claude session file")
struct ClaudeSessionFileTests {

    @Test("decodes a real session file")
    func decodesRealFile() throws {
        let file = try decodeReal()
        #expect(file.pid == 27435)
        #expect(file.sessionId == "dd099179-0f6b-4986-a9f5-1a9fe5fae977")
        #expect(file.status == "busy")
        #expect(file.name == "agent-monitor-e8")
        #expect(file.bridgeSessionId == nil)
    }

    /// The format is undocumented, so a file missing every optional field must still
    /// decode rather than taking the session down with it.
    @Test("survives a file missing every optional field")
    func decodesMinimalFile() throws {
        let file = try decode(#"{"pid": 42, "sessionId": "abc", "cwd": "/tmp"}"#)
        #expect(file.pid == 42)
        #expect(file.status == nil)
        #expect(file.procStart == nil)
    }

    @Test("converts epoch milliseconds to dates")
    func convertsTimestamps() throws {
        let file = try decodeReal()
        #expect(abs(file.stateChangedAtDate.timeIntervalSince1970 - 1_790_175_859.515) < 0.001)
    }

    /// `statusUpdatedAt` is the escalation clock; if it is absent we still need *some*
    /// origin rather than defaulting to now, which would reset on every scan and make
    /// "waiting for 20 minutes" unreachable.
    @Test("falls back when statusUpdatedAt is absent")
    func fallsBackForEscalationClock() throws {
        let file = try decode(#"{"pid": 1, "sessionId": "a", "cwd": "/tmp", "updatedAt": 1790175859515}"#)
        #expect(abs(file.stateChangedAtDate.timeIntervalSince1970 - 1_790_175_859.515) < 0.001)
    }

    @Test("detects an attached remote-control bridge")
    func detectsBridge() throws {
        let file = try decode(
            #"{"pid": 1, "sessionId": "a", "cwd": "/tmp", "bridgeSessionId": "session_01Cmdfvz"}"#)
        #expect(file.bridgeSessionId == "session_01Cmdfvz")
    }
}

@Suite("liveness")
struct ClaudeSessionLivenessTests {

    @Test("accepts a session whose pid is held by the same process")
    func acceptsLiveSession() throws {
        let file = try decodeReal()
        guard case .success(let session) = ClaudeSessionSource.makeSession(from: file, inspector: inspector())
        else { Issue.record("expected a live session"); return }

        #expect(session.pid == 27435)
        #expect(session.state == .busy)
        #expect(session.displayName == "agent-monitor-e8")
        #expect(session.agent == .claudeCode)
        #expect(session.isBridged == false)
    }

    @Test("rejects a session whose process is gone")
    func rejectsDeadProcess() throws {
        let file = try decodeReal()
        guard case .failure(let reason) = ClaudeSessionSource.makeSession(from: file, inspector: { _ in nil })
        else { Issue.record("expected rejection"); return }
        #expect(reason == .processGone)
    }

    /// A recycled pid belongs to a process that started later, so the start-time
    /// comparison is what catches it.
    @Test("rejects a pid recycled into another process")
    func rejectsRecycledPID() throws {
        let file = try decodeReal()
        guard case .failure(let reason) = ClaudeSessionSource.makeSession(
            from: file, inspector: inspector(startTime: realKernelStart.addingTimeInterval(3600)))
        else { Issue.record("expected rejection"); return }
        #expect(reason == .startTimeMismatch)
    }

    /// The whole-stack version of the timezone regression: a genuinely live session on
    /// a non-UTC machine must be accepted. If `procStart` were compared as a raw string,
    /// or parsed as local time, this session would be discarded as a ghost and the
    /// monitor would show an empty dashboard to a user with work in flight.
    @Test("a live session on a non-UTC machine is not mistaken for a ghost")
    func liveSessionSurvivesTimezoneSkew() throws {
        let file = try decodeReal()
        guard case .success = ClaudeSessionSource.makeSession(from: file, inspector: inspector())
        else { Issue.record("live session rejected — the timezone bug is back"); return }
    }

    /// The process name must NOT gate a session that has already proved its identity
    /// by start time. `claude.exe` (Homebrew/npm) and `claude` (native installer) are
    /// both real, and an install variant we have not enumerated must not blank the UI.
    @Test("an unfamiliar process name does not reject a start-time match")
    func unfamiliarNameDoesNotRejectVerifiedSession() throws {
        let file = try decodeReal()
        guard case .success = ClaudeSessionSource.makeSession(
            from: file, inspector: inspector(command: "some-future-launcher"))
        else { Issue.record("a start-time match must outrank the name check"); return }
    }

    /// With no `procStart` to compare against, the name is the only recycling guard
    /// left, so it does apply.
    @Test("falls back to the name check when procStart is absent")
    func namesGuardWhenProcStartAbsent() throws {
        let file = try decode(#"{"pid": 1, "sessionId": "a", "cwd": "/tmp", "status": "idle"}"#)

        guard case .failure(let reason) = ClaudeSessionSource.makeSession(
            from: file, inspector: inspector(command: "Safari"))
        else { Issue.record("expected rejection"); return }
        #expect(reason == .commandMismatch("Safari"))

        guard case .success = ClaudeSessionSource.makeSession(from: file, inspector: inspector())
        else { Issue.record("a known process name should pass the fallback"); return }
    }

    @Test("accepts both known process names")
    func acceptsBothKnownNames() throws {
        let file = try decode(#"{"pid": 1, "sessionId": "a", "cwd": "/tmp", "status": "idle"}"#)
        for name in ClaudeProcess.commandNames {
            guard case .success = ClaudeSessionSource.makeSession(
                from: file, inspector: inspector(command: name))
            else { Issue.record("'\(name)' should be accepted"); return }
        }
    }

    @Test("rejects a status this build does not understand")
    func rejectsUnknownStatus() throws {
        let file = try decode(#"{"pid": 1, "sessionId": "a", "cwd": "/tmp", "status": "hibernating"}"#)
        guard case .failure(let reason) = ClaudeSessionSource.makeSession(from: file, inspector: inspector())
        else { Issue.record("expected rejection"); return }
        #expect(reason == .unknownStatus("hibernating"))
    }
}

@Suite("config locator")
struct ClaudeConfigLocatorTests {

    /// Hardcoding `~/.claude` shows an empty dashboard to exactly the power users most
    /// likely to run a multi-agent monitor. See DESIGN.md §7.1 trap #1.
    @Test("prefers CLAUDE_CONFIG_DIR from the environment")
    func prefersEnvironment() {
        let locator = ClaudeConfigLocator.resolve(environment: ["CLAUDE_CONFIG_DIR": "/tmp/custom-config"])
        #expect(locator.directory.path == "/tmp/custom-config")
        #expect(locator.source == .ownEnvironment)
    }

    @Test("expands a tilde in the config dir")
    func expandsTilde() {
        let locator = ClaudeConfigLocator.resolve(environment: ["CLAUDE_CONFIG_DIR": "~/.claude-official"])
        #expect(locator.directory.path.contains("~") == false)
        #expect(locator.directory.path.hasSuffix(".claude-official"))
    }

    @Test("ignores an empty config dir")
    func ignoresEmpty() {
        let locator = ClaudeConfigLocator.resolve(environment: ["CLAUDE_CONFIG_DIR": ""])
        #expect(locator.source != .ownEnvironment)
    }

    @Test("sessions directory hangs off the config dir")
    func sessionsDirectory() {
        let locator = ClaudeConfigLocator(directory: URL(fileURLWithPath: "/tmp/cfg"), source: .defaultPath)
        #expect(locator.sessionsDirectory.path == "/tmp/cfg/sessions")
    }
}
