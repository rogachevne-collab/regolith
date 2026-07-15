# One-shot game — from a one-line idea to a finished, polished game

> Entry-point pack for "make me a game" requests: expand a vague idea into a full GameSpec via defaults (never ask follow-ups), route to a genre blueprint, build phase-by-phase behind verify gates, finish with the juice pass. Written so a small model ships a good game by following recipes instead of planning.

## When to use
The user gives a short or vague game request ("make a platformer", "zombie game", "something fun"). Load this pack FIRST, then the one blueprint it routes to. Do NOT ask clarifying questions — every missing detail has a default below. State the expanded spec in one short message, then build.

## Step 1 — expand the idea into a GameSpec (silently, with defaults)
Fill every row; where the idea is silent, take the default. A finished small game beats an unfinished big one — never exceed the scope cap.

| Field | Default |
|---|---|
| Genre | closest blueprint below (unsure → top-down arena) |
| Camera | per blueprint (one fixed screen) |
| Controls | built-in `ui_left/ui_right/ui_up/ui_down/ui_accept` + mouse — NEVER define new InputMap actions |
| Core verb | exactly ONE: jump / shoot / dodge |
| Challenge | one enemy or hazard type + one spawner or difficulty ramp |
| Win/lose | score + death → Game Over panel → Retry restarts |
| Level | ONE screen (default viewport 1152×648), coordinates 0,0 → 1152,648 |
| UI | score label top-left + hidden game-over panel with a Retry button |
| Art | flat-color shapes with the palette below; no external assets |
| Juice | the mandatory pass in Step 4 |
| Scope cap | 60–90 seconds of fun, 3–5 scripts, ONE scene |

Theme reskin: a "zombie game" and a "space game" are the SAME blueprint — change only node names (Enemy→Zombie), accent colors, and shape sizes. Mechanics stay identical.

## Step 2 — route to a blueprint pack
| Idea keywords | load_skill name= |
|---|---|
| platformer, jump, mario, runner, climb, coins | game-platformer-2d |
| top-down, shooter, zombie, survival, arena, dodge, twin-stick, space | game-topdown-2d |
| anything else | the closer of the two, reskinned to the theme |

## Fastest path — scaffold, then reskin (preferred, esp. for small models)
For a platformer, ONE call writes the whole working game (scene + 4 scripts) and sets the main scene:
`apply_template template=platformer-2d` → then reskin names/colors to the theme (the Step 4 juice is already wired) → run the final gate. This skips fragile by-hand node assembly entirely. Build the spine manually (below) only for a genre with no template, or when you need a different structure. Run `apply_template` with no args to list templates.

## Step 3 — build spine (when there's no template, or you want full control)
- **P0 bootstrap** — `write_file` a minimal scene (`[gd_scene format=3]` + one root node), `open_scene`, then `set_project_setting setting=application/run/main_scene value=res://<your_scene>.tscn`. The param is **`setting`** (not `name`); the tool errors loudly if it is missing, so never assume a silent success — re-read it with `get_project_setting` if unsure.
- **P1 world** — background ColorRect first (never default gray), camera, arena/platform geometry.
- **P2 player + core verb** → GATE.
- **P3 challenge** — enemy/hazard + spawner → GATE.
- **P4 game loop** — score, death, game-over UI, restart → GATE (play, die on purpose, click Retry, confirm restart).
- **P5 juice pass** (Step 4) → final GATE: fresh 60 s playtest + screenshots.
`save_scene` before EVERY gate.

**Gate protocol (binary, never skip):** `play_scene` → `wait_until condition=game_connected` (it answers "not yet"? call it again — it caps each wait to keep the editor launching) → `simulate_input` the core verb → `screenshot` and LOOK at it → `assert_node_state` on what the phase added → `logs_read` (errors only) → `stop_scene`. A gate failing twice means: apply the blueprint's fallback row (simplify), do not keep debugging.

## Palette — flat shapes that read as deliberate design
| Role | Color |
|---|---|
| Background | `#1a1c2c` |
| Ground / walls | `#333c57` |
| Player | `#41a6f6` |
| Danger / enemy | `#ef7d57` |
| Pickup / score | `#ffcd75` |
| Text | `#f4f4f4` |
Rules: first node in the scene is a full-screen background ColorRect in `#1a1c2c`. One accent per role, used consistently. Make the player slightly bigger than feels necessary (readability). Cheap outline: a darker rect 2–3 px larger behind a shape. Diamonds are rotated squares (`rotation_degrees = 45`).

## Step 4 — juice pass (mandatory — this IS the quality)
Each item is a few lines in the blueprints; all use Tween / CPUParticles2D already shown there:
1. Core-verb feedback — tween the visual's `scale` to ~(1.15, 0.85) and back in ~0.1 s (jump squash / shoot kick). Set `pivot_offset` to the rect's center first.
2. Hit/death — flash `modulate` bright for 0.05 s, then tween back; shake `Camera2D.offset` ±8 px for ~0.15 s.
3. Pickup/kill — one-shot CPUParticles2D burst at the spot + score label pop (tween scale 1 → 1.3 → 1).
4. Game over — brief beat (~0.3 s timer) before pausing and showing the panel.
5. Nothing teleports — anything that moves accelerates/decelerates (`move_toward`, velocity, tween), never a bare `position =` jump.

## Quality bar — done means ALL of these
- Input responds immediately on play; the core verb feels instant.
- The player can die within ~10 s of mistakes, and Retry restarts cleanly (`get_tree().reload_current_scene()`).
- Score is visible and increases; every player action has visible feedback.
- Final 60 s playtest: `logs_read` shows no errors, nothing escapes the screen bounds, and the screenshot looks composed (palette applied, no default-gray anywhere).
- **Objective final gate (cannot be skipped or faked):** `assert_scene require_types=["CharacterBody2D","Area2D"] require_main_scene=true` returns `pass: true`. It reads the SAVED scene — confirms main_scene is set, node count is real, and the required types exist. If it returns `pass: false`, the game is NOT done: fix what its `reasons` list and build again.

## Rules for small models (anti-drift)
- **Never report a phase or the game "done" without proof from THIS session.** Do not describe gameplay (jumps, pickups, deaths) you have not just seen in a `screenshot` + `logs_read`, and do not claim success until `assert_scene` returns `pass: true`. A green result on `set_project_setting`/`save_scene` is NOT proof the game works — only the gate + `assert_scene` are.
- Copy the blueprint's scripts VERBATIM, then adapt names/numbers only. Never write GDScript from memory — anything beyond the blueprint, `describe_class` / `find_methods` first.
- One phase at a time; pass its gate before touching the next. Never refactor working code.
- Use `batch_execute` for each phase's node setup — it rolls back as one unit on failure.
- `validate_script` fails twice on the same script → re-copy from the blueprint; don't improvise a fix.
- Built-in `ui_*` actions only; never edit the InputMap (it needs serialized InputEvent objects — easy to corrupt, impossible to debug from logs).

Confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — APIs shift between Godot versions.
