import AgentMonitorCore
import AppKit

/// Finds and brings forward the app a session is running in — Ghostty, Cursor, iTerm.
///
/// App-level only: it raises the application, not the specific tab or split. Landing on
/// the exact pane is DESIGN.md §7.4's tiered problem and needs per-terminal adapters;
/// this is the tier that works everywhere and needs no permission.
@MainActor
enum HostApp {

    /// How the host was found. Surfaced so a wrong jump can be diagnosed.
    enum Source: String {
        case processTree = "process tree"
        case environment = "environment"
    }

    static func find(for pid: pid_t) -> (app: NSRunningApplication, source: Source)? {
        // Nearest ancestor that is an ordinary app. Helpers and daemons are skipped:
        // Cursor's integrated terminal sits under a "Cursor Helper" whose own parent is
        // the Cursor app the user actually recognises.
        for ancestor in ProcessInspector.ancestry(of: pid).dropFirst() {
            if let app = NSRunningApplication(processIdentifier: ancestor),
               app.activationPolicy == .regular {
                return (app, .processTree)
            }
        }

        // The tree can be cut: tmux reparents its server to launchd, and so does anything
        // run under a daemon. The agent's environment still remembers which app launched
        // it — `claude` is not code-signing-restricted, so it can be read.
        if let bundleID = ProcessInspector.environment(of: pid)["__CFBundleIdentifier"],
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.activationPolicy == .regular }) {
            return (app, .environment)
        }
        return nil
    }

    /// Brings the session's host app to the front. Returns `false` if none was found.
    ///
    /// Since macOS 14 activation is cooperative and a request from an app that is not
    /// itself active can be refused. Measured on this machine a plain `activate()` from
    /// the pet did work, so that is the first route — but it is verified, and if the app
    /// did not come forward, Launch Services is asked to open the already-running app,
    /// which only brings it to the front and is not subject to the same rule.
    @discardableResult
    static func activate(for session: AgentSession) -> Bool {
        guard let (app, _) = find(for: session.pid) else { return false }
        app.activate()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard NSWorkspace.shared.frontmostApplication != app, let url = app.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return true
    }
}
