import AgentMonitorCore
import AppKit
import SwiftUI

/// The dot at the start of a session row, drawn so each family of state reads at a glance
/// without its label: working things move, blocked things blink, finished things tick,
/// broken things say so.
///
/// Motion is reserved for states where something is actually happening — an animated dot
/// for a session idle since last week would train the eye to ignore motion. These only
/// run while the card is open, so they cost nothing the rest of the time.
struct StatusGlyph: View {
    let state: SessionState
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            switch state {
            case .busy:
                Ripple(colour: colour, size: size)
            case .subagentSwarm:
                Bouncing(colour: colour, size: size)
            case .compacting:
                Spinner(colour: colour, size: size)
            case .waiting, .awaitingPermission, .awaitingAnswer:
                Blink(colour: colour, size: size, symbol: state == .awaitingAnswer ? "questionmark" : "exclamationmark")
            case .doneSuccess:
                Badge(colour: colour, size: size, symbol: "checkmark")
            case .doneError, .rateLimited, .contextCritical:
                Badge(colour: colour, size: size, symbol: state == .rateLimited ? "hourglass" : "exclamationmark")
            case .disconnected:
                Badge(colour: colour, size: size, symbol: "xmark")
            case .idle:
                Circle().strokeBorder(colour, lineWidth: 1.5).frame(width: size * 0.55, height: size * 0.55)
            case .shell:
                Image(systemName: "terminal").font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(colour)
            }
        }
        .frame(width: size, height: size)
    }

    private var colour: Color { StateStyle.colour(state) }
}

/// A solid dot with a ring expanding out of it — "alive, working".
private struct Ripple: View {
    let colour: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            ZStack {
                Circle()
                    .stroke(colour, lineWidth: 1.5)
                    .frame(width: size * (0.45 + 0.55 * t), height: size * (0.45 + 0.55 * t))
                    .opacity(1 - t)
                Circle()
                    .fill(colour)
                    .frame(width: size * 0.45, height: size * 0.45)
                    .scaleEffect(1 + 0.12 * sin(t * .pi * 2))
            }
        }
    }
}

/// Three dots taking turns — several things at once.
private struct Bouncing: View {
    let colour: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.08) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(colour)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .offset(y: -size * 0.22 * max(0, sin((t * 2 - Double(index) * 0.2) * .pi * 2)))
                }
            }
        }
    }
}

/// A turning arc — busy, but digesting rather than doing.
private struct Spinner: View {
    let colour: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size * 0.7, height: size * 0.7)
                .rotationEffect(.degrees(angle))
        }
    }
}

/// A filled badge that breathes in and out — "your turn".
private struct Blink: View {
    let colour: Color
    let size: CGFloat
    let symbol: String

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
            let pulse = 0.5 + 0.5 * cos(t * .pi * 2)
            Badge(colour: colour, size: size, symbol: symbol)
                .scaleEffect(0.9 + 0.12 * pulse)
                .opacity(0.55 + 0.45 * pulse)
        }
    }
}

/// A still, filled circle with a symbol in it — an outcome, not an activity.
private struct Badge: View {
    let colour: Color
    let size: CGFloat
    let symbol: String

    var body: some View {
        ZStack {
            Circle().fill(colour)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Product

/// Which product a session belongs to: the agent (Claude Code, Codex, …) and the app it
/// runs in (Cursor, Ghostty, iTerm, the Codex desktop app…).
///
/// The two are different questions. A Claude Code session in Cursor's terminal is Claude
/// Code — Cursor is only where it lives, and where clicking the row will take you.
struct ProductLabel: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 4) {
            Text(session.agent.displayName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AgentStyle.foreground(session.agent))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(AgentStyle.background(session.agent)))
            if let host = HostCache.shared.host(for: session.pid) {
                HStack(spacing: 3) {
                    if let icon = host.icon {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text(host.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize()
    }
}

enum AgentStyle {
    static func background(_ agent: AgentKind) -> Color {
        switch agent.rawValue {
        case AgentKind.claudeCode.rawValue: return Color(red: 0.85, green: 0.47, blue: 0.34)   // Claude's terracotta
        case AgentKind.codex.rawValue: return Color(white: 0.15)
        default: return Color.primary.opacity(0.15)
        }
    }

    static func foreground(_ agent: AgentKind) -> Color {
        switch agent.rawValue {
        case AgentKind.claudeCode.rawValue, AgentKind.codex.rawValue: return .white
        default: return .primary
        }
    }
}

/// Host-app lookups, remembered per process. Finding the host walks the process tree
/// and asks Launch Services about each ancestor — cheap once, wasteful at 60 fps while
/// the card's glyphs animate.
@MainActor
final class HostCache {
    static let shared = HostCache()

    struct Host {
        let name: String
        let icon: NSImage?
    }

    private var hosts: [pid_t: Host?] = [:]

    func host(for pid: pid_t) -> Host? {
        if let cached = hosts[pid] { return cached }
        let found = HostApp.find(for: pid).map { match -> Host in
            let icon = match.app.icon
            icon?.size = NSSize(width: 12, height: 12)
            return Host(name: match.app.localizedName ?? "?", icon: icon)
        }
        if hosts.count > 256 { hosts.removeAll() }
        hosts[pid] = found
        return found
    }
}
