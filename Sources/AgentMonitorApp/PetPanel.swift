import AppKit

/// The floating window the character lives in.
///
/// Every setting here was chosen against measurements rather than folklore, because
/// most of the advice online for this exact window is wrong:
///
/// **Level 25, not 1000.** Three panels at levels 3, 25 and 1000 were composited over
/// another app's native full-screen window simultaneously — all three floated above it,
/// so `.screenSaver` buys nothing. What it *does* buy is painting over context menus
/// (101), the menu bar (24), Control Center (25) and drag images (500).
///
/// **No `.fullScreenAuxiliary`.** It contributes exactly nothing to floating over
/// *other* apps: a panel carrying it alone vanished from the on-screen window list
/// entirely. AppKit's own header says it lets a window show with *the* full-screen
/// window, meaning your own app's. `.canJoinAllSpaces` is the flag doing the work.
///
/// **Sized to the character.** macOS 26.3 RC regressed per-pixel hit testing so a
/// transparent window swallows clicks across its whole frame. Keeping the window at
/// the character's own size means that bug costs a small dead zone rather than the
/// entire display.
///
/// See DESIGN.md §4.3.
@MainActor
final class PetPanel: NSPanel {

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        // Server-side dragging is disabled so we can implement snapping ourselves.
        // The cost, per AppKit's header, is that the system will no longer reposition
        // the window on a display reconfiguration — we own that now.
        isMovable = false
        // A pet must never be the reason a keystroke went missing.
        ignoresMouseEvents = false
        applyFloatingBehaviour()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit otherwise drags a panel overlapping the menu bar back down below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Level and collection behaviour are state to be **re-asserted**, not set once.
    ///
    /// Every field report of an overlay silently dropping out of the foreground traces
    /// back to the native window being recreated or its behaviour overwritten. Even in
    /// pure AppKit it is worth reapplying on space changes, display changes and wake.
    func applyFloatingBehaviour() {
        level = .statusBar

        var behaviour: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .stationary,   // unaffected by Exposé
            .ignoresCycle, // never appears in Cmd-Tab
        ]
        if #available(macOS 13.0, *) {
            // .canJoinAllApplications — Apple's own flag for system overlays, and
            // mutually exclusive with .primary/.auxiliary.
            behaviour.insert(NSWindow.CollectionBehavior(rawValue: 1 << 18))
        }
        collectionBehavior = behaviour

        orderFrontRegardless()
    }

    /// True when the panel is where it is supposed to be. Cheap enough to poll as a
    /// watchdog, and the only honest way to know the flags still hold.
    var isFloatingCorrectly: Bool {
        isOnActiveSpace
            && level == .statusBar
            && collectionBehavior.contains(.canJoinAllSpaces)
    }

    /// Human-readable state, for `--selftest`.
    var diagnostics: [(String, String)] {
        [
            ("level", "\(level.rawValue) (expected \(NSWindow.Level.statusBar.rawValue))"),
            ("collectionBehavior", "0x\(String(collectionBehavior.rawValue, radix: 16))"),
            ("canJoinAllSpaces", "\(collectionBehavior.contains(.canJoinAllSpaces))"),
            ("fullScreenAuxiliary", "\(collectionBehavior.contains(.fullScreenAuxiliary)) (expected false)"),
            ("canJoinAllApplications", "\(collectionBehavior.rawValue & (1 << 18) != 0)"),
            ("isOpaque", "\(isOpaque)"),
            ("hasShadow", "\(hasShadow)"),
            ("hidesOnDeactivate", "\(hidesOnDeactivate) (must be false)"),
            ("canBecomeKey", "\(canBecomeKey)"),
            ("isOnActiveSpace", "\(isOnActiveSpace)"),
            ("alphaValue", String(format: "%.2f", alphaValue)),
            ("frame", "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"),
        ]
    }
}
