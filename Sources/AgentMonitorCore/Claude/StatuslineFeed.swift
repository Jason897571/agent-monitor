import Foundation

/// Quota and context numbers, read from what Claude Code already hands its status line.
///
/// Claude Code pipes a JSON document into the `statusLine` command after every assistant
/// message: model, `context_window.used_percentage`, and `rate_limits.five_hour` /
/// `seven_day` with reset times. That is the only sanctioned way to see plan usage —
/// reading the OAuth token out of the Keychain to ask the API directly would breach the
/// terms of service, and is a hard constraint on this project.
///
/// The slot holds one command, so there are two ways in:
///
/// - **Empty slot:** we fill it with `statusline`, which saves a copy and prints a short
///   line of its own.
/// - **Occupied slot:** we never touch it. The user gets `statusline-tee`, which saves a
///   copy and passes the input through, to put in front of their own command.
///
/// Either way a file per session lands in `directory`, and this type reads them.
public struct StatuslineFeed: Sendable {

    public let directory: URL
    public let binDirectory: URL

    /// Every script path contains this; it is how settings recognise our command.
    public static let scriptDirectoryMarker = "AgentMonitor/bin/"

    public init(supportDirectory: URL = StatuslineFeed.defaultSupportDirectory) {
        self.directory = supportDirectory.appendingPathComponent("statusline", isDirectory: true)
        self.binDirectory = supportDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    public static var defaultSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMonitor", isDirectory: true)
    }

    // MARK: - Reading

    public struct Sample: Sendable, Equatable {
        public let contextUsedPercent: Double?
        public let contextWindow: Int?
        public let quota: [QuotaWindow]
        public let sampledAt: Date
    }

    public func sample(for sessionID: String) -> Sample? {
        let url = directory.appendingPathComponent("\(sessionID).json")
        guard let data = try? Data(contentsOf: url),
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        return Self.parse(data, sampledAt: modified)
    }

    /// The account-wide quota, from whichever session reported most recently.
    public func latestQuota() -> QuotaSnapshot? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        let dated = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date)? in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return (url, date)
        }
        for (url, date) in dated.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let data = try? Data(contentsOf: url),
                  let sample = Self.parse(data, sampledAt: date), !sample.quota.isEmpty else { continue }
            return QuotaSnapshot(agent: .claudeCode, windows: sample.quota, sampledAt: date)
        }
        return nil
    }

    static func parse(_ data: Data, sampledAt: Date) -> Sample? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let context = root["context_window"] as? [String: Any]
        let used = (context?["used_percentage"] as? NSNumber)?.doubleValue
            ?? (context?["remaining_percentage"] as? NSNumber).map { 100 - $0.doubleValue }

        var windows: [QuotaWindow] = []
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let window = limits[key] as? [String: Any],
                  let percent = (window["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(QuotaWindow(label: label, usedPercent: percent, resetsAt: resets))
        }

        return Sample(
            contextUsedPercent: used,
            contextWindow: (context?["context_window_size"] as? NSNumber)?.intValue,
            quota: windows,
            sampledAt: sampledAt
        )
    }

    /// Drops samples for sessions that are long gone, so the directory stays small.
    public func prune(olderThan age: TimeInterval = 7 * 86_400, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }
        for url in files {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(date) > age else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Scripts

    public var statuslineScript: URL { binDirectory.appendingPathComponent("statusline") }
    public var teeScript: URL { binDirectory.appendingPathComponent("statusline-tee") }

    /// A shell-safe reference to a script, for putting in a command string.
    public static func quoted(_ url: URL) -> String {
        "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command to put in front of an existing status line, so both keep working.
    public func wrapped(_ existingCommand: String) -> String {
        "\(Self.quoted(teeScript)) | \(existingCommand)"
    }

    /// Writes both scripts. Idempotent; safe to call on every launch so an app update
    /// also updates the scripts.
    public func installScripts() throws {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (url, body) in [(teeScript, Self.teeBody), (statuslineScript, Self.statuslineBody)] {
            let text = Self.header(directory: directory) + body
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Shared by both scripts: save stdin under the session id, atomically.
    private static func header(directory: URL) -> String {
        """
        #!/bin/sh
        # Written by Agent Monitor. Saves the JSON Claude Code hands its status line, so the
        # monitor can show quota and context without asking anyone's API for them.
        dir=\(quoted(directory))
        input=$(cat)
        sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([A-Za-z0-9_-]*\\)".*/\\1/p' | head -n 1)
        if [ -n "$sid" ]; then
          mkdir -p "$dir" 2>/dev/null
          printf '%s' "$input" > "$dir/.$sid.tmp" 2>/dev/null && mv -f "$dir/.$sid.tmp" "$dir/$sid.json" 2>/dev/null
        fi

        """
    }

    /// Passes the input through untouched, for piping into the user's own command.
    private static let teeBody = """
        printf '%s' "$input"

        """

    /// A minimal status line of our own, for an empty slot. `plutil` rather than `jq`
    /// or `python3`: it is on every Mac without the Command Line Tools.
    private static let statuslineBody = """
        get() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
        out=$(get model.display_name)
        ctx=$(get context_window.used_percentage)
        five=$(get rate_limits.five_hour.used_percentage)
        [ -n "$ctx" ] && out="$out · 上下文 ${ctx%.*}%"
        [ -n "$five" ] && out="$out · 5h 额度 ${five%.*}%"
        printf '%s\\n' "$out"

        """
}
