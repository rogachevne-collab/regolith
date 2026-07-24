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
5. Verify kernel: `./tests/run_one.sh test_rover_compose` (or Windows Godot headless
   `res://scenes/test_rover_compose.tscn`).
6. **TTX (numbers) — necessary, not sufficient:**
   - Run oneshot / read **`ROVER-LOAD-*`**: mass, CoM, axle loads, 0.5g/1.0g
     `wheelie_risk` / `nose_dive_risk`. Iterate phrase if flags trip.
7. **Visual review — required whenever decor / silhouette / «прикольный дизайн»
   changed (or user cares how it looks):**
   - Open `.\run.ps1 res://scenes/demo_rover_load.tscn`.
   - Walk fixed presets **1–5** (side / ¾ / front / rear / top) or ask human;
     with Beckett: screenshot each preset if MCP is up.
   - Judge: readable silhouette, no floating clutter, prow/skirts/mast/rack
     read as one composition, asymmetry intentional not broken.
   - **Do not claim “looks good” from green tests or load numbers alone.**
   - If only TTX was checked, say so explicitly when reporting.

## Do not

- Interrogate the user for missing size tags.
- Free-search grid cells.
- Promise ships/bases in this skill (rovers only).
- Treat green `test_rover_compose` or clean `ROVER-LOAD-*` as proof of look.
