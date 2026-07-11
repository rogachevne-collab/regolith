---
name: run-tests
description: >-
  Runs Regolith headless PoC tests from repo root. Use when the user asks to run
  tests, прогон тестов, run_tests, verify PoC, or validate before commit.
---

# Run Regolith Tests

## When to use

- User asks to run tests or verify PoC
- Before commit when changes touch gameplay scripts, scenes, or shaders
- User mentions `run_tests`, PoC, or Definition of Done in AGENTS.md

## Prerequisites

- Stock Godot 4.5+ (`/Applications/Godot.app`, `$GODOT`, or `PATH`)
- Voxel GDExtension present: `addons/zylann.voxel/voxel.gdextension`
- First clone: `./run.sh --headless --import` once

## Commands

Run from repo root `~/Desktop/regolith`.

| Goal | Command |
|------|---------|
| All PoC tests | `./tests/run_tests.sh` |
| Single test | `./run.sh --headless res://scenes/test_cart_flat.tscn` |
| Shader compile smoke | `./run.sh --headless res://scenes/main.tscn` |
| Play | `./run.sh res://scenes/main.tscn` |

## Test inventory (7 scenes)

`tests/run_tests.sh` runs every `scenes/test_*.tscn` in lexicographic order.
Each test prints `POC*: PASS` and exits 0, or `POC*: FAIL` and exits 1.

| Scene | PoC |
|-------|-----|
| `test_cart_flat.tscn` | 1a — suspension settle |
| `test_cart_drive.tscn` | 1b — drive/brake |
| `test_cart_steering.tscn` | 1c — steering |
| `test_assembly.tscn` | 2 — assembly |
| `test_cart_rebuild.tscn` | 2 — rover rebuild |
| `test_wheel_detach.tscn` | 2 — wheel detach |
| `test_passenger.tscn` | 3 — passenger on moving grid |

## Agent workflow

1. `cd` to repo root
2. Run `./tests/run_tests.sh` (never claim pass without executing)
3. On shader changes, also run `./run.sh --headless res://scenes/main.tscn`
4. Report results in a table

## Report format

| Command | Exit code | Result |
|---------|-----------|--------|
| `./tests/run_tests.sh` | 0 | pass |

On failure, paste last 20 lines of output for each failed test.
