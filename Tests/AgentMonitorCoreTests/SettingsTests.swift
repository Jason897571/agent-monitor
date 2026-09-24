import Foundation
import Testing

@testable import AgentMonitorCore

/// A throwaway config directory with a settings.json in it.
private struct SettingsSandbox {
    let root: URL
    var url: URL { root.appendingPathComponent("settings.json") }
    var settings: ClaudeSettings {
        ClaudeSettings(locator: ClaudeConfigLocator(directory: root, source: .defaultPath),
                       managedURL: root.appendingPathComponent("managed-settings.json"))
    }

    init(_ json: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-monitor-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let json { try json.write(to: url, atomically: true, encoding: .utf8) }
    }

    func object() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("settings.json edits")
struct SettingsTests {

    /// DESIGN.md §7.2 #12: hooks merge across layers and other tools own entries in them.
    @Test("installing appends ours and leaves everything else exactly alone")
    func installPreservesForeign() throws {
        let sandbox = try SettingsSandbox("""
        {"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]},
         "statusLine":{"type":"command","command":"my-line"}}
        """)
        defer { sandbox.cleanUp() }

        try sandbox.settings.installHooks(port: 47291)
        #expect(sandbox.settings.hookStatus(port: 47291) == .installed)

        let root = try sandbox.object()
        #expect(root["theme"] as? String == "dark")
        #expect((root["statusLine"] as? [String: Any])?["command"] as? String == "my-line")
        let stop = (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)
        #expect(((stop?.first?["hooks"] as? [[String: Any]])?.first?["command"]) as? String == "say done")
        let ours = (stop?.last?["hooks"] as? [[String: Any]])?.first
        #expect(ours?["type"] as? String == "http")
        #expect(ours?["url"] as? String == "http://127.0.0.1:47291/agent-monitor/v1/Stop")
        #expect(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("settings.json.agent-monitor-backup").path))
    }

