import Foundation

/// One entry of Claude Code's task list: `$CLAUDE_CONFIG_DIR/tasks/<list>/<N>.json`.
///
/// The list is keyed by session id for a solo session and by team name once the session
/// starts a team — Claude Code moves the list across when that happens. `activeForm` is
/// the present-continuous label the model writes for itself (「对比方案」): literally a
/// ready-made caption for what the agent is doing.
public struct ClaudeTask: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let subject: String
    public let activeForm: String?
    /// The teammate that owns the task, by name. `nil` for the lead's own list.
    public let owner: String?
    public let status: Status
    public let blocks: [String]
    public let blockedBy: [String]

    public enum Status: String, Decodable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public init(
        id: String, subject: String, activeForm: String? = nil, owner: String? = nil,
        status: Status, blocks: [String] = [], blockedBy: [String] = []
    ) {
        self.id = id
        self.subject = subject
        self.activeForm = activeForm
        self.owner = owner
        self.status = status
        self.blocks = blocks
        self.blockedBy = blockedBy
    }

    enum CodingKeys: String, CodingKey {
        case id, subject, activeForm, owner, status, blocks, blockedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subject = try container.decode(String.self, forKey: .subject)
        activeForm = try container.decodeIfPresent(String.self, forKey: .activeForm)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        status = try container.decode(Status.self, forKey: .status)
        blocks = (try? container.decodeIfPresent([String].self, forKey: .blocks)) ?? []
        blockedBy = (try? container.decodeIfPresent([String].self, forKey: .blockedBy)) ?? []
    }

    /// The caption to show while this task is being worked on.
    public var caption: String { activeForm?.trimmedNonEmpty ?? subject }
}

/// A Claude Code agent team (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) as a graph: who is
/// on it, what each of them is doing, and who is waiting on whom.
///
/// Nobody else reads this. It is what the pet form factor exists for — a notch bar is one
/// dimension wide and cannot draw "this worker is idle although its work is unblocked".
/// See DESIGN.md §2 支点 D.
public struct AgentTeam: Sendable, Equatable {

    public struct Member: Sendable, Equatable, Identifiable {
        public let name: String
        public let agentType: String?
        public let isLead: Bool
        /// `in-process`, `tmux`, `iterm2`.
        public let backend: String?
        public var state: TeammateState
        /// What it is doing, when it is doing something.
        public var activity: String?
        /// Dependency depth of the work in front of it: 0 means nothing it holds waits on
        /// anyone. This is the horizontal position in the topology.
        public var depth: Int

        public var id: String { name }
    }

    public let name: String
    public let leadSessionId: String?
    public var members: [Member]
    public var tasks: [ClaudeTask]
    /// `from` must finish before `to` can start, aggregated from task edges.
    public var edges: [Edge]

    public struct Edge: Sendable, Equatable, Hashable {
        public let from: String
        public let to: String
    }

    /// Teammates idle although work is waiting for them — the state worth surfacing.
    public var stalled: [Member] { members.filter { $0.state == .stalled } }
}

public enum TeammateState: String, Sendable, Equatable {
    /// Holds an in-progress task.
    case working
    /// Everything it holds waits on someone else's task.
    case blocked
    /// Holds a task whose dependencies are all done, but is not working on it.
    /// Claude Code's own `TeammateIdle` event, cross-checked against `blockedBy`.
    case stalled
    /// Nothing assigned, or everything it had is done.
    case idle
}

/// Reads teams and task lists out of the Claude config directory.
public enum ClaudeTeams {

