#!/usr/bin/env bash
# Measure steady-state CPU and memory for each pet state.
#
# The app measures itself via `getrusage` and reports over a window that starts well
# after launch. Earlier versions of this script sampled `ps -o time=` from outside and
# were not trustworthy: that field resolves to 10 ms, which at these levels is the same
# order as the entire signal, and two consecutive runs produced 0.8% and 0.0% for the
# same state. Anything that disagrees with a process asking the kernel about itself is
# measuring the machine, not the app.
#
# The display must be awake. CADisplayLink stops delivering callbacks when the screen
# sleeps — correct, and a genuine power win, but it means an unattended benchmark
# silently measures an app that is doing nothing. `caffeinate -u` wakes the display and
# keeps it awake; `-d` only prevents future sleep and will not wake one already asleep,
# which cost an hour of confusion before this comment existed.
#
# Usage: scripts/measure.sh [sample-seconds]
set -euo pipefail

cd "$(dirname "$0")/.."

SAMPLE="${1:-20}"
DURATION=$((SAMPLE + 4))
EMPTY="$(mktemp -d)/empty-config"
mkdir -p "$EMPTY/sessions"
trap 'rm -rf "$(dirname "$EMPTY")"' EXIT

echo "building release…"
swift build -c release >/dev/null 2>&1
BINARY=".build/release/agent-monitor"

# Keep the display awake for the whole run, plus slack for the warm-up.
caffeinate -u -t $(( (DURATION + 4) * 4 + 30 )) &
CAFFEINATE=$!
trap 'kill "$CAFFEINATE" 2>/dev/null || true; rm -rf "$(dirname "$EMPTY")"' EXIT
sleep 3

# Discarded: the first run after a build competes with whatever the toolchain and
# Spotlight are still finishing.
CLAUDE_CONFIG_DIR="$EMPTY" "$BINARY" --selftest 8 --no-fade >/dev/null 2>&1 || true

run() {
    local label="$1" config="$2"; shift 2
    local output
    output=$(CLAUDE_CONFIG_DIR="$config" "$BINARY" --selftest "$DURATION" "$@" 2>&1)
    local pose fps cpu mem
    pose=$(sed -n 's/^  pose  *//p' <<<"$output")
    fps=$(sed -n 's/^  measured fps  *//p' <<<"$output")
    cpu=$(sed -n 's/^  cpu  *//p' <<<"$output")
    mem=$(sed -n 's/^  resident memory  *//p' <<<"$output")
    printf '  %-28s %-10s %-7s %-34s %s\n' "$label" "$pose" "$fps" "$cpu" "$mem"
}

echo "release build · ${SAMPLE}s sample, launch excluded, self-measured"
echo "--------------------------------------------------------------------------------------------------"
printf '  %-28s %-10s %-7s %-34s %s\n' "state" "pose" "fps" "cpu" "memory"
run "dormant, faded"     "$EMPTY"                              --fade-after 2
run "dormant, breathing" "$EMPTY"                              --no-fade
run "active"             "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" --no-fade
