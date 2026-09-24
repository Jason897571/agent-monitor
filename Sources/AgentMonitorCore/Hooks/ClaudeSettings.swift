import Foundation

/// Careful, reversible edits to Claude Code's `settings.json`.
///
/// Every rule here is one of the traps in DESIGN.md §7.2:
///
/// - **Append, never replace** (#12). `hooks` merges across settings layers and other
///   tools put entries in it; we only ever add our own and only ever remove our own,
///   recognised by URL or command path.
/// - **Back up, validate, write atomically** (#13). Claude Code reads this file live and
///   writes it too. A file we cannot parse is refused, not "repaired"; the new document
///   is re-parsed before it replaces the old one, and the replacement is a rename.
/// - **Never touch an occupied `statusLine`** (#11). It is a single slot with no merge.
/// - **Detect policy** (#15). A managed `allowManagedHooksOnly` silently disables every
///   user hook; the UI says so instead of looking broken.
public struct ClaudeSettings: Sendable {

    public let url: URL
    /// Where an organisation's managed settings live on macOS.
    public let managedURL: URL

    public init(locator: ClaudeConfigLocator,
                managedURL: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")) {
        self.url = locator.directory.appendingPathComponent("settings.json")
        self.managedURL = managedURL
    }

    public enum EditError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case notAnObject
        case writeFailed(String)
        case occupied(String)

