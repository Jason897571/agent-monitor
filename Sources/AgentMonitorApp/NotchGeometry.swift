import AppKit

/// Where the docked bar sits on a given screen.
///
/// All of this is public API since macOS 12. `safeAreaInsets.top > 0` is the notch
/// test; the notch's width is what is left after the two unobscured shoulders on
/// either side of it.
struct NotchGeometry {

    let screen: NSScreen
    /// Height of the notch, or of the menu bar on a display without one.
    let height: CGFloat
    /// Width of the physical cutout, or a sensible default when there is none.
    let width: CGFloat
    let hasNotch: Bool

    init(screen: NSScreen) {
        self.screen = screen
        let inset = screen.safeAreaInsets.top
        self.hasNotch = inset > 0

        if hasNotch {
            height = inset
            if let left = screen.auxiliaryTopLeftArea?.width,
               let right = screen.auxiliaryTopRightArea?.width {
                // The shoulders do not quite meet the cutout; shipping notch apps add a
                // few points so the drawn shape overlaps rather than leaving a seam.
                width = screen.frame.width - left - right + 4
            } else {
                width = 200
            }
        } else {
            // No cutout: hang under the menu bar instead, which is the same shape in a
            // different place.
            height = screen.frame.maxY - screen.visibleFrame.maxY
            width = 200
        }
    }

    /// Frame for a bar of `size`, centred horizontally and flush to the top.
    func frame(for size: NSSize) -> NSRect {
        NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