    @Test("installing twice does not duplicate, and uninstalling restores the original shape")
    func idempotentAndReversible() throws {
        let sandbox = try SettingsSandbox("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
        """)
        defer { sandbox.cleanUp() }

        try sandbox.settings.installHooks()
        try sandbox.settings.installHooks()
        let stop = (try sandbox.object()["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)

        try sandbox.settings.uninstallHooks()
        let hooks = try sandbox.object()["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["Stop"])
        #expect((hooks?["Stop"] as? [[String: Any]])?.count == 1)
        #expect(sandbox.settings.hookStatus() == .notInstalled)
    }

    @Test("uninstalling from a file that had no hooks leaves no empty hooks key behind")
    func uninstallCleansUp() throws {
        let sandbox = try SettingsSandbox(#"{"theme":"dark"}"#)
        defer { sandbox.cleanUp() }
        try sandbox.settings.installHooks()
        try sandbox.settings.uninstallHooks()
        let root = try sandbox.object()
        #expect(root["hooks"] == nil)
        #expect(root["theme"] as? String == "dark")
    }

    /// DESIGN.md §7.2 #13: a file we cannot parse is refused, never "repaired".
    @Test("an unparsable settings.json is refused and left byte-for-byte intact")
    func refusesUnreadable() throws {
        let broken = #"{"theme": "dark",, }"#
        let sandbox = try SettingsSandbox(broken)
        defer { sandbox.cleanUp() }
        #expect(throws: ClaudeSettings.EditError.self) { try sandbox.settings.installHooks() }
        #expect(try String(contentsOf: sandbox.url, encoding: .utf8) == broken)
    }

    @Test("a missing settings.json is created")
    func createsMissing() throws {
        let sandbox = try SettingsSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.settings.installHooks()
        #expect(sandbox.settings.hookStatus() == .installed)
    }

    /// Dotfile managers keep settings.json as a symlink into a repo.
    @Test("writes through a symlink instead of replacing it")
    func keepsSymlink() throws {
        let sandbox = try SettingsSandbox()
        defer { sandbox.cleanUp() }
        let real = sandbox.root.appendingPathComponent("dotfiles-settings.json")
        try #"{"theme":"dark"}"#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sandbox.url, withDestinationURL: real)

        try sandbox.settings.installHooks()
        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any]
        #expect(written?["hooks"] != nil)
    }

    /// DESIGN.md §7.2 #15.
    @Test("an organisation policy that disables hooks is reported, not hidden")
    func detectsPolicy() throws {
        let sandbox = try SettingsSandbox("{}")
        defer { sandbox.cleanUp() }
        try #"{"allowManagedHooksOnly": true}"#.write(
            to: sandbox.root.appendingPathComponent("managed-settings.json"), atomically: true, encoding: .utf8)
        guard case .disabledByPolicy = sandbox.settings.hookStatus() else {
            Issue.record("policy not detected"); return
        }
    }

    @Test("a hook set missing events is reported as partial")
    func partial() throws {
        let sandbox = try SettingsSandbox("""
        {"hooks":{"Stop":[{"hooks":[{"type":"http","url":"http://127.0.0.1:47291/agent-monitor/v1/Stop"}]}]}}
        """)
        defer { sandbox.cleanUp() }
        guard case .partial(let missing) = sandbox.settings.hookStatus() else { Issue.record("not partial"); return }
        #expect(missing.count == HookEvent.subscribed.count - 1)
    }

    /// DESIGN.md §7.2 #11: the status line is a single slot. An occupied one is never
    /// touched — not even to "helpfully" wrap it.
    @Test("an occupied status line is reported with its owner and never overwritten")
    func occupiedStatusLine() throws {
        let command = #"bash -c 'plugin_dir=$(ls -d "$HOME"/.claude/plugins/cache/*/claude-hud/*/); exec bun "${plugin_dir}src/index.ts"'"#
        let sandbox = try SettingsSandbox("""
        {"statusLine":{"type":"command","command":\(String(data: try JSONEncoder().encode(command), encoding: .utf8)!)}}
        """)
        defer { sandbox.cleanUp() }
        let slot = sandbox.settings.statusLineSlot(ourCommand: "'/x/AgentMonitor/bin/statusline'")
        #expect(slot == .occupied(owner: "claude-hud", command: command))
        #expect(throws: ClaudeSettings.EditError.self) {
            try sandbox.settings.installStatusLine(command: "'/x/AgentMonitor/bin/statusline'")
        }
        let after = (try sandbox.object()["statusLine"] as? [String: Any])?["command"] as? String
        #expect(after == command)
    }

    @Test("an empty status line is filled, recognised as ours, and removable")
    func emptyStatusLine() throws {
        let sandbox = try SettingsSandbox("{}")
        defer { sandbox.cleanUp() }
        let ours = "'/Users/x/Library/Application Support/AgentMonitor/bin/statusline'"
        #expect(sandbox.settings.statusLineSlot(ourCommand: ours) == .empty)
        try sandbox.settings.installStatusLine(command: ours)
        #expect(sandbox.settings.statusLineSlot(ourCommand: ours) == .ours)
        try sandbox.settings.uninstallStatusLine()
        #expect(sandbox.settings.statusLineSlot(ourCommand: ours) == .empty)
    }
}

@Suite("statusline feed")
struct StatuslineFeedTests {

    private func support() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-monitor-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let sample = #"""
    {"session_id":"abc-123","model":{"id":"claude-x","display_name":"Opus"},
     "context_window":{"context_window_size":200000,"used_percentage":93.5,"remaining_percentage":6.5},
     "rate_limits":{"five_hour":{"used_percentage":91,"resets_at":1790300000},
                    "seven_day":{"used_percentage":40,"resets_at":1790900000}}}
    """#

    @Test("reads context use and both quota windows from Claude Code's statusline input")
    func parses() throws {
        let parsed = try #require(StatuslineFeed.parse(Data(sample.utf8), sampledAt: Date()))
        #expect(parsed.contextUsedPercent == 93.5)
        #expect(parsed.contextWindow == 200_000)
        #expect(parsed.quota.map(\.label) == ["5h", "7d"])
        #expect(parsed.quota.first?.usedPercent == 91)
        #expect(parsed.quota.first?.resetsAt == Date(timeIntervalSince1970: 1_790_300_000))
    }

    /// The scripts run inside the user's status line on every refresh; they must pass the
    /// input through byte-for-byte and never print anything else.
    @Test("the tee script saves a copy and passes input through untouched")
    func teeScript() throws {
        let root = try support()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = StatuslineFeed(supportDirectory: root)
        try feed.installScripts()

        let output = try run(feed.teeScript, input: sample)
        #expect(output == sample.trimmingCharacters(in: .newlines))
        let saved = feed.sample(for: "abc-123")
        #expect(saved?.contextUsedPercent == 93.5)
        #expect(feed.latestQuota()?.windows.count == 2)
    }

    @Test("our own status line prints a short summary")
    func ownScript() throws {
        let root = try support()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = StatuslineFeed(supportDirectory: root)
        try feed.installScripts()
        let output = try run(feed.statuslineScript, input: sample)
        #expect(output == "Opus · 上下文 93% · 5h 额度 91%")
        #expect(feed.sample(for: "abc-123") != nil)
    }

    @Test("the wrapper puts our tee in front of the existing command")
    func wrapper() {
        let feed = StatuslineFeed(supportDirectory: URL(fileURLWithPath: "/Users/x/Library/Application Support/AgentMonitor"))
        #expect(feed.wrapped("npx ccusage statusline") ==
                "'/Users/x/Library/Application Support/AgentMonitor/bin/statusline-tee' | npx ccusage statusline")
    }

    private func run(_ script: URL, input: String) throws -> String {
        let process = Process()
        process.executableURL = script
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