        public var description: String {
            switch self {
            case .unreadable(let why): return "settings.json 无法解析，未做任何修改：\(why)"
            case .notAnObject: return "settings.json 顶层不是一个对象，未做任何修改"
            case .writeFailed(let why): return "写入 settings.json 失败：\(why)"
            case .occupied(let owner): return "statusLine 已被 \(owner) 占用"
            }
        }
    }

    // MARK: - Hooks

    public enum HookStatus: Sendable, Equatable {
        case notInstalled
        /// All subscribed events point at us.
        case installed
        /// Some are missing — typically after a Claude Code upgrade added events, or a
        /// hand edit removed some.
        case partial(missing: [String])
        /// Installed or not, they will not run.
        case disabledByPolicy(String)
        case unreadable(String)
    }

    public func hookURL(for event: String, port: UInt16 = HookServer.defaultPort) -> String {
        "http://127.0.0.1:\(port)\(HookServer.pathPrefix)\(event)"
    }

    public func hookStatus(port: UInt16 = HookServer.defaultPort) -> HookStatus {
        if let reason = policyBlock() { return .disabledByPolicy(reason) }
        let root: [String: Any]
        do { root = try read() } catch let error as EditError { return .unreadable(error.description) } catch {
            return .unreadable(error.localizedDescription)
        }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let present = HookEvent.subscribed.filter { event in
            let groups = hooks[event] as? [[String: Any]] ?? []
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { Self.isOurs($0) }
            }
        }
        if present.isEmpty { return .notInstalled }
        let missing = HookEvent.subscribed.filter { !present.contains($0) }
        return missing.isEmpty ? .installed : .partial(missing: missing)
    }

    /// Adds our hook to every subscribed event, replacing any earlier copy of ours.
    public func installHooks(port: UInt16 = HookServer.defaultPort) throws {
        try edit { root in
            var hooks = Self.removingOurHooks(from: root["hooks"] as? [String: Any] ?? [:])
            for event in HookEvent.subscribed {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append([
                    "hooks": [[
                        "type": "http",
                        "url": hookURL(for: event, port: port),
                        // Loopback answers in microseconds or refuses instantly; anything
                        // slower means the app is wedged, and the agent must not wait on it.
                        "timeout": 2,
                    ] as [String: Any]],
                ])
                hooks[event] = groups
            }
            root["hooks"] = hooks
        }
    }

    /// Removes every hook entry that points at us, and nothing else.
    public func uninstallHooks() throws {
        try edit { root in
            guard let existing = root["hooks"] as? [String: Any] else { return }
            let cleaned = Self.removingOurHooks(from: existing)
            if cleaned.isEmpty { root["hooks"] = nil } else { root["hooks"] = cleaned }
        }
    }

    static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let url = hook["url"] as? String else { return false }
        return url.hasPrefix("http://127.0.0.1:") && url.contains(HookServer.pathPrefix)
    }

    static func removingOurHooks(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value  // not ours to interpret
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.count == entries.count { return group }
                if remaining.isEmpty { return nil }
                var copy = group
                copy["hooks"] = remaining
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    /// Why hooks would not run even if installed, if anything stops them.
    public func policyBlock() -> String? {
        if let managed = try? readObject(at: managedURL) {
            if managed["allowManagedHooksOnly"] as? Bool == true {
                return "你的组织只允许托管 hook（allowManagedHooksOnly）"
            }
            if managed["disableAllHooks"] as? Bool == true {
                return "你的组织禁用了全部 hook（disableAllHooks）"
            }
        }
        if let root = try? read(), root["disableAllHooks"] as? Bool == true {
            return "settings.json 里设置了 disableAllHooks"
        }
        return nil
    }

    // MARK: - Status line

    public enum StatusLineSlot: Sendable, Equatable {
        case empty
        case ours
        /// Someone else's command, with a short guess at whose.
        case occupied(owner: String, command: String)
    }

    public func statusLineSlot(ourCommand: String) -> StatusLineSlot {
        guard let root = try? read(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String, !command.isEmpty
        else { return .empty }
        if command.contains(ourCommand) || command.contains(StatuslineFeed.scriptDirectoryMarker) {
            return .ours
        }
        return .occupied(owner: Self.owner(of: command), command: command)
    }

    /// Fills an *empty* status line slot. Refuses an occupied one — the caller offers the
    /// user a one-line wrapper to add themselves instead.
    public func installStatusLine(command: String) throws {
        try edit { root in
            if let existing = root["statusLine"] as? [String: Any],
               let current = existing["command"] as? String, !current.isEmpty,
               !current.contains(StatuslineFeed.scriptDirectoryMarker) {
                throw EditError.occupied(Self.owner(of: current))
            }
            root["statusLine"] = ["type": "command", "command": command] as [String: Any]
        }
    }

    public func uninstallStatusLine() throws {
        try edit { root in
            guard let existing = root["statusLine"] as? [String: Any],
                  let current = existing["command"] as? String,
                  current.contains(StatuslineFeed.scriptDirectoryMarker) else { return }
            // Ours alone: remove the slot. Wrapped around someone else's command by hand:
            // leave it, since unwrapping a command we did not write is guesswork.
            if !current.contains("|") { root["statusLine"] = nil }
        }
    }

    /// A short, human name for whoever owns a status line command.
    static func owner(of command: String) -> String {
        for known in ["claude-hud", "ccusage", "ccstatusline", "claude-powerline", "starship"]
        where command.contains(known) {
            return known
        }
        let first = command.split(separator: " ").first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    // MARK: - File plumbing

    func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try readObject(at: url)
    }

    private func readObject(at url: URL) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw EditError.unreadable(error.localizedDescription) }
        if data.isEmpty { return [:] }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            throw EditError.unreadable(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else { throw EditError.notAnObject }
        return root
    }

    private func edit(_ change: (inout [String: Any]) throws -> Void) throws {
        var root = try read()
        try change(&root)

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            // Never replace a file with something we could not read back ourselves.
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EditError.writeFailed(error.localizedDescription)
        }

        // Write through a symlink, not over it: dotfile managers keep settings.json as a
        // link into a repo, and an atomic rename would silently replace the link.
        let target = url.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                let backup = target.deletingLastPathComponent()
                    .appendingPathComponent("settings.json.agent-monitor-backup")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: target, to: backup)
            }
            // `.atomic` writes a sibling temp file and renames it over the original, so
            // Claude Code can never read a half-written document.
            try data.write(to: target, options: .atomic)
        } catch {
            throw EditError.writeFailed(error.localizedDescription)
        }
    }
}
