import AppKit

/// The menu-bar item: switch shells, quit.
///
/// Needed the moment this runs as an app rather than from a terminal. It has no Dock icon
/// and no menu bar of its own, so without this the only way to quit a Finder-launched
/// copy was Activity Monitor. Deliberately minimal — DESIGN.md keeps the status item to
/// settings and quit, and never as the only way to reach the pet, because macOS 26 lets
/// users hide status items and reports them visible when they are not.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: PetController
    private let toggleItem = NSMenuItem()

    init(controller: PetController) {
        self.controller = controller
        super.init()

        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Monitor")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.target = self
        toggleItem.action = #selector(toggleMode)
        // Shown for discoverability only; the real binding is the global Carbon hotkey.
        toggleItem.keyEquivalent = "p"
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Agent Monitor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = controller.currentMode == .pet ? "切换到刘海模式" : "切换到桌宠模式"
    }

    @objc private func toggleMode() { controller.toggleMode() }

    @objc private func quit() {
        controller.stop()
        NSApp.terminate(nil)
    }
}
