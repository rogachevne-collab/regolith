# UI-* verification — BUG-HUNT-RC-2026-07-25

Read-only pass: static code review + mapping to existing headless tests. **No fixes, no playtest run.**

Scope: **UI-01 … UI-15** (`docs/BUG-HUNT-RC-2026-07-25.md` §3.6). No separate **HUD-*** IDs in the hunt doc (HUD mentions are cross-refs / PERF-H*).

Snapshot date: 2026-07-25.

---

## Summary counts

| Verdict | Count |
|---|---:|
| **CONFIRMED** (code proves hunt claim) | 13 |
| **PARTIAL** (claim overstated or incomplete) | 2 |
| **NEEDS_PLAYTEST** (user-visible effect / timing not provable headless) | 6 |
| **REFUTED** | 0 |
| **Total UI-* entries** | **15** |

Notes:

- **CONFIRMED** = mechanism in Evidence column matches current code.
- **NEEDS_PLAYTEST** is additive: 12 entries include exact repro steps; code path is clear but R2 forbids headless HUD proof. UI-01, UI-13, UI-14 are code-deterministic (optional in-game sanity only).
- **PARTIAL** entries still have a real defect; the hunt title/repro is imprecise.
- Existing headless tests (`test_hud_palette_layout`, `test_hud_inventory_transfer`, `test_control_actions`) cover palette layout, transfer payload, and control-terminal **kernel** snapshots — **none** assert UI-01…UI-15 behavior.

---

## Findings

### UI-01 · Drag инвентаря рвётся на `command_completed` — **CONFIRMED**

**Code:** `hud_inventory_grid.gd` `_on_command_completed` always calls `refresh()` → `apply_snapshot` → `_rebuild_grid()` (`queue_free` all slot children). Same unconditional `refresh()` in `hud_inventory_container_panel.gd`. `hud_terminal.gd` `_on_command_completed` calls `_refresh_panels()` → panel `apply_snapshot` → grid rebuild. Contrast: `hud_control_terminal.gd` `_refresh()` bails when `gui_is_dragging()` (lines 486–490).

**Headless:** none.

**Playtest:** optional — repro is deterministic from Godot DnD + node teardown; in-game confirms UX only.

---

### UI-02 · Seat tool-gate: only `is_in_vehicle()`, not seat meta — **CONFIRMED** (+ **NEEDS_PLAYTEST** timing)

**Code:** `tool_controller.gd` `_pressed_action` / `_physics_process` gate tools with `in_vehicle = is_in_vehicle()` only (lines 322–325, 676–679). `mouse_look.gd` `_is_in_vehicle()` also treats `control_seat_element_id` meta (lines 267–270). `world_command_gateway.gd` `ensure_local_seat_binding()` documents replica body recreate orphaning the player while gateway seat id remains (1602–1631). During that window meta can outlive valid `current_vehicle`.

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Coop guest (or host with forced snapshot recreate on a moving rover).
2. Sit **passenger_seat** (PAX).
3. Trigger body recreate (coop snapshot / reproject — e.g. structural change on rover).
4. Before `ensure_local_seat_binding()` runs (~next gateway tick), hold **LMB** (drill/build).
5. **Expected:** tool fires while camera still behaves seated (`mouse_look` meta path).

---

### UI-03 · `passenger: true` without archetype check — **CONFIRMED**

**Code:** `world_command_gateway.gd` `_resolve_passenger_seat` (1757–1759):

```gdscript
if bool(command.get("parameters", {}).get("passenger", false)):
    return true
```

Archetype check only on the non-parameter path (1762–1763). Used from `_toggle_control_seat` (1350).

**Headless:** none.

**NEEDS_PLAYTEST repro (coop guest):**

1. Compose rover with cockpit + guest joined.
2. Aim cockpit `control_seat`, send/interact with `toggle_control_seat` and **`parameters.passenger: true`** (malicious or buggy client).
3. **Expected:** seated as PAX on cockpit — freelook, no driver controls (`controls_permitted` false), exit with **E**.

---

### UI-04 · Feedback «E — сесть в кокпит» on wrong seats — **PARTIAL**

