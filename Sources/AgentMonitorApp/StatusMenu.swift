import AgentMonitorCore
import AppKit

/// The menu-bar item: switch shells, the opt-in feeds, quit.
///
/// Needed the moment this runs as an app rather than from a terminal. It has no Dock icon
/// and no menu bar of its own, so without this the only way to quit a Finder-launched
/// copy was Activity Monitor. Deliberately small — DESIGN.md keeps the status item to
/// settings and quit, and never as the only way to reach the pet, because macOS 26 lets
/// users hide status items and reports them visible when they are not.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: PetController
    private let integrations: Integrations
    /// The existing status line command, when the slot is occupied — what "copy" wraps.
    private var occupiedCommand: String?

    init(controller: PetController, integrations: Integrations) {
        self.controller = controller
        self.integrations = integrations
        super.init()

        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Monitor")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt on every open: hook and status line state live in a file other programs
    /// edit, so anything cached here would drift.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: controller.currentMode == .pet ? "切换到刘海模式" : "切换到桌宠模式",
            action: #selector(toggleMode), keyEquivalent: "p"
        )
        // Shown for discoverability only; the real binding is the global Carbon hotkey.
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())
        addHookItems(to: menu)

        menu.addItem(.separator())
        addQuotaItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(action("自定义 agent 清单…", #selector(openManifests)))

        menu.addItem(.separator())
        menu.addItem(action("退出 Agent Monitor", #selector(quit), key: "q"))
    }

    private func addHookItems(to menu: NSMenu) {
        menu.addItem(label(integrations.hookSummary))
        switch integrations.hookStatus {
        case .notInstalled:
            menu.addItem(action("安装 hook（显示压缩、子 agent、当前工具）…", #selector(installHooks)))
        case .installed:
            menu.addItem(action("移除 hook", #selector(uninstallHooks)))
        case .partial:
            menu.addItem(action("重新安装 hook…", #selector(installHooks)))
            menu.addItem(action("移除 hook", #selector(uninstallHooks)))
        case .disabledByPolicy, .unreadable:
            break
        }
    }

    private func addQuotaItems(to menu: NSMenu) {
        occupiedCommand = nil
        switch integrations.statusLineSlot {
        case .empty:
            menu.addItem(label("额度显示：未启用"))
            menu.addItem(action("启用额度和上下文显示…", #selector(enableQuota)))
        case .ours:
            menu.addItem(label("额度显示：已启用"))
            menu.addItem(action("关闭额度显示", #selector(disableQuota)))
        case .occupied(let owner, let command):
            occupiedCommand = command
            // Never touch an occupied slot. Say whose it is and hand over the one-liner.
            menu.addItem(label("额度显示不可用：statusLine 已被 \(owner) 占用"))
            menu.addItem(action("复制接入命令（保留 \(owner)）", #selector(copyQuotaCommand)))
        }
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleMode() { controller.toggleMode() }
    @objc private func installHooks() { integrations.installHooks() }
    @objc private func uninstallHooks() { integrations.uninstallHooks() }
    @objc private func enableQuota() { integrations.enableQuota() }
    @objc private func disableQuota() { integrations.disableQuota() }
    @objc private func openManifests() { integrations.openManifestFolder() }

    @objc private func copyQuotaCommand() {
        guard let occupiedCommand else { return }
        integrations.copyQuotaCommand(for: occupiedCommand)
    }

    @objc private func quit() {
        controller.stop()
        NSApp.terminate(nil)
    }
}
