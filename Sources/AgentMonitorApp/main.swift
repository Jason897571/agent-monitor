import AgentMonitorCore
import AppKit

// The pet.
//
//   swift run agent-monitor                     run it
//   swift run agent-monitor --selftest [secs]   run it, dump window state, then exit
//
// `--selftest` exists because the settings that make an overlay behave are invisible
// from the outside and have a history of silently not taking. Printing what the window
// server actually believes is the only honest check.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?
    private var statusMenu: StatusMenu?
    private var integrations: Integrations?
    private let selfTestDuration: TimeInterval?
    private let fadePolicy: FadePolicy?
    private let startMode: PetController.Mode?

    init(selfTestDuration: TimeInterval?, fadePolicy: FadePolicy?, startMode: PetController.Mode?) {
        self.selfTestDuration = selfTestDuration
        self.fadePolicy = fadePolicy
        self.startMode = startMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar, never steals focus. Set at runtime so the app
        // behaves correctly straight out of `swift run`, before there is a bundle with
        // an LSUIElement key in it.
        NSApp.setActivationPolicy(.accessory)

        if let index = arguments.firstIndex(of: "--preview-skin"), index + 2 < arguments.count {
            let ok = previewSkin(id: arguments[index + 1], to: URL(fileURLWithPath: arguments[index + 2]))
            exit(ok ? 0 : 1)
        }

        if arguments.contains("--jump-test") {
            Task { @MainActor in await runJumpTest(); NSApp.terminate(nil) }
            return
        }

        let locator = ClaudeConfigLocator.resolve()
        let integrations = Integrations(locator: locator)
        let registry = makeRegistry(locator: locator, integrations: integrations)
        integrations.startServer { _ in
            Task { await registry.invalidate(.claudeCode) }
        }
        let controller = PetController(registry: registry, fadePolicy: fadePolicy, mode: startMode)
        if let startSkin { controller.setSkin(id: startSkin) }
        controller.start()
        self.controller = controller
        self.integrations = integrations
        statusMenu = StatusMenu(controller: controller, integrations: integrations,
                                settings: SettingsWindowController(controller: controller, integrations: integrations))
        if let statusMenu {
            controller.contextMenuProvider = { [weak statusMenu] in statusMenu?.contextMenu() ?? NSMenu() }
        }
        if arguments.contains("--settings") { statusMenu?.openSettings() }
        if showsCard {
            controller.pinsCard = true
            Task { @MainActor in
                // Wait for the first snapshot so the card has something to show.
                try? await Task.sleep(for: .seconds(1.5))
                controller.showCard()
            }
        }

        guard let selfTestDuration else { return }
        print("config dir : \(locator.directory.path)")
        Task { @MainActor in
            // Let the window server settle before asking it what it thinks.
            try? await Task.sleep(for: .seconds(showsCard ? 2.5 : 1))
            report(controller)

            // Measure over a window that excludes launch.
            //
            // CPU is read with `getrusage` rather than sampled with `ps`: `ps -o time=`
            // resolves to 10 ms, which at these levels is the same order as the whole
            // signal, and picking the process externally is fragile enough that two
            // consecutive runs produced 0.8% and 0.0% for the same state. A process
            // asking the kernel about itself has neither problem.
            let sample = max(2.0, min(20.0, selfTestDuration - 2))
            let startCPU = processCPUTime()
            let startTicks = controller.tickCount
            let startWall = Date()
            try? await Task.sleep(for: .seconds(sample))
            let elapsed = Date().timeIntervalSince(startWall)
            let usedCPU = processCPUTime() - startCPU
            let delivered = Double(controller.tickCount - startTicks) / elapsed

            print("  \("measured fps".padding(toLength: 24, withPad: " ", startingAt: 0))" +
                  String(format: "%.1f", delivered))
            print("  \("cpu".padding(toLength: 24, withPad: " ", startingAt: 0))" +
                  String(format: "%.3f%% of one core (%.0f ms over %.0f s)",
                         usedCPU / elapsed * 100, usedCPU * 1000, elapsed))
            print("  \("resident memory".padding(toLength: 24, withPad: " ", startingAt: 0))" +
                  String(format: "%.1f MB", residentMemoryMB()))
            print("")

            try? await Task.sleep(for: .seconds(max(0, selfTestDuration - 1 - sample)))
            controller.stop()
            NSApp.terminate(nil)
        }
    }

    /// Claude Code, plus every agent described by a manifest.
    private func makeRegistry(locator: ClaudeConfigLocator, integrations: Integrations) -> SessionRegistry {
        let claude = ClaudeProvider(
            source: ClaudeSessionSource(locator: locator),
            hooks: integrations.hookStore,
            statusline: integrations.statusline
        )
        let manifests = AgentManifest.loadAll()
        for problem in manifests.problems { print("manifest: \(problem)") }
        return SessionRegistry(providers: [claude] + manifests.manifests.map { ManifestProvider(manifest: $0) })
    }

    private func report(_ controller: PetController) {
        print("")
        print("WINDOW STATE")
        print(String(repeating: "-", count: 62))
        for (key, value) in controller.diagnostics {
            print("  \(key.padding(toLength: 24, withPad: " ", startingAt: 0))\(value)")
        }
        print("")
        print("  \("screens".padding(toLength: 24, withPad: " ", startingAt: 0))\(NSScreen.screens.count)")
        for screen in NSScreen.screens {
            let notch = screen.safeAreaInsets.top > 0 ? "notch \(Int(screen.safeAreaInsets.top))pt" : "no notch"
            let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
            print("  \("".padding(toLength: 24, withPad: " ", startingAt: 0))\(screen.localizedName): \(size), \(notch)")
        }
        print("")
    }
}

