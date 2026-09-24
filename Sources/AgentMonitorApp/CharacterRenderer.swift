import AgentMonitorCore
import AppKit

/// How a character is drawn.
///
/// The seam exists so the placeholder below can be swapped for a sprite atlas — or
/// a petdex-format pack — without the window, the hit testing or the state plumbing
/// noticing. Art must never be what blocks the rest of the build.
@MainActor
protocol CharacterRenderer {
    /// Draws one frame. `phase` advances with time and wraps at 1.
    func draw(pose: PetPose, phase: Double, in rect: NSRect)

    /// The character's silhouette, used both for drawing and as the mouse hit mask.
    ///
    /// One source of truth on purpose: if the shape and the clickable area can drift
    /// apart, they will, and the bug is invisible until a user complains that the pet
    /// eats clicks next to its head.
    func bodyPath(pose: PetPose, phase: Double, in rect: NSRect) -> NSBezierPath
}

/// A small procedural character: a rounded body, two eyes, and an accent that reacts
/// to state. Deliberately simple — it exists so every other layer can be built and
/// verified before any art exists.
@MainActor
struct ProceduralCharacter: CharacterRenderer {

    func bodyPath(pose: PetPose, phase: Double, in rect: NSRect) -> NSBezierPath {
        let metrics = Metrics(pose: pose, phase: phase, rect: rect)
        return NSBezierPath(roundedRect: metrics.body,
                            xRadius: metrics.cornerRadius,
                            yRadius: metrics.cornerRadius)
    }

    func draw(pose: PetPose, phase: Double, in rect: NSRect) {
        let metrics = Metrics(pose: pose, phase: phase, rect: rect)
        let palette = Palette(pose: pose)

        if pose == .alert {
            drawAlertHalo(metrics: metrics, palette: palette, phase: phase)
        }

        let body = bodyPath(pose: pose, phase: phase, in: rect)
        palette.body.setFill()
        body.fill()
        palette.outline.setStroke()
        body.lineWidth = 1.5
        body.stroke()

        drawEyes(pose: pose, phase: phase, metrics: metrics, palette: palette)

        if pose == .working { drawWorkingIndicator(metrics: metrics, palette: palette, phase: phase) }
        if pose == .sleeping { drawSleepMark(metrics: metrics, palette: palette, phase: phase) }
    }

    // MARK: - Pieces

