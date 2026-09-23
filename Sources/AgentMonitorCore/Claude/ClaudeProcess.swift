import Foundation

/// Facts about the Claude Code process itself.
public enum ClaudeProcess {

    /// The `p_comm` values a Claude Code process can present.
    ///
    /// Beware a genuinely confusing discrepancy here: `ps -o comm=` prints `claude`,
    /// but that is `argv[0]`. The kernel's `p_comm` — what `sysctl` and `ps -o ucomm=`
    /// report — is **`claude.exe`** on an npm/Homebrew install, because the CLI ships
    /// as a Node single-file executable and `/opt/homebrew/bin/claude` is only a
    /// symlink to `.../claude-code/bin/claude.exe`. The native installer ships a real
    /// `claude` binary instead.
    ///
    /// Verified on macOS 26.2 against Claude Code 2.1.220.
    ///
    /// `node` is deliberately absent: it would match any Node process that inherited a
    /// recycled pid, which is exactly what this set is meant to rule out.
    public static let commandNames: Set<String> = ["claude", "claude.exe"]
}