**Code:** `hud_feedback.gd` lines 91–99: `_is_terminal_target(hit)` → «E — открыть инвентарь» runs **before** generic `KIND_CONTROL_SEAT` → «E — сесть в кокпит». Stationary **`control_terminal`** with a terminal store gets the inventory prompt (correct). **`passenger_seat`** (no terminal store) falls through to «кокпит» (wrong copy; behavior is PAX sit, not pilot).

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. On foot, aim **`passenger_seat`** on a composed rover (≤4.5 m).
2. **Expected:** prompt «E — сесть в кокпит»; **E** enters PAX (no wheel/thrust).
3. Repeat on **`control_terminal`** base console — prompt should be «E — открыть инвентарь», not «кокпит».

---

### UI-05 · Debug spoil (`O`) not seat-gated — **CONFIRMED** `[спек]`

**Code:** `tool_controller.gd` `_update_debug_spoil_input` (720–736) runs after UI-window early-out but **without** `in_vehicle` / passenger check (contrast `_pressed_action` 695–711). `world_command_gateway.gd` `_debug_spawn_spoil` (644–660) has no seat/PAX gate. Spec: `COOP-HOST-V0.md` RC-2 / `COOP_SPIKE_PLAN.md` PAX = no dig/tools.

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Sit **passenger_seat** (PAX).
2. Hold **`debug_spawn_spoil`** (**O**).
3. **Expected:** spoil heap spawns at crosshair despite PAX tool ban on LMB.

---

### UI-06 · Hotkeys swallowed when `UIWindowStack.push` fails — **CONFIRMED**

**Code:** Exclusive stack (`ui_window_stack.gd` 6–8): second modal `push` returns `false`. All three handlers still call `set_input_as_handled()` after no-op open:

| File | Action | Pattern |
|---|---|---|
| `hud_terminal.gd` 258–265 | `toggle_inventory` | `open_solo()` may no-op; always `handled` |
| `hud_palette.gd` 254–257 | `toggle_palette` | `_toggle()` may return early; always `handled` |
| `hud_control_terminal.gd` 835–837 | `control_terminal_toggle` | `toggle()` may no-op; always `handled` |

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Open **Esc** settings (`player_settings_overlay` — exclusive).
2. Press **I** or **G** (or **K** in cockpit).
3. **Expected:** inventory/palette/terminal does **not** open; key does not reach gameplay (eaten).

---

### UI-07 · Hotbar hidden in seat blocks inventory remap — **CONFIRMED**

**Code:** `hud_toolbar.gd` 172–184: `visible = false` when `is_in_vehicle()` or control terminal open. Drag-drop remap targets toolbar slots that are not visible/available. Inventory open in PAX is allowed by spec.

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Sit **passenger_seat**.
2. **I** → open inventory.
3. Drag tool instance toward hotbar slots 1–3.
4. **Expected:** no drop target; bar hidden.

---

### UI-08 · K-terminal page keys ignore LineEdit focus — **CONFIRMED**

**Code:** `hud_control_terminal.gd` `_unhandled_input` 841–851: `toolbar_page_prev` / `toolbar_page_next` handled **before** `gui_get_focus_owner() is LineEdit` guard (850). Slot digit actions correctly sit after the guard.

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Open **K** terminal on rover.
2. Focus **rename** LineEdit; type text.
3. Press page prev/next bindings.
4. **Expected:** toolbar page changes while still editing.

---

### UI-09 · Close restores capture/gameplay without stack check — **CONFIRMED**

**Code:** `player_settings_overlay.gd` `close()` (70–73): always `set_gameplay_input_enabled(true)` + `MOUSE_MODE_CAPTURED`; no `UIWindowStack.any_open()` check. `hud_terminal.gd` / `hud_actuator_panel.gd` use deferred `_restore_gameplay_input_if_still_closed` (checks own `_open` only, not stack depth). Exclusive stack often masks the glitch (per hunt).

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Open **I** (inventory).
2. Open **Esc** settings on top (if stack allows — otherwise: open settings, then attempt second window).
3. Close **settings** while inventory still open (or rapid **Esc** / **I** alternation).
4. **Expected:** mouse captured + gameplay enabled while another modal still visible, or inverse flash.

---

### UI-10 · `V` vehicle camera ignores modals — **CONFIRMED**

