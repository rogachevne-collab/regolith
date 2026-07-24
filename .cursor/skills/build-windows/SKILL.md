---
name: build-windows
description: >-
  Exports a playable Windows debug Regolith.exe via tools/export_windows_debug.ps1
  (custom Godot precision=double). Use when the user asks to build/export Windows
  exe, собрать билд, export Windows, or make a playable .exe.
---

# Build Windows (debug exe)

## When to use

- User asks to build / export / собрать билд / сделать exe
- Need a playable Windows package from the current tree

This is **gameplay export**, not kernel tests. Do not run `run_tests.sh` just for a build.

## Prerequisites

All must exist (script fails fast if missing):

| Path | Role |
|------|------|
| `Y:\godot-engine\bin\godot.windows.editor.double.x86_64.exe` | Editor (`$env:GODOT` overrides) |
| `Y:\godot-engine\bin\godot.windows.template_debug.double.x86_64.exe` | Custom double `template_debug` |
| `addons/zylann.voxel/bin/libvoxel.windows.editor.double.x86_64.dll` | Voxel double DLL |
| `export_presets.cfg` preset `"Windows Desktop"` | Export target |

If the template is missing, tell the user to build it (20–60+ min):

```text
cd Y:\godot-engine
python -m SCons platform=windows target=template_debug arch=x86_64 precision=double accesskit=no d3d12=no
```

Do **not** invent a stock Godot export — this project requires double precision + custom template paths in `export_presets.cfg`.

## Command

From repo root (`Y:\regolith`):

```powershell
.\tools\export_windows_debug.ps1
```

- Allow long runtime (export often ~20–120s; first import can be longer).
- Exit code must be 0; confirm `build/windows/Regolith.exe` exists.

## Output

| Artifact | Path |
|----------|------|
| Game | `build/windows/Regolith.exe` |
| Pack | `build/windows/Regolith.pck` |
| Console wrapper | `build/windows/Regolith.console.exe` |
| Native DLLs | `libvoxel…`, `libregolith_…` in the same folder |

Run from `build/windows/` so the `.pck` and DLLs sit next to the exe. Prefer `Regolith.console.exe` when diagnosing launch errors.

## Agent workflow

1. `cd` to repo root
2. Run `.\tools\export_windows_debug.ps1` (do not hand-roll `--export-debug` argv — preset name has a space; the script uses `cmd /c`)
3. On success: report full path to `Regolith.exe` and that siblings (`.pck`, DLLs) must stay alongside
4. On failure: paste the script error (missing editor/template/voxel DLL, or non-zero Godot exit). Fix prerequisites; do not switch to stock Godot templates
)