/// Total CPU seconds this process has consumed, user plus system, at microsecond
/// resolution.
func processCPUTime() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// Physical footprint, the number Activity Monitor shows under "Memory".
func residentMemoryMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.phys_footprint) / 1_048_576
}

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> Double? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return Double(arguments[index + 1])
}

let selfTestDuration: TimeInterval? = arguments.contains("--selftest")
    ? (value(after: "--selftest") ?? 6)
    : nil

// Overrides the fade preference for one run — a ten-minute default is untestable by hand.
let fadePolicy: FadePolicy? = {
    if arguments.contains("--no-fade") { return .never }
    if let delay = value(after: "--fade-after") { return FadePolicy(delay: delay) }
    return nil
}()

// Which shell to start in. Normally remembered from last run and toggled with the
// hotkey; the flag exists so either can be exercised directly.
let startMode: PetController.Mode? = {
    guard let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count else { return nil }
    return PetController.Mode(rawValue: arguments[index + 1])
}()

// Picks a skin by folder name (and remembers it, like the menu does).
let startSkin: String? = {
    guard let index = arguments.firstIndex(of: "--skin"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}()

// Opens the detail card without hovering — for previewing or screenshotting it.
let showsCard = arguments.contains("--show-card")

setvbuf(stdout, nil, _IOLBF, 0)

let application = NSApplication.shared
let delegate = AppDelegate(selfTestDuration: selfTestDuration, fadePolicy: fadePolicy, startMode: startMode)
application.delegate = delegate
application.run()

/// Diagnoses click-to-jump without a mouse: resolves every live session's host app,
/// then tries each activation route on one of them and reports which actually moved the
/// frontmost app. Activation on macOS 14+ is cooperative and easy to get silently
/// refused, so this is measured rather than assumed.
@MainActor
func runJumpTest() async {
    let registry = SessionRegistry(providers: [ClaudeProvider(source: ClaudeSessionSource(locator: ClaudeConfigLocator.resolve()))]
        + AgentManifest.loadAll().manifests.map { ManifestProvider(manifest: $0) })
    let sessions = await registry.refresh().sessions
    print("HOST APPS")
    for session in sessions {
        let host = HostApp.find(for: session.pid)
        let name = host.map { "\($0.app.localizedName ?? "?") [\($0.app.bundleIdentifier ?? "?")] via \($0.source.rawValue)" } ?? "NOT FOUND"
        print("  \(String(session.pid).padding(toLength: 7, withPad: " ", startingAt: 0)) \(session.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)) → \(name)")
    }

    let front = { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
    guard let target = sessions.compactMap({ s in HostApp.find(for: s.pid).map { (s, $0.app) } })
            .first(where: { $0.1 != NSWorkspace.shared.frontmostApplication }) else {
        print("\nno session hosted by a non-frontmost app to test activation on")
        return
    }
    let app = target.1
    print("\nACTIVATION → \(app.localizedName ?? "?")   (frontmost before: \(front()))")

    app.activate()
    try? await Task.sleep(for: .milliseconds(400))
    print("  plain activate()                 frontmost: \(front())")

    NSApp.activate()
    NSApp.yieldActivation(to: app)
    app.activate()
    try? await Task.sleep(for: .milliseconds(400))
    print("  self-activate + yield + activate frontmost: \(front())")

    if let url = app.bundleURL {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try? await Task.sleep(for: .milliseconds(400))
        print("  NSWorkspace.openApplication      frontmost: \(front())")
    }

    // End to end, through the function the card actually calls: jump to a session hosted
    // by whichever app is *not* frontmost now.
    guard let other = sessions.first(where: { HostApp.find(for: $0.pid)?.app != NSWorkspace.shared.frontmostApplication }),
          let otherApp = HostApp.find(for: other.pid)?.app else { return }
    print("\nHostApp.activate(\(other.displayName)) → expecting \(otherApp.localizedName ?? "?")")
    HostApp.activate(for: other)
    try? await Task.sleep(for: .milliseconds(800))
    print("  frontmost: \(front())  \(NSWorkspace.shared.frontmostApplication == otherApp ? "✓" : "✗")")
}


/// Renders every pose of a skin — three frames each, with the clickable area tinted — into
/// one PNG. For checking a skin without watching the pet cycle through ten states:
///
///   agent-monitor --preview-skin <folder> out.png
@MainActor
func previewSkin(id: String, to output: URL) -> Bool {
    guard let skin = SkinLibrary.load(id: id) else {
        print("no skin '\(id)' in \(SkinLibrary.directory.path) (missing, or skin.json unreadable)")
        return false
    }
    let cell: CGFloat = 132, label: CGFloat = 18
    let poses = PetPose.allCases
    let size = NSSize(width: cell * 4, height: (cell + label) * CGFloat(poses.count))
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (row, pose) in poses.enumerated() {
        let y = size.height - CGFloat(row + 1) * (cell + label)
        let resolved = skin.resolve(pose)
        let caption = resolved == pose ? pose.rawValue : "\(pose.rawValue) → \(resolved?.rawValue ?? "none")"
        guard let animation = skin.animation(for: pose, pixels: 264) else { continue }
        caption.appending(String(format: "  %d frames, %.1fs", animation.frames.count, animation.duration))
            .draw(at: NSPoint(x: 4, y: y + cell + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        for (column, fraction) in [0.0, 0.33, 0.66].enumerated() {
            let frame = animation.frame(at: animation.duration * fraction)
            let fit = min(cell / CGFloat(frame.width), cell / CGFloat(frame.height))
            let drawn = NSSize(width: CGFloat(frame.width) * fit, height: CGFloat(frame.height) * fit)
            let rect = NSRect(x: CGFloat(column) * cell + (cell - drawn.width) / 2, y: y + (cell - drawn.height) / 2,
                              width: drawn.width, height: drawn.height)
            NSImage(cgImage: frame, size: drawn).draw(in: rect)
        }
        // Fourth column: the hit mask, as the pet will use it.
        let origin = NSPoint(x: cell * 3, y: y)
        NSColor(calibratedRed: 0.2, green: 0.6, blue: 1, alpha: 0.55).setFill()
        let first = animation.frames[0]
        let fit = min(cell / CGFloat(first.width), cell / CGFloat(first.height))
        let drawn = NSSize(width: CGFloat(first.width) * fit, height: CGFloat(first.height) * fit)
        let inset = NSPoint(x: (cell - drawn.width) / 2, y: (cell - drawn.height) / 2)
        for gy in stride(from: 0, to: drawn.height, by: 3) {
            for gx in stride(from: 0, to: drawn.width, by: 3)
            where animation.mask.contains(CGPoint(x: gx / drawn.width, y: gy / drawn.height)) {
                NSRect(x: origin.x + inset.x + gx, y: origin.y + inset.y + gy, width: 3, height: 3).fill()
            }
        }
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: output) } catch { print(error); return false }
    print("wrote \(output.path)")
    return true
}
