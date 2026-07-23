#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Bare ./run.sh opens the current visual test scene; pass args to override
# (e.g. ./run.sh res://scenes/main.tscn, or any other engine args).
DEFAULT_SCENE="res://addons/ropes/demos/avbd_shootout.tscn"

pick_godot() {
	if [[ -n "${GODOT:-}" && -x "$GODOT" ]]; then
		echo "$GODOT"
		return
	fi
	if [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
		echo "/Applications/Godot.app/Contents/MacOS/Godot"
		return
	fi
	# The voxel GDExtension in addons/zylann.voxel is built against a 4.8
	# double-precision build, so a stock release engine loads the project with
	# the extension disabled: EVERY script touching VoxelTool / VoxelBuffer
	# then dies with "Could not find type", and every test fails for a reason
	# that has nothing to do with the code under test. Prefer the matching
	# custom build; the stock candidates below are a last resort.
	for candidate in \
		"/y/godot-engine/bin/godot.windows.editor.double.x86_64.exe" \
		"/Y/godot-engine/bin/godot.windows.editor.double.x86_64.exe" \
		"Y:/godot-engine/bin/godot.windows.editor.double.x86_64.exe" \
		"/y/Godot/godot.windows.editor.double.x86_64.exe" \
		"Y:/Godot/godot.windows.editor.double.x86_64.exe"
	do
		if [[ -x "$candidate" || -f "$candidate" ]]; then
			echo "$candidate"
			return
		fi
	done
	# Windows (native / Git Bash / MSYS): stock Y:\Godot 4.8
	for candidate in \
		"/y/Godot/Godot_v4.8-stable_win64_console.exe" \
		"/Y/Godot/Godot_v4.8-stable_win64_console.exe" \
		"Y:/Godot/Godot_v4.8-stable_win64_console.exe" \
		"Y:\\Godot\\Godot_v4.8-stable_win64_console.exe" \
		"/y/Godot/Godot_v4.8-stable_win64.exe" \
		"/Y/Godot/Godot_v4.8-stable_win64.exe" \
		"Y:/Godot/Godot_v4.8-stable_win64.exe" \
		"Y:\\Godot\\Godot_v4.8-stable_win64.exe"
	do
		if [[ -x "$candidate" || -f "$candidate" ]]; then
			echo "$candidate"
			return
		fi
	done
	if command -v godot >/dev/null 2>&1; then
		command -v godot
		return
	fi
	echo ""
}

GODOT_BIN="$(pick_godot)"
if [[ -z "$GODOT_BIN" ]]; then
	echo "No Godot binary found." >&2
	echo "Expected the double-precision 4.8 build at Y:\\godot-engine\\bin\\ (it" >&2
	echo "matches addons/zylann.voxel), or set GODOT=/path/to/Godot" >&2
	exit 1
fi

if [[ ! -f "$ROOT/addons/zylann.voxel/voxel.gdextension" ]]; then
	echo "Missing GDExtension plugin at addons/zylann.voxel/" >&2
	echo "Download: https://github.com/Zylann/godot_voxel/releases/download/v1.6x/GodotVoxelExtension.zip" >&2
	exit 1
fi

cd "$ROOT"
echo "Using: $("$GODOT_BIN" --version)"
if [[ $# -eq 0 ]]; then
	exec "$GODOT_BIN" --path "$ROOT" "$DEFAULT_SCENE"
fi
exec "$GODOT_BIN" --path "$ROOT" "$@"
