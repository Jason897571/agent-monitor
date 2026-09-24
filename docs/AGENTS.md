# Adding an agent

Agent Monitor reads agents through **manifests**: one JSON file per agent that says
where its sessions live on disk and how to read them. Adding an agent, or fixing one
after the agent ships a release that moves things around, means editing JSON, not
Swift.

The motivation is in DESIGN.md §4. The most expensive thing about any agent monitor is
keeping adapters working, and most of the monitors that stopped being maintained died
at exactly that point.

- **Built-in manifests** live in [`manifests/`](../manifests). Right now that is only
  [`codex.json`](../manifests/codex.json).
- **Your own manifests** go in `~/Library/Application Support/AgentMonitor/agents/`. The
  paw-print menu's "自定义 agent 清单…" item opens that folder. A file with the same `id`
  as a built-in one replaces it. A file that fails to parse is skipped and reported,
  and it never breaks the app. Manifests are read at launch.

Claude Code is the one agent that does not go through a manifest. Its liveness check
has to convert a UTC timestamp and cross-check the process start time, and its state
is refined from four separate sources. That does not fit in JSON. Everything else
should.

## The two shapes

Every CLI agent we have looked at stores its sessions in one of two ways.

### `eventLog`: one append-only JSONL file per session

This is how Codex works. The session's state is decided by the **newest** line that
matches one of your `states` rules. After the first read, only newly appended bytes are
parsed, so an agent that writes many lines a second costs almost nothing.

```jsonc
"eventLog": {
  "files": "sessions/*/*/*/rollout-*.jsonl",  // relative to home; * = one path component
  "watch": "sessions",                        // directory to watch for changes
  "maxAgeHours": 48,                          // older files are ignored entirely
  "tailBytes": 262144,                        // how much to read the first time
  "timestamp": "timestamp",                   // key path of each line's time (ISO 8601 or epoch)
  "header": {                                 // the first line of the file
    "match": { "type": "session_meta" },
    "id": "payload.id",
    "cwd": "payload.cwd",
    "startedAt": "payload.timestamp",
    "origin": "payload.originator"            // optional; see hostProcess below
  },
  "states": [
    { "match": { "type": "event_msg", "payload.type": "task_started" }, "state": "busy" },
    { "match": { "type": "event_msg", "payload.type": "task_complete" }, "state": "doneSuccess",
      "ifPresent": "payload.error", "then": "doneError", "problem": "payload.error.message" }
  ],
  "context": { "match": {…}, "used": "…input_tokens", "window": "…model_context_window" },
  "quota":   { "match": {…}, "windows": [ { "usedPercent": "…", "resetsAt": "…", "minutes": "…" } ] },
  "title":   { "index": "session_index.jsonl", "id": "id", "value": "thread_name" }
}
```

### `sessionFiles`: one JSON document per live session

This is how Claude Code's own session registry works. Each file carries a pid and a
status, and the agent rewrites it in place.

```jsonc
"sessionFiles": {
  "directory": "live",
  "pid": "pid", "id": "id", "cwd": "dir", "status": "phase",
  "statusMap": { "thinking": "busy", "asking": "awaitingPermission", "resting": "idle" },
  "startedAt": "started", "updatedAt": "updated", "name": "title", "waitingFor": "reason"
}
```

A status that is not in `statusMap` is **rejected**. It is never guessed. A new release
that adds a status should show up as "unknown status" in `agent-monitor-cli`, not get
quietly labelled idle.

## Key paths and matching

A key path is a dotted walk through a JSON object, for example
`payload.info.model_context_window`. Arrays are not indexed.

A `match` object is a set of key paths that must all hold exactly the given string.
Numbers compare by their string form.

## States

A rule's `state` is one of the values below. Anything more specific than the four
basic states counts as a *refinement* of one of them, and the monitor enforces that
relationship.

| State | Refines | Meaning |
|---|---|---|
| `busy` | — | working |
| `idle` | — | alive, nothing to do |
| `waiting` | — | blocked on the user, for some other reason |
| `shell` | — | user shelled out |
| `awaitingPermission` | waiting | allow/deny prompt |
| `awaitingAnswer` | waiting | a question for the user |
| `compacting` | busy | summarising its own context |
| `subagentSwarm` | busy | two or more subagents running |
| `contextCritical` | busy / idle | set automatically from `context` at ≥ 90% |
| `doneSuccess` | idle | the last turn finished |
| `doneError` | idle | the last turn failed |
| `rateLimited` | idle | the last turn was refused for quota |

When no rule has matched yet, the state is `idle`.

## Liveness

The files alone cannot tell you whether a session is still running. A finished session
and an idle one look the same on disk. So liveness is decided from running processes,
matched by `processNames` (the kernel's `p_comm`, which is truncated to 16 characters):

```jsonc
"processNames": ["codex"],
"liveness": {
  "processCwd": true,
  "hostProcess": { "argsContain": "app-server", "activeWithinMinutes": 30, "origins": ["Codex Desktop"] }
}
```

- **`processCwd`**: a CLI process owns the most recently written log whose `cwd` equals
  the process's working directory. Only logs written since the process started count.
  `/tmp` and `/private/tmp` are treated as the same directory.
- **`hostProcess`**: covers a long-running server that hosts many sessions, such as the
  app server behind a desktop app. Each of its sessions counts as live for a while
  after its last write. `origins` limits this to sessions whose header `origin` is in
  the list. Without it, a one-shot CLI run that finished a minute ago would be
  mistaken for a live session hosted by the app.
- **`sessionFiles`** manifests use the file's own `pid`.

Clicking a session's row in the card brings forward the app that owns the matched
process. For a hosted session, that app is the host.

## Checking your manifest

```sh
swift run agent-monitor-cli
```

The command prints every agent it loaded along with its home directory. It lists
manifests that failed to load, with the reason, at the top. Sessions from your agent
appear with its `id` in the first column. Rejected session files are listed at the
bottom, each with the reason it was rejected.

## What is verified for Codex

These were checked against Codex 0.154 on a real machine:
- the rollout layout
- `session_meta`, `task_started`, and `task_complete` (with and without `error`)
- `token_count` context and rate-limit fields
- `session_index.jsonl` titles
- the Desktop app's `originator`

The approval events (`exec_approval_request`, `apply_patch_approval_request`) and
`request_user_input` exist in the Codex binary. They have **not** yet been observed in a
rollout. If Codex does not persist them, those rules simply never match.
