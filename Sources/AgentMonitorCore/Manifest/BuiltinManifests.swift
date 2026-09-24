import Foundation

/// Manifests compiled into the app, so it works out of the box with no files to install.
///
/// Each one is a byte-for-byte copy of the file of the same name in `manifests/` at the
/// repository root — the copy contributors read and edit. A test holds the two equal.
enum BuiltinManifests {
    static let all: [String] = [codex]

    static let codex = #"""
{
  "schema": 1,
  "id": "codex",
  "displayName": "Codex",
  "home": { "env": "CODEX_HOME", "default": "~/.codex" },
  "processNames": ["codex"],
  "eventLog": {
    "files": "sessions/*/*/*/rollout-*.jsonl",
    "watch": "sessions",
    "maxAgeHours": 48,
    "tailBytes": 262144,
    "timestamp": "timestamp",
    "header": {
      "match": { "type": "session_meta" },
      "id": "payload.id",
      "cwd": "payload.cwd",
      "startedAt": "payload.timestamp",
      "origin": "payload.originator"
    },
    "states": [
      { "match": { "type": "event_msg", "payload.type": "task_started" }, "state": "busy" },
      { "match": { "type": "event_msg", "payload.type": "task_complete" }, "state": "doneSuccess",
        "ifPresent": "payload.error", "then": "doneError", "problem": "payload.error.message" },
      { "match": { "type": "event_msg", "payload.type": "turn_aborted" }, "state": "idle" },
      { "match": { "type": "event_msg", "payload.type": "exec_approval_request" }, "state": "awaitingPermission" },
      { "match": { "type": "event_msg", "payload.type": "apply_patch_approval_request" }, "state": "awaitingPermission" },
      { "match": { "type": "event_msg", "payload.type": "request_user_input" }, "state": "awaitingAnswer" }
    ],
    "context": {
      "match": { "type": "event_msg", "payload.type": "token_count" },
      "used": "payload.info.last_token_usage.input_tokens",
      "window": "payload.info.model_context_window"
    },
    "quota": {
      "match": { "type": "event_msg", "payload.type": "token_count" },
      "windows": [
        { "usedPercent": "payload.rate_limits.primary.used_percent",
          "resetsAt": "payload.rate_limits.primary.resets_at",
          "minutes": "payload.rate_limits.primary.window_minutes" },
        { "usedPercent": "payload.rate_limits.secondary.used_percent",
          "resetsAt": "payload.rate_limits.secondary.resets_at",
          "minutes": "payload.rate_limits.secondary.window_minutes" }
      ]
    },
    "title": { "index": "session_index.jsonl", "id": "id", "value": "thread_name" }
  },
  "liveness": {
    "processCwd": true,
    "hostProcess": { "argsContain": "app-server", "activeWithinMinutes": 30, "origins": ["Codex Desktop"] }
  }
}
"""#
}
