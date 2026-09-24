import AgentMonitorCore
import AppKit

/// An agent team drawn around the pet: the lead is the pet itself, every teammate a small
/// companion placed by where its work sits in the dependency graph.
///
/// This is the one thing the pet form factor can show that a notch bar cannot — a bar is
/// one-dimensional, and "this worker is idle although its work is unblocked" needs a
/// second dimension to point at. Columns are dependency depth (who waits on whom), rows
/// separate teammates at the same depth, and arrows are the `blockedBy` edges between
/// people. A stalled teammate is the orange one. DESIGN.md §2 支点 D.
///
/// Drawn once per change, not animated: it is a diagram, and a diagram that breathes
/// would cost frames for nothing.
@MainActor
final class TeamPanel: NSPanel {

    private let diagram = TeamDiagramView(frame: .zero)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = .statusBar
        var behaviour: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        behaviour.insert(NSWindow.CollectionBehavior(rawValue: 1 << 18))
        collectionBehavior = behaviour
        contentView = diagram
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Teammates are drawn in the same character as the pet.
    var skin: Skin? {
        get { diagram.skin }
        set { diagram.skin = newValue; diagram.needsDisplay = true }
    }

    /// Shows `team` beside `anchor`, or hides when there is no one to show.
    func show(_ team: AgentTeam?, beside anchor: NSRect, on screen: NSScreen?) {
        guard let team, team.members.contains(where: { !$0.isLead }) else {
            orderOut(nil)
            return
        }
        diagram.team = team
        let size = diagram.preferredSize
        let bounds = screen?.visibleFrame
        // Toward the middle of the screen, like the card: the pet lives in a corner.
        let opensLeft = bounds.map { anchor.midX > $0.midX } ?? true
        diagram.opensLeft = opensLeft
        var x = opensLeft ? anchor.minX - size.width + 12 : anchor.maxX - 12
        var y = anchor.midY - size.height / 2
        if let bounds {
            x = min(max(x, bounds.minX), bounds.maxX - size.width)
            y = min(max(y, bounds.minY), bounds.maxY - size.height)
        }
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        diagram.needsDisplay = true
        orderFrontRegardless()
    }
}

@MainActor
final class TeamDiagramView: NSView {

    var team: AgentTeam?
    var skin: Skin?
    /// Whether the diagram extends to the left of the pet (so the lead end is on the right).
    var opensLeft = true

    private let renderer = ProceduralCharacter()
    private let column: CGFloat = 70
    private let row: CGFloat = 52
    private let mini: CGFloat = 30

    override var isOpaque: Bool { false }

    private var teammates: [AgentTeam.Member] {
        (team?.members ?? []).filter { !$0.isLead }.sorted { ($0.depth, $0.name) < ($1.depth, $1.name) }
    }

    private var columns: [[AgentTeam.Member]] {
        let grouped = Dictionary(grouping: teammates, by: { min($0.depth, 4) })
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
    }

    var preferredSize: NSSize {
        let columns = columns
        let rows = columns.map(\.count).max() ?? 1
        return NSSize(width: CGFloat(columns.count) * column + 24, height: CGFloat(rows) * row + 12)
    }

    /// Centre of each teammate's mini pet, in view coordinates.
    private func positions() -> [String: NSPoint] {
        var result: [String: NSPoint] = [:]
        for (columnIndex, members) in columns.enumerated() {
            // Column 0 sits next to the pet (the lead); deeper work fans outward.
            let x = opensLeft
                ? bounds.maxX - 12 - column * (CGFloat(columnIndex) + 0.5)
                : bounds.minX + 12 + column * (CGFloat(columnIndex) + 0.5)
            let total = CGFloat(members.count) * row
            for (rowIndex, member) in members.enumerated() {
                let y = bounds.midY + total / 2 - row * (CGFloat(rowIndex) + 0.5) + 6
                result[member.name] = NSPoint(x: x, y: y)
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let team else { return }
        let points = positions()
        let lead = NSPoint(x: opensLeft ? bounds.maxX : bounds.minX, y: bounds.midY)

        // Edges first, under the pets. Lead → first column, then task dependencies.
        NSColor.white.withAlphaComponent(0.55).setStroke()
        for member in teammates where member.depth == 0 {
            if let point = points[member.name] { line(from: lead, to: point, dashed: true) }
        }
        for edge in team.edges {
            guard let from = points[edge.from], let to = points[edge.to] else { continue }
            line(from: from, to: to, dashed: false)
        }

        for member in teammates {
            guard let center = points[member.name] else { continue }
            let rect = NSRect(x: center.x - mini / 2, y: center.y - mini / 2, width: mini, height: mini)
            if member.state == .stalled {
                TeamStyle.nsColour(.stalled).withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -5, dy: -5)).fill()
            }
            if let still = skin?.still(for: pose(for: member.state)) {
                let fit = min(rect.width / CGFloat(still.width), rect.height / CGFloat(still.height))
                let size = NSSize(width: CGFloat(still.width) * fit, height: CGFloat(still.height) * fit)
                NSImage(cgImage: still, size: size).draw(in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height))
            } else {
                renderer.draw(pose: pose(for: member.state), phase: 0.3, in: rect)
            }
            drawName(member.name, under: rect, colour: TeamStyle.nsColour(member.state))
        }
    }

    private func pose(for state: TeammateState) -> PetPose {
        switch state {
        case .working: return .working
        case .blocked: return .resting
        case .stalled: return .alert
        case .idle: return .sleeping
        }
    }

    private func line(from: NSPoint, to: NSPoint, dashed: Bool) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 1.2
        if dashed { path.setLineDash([3, 3], count: 2, phase: 0) }
        path.stroke()
    }

    private func drawName(_ name: String, under rect: NSRect, colour: NSColor) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        let text = NSAttributedString(string: name.count > 12 ? String(name.prefix(11)) + "…" : name,
                                      attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 1))
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - size.width / 2 - 7, y: rect.minY - size.height / 2 - 4,
                                    width: 4, height: 4)).fill()
    }
}
