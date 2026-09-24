import Foundation

/// Reads a variable from the user's login shell.
///
/// An app opened from Finder or at login gets launchd's environment, not the one the
/// user's terminal builds from `.zshrc`, so an `export` there is invisible to it. The
/// usual fix — the one editors use to pick up a terminal's `PATH` — is to ask the shell
/// itself: run it interactively as a login shell and have it print the value.
///
/// Interactive shells print banners, prompts and warnings, so the value is fenced
/// between markers. And a shell config can block — a plugin prompting for an update —
/// so the whole thing is bounded by a timeout and then killed.
public enum LoginShell {

    public static func value(
        of name: String,
        shell: String = userShell,
        timeout: TimeInterval = 3
    ) -> String? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }

        let marker = "__AGENT_MONITOR_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '%s%s%s' '\(marker)' \"$\(name)\" '\(marker)'"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: marker)
        // "<noise>MARKER<value>MARKER<noise>"
        guard parts.count >= 3 else { return nil }
        let value = parts[parts.count - 2]
        return value.isEmpty ? nil : value
    }

    /// The account's shell from the user database — `$SHELL` may be absent for an app
    /// launched by launchd.
    public static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
