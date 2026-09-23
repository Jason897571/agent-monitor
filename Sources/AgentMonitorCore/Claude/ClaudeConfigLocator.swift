import Foundation

/// Finds Claude Code's config directory.
///
/// Hardcoding `~/.claude` is the single most common way a third-party monitor shows an
/// empty dashboard to a heavy user: `CLAUDE_CONFIG_DIR` relocates *everything*, and the
/// people most likely to run a multi-agent monitor are exactly the ones who set it.
///
/// The wrinkle is that an app launched from Finder does **not** inherit the user's shell
/// exports, so reading our own environment is not enough. We therefore fall back to
/// asking a running `claude` process what its config dir is — which works because the
/// `claude` binary is not code-signing-restricted. See DESIGN.md §7.1 trap #1.
public struct ClaudeConfigLocator: Sendable {

    public enum Source: Sendable, Equatable {
        /// `CLAUDE_CONFIG_DIR` was set in our own environment.
        case ownEnvironment
        /// Recovered from a live `claude` process (pid included for diagnostics).
        case runningProcess(pid_t)
        /// Nothing told us otherwise; `~/.claude`.
        case defaultPath
    }

    public let directory: URL
    public let source: Source

    public init(directory: URL, source: Source) {
        self.directory = directory
        self.source = source
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeConfigLocator {
        if let raw = environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
            return ClaudeConfigLocator(directory: expand(raw), source: .ownEnvironment)
        }

        // Prefer the most recently started session: if the user has migrated their
        // config, newer processes carry the current value.
        let live = ProcessInspector.processes(matching: ClaudeProcess.commandNames)
            .sorted { $0.startTime > $1.startTime }
        for process in live {
            let env = ProcessInspector.environment(of: process.pid)
            if let raw = env["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
                return ClaudeConfigLocator(directory: expand(raw), source: .runningProcess(process.pid))
            }
        }

        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        return ClaudeConfigLocator(directory: fallback, source: .defaultPath)
    }

    /// `<config>/sessions` — the live per-process session registry.
    public var sessionsDirectory: URL {
        directory.appendingPathComponent("sessions", isDirectory: true)
    }

    private static func expand(_ raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }
}
