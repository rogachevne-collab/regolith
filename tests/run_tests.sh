#!/usr/bin/env bash
# Headless gate: run every res://scenes/test_*.tscn and aggregate PASS/FAIL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/run.sh"

if [[ ! -x "$RUN" ]]; then
	chmod +x "$RUN"
fi

SCENES=()
while IFS= read -r path; do
	SCENES+=("$path")
done < <(find "$ROOT/scenes" -maxdepth 1 -name 'test_*.tscn' -print | sort)

if [[ ${#SCENES[@]} -eq 0 ]]; then
	echo "No test scenes found in scenes/test_*.tscn" >&2
	exit 1
fi

pass=0
fail=0
failed=()

echo "Regolith headless tests (${#SCENES[@]} scenes)"
echo

for path in "${SCENES[@]}"; do
	name="$(basename "$path" .tscn)"
	printf '== %s ' "$name"

	set +e
	output="$("$RUN" --headless "res://scenes/$name.tscn" 2>&1)"
	code=$?
	set -e

	if [[ $code -eq 0 ]] && echo "$output" | grep -qE 'POC[0-9A-Z-]*: PASS'; then
		echo "PASS"
		pass=$((pass + 1))
	else
		echo "FAIL (exit $code)"
		fail=$((fail + 1))
		failed+=("$name")
		echo "$output" | tail -20
		echo
	fi
done

echo
echo "Summary: $pass passed, $fail failed"

if [[ $fail -gt 0 ]]; then
	printf 'Failed: %s\n' "${failed[*]}"
	exit 1
fi

exit 0