    /// Every task in one list, sorted by id so the order is stable.
    public static func tasks(list: String, in locator: ClaudeConfigLocator) -> [ClaudeTask] {
        let directory = locator.directory
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(list, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ClaudeTask.self, from: Data(contentsOf: $0)) }
            .sorted { (Int($0.id) ?? .max, $0.id) < (Int($1.id) ?? .max, $1.id) }
    }

    /// The caption for whatever a session is doing, from its own task list.
    ///
    /// `owner == nil` means the session that owns the list — the lead, for a team list,
    /// whose own tasks carry no owner (or an empty one). A teammate's in-progress task
    /// must never be captioned as the lead's work.
    public static func activity(in tasks: [ClaudeTask], owner: String? = nil) -> String? {
        let wanted = owner?.trimmedNonEmpty
        return tasks.first { $0.status == .inProgress && $0.owner?.trimmedNonEmpty == wanted }?.caption
    }

    /// Teams whose config is on disk, keyed by the session that leads them.
    public static func teams(in locator: ClaudeConfigLocator) -> [AgentTeam] {
        let root = locator.directory.appendingPathComponent("teams", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { entry in
            let configURL = entry.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let config = try? JSONDecoder().decode(TeamConfig.self, from: data)
            else { return nil }
            let tasks = tasks(list: entry.lastPathComponent, in: locator)
            return build(config: config, tasks: tasks)
        }
    }

    // MARK: - Graph

    struct TeamConfig: Decodable {
        let name: String
        let leadSessionId: String?
        let leadAgentId: String?
        let members: [MemberConfig]

        struct MemberConfig: Decodable {
            let agentId: String?
            let name: String
            let agentType: String?
            let backendType: String?
            let tmuxPaneId: String?
        }
    }

    static func build(config: TeamConfig, tasks: [ClaudeTask]) -> AgentTeam {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Depth of a task in the dependency DAG. Memoised, and cycle-safe: a malformed
        // list must degrade to a flat layout, never hang the monitor.
        var depthCache: [String: Int] = [:]
        func depth(of id: String, visiting: Set<String> = []) -> Int {
            if let cached = depthCache[id] { return cached }
            guard let task = byID[id], !visiting.contains(id) else { return 0 }
            let parents = task.blockedBy.map { depth(of: $0, visiting: visiting.union([id])) + 1 }
            let value = parents.max() ?? 0
            depthCache[id] = value
            return value
        }

        func isReady(_ task: ClaudeTask) -> Bool {
            task.blockedBy.allSatisfy { byID[$0]?.status == .completed || byID[$0] == nil }
        }

        let members = config.members.map { member -> AgentTeam.Member in
            let isLead = member.agentId != nil && member.agentId == config.leadAgentId
                || member.tmuxPaneId == "leader"
            // The lead's own tasks carry no owner.
            let owned = tasks.filter {
                $0.owner == member.name || (isLead && $0.owner?.trimmedNonEmpty == nil)
            }
            let open = owned.filter { $0.status != .completed }

            let state: TeammateState
            var activity: String?
            if let current = open.first(where: { $0.status == .inProgress }) {
                state = .working
                activity = current.caption
            } else if let ready = open.first(where: isReady) {
                state = .stalled
                activity = ready.subject
            } else if !open.isEmpty {
                state = .blocked
                activity = open.first?.subject
            } else {
                state = .idle
            }

            let relevant = open.isEmpty ? owned : open
            let memberDepth = isLead ? 0 : (relevant.map { depth(of: $0.id) }.min() ?? 0)
            return AgentTeam.Member(
                name: member.name, agentType: member.agentType, isLead: isLead,
                backend: member.backendType, state: state, activity: activity, depth: memberDepth
            )
        }

        // Member-level edges: A → B when one of B's tasks waits on one of A's.
        var edges: Set<AgentTeam.Edge> = []
        for task in tasks {
            guard let to = task.owner else { continue }
            for blocker in task.blockedBy {
                guard let from = byID[blocker]?.owner, from != to else { continue }
                edges.insert(AgentTeam.Edge(from: from, to: to))
            }
        }

        return AgentTeam(
            name: config.name,
            leadSessionId: config.leadSessionId,
            members: members,
            tasks: tasks,
            edges: edges.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        )
    }
}
