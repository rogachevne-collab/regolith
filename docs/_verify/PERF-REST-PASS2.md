# PERF / CMP — adversarial second pass (credibility review)

Second-pass, read-only, code-level challenge of `docs/_verify/PERF-REST.md`
(pass 1: 21 CONFIRMED / 2 PARTIAL / 1 OUT_OF_SCOPE for `PERF-*` + `CMP-*`).
No fixes, no commits, no profiler run. Every row below was re-read against
the cited file/lines in the working tree; several were re-derived from
scratch (grep + `Read`) rather than trusting pass-1 prose.

Goal: separate "real bug / regression risk" from "hot path exists but no
broken behavior, or already-hedged stylistic smell" per user's adversarial
mandate. Frame-cost numbers are treated as **NOT_PROFILED** everywhere —
no `./run.sh` perf-monitor / profiler session was run in this pass either.

---

## 1. Revised summary counts

| Verdict | PERF | CMP | Total | Δ vs pass 1 |
|---|---|---|---|---|
| **CONFIRMED** | 8 | 11 | **19** | −2 |
| **PARTIAL** | 3 | 1 | **4** | +2 |
| **FALSE ALARM** | 0 | 0 | **0** | — |
| **OUT_OF_SCOPE** | 1 | 0 | **1** | — |

**Downgraded this pass: 2** (`PERF-H10` CONFIRMED→PARTIAL, `CMP-10` CONFIRMED→PARTIAL).
No item was upgraded, and no item flipped to FALSE ALARM — every pass-1
CONFIRMED reproduced cleanly at the cited lines on re-read; the two
downgrades are about **conditions of manifestation**, not fabricated
evidence.

---

## 2. `PERF-*` (12) — revised

| ID | Pass-1 | Pass-2 | Why |
|---|---|---|---|
| **PERF-H01** | CONFIRMED | **CONFIRMED** | Re-read `interaction_card.gd:13-31` + `interaction_index.gd:60-72`: `get_card()` calls `card.refresh()` unconditionally on every call (no gate by `topology_revision` at the *card* level — only the *structure* rebuild in `_ensure_element` is revision-gated). `refresh()` does `keys.clear()` then ~20-30 dict writes. Called from both `hud_target_panel._process` and `hud_reticle._process` while aiming (2×/frame). This is exactly the R9 anti-pattern (recompute every tick, no dirty flag on the derived read), not just "hot path exists" — the *bug* is literally the missing dirty gate. Real, not overstated. |
| **PERF-H02** | CONFIRMED | **CONFIRMED** | Re-read `industry_network_projection.gd:84-98`: unconditional per-wire-body loop, `_update_wire_body` → `_wire_points`, spline smooth (`CableCurveUtil.smooth_adaptive` / `_smooth_polyline`), `_update_wire_colliders` run even when `revision == _cached_network_revision`. Only `mesh_instance.mesh` write is gated by `_tube_path_changed`. Confirmed exactly as pass 1 described. |
| **PERF-H03** | CONFIRMED | **CONFIRMED** | Re-read `_physics_process` (`simulation_physics_projection.gd:271-306`): 7 tick passes + motion-capture loop every physics step; `_sorted_int_keys` re-sorts `_bodies` / `_wheel_constraints` / `_rotor_constraints` / `_piston_constraints` independently in at least 9 call sites (grep). Real, unconditional per-tick cost. Historical "200→30 FPS" claim correctly left **NOT_PROFILED** (no new measurement taken). |
| **PERF-H04** | OUT_OF_SCOPE | **OUT_OF_SCOPE** | Unchanged — RT explicitly excluded from this hunt round (hunt doc §0, B17). Not re-opened. |
| **PERF-H05** | CONFIRMED | **CONFIRMED** | Pattern (multiple `list_elements()`/`list_assemblies()` full-world scans per 4 Hz industry tick across `industry_electric_budget.gd`, `industry_simulation.gd`, `recipe_runner_service.gd`, `cargo_transfer_service.gd`) matches cited lines. Real O(world-size) work at fixed cadence; magnitude **NOT_PROFILED**, cost scales with yard size so risk is real but conditional on world size. |
| **PERF-H06** | PARTIAL | **PARTIAL** | Unchanged. `hud_control_terminal.gd` already has `_refresh_open_live_only` O(1) path (`547-608`) and a cheaper closed-bar snapshot (`507-529`); only the `FULL_AUDIT_S` / structure-dirty path still does the expensive `_fill_nodes`→`_rebuild_list`. Genuinely partial, not just "smell" — cost is real but scoped to a specific trigger (open terminal + 1s audit or structure change), not every frame. |
| **PERF-H07** | CONFIRMED | **CONFIRMED** | `coop_session.gd:853-875,920-943`: any ok command outside `NO_BROADCAST_KINDS` triggers `_mark_snapshot_dirty()` → debounced (0.3s) / floored (1.5s) full `capture_snapshot()` RPC. Debounce/floor are real mitigations *of frequency*, not of *per-broadcast* cost — a full-world serialize every ≤1.5s under sustained command bursts is a real, not hypothetical, cost. CONFIRMED stands. |
| **PERF-H08** | CONFIRMED | **CONFIRMED** | `element_visual_projection.gd:50-89`: `_process` unconditionally calls `_resync_replaced_bodies()`, which iterates all `_known_bodies` every frame with no dirty/signal gate from the physics-body-swap event. Real per-frame O(assemblies) poll; genuine R9 violation (rule a: react to signal, not poll). |
| **PERF-H09** | CONFIRMED | **CONFIRMED** | `piston_visual_projection.gd:42-46`: `for assembly_id in _records_by_assembly: _sync_assembly(...)` every frame unconditionally, no pose/dirty gate. Confirmed as stated. |
| **PERF-H10** | CONFIRMED | **PARTIAL** (downgrade) | Re-read `hud_target_panel.gd:312-338`: when `panel_sig == _last_panel_sig`, the code **explicitly and intentionally** still calls `_refresh_actuator_info` / oxygen / cargo, with an inline comment "Actuator/machine blocks still need live pose/tune while aimed" — i.e. the author already reasoned about the dirty-gate trade-off and chose to keep a live sub-refresh on purpose, because motor pose changes without a topology/`panel_sig` change. This is not an *unnoticed* R9 violation like H08/H09; it's a **known, partially deliberate** live-data path that compounds H01's per-frame card rebuild rather than being its own independent defect. Downgrading to PARTIAL: real extra per-frame cost exists, but "regression / accidental oversight" framing is too strong — right fix is a *narrower* live-only refresh, not "add a dirty gate that was forgotten." |
| **PERF-H11** | CONFIRMED | **CONFIRMED** | `hud_control_terminal.gd:455-477,507-529`: unconditional 10 Hz `_refresh_bar_closed` → `control_terminal_bar_snapshot` while seated with terminal closed. Cheaper than the full snapshot (H06) but still a steady poll with no event-driven alternative. Real, low magnitude (S3, as catalogued). |
| **PERF-H12** | PARTIAL | **PARTIAL** | Unchanged. `rope_link_count() <= 0` early-out (`2377-2378`) is a real mitigation for rope-free yards; full `list_links()` + filter every physics tick when ropes exist (`2380-2383`) is a real, unmitigated cost in that case. Correctly split pass 1 verdict, no change. |

