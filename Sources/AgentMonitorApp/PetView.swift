import AgentMonitorCore
import AppKit
import QuartzCore

/// Draws the character and owns its animation clock.
@MainActor
final class PetView: NSView {

    private let renderer: CharacterRenderer = ProceduralCharacter()
    private lazy var sprites = SpriteCache(renderer: renderer)
    private var displayedFrame: CGImage?
    private var displayLink: CADisplayLink?
    private var phase: Double = 0
    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var dragOrigin: NSPoint?

    /// How long one breathing cycle takes, in seconds.
    ///
    /// Phase advances against wall time rather than per frame, so dropping to 2 fps
    /// while asleep slows the *sampling*, not the motion. Tying phase to frames is the
    /// classic way to end up with a pet that breathes at different speeds depending on
    /// how busy it is.
    private let cycleDuration: Double = 2.6

    var presentation: PetPresentation = PetPresentation(pose: .sleeping, opacity: 1, framesPerSecond: 2) {
        didSet {
            guard presentation != oldValue else { return }
            applyFrameRate()
            // A pose change must land even when the animation is paused — a pet that
            // falls asleep at 0 fps still has to actually close its eyes.
            if presentation.pose != oldValue.pose { presentCurrentFrame() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // Frames are pre-rendered at the display's pixel density and assigned whole,
        // so the layer must not resample them.
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    // MARK: - Animation

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopDisplayLink() } else { startDisplayLink() }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // CVDisplayLink is deprecated as of macOS 15; the view-attached CADisplayLink
        // also follows the window across displays on its own.
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = CACurrentMediaTime()
        applyFrameRate()
        presentCurrentFrame()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func applyFrameRate() {
        guard let displayLink else { return }
        let fps = presentation.framesPerSecond
        guard fps > 0 else {
            // A faded, sleeping pet has nothing worth a frame. Pausing outright — not
            // throttling — is what keeps the most common state also the cheapest.
            displayLink.isPaused = true
            return
        }
        displayLink.isPaused = false
        // Without an explicit range this runs at the display's rate, which on ProMotion
        // means 120 fps of sprite work for no visible gain and real battery cost.
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(max(1, fps / 2)),
            maximum: Float(fps),
            preferred: Float(fps)
        )
    }

    /// Counts actual display-link callbacks, so the effective frame rate can be
    /// measured rather than assumed. `preferredFrameRateRange` is a request, not a
    /// guarantee, and the difference between 2 fps and a display's native 120 is the
    /// whole energy budget.
    private(set) var tickCount: Int = 0

    /// Whether the animation clock exists and is running. Reported by `--selftest`
    /// because "the pet is not moving" has several very different causes.
    var displayLinkState: String {
        guard let displayLink else { return "absent" }
        return displayLink.isPaused ? "paused" : "running"
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastTick
        lastTick = now
        tickCount += 1
        phase = (phase + elapsed / cycleDuration).truncatingRemainder(dividingBy: 1.0)
        presentCurrentFrame()
    }

    // MARK: - Drawing

    /// The entire per-frame cost: pick a cached image and hand it to the layer.
    ///
    /// There is deliberately no `draw(_:)` override. Drawing the character live cost
    /// ~1.5 ms of CPU per frame; this is a pointer comparison and an assignment, and
    /// the render server composites it.
    private func presentCurrentFrame() {
        let scale = window?.backingScaleFactor ?? 2
        guard let frame = sprites.image(
            pose: presentation.pose, phase: phase, size: bounds.size, scale: scale
        ) else { return }
        guard frame !== displayedFrame else { return }
        displayedFrame = frame
        // Frames are swapped on purpose, so suppress the implicit contents crossfade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = frame
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving to a display with a different density would otherwise leave the pet
        // crisp on one monitor and soft on the next.
        sprites.invalidate()
        displayedFrame = nil
        presentCurrentFrame()
    }

    // MARK: - Hit testing

    /// Whether a point in view coordinates lands on the character itself.
    ///
    /// An explicit mask from day one rather than trusting the window server's alpha
    /// test: that test regressed on macOS 26.3 RC so a transparent window swallowed
    /// clicks across its whole frame. Treating alpha hit testing as an optimisation
    /// instead of a correctness dependency means such a regression costs nothing.
    func bodyContains(_ point: NSPoint) -> Bool {
        renderer.bodyPath(pose: presentation.pose, phase: phase, in: bounds).contains(point)
    }

    // MARK: - Dragging

    /// True for the whole of a drag gesture. The controller pins hit testing on while
    /// this holds, so the pet cannot slip out from under the cursor mid-drag.
    var isDragging: Bool { dragOrigin != nil }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragOrigin = NSEvent.mouseLocation - window.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOrigin else { return }
        let target = NSEvent.mouseLocation - dragOrigin
        window.setFrameOrigin(target)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard let window, dragOrigin != nil else { return }
        window.setFrameOrigin(snapped(window.frame, on: window.screen))
    }

    /// Pulls the pet flush to a screen edge when released near one.
    ///
    /// `visibleFrame` rather than `frame`, so it respects the Dock and menu bar — a pet
    /// that snaps *underneath* the Dock has effectively hidden itself.
    private func snapped(_ frame: NSRect, on screen: NSScreen?) -> NSPoint {
        guard let bounds = screen?.visibleFrame else { return frame.origin }
        let threshold: CGFloat = 40
        var origin = frame.origin

        if abs(frame.minX - bounds.minX) < threshold { origin.x = bounds.minX }
        if abs(frame.maxX - bounds.maxX) < threshold { origin.x = bounds.maxX - frame.width }
        if abs(frame.minY - bounds.minY) < threshold { origin.y = bounds.minY }
        if abs(frame.maxY - bounds.maxY) < threshold { origin.y = bounds.maxY - frame.height }

        return origin
    }
}

private func - (lhs: NSPoint, rhs: NSPoint) -> NSPoint {
    NSPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}
