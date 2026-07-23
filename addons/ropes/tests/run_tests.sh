#!/usr/bin/env bash
# Ropes! addon test gate.
#
# Every test is run under a hard OS timeout, so a hung or crashed test is
# reported as a failure within seconds instead of spinning the engine
# forever. The harness (rope_test.gd) guarantees quit() on the normal path;
# this timeout covers the paths it cannot reach.
#
# Usage: addons/ropes/tests/run_tests.sh
#   GODOT=/path/to/godot          override the engine binary
#   ROPES_TEST_TIMEOUT=120        override the per-test limit (seconds)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GODOT="${GODOT:-Y:/godot-engine/bin/godot.windows.editor.double.x86_64.console.exe}"
LIMIT="${ROPES_TEST_TIMEOUT:-90}"

TESTS=(
	addons/ropes/tests/test_catenary.gd
	addons/ropes/tests/test_free_fall.gd
	addons/ropes/tests/test_compliance.gd
	addons/ropes/tests/test_unilateral.gd
	addons/ropes/tests/test_drape.gd
)

pass=0
fail=0
failed=()

echo "Ropes! gate — ${#TESTS[@]} tests, ${LIMIT}s limit each"
echo

for t in "${TESTS[@]}"; do
	echo "== $(basename "$t")"
	out=$(timeout --foreground -k 5 "$LIMIT" \
		"$GODOT" --headless --path "$ROOT" -s "$t" 2>&1)
	code=$?
	echo "$out" | grep -vE '^Godot Engine|V-Sync mode|^[[:space:]]*$'
	case $code in
		0)
			pass=$((pass + 1)) ;;
		124 | 137)
			echo "  TIMEOUT: killed after ${LIMIT}s"
			fail=$((fail + 1)); failed+=("$(basename "$t") [timeout]") ;;
		*)
			fail=$((fail + 1)); failed+=("$(basename "$t") [exit $code]") ;;
	esac
	echo
done

echo "Summary: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
	printf 'Failed: %s\n' "${failed[*]}"
	exit 1
fi
exit 0
