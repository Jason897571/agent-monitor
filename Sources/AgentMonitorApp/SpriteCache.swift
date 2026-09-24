import AgentMonitorCore
import AppKit

/// Pre-renders a pose's animation cycle into images, once.
///
/// Drawing the character through Core Graphics on every frame was measured at ~1.5 ms
/// of CPU per frame — 3.55% of a core at 24 fps for a 132pt view, against a budget of
/// 1%. Cost scaled linearly with frame rate, which is the signature of per-frame
/// drawing rather than fixed overhead.
///
/// So frames are rendered once and animation becomes a `layer.contents` assignment:
/// a pointer swap the render server composites, with no main-thread drawing at all.
/// This is also the seam a real sprite atlas slots into unchanged — the animation path
/// stops caring where the images came from.
@MainActor
final class SpriteCache {

    /// Frames per animation cycle.
    ///
    /// The cycle is 2.6 s of slow breathing, so 16 steps is already finer than the eye
    /// resolves at this size, and it bounds memory: at 132pt on a 2× display each frame
    /// is ~280 KB, so one cached pose costs ~4.5 MB. Only the active pose is held.
    static let frameCount = 16

    private let renderer: CharacterRenderer
    private var pose: PetPose?
    private var size: NSSize = .zero
    private var scale: CGFloat = 0
    private var frames: [CGImage] = []

    init(renderer: CharacterRenderer) {
        self.renderer = renderer
    }

    /// The image for `phase`, rendering the pose's cycle first if needed.
    func image(pose: PetPose, phase: Double, size: NSSize, scale: CGFloat) -> CGImage? {
        rebuildIfNeeded(pose: pose, size: size, scale: scale)
        guard !frames.isEmpty else { return nil }
        let wrapped = phase - phase.rounded(.down)
        let index = min(frames.count - 1, max(0, Int(wrapped * Double(frames.count))))
        return frames[index]
    }

    /// Invalidate when the pet moves to a display with a different pixel density,
    /// otherwise it would stay crisp on one monitor and soft on another.
    func invalidate() {
        pose = nil
        frames = []
    }

    private func rebuildIfNeeded(pose: PetPose, size: NSSize, scale: CGFloat) {
        guard self.pose != pose || self.size != size || self.scale != scale else { return }
        guard size.width > 0, size.height > 0, scale > 0 else { return }

        self.pose = pose
        self.size = size
        self.scale = scale
        frames = (0..<Self.frameCount).compactMap { index in
            render(pose: pose, phase: Double(index) / Double(Self.frameCount), size: size, scale: scale)
        }
    }

    private func render(pose: PetPose, phase: Double, size: NSSize, scale: CGFloat) -> CGImage? {
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        renderer.draw(pose: pose, phase: phase, in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.current = previous

        return context.makeImage()
    }
}
