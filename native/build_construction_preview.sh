#!/usr/bin/env bash
# Build regolith_construction_preview GDExtension using linked godot-cpp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/native/regolith_construction_preview"
python -m SCons platform=macos target=template_debug arch=universal \
	precision=double build_library=no generate_bindings=no -j"$(sysctl -n hw.ncpu)"
echo "Built: addons/regolith_construction_preview/bin/libregolith_construction_preview.macos.template_debug.universal.dylib"
