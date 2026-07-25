# Verification — `IND-*` (§3.5, `docs/BUG-HUNT-RC-2026-07-25.md`)

Static-analysis findings re-checked against current tree (uncommitted session changes included).
No fixes applied in this pass. `test_industry_v1` and `test_game_balance` run via
`tests/run_one.sh` (git-bash, since default shell is PowerShell).

## Note on the "rope_path guest spam" fix

The session's `simulation_physics_projection.gd` fix (`rope_path()` stale-`RigidBody3D` guard +
`_clear_all_bodies()` clearing `_rope_states`) fixes a **different** bug than any cataloged
`IND-*` entry: it's live rope-line **rendering** after a guest rejoin holding a freed body
reference (~13k `SCRIPT ERROR`/frame). `IND-01`/`IND-02` are about `capture_snapshot` /
`create_from_snapshot` **round-trip** of rope/`cable_stake` topology in the kernel test, an
unrelated code path (`connect_rope`, `SimulationSnapshot`, not `rope_path`/`_rope_states`).
**No `IND-*` item maps to the rope_path spam fix** — it is closest to `COOP-06`/`PHY-*`
territory (not itself cataloged) rather than the `IND-*` industry/balance section.

## IND-01 — S0 — rope/`cable_stake` snapshot round-trip

**CONFIRMED → now FIXED.** Ran `tests/run_one.sh test_industry_v1`: **PASS** (full suite,
including `_test_cable_rope_free_attach`). `git diff HEAD -- scripts/test_industry_v1.gd` shows
this session rewrote `_run_rope_free_attach_scenario()`: swapped the fixture to a single-block
blueprint (`_rope_anchor_blueprint`, avoiding an unrelated native rigid-find/foundation-span
issue called out in a new comment) and rewrote the post-restore assertions to match the
stake-endpoint model instead of the stale world-point model (see IND-02). The scenario now
passes snapshot round-trip for 3 ropes (block→stake, twin, stake→stake). Confirms the user's
note: `test_industry_v1` is green in the current tree, not merely "was green in a recent gate."
**Caveat:** this is a test-contract fix (assertions now match the stake model), not evidence
that every rope/cable_stake path was broken in production code — see IND-02.

## IND-02 — S1 — restore-asserts stale after stake model

**CONFIRMED → now FIXED.** Same diff as IND-01. Old assertions expected
`restored_link.element_b != 0` and `attach_b ≈ ground_point` (raw world point) — exactly the
pre-stake, world-pinned-anchor contract the report describes as stale. New assertions check
`restored_stake.archetype_id == "cable_stake"`, `element_b == link.element_b`, and
`attach_a`/`attach_b` against the live link's own attach points (post-localize), matching
`CableAnchorUtil.localize` / `connect_rope`'s actual stake-based contract. Test is green.

## IND-03 — S1 — legacy inventory doesn't backfill `tool_rope`

**CONFIRMED**, still open. `scripts/simulation/industry/player_inventory_registry.gd:142-151`
(`migrate_legacy_save`): when `_instances` is non-empty (legacy save with the old 4 tools), the
function only calls `validate_hotbar_refs()` and backfills **hotbar ref** slots from
`DEFAULT_HOTBAR_REFS` for instances that already exist — it never adds missing
`STARTER_INSTANCES` entries. A legacy save with 4 tools loads with 4 tools forever;
`starter_tool_rope` / slot `5:7` stays empty. Only the `_instances.is_empty()` branch
(`seed_starter_tools`) seeds all 5.

## IND-04 — S1 — `game_balance.json` missing slice rover parts

**CONFIRMED**, still open (partially touched, not resolved). `git diff HEAD` on
`resources/balance/game_balance.json` adds only `elements.cable_stake` (+4 lines). Grepped
`elements{}` for `drive_wheel`, `wheel_suspension`, `control_terminal`, `H2O_Tank`,
`Suspension_Medium`, `Test_Battery`, `Wheel_Medium_01`: **zero matches**, while the
corresponding `.tres` archetypes all exist under `resources/archetypes/slice01/` and
`resources/archetypes/authored/`. `test_game_balance` (`run_one.sh`: **PASS**) doesn't catch
this because it only iterates `Slice01Archetypes.REQUIRED_IDS`, which excludes rover/authored
parts — confirms IND-13's root-cause claim too.

## IND-05 — S2 — legacy dual-path still present

**CONFIRMED**, still open. `game_balance.json` still has `reduce_oxide → metal_ingot`,
`sinter_component → construction_component` (lines ~242-292), but grep for
`"resource_id": "construction_component"` across the whole file returns **zero matches** — no
BOM/build_requirement anywhere consumes it. All element BOMs use `plate_metal` (18 refs) /
`mechanism` (9 refs) instead. `construction_component` is a dead-end recipe output.

## IND-06 — S2 — ISRU oxygen doesn't refill `OxygenModule`

**CONFIRMED** as a code fact, but the report's own framing needs adjustment: this is the
**same, intentionally-deferred** contract as IND-14, not an independent gap. `CargoTransferService.transfer_between_stores` (`cargo_transfer_service.gd:27-33`) unconditionally
returns `transfer_blocked` when either store is an `OxygenModule` store, with a comment stating
"topology-only in v0". `docs/specs/OXYGEN-SURVIVAL-V0.md:145-146,224-228` explicitly lists
"Module replenishment из bulk oxygen, electrolyzer, cargo auto-transfer" under **«Не входит»**
(out of scope) for v0. So: technically accurate description of current behavior, but it matches
the spec rather than contradicting it — recommend re-tagging as `[спек]`/informational like
IND-14 rather than a standalone S2 defect, or merging into IND-14.

