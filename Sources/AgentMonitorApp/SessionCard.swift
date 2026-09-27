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

    private let host = FirstClickHostingView(rootView: SessionCardView(snapshot: nil, now: Date(), onSelect: { _ in }))
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
        snapshot: SessionRegistry.Snapshot?,
        near anchor: NSRect,
        on screen: NSScreen?,
        edge: Edge,
        onSelect: @escaping @MainActor (AgentSession) -> Void
    ) {
        host.rootView = SessionCardView(snapshot: snapshot, now: Date(), onSelect: onSelect)
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

/// One row per session, most urgent first; then teams; then plan usage.
struct SessionCardView: View {

    let snapshot: SessionRegistry.Snapshot?
    let now: Date
    /// Called when a row is clicked.
    let onSelect: @MainActor (AgentSession) -> Void

    /// Beyond this the card stops being glanceable. The rest are summarised in a line.
    private let limit = 8

    private var sessions: [AgentSession] { (snapshot?.sessions ?? []).orderedForDisplay() }

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
            ForEach(snapshot?.teams ?? [], id: \.name) { team in
                Divider().opacity(0.4)
                TeamSection(team: team)
            }
            if !quotaLines.isEmpty {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(quotaLines, id: \.text) { line in
                        Text(line.text)
                            .font(.system(size: 11))
                            .foregroundStyle(line.isNearLimit ? StateStyle.colour(.waiting) : .secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 340, alignment: .leading)
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
        let blocked = sessions.filter { $0.state.isBlockedOnUser }.count
        let working = sessions.filter { $0.state.isWorking }.count
        let trouble = sessions.filter { $0.state.isTrouble }.count
        let rest = sessions.count - blocked - working - trouble
        var parts: [String] = []
        if blocked > 0 { parts.append("\(blocked) 个在等你") }
        if trouble > 0 { parts.append("\(trouble) 个有问题") }
        if working > 0 { parts.append("\(working) 个工作中") }
        if rest > 0 { parts.append("\(rest) 个空闲") }
        return parts.joined(separator: " · ")
    }

    private var quotaLines: [(text: String, isNearLimit: Bool)] {
        (snapshot?.quotas ?? []).compactMap { quota in
            let windows = quota.current(now: now)
            guard !windows.isEmpty else { return nil }
            let parts = windows.map { window -> String in
                var text = "\(window.label) \(Int(window.usedPercent.rounded()))%"
                if window.isNearLimit, let resets = window.resetsAt {
                    text += "（\(Self.until(resets, now: now))重置）"
                }
                return text
            }
            return ("\(quota.agent.displayName) 额度 · " + parts.joined(separator: " · "),
                    windows.contains { $0.isNearLimit })
        }
    }

    static func until(_ date: Date, now: Date) -> String {
        let seconds = Int(max(0, date.timeIntervalSince(now)))
        if seconds < 3600 { return "\(max(1, seconds / 60)) 分钟后" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时后" }
        return "\(seconds / 86_400) 天后"
    }
}

private struct SessionRow: View {

    let session: AgentSession
    let now: Date
    let onSelect: @MainActor (AgentSession) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusGlyph(state: session.state)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(StateStyle.label(session.state))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colour)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(colour.opacity(0.16)))
                        .fixedSize()
                    Text(age)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                ProductLabel(session: session)
                if let detail {
                    Text(detail.text)
                        .font(.system(size: 11))
                        .foregroundStyle(detail.emphasised ? colour : .secondary)
                        .lineLimit(detail.lines)
                        .truncationMode(.tail)
                }
                if let title = session.title {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let extras {
                    Text(extras)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
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

    /// The one line that says most about this session right now.
    private var detail: (text: String, emphasised: Bool, lines: Int)? {
        switch session.state {
        case .waiting:
            return session.waitingFor.map { ($0, true, 1) }
        case .awaitingPermission, .awaitingAnswer:
            return nil
        case .doneError, .rateLimited:
            return session.problem.map { ($0, true, 2) }
        case .busy, .compacting, .subagentSwarm:
            return session.activity.map { ("⋯ \($0)", false, 1) }
        case .contextCritical:
            return session.contextUsedPercent.map { ("上下文已用 \(Int($0))%，下个大任务前可以考虑新开会话", true, 2) }
        case .idle, .doneSuccess:
            return session.recap.map { ($0, false, 2) }
        case .shell, .disconnected:
            return nil
        }
    }

    private var extras: String? {
        var parts: [String] = []
        if session.subagents > 0 { parts.append("\(session.subagents) 个子 agent") }
        if let team = session.team { parts.append("团队 \(team)") }
        if let used = session.contextUsedPercent, used >= 70, session.state != .contextCritical {
            parts.append("上下文 \(Int(used))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var colour: Color { StateStyle.colour(session.state) }

    private var age: String {
        let seconds = Int(max(0, session.timeInState(now: now)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时" }
        return "\(seconds / 86_400) 天"
    }
}

/// A team as a list, lead first, in dependency order — the textual twin of the topology
/// drawn around the pet.
private struct TeamSection: View {
    let team: AgentTeam

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("团队 \(team.name)").font(.system(size: 11, weight: .semibold))
                Spacer()
                if !team.stalled.isEmpty {
                    Text("\(team.stalled.count) 个停摆")
                        .font(.system(size: 11))
                        .foregroundStyle(StateStyle.colour(.waiting))
                }
            }
            ForEach(team.members.sorted { ($0.isLead ? -1 : $0.depth, $0.name) < ($1.isLead ? -1 : $1.depth, $1.name) }) { member in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(colour(member.state)).frame(width: 6, height: 6)
                    Text(member.isLead ? "\(member.name)（lead）" : member.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(member.activity.map { "\(label(member.state)) · \($0)" } ?? label(member.state))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, CGFloat(member.isLead ? 0 : min(member.depth, 3)) * 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func label(_ state: TeammateState) -> String {
        switch state {
        case .working: return "工作中"
        case .blocked: return "等依赖"
        case .stalled: return "停摆"
        case .idle: return "空闲"
        }
    }

    private func colour(_ state: TeammateState) -> Color { TeamStyle.colour(state) }
}

enum TeamStyle {
    static func nsColour(_ state: TeammateState) -> NSColor {
        switch state {
        case .working: return StateStyle.nsColour(.busy)
        case .blocked: return StateStyle.nsColour(.idle)
        case .stalled: return StateStyle.nsColour(.waiting)
        case .idle: return StateStyle.nsColour(.shell)
        }
    }

    static func colour(_ state: TeammateState) -> Color { Color(nsColor: nsColour(state)) }
}
