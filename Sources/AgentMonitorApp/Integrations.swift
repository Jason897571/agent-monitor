import AgentMonitorCore
import AppKit

/// The opt-in feeds: Claude Code hooks and the statusline copy.
///
/// Both write to the user's `settings.json`, so both are strictly opt-in, confirmed with
/// a dialog that says exactly what will change, and removable from the same menu. The
/// app works without either — they only sharpen what it already shows.
@MainActor
final class Integrations {

    let locator: ClaudeConfigLocator
    let settings: ClaudeSettings
    let statusline = StatuslineFeed()
    let hookStore = HookEventStore()
    private(set) var server: HookServer?

    init(locator: ClaudeConfigLocator) {
        self.locator = locator
        self.settings = ClaudeSettings(locator: locator)
    }

    /// Listens for hooks whenever they are installed. Listening costs one idle socket;
    /// not listening while they are installed turns every hook into an error line in the
    /// user's sessions, so the server runs whenever there is any chance of events.
    func startServer(onEvent: @escaping @Sendable (HookEvent) -> Void) {
        guard server == nil else { return }
        let store = hookStore
        let server = HookServer { event in
            store.apply(event)
            onEvent(event)
        }
        server.start()
        self.server = server
    }

    // MARK: - Hooks

    var hookStatus: ClaudeSettings.HookStatus { settings.hookStatus() }

    /// One line for the menu.
    var hookSummary: String {
        switch hookStatus {
        case .notInstalled: return "Claude hook：未安装（可选）"
        case .installed:
            if let last = hookStore.lastEventAt {
                return "Claude hook：已连接 · \(Self.ago(last))收到事件"
            }
            if case .failed(let why) = server?.state { return "Claude hook：已安装，但端口监听失败（\(why)）" }
            return "Claude hook：已安装，等待事件"
        case .partial(let missing): return "Claude hook：缺 \(missing.count) 个事件，建议重新安装"
        case .disabledByPolicy(let reason): return "Claude hook 不可用：\(reason)"
        case .unreadable(let why): return "Claude hook：\(why)"
        }
    }

    func installHooks() {
        let confirmed = confirm(
            title: "安装 Claude Code hook？",
            message: """
            会在 \(settings.url.path) 里追加 \(HookEvent.subscribed.count) 条 http hook，指向本机 127.0.0.1:\(HookServer.defaultPort)。只追加，不改动你已有的内容；修改前会备份到同目录的 settings.json.agent-monitor-backup。

            装上之后能多看到：正在压缩上下文、同时开了几个子 agent、当前在跑哪个工具。已经在运行的会话不用重启，下一次调用工具时就会生效。

            注意：Agent Monitor 没在运行时，这些 hook 会连不上。Claude 照常工作，只是每次触发会记一条不影响运行的 hook 错误。不想要了随时可以从这个菜单移除。
            """,
            action: "安装"
        )
        guard confirmed else { return }
        perform { try self.settings.installHooks() }
    }

    func uninstallHooks() {
        perform { try self.settings.uninstallHooks() }
    }

    // MARK: - Status line

    var statusLineSlot: ClaudeSettings.StatusLineSlot {
        settings.statusLineSlot(ourCommand: StatuslineFeed.quoted(statusline.statuslineScript))
    }

    func enableQuota() {
        let confirmed = confirm(
            title: "启用额度和上下文显示？",
            message: """
            你的 statusLine 目前是空的。会在 settings.json 里把它设成 Agent Monitor 的一个小脚本：每次 Claude 刷新状态栏时，脚本把 Claude 自己提供的额度和上下文数字存一份给宠物用，同时在状态栏显示「模型 · 上下文 · 5h 额度」。

            不读钥匙串，不调用任何接口，用的全是 Claude Code 本来就交给状态栏的数据。修改前会备份。
            """,
            action: "启用"
        )
        guard confirmed else { return }
        perform {
            try self.statusline.installScripts()
            try self.settings.installStatusLine(command: StatuslineFeed.quoted(self.statusline.statuslineScript))
        }
    }

    func disableQuota() {
        perform { try self.settings.uninstallStatusLine() }
    }

    /// For an occupied slot: we never edit someone else's status line. Instead the user
    /// gets the exact command to paste — their own, with our tee in front.
    func copyQuotaCommand(for existing: String) {
        perform {
            try self.statusline.installScripts()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(self.statusline.wrapped(existing), forType: .string)
        }
        inform(
            title: "接入命令已复制",
            message: """
            把 settings.json 里 statusLine.command 的值换成剪贴板里的内容即可。它只是在你原来的命令前面加了一段：先存一份状态栏数据，再原样交给你原来的命令，所以你的状态栏显示不会有任何变化。
            """
        )
    }

    // MARK: - Manifests

    func openManifestFolder() {
        let folder = AgentManifest.userDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Dialogs

    private func confirm(title: String, message: String, action: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            inform(title: "没有完成", message: "\(error)")
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}
