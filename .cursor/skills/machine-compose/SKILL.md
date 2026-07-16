---
name: machine-compose
description: >-
  Compose a named actuator rig (drill arm: rotor+hinge+piston+drill) from a
  short phrase via MachineComposer in ~60s without asking the user. Use when
  the user asks to build/assemble/spawn a manipulator, drill arm, or similar
  machine.
---

# Machine compose

## Goal

User says e.g. «буровой манипулятор» / «длинная стрела с запястьем» → working
rig in ~60s. **Do not ask clarifying questions.** Fill gaps with defaults.

## Steps

1. Read `docs/cheatsheets/machine-compose.md` (short).
2. Map phrase → `MachineIntent` (`from_phrase` or `from_dict`).
   - v0 recipe: **drill_arm** only.
   - Tags: long/short reach, wrist/запястье.
3. Call `MachineComposer.compose` (headless) or `spawn_on_terrain_from_phrase`.
   - Never invent `origin_cell` / revision by hand.
4. If fail: one retry softening wrist/long; else report `error`/`failures`.
5. Verify: `./tests/run_one.sh test_machine_compose`.

## Do not

- Interrogate the user for missing tags.
- Free-search grid cells.
- Promise cranes/carousels/doors in v0 (unsupported_recipe).
- Reuse RoverComposer for actuator towers.
