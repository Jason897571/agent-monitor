import Foundation

/// One agent's adapter: turns whatever that agent leaves on disk into `AgentSession`s.
///
/// The registry owns providers and calls them only from its own actor, so a provider may
/// keep caches without locking — hence `@unchecked Sendable` on the conforming classes.
public protocol SessionProvider: AnyObject, Sendable {
    var agent: AgentKind { get }
    /// Directories whose changes should trigger a rescan of this provider. Keep them as
    /// narrow as possible: FSEvents is recursive — see `DirectoryWatcher`.
    var watchedDirectories: [URL] { get }
    func scan(now: Date) -> ProviderScan
}

public struct ProviderScan: Sendable, Equatable {
    public var sessions: [AgentSession]
    public var rejected: [RejectedSession]
    /// Plan usage, when the agent reported any.
    public var quota: QuotaSnapshot?
    /// Agent teams led by a live session.
    public var teams: [AgentTeam]

    public init(sessions: [AgentSession] = [], rejected: [RejectedSession] = [],
                quota: QuotaSnapshot? = nil, teams: [AgentTeam] = []) {
        self.sessions = sessions
        self.rejected = rejected
        self.quota = quota
        self.teams = teams
    }
}

/// A session record that did not become a live session, and why. Kept for diagnostics —
/// silent drops make an adapter impossible to debug against real machines.
public struct RejectedSession: Sendable, Equatable {
    public let agent: AgentKind
    public let file: String
    public let reason: String

    public init(agent: AgentKind, file: String, reason: String) {
        self.agent = agent
        self.file = file
        self.reason = reason
    }
}
