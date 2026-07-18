#!/usr/bin/env bash
# Run a single headless test scene with known-benign engine noise filtered out.
# Usage: tests/run_one.sh <test_name>   (e.g. tests/run_one.sh test_simulation_kernel)
# Optional: REGOLITH_TEST_TIMEOUT_SEC=20 (default) — hard kill hung scenes.
# Polls output and kills immediately on SCRIPT ERROR so agents do not sit on a
# dead scene until the full timeout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$(basename "${1:?usage: tests/run_one.sh <test_name>}" .tscn)"
TIMEOUT_SEC="${REGOLITH_TEST_TIMEOUT_SEC:-20}"

if [[ ! -f "$ROOT/scenes/$NAME.tscn" ]]; then
	echo "No such test scene: scenes/$NAME.tscn" >&2
	exit 2
fi

# Benign noise: headless render/audio stubs and exit-time leak reports.
NOISE='VK_KHR|[Vv]ulkan|ALSA|SDFGI|XDG|OpenGL API|Godot Engine v|ObjectDB instances leaked|Orphan StringName|RID allocations of type|Resources still in use at exit|leaked at exit'
FATAL='SCRIPT ERROR:|Parse Error:'

tmp="$(mktemp)"
godot_pid=""
cleanup() {
	if [[ -n "$godot_pid" ]] && kill -0 "$godot_pid" 2>/dev/null; then
		kill -KILL "$godot_pid" 2>/dev/null || true
		wait "$godot_pid" 2>/dev/null || true
	fi
	rm -f "$tmp"
}
trap cleanup EXIT

set +e
timeout --signal=KILL "${TIMEOUT_SEC}s" \
	"$ROOT/run.sh" --headless "res://scenes/$NAME.tscn" \
	>"$tmp" 2>&1 &
godot_pid=$!

fatal_seen=0
while kill -0 "$godot_pid" 2>/dev/null; do
	if grep -qE "$FATAL" "$tmp" 2>/dev/null; then
		fatal_seen=1
		kill -KILL "$godot_pid" 2>/dev/null || true
		break
	fi
	sleep 0.15
done
wait "$godot_pid" 2>/dev/null
godot_code=$?
godot_pid=""
set -e

output="$(cat "$tmp")"

if [[ $fatal_seen -eq 1 ]]; then
	echo "FAIL $NAME (script error)"
	grep -Ev "$NOISE" <<<"$output" | tail -40
	exit 1
fi

# timeout(1) exits 124; KILL often surfaces as 137.
if [[ $godot_code -eq 137 || $godot_code -eq 124 ]]; then
	echo "FAIL $NAME (timeout ${TIMEOUT_SEC}s)"
	grep -Ev "$NOISE" <<<"$output" | tail -40
	exit 1
fi

if [[ $godot_code -eq 0 ]] && grep -qE '[A-Z][A-Z0-9_-]*: PASS' <<<"$output"; then
	echo "PASS $NAME"
	exit 0
fi

echo "FAIL $NAME (exit $godot_code)"
grep -Ev "$NOISE" <<<"$output" | tail -60
exit 1
