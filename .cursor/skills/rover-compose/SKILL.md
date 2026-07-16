---
name: rover-compose
description: >-
  Compose a parametric rover from a short phrase (N wheels, long/short/wide/tall/low)
  via RoverComposer in ~60s without asking the user. Use when the user asks to
  build/assemble/spawn a rover variant.
---

# Rover compose

## Goal

User says e.g. «ровер на 6 колёс, длинный, низкий» → working rover in ~60s.
**Do not ask clarifying questions.** Fill gaps with defaults.

## Steps

1. Read `docs/cheatsheets/rover-compose.md` (short).
2. Map phrase → `RoverIntent` (`RoverIntent.from_phrase` or `from_dict`).
   - Supported `wheel_count`: **even 4..12**.
   - Tags: long/short, wide/narrow, tall/low, cockpit center, power side, «колбаса».
3. Call `RoverComposer.compose` (headless) or `spawn_on_terrain_from_phrase` (in game).
   - Never invent `origin_cell` / revision by hand.
4. If fail: one retry softening extreme tags; else report `error`/`failures`.
5. Verify kernel: `./tests/run_one.sh test_rover_compose`.
   In game: `./run.sh res://scenes/main.tscn` — rover near BaseSpawn from `demo_rover_phrase`.

## Do not

- Interrogate the user for missing size tags.
- Free-search grid cells.
- Promise ships/bases in this skill (rovers only).
