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
        public let rejected: [ClaudeSessionSource.Rejected]
        public let at: Date

        /// Whether anything a renderer would react to actually moved.
        ///
        /// Deliberately ignores `updatedAt`: an agent rewrites its session file on
        /// ordinary activity, and waking the pet for a timestamp it does not draw is
        /// exactly the kind of idle cost the energy budget is meant to exclude.
        func differsVisibly(from other: Snapshot) -> Bool {
            if attention.level != other.attention.level { return true }
            if attention.session?.id != other.attention.session?.id { return true }
            if sessions.count != other.sessions.count { return true }
            for (new, old) in zip(sessions, other.sessions) {
                if new.id != old.id
                    || new.state != old.state
                    || new.waitingFor != old.waitingFor
                    || new.displayName != old.displayName
                    || new.stateChangedAt != old.stateChangedAt {
                    return true
                }
            }
            return false
        }
    }

    private let source: ClaudeSessionSource
    private let escalator: AttentionEscalator
    /// Upper bound on time between liveness sweeps. Crashed sessions are invisible
    /// until one runs, so this is the worst-case lag on noticing a dead agent.
    private let maxReconcileInterval: TimeInterval
    /// Floor on timer sleeps, so a misconfigured policy can never spin.
    private let minReconcileInterval: TimeInterval

    /// Remembers which sessions we have already gone looking for a title for.
    ///
    /// Titles live in transcripts, which are large, slugged under an irreversible
    /// directory name, and only written once the model has something to name. So the
    /// lookup is comparatively expensive, frequently returns nothing early in a
    /// session, and must not be repeated on every scan.
    private struct TitleLookup {
        let title: String?
        let checkedAt: Date
    }

    private var titles: [String: TitleLookup] = [:]
    /// How long to wait before looking again for a title that was not there yet.
    private let titleRetryInterval: TimeInterval = 120

    private var watcher: DirectoryWatcher?
    private var reconcileTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var latest: Snapshot?
    private var isRunning = false

    public init(
        source: ClaudeSessionSource = ClaudeSessionSource(),
        escalator: AttentionEscalator = AttentionEscalator(),
        maxReconcileInterval: TimeInterval = 30,
        minReconcileInterval: TimeInterval = 1
    ) {
        self.source = source
        self.escalator = escalator
        self.maxReconcileInterval = maxReconcileInterval
        self.minReconcileInterval = minReconcileInterval
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
        startWatcherIfPossible()
        startReconcileLoop()
    }

    public func stop() {
        isRunning = false
        reconcileTask?.cancel()
        reconcileTask = nil
        watcher?.stop()
        watcher = nil
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    public var current: Snapshot? { latest }

    // MARK: - Scanning

    /// Rescans and publishes if anything visible moved. Safe to call at any time.
    @discardableResult
    public func refresh(now: Date = Date()) -> Snapshot {
        let result = source.scan(now: now)
        let sessions = result.sessions.map { enrich($0, now: now) }
        let snapshot = Snapshot(
            sessions: sessions,
            aggregate: result.aggregate,
            attention: escalator.assess(sessions: sessions, now: now),
            rejected: result.rejected,
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

    /// Attaches a title, looking one up only when we have not recently tried.
    private func enrich(_ session: AgentSession, now: Date) -> AgentSession {
        if let cached = titles[session.id] {
            // A title we already found will not change in a way worth re-reading a
            // transcript for; one we did not find might appear once the model names
            // the session, so that case is retried on a slow cadence.
            if cached.title != nil || now.timeIntervalSince(cached.checkedAt) < titleRetryInterval {
                return session.withTitle(cached.title)
            }
        }

        let title = ClaudeTranscript
            .url(forSessionID: session.id, in: source.locator)
            .flatMap { ClaudeTranscript.latestTitle(in: $0) }
        titles[session.id] = TitleLookup(title: title, checkedAt: now)

        // Drop entries for sessions that are gone, so a long-running monitor does not
        // accumulate one per session the machine has ever had.
        if titles.count > 256 {
            let live = Set(sessions(from: titles.keys))
            titles = titles.filter { live.contains($0.key) }
        }
        return session.withTitle(title)
    }

    private func sessions(from keys: Dictionary<String, TitleLookup>.Keys) -> [String] {
        guard let latest else { return Array(keys) }
        return latest.sessions.map(\.id)
    }

    // MARK: - Watching

    private func startWatcherIfPossible() {
        guard watcher == nil else { return }
        let watcher = DirectoryWatcher(url: source.locator.sessionsDirectory) { [weak self] paths in
            // Ignore anything that is not a session document: the directory also picks
            // up editor swap files and the occasional dotfile.
            guard paths.isEmpty || paths.contains(where: { $0.hasSuffix(".json") }) else { return }
            Task { await self?.handleFileEvent() }
        }
        if watcher.start() {
            self.watcher = watcher
        }
    }

    private func handleFileEvent() {
        guard isRunning else { return }
        refresh()
        // A file event may have changed what the ladder is counting down to, so the
        // sleeping timer's deadline is now stale.
        restartReconcileLoop()
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
        // Retry the watcher: the sessions directory does not exist until the user has
        // run an agent at least once, so a monitor launched first would otherwise stay
        // blind forever.
        startWatcherIfPossible()
        refresh()
    }

    /// Sleep exactly until the next thing that can happen on its own.
    private func nextReconcileDelay(now: Date = Date()) -> TimeInterval {
        var delay = maxReconcileInterval
        if let nextChange = latest?.attention.nextChange {
            delay = Swift.min(delay, nextChange.timeIntervalSince(now))
        }
        // A missing watcher means we are polling for the directory to appear; do not
        // let that stretch to the full liveness interval.
        if watcher == nil {
            delay = Swift.min(delay, 5)
        }
        return Swift.max(minReconcileInterval, delay)
    }
}
