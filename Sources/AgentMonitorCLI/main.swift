import AgentMonitorCore
import Foundation

// A thin harness over the core so the read path can be verified against a real machine
// without building an app bundle. `swift run agent-monitor-cli`.

let locator = ClaudeConfigLocator.resolve()
let source = ClaudeSessionSource(locator: locator)
let result = source.scan()

func describe(_ source: ClaudeConfigLocator.Source) -> String {
    switch source {
    case .ownEnvironment: return "own environment"
    case .runningProcess(let pid): return "running claude process (pid \(pid))"
    case .defaultPath: return "default ~/.claude"
    }
}

func describe(_ reason: ClaudeSessionSource.Rejection) -> String {
    switch reason {
    case .unreadable(let message): return "unreadable: \(message)"
    case .processGone: return "process gone"
    case .commandMismatch(let command): return "pid recycled (now '\(command)')"
    case .startTimeMismatch: return "pid recycled (start time differs)"
    case .unknownStatus(let raw): return "unknown status '\(raw ?? "nil")'"
    }
}

func format(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m" }
    if total < 86400 { return "\(total / 3600)h\((total % 3600) / 60)m" }
    return "\(total / 86400)d\((total % 86400) / 3600)h"
}

print("config dir : \(locator.directory.path)")
print("resolved by: \(describe(locator.source))")
print("")

switch result.aggregate {
case .dormant:
    print("aggregate  : dormant  (pet sleeps)")
case .active(let state):
    print("aggregate  : active(\(state.rawValue))")
}
print("")

if result.sessions.isEmpty {
    print("no live sessions")
} else {
    print("LIVE SESSIONS (\(result.sessions.count))")
    print(String(repeating: "-", count: 96))
    print("  pid     state    in-state  name                     cwd")
    print(String(repeating: "-", count: 96))
    for session in result.sessions {
        let pid = String(session.pid).padding(toLength: 8, withPad: " ", startingAt: 0)
        let state = session.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
        let age = format(session.timeInState()).padding(toLength: 10, withPad: " ", startingAt: 0)
        let name = session.displayName.padding(toLength: 25, withPad: " ", startingAt: 0)
        var line = "  \(pid)\(state)\(age)\(name)\(session.cwd)"
        if let waitingFor = session.waitingFor { line += "  [\(waitingFor)]" }
        if session.isBridged { line += "  [bridged]" }
        print(line)
    }
}

if !result.rejected.isEmpty {
    print("")
    print("REJECTED (\(result.rejected.count))")
    print(String(repeating: "-", count: 96))
    for entry in result.rejected {
        print("  \(entry.file.padding(toLength: 16, withPad: " ", startingAt: 0))\(describe(entry.reason))")
    }
}
