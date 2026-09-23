import Foundation
import Testing

@testable import AgentMonitorCore

/// A sandbox holding a fake `<config>/sessions` directory.
private struct Sandbox {
    let root: URL
    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    var locator: ClaudeConfigLocator { ClaudeConfigLocator(directory: root, source: .defaultPath) }

    init(createSessionsDirectory: Bool = true) throws {
        // Resolve symlinks: /tmp is a link to /private/tmp and FSEvents reports the
        // resolved path, so an unresolved root makes path comparisons confusing.
        root = URL(
            fileURLWithPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-monitor-tests-\(UUID().uuidString)").path
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createSessionsDirectory {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }
    }

    /// Writes a session document. `procStart` is deliberately omitted so liveness falls
    /// through to the injected inspector's process name rather than needing a real
    /// process with a matching start time.
    func write(pid: Int, status: String, statusUpdatedAt: Date = Date(), waitingFor: String? = nil) throws {
        var fields: [String] = [
            "\"pid\": \(pid)",
            "\"sessionId\": \"session-\(pid)\"",
            "\"cwd\": \"/tmp/project-\(pid)\"",
            "\"name\": \"project-\(pid)\"",
            "\"status\": \"\(status)\"",
            "\"statusUpdatedAt\": \(Int(statusUpdatedAt.timeIntervalSince1970 * 1000))",
            "\"updatedAt\": \(Int(statusUpdatedAt.timeIntervalSince1970 * 1000))",
        ]
        if let waitingFor { fields.append("\"waitingFor\": \"\(waitingFor)\"") }
        let json = "{\(fields.joined(separator: ", "))}"
        try json.write(to: sessions.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    func remove(pid: Int) throws {
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(pid).json"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Reports every pid as a live `claude`, so tests exercise scanning and watching
/// rather than the host's real process table.
private let allAlive: @Sendable (pid_t) -> ProcessInspector.Info? = { pid in
    ProcessInspector.Info(pid: pid, command: "claude", startTime: Date(timeIntervalSince1970: 0))
}

private let noneAlive: @Sendable (pid_t) -> ProcessInspector.Info? = { _ in nil }

private func makeRegistry(
    _ sandbox: Sandbox,
    inspector: @escaping @Sendable (pid_t) -> ProcessInspector.Info? = allAlive
) -> SessionRegistry {
    SessionRegistry(
        source: ClaudeSessionSource(locator: sandbox.locator, inspector: inspector),
        maxReconcileInterval: 2,
        minReconcileInterval: 0.2
    )
}

/// Waits for a snapshot satisfying `predicate`, or gives up.
private func waitForSnapshot(
    in stream: AsyncStream<SessionRegistry.Snapshot>,
    timeout: Duration = .seconds(10),
    matching predicate: @escaping @Sendable (SessionRegistry.Snapshot) -> Bool
) async -> SessionRegistry.Snapshot? {
    await withTaskGroup(of: SessionRegistry.Snapshot?.self) { group in
        group.addTask {
            for await snapshot in stream where predicate(snapshot) { return snapshot }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@Suite("session registry")
struct SessionRegistryTests {

    @Test("an empty sessions directory is dormant")
    func emptyDirectoryIsDormant() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }

        let registry = makeRegistry(sandbox)
        let snapshot = await registry.refresh()
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.aggregate == .dormant)
        #expect(snapshot.attention.level == .ignore)
        #expect(snapshot.attention.nextChange == nil)
    }

    @Test("subscribers get the current snapshot immediately")
    func subscribersGetCurrentStateImmediately() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write(pid: 4242, status: "busy")

        let registry = makeRegistry(sandbox)
        await registry.refresh()
        let stream = await registry.snapshots()

        let snapshot = await waitForSnapshot(in: stream) { !$0.sessions.isEmpty }
        #expect(snapshot?.sessions.first?.pid == 4242)
        await registry.stop()
    }

    /// The reason `kFSEventStreamCreateFlagFileEvents` is mandatory: agents rewrite
    /// session documents **in place**, and modifying a file inside a directory does not
    /// change that directory's mtime. A plain vnode watch sees nothing here.
    @Test("an in-place modification is noticed")
    func inPlaceModificationIsNoticed() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write(pid: 4242, status: "busy")

        let registry = makeRegistry(sandbox)
        let stream = await registry.snapshots()
        await registry.start()

        _ = await waitForSnapshot(in: stream) { $0.sessions.first?.state == .busy }
        try sandbox.write(pid: 4242, status: "waiting", waitingFor: "input needed")

        let snapshot = await waitForSnapshot(in: stream) { $0.sessions.first?.state == .waiting }
        #expect(snapshot?.sessions.first?.waitingFor == "input needed")
        #expect(snapshot?.attention.level == .makeAware)
        await registry.stop()
    }

    @Test("a new session file is picked up")
    func newSessionIsPickedUp() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }

        let registry = makeRegistry(sandbox)
        let stream = await registry.snapshots()
        await registry.start()

        _ = await waitForSnapshot(in: stream) { $0.aggregate == .dormant }
        try sandbox.write(pid: 777, status: "busy")

        let snapshot = await waitForSnapshot(in: stream) { $0.sessions.count == 1 }
        #expect(snapshot?.sessions.first?.pid == 777)
        #expect(snapshot?.aggregate == .active(.busy))
        await registry.stop()
    }

    /// A clean exit removes the file, which is a filesystem event. A *crash* leaves it
    /// behind — that case is covered by `deadProcessIsReconciled`.
    @Test("a removed session file returns the pet to dormant")
    func removedSessionGoesDormant() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write(pid: 888, status: "busy")

        let registry = makeRegistry(sandbox)
        let stream = await registry.snapshots()
        await registry.start()

        _ = await waitForSnapshot(in: stream) { $0.sessions.count == 1 }
        try sandbox.remove(pid: 888)

        let snapshot = await waitForSnapshot(in: stream) { $0.aggregate == .dormant }
        #expect(snapshot != nil)
        #expect(snapshot?.sessions.isEmpty == true)
        await registry.stop()
    }