    private func drawEyes(pose: PetPose, phase: Double, metrics: Metrics, palette: Palette) {
        let eyeY = metrics.body.midY + metrics.body.height * 0.12
        let spacing = metrics.body.width * 0.22
        let centers = [
            NSPoint(x: metrics.body.midX - spacing, y: eyeY),
            NSPoint(x: metrics.body.midX + spacing, y: eyeY),
        ]

        palette.eye.setFill()
        palette.eye.setStroke()

        for center in centers {
            switch pose {
            case .sleeping:
                // Closed: a downward arc reads as "asleep" far more clearly at small
                // sizes than a filled shape does.
                let path = NSBezierPath()
                let width = metrics.eyeRadius * 1.6
                path.move(to: NSPoint(x: center.x - width, y: center.y))
                path.curve(to: NSPoint(x: center.x + width, y: center.y),
                           controlPoint1: NSPoint(x: center.x - width * 0.4, y: center.y - width * 0.9),
                           controlPoint2: NSPoint(x: center.x + width * 0.4, y: center.y - width * 0.9))
                path.lineWidth = 2
                path.lineCapStyle = .round
                path.stroke()

            case .waking:
                // Squinting open over the course of the animation.
                let openness = min(1, max(0.15, phase * 1.6))
                let height = metrics.eyeRadius * 2 * openness
                let rect = NSRect(x: center.x - metrics.eyeRadius, y: center.y - height / 2,
                                  width: metrics.eyeRadius * 2, height: height)
                NSBezierPath(ovalIn: rect).fill()

            default:
                let blink = blinkScale(phase: phase, pose: pose)
                let widen: CGFloat = (pose == .alert || pose == .attentive) ? 1.25 : 1.0
                let height = metrics.eyeRadius * 2 * blink * widen
                let rect = NSRect(x: center.x - metrics.eyeRadius * widen,
                                  y: center.y - height / 2,
                                  width: metrics.eyeRadius * 2 * widen, height: height)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    /// Blinks are rare and quick; a pet that blinks on a metronome looks mechanical.
    private func blinkScale(phase: Double, pose: PetPose) -> CGFloat {
        guard pose != .alert else { return 1.0 }  // too tense to blink
        let window = 0.06
        let position = phase.truncatingRemainder(dividingBy: 1.0)
        guard position < window else { return 1.0 }
        let t = position / window
        return CGFloat(abs(cos(t * .pi)))
    }

    private func drawAlertHalo(metrics: Metrics, palette: Palette, phase: Double) {
        let pulse = 0.5 + 0.5 * sin(phase * .pi * 2)
        let inset = -metrics.body.width * (0.06 + 0.05 * pulse)
        let halo = NSBezierPath(roundedRect: metrics.body.insetBy(dx: inset, dy: inset),
                                xRadius: metrics.cornerRadius * 1.3,
                                yRadius: metrics.cornerRadius * 1.3)
        palette.accent.withAlphaComponent(0.25 + 0.25 * pulse).setStroke()
        halo.lineWidth = 2.5
        halo.stroke()
    }

    private func drawWorkingIndicator(metrics: Metrics, palette: Palette, phase: Double) {
        // Three dots cycling — the universal "still going" shorthand, and honest:
        // it says activity, not progress, because we do not know progress.
        let count = 3
        let radius = metrics.body.width * 0.035
        let spacing = radius * 3.2
        let y = metrics.body.minY + metrics.body.height * 0.18
        let startX = metrics.body.midX - spacing
        for index in 0..<count {
            let lit = Int((phase * Double(count) * 2).rounded(.down)) % count == index
            palette.accent.withAlphaComponent(lit ? 0.95 : 0.3).setFill()
            let center = NSPoint(x: startX + CGFloat(index) * spacing, y: y)
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawSleepMark(metrics: Metrics, palette: Palette, phase: Double) {
        let drift = CGFloat(sin(phase * .pi * 2)) * metrics.body.width * 0.02
        let origin = NSPoint(x: metrics.body.maxX - metrics.body.width * 0.1,
                             y: metrics.body.maxY - metrics.body.height * 0.02 + drift)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: metrics.body.width * 0.18, weight: .semibold),
            .foregroundColor: palette.accent.withAlphaComponent(0.55),
        ]
        NSAttributedString(string: "z", attributes: attributes).draw(at: origin)
    }

    // MARK: - Geometry and colour

    private struct Metrics {
        let body: NSRect
        let cornerRadius: CGFloat
        let eyeRadius: CGFloat

        init(pose: PetPose, phase: Double, rect: NSRect) {
            // Leave room for the alert halo and the sleep mark so neither is clipped.
            let inset = rect.width * 0.14
            var body = rect.insetBy(dx: inset, dy: inset)

            // Breathing: slow and shallow while asleep, a little livelier awake.
            let amplitude: CGFloat
            switch pose {
            case .sleeping: amplitude = 0.020
            case .working: amplitude = 0.028
            case .alert: amplitude = 0.034
            case .waking: amplitude = 0.045
            default: amplitude = 0.016
            }
            let breath = CGFloat(sin(phase * .pi * 2)) * amplitude
            body = body.insetBy(dx: -body.width * breath, dy: -body.height * breath)

            // Waking is a stretch: squash low, then rise.
            if pose == .waking {
                let rise = CGFloat(min(1, phase * 1.4))
                body = body.offsetBy(dx: 0, dy: -body.height * 0.12 * (1 - rise))
            }

            self.body = body
            self.cornerRadius = body.width * 0.34
            self.eyeRadius = body.width * 0.075
        }
    }

    private struct Palette {
        let body: NSColor
        let outline: NSColor
        let eye: NSColor
        let accent: NSColor

        init(pose: PetPose) {
            // An overlay sits on an unknown background, so the body carries its own
            // contrast rather than trusting the desktop behind it.
            outline = NSColor.black.withAlphaComponent(0.35)
            eye = NSColor.black.withAlphaComponent(0.78)
            switch pose {
            case .sleeping:
                body = NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.76, alpha: 0.92)
                accent = NSColor(calibratedRed: 0.35, green: 0.40, blue: 0.55, alpha: 1)
            case .waking, .resting:
                body = NSColor(calibratedRed: 0.74, green: 0.80, blue: 0.84, alpha: 0.95)
                accent = NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.52, alpha: 1)
            case .working:
                body = NSColor(calibratedRed: 0.52, green: 0.80, blue: 0.70, alpha: 0.96)
                accent = NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.34, alpha: 1)
            case .attentive:
                body = NSColor(calibratedRed: 0.95, green: 0.83, blue: 0.52, alpha: 0.96)
                accent = NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.08, alpha: 1)
            case .alert:
                body = NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.48, alpha: 0.97)
                accent = NSColor(calibratedRed: 0.72, green: 0.28, blue: 0.12, alpha: 1)
            }
        }
    }
}
