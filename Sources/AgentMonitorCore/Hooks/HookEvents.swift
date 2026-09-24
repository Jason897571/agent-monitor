import Foundation

/// One Claude Code hook invocation, as delivered to `HookServer`.
///
/// Decoded leniently: the payload grows fields every release, and the monitor only needs
/// a handful of them. Anything unknown is ignored rather than failing the event.
public struct HookEvent: Decodable, Sendable, Equatable {
    public let name: String
    public let sessionID: String
    public let toolName: String?
    public let agentID: String?
    /// `StopFailure`: Claude Code's error class — `rate_limit`, `server_error`, …
    public let error: String?
    public let errorDetails: String?
    public let lastAssistantMessage: String?
    /// `SessionStart`: `startup`, `resume`, `clear`, `compact`, `fork`.
    public let source: String?
    public let teammateName: String?
    /// When the monitor received it. Hook payloads carry no timestamp of their own.
    public var receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case name = "hook_event_name"
        case sessionID = "session_id"
        case toolName = "tool_name"
        case agentID = "agent_id"
        case error
        case errorDetails = "error_details"
        case lastAssistantMessage = "last_assistant_message"
        case source
        case teammateName = "teammate_name"
    }

    public init(
        name: String, sessionID: String, toolName: String? = nil, agentID: String? = nil,
        error: String? = nil, errorDetails: String? = nil, lastAssistantMessage: String? = nil,
        source: String? = nil, teammateName: String? = nil, receivedAt: Date = Date()
    ) {
        self.name = name
        self.sessionID = sessionID
        self.toolName = toolName
        self.agentID = agentID
        self.error = error
        self.errorDetails = errorDetails
        self.lastAssistantMessage = lastAssistantMessage
        self.source = source
        self.teammateName = teammateName
        self.receivedAt = receivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
        agentID = try? c.decodeIfPresent(String.self, forKey: .agentID)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        errorDetails = try? c.decodeIfPresent(String.self, forKey: .errorDetails)
        lastAssistantMessage = try? c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        teammateName = try? c.decodeIfPresent(String.self, forKey: .teammateName)
        receivedAt = Date()
    }

    /// The events the installer subscribes to — each one earns its place by changing
    /// something the pet can show. `PostToolUse` and `PermissionRequest` are deliberately
    /// absent: the first only says a tool finished (the next `PreToolUse` or `Stop` says
    /// more), and the second is already visible without hooks through the session file's
    /// `waitingFor: "permission prompt"`. Every subscription is one more HTTP call per
    /// occurrence, and one more non-blocking error line while the app is not running.
    public static let subscribed: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "StopFailure",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop",
        "TeammateIdle", "TaskCreated", "TaskCompleted", "SessionEnd",
    ]
}

/// What the hook channel knows about each session beyond the session file.
///
/// Thread-safe: the server writes from its network queue, the registry reads from its
/// actor. Bounded, and self-healing — every overlay is only ever used to *refine* what
/// the session file says (see `SessionState.refines`), so an event the app missed the
/// end of can at worst leave a stale detail on a session, never a wrong state.
public final class HookEventStore: @unchecked Sendable {

    public struct Overlay: Sendable, Equatable {
        public var lastEventAt: Date
        /// The tool the agent most recently started, and when.
        public var tool: (name: String, at: Date)?
        public var compactingSince: Date?
        /// Running subagents, by id, with when each started. Not cleared by `Stop`:
        /// subagents can run in the background past the end of the turn that launched
        /// them — observed live, where both of a pair outlived the parent's `Stop` and
        /// reported back as new turns.
        public var subagents: [String: Date] = [:]
        public var ending: Ending?

        public enum Ending: Sendable, Equatable {
            case completed(at: Date)
            case failed(kind: String, message: String?, at: Date)
        }

        public static func == (lhs: Overlay, rhs: Overlay) -> Bool {
            lhs.lastEventAt == rhs.lastEventAt
                && lhs.tool?.name == rhs.tool?.name && lhs.tool?.at == rhs.tool?.at
                && lhs.compactingSince == rhs.compactingSince
                && lhs.subagents == rhs.subagents
                && lhs.ending == rhs.ending
        }
    }

    private let lock = NSLock()
    private var overlays: [String: Overlay] = [:]
    private(set) public var lastEventAt: Date?
    /// Sessions beyond this are evicted oldest-first. A monitor left running for weeks
    /// must not grow without bound.
    private let capacity = 256