    /// Process death produces no filesystem event at all, so only the reconcile timer
    /// can notice it. This is the case a watcher-only design silently gets wrong.
    @Test("a dead process is caught by reconciliation, not by file events")
    func deadProcessIsReconciled() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write(pid: 999, status: "busy")

        // The file stays on disk untouched, exactly as a crashed session leaves it.
        let alive = SessionRegistry(
            source: ClaudeSessionSource(locator: sandbox.locator, inspector: allAlive),
            maxReconcileInterval: 2, minReconcileInterval: 0.2
        )
        #expect(await alive.refresh().sessions.count == 1)

        let dead = SessionRegistry(
            source: ClaudeSessionSource(locator: sandbox.locator, inspector: noneAlive),
            maxReconcileInterval: 2, minReconcileInterval: 0.2
        )
        let snapshot = await dead.refresh()
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.aggregate == .dormant)
        #expect(snapshot.rejected.contains { $0.reason == .processGone })
    }

    /// The sessions directory does not exist until the user has run an agent once, so a
    /// monitor launched first must not give up permanently.
    @Test("a missing sessions directory is retried, not fatal")
    func missingDirectoryIsRetried() async throws {
        let sandbox = try Sandbox(createSessionsDirectory: false)
        defer { sandbox.cleanUp() }

        let registry = makeRegistry(sandbox)
        let stream = await registry.snapshots()
        await registry.start()

        _ = await waitForSnapshot(in: stream) { $0.aggregate == .dormant }

        try FileManager.default.createDirectory(at: sandbox.sessions, withIntermediateDirectories: true)
        try sandbox.write(pid: 555, status: "busy")

        let snapshot = await waitForSnapshot(in: stream) { $0.sessions.count == 1 }
        #expect(snapshot?.sessions.first?.pid == 555)
        await registry.stop()
    }

    /// Waking a renderer for a timestamp it does not draw is exactly the idle cost the
    /// energy budget exists to exclude.
    @Test("a write that changes nothing visible does not emit")
    func invisibleWriteDoesNotEmit() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let changed = Date()
        try sandbox.write(pid: 321, status: "busy", statusUpdatedAt: changed)

        let registry = makeRegistry(sandbox)
        let first = await registry.refresh()
        let second = await registry.refresh()
        #expect(first.differsVisibly(from: second) == false)

        try sandbox.write(pid: 321, status: "idle", statusUpdatedAt: changed.addingTimeInterval(1))
        let third = await registry.refresh()
        #expect(third.differsVisibly(from: second))
    }
}

@Suite("directory watcher")
struct DirectoryWatcherTests {

    @Test("refuses to start on a directory that does not exist")
    func refusesMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-monitor-absent-\(UUID().uuidString)")
        let watcher = DirectoryWatcher(url: missing) { _ in }
        #expect(watcher.start() == false)
        #expect(watcher.isRunning == false)
    }

    @Test("starting twice is harmless")
    func startingTwiceIsHarmless() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let watcher = DirectoryWatcher(url: sandbox.sessions) { _ in }
        #expect(watcher.start())
        #expect(watcher.start())
        watcher.stop()
        #expect(watcher.isRunning == false)
        watcher.stop()
    }
}
