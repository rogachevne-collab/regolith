#!/usr/bin/env bash
# Ropes! addon test gate.
#
# Every test is run under a hard OS timeout, so a hung or crashed test is
# reported as a failure within seconds instead of spinning the engine
# forever. The harness (rope_test.gd) guarantees quit() on the normal path;
# this timeout covers the paths it cannot reach.
#
# Output STREAMS, and getting that right took two goes. The engine's stdout is
# NOT piped or captured anywhere — it is handed straight to the terminal, on
# purpose:
#
#   - capturing it (out=$(...)) buffers a whole test and prints it at the end,
#     which is twenty seconds of silence per test;
#   - piping it through a filter is barely better, because the engine then sees
#     a pipe rather than a terminal and its own C runtime switches to block
#     buffering. `grep --line-buffered` fixes the filter's end of that and does
#     nothing about the engine's.
#
# So the two banner lines the engine prints on startup are left in. They are
# the price of being able to tell a slow test from a hung one, and from the
# outside those two look identical — which is the one thing a gate exists to
# tell you.
#
# NOTE: this only helps when a human runs it in a terminal. Output captured by
# any tool that returns on completion still arrives in one lump; that is a
# property of the caller, not of this script.
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
	addons/ropes/tests/test_length_guard.gd
)

pass=0
fail=0
failed=()
started=$SECONDS

echo "Ropes! gate — ${#TESTS[@]} tests, ${LIMIT}s limit each"
echo "engine: $GODOT"
echo

n=0
for t in "${TESTS[@]}"; do
	n=$((n + 1))
	name=$(basename "$t")
	# Announced BEFORE the engine starts, so a test that never prints anything
	# is still attributable to a name rather than to a blank screen.
	printf '== [%d/%d] %s\n' "$n" "${#TESTS[@]}" "$name"
	t0=$SECONDS
	# No pipe, no capture — see the header. The engine inherits this terminal.
	timeout --foreground -k 5 "$LIMIT" \
		"$GODOT" --headless --path "$ROOT" -s "$t" 2>&1
	code=$?
	took=$((SECONDS - t0))
	case $code in
		0)
			pass=$((pass + 1))
			printf '   -> PASS (%ds)\n\n' "$took" ;;
		124 | 137)
			echo "   -> TIMEOUT: killed after ${LIMIT}s"
			echo "      (a test that prints its checks and then hangs is missing quit())"
			echo
			fail=$((fail + 1)); failed+=("$name [timeout]") ;;
		*)
			printf '   -> FAIL (exit %d, %ds)\n\n' "$code" "$took"
			fail=$((fail + 1)); failed+=("$name [exit $code]") ;;
	esac
done

echo "Summary: $pass passed, $fail failed in $((SECONDS - started))s"
if [[ $fail -gt 0 ]]; then
	printf 'Failed: %s\n' "${failed[*]}"
	exit 1
fi
exit 0
