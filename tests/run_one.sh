#!/usr/bin/env bash
# Run a single headless test scene with known-benign engine noise filtered out.
# Usage: tests/run_one.sh <test_name>   (e.g. tests/run_one.sh test_simulation_kernel)
# Optional: REGOLITH_TEST_TIMEOUT_SEC=20 (default) — hard kill hung scenes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$(basename "${1:?usage: tests/run_one.sh <test_name>}" .tscn)"
TIMEOUT_SEC="${REGOLITH_TEST_TIMEOUT_SEC:-45}"

if [[ ! -f "$ROOT/scenes/$NAME.tscn" ]]; then
	echo "No such test scene: scenes/$NAME.tscn" >&2
	exit 2
fi

# Benign noise: headless render/audio stubs and exit-time leak reports.
NOISE='VK_KHR|[Vv]ulkan|ALSA|SDFGI|XDG|OpenGL API|Godot Engine v|ObjectDB instances leaked|Orphan StringName|RID allocations of type|Resources still in use at exit|leaked at exit'

set +e
output="$(timeout --signal=KILL "${TIMEOUT_SEC}s" "$ROOT/run.sh" --headless "res://scenes/$NAME.tscn" 2>&1)"
code=$?
set -e

if [[ $code -eq 137 || $code -eq 124 ]]; then
	echo "FAIL $NAME (timeout ${TIMEOUT_SEC}s)"
	grep -Ev "$NOISE" <<<"$output" | tail -40
	exit 1
fi

if [[ $code -eq 0 ]] && grep -qE '[A-Z][A-Z0-9_-]*: PASS' <<<"$output"; then
	echo "PASS $NAME"
	exit 0
fi

echo "FAIL $NAME (exit $code)"
grep -Ev "$NOISE" <<<"$output" | tail -60
exit 1
