# agent-monitor

A desktop pet that ambiently mirrors what your AI coding agents are doing.

Read [DESIGN.md](DESIGN.md) for what this is and why. [docs/RESEARCH.md](docs/RESEARCH.md)
holds the evidence behind every claim in it.

> Early, but it runs: the pet reads live Claude Code sessions and reacts to them.
> Character art is a placeholder; Codex and the interactive features are not built.

## Build and run

```sh
swift build
swift run agent-monitor               # the pet
swift run agent-monitor --selftest    # …and dump what the window server actually thinks

swift run agent-monitor-cli           # one-shot: every live session the core can see
swift run agent-monitor-cli watch     # follow live, printing whenever the pet would change

./scripts/test.sh                     # 98 tests
./scripts/measure.sh                  # CPU and memory per pet state
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
    Model/              AgentSession, SessionState, AggregateState, SessionSummary
    Claude/             Claude Code adapter (config, session files, liveness, titles)
    Attention/          the five-level escalation ladder, as data
    Presentation/       poses, fading, frame budget, power throttling
    Registry/           FSEvents + reconcile, snapshots out
    System/             sysctl process inspection, directory watching
  AgentMonitorApp/      the only target that touches AppKit
  AgentMonitorCLI/      a harness for verifying the read path against a real machine
```

`AgentMonitorCore` has no UI dependency on purpose. The pet is meant to be one
renderer over a documented event stream, not the only way to consume it — see
DESIGN.md §8.

## Status

**Working** — P0 is complete.

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
- A floating pet: a non-activating panel that joins every Space, never takes focus,
  never appears in Cmd-Tab, is click-through except on the character itself, and can be
  dragged and snapped to a screen edge. It sleeps when no agents are running, wakes
  when one starts, and fades — but only ever while asleep.
- A docked bar that welds to the notch, or hangs under the menu bar without one.
  **⌃⌥⌘P** switches between the two. Registered through Carbon, which needs no
  Accessibility permission — so the app still prompts for nothing at all.
- Animation from pre-rendered sprite frames, at a frame rate chosen per pose, capped
  by Low Power Mode and thermal pressure, and paused outright when nothing is visible.
- Position remembered per display, keyed by CGDisplay UUID rather than by index —
  `NSScreen.screens` order is not stable across a dock cycle.
- Session labels: a guaranteed short name, plus the model-written description of what
  the session is about when one can be found.
- Hover the pet or the docked bar for a card listing every session; click a row to
  bring forward the app it runs in (Ghostty, Cursor, iTerm…). App-level only — the
  right window of that app, not yet the exact tab or split.
- 98 tests, several of which are regression locks on traps documented in DESIGN.md §7.

**Not built yet**

Real character art, Codex, and everything in P1/P2. See DESIGN.md §6.

**Measured**

The state engine costs 0.083% of one core watching 14 live sessions. The pet costs
about 0.5% while animating at 24 fps, near zero once asleep and faded, and 0.09% while
the display is asleep.

Drawing the character live through Core Graphics cost 3.55% — pre-rendering the frames
and swapping `layer.contents` cut that ~7×. Absolute numbers are provisional: the
machine they were taken on had a load average of 17, and repeats of the same state
spread 6×. See DESIGN.md §5.

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