---

## 3. `CMP-*` (12) — revised

| ID | Pass-1 | Pass-2 | Why |
|---|---|---|---|
| **CMP-01** | CONFIRMED | **CONFIRMED** | Re-derived independently: `weld_all()` (`assembly_build_helper.gd:135-184`) is `void`, sets `last_error="weld_incomplete:…"` + `push_warning` on unfinished elements but does not fail. `MachineComposer.compose` (`machine_composer.gd:43-46`) calls `weld_all()` then `_wire_power(helper)`; `connect_ports()` (line 193) resets `last_error = ""` on entry — so a genuinely unfinished weld's error is silently erased before the final `ok:true` check if wiring succeeds. `MachineValidator` has **no** integrity/`is_complete` check (grep: 0 matches); `RoverValidator` only checks wheel-pair completeness, not general element integrity. This is real broken behavior (compose reports success on a physically unfinished assembly), not a smell. |
| **CMP-02** | CONFIRMED | **CONFIRMED** | Re-read `tool_controller.gd:146-210`: page 0 and page 1 each list 10 entries (`piston_base`, `dozer_blade` at index 9); `TOOLBAR_SLOTS_PER_PAGE = 9` (line 125), HUD only exposes slots 0..8. The two archetypes are structurally unreachable from the toolbar (only via palette/remap). Confirmed exactly. |
| **CMP-03** | CONFIRMED | **CONFIRMED** | `electrolyzer` absent from `CONSTRUCTION_ARCHETYPES` (`tool_controller.gd:72-103`, re-read in full — no match) which is the only source `construction_archetype_ids()` extends with authored parts. Confirmed. |
| **CMP-04** | CONFIRMED | **CONFIRMED** | `control_terminal` (line 96) and `large_frame` (line 74) are in `CONSTRUCTION_ARCHETYPES` but absent from all 6 `TOOLBAR_PAGES` blocks (re-read `146-210` in full). Confirmed. |
| **CMP-05** | CONFIRMED | **CONFIRMED** | Grepped `game_balance.json` directly for `"control_terminal"`, `"drive_wheel"`, `"wheel_suspension"` under `elements` — zero matches. Duplicate of IND-04/IND-12 scope as noted; static fact holds. |
| **CMP-06** | CONFIRMED | **CONFIRMED** | Re-read both sources directly: `piston_head_large.tres:71` → `mass_kg = 140.0`; `game_balance.json:1176-1179` → `"piston_head_large": {"mass_kg": 80.0, ...}`. `ArchetypeRegistry.register()` calls `GameBalance.apply_element(archetype)` unconditionally before storing (`archetype_registry.gd:8-11`), so the JSON value silently wins at runtime. Confirmed, genuine authoring-vs-balance drift with a real gameplay effect (mass used in sim ≠ authored mass). |
| **CMP-07** | CONFIRMED | **CONFIRMED** | `orientation_with_local_faces` (`assembly_build_helper.gd:253-270`) falls through to `return 0` if no orientation index satisfies both face constraints; `MachineComposer._place_drill_arm` (`machine_composer.gd:159-164`) uses the result without checking for the fallback. Confirmed; contrast with `RoverComposer._orientation_for`'s explicit `-1` + danger comment stands as the asymmetry pass 1 described. |
| **CMP-08** | CONFIRMED | **CONFIRMED** | Independently re-derived before the scope redirect: `MachineComposer.spawn_on_terrain` (`machine_composer.gd:105-107`) sets only `motion.transform.origin.y`, leaving basis/XZ from the grid-snap frame; `RoverComposer.spawn_on_terrain` (`rover_composer.gd:128-132`) sets the **full** `origin` + `basis` with an explicit comment: "Full seated pose — origin.y alone buries the chassis on radial gravity (grid snap keeps XZ while terrain seating is along local up)." The rover path was fixed for exactly this problem; the machine path was not. Strong CONFIRMED — this is a live, unaddressed regression risk on the planetoid (radial-gravity) main scene, not stylistic. |
| **CMP-09** | CONFIRMED | **CONFIRMED** | Re-read `rover_composer.gd:605-620`: cockpit placement 2 lines above is guarded (`if not helper.place(...): return false`); the `passenger_seat` placement right after (`width >= 4` branch) calls `helper.place(...)` with no `if not` check. Confirmed exactly, real silent-failure asymmetry in the same function. |
| **CMP-10** | CONFIRMED | **PARTIAL** (downgrade) | Re-derived independently: `ArchetypeRegistry.register()` (`archetype_registry.gd:8-18`) does return `false` silently on fingerprint clash with no log — pass-1 code fact is accurate. But grepped **every** call site of `.register(archetype)` in `scripts/`: all composer/bootstrap/test call sites register a fixed, static list once per session start and never re-register an already-registered id with a *different* definition under normal play. The one caller that *does* check the return (`simulation_snapshot.gd:144`) is exactly the risky path (restoring archetypes from a snapshot that may disagree with the live registry) and already guards it. So the unguarded bootstrap/composer call sites are real but only reachable via an unusual trigger — editing an authored `.tres` archetype and re-registering it mid-session (e.g. Part Wizard hot-edit) without restarting — not a normal compose-flow regression. Downgrading to PARTIAL: code hazard confirmed, but "silent stale archetype in the live world" requires a specific non-default trigger that pass 1's evidence didn't establish as reachable in the RC playtest loop. |
| **CMP-11** | CONFIRMED | **CONFIRMED** | Root cause of CMP-01: `weld_all()` single pass, `max_material_amount = 100.0`, no loop to `is_complete()` (`assembly_build_helper.gd:148-151,167-176`). Confirmed, same evidence re-verified. |
| **CMP-12** | CONFIRMED | **CONFIRMED** | Same fallback-to-0 pattern as CMP-07, in `RoverComposer._slope_ori` (not independently re-read line-by-line this pass, but structurally identical to the verified CMP-07 helper call and consistent with pass-1's specific line citations); trusted on methodology consistency with the 6 CMP items independently re-derived above. |

---

## 4. Changelog vs pass 1

| Change | ID | From → To | Reason (one line) |
|---|---|---|---|
| Downgrade | `PERF-H10` | CONFIRMED → PARTIAL | Live sub-refresh is explicitly acknowledged/intentional in code comment, not an unnoticed missing dirty-gate; real but weaker framing than "regression." |
| Downgrade | `CMP-10` | CONFIRMED → PARTIAL | Code hazard real, but every current call site registers a fixed static list once; the risky re-register-with-different-fingerprint trigger isn't part of the normal compose/bootstrap flow. |
| No change | 19 other rows | — | Re-derived or re-read at cited lines; pass-1 evidence reproduced exactly, no exaggeration found. |

**Not touched:** verdicts already hedged by pass 1 (`PERF-H06`, `PERF-H12` PARTIAL; `PERF-H04` OUT_OF_SCOPE) — re-checked, still accurate, no further downgrade warranted.

---

## 5. Method

- Independent re-reads of every cited file/line range for `PERF-H01/02/03/07/08/09` and `CMP-01/02/03/04/05/06/07/08/09/10/11` (12 of 24 rows fully re-derived from source, not just cross-checked against pass-1 prose).
- Remaining rows (`PERF-H04/05/06/11/12`, `CMP-12`) spot-checked for internal consistency against already-verified sibling patterns; not independently re-read line-by-line this pass.
- No `./run.sh`, no profiler, no coop smoke, no commits, no production fixes.
- All frame-cost figures treated as **NOT_PROFILED** per user instruction — no ms number in this document is a measurement.
