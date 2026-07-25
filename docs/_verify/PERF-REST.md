# PERF / CMP / leftover verify — BUG-HUNT-RC-2026-07-25

Static code verification only (no fixes, no playtest, no profiler).  
Scope: `PERF-*`, `AUTH-*`, and any catalog prefix **not** in the excluded set  
(`DIG`, `COOP`, `KRN`, `PHY`, `IND`, `UI`, `VOX`, `HUD`).  
RT / day-night explicitly out of scope per hunt doc.

Verified against working tree ~2026-07-25.

---

## 1. Catalog prefixes (§3 of hunt doc)

| Prefix | § | Records | This pass |
|---|---|---|---|
| `DIG-*` | 3.1 Terrain / dig / join | 14 | excluded |
| `COOP-*` | 3.2 Coop network / session | 7 | excluded |
| `PHY-*` | 3.3 Physics / freeze / seats | 14 | excluded |
| `KRN-*` | 3.4 Kernel / snapshot | 15 | excluded |
| `IND-*` | 3.5 Industry / balance / save | 14 | excluded |
| `UI-*` | 3.6 HUD / input / seats | 15 | excluded |
| `PERF-*` | 3.7 Perf / R9 hot paths | 12 | **verified below** |
| `CMP-*` | 3.8 Authoring / compose / toolbar | 12 | **verified below** |

**Not in catalog (nothing to verify):**

| Prefix | Notes |
|---|---|
| `AUTH-*` | No rows in `docs/BUG-HUNT-RC-2026-07-25.md`. Likely meant `CMP-*` (authoring agent). |
| `VOX-*` | No rows; voxel findings merged into `DIG-*`. |
| `HUD-*` | No rows; HUD findings merged into `UI-*` (`BH-*` aliases). |

Legacy source IDs (`D*`, `H01…H12`, `BH-*`, `SW-*`, `COOP-01/02/03/08/11`) are deduped into the table above (§4).

---

## 2. Summary counts

| Verdict | PERF | CMP | Total |
|---|---|---|---|
| **CONFIRMED** | 9 | 12 | **21** |
| **PARTIAL** | 2 | 0 | **2** |
| **FALSE ALARM** | 0 | 0 | **0** |
| **NEEDS_PLAYTEST** | 0 | 0 | **0** |
| **OUT_OF_SCOPE** | 1 | 0 | **1** |
| **Prefix absent** | — | — | **AUTH-* (0 IDs)** |

**IDs unassigned:** none (all 24 in-scope catalog rows covered).

Ms/frame estimates in the hunt table remain **unmeasured**; static pass confirms code paths, not profiler numbers. Where impact severity matters, evidence notes “magnitude unverified” without upgrading verdict to NEEDS_PLAYTEST (pattern itself is confirmed or partial).

---

## 3. `PERF-*` (12)

