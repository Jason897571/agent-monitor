import AgentMonitorCore
import AppKit
import SwiftUI

/// One place for how each state reads on screen: its word and its colour. The card, the
/// docked bar and the bubble all use it, so a state cannot be orange in one and red in
/// another.
///
/// Colour carries the family, not the individual state: blocked-on-you is warm orange,
/// working is green, trouble is red, finished is blue, resting is grey. Fourteen hues
/// would be unreadable; five families are glanceable.
enum StateStyle {

    static func label(_ state: SessionState) -> String {
        switch state {
        case .busy: return "工作中"
        case .shell: return "shell"
        case .idle: return "空闲"
        case .waiting: return "等你"
        case .awaitingPermission: return "等你批准"
        case .awaitingAnswer: return "等你回答"
        case .compacting: return "压缩上下文"
        case .subagentSwarm: return "多代理并行"
        case .contextCritical: return "上下文将满"
        case .doneSuccess: return "完成"
        case .doneError: return "出错"
        case .rateLimited: return "额度用尽"
        case .disconnected: return "已断开"
        }
    }

    static func nsColour(_ state: SessionState) -> NSColor {
        switch state {
        case .waiting, .awaitingPermission, .awaitingAnswer:
            return NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.33, alpha: 1)
        case .busy, .subagentSwarm:
            return NSColor(calibratedRed: 0.40, green: 0.83, blue: 0.68, alpha: 1)
        case .compacting:
            return NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.95, alpha: 1)
        case .doneSuccess:
            return NSColor(calibratedRed: 0.45, green: 0.66, blue: 0.98, alpha: 1)
        case .doneError, .rateLimited, .disconnected, .contextCritical:
            return NSColor(calibratedRed: 0.93, green: 0.36, blue: 0.36, alpha: 1)
        case .idle:
            return NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.78, alpha: 1)
        case .shell:
            return NSColor(calibratedWhite: 0.55, alpha: 1)
        }
    }

    static func colour(_ state: SessionState) -> Color { Color(nsColor: nsColour(state)) }
}
