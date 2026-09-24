import AgentMonitorCore
import AppKit
import SwiftUI

/// The detail card shown while the pointer rests on the pet.
///
/// Text lives here, on neutral chrome, and never in the character's mouth — DESIGN.md §1:
/// the pet mirrors state through posture, and anything that reads like the pet talking
/// about your code is the first step toward Clippy.
@MainActor
final class SessionCardPanel: NSPanel {

    private let host = FirstClickHostingView(rootView: SessionCardView(sessions: [], now: Date(), onSelect: { _ in }))
    private let effect = NSVisualEffectView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        // Takes clicks while it is open. It only exists while the pointer is on it or on
        // its way to it, so there is no window behind it the user could be aiming for.
        ignoresMouseEvents = false
        level = .statusBar
        var behaviour: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if #available(macOS 13.0, *) {
            behaviour.insert(NSWindow.CollectionBehavior(rawValue: 1 << 18))
        }
        collectionBehavior = behaviour

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isShowing: Bool { isVisible && alphaValue > 0 }

    /// Where the card opens relative to the window that summoned it.
    enum Edge {
        /// Beside the free-floating pet.
        case side
        /// Hanging from the docked bar, like a menu from the menu bar.
        case below
    }

    /// Shows or refreshes the card next to `anchor`, a frame in screen coordinates.
    func show(
        sessions: [AgentSession],
        near anchor: NSRect,
        on screen: NSScreen?,
        edge: Edge,
        onSelect: @escaping @MainActor (AgentSession) -> Void
    ) {
        host.rootView = SessionCardView(sessions: sessions.orderedForDisplay(), now: Date(), onSelect: onSelect)
        let size = host.fittingSize
        let frame = switch edge {
        case .side: Self.placement(for: size, beside: anchor, within: screen?.visibleFrame)
        case .below: Self.placement(for: size, below: anchor, within: screen?.visibleFrame)
        }
        setFrame(frame, display: true)

        guard !isShowing else { return }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
            }
        })
    }

    /// Centred under the docked bar. `visibleFrame` already excludes the menu bar, so
    /// clamping to it keeps the card from sliding up underneath the bar it hangs from.
    static func placement(for size: NSSize, below anchor: NSRect, within bounds: NSRect?) -> NSRect {
        let gap: CGFloat = 6
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - gap - size.height
        if let bounds {
            x = min(max(x, bounds.minX + gap), bounds.maxX - size.width - gap)
            y = min(max(y, bounds.minY + gap), bounds.maxY - size.height)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Beside the pet on whichever side has room, preferring the side facing the middle
    /// of the screen — the pet usually lives in a corner, and a card that opens off the
    /// edge of the display is a card nobody sees.
    static func placement(for size: NSSize, beside anchor: NSRect, within bounds: NSRect?) -> NSRect {
        let gap: CGFloat = 8
        guard let bounds else {
            return NSRect(x: anchor.minX - size.width - gap, y: anchor.minY, width: size.width, height: size.height)
        }
        let opensLeft = anchor.midX > bounds.midX
        var x = opensLeft ? anchor.minX - size.width - gap : anchor.maxX + gap
        // Bottom-align with the pet, then grow upward if it is sitting low.
        var y = anchor.minY
        x = min(max(x, bounds.minX + gap), bounds.maxX - size.width - gap)
        y = min(max(y, bounds.minY + gap), bounds.maxY - size.height - gap)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Hosts SwiftUI in a window that is never key.
///
/// Such a window treats the first click as "bring me forward" and swallows it, so every
/// row would have needed two clicks. Accepting the first mouse makes one enough.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One row per session, most urgent first.
struct SessionCardView: View {

    let sessions: [AgentSession]
    let now: Date
    /// Called when a row is clicked.
    let onSelect: @MainActor (AgentSession) -> Void

    /// Beyond this the card stops being glanceable. The rest are summarised in a line.
    private let limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if sessions.isEmpty {
                Text("没有正在运行的 agent")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions.prefix(limit)) { session in
                        SessionRow(session: session, now: now, onSelect: onSelect)
                    }
                }
                .padding(.vertical, 4)
                if sessions.count > limit {
                    Text("还有 \(sessions.count - limit) 个会话")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(width: 320, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("Agent 会话").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var summary: String {
        let counts = SessionSummary(sessions: sessions)
        var parts: [String] = []
        if counts.count(.waiting) > 0 { parts.append("\(counts.count(.waiting)) 个在等你") }
        if counts.count(.busy) > 0 { parts.append("\(counts.count(.busy)) 个工作中") }
        let rest = counts.count(.idle) + counts.count(.shell)
        if rest > 0 { parts.append("\(rest) 个空闲") }
        return parts.joined(separator: " · ")
    }
}

private struct SessionRow: View {

    let session: AgentSession
    let now: Date
    let onSelect: @MainActor (AgentSession) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(colour)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(label) · \(age)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let waitingFor = session.waitingFor, session.state == .waiting {
                    Text(waitingFor)
                        .font(.system(size: 11))
                        .foregroundStyle(colour)
                        .lineLimit(1)
                }
                if let title = session.title {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                .padding(.horizontal, 6)
        )
        // The whole row is the target, not just the glyphs in it.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect(session) }
        .help("切到运行这个会话的应用")
    }

    private var label: String {
        switch session.state {
        case .busy: return "工作中"
        case .waiting: return "等你"
        case .idle: return "空闲"
        case .shell: return "shell"
        }
    }

    private var colour: Color {
        switch session.state {
        case .waiting: return Color(red: 0.96, green: 0.55, blue: 0.33)
        case .busy: return Color(red: 0.40, green: 0.83, blue: 0.68)
        case .idle: return Color(red: 0.75, green: 0.75, blue: 0.78)
        case .shell: return Color(white: 0.55)
        }
    }

    private var age: String {
        let seconds = Int(max(0, session.timeInState(now: now)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时" }
        return "\(seconds / 86_400) 天"
    }
}
