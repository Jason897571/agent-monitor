import Foundation

/// A declarative description of how to read one agent's sessions off disk.
///
/// The single largest ongoing cost in this category is adapter upkeep: every agent
/// release breaks somebody's adapter, and the graveyard of abandoned monitors is mostly
/// adapters nobody had time to fix. So an adapter is data. A contributor adding an agent
/// writes one JSON file — no Swift, no build — and fixing one after an agent release is
/// a one-line diff a user can make locally. See DESIGN.md §4 and docs/AGENTS.md.
///
/// Two shapes of agent are covered, which between them describe every CLI agent
/// surveyed:
///
/// - **`eventLog`** — one append-only JSONL file per session, state recovered from the
///   newest event that means something (Codex rollouts).
/// - **`sessionFiles`** — one JSON document per live session, rewritten in place with a
///   pid and a status field (the shape of Claude Code's own registry).
public struct AgentManifest: Decodable, Sendable, Equatable {
    /// Bumped on incompatible changes to this format. Unknown versions are refused
    /// rather than half-understood.
    public let schema: Int
    public let id: String
    public let displayName: String
    public let home: Home
    /// Kernel process names (`p_comm`) the agent runs as.
    public let processNames: [String]
    public let eventLog: EventLog?
    public let sessionFiles: SessionFiles?
    public let liveness: Liveness?

    public static let supportedSchema = 1

    public struct Home: Decodable, Sendable, Equatable {
        /// Environment variable that relocates the agent's data, like `CODEX_HOME`.
        public let env: String?
        /// Where it lives otherwise. `~` is expanded.
        public let `default`: String
    }

    /// `{"type": "event_msg", "payload.type": "task_started"}`: every key path must hold
    /// exactly that string.
    public typealias Match = [String: String]

    public struct EventLog: Decodable, Sendable, Equatable {
        /// Relative to home. `*` matches one path component (or part of one).
        public let files: String
        /// Relative to home: the directory to watch for changes.
        public let watch: String
        /// Logs untouched for longer are not considered at all.
        public let maxAgeHours: Double
        /// How much of a log to read when first seen. After that only appended bytes.
        public let tailBytes: Int?
        /// Key path of each line's timestamp (ISO 8601).
        public let timestamp: String
        public let header: Header
        /// Checked in order against every line; the newest line matching any rule sets
        /// the state.
        public let states: [StateRule]
        public let context: ContextRule?
        public let quota: QuotaRule?
        public let title: TitleRule?
    }

    public struct Header: Decodable, Sendable, Equatable {
        public let match: Match
        public let id: String
        public let cwd: String
        public let startedAt: String?
        /// Key path of what started the session (`Codex Desktop`, `codex_exec`), for
        /// telling a host process's sessions from a CLI's.
        public let origin: String?
    }

    public struct StateRule: Decodable, Sendable, Equatable {
        public let match: Match
        /// A `SessionState` raw value.
        public let state: String
        /// If this key path holds anything non-null, use `then` instead.
        public let ifPresent: String?
        public let then: String?
        /// Key path of a human-readable reason, shown for error states.
        public let problem: String?
    }

    public struct ContextRule: Decodable, Sendable, Equatable {
        public let match: Match
        /// Key path of tokens in the context window now.
        public let used: String
        /// Key path of the window size.
        public let window: String
    }

    public struct QuotaRule: Decodable, Sendable, Equatable {
        public let match: Match
        public let windows: [QuotaWindowRule]
    }

    public struct QuotaWindowRule: Decodable, Sendable, Equatable {
        public let usedPercent: String
        /// Epoch seconds.
        public let resetsAt: String?
        /// Key path of the window length in minutes, used to label it (`5h`, `7d`).
        public let minutes: String?
        public let label: String?
    }

    public struct TitleRule: Decodable, Sendable, Equatable {
        /// JSONL file relative to home; the last line for an id wins.
        public let index: String
        public let id: String
        public let value: String
    }

    public struct SessionFiles: Decodable, Sendable, Equatable {
        /// Relative to home.
        public let directory: String
        public let pid: String
        public let id: String
        public let cwd: String
        public let status: String
        /// Agent status string → `SessionState` raw value. Unlisted statuses are rejected
        /// rather than guessed at.
        public let statusMap: [String: String]
        public let startedAt: String?
        public let updatedAt: String?
        public let name: String?
        public let waitingFor: String?
    }

    public struct Liveness: Decodable, Sendable, Equatable {
        /// A running process whose working directory equals the session's `cwd` owns the
        /// newest log for that directory — how a CLI agent is tied to its log.
        public let processCwd: Bool?
        /// A long-lived process hosting many sessions (an app server behind a desktop
        /// app): its sessions count as live while recently active.
        public let hostProcess: HostProcess?
    }

    public struct HostProcess: Decodable, Sendable, Equatable {
        public let argsContain: String
        public let activeWithinMinutes: Double
        /// Header `origin` values this host owns. Without it, a one-shot CLI run that
        /// finished a minute ago would pass for a session hosted by the app.
        public let origins: [String]?
    }

    public var kind: AgentKind { AgentKind(id, displayName: displayName) }

    // MARK: - Loading

    public enum LoadError: Error, Equatable {
        case unsupportedSchema(Int)
        case noSessionShape
    }

    public static func decode(_ data: Data) throws -> AgentManifest {
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
        guard manifest.schema == supportedSchema else { throw LoadError.unsupportedSchema(manifest.schema) }
        guard manifest.eventLog != nil || manifest.sessionFiles != nil else { throw LoadError.noSessionShape }
        return manifest
    }

    /// Built-in manifests, overridden by any user manifest with the same `id` in
    /// `directory`. A broken user manifest is skipped and reported, never fatal.
    public static func loadAll(userDirectory: URL = AgentManifest.userDirectory)
        -> (manifests: [AgentManifest], problems: [String]) {
        var byID: [String: AgentManifest] = [:]
        var problems: [String] = []
        for builtin in BuiltinManifests.all {
            do {
                let manifest = try decode(Data(builtin.utf8))
                byID[manifest.id] = manifest
            } catch {
                problems.append("built-in manifest: \(error)")
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: userDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "json" {
            do {
                let manifest = try decode(Data(contentsOf: file))
                byID[manifest.id] = manifest
            } catch {
                problems.append("\(file.lastPathComponent): \(error)")
            }
        }
        return (byID.values.sorted { $0.id < $1.id }, problems)
    }

    public static var userDirectory: URL {
        StatuslineFeed.defaultSupportDirectory.appendingPathComponent("agents", isDirectory: true)
    }
}

// MARK: - Key paths over decoded JSON

enum JSONPath {
    /// `payload.info.model_context_window` into a `JSONSerialization` tree.
    static func value(_ path: String, in object: Any) -> Any? {
        var current: Any? = object
        for key in path.split(separator: ".") {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[String(key)]
        }
        if current is NSNull { return nil }
        return current
    }

    static func string(_ path: String, in object: Any) -> String? {
        switch value(path, in: object) {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func double(_ path: String, in object: Any) -> Double? {
        switch value(path, in: object) {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    static func date(_ path: String, in object: Any) -> Date? {
        switch value(path, in: object) {
        case let string as String:
            return ClaudeTranscript.parseTimestamp(string)
        case let number as NSNumber:
            // Seconds or milliseconds since the epoch; the magnitude says which.
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
        default:
            return nil
        }
    }

    static func matches(_ match: AgentManifest.Match, _ object: Any) -> Bool {
        match.allSatisfy { string($0.key, in: object) == $0.value }
    }
}
