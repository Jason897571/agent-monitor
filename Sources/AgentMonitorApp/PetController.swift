import AgentMonitorCore
import AppKit

/// Wires the state engine to the windows: snapshots in, poses and opacity out.
///
/// Owns both shells from DESIGN.md §3 — the free-floating pet and the docked bar —
/// over one presenter. Only the render layer differs; nothing below this class knows
/// which one is on screen.
@MainActor
final class PetController {

    enum Mode: String {
        case pet
        case docked

        var next: Mode { self == .pet ? .docked : .pet }
    }

    private let registry: SessionRegistry
    private let panel: PetPanel
    private let view: PetView
    private let docked: DockedPanel
    private var presenter: PetPresenter

    private var streamTask: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var presentationTimer: Timer?
    private var watchdog: Timer?
    private var hotkey: GlobalHotkey?
    private var isHovered = false
    private var latest: SessionRegistry.Snapshot?
    private var mode: Mode

    private static let size = NSSize(width: 132, height: 132)
    private static let modeKey = "pet.mode"

    init(registry: SessionRegistry, fadePolicy: FadePolicy = .default, mode: Mode? = nil) {
        self.registry = registry
        self.presenter = PetPresenter(fadePolicy: fadePolicy)
        self.panel = PetPanel(size: Self.size)
        self.view = PetView(frame: NSRect(origin: .zero, size: Self.size))
        self.docked = DockedPanel()
        self.mode = mode
            ?? Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "")
            ?? .pet
        panel.contentView = view
        // Click-through everywhere except the character's own silhouette. A pet that
        // eats clicks in the empty corners of its window is a pet users delete.
        panel.ignoresMouseEvents = true
    }

    // MARK: - Lifecycle

    func start() {
        restorePosition()
        refreshPowerConditions()
        applyMode()
        refreshPresentation()

        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await registry.snapshots()
            await registry.start()
            for await snapshot in stream {
                self.apply(snapshot)
            }
        }

        installMouseMonitors()
        installHotkey()
        installWatchdog()
        observeEnvironmentChanges()
    }

    func stop() {
        savePosition()
        streamTask?.cancel()
        presentationTimer?.invalidate()
        watchdog?.invalidate()
        hotkey?.unregister()
        hotkey = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        Task { await registry.stop() }
    }

    // MARK: - Mode

    func toggleMode() {
        mode = mode.next
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        applyMode()
        refreshPresentation()
    }

    private func applyMode() {
        switch mode {
        case .pet:
            docked.orderOut(nil)
            panel.orderFrontRegardless()
        case .docked:
            panel.orderOut(nil)
            docked.orderFrontRegardless()
        }
        // The hidden shell must stop costing anything; `PowerConditions` already knows
        // how to express "nothing of this is on screen".
        presenter.power.isOccluded = (mode != .pet)
    }

    // MARK: - State in

    private func apply(_ snapshot: SessionRegistry.Snapshot) {
        latest = snapshot
        presenter.observe(
            aggregate: snapshot.aggregate,
            attention: snapshot.attention.level,
            now: Date()
        )
        refreshPresentation()
    }

    /// Recomputes what the pet should look like, applies it, and schedules the next
    /// self-driven change — the fade deadline or the end of the waking animation.
    /// Nothing pending means no timer at all.
    private func refreshPresentation() {
        let now = Date()
        let presentation = presenter.presentation(now: now, isHovered: isHovered)

        switch mode {
        case .pet:
            view.presentation = presentation
            setOpacity(presentation.opacity)
        case .docked:
            docked.update(
                summary: SessionSummary(sessions: latest?.sessions ?? []),
                presentation: presentation,
                on: preferredScreen()
            )
        }

        presentationTimer?.invalidate()
        presentationTimer = nil
        guard let next = presenter.nextChange(now: now) else { return }
        let delay = max(0.05, next.timeIntervalSince(now))
        presentationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshPresentation() }
        }
    }

    private func setOpacity(_ target: Double) {
        guard abs(panel.alphaValue - CGFloat(target)) > 0.001 else { return }
        // Slow enough on the way out that it reads as settling rather than as a glitch;
        // near-instant on the way back so reaching for the pet feels direct.
        let duration = target < Double(panel.alphaValue) ? 2.0 : 0.15
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = CGFloat(target)
        }
    }

    // MARK: - Power

    /// The three free, permission-less throttles from DESIGN.md §5.
    private func refreshPowerConditions() {
        let info = ProcessInfo.processInfo
        var power = presenter.power
        power.isLowPower = info.isLowPowerModeEnabled
        power.thermal = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        // A transparent window frequently reports itself visible even when it is not —
        // AppKit's own header warns about exactly this — so occlusion is treated as a
        // hint that can only ever save work, never as ground truth.
        if mode == .pet {
            power.isOccluded = !panel.occlusionState.contains(.visible)
        }
        guard power != presenter.power else { return }
        presenter.power = power
        refreshPresentation()
    }

    // MARK: - Mouse

    /// Hover drives two things: restoring a faded pet, and deciding whether clicks
    /// land on it or pass through to whatever is underneath.
    ///
    /// Mouse-moved monitors need no Accessibility permission — only keyboard ones do —
    /// so this costs the user nothing at install time.
    private func installMouseMonitors() {
        let handler: @MainActor (NSEvent) -> Void = { [weak self] _ in
            self?.updateHover()
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            Task { @MainActor in handler(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            Task { @MainActor in handler(event) }
            return event
        }
    }

    private func updateHover() {
        guard mode == .pet else { return }
        // Keep the window grabbable for the whole of a drag; losing pointer capture
        // halfway through a gesture is the classic failure of this pattern.
        if view.isDragging { return }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let viewPoint = view.convert(windowPoint, from: nil)
        let hovering = view.bounds.contains(viewPoint) && view.bodyContains(viewPoint)

        panel.ignoresMouseEvents = !hovering
        guard hovering != isHovered else { return }
        isHovered = hovering
        refreshPresentation()
    }

    // MARK: - Hotkey

    private func installHotkey() {
        hotkey = GlobalHotkey(
            keyCode: GlobalHotkey.defaultKeyCode,
            modifiers: GlobalHotkey.defaultModifiers
        ) { [weak self] in
            self?.toggleMode()
        }
    }

    // MARK: - Staying put

    /// Level and collection behaviour are state that drifts. Every field report of an
    /// overlay quietly falling behind other windows traces back to them being reset,
    /// so re-assert on the events that cause it and keep a cheap poll as a backstop.
    private func installWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.mode == .pet, !self.panel.isFloatingCorrectly {
                    self.panel.applyFloatingBehaviour()
                }
                self.refreshPowerConditions()
            }
        }
    }

    private func observeEnvironmentChanges() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        for (notificationCenter, name) in [
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (center, NSApplication.didChangeScreenParametersNotification),
        ] {
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.panel.applyFloatingBehaviour()
                    self?.docked.applyFloatingBehaviour()
                    self?.applyMode()
                    self?.keepOnScreen()
                    self?.refreshPresentation()
                }
            }
        }

        for name in [
            NSNotification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPowerConditions() }
            }
        }

        center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPowerConditions() }
        }
    }

    /// With `isMovable = false` the system no longer rescues the window when a display
    /// disappears, so a pet parked on an unplugged monitor would be stranded offscreen.
    private func keepOnScreen() {
        let frame = panel.frame
        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        guard !isVisible else { return }
        placeAtDefaultPosition()
    }

    private func restorePosition() {
        if let origin = ScreenMemory.restore(size: Self.size) {
            panel.setFrameOrigin(origin)
        } else {
            placeAtDefaultPosition()
        }
    }

    private func savePosition() {
        ScreenMemory.save(origin: panel.frame.origin, screen: panel.screen)
    }

    private func placeAtDefaultPosition() {
        guard let screen = preferredScreen() else { return }
        let bounds = screen.visibleFrame
        let margin: CGFloat = 24
        panel.setFrameOrigin(NSPoint(
            x: bounds.maxX - Self.size.width - margin,
            y: bounds.minY + margin
        ))
    }

    /// Where a pet should appear on a multi-display desk.
    ///
    /// Explicitly **not** `NSScreen.main`: that is "the screen with the key window",
    /// and this app never has a key window — it is an accessory whose panel refuses to
    /// become key by design. Asking for `.main` here returned a secondary display and
    /// parked the pet at a negative origin on a monitor the user was not looking at.
    ///
    /// The screen under the cursor is where attention already is. `screens.first` —
    /// the display owning the menu bar — is the fallback.
    private func preferredScreen() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.screens.first
    }

    // MARK: - Diagnostics

    var diagnostics: [(String, String)] {
        panel.diagnostics + [
            ("mode", mode.rawValue),
            ("hotkey", GlobalHotkey.defaultDescription + (hotkey == nil ? " (FAILED)" : " (registered)")),
            ("pose", view.presentation.pose.rawValue),
            ("requestedFPS", "\(view.presentation.framesPerSecond)"),
            ("displayLink", view.displayLinkState),
            ("power", presenter.power.isConstrained ? "constrained: \(presenter.power)" : "unconstrained"),
        ]
    }

    /// Display-link callbacks so far — used by `--selftest` to measure the rate the
    /// system actually delivered against the rate we asked for.
    var tickCount: Int { view.tickCount }
}
