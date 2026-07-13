---
name: run-tests
description: >-
  Runs Regolith headless kernel tests from repo root. Use when the user asks to
  run tests, прогон тестов, run_tests, verify kernel logic, or validate before
  commit.
---

# Run Regolith Tests

## When to use

- User asks to run tests or validate before commit
- After changes to simulation-kernel logic (`scripts/simulation/`)
- User mentions `run_tests` or Definition of Done in AGENTS.md

Gameplay/HUD/presentation changes are NOT verified here — run the game
(Beckett: `play_scene` → `screenshot`/`game_logs`) per AGENTS.md «Верификация».

## Prerequisites

- Stock Godot 4.5+ (`/Applications/Godot.app`, `$GODOT`, or `PATH`)
- Voxel GDExtension present: `addons/zylann.voxel/voxel.gdextension`
- First clone: `./run.sh --headless --import` once

## Commands

Run from repo root `~/Desktop/regolith`.

| Goal | Command |
|------|---------|
| Kernel gate (default, pre-commit) | `./tests/run_tests.sh` |
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
3. Before "done": `./tests/run_tests.sh` once
4. On shader changes, also run the shader compile smoke
5. Report PASS/FAIL per scene; on failure, paste the filtered output that
   `run_one.sh` already prints (engine noise is stripped)