| ID | Verdict | Evidence |
|---|---|---|
| **PERF-H01** | **CONFIRMED** | `InteractionIndex.get_card()` calls `InteractionCard.refresh()` on every read (`interaction_index.gd:60-72`); `refresh()` always `keys.clear()` then full rewrite (`interaction_card.gd:23-31`). `hud_target_panel._process` and `hud_reticle._process` call `_aim_keys()` → `hit.card_keys()` every frame while aiming (`hud_target_panel.gd:312-325`, `hud_reticle.gd:60-92`). Reticle also refreshes inside `_summary_key` every frame. |
| **PERF-H02** | **CONFIRMED** | `industry_network_projection._process`: when `revision == _cached_network_revision`, still iterates every wire child and calls `_update_wire_body` → `_wire_points`, spline smooth, `_update_wire_colliders` each frame (`industry_network_projection.gd:84-98,131-157`). Mesh rebuild gated by `_tube_path_changed`; pose/collider path is not. |
| **PERF-H03** | **CONFIRMED** | `_physics_process` runs rotor, piston, wheel, thruster, rope, tension, anchor ticks then motion capture over all unfrozen assemblies (`simulation_physics_projection.gd:271-306`). `_sorted_int_keys` used 14× in file (grep). Wheel tick sorts `_bodies` and `_wheel_constraints` each physics step (`1962-1967`). Historical “200→30 FPS” not re-measured. |
| **PERF-H04** | **OUT_OF_SCOPE** | World RT / TLAS: hunt doc §3.7 + batch B17 mark RT excluded. `world_rt_geometry._process` still calls `_rebuild_tlas()` every frame (`world_rt_geometry.gd:96,396-405`) — noted but not triaged here. |
| **PERF-H05** | **CONFIRMED** | `IndustrySimulation._tick_once` (4 Hz) chains services that scan the world: `IndustryElectricBudget.apply_tick` → `world.list_elements()` (`industry_electric_budget.gd:16-21`); `_sync_machine_power_draw` → `list_elements()` (`industry_simulation.gd:200-201`); `recipe_runner_service` multiple `list_elements()` passes; `cargo_transfer_service` `list_elements()` at 240+ (`recipe_runner_service.gd:17,259,373,810`; `cargo_transfer_service.gd:240,276`). |
| **PERF-H06** | **PARTIAL** | Open terminal: 10 Hz `_process` + `control_terminal_snapshot` on structure change or `FULL_AUDIT_S` (1 s) full path with `_fill_nodes` → `_rebuild_list` queue_free rebuild (`hud_control_terminal.gd:174-176,448-478,534-587,1691-1696`). **Mitigations since hunt text:** closed window uses cheaper `control_terminal_bar_snapshot` only (`507-529`); unchanged structure uses `_refresh_open_live_only` O(1) path (`547-549,590-608`). Full O(nodes) rebuild still real on audit/structure dirty. |
| **PERF-H07** | **CONFIRMED** | Host `_on_host_command_completed`: ok commands outside `NO_BROADCAST_KINDS` call `_mark_snapshot_dirty()` (`coop_session.gd:853-875,920-943`). Debounce `SNAPSHOT_DEBOUNCE=0.3`, floor `SNAPSHOT_FLOOR_MS=1500` → `rpc(_cli_apply_snapshot, capture_snapshot())`. |
| **PERF-H08** | **CONFIRMED** | `element_visual_projection._process` unconditionally calls `_resync_replaced_bodies()` which walks all `_known_bodies` vs current physics body (`element_visual_projection.gd:50-89`). No dirty/signal gate. |
| **PERF-H09** | **CONFIRMED** | `piston_visual_projection._process`: `for assembly_id in _records_by_assembly: _sync_assembly(...)` every frame (`piston_visual_projection.gd:42-46,270+`). No pose/dirty gate. |
| **PERF-H10** | **CONFIRMED** | `hud_target_panel._process`: when `panel_sig == _last_panel_sig`, still calls `_refresh_actuator_info` / `_refresh_machine_info` / oxygen / cargo every frame (explicit comment “still need live pose/tune”, `hud_target_panel.gd:329-338`). Compounds PERF-H01 via `_aim_keys` on same path. |
| **PERF-H11** | **CONFIRMED** | Seated driver with closed terminal: `_process` runs at `REFRESH_S=0.1` (10 Hz) and calls `_refresh_bar_closed` → `control_terminal_bar_snapshot` (`hud_control_terminal.gd:455-477,507-529`). Cheaper than full snapshot but still 10 Hz gateway poll in cabin. |
| **PERF-H12** | **PARTIAL** | Early-out when `rope_link_count() <= 0` skips work (`simulation_physics_projection.gd:2377-2378`). When ropes exist: full `list_links()` + filter every physics tick (`2380-2383`). Mitigation for rope-free yards; confirmed cost when ropes present. |

---

## 4. `CMP-*` (12)

