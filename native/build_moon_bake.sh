#!/usr/bin/env bash
# Build regolith_moon_bake GDExtension using Erebus godot-cpp (precompiled .a).
# Windows: use build_moon_bake.ps1 instead.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EREBUS_CPP="${EREBUS_CPP:-$HOME/Desktop/Erebus/thirdparty/godot-cpp}"
if [[ ! -f "$EREBUS_CPP/bin/libgodot-cpp.macos.template_debug.universal.a" ]]; then
	echo "Missing Erebus godot-cpp at $EREBUS_CPP" >&2
	exit 1
fi
if [[ ! -e "$ROOT/native/godot-cpp" ]]; then
	ln -s "$EREBUS_CPP" "$ROOT/native/godot-cpp"
fi
cd "$ROOT/native/regolith_moon_bake"
python3 -m SCons platform=macos target=template_debug arch=universal \
	build_library=no generate_bindings=no -j"$(sysctl -n hw.ncpu)"
echo "Built: addons/regolith_moon_bake/bin/libregolith_moon_bake.macos.template_debug.universal.dylib"
