# agent-monitor

A desktop pet that ambiently mirrors what your AI coding agents are doing.

Read [DESIGN.md](DESIGN.md) for what this is and why. [docs/RESEARCH.md](docs/RESEARCH.md)
holds the evidence behind every claim in it.

> Early. The state engine reads live Claude Code sessions; there is no pet yet.

## Build and run

```sh
swift build
swift run agent-monitor-cli           # one-shot: every live session the core can see
swift run agent-monitor-cli watch     # follow live, printing whenever the pet would change
./scripts/test.sh
```

Requires macOS 14+ and a Swift 6 toolchain. Xcode is **not** required — the Command
Line Tools are enough.

`scripts/test.sh` exists because of that: swift-testing ships inside the CLT but
SwiftPM does not wire it up there, so `swift test` needs three compensating flags on
a CLT-only machine. The script detects the situation instead of hardcoding it, and
passes nothing extra when a full Xcode is installed. Run it rather than `swift test`.

## Layout

```
Sources/
  AgentMonitorCore/     the state engine — no AppKit, deliberately
    Model/              AgentSession, SessionState, AggregateState
    Claude/             Claude Code adapter (config discovery, session files, liveness)
    System/             sysctl-based process inspection
  AgentMonitorCLI/      a harness for verifying the read path against a real machine
```

`AgentMonitorCore` has no UI dependency on purpose. The pet is meant to be one
renderer over a documented event stream, not the only way to consume it — see
DESIGN.md §8.

## Status

**Working**

- Resolves Claude Code's config directory, honouring `CLAUDE_CONFIG_DIR`, and falling
  back to reading it out of a running `claude` process when our own environment does
  not have it (a Finder-launched app inherits no shell exports).
- Reads `sessions/<pid>.json`, the undocumented per-process registry, and turns it
  into live sessions — no hooks installed, no TCC prompt, nothing in the agent's
  tool-call hot path.
- Verifies liveness properly: a pid that still exists, held by a process whose kernel
  start time matches the recorded one. Neither file age nor `updatedAt` is evidence of
  anything; there is no heartbeat.
- Follows changes live: FSEvents for what the filesystem can report, plus a reconcile
  timer for what it cannot — a *crashed* session leaves its file untouched, so process
  death produces no event at all.
- The attention ladder, as data: five levels, per-state rules that rise *and decay*,
  and a computed "when could this change on its own" deadline.
- 61 tests, several of which are regression locks on traps documented in DESIGN.md §7.

**Not built yet**

Both window modes, sprite rendering, Codex, and everything in P1/P2. See DESIGN.md §6.

**Measured**

Watching 14 live sessions, debug build: **0.083% of one core, 7.2 MB RSS** over a
60-second run. The timer does not poll — it sleeps until the exact instant some
session's attention level could change, and schedules nothing at all once they have
all settled. The rendering layer is where the energy budget will actually be spent.

## The two bugs worth knowing about

Both were found by running against a real machine rather than by reading docs, and both
fail silently and totally.

**`procStart` is UTC; `ps -o lstart=` is local.** Compare them as strings and you
reject every live session as a ghost — in every timezone except UTC, and invisibly to
anyone developing in UTC. On the development machine all 15 sessions differed by
exactly four hours. `ProcStartParser` exists solely to get this right, and two tests
lock it.

**The process is `claude.exe`, not `claude`.** `ps -o comm=` prints `argv[0]`; the
kernel's `p_comm` — what `sysctl` and `ps -o ucomm=` report — is `claude.exe` on an
npm/Homebrew install, because the CLI ships as a Node single-file executable and
`/opt/homebrew/bin/claude` is only a symlink. The native installer ships a real
`claude`. So the process name is a fallback guard, never a gate: an install variant we
have not enumerated must not blank the UI.
