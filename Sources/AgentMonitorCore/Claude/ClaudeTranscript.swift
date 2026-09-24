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
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A non-zero offset almost certainly lands mid-line; that fragment is not JSON.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard line.contains(titleMarker) else { continue }
            if let title = decodeTitle(Data(line)) { return title }
        }
        return nil
    }

    /// Cheap pre-filter so we only attempt JSON decoding on plausible lines.
    private static let titleMarker = Array(#""type":"ai-title""#.utf8)

    private struct TitleLine: Decodable {
        let type: String
        let aiTitle: String?
    }

    private static func decodeTitle(_ data: Data) -> String? {
        guard let line = try? JSONDecoder().decode(TitleLine.self, from: data),
              line.type == "ai-title",
              let title = line.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
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
