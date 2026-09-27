# agent-monitor

A desktop pet that ambiently mirrors what your AI coding agents are doing.

Read [DESIGN.md](DESIGN.md) for what this is and why. [docs/RESEARCH.md](docs/RESEARCH.md)
holds the evidence behind every claim in it.

> Early, but it runs. The pet reads live Claude Code and Codex sessions and reacts to
> them. The character art is a placeholder, and the interactive features (P2) are not
> built.

## Build and run

```sh
swift build
swift run agent-monitor               # the pet
swift run agent-monitor --selftest    # …and dump what the window server actually thinks

swift run agent-monitor-cli           # one-shot: every live session the core can see
swift run agent-monitor-cli watch     # follow live, printing whenever the pet would change
swift run agent-monitor-cli watch --hooks   # …and receive Claude Code hooks, like the app

./scripts/test.sh                     # 172 tests
./scripts/measure.sh                  # CPU and memory per pet state
./scripts/package.sh 0.1.0            # dist/Agent Monitor.app + a drag-to-install DMG
```

The package is universal (Apple silicon and Intel) and **ad-hoc signed** — there is no
Developer ID behind it yet. It opens normally on the Mac that built it. A copy downloaded
onto another Mac is blocked by Gatekeeper until you allow it under System Settings →
Privacy & Security, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Agent Monitor.app"
```

The paw-print icon in the menu bar lets you switch between the pet and the notch bar,
quit, and turn on the two optional feeds below.

## Optional feeds

Without these, the app changes nothing on your machine. With nothing configured it
already recognises 9 of the 13 states. It tells a permission prompt apart from a
question, and it recognises:

- a finished turn
- a failed turn
- a turn that ran out of quota
- a crashed session

It also reads Codex. The two feeds below add the remaining states. Each one is opt-in,
shows a confirmation dialog that says exactly what it will change, backs up
`settings.json` first, and can be removed from the same menu.

- **Claude hook.** Appends 13 `type: "http"` hooks to `settings.json`, pointed at
  `127.0.0.1:47291`. They add three states: compacting, several subagents running, and
  which tool is running right now. The hooks load into running sessions immediately,
  with no restart. If the app is not running while a hook fires, Claude records a
  non-blocking hook error and carries on.
- **Quota and context.** Claude Code gives its status line command the plan's quota
  and the context-window usage. If your `statusLine` is empty, the app can fill it with
  a small script that saves a copy of those numbers. If the slot is already taken, the
  app never touches it. Instead it copies a one-line wrapper to your clipboard, and you
  paste it in front of your existing command yourself. Nothing is fetched from the
  Keychain or from any API.

Adding another agent means writing a JSON manifest, not Swift. See
[docs/AGENTS.md](docs/AGENTS.md).

## Settings

paw print → 设置… (⌘,). Changes apply immediately. There are four tabs:

- **外观.** The character and pet size. Pick an animation for each pose, or import
  one.
- **行为.** Pet or notch bar, whether and when it fades while asleep, captions, the
  hover delay for the card, and launch at login.
- **提醒.** Do-not-disturb (no sound, no captions; the pet still mirrors state), and
  an optional sound when an agent has been blocked on you long enough to escalate.
  It plays once per episode. A finished turn never makes a sound.
- **数据源.** Claude hooks, the quota feed, Codex on or off, and the custom manifests
  folder.

## Skins

You can swap the placeholder character for any set of animated GIFs, APNGs or PNGs.
Put them in a folder under `~/Library/Application Support/AgentMonitor/skins/` with a
`skin.json` — or do it all from paw print → 设置… → 外观 — then choose it from
paw print → 角色. Each of the ten poses maps to one
file, and any pose you leave out falls back to the nearest one you have. See
[docs/SKINS.md](docs/SKINS.md). Skins stay on your machine; they are not part of the
app or this repository.

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
    Claude/             Claude Code adapter (session files, transcript tail, tasks, teams, statusline)
    Hooks/              the optional hook channel: HTTP receiver, event store, settings.json edits
    Manifest/           declarative adapters; Codex is the first
    Attention/          the five-level escalation ladder, as data
    Presentation/       poses, fading, frame budget, power throttling
    Registry/           FSEvents + reconcile, snapshots out
    System/             sysctl process inspection, directory watching
  AgentMonitorApp/      the only target that touches AppKit
  AgentMonitorCLI/      a harness for verifying the read path against a real machine
manifests/              agent manifests (built into the app; your own go in ~/Library/…)
```

`AgentMonitorCore` has no UI dependency on purpose. The pet is meant to be one
renderer over a documented event stream, not the only way to consume it — see
DESIGN.md §8.

## Status

**Working.** P0 and P1 are complete.

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
- Thirteen states. Every source other than the session file can only *refine* what the
  file says, never contradict it. That rule is what keeps a stale hook event or an
  hour-old statusline sample from putting a session in the wrong state.
- Captions. A short bubble appears over the pet when what it has to say changes. The
  text is the agent's own: `activeForm` while it works, the `away_summary` recap once
  it stops.
- Codex, read passively from its rollout files through a manifest, including context
  use and plan quota. Sessions in the Codex desktop app are attributed to its app
  server.
- Agent teams. Teammates appear as small companions next to the pet, laid out by
  dependency depth. A teammate that is idle while its work is unblocked shows up as
  stalled.
- Quota. When a window crosses 90% the pet mentions it once, with the reset time, and
  after that it appears only in the card.
- 172 tests, several of which are regression locks on traps documented in DESIGN.md §7.

**Not built yet**

Original character art — the built-in one is still a placeholder, though any skin
replaces it — and everything in P2. The agent-team topology has only been
verified against synthetic data. See DESIGN.md §6.

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
