---
name: run-tests
description: >-
  Runs Regolith headless kernel tests from repo root. Use when the user asks to
  run tests, прогон тестов, run_tests, or verify kernel logic (pre-commit only
  when kernel code/tests changed; see AGENTS.md).
---

# Run Regolith Tests

## When to use

- User asks to run tests or validate before commit
- After changes to simulation-kernel logic (`scripts/simulation/`)
- User mentions `run_tests` or Definition of Done in AGENTS.md

Gameplay/HUD/presentation changes are NOT verified here — run the game
(Beckett: `play_scene` → `screenshot`/`game_logs`) per AGENTS.md «Верификация».

## Prerequisites

- Godot 4.8 — macOS: `/Applications/Godot.app`, `$GODOT`, `PATH`.
  **Windows (this machine):** `Y:\godot-engine\bin\` — custom double build
  (`godot.windows.editor.double.x86_64.console.exe` для headless,
  `.exe` без `.console` для редактора). `run.ps1` / `run.sh` ищут его первым;
  fallback — stock `Y:\Godot\Godot_v4.8-stable_win64*.exe`, затем `$GODOT` / `PATH`.
- Voxel GDExtension present: `addons/zylann.voxel/voxel.gdextension`
- First clone: `./run.sh --headless --import` or `.\run.ps1 --headless --import` once

## Windows без bash

Если `bash` недоступен, один тест напрямую:

```powershell
cd Y:\regolith
& Y:\godot-engine\bin\godot.windows.editor.double.x86_64.console.exe `
  --path Y:\regolith --headless res://scenes/test_<name>.tscn
```

Или через лаунчер: `.\run.ps1 --headless res://scenes/test_<name>.tscn`

## Commands

Run from repo root (`~/Desktop/regolith` / `Y:\regolith`).

| Goal | Command |
|------|---------|
| Kernel gate (only if kernel logic changed) | `./tests/run_tests.sh` |
| Single test, noise filtered | `./tests/run_one.sh test_simulation_kernel` |
| Everything incl. legacy gameplay scenes (slow) | `./tests/run_tests.sh --all` |
| Shader compile smoke | `./run.sh --headless res://scenes/main.tscn` |

While iterating, run only the one relevant test via `run_one.sh`; the full
gate runs once before "done"/commit.

## Test tiers

The kernel list (pure simulation logic: kernel, topology, graphs, resources,
projection parity) lives in `tests/run_tests.sh` as `KERNEL=()`. Legacy
physics/gameplay/UI scenes are in `EXTRA=()` and run only with `--all`.

## Agent workflow

1. `cd` to repo root
2. Iterate with `./tests/run_one.sh test_<name>` (never claim pass without executing)
3. **Do not wait on hung Godot.** `run_one.sh` hard-kills after
   `REGOLITH_TEST_TIMEOUT_SEC` (default 20s) and aborts immediately on
   `SCRIPT ERROR` / `Parse Error`. Headless suites preload
   `scripts/testing/headless_test_harness.gd` and call
   `_HeadlessTestHarness.arm_watchdog` so a stuck await still `quit(1)`.
   If a scene is still running past ~20s, treat it as FAIL and inspect the
   filtered output — do not sit on the process. New headless tests must arm
   the watchdog at suite start.
4. Before "done"/commit: `./tests/run_tests.sh` once **only if** the change
   touched simulation-kernel logic (or added/changed a kernel test). Skip for
   gameplay, bake, HUD, VFX, docs-only, etc. — use the matching DoD row in
   `AGENTS.md` instead.
5. On shader changes, also run the shader compile smoke
6. Report PASS/FAIL per scene; on failure, paste the filtered output that
   `run_one.sh` already prints (engine noise is stripped)
