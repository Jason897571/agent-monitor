import AgentMonitorCore
import AppKit
import SwiftUI

/// A one-line caption above the pet: what the most relevant agent is doing, or what just
/// happened to it.
///
/// Claude Code already writes these lines for us — `activeForm` (「对比方案」) while it
/// works, the `away_summary` recap when it stops — so this costs no inference and invents
/// nothing. It is still chrome, not speech: a neutral capsule with no tail, because text
/// in the character's mouth is how a mirror turns into Clippy (DESIGN.md §1).
///
/// Transient by design. It appears when the line *changes*, stays a few seconds, and
/// goes. A caption that is always on is one more thing on screen to learn to ignore; the
/// card is one hover away for anything longer.
@MainActor
final class BubblePanel: NSPanel {

    private let host = NSHostingView(rootView: BubbleView(text: "", tint: .secondary))
    private var hideTimer: Timer?
    private var shownText: String?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        // Pure display. Never takes a click from whatever is underneath.
        ignoresMouseEvents = true
        level = .statusBar
        var behaviour: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        behaviour.insert(NSWindow.CollectionBehavior(rawValue: 1 << 18))
        collectionBehavior = behaviour
        contentView = host
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `text` near `anchor` for `duration` seconds. The same text twice in a row is
    /// not news and is ignored.
    func show(_ text: String, tint: Color, near anchor: NSRect, on screen: NSScreen?, duration: TimeInterval = 6) {
        guard text != shownText else { return }
        shownText = text
        host.rootView = BubbleView(text: text, tint: tint)
        let size = host.fittingSize
        setFrame(Self.placement(for: size, above: anchor, within: screen?.visibleFrame), display: true)

        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 1
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    /// Keeps an open bubble attached while the pet is dragged.
    func follow(_ anchor: NSRect, on screen: NSScreen?) {
        guard isVisible else { return }
        setFrame(Self.placement(for: frame.size, above: anchor, within: screen?.visibleFrame), display: false)
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
            }
        })
    }

    /// Forget what was last shown, so the same line may appear again later — after the
    /// pet slept, say.
    func reset() {
        shownText = nil
        hide()
    }

    /// Centred above the pet; below it when the pet is against the top of the screen.
    static func placement(for size: NSSize, above anchor: NSRect, within bounds: NSRect?) -> NSRect {
        let gap: CGFloat = 2
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY - 10 + gap
        if let bounds {
            if y + size.height > bounds.maxY { y = anchor.minY - size.height - gap }
            x = min(max(x, bounds.minX + 4), bounds.maxX - size.width - 4)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

struct BubbleView: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        )
        .padding(4)
        .fixedSize()
    }
}

/// What the bubble should say, derived from a snapshot. Pure, so the wording rules can
/// be read in one place.
enum BubbleText {

    /// The session worth captioning: the one the attention ladder picked if it is asking
    /// for a glance, otherwise the most urgent one — usually the one at work.
    static func focus(in snapshot: SessionRegistry.Snapshot) -> AgentSession? {
        if snapshot.attention.level >= .makeAware, let session = snapshot.attention.session {
            return snapshot.sessions.first { $0.id == session.id } ?? session
        }
        return snapshot.sessions.max { $0.state.urgency < $1.state.urgency }
    }

    static func line(for session: AgentSession, among count: Int) -> String? {
        // With several agents live, say which one. With one, the name is noise.
        let who = count > 1 ? "\(session.displayName)：" : ""
        switch session.state {
        case .busy, .subagentSwarm:
            guard let activity = session.activity else { return nil }
            let fan = session.subagents > 1 ? "（\(session.subagents) 个子 agent）" : ""
            return "\(who)\(activity)\(fan)"
        case .compacting: return "\(who)正在压缩上下文"
        case .awaitingPermission: return "\(who)等你批准权限"
        case .awaitingAnswer: return "\(who)有个问题等你回答"
        case .waiting: return "\(who)等你" + (session.waitingFor.map { "：\($0)" } ?? "")
        case .doneSuccess: return session.recap.map { "\(who)\($0)" } ?? "\(who)这一轮完成了"
        case .doneError: return "\(who)出错了" + (session.problem.map { "：\($0)" } ?? "")
        case .rateLimited: return "\(who)" + (session.problem ?? "额度用尽了")
        case .contextCritical:
            return "\(who)上下文快满了" + (session.contextUsedPercent.map { "（\(Int($0))%）" } ?? "")
        case .disconnected: return "\(who)意外退出了"
        case .idle, .shell: return nil
        }
    }
}
