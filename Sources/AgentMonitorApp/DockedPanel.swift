import AgentMonitorCore
import AppKit

/// The compact bar that welds to the notch, or hangs under the menu bar on a display
/// without one.
///
/// Shares `PetPanel`'s floating behaviour — same level, same collection behaviour,
/// same refusal to take focus — because the reasons for those settings do not change
/// with the shape. What differs is position and content, which is the whole point of
/// DESIGN.md §3: one core, two shells.
@MainActor
final class DockedPanel: NSPanel {

    private let barView: DockedView

    init() {
        barView = DockedView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        super.init(
            contentRect: barView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        // The bar is chrome, not a target: nothing on it is clickable yet, so it must
        // never intercept a click meant for the menu bar behind it.
        ignoresMouseEvents = true
        contentView = barView
        // The physical cutout is pure black in every appearance; forcing dark keeps the
        // drawn shape matching it when the system is in light mode.
        appearance = NSAppearance(named: .darkAqua)
        applyFloatingBehaviour()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Without this AppKit drags a panel overlapping the menu bar back down below it —
    /// which for this window is the entire intended position.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func applyFloatingBehaviour() {
        level = .statusBar
        var behaviour: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if #available(macOS 13.0, *) {
            behaviour.insert(NSWindow.CollectionBehavior(rawValue: 1 << 18))
        }
        collectionBehavior = behaviour
    }

    func update(summary: SessionSummary, presentation: PetPresentation, on screen: NSScreen?) {
        barView.summary = summary
        barView.presentation = presentation
        reposition(on: screen)
    }

    private func reposition(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.screens.first else { return }
        let geometry = NotchGeometry(screen: screen)
        let size = barView.preferredSize(notch: geometry)
        setFrame(geometry.frame(for: size), display: true)
        barView.frame = NSRect(origin: .zero, size: size)
        barView.notchWidth = geometry.hasNotch ? geometry.width : 0
        barView.needsDisplay = true
    }
}

/// Draws the bar: a bottom-rounded black shape with state badges on either side of the
/// cutout.
@MainActor
final class DockedView: NSView {

    var summary = SessionSummary(sessions: [])
    var presentation = PetPresentation(pose: .sleeping, opacity: 1, framesPerSecond: 0)
    /// Width of the physical cutout to leave clear, or `0` on a display without one.
    var notchWidth: CGFloat = 0

    override var isOpaque: Bool { false }

    /// Wide enough for the cutout plus what is actually being shown, and no wider.
    ///
    /// Sizing to a fixed minimum instead left a slab of empty black hanging below the
    /// menu bar whenever there was little to report — which is most of the time, and
    /// exactly when the bar should be least noticeable.
    func preferredSize(notch: NotchGeometry) -> NSSize {
        let badgeWidth: CGFloat = 40
        let content = summary.badges.isEmpty
            ? 30  // just the sleep mark
            : CGFloat(summary.badges.count) * badgeWidth
        return NSSize(
            width: notch.width + content + 20,
            height: max(notch.height, 24)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        // A bottom-rounded rectangle in solid black: against the cutout it reads as the
        // notch itself growing, because the physical notch is the same colour.
        let shape = NSBezierPath()
        let radius: CGFloat = 10
        shape.move(to: NSPoint(x: bounds.minX, y: bounds.maxY))
        shape.line(to: NSPoint(x: bounds.minX, y: bounds.minY + radius))
        shape.curve(to: NSPoint(x: bounds.minX + radius, y: bounds.minY),
                    controlPoint1: NSPoint(x: bounds.minX, y: bounds.minY),
                    controlPoint2: NSPoint(x: bounds.minX, y: bounds.minY))
        shape.line(to: NSPoint(x: bounds.maxX - radius, y: bounds.minY))
        shape.curve(to: NSPoint(x: bounds.maxX, y: bounds.minY + radius),
                    controlPoint1: NSPoint(x: bounds.maxX, y: bounds.minY),
                    controlPoint2: NSPoint(x: bounds.maxX, y: bounds.minY))
        shape.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        shape.close()
        NSColor.black.setFill()
        shape.fill()

        drawBadges()
    }

    private func drawBadges() {
        let badges = summary.badges
        guard !badges.isEmpty else {
            drawSleepingIndicator()
            return
        }

        // Badges sit on the left shoulder, reading outward from the cutout.
        let slot: CGFloat = 40
        var x = bounds.midX - notchWidth / 2 - 8
        for badge in badges {
            x -= slot
            draw(state: badge.state, count: badge.count, at: NSPoint(x: x, y: bounds.midY))
        }
    }

    private func draw(state: SessionState, count: Int, at point: NSPoint) {
        let radius: CGFloat = 4
        colour(for: state).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        NSAttributedString(string: "\(count)", attributes: attributes)
            .draw(at: NSPoint(x: point.x + radius * 2 + 4, y: point.y - 7))
    }

    private func drawSleepingIndicator() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
        ]
        let text = NSAttributedString(string: "zz", attributes: attributes)
        let x = bounds.midX - notchWidth / 2 - 26
        text.draw(at: NSPoint(x: x, y: bounds.midY - 6))
    }

    private func colour(for state: SessionState) -> NSColor {
        switch state {
        case .waiting: return NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.33, alpha: 1)
        case .busy: return NSColor(calibratedRed: 0.40, green: 0.83, blue: 0.68, alpha: 1)
        case .idle: return NSColor(calibratedRed: 0.95, green: 0.83, blue: 0.52, alpha: 1)
        case .shell: return NSColor(calibratedWhite: 0.6, alpha: 1)
        }
    }
}
