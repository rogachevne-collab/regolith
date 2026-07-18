#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

pick_godot() {
	if [[ -n "${GODOT:-}" && -x "$GODOT" ]]; then
		echo "$GODOT"
		return
	fi
	if [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
		echo "/Applications/Godot.app/Contents/MacOS/Godot"
		return
	fi
	# Windows (native / Git Bash / MSYS): prefer Y:\Godot 4.7.1
	for candidate in \
		"/y/Godot/Godot_v4.7.1-stable_win64_console.exe" \
		"/Y/Godot/Godot_v4.7.1-stable_win64_console.exe" \
		"Y:/Godot/Godot_v4.7.1-stable_win64_console.exe" \
		"Y:\\Godot\\Godot_v4.7.1-stable_win64_console.exe" \
		"/y/Godot/Godot_v4.7.1-stable_win64.exe" \
		"/Y/Godot/Godot_v4.7.1-stable_win64.exe" \
		"Y:/Godot/Godot_v4.7.1-stable_win64.exe" \
		"Y:\\Godot\\Godot_v4.7.1-stable_win64.exe"
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
	echo "Stock Godot 4.7+ not found." >&2
	echo "Install Godot 4.7.1 (Windows: Y:\\Godot\\) or set GODOT=/path/to/Godot" >&2
	exit 1
fi

if [[ ! -f "$ROOT/addons/zylann.voxel/voxel.gdextension" ]]; then
	echo "Missing GDExtension plugin at addons/zylann.voxel/" >&2
	echo "Download: https://github.com/Zylann/godot_voxel/releases/download/v1.6x/GodotVoxelExtension.zip" >&2
	exit 1
fi

cd "$ROOT"
echo "Using: $("$GODOT_BIN" --version)"
exec "$GODOT_BIN" --path "$ROOT" "$@"