| ID | Verdict | Evidence |
|---|---|---|
| **CMP-01** | **CONFIRMED** | `AssemblyBuildHelper.weld_all()` is `void`; incomplete weld sets `last_error` + `push_warning` but does not fail compose (`assembly_build_helper.gd:135-184`). `connect_ports` clears `last_error` on entry (`193`); `MachineComposer` / `RoverComposer` check only `_wire_power` after weld (`machine_composer.gd:43-45`, `rover_composer.gd:64-66`). `MachineValidator` / `RoverValidator` check topology/counts, not `element.is_complete()` / integrity. |
| **CMP-02** | **CONFIRMED** | `TOOLBAR_SLOTS_PER_PAGE = 9` (`tool_controller.gd:125`); page 0 has 10 entries (10th: `piston_base`), page 1 has 10 (10th: `dozer_blade`) (`146-170`). HUD reads slots 0..8 only. |
| **CMP-03** | **CONFIRMED** | `electrolyzer` in `Slice01Archetypes.REQUIRED_IDS` + balance/recipes; **not** in `CONSTRUCTION_ARCHETYPES` nor `construction_archetype_ids()` palette source (`tool_controller.gd:72-103`). Not buildable via Block Palette. |
| **CMP-04** | **CONFIRMED** | `control_terminal` and `large_frame` in `CONSTRUCTION_ARCHETYPES` (`96`, `74`) but absent from all `TOOLBAR_PAGES` entries (`146-210`). Palette-only access. |
| **CMP-05** | **CONFIRMED** | `game_balance.json` `elements` has no `control_terminal`, `drive_wheel`, `wheel_suspension` (grep). `GameBalance.apply_element` no-op when entry missing (`game_balance.gd:199-201`). Duplicates IND-04/IND-12 scope; static facts match. |
| **CMP-06** | **CONFIRMED** | `piston_head_large.tres` `mass_kg = 140.0`; `game_balance.json` `elements.piston_head_large.mass_kg = 80.0`. Register path calls `GameBalance.apply_element` → overwrites tres on first register (`game_balance.gd:202-203`, `archetype_registry.gd:11`). |
| **CMP-07** | **CONFIRMED** | `MachineComposer._place_drill_arm` uses `AssemblyBuildHelper.orientation_with_local_faces(...)` with silent `return 0` fallback (`machine_composer.gd:159-164`, `assembly_build_helper.gd:253-270`). `RoverComposer._orientation_for` documents danger and returns `-1` instead (`rover_composer.gd:553-567`). |
| **CMP-08** | **CONFIRMED** | `MachineComposer.spawn_on_terrain` sets only `motion.transform.origin.y` from surface; basis/XZ from grid frame (`machine_composer.gd:105-107`). Contrast `RoverComposer.spawn_on_terrain` full `origin` + `basis` with comment about radial gravity (`rover_composer.gd:128-132`). |
| **CMP-09** | **CONFIRMED** | `RoverComposer._place_modules`: `width >= 4` calls `helper.place(passenger_seat, …)` without checking return (`rover_composer.gd:614-620`). Occupied cockpit cell `(3, module_y, cockpit_z)` can fail silently while compose continues. |
| **CMP-10** | **CONFIRMED** | `ArchetypeRegistry.register`: fingerprint clash → `return false`, no log (`archetype_registry.gd:14-15`). `bootstrap.gd:278-285` and composers call `register()` without checking return. |
| **CMP-11** | **CONFIRMED** | `weld_all` single pass per element, `max_material_amount = 100.0`, no loop until `is_complete()` (`assembly_build_helper.gd:148-151,167-176`). Root of CMP-01 partial welds. |
| **CMP-12** | **CONFIRMED** | `RoverComposer._slope_ori` → `orientation_with_local_faces` with silent 0 fallback (`rover_composer.gd:377-384`, `assembly_build_helper.gd:270`). `_try_decor_place` swallows failure by clearing `last_error` (`396-397`). |

---

## 5. Unassigned / orphaned IDs

**None.** All 12 `PERF-*` and 12 `CMP-*` catalog rows assigned above.  
`AUTH-*`: prefix not present in hunt catalog (0 rows).

---

## 6. Method

- Read-only grep + targeted file reads at cited paths.
- No `./run.sh`, no profiler, no coop smoke, no commits.
- RT (`PERF-H04`) marked OUT_OF_SCOPE per hunt doc, not re-opened.
