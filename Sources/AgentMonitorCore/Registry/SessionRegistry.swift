import Foundation

/// The live view of every agent session, and what it currently deserves.
///
/// Two signals feed it, because neither is sufficient alone:
///
/// **File events** catch everything an agent writes — a state transition, a new
/// session, a clean exit (which removes the file). They are immediate and cheap.
///
/// **A reconcile timer** catches what the filesystem cannot tell us. A *crashed*
/// session leaves its file behind untouched, so process death produces no event at
/// all; only re-checking the pid reveals it. The timer is also what advances the
/// escalation ladder, since "has been waiting 90 seconds" is not a filesystem event
/// either.
///
/// The timer does not poll at a fixed rate. It sleeps until the exact instant the
/// attention level could next change, capped by a slow liveness sweep — so a machine
/// with one idle session wakes twice an hour rather than seven hundred times.
public actor SessionRegistry {

    public struct Snapshot: Sendable, Equatable {
        public let sessions: [AgentSession]
        public let aggregate: AggregateState
        public let attention: AttentionAssessment
        public let rejected: [RejectedSession]
        /// Plan usage per agent, where the agent reported it.
        public let quotas: [QuotaSnapshot]
        /// Agent teams led by a live session.
        public let teams: [AgentTeam]
        public let at: Date

        public init(sessions: [AgentSession], aggregate: AggregateState, attention: AttentionAssessment,
                    rejected: [RejectedSession] = [], quotas: [QuotaSnapshot] = [], teams: [AgentTeam] = [],
                    at: Date) {
            self.sessions = sessions
            self.aggregate = aggregate
            self.attention = attention
            self.rejected = rejected
            self.quotas = quotas
            self.teams = teams
            self.at = at
        }

        /// Whether anything a renderer would react to actually moved.
        ///
        /// Deliberately ignores `updatedAt`: an agent rewrites its session file on
        /// ordinary activity, and waking the pet for a timestamp it does not draw is
        /// exactly the kind of idle cost the energy budget is meant to exclude. Context
        /// use is compared in whole percent for the same reason.
        func differsVisibly(from other: Snapshot) -> Bool {
            if attention.level != other.attention.level { return true }
            if attention.session?.id != other.attention.session?.id { return true }
            if sessions.count != other.sessions.count { return true }
            for (new, old) in zip(sessions, other.sessions) {
                if new.id != old.id
                    || new.state != old.state
                    || new.waitingFor != old.waitingFor
                    || new.displayName != old.displayName
                    || new.stateChangedAt != old.stateChangedAt
                    || new.title != old.title
                    || new.activity != old.activity
                    || new.recap != old.recap
                    || new.problem != old.problem
                    || new.subagents != old.subagents
                    || new.team != old.team
                    || new.contextUsedPercent.map(Int.init) != old.contextUsedPercent.map(Int.init) {
                    return true
                }
            }
            if quotas.map({ $0.windows.map { "\($0.label)\(Int($0.usedPercent))" } })
                != other.quotas.map({ $0.windows.map { "\($0.label)\(Int($0.usedPercent))" } }) {
                return true
            }
            return teams != other.teams
        }
    }

    private let providers: [SessionProvider]
    private let escalator: AttentionEscalator
    /// Upper bound on time between liveness sweeps. Crashed sessions are invisible
    /// until one runs, so this is the worst-case lag on noticing a dead agent.
    private let maxReconcileInterval: TimeInterval
    /// Floor on timer sleeps, so a misconfigured policy can never spin.
    private let minReconcileInterval: TimeInterval

    /// The last scan of each provider, by agent. A file event from one agent rescans that
    /// agent only; the others' results are reused.
    private var scans: [String: ProviderScan] = [:]
    private var watchers: [String: DirectoryWatcher] = [:]
    private var pendingInvalidations: Set<String> = []
    /// Agents the user switched off. Their providers are neither scanned nor published.
    private var disabled: Set<String> = []
    private var invalidationTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var latest: Snapshot?
    private var isRunning = false

    public init(
        providers: [SessionProvider],
        escalator: AttentionEscalator = AttentionEscalator(),
        maxReconcileInterval: TimeInterval = 30,
        minReconcileInterval: TimeInterval = 1
    ) {
        self.providers = providers
        self.escalator = escalator
        self.maxReconcileInterval = maxReconcileInterval
        self.minReconcileInterval = minReconcileInterval
    }

    /// Claude Code only, without the optional feeds — the P0 read path.
    public init(
        source: ClaudeSessionSource = ClaudeSessionSource(),
        escalator: AttentionEscalator = AttentionEscalator(),
        maxReconcileInterval: TimeInterval = 30,
        minReconcileInterval: TimeInterval = 1
    ) {
        self.init(
            providers: [ClaudeProvider(source: source, statusline: nil)],
            escalator: escalator,
            maxReconcileInterval: maxReconcileInterval,
            minReconcileInterval: minReconcileInterval
        )
    }

    // MARK: - Lifecycle

    /// A stream of snapshots. The current one is delivered immediately on subscribe,
    /// so a renderer never has to render an empty frame while it waits.
    public func snapshots() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            if let latest { continuation.yield(latest) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        _ = refresh()
        startWatchersIfPossible()
        startReconcileLoop()
    }

    public func stop() {
        isRunning = false
        reconcileTask?.cancel()
        reconcileTask = nil
        invalidationTask?.cancel()
        invalidationTask = nil
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    public var current: Snapshot? { latest }

    /// Turns an agent's sessions on or off without rebuilding the registry.
    public func setEnabled(_ agent: AgentKind, _ enabled: Bool) {
        let changed = enabled ? disabled.remove(agent.rawValue) != nil : disabled.insert(agent.rawValue).inserted
        guard changed else { return }
        if enabled { scans[agent.rawValue] = nil }
        refresh()
    }

    // MARK: - Scanning

    /// Rescans every provider and publishes if anything visible moved.
    @discardableResult
    public func refresh(now: Date = Date()) -> Snapshot {
        for provider in providers where !disabled.contains(provider.agent.rawValue) {
            scans[provider.agent.rawValue] = provider.scan(now: now)
        }
        return publish(now: now)
    }

    /// Something outside the filesystem changed what `agent` would report — a hook event
    /// arrived. Coalesced: a burst of tool calls rescans once.
    public func invalidate(_ agent: AgentKind) {
        pendingInvalidations.insert(agent.rawValue)
        guard invalidationTask == nil else { return }
        invalidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.flushInvalidations()
        }
    }

    private func flushInvalidations() {
        invalidationTask = nil
        guard isRunning else { return }
        let agents = pendingInvalidations
        pendingInvalidations.removeAll()
        rescan(agents)
    }

    private func rescan(_ agents: Set<String>, now: Date = Date()) {
        for provider in providers where agents.contains(provider.agent.rawValue)
            && !disabled.contains(provider.agent.rawValue) {
            scans[provider.agent.rawValue] = provider.scan(now: now)
        }
        publish(now: now)
        // A change may have moved what the ladder is counting down to, so the sleeping
        // timer's deadline is now stale.
        restartReconcileLoop()
    }

    @discardableResult
    private func publish(now: Date) -> Snapshot {
        let results = providers
            .filter { !disabled.contains($0.agent.rawValue) }
            .compactMap { scans[$0.agent.rawValue] }
        let sessions = results.flatMap(\.sessions).sorted { $0.stateChangedAt > $1.stateChangedAt }
        let snapshot = Snapshot(
            sessions: sessions,
            aggregate: AggregateState(sessions: sessions),
            attention: escalator.assess(sessions: sessions, now: now),
            rejected: results.flatMap(\.rejected),
            quotas: results.compactMap(\.quota),
            teams: results.flatMap(\.teams),
            at: now
        )

        let shouldEmit = latest.map { snapshot.differsVisibly(from: $0) } ?? true
        latest = snapshot
        if shouldEmit {
            for continuation in continuations.values { continuation.yield(snapshot) }
        }
        return snapshot
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    // MARK: - Watching

    private func startWatchersIfPossible() {
        for provider in providers {
            for directory in provider.watchedDirectories where watchers[directory.path] == nil {
                let agent = provider.agent.rawValue
                let watcher = DirectoryWatcher(url: directory) { [weak self] _ in
                    Task { await self?.handleFileEvent(agent: agent) }
                }
                if watcher.start() {
                    watchers[directory.path] = watcher
                }
            }
        }
    }

    private func handleFileEvent(agent: String) {
        guard isRunning else { return }
        pendingInvalidations.insert(agent)
        guard invalidationTask == nil else { return }
        // Coalesce: an agent streaming a turn appends to its log many times a second.
        invalidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.flushInvalidations()
        }
    }

    // MARK: - Reconciling

    private func startReconcileLoop() {
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.nextReconcileDelay()
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self.reconcile()
            }
        }
    }

    private func restartReconcileLoop() {
        guard isRunning else { return }
        reconcileTask?.cancel()
        startReconcileLoop()
    }

    private func reconcile() {
        guard isRunning else { return }
        // Retry watchers: a directory does not exist until the user has run that agent
        // at least once, so a monitor launched first would otherwise stay blind forever.
        startWatchersIfPossible()
        refresh()
    }

    /// Sleep exactly until the next thing that can happen on its own.
    private func nextReconcileDelay(now: Date = Date()) -> TimeInterval {
        var delay = maxReconcileInterval
        if let nextChange = latest?.attention.nextChange {
            delay = Swift.min(delay, nextChange.timeIntervalSince(now))
        }
        // A disconnected session expires on a clock too.
        if latest?.sessions.contains(where: { $0.state == .disconnected }) == true {
            delay = Swift.min(delay, 60)
        }
        // The primary sessions directory missing means we are polling for it to appear;
        // do not let that stretch to the full liveness interval. Optional directories
        // (tasks, teams) are allowed to be absent for good.
        if let primary = providers.first?.watchedDirectories.first, watchers[primary.path] == nil {
            delay = Swift.min(delay, 5)
        }
        return Swift.max(minReconcileInterval, delay)
    }
}