## IND-07 — S2 — starter inventory near-full (94.2/100 L)

**CONFIRMED**, still open. Verified by direct computation from `game_balance.json`:
tools = drill 8 + welder 6 + grinder 7 + connector 4 + rope 6 = **31 L**; `starter.player_resources`
= ore_mare_regolith 4×2.5 + regolith_fines 4×1.8 + sintered_basalt 2×1.5 + hydrogen 2×2.5 +
plate_metal 8×3.0 + girder 2×4.0 + plate_basalt 2×3.0 = **63.2 L**. Total **94.2 L** against
`parameters.player_carry_capacity_l = 100.0` → **5.8 L** headroom, matching the report exactly.

## IND-08 — S2 — `frame_lamp` in `elements` but not `electric.archetypes`

**CONFIRMED**, still open. `elements.frame_lamp` exists (`game_balance.json:1051`). The single
`electric.archetypes{}` block (`:585-627` and onward) has no `frame_lamp` entry — grep for
`"archetypes"|"frame_lamp"` across the whole file finds exactly one `archetypes` block and the
only other `frame_lamp` hit is the `elements` entry. Not registered as an electric consumer.

## IND-09 — S2 — tools have no recipe/craft path

**CONFIRMED**, still open. `tool_hand_drill`, `tool_welder`, `tool_grinder`, `tool_connector`,
`tool_rope` are declared only in the `items{}` catalog (`:54-82`); grepping the whole file for
each id finds zero occurrences inside any `recipes.*` block (inputs or outputs). Fabricator
default recipes only touch plates/ingots/mechanisms.

## IND-10 — S2 — two independent version channels (save vs snapshot)

**CONFIRMED**, still open, as a code fact — though the failure mode is a bit more nuanced than
"outer OK / inner fail is silent". `WorldPersistence.SAVE_VERSION := 4`
(`world_persistence.gd:9`) is checked with **exact equality** in `read_payload()` (`:45`); on
mismatch the **entire payload is discarded** (comment: "unreleased game...wipe OK"). Independently,
`SimulationSnapshot.VERSION := 11` (`simulation_snapshot.gd:4`) accepts **9, 10, or 11**
(`:59-64`) when restoring the embedded `simulation` blob. Since these two counters are bumped
independently and only the inner one has a compatibility range, a save with matching
`save_version:4` but an out-of-range/incompatible `simulation.version` will pass the outer gate
and then fail/warn inside `restore_snapshot_data`, leaving cold poses/markers (stored outside the
snapshot in the same payload) applied against a fresh/empty simulation world — exactly the
report's repro.

## IND-11 — S3 — spec vs registry disagree on starter rope/hotbar

**CONFIRMED**, still open. `docs/specs/INDUSTRY-V1.md:172-174` documents starter migration ids
as `starter_tool_drill|welder|grinder|connector` and hotbar page 0 slots `0,1,2,8` only — no
mention of rope or page 5. Code (`player_inventory_registry.gd:11-27`) has a 5th starter,
`starter_tool_rope` → `tool_rope`, bound to slot `5:7`. `scripts/test_player_inventory_hotbar.gd`
has zero references to `rope` — confirmed via grep, the test doesn't cover this slot either.

## IND-12 — S3 — authored archetypes outside balance

**CONFIRMED**, still open (same evidence as IND-04, kept as a distinct catalog line per the
report's own dedup note). `H2O_Tank`, `Suspension_Medium`, `Test_Battery`, `Wheel_Medium_01`
`.tres` files exist under `resources/archetypes/authored/`; none of their ids appear in
`elements{}`.

## IND-13 — S3 — `GameBalance.validate()` doesn't catch archetype-coverage gaps

**CONFIRMED**, still open. Read `scripts/simulation/balance/game_balance.gd:235-342`
(`validate()`): it checks item-shape, recipe-reference validity, parameter-shape, and (for each
element **already present** in `elements{}`) BOM-reference validity — it never asserts that
every `REQUIRED_IDS`/rover/authored archetype id has a corresponding `elements{}` entry, and
never asserts electric-consumer registration for lamps. Empirically demonstrated: ran
`tests/run_one.sh test_game_balance` → **PASS**, even though IND-04/IND-08/IND-12's missing
entries are present in the tree right now. Root cause for IND-04/IND-08/IND-12 as claimed.

## IND-14 — info — OxygenModule refill deferred (by design)

**CONFIRMED** as a documented, intentional v0 contract, not a bug. `docs/specs/OXYGEN-SURVIVAL-V0.md:224-228` ("Не входит") explicitly lists module replenishment from bulk
oxygen/electrolyzer/cargo auto-transfer as out of scope for v0; matches the `transfer_blocked`
behavior verified under IND-06. No action implied here beyond the IND-06 re-tag suggestion above.

---

## Counts

| Status | IDs | Count |
|---|---|---|
| **FIXED** | IND-01, IND-02 | 2 |
| **CONFIRMED** | IND-03, IND-04, IND-05, IND-06, IND-07, IND-08, IND-09, IND-10, IND-11, IND-12, IND-13, IND-14 | 12 |
| **FALSE ALARM** | — | 0 |
| **PARTIAL** | — | 0 |
| **NEEDS_PLAYTEST** | — | 0 |
| **Total IND-\* entries** | | **14** |

No `IND-*` entry maps to the `rope_path` guest-join-spam fix (`_rope_states` stale-body guard) —
that fix addresses an uncataloged coop/rendering bug, not a topology/balance finding in this
section.
