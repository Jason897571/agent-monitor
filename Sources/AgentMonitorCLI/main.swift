import AgentMonitorCore
import Foundation

// A thin harness over the core so the read path can be verified against a real machine
// without building an app bundle.
//
//   swift run agent-monitor-cli          one-shot scan
//   swift run agent-monitor-cli watch    follow live, printing whenever the pet would change

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

func describe(_ level: AttentionLevel) -> String {
    switch level {
    case .ignore: return "ignore"
    case .changeBlind: return "change-blind"
    case .makeAware: return "make-aware"
    case .interrupt: return "INTERRUPT"
    case .demandAttention: return "DEMAND-ATTENTION"
    }
}

func format(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m" }
    if total < 86400 { return "\(total / 3600)h\((total % 3600) / 60)m" }
    return "\(total / 86400)d\((total % 86400) / 3600)h"
}

func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

func render(_ snapshot: SessionRegistry.Snapshot, verbose: Bool) {
    switch snapshot.aggregate {
    case .dormant:
        print("aggregate  : dormant  (pet sleeps)")
    case .active(let state):
        print("aggregate  : active(\(state.rawValue))")
    }

    let attention = snapshot.attention
    var line = "attention  : \(describe(attention.level))"
    if let session = attention.session { line += "  ← \(session.displayName)" }
    if let next = attention.nextChange {
        line += "  (next change in \(format(next.timeIntervalSince(snapshot.at))))"
    } else {
        line += "  (nothing scheduled)"
    }
    print(line)
    print("")

    if snapshot.sessions.isEmpty {
        print("no live sessions")
    } else {
        print("LIVE SESSIONS (\(snapshot.sessions.count))")
        print(String(repeating: "-", count: 104))
        print("  pid     state    in-state  attention      name                     cwd")
        print(String(repeating: "-", count: 104))
        let escalator = AttentionEscalator()
        for session in snapshot.sessions {
            let level = escalator.policy
                .rule(for: session.state)
                .level(afterTimeInState: session.timeInState(now: snapshot.at))
            let pid = String(session.pid).padding(toLength: 8, withPad: " ", startingAt: 0)
            let state = session.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let age = format(session.timeInState(now: snapshot.at))
                .padding(toLength: 10, withPad: " ", startingAt: 0)
            let attn = describe(level).padding(toLength: 15, withPad: " ", startingAt: 0)
            let name = session.displayName.padding(toLength: 25, withPad: " ", startingAt: 0)
            var row = "  \(pid)\(state)\(age)\(attn)\(name)\(session.cwd)"
            if let waitingFor = session.waitingFor { row += "  [\(waitingFor)]" }
            if session.isBridged { row += "  [bridged]" }
            print(row)
            if let title = session.title {
                print("  \(String(repeating: " ", count: 42))↳ \(title)")
            }
        }
    }

    if verbose, !snapshot.rejected.isEmpty {
        print("")
        print("REJECTED (\(snapshot.rejected.count))")
        print(String(repeating: "-", count: 104))
        for entry in snapshot.rejected {
            print("  \(entry.file.padding(toLength: 16, withPad: " ", startingAt: 0))\(describe(entry.reason))")
        }
    }
}

let arguments = Set(CommandLine.arguments.dropFirst())
let shouldWatch = arguments.contains("watch")

// stdout is block-buffered when it is not a terminal, so piping watch mode anywhere —
// `| tee`, a log file, another process — shows nothing until several kilobytes have
// accumulated. For a tool whose entire job is to report state as it changes, that
// looks like a hang. Line buffering costs nothing at this volume.
setvbuf(stdout, nil, _IOLBF, 0)

let locator = ClaudeConfigLocator.resolve()
print("config dir : \(locator.directory.path)")
print("resolved by: \(describe(locator.source))")
print("")

let registry = SessionRegistry(source: ClaudeSessionSource(locator: locator))

if shouldWatch {
    print("watching \(locator.sessionsDirectory.path) — Ctrl-C to stop")
    print("")
    let stream = await registry.snapshots()
    await registry.start()
    for await snapshot in stream {
        print("┌─ \(clock(snapshot.at)) ─────────────────────────────────────────────")
        render(snapshot, verbose: false)
        print("")
    }
} else {
    let snapshot = await registry.refresh()
    render(snapshot, verbose: true)
}
