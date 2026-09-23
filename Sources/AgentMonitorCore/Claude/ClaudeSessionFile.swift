import Foundation

/// One `sessions/<pid>.json` document, exactly as Claude Code writes it.
///
/// This surface is entirely undocumented, so every field except the four we genuinely
/// depend on is optional and unknown `status` values decode to `nil` rather than a
/// default. A future release that adds a state should make the pet show "unknown",
/// not quietly mislabel it.
public struct ClaudeSessionFile: Decodable, Sendable, Equatable {
    public let pid: pid_t
    public let sessionId: String
    public let cwd: String
    /// Epoch milliseconds.
    public let startedAt: Double?
    /// UTC, `ctime`-shaped. Parse with `ProcStartParser` — never compare as a string.
    public let procStart: String?
    public let version: String?
    public let peerProtocol: Int?
    public let kind: String?
    public let entrypoint: String?
    public let name: String?
    public let nameSource: String?
    public let status: String?
    public let waitingFor: String?
    /// Epoch milliseconds. No heartbeat — see `AgentSession.updatedAt`.
    public let updatedAt: Double?
    /// Epoch milliseconds, advanced only on a real state transition.
    public let statusUpdatedAt: Double?
    /// Non-nil when Remote Control / the claude.ai bridge is attached.
    public let bridgeSessionId: String?

    public static func decode(contentsOf url: URL) throws -> ClaudeSessionFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    }
}

extension ClaudeSessionFile {
    var startedAtDate: Date { Self.date(fromEpochMilliseconds: startedAt) }
    var updatedAtDate: Date { Self.date(fromEpochMilliseconds: updatedAt) }

    /// Falls back to `updatedAt` then `startedAt`, so the escalation clock always has
    /// *some* origin even on a partially written file.
    var stateChangedAtDate: Date {
        Self.date(fromEpochMilliseconds: statusUpdatedAt ?? updatedAt ?? startedAt)
    }

    private static func date(fromEpochMilliseconds value: Double?) -> Date {
        guard let value, value > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
