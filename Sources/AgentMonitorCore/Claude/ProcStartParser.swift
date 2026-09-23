import Foundation

/// Parses the `procStart` string Claude Code writes into `sessions/<pid>.json`.
///
/// **This is a trap.** The field looks like `ctime(3)` output — `"Wed Sep 23 09:16:28 2026"` —
/// and `ps -o lstart=` prints the same shape, so it is natural to compare the two as
/// strings when guarding against PID recycling. But the JSON is **UTC** while `ps` is
/// **local time**. On this machine (EDT, UTC-4) all 15 live sessions differ by exactly
/// four hours, so a string comparison rejects every one of them as a ghost — in every
/// timezone except UTC, and invisibly to anyone developing in UTC.
///
/// The fix is to parse as UTC and compare against the kernel's own start time from
/// `ProcessInspector`, which has no timezone at all. See DESIGN.md §7.1 trap #3.
public enum ProcStartParser {

    /// Interprets `raw` as UTC and returns the instant it denotes.
    public static func parse(_ raw: String) -> Date? {
        // `ctime` pads single-digit days with a second space ("Sun Sep  6 03:57:25 2026").
        // DateFormatter will not collapse that for us, so normalise first.
        let normalized = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: normalized)
    }

    /// Whether a `procStart` string plausibly describes the process actually holding `pid`.
    ///
    /// `procStart` has one-second resolution, hence the tolerance.
    public static func matches(_ raw: String, actualStart: Date, tolerance: TimeInterval = 2) -> Bool {
        guard let claimed = parse(raw) else { return false }
        return abs(claimed.timeIntervalSince(actualStart)) <= tolerance
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX locale so month and weekday names never depend on the user's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
}
