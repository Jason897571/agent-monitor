import CoreServices
import Foundation

/// Watches one directory for file-level changes.
///
/// Two things make this fussier than it looks.
///
/// `kFSEventStreamCreateFlagFileEvents` is mandatory, not an optimisation. Session
/// files are rewritten **in place**, and modifying a file inside a directory does not
/// change that directory's mtime — so the obvious `DispatchSource` vnode watch on the
/// directory sees nothing at all when an agent goes busy → idle.
///
/// Scope must stay narrow. FSEvents is always recursive, so pointing this at the Claude
/// config directory instead of its `sessions` subdirectory would subscribe to roughly
/// half a gigabyte of transcript and tool-result churn — measured at 121 files touched
/// per hour, with the hot paths being spill files nobody wants to hear about. Watch the
/// smallest directory that answers the question.
public final class DirectoryWatcher: @unchecked Sendable {

    /// Retained by the FSEvents stream itself, so the callback can never outlive its
    /// handler even if the watcher is torn down on another thread.
    private final class Context: @unchecked Sendable {
        let handler: @Sendable ([String]) -> Void
        init(handler: @escaping @Sendable ([String]) -> Void) { self.handler = handler }
    }

    private let url: URL
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    /// - Parameter latency: coalescing window. Long enough to collapse the burst a
    ///   single agent write produces, short enough to stay imperceptible.
    public init(
        url: URL,
        latency: TimeInterval = 0.2,
        queue: DispatchQueue = DispatchQueue(label: "agent-monitor.watcher", qos: .utility),
        handler: @escaping @Sendable ([String]) -> Void
    ) {
        self.url = url
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { stream != nil }

    /// Starts watching. Returns `false` if the directory does not exist yet — the
    /// caller is expected to retry later rather than treat it as a hard failure, since
    /// the directory appears the first time the user runs an agent.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        let context = Context(handler: handler)
        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(context).toOpaque(),
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Context>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            context.handler(count > 0 ? paths : [])
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                // Deliver the first event of a burst immediately; only then apply
                // latency. Without this a state change waits out the full window.
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &streamContext,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            // FSEventStreamCreate did not take ownership, so balance the retain above.
            Unmanaged.passUnretained(context).release()
            return false
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }

        stream = created
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
