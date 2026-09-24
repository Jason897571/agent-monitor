import Foundation

/// Finds a session's transcript and reads the model-generated title out of it.
///
/// Both halves are awkward for the same underlying reason: the project directory name
/// is a **lossy, irreversible** slug of the working directory — every character outside
/// `[A-Za-z0-9-]` collapses to one dash, so `短剧生成工作流` and `pp worker` are
/// unrecoverable. There is no way to compute a transcript path from a `cwd`, which
/// leaves searching by session id as the only correct option.
public enum ClaudeTranscript {

    /// Locates `projects/<slug>/<sessionId>.jsonl` without knowing the slug.
    ///
    /// One directory listing plus a stat per project. Cheap, but not free, which is
    /// why `SessionRegistry` caches the answer rather than asking on every scan.
    public static func url(forSessionID sessionID: String, in locator: ClaudeConfigLocator) -> URL? {
        let projects = locator.directory.appendingPathComponent("projects", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        for entry in entries {
            let candidate = entry.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The most recent `ai-title` in a transcript, if one has been written yet.
    ///
    /// Reads only the tail. Transcripts run to hundreds of megabytes in aggregate, and
    /// loading one to recover a short label would undo the whole point of a monitor
    /// that watches a single small directory. A title written long ago and never
    /// refreshed can fall outside the window — this is best-effort by construction,
    /// and callers already have `AgentSession.displayName` as a guaranteed label.
    public static func latestTitle(in url: URL, maxBytes: Int = 256 * 1024) -> String? {
        tail(of: url, maxBytes: maxBytes)?.title
    }

    /// Everything the monitor reads out of a transcript, from one pass over its tail.
    public struct Tail: Sendable, Equatable {
        /// The model-written session title.
        public var title: String?
        /// Claude Code's own recap for someone returning to the session, with the
        /// `(disable recaps in /config)` hint stripped. Only kept when it is newer than
        /// the last thing the user typed — once they are back, it is stale.
        public var recap: String?
        /// What the user last asked for.
        public var lastPrompt: String?
        /// How the most recent turn ended, if it has.
        public var ending: Ending?

        public enum Ending: Sendable, Equatable {
            /// The last word is the assistant's and it is not an error.
            case completed(at: Date)
            /// The turn died on an API error. `kind` is Claude Code's own error class
            /// (`rate_limit`, `server_error`, `authentication_failed`…).
            case apiError(kind: String, message: String?, at: Date)

            public var at: Date {
                switch self {
                case .completed(let at), .apiError(_, _, let at): return at
                }
            }
        }

        public init(title: String? = nil, recap: String? = nil, lastPrompt: String? = nil, ending: Ending? = nil) {
            self.title = title
            self.recap = recap
            self.lastPrompt = lastPrompt
            self.ending = ending
        }
    }

    /// Parses the last `maxBytes` of a transcript. `nil` if it cannot be read at all.
    ///
    /// Only lines that carry one of a handful of markers are decoded: the tail of an
    /// active transcript is mostly tool output, and JSON-decoding all of it on every
    /// refresh would be the most expensive thing this app does.
    public static func tail(of url: URL, maxBytes: Int = 256 * 1024) -> Tail? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return Tail() }

        var lines = [UInt8](data).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A non-zero offset almost certainly lands mid-line; that fragment is not JSON.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return parse(lines: lines)
    }

    static func parse(lines: [ArraySlice<UInt8>]) -> Tail {
        var tail = Tail()
        var recap: (text: String, at: Date?)?
        var endingDecided = false
        var lastPromptAt: Date?

        // Walk backwards: the newest occurrence of each thing is the one that matters,
        // and most of them are found within the last few lines.
        for line in lines.reversed() {
            if tail.title == nil, line.contains(Marker.title) {
                tail.title = decode(TitleLine.self, line)?.cleanTitle
            }
            if tail.lastPrompt == nil, line.contains(Marker.lastPrompt) {
                tail.lastPrompt = decode(PromptLine.self, line)?.cleanPrompt
            }
            if recap == nil, line.contains(Marker.recap),
               let entry = decode(Entry.self, line), entry.subtype == "away_summary",
               let text = entry.cleanRecap {
                recap = (text, entry.date)
            }
            if !endingDecided || lastPromptAt == nil,
               line.contains(Marker.assistant) || line.contains(Marker.user),
               let entry = decode(Entry.self, line), entry.isSidechain != true, entry.isMeta != true {
                // Only ever consulted for a session the file already calls idle, so the
                // turn is known to be over; the newest message says how it ended. An
                // error is its own assistant line. A user line on top — a prompt, or the
                // tool result of an interrupted call — means it was cut off, not ended.
                if !endingDecided {
                    endingDecided = true
                    if entry.type == "assistant" {
                        tail.ending = entry.isApiErrorMessage == true
                            ? .apiError(kind: entry.error ?? "unknown",
                                        message: entry.message?.firstText,
                                        at: entry.date ?? .distantPast)
                            : .completed(at: entry.date ?? .distantPast)
                    }
                }
                if lastPromptAt == nil, entry.type == "user", entry.message?.isToolResult != true {
                    lastPromptAt = entry.date ?? .distantPast
                }
            }
            if tail.title != nil, tail.lastPrompt != nil, recap != nil,
               endingDecided, lastPromptAt != nil { break }
        }

        // A recap describes the session as it was when the user stepped away. Once
        // they have typed something since, it is history, not news.
        if let recap {
            let userAt = lastPromptAt ?? .distantPast
            if (recap.at ?? .distantFuture) > userAt { tail.recap = recap.text }
        }
        return tail
    }

    // MARK: - Line shapes

    /// Cheap pre-filters so we only attempt JSON decoding on plausible lines.
    private enum Marker {
        static let title = Array(#""type":"ai-title""#.utf8)
        static let lastPrompt = Array(#""type":"last-prompt""#.utf8)
        static let recap = Array(#""subtype":"away_summary""#.utf8)
        static let assistant = Array(#""type":"assistant""#.utf8)
        static let user = Array(#""type":"user""#.utf8)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ line: ArraySlice<UInt8>) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(line))
    }

    private struct TitleLine: Decodable {
        let type: String
        let aiTitle: String?

        var cleanTitle: String? {
            guard type == "ai-title" else { return nil }
            return aiTitle?.trimmedNonEmpty
        }
    }

    private struct PromptLine: Decodable {
        let type: String
        let lastPrompt: String?

        var cleanPrompt: String? {
            guard type == "last-prompt" else { return nil }
            return lastPrompt?.trimmedNonEmpty
        }
    }

    private struct Entry: Decodable {
        let type: String
        let subtype: String?
        let timestamp: String?
        let isSidechain: Bool?
        let isMeta: Bool?
        let isApiErrorMessage: Bool?
        let error: String?
        let content: String?
        let message: Message?

        struct Message: Decodable {
            let content: Content?

            /// `content` is a plain string on typed user prompts and an array of blocks
            /// everywhere else.
            enum Content: Decodable {
                case text(String)
                case blocks([Block])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) {
                        self = .text(text)
                    } else {
                        self = .blocks((try? container.decode([Block].self)) ?? [])
                    }
                }
            }

            struct Block: Decodable {
                let type: String?
                let text: String?
            }

            var firstText: String? {
                switch content {
                case .text(let text): return text.trimmedNonEmpty
                case .blocks(let blocks): return blocks.first { $0.type == "text" }?.text?.trimmedNonEmpty
                case nil: return nil
                }
            }

            var isToolResult: Bool {
                guard case .blocks(let blocks) = content else { return false }
                return blocks.contains { $0.type == "tool_result" }
            }
        }

        var date: Date? { timestamp.flatMap(ClaudeTranscript.parseTimestamp) }

        /// Claude Code appends a settings hint to every recap; it is not part of it.
        var cleanRecap: String? {
            guard var text = content else { return nil }
            if let range = text.range(of: "(disable recaps in /config)") {
                text.removeSubrange(range)
            }
            return text.trimmedNonEmpty
        }
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension ArraySlice<UInt8> {
    /// Substring search over raw bytes — avoids decoding a whole JSONL line to UTF-8
    /// just to reject it.
    func contains(_ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, count >= pattern.count else { return false }
        let limit = count - pattern.count
        var index = 0
        while index <= limit {
            var matched = true
            for offset in 0..<pattern.count where self[startIndex + index + offset] != pattern[offset] {
                matched = false
                break
            }
            if matched { return true }
            index += 1
        }
        return false
    }
}