    public init() {}

    public func apply(_ event: HookEvent) {
        lock.lock()
        defer { lock.unlock() }
        lastEventAt = event.receivedAt

        if event.name == "SessionEnd" {
            overlays[event.sessionID] = nil
            return
        }

        var overlay = overlays[event.sessionID] ?? Overlay(lastEventAt: event.receivedAt)
        overlay.lastEventAt = event.receivedAt
        let now = event.receivedAt

        switch event.name {
        case "UserPromptSubmit":
            // A new turn. How the last one ended is history.
            overlay.ending = nil
            overlay.tool = nil
            overlay.compactingSince = nil
        case "PreToolUse":
            if let tool = event.toolName { overlay.tool = (tool, now) }
        case "Stop":
            overlay.ending = .completed(at: now)
            overlay.tool = nil
            overlay.compactingSince = nil
        case "StopFailure":
            overlay.ending = .failed(kind: event.error ?? "unknown",
                                     message: event.errorDetails ?? event.lastAssistantMessage,
                                     at: now)
            overlay.tool = nil
            overlay.compactingSince = nil
        case "PreCompact":
            overlay.compactingSince = now
        case "PostCompact":
            overlay.compactingSince = nil
        case "SessionStart":
            if event.source == "compact" { overlay.compactingSince = nil }
            if event.source == "clear" || event.source == "startup" {
                overlay = Overlay(lastEventAt: now)
            }
        case "SubagentStart":
            if let id = event.agentID { overlay.subagents[id] = now }
        case "SubagentStop":
            if let id = event.agentID { overlay.subagents[id] = nil }
        default:
            break
        }
        overlays[event.sessionID] = overlay

        if overlays.count > capacity,
           let oldest = overlays.min(by: { $0.value.lastEventAt < $1.value.lastEventAt })?.key {
            overlays[oldest] = nil
        }
    }

    public func overlay(for sessionID: String) -> Overlay? {
        lock.lock()
        defer { lock.unlock() }
        return overlays[sessionID]
    }

    /// Refines `session` with whatever the hook channel knows.
    ///
    /// - Compacting that has run for more than `compactionTimeout` is assumed to have
    ///   finished while we were not listening; a real one takes seconds to a minute.
    /// - A subagent that has not reported back within `subagentTimeout` is assumed to
    ///   have ended unobserved (the app was not running for its `SubagentStop`).
    public func refine(_ session: inout AgentSession, now: Date = Date(),
                       compactionTimeout: TimeInterval = 600,
                       subagentTimeout: TimeInterval = 2 * 3600) {
        guard let overlay = overlay(for: session.id) else { return }

        let running = overlay.subagents.values.filter { now.timeIntervalSince($0) < subagentTimeout }.count
        session.subagents = running
        if let since = overlay.compactingSince, now.timeIntervalSince(since) < compactionTimeout {
            session.refine(to: .compacting, since: since)
        }
        if running >= 2 {
            session.refine(to: .subagentSwarm)
        }
        if session.rawState == .busy, session.activity == nil, let tool = overlay.tool {
            session.activity = ToolCaption.caption(for: tool.name)
        }
        switch overlay.ending {
        case .completed(let at):
            session.refine(to: .doneSuccess, since: at)
        case .failed(let kind, let message, let at):
            session.refine(to: kind == "rate_limit" ? .rateLimited : .doneError, since: at)
            if session.state == .rateLimited || session.state == .doneError {
                session.problem = session.problem ?? message
            }
        case nil:
            break
        }
    }
}

/// Present-tense captions for tool names, for when the agent has not written its own.
enum ToolCaption {
    static func caption(for tool: String) -> String {
        switch tool {
        case "Bash": return "运行命令"
        case "Read": return "读文件"
        case "Edit", "MultiEdit": return "改代码"
        case "Write": return "写文件"
        case "Grep", "Glob": return "搜索代码"
        case "WebFetch", "WebSearch": return "查资料"
        case "Task", "Agent": return "派出子 agent"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "整理任务"
        case "AskUserQuestion": return "想问你一个问题"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "__")
                return "调用 \(parts.count > 1 ? String(parts[1]) : tool)"
            }
            return "使用 \(tool)"
        }
    }
}