**Code:** `mouse_look.gd` `_process` 77–78 polls `toggle_vehicle_camera` with no `UIWindowStack` / mouse-mode guard (comment 45–46 acknowledges HUD ordering issue).

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Sit driver seat.
2. Open **I** or **K** (mouse visible, gameplay input off).
3. Press **V**.
4. **Expected:** orbit mode toggles under open UI.

---

### UI-11 · Interact vs tools seat detection asymmetry — **CONFIRMED**

**Code:** `tool_controller.gd` `_target_for_action` (1682–1723): synthetic exit `KIND_CONTROL_SEAT` when seated via `is_in_vehicle()` **or** `control_seat_element_id` meta. `_pressed_action` uses only `is_in_vehicle()`. Same root as UI-02.

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Reproduce orphan-seat window (UI-02 repro steps 1–3).
2. Press **E** → exit path; **LMB** → tool world action still fires.
3. **Expected:** asymmetric behavior.

---

### UI-12 · PAX **K**: silent deny + input handled — **CONFIRMED**

**Code:** `hud_control_terminal.gd` `controls_permitted()` (357–365): false for passenger. `toggle()` (337–342) no-ops when not permitted. `_unhandled_input` (835–837) always `set_input_as_handled()` after `toggle()`. No toast on denied open (contrast fault bar on failed **commands**, 900–908).

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Sit **passenger_seat**.
2. Press **K**.
3. **Expected:** nothing opens, no feedback; key not passed elsewhere.

---

### UI-13 · Orbit pitch reset to 15° — **CONFIRMED**

**Code:** `mouse_look.gd` `_init_orbit_from_vehicle` (224–254): `_orbit_pitch = clampf(15.0, orbit_min_pitch, orbit_max_pitch)` always; called from `_set_orbit_mode(true)` (217–218) on every orbit **on**.

**Headless:** none.

**Playtest:** optional — purely deterministic camera math.

**Repro:** seated → **V** on → adjust pitch with mouse → **V** off → **V** on → pitch returns to 15°.

---

### UI-14 · Triple inventory rebuild per command — **CONFIRMED**

**Code:** On `command_completed` with dual terminal open: (1) `hud_inventory_grid` refresh/rebuild per panel grid, (2) `hud_inventory_container_panel` refresh, (3) `hud_terminal` `_refresh_panels` → both panels `apply_snapshot`. Each grid `apply_snapshot` → `_rebuild_grid()`. `hud_control_terminal` `_on_command_completed` only updates fault cell for **pending** terminal commands — not a fourth full inventory rebuild.

**Headless:** none.

**Playtest:** optional — perf/UX observation (lag on submit).

---

### UI-15 · Flight-look delta with stuck capture — **PARTIAL** `[?]`

**Code:** `mouse_look.gd` `_unhandled_input` 47–59: motion accumulates in `_flight_look_delta` when `MOUSE_MODE_CAPTURED` and `_is_flight_controls_active()`. No check of `is_gameplay_input_enabled()`. Depends on UI-09 leaving **CAPTURED** while modal/UI state disagrees — mechanism chain is plausible, not proven for attitude jerk.

**Headless:** none.

**NEEDS_PLAYTEST repro:**

1. Driver seat with gyros/flight controls enabled.
2. Trigger UI-09 stuck-capture (settings close while another window open).
3. Move mouse with apparent “UI closed” but capture still on.
4. Close UI fully.
5. **Expected:** one-frame attitude spike from accumulated `_flight_look_delta` (`consume_flight_look_delta` in `player_controller` 87–88).

---

## Headless test map

| Test | In `run_tests.sh` | Covers UI-*? |
|---|---|---|
| `test_hud_palette_layout` | yes | No — layout/labels/drag payload only |
| `test_hud_inventory_transfer` | no (util gate) | No — transfer math/payload |
| `test_control_actions` | yes | No — simulation snapshots / seat control kernel |
| `test_player_interaction` | yes (`--all`) | No — interaction hit logic, not HUD windows |

---

## Cross-refs (out of UI-* scope, HUD-related)

| ID | Note |
|---|---|
| **COOP-05** | HUD store/hotbar freeze on unreliable stream — coop, not UI-* |
| **COOP-09** | Dig soft-retry HUD silence — coop UX |
| **PERF-H01, H06, H10, H11** | HUD perf hot paths — PERF-*, not UI-* |
