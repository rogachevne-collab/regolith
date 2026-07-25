# Master verification report — BUG-HUNT RC 2026-07-25

Merged from domain passes (prefer **PERF-REST-PASS2** over PASS1 where both exist).
Read-only verification — **no production fixes** in this merge step.
Catalog source: `docs/BUG-HUNT-RC-2026-07-25.md` (103 rows, §3.1–§3.8).

> **Caveat (honest).** Most **CONFIRMED** verdicts mean the cited **code mechanism matches
> the hunt claim** — static analysis + selective headless probes (`test_coop_bug_regressions`,
> `test_coop_dig_replay`, `test_industry_v1`, `test_game_balance`). They do **not** imply
> dual-process in-game repro or human playtest confirmation, except where a pass explicitly
> notes live smoke (coop dig sqlite bulk, rope regression gate) or marks **NEEDS_PLAYTEST**.

---

## 1. Coverage — all 103 catalog IDs

Every row in §3.1–§3.8 appears in exactly one domain pass. **No orphans.**

| Prefix | Count | Verified in |
|---|---:|---|
| DIG-* | 14 | `docs/_verify/DIG-COOP.md` |
| COOP-* | 7 | `docs/_verify/DIG-COOP.md` (COOP-01/02/03/08/11 folded into DIG rows per hunt §4) |
| PHY-* | 14 | `docs/_verify/PHY.md` |
| KRN-* | 15 | `docs/_verify/KRN.md` |
| IND-* | 14 | `docs/_verify/IND.md` |
| UI-* | 15 | `docs/_verify/UI.md` |
| PERF-* | 12 | `docs/_verify/PERF-REST-PASS2.md` (authoritative over PASS1) |
| CMP-* | 12 | `docs/_verify/PERF-REST-PASS2.md` |
| **Total** | **103** | |

Uncataloged fix this session (not in the 103-row table): **rope_path guest spam**
(`simulation_physics_projection.gd` — stale `RigidBody3D` guard + `_rope_states.clear()`
in `_clear_all_bodies`). Green gate: `test_coop_rope_projection`. See hunt «Статус прогона».

---

## 2. Grand totals (primary verdict per ID)

Each ID assigned **one** primary bucket. **103 = 83 + 1 + 7 + 3 + 7 + 2.**

| Verdict | Count | Meaning |
|---|---:|---|
| **CONFIRMED** | **83** | Code mechanism matches hunt claim |
| **FALSE ALARM** | **1** | Static re-read refutes the finding |
| **PARTIAL** | **7** | Mechanism real; hunt title/severity/framing overstated |
| **NEEDS_PLAYTEST** | **3** | Plausible mechanism; outcome depends on VT/Jolt/live timing |
| **FIXED** | **7** | Catalog IDs fixed this session (production + test gate) |
| **OUT_OF_SCOPE** | **2** | Hunt-excluded or intentional v0 contract, not an open defect |

Plus **1 uncataloged FIXED** (rope_path spam — see §1).

### Per-prefix subtotals

| Prefix | Total | CONF | FA | PART | PLAY | FIX | OOS |
|---|---:|---:|---:|---:|---:|---:|---:|
| DIG | 14 | 8 | — | 1 | 2 | 3 | — |
| COOP | 7 | 5 | — | — | — | 2 | — |
| PHY | 14 | 13 | — | — | 1 | — | — |
| KRN | 15 | 14 | 1 | — | — | — | — |
| IND | 14 | 11 | — | — | — | 2 | 1 |
| UI | 15 | 13 | — | 2 | — | — | — |
| PERF | 12 | 8 | — | 3 | — | — | 1 |
| CMP | 12 | 11 | — | 1 | — | — | — |
| **Σ** | **103** | **83** | **1** | **7** | **3** | **7** | **2** |

Abbreviations: CONF = CONFIRMED, FA = FALSE ALARM, PART = PARTIAL, PLAY = NEEDS_PLAYTEST,
FIX = FIXED, OOS = OUT_OF_SCOPE.

---

## 3. Hard list — S0 + adversarial-confirmed coop/dig block

**Previously on hard list, now FIXED (2026-07-25, agent d67c5dbf):**

| ID | Sev | Verdict | Note |
|---|---|---|---|
| **DIG-01** | S0 | FIXED | `_persist_digs_durable` waits for in-flight save instead of no-op |
| **DIG-02** | S0 | FIXED | `dig_mark` captured after `await flush_digs_for_coop_join()` |
| **DIG-03** | S1 | FIXED | `fallback_dig_ops` ring when chunked `terrain_bulk` times out |
| **COOP-04** | S1 | FIXED | Live `_cli_dig_op` queues failed replay into `_pending_dig_ops` |
| **COOP-05** | S1 | FIXED | Store/hotbar diff keyed on `SimulationResourceStore.revision` |

Green gate: `test_coop_bug_regressions` **PASS** — now in KERNEL (`run_tests.sh`).

**Also FIXED this session:** **IND-01/02** (rope/`cable_stake` snapshot round-trip —
`test_industry_v1` green; see §6).

No remaining S0 items on the hard list. Next highest open coop/dig: **KRN-01/02/03** (§2 TL;DR).

---

## 4. FALSE ALARM (full IDs)

| ID | Was | Why dropped |
|---|---|---|
| **KRN-11** | S2 — industry runner stale `_cargo_graph` in batch | `IndustrySimulation._tick_once` reassigns `_cargo_graph = world.ensure_cargo_graph_current()` every tick; compose batches are synchronous (no yield), so no interleaved stale window |

---

## 5. NEEDS_PLAYTEST (full IDs)

**Primary** — static analysis cannot settle outcome (VT/Jolt semantics or timing):

| ID | Why |
|---|---|
| **DIG-09** | Spawn settle vs pad-retire on independent timers; crust fall-through depends on VT collider lag `[R7]` |
| **DIG-10** | Stream swap + viewer `view_distance` toggle — whether resident LOD0 blocks reload is VT-implementation `[R7]` |
| **PHY-13** | Mixed freeze on joint-connected bodies — Godot/Jolt #89859; motor targets on frozen end not provable from docs alone `[R8]` |

**Secondary (additive)** — code path **CONFIRMED**, but R2/HUD layer requires in-game UX proof:
UI-02, UI-03, UI-04, UI-05, UI-06, UI-07, UI-08, UI-09, UI-10, UI-11, UI-12, UI-15
(optional sanity only: UI-01, UI-13, UI-14).

---

## 6. FIXED this session

| Item | Scope | Evidence |
|---|---|---|
| **DIG-01** | `flush_digs_for_coop_join` no-op during in-flight persist | `_persist_digs_durable` awaits in-flight save; `test_coop_bug_regressions` **PASS** |
| **DIG-02** | Digs during flush → SQLite + `dig_ops` tail double-carve | `dig_mark` after flush await; `test_coop_bug_regressions` **PASS** |
| **DIG-03** | Chunked `terrain_bulk` timeout, no fallback | `fallback_dig_ops` pre-mark ring on timeout; `test_coop_bug_regressions` **PASS** |
| **COOP-04** | Live `_cli_dig_op` drops failed replay | Failed replay queued to `_pending_dig_ops`; `test_coop_bug_regressions` **PASS** |
| **COOP-05** | Optimistic store/hotbar cache on `unreliable_ordered` | Diff keyed on `SimulationResourceStore.revision`; `test_coop_bug_regressions` **PASS** |
| **IND-01** | Rope / `cable_stake` snapshot round-trip | `test_industry_v1` **PASS** — `_run_rope_free_attach_scenario` rewritten for stake model |
| **IND-02** | Stale post-restore assertions (pre-stake world-point contract) | Same diff as IND-01; assertions now match `CableAnchorUtil.localize` / `connect_rope` |
| **rope_path** *(uncataloged)* | ~13k `SCRIPT ERROR`/frame on guest rejoin | `simulation_physics_projection.gd` stale-body guard + `_rope_states` clear; `test_coop_rope_projection` in KERNEL gate |

**Caveat on IND-01/02:** fix is primarily **test-contract alignment** with the stake-endpoint
model; not proof that every production rope path was broken before the rewrite.

---

## 7. OUT_OF_SCOPE (full IDs)

| ID | Reason |
|---|---|
| **IND-14** | OxygenModule cargo refill explicitly deferred in `OXYGEN-SURVIVAL-V0` § «Не входит» — intentional v0 contract, not implementation bug |
| **PERF-H04** | World RT / `WorldRtGeometry` TLAS rebuild — excluded from this hunt round (see hunt doc §0) |

**Informational (still CONFIRMED as code fact, matches spec):** **IND-06** — same v0 deferral
as IND-14; recommend re-tagging `[спек]` in catalog, not merging into OUT_OF_SCOPE count above.

---

## 8. PARTIAL (full IDs)

| ID | Verdict detail |
|---|---|
| **DIG-13** | Division in `raycast_hit_world_distance` confirmed; upstream VT docs don't nail `hit.distance` units — inert at `VOXEL_SCALE=1.0` |
| **UI-04** | Wrong «кокпит» copy on `passenger_seat`; terminal path partially correct |
| **UI-15** | Flight-look delta accumulation plausible via UI-09 chain; attitude jerk not proven headless |
| **PERF-H06** | Full audit path expensive, but open-terminal refresh already has cheaper live/closed branches |
| **PERF-H10** | Live sub-refresh intentional (code comment); not an unnoticed missing dirty-gate |
| **PERF-H12** | `rope_link_count()<=0` early-out mitigates rope-free yards; cost real when ropes exist |
| **CMP-10** | `register()` silent `false` on fingerprint clash real; normal bootstrap/composer flow never re-registers conflicting defs |

---

## 9. FALSE ALARM list — empty except KRN-11

See §4.

---

## 10. Domain pass index

| File | IDs | Key headless probes |
|---|---|---|
| [`DIG-COOP.md`](DIG-COOP.md) | DIG-01…14, COOP-04…10 | `test_coop_dig_replay` (DIG-04 PASS); `test_coop_bug_regressions` (DIG-01…03, COOP-04/05 **PASS**, KERNEL gate) |
| [`KRN.md`](KRN.md) | KRN-01…15 | Static only |
| [`PHY.md`](PHY.md) | PHY-01…14 | Static + R8 web/doc cross-check |
| [`IND.md`](IND.md) | IND-01…14 | `test_industry_v1`, `test_game_balance` |
| [`UI.md`](UI.md) | UI-01…15 | Static only (R2) |
| [`PERF-REST-PASS2.md`](PERF-REST-PASS2.md) | PERF-H01…12, CMP-01…12 | Adversarial re-read; frame costs **NOT_PROFILED** |

Pass-1 perf counts (`PERF-REST.md`: 21 CONF / 2 PART / 1 OOS) superseded by PASS2
(19 CONF / 4 PART / 1 OOS for PERF+CMP combined).

---

## 11. Full ID → verdict lookup

| ID | Verdict | Source |
|---|---|---|
| DIG-01 | FIXED | DIG-COOP |
| DIG-02 | FIXED | DIG-COOP |
| DIG-03 | FIXED | DIG-COOP |
| DIG-04 | CONFIRMED | DIG-COOP |
| DIG-05 | CONFIRMED | DIG-COOP |
| DIG-06 | CONFIRMED | DIG-COOP |
| DIG-07 | CONFIRMED | DIG-COOP |
| DIG-08 | CONFIRMED | DIG-COOP |
| DIG-09 | NEEDS_PLAYTEST | DIG-COOP |
| DIG-10 | NEEDS_PLAYTEST | DIG-COOP |
| DIG-11 | CONFIRMED | DIG-COOP |
| DIG-12 | CONFIRMED | DIG-COOP |
| DIG-13 | PARTIAL | DIG-COOP |
| DIG-14 | CONFIRMED | DIG-COOP |
| COOP-04 | FIXED | DIG-COOP |
| COOP-05 | FIXED | DIG-COOP |
| COOP-06 | CONFIRMED | DIG-COOP |
| COOP-07 | CONFIRMED | DIG-COOP |
| COOP-08 | CONFIRMED | DIG-COOP |
| COOP-09 | CONFIRMED | DIG-COOP |
| COOP-10 | CONFIRMED | DIG-COOP |
| PHY-01 | CONFIRMED | PHY |
| PHY-02 | CONFIRMED | PHY |
| PHY-03 | CONFIRMED | PHY |
| PHY-04 | CONFIRMED | PHY |
| PHY-05 | CONFIRMED | PHY |
| PHY-06 | CONFIRMED | PHY |
| PHY-07 | CONFIRMED | PHY |
| PHY-08 | CONFIRMED | PHY |
| PHY-09 | CONFIRMED | PHY |
| PHY-10 | CONFIRMED | PHY |
| PHY-11 | CONFIRMED | PHY |
| PHY-12 | CONFIRMED | PHY |
| PHY-13 | NEEDS_PLAYTEST | PHY |
| PHY-14 | CONFIRMED | PHY |
| KRN-01 | CONFIRMED | KRN |
| KRN-02 | CONFIRMED | KRN |
| KRN-03 | CONFIRMED | KRN |
| KRN-04 | CONFIRMED | KRN |
| KRN-05 | CONFIRMED | KRN |
| KRN-06 | CONFIRMED | KRN |
| KRN-07 | CONFIRMED | KRN |
| KRN-08 | CONFIRMED | KRN |
| KRN-09 | CONFIRMED | KRN |
| KRN-10 | CONFIRMED | KRN |
| KRN-11 | FALSE ALARM | KRN |
| KRN-12 | CONFIRMED | KRN |
| KRN-13 | CONFIRMED | KRN |
| KRN-14 | CONFIRMED | KRN |
| KRN-15 | CONFIRMED | KRN |
| IND-01 | FIXED | IND |
| IND-02 | FIXED | IND |
| IND-03 | CONFIRMED | IND |
| IND-04 | CONFIRMED | IND |
| IND-05 | CONFIRMED | IND |
| IND-06 | CONFIRMED | IND |
| IND-07 | CONFIRMED | IND |
| IND-08 | CONFIRMED | IND |
| IND-09 | CONFIRMED | IND |
| IND-10 | CONFIRMED | IND |
| IND-11 | CONFIRMED | IND |
| IND-12 | CONFIRMED | IND |
| IND-13 | CONFIRMED | IND |
| IND-14 | OUT_OF_SCOPE | IND |
| UI-01 | CONFIRMED | UI |
| UI-02 | CONFIRMED | UI |
| UI-03 | CONFIRMED | UI |
| UI-04 | PARTIAL | UI |
| UI-05 | CONFIRMED | UI |
| UI-06 | CONFIRMED | UI |
| UI-07 | CONFIRMED | UI |
| UI-08 | CONFIRMED | UI |
| UI-09 | CONFIRMED | UI |
| UI-10 | CONFIRMED | UI |
| UI-11 | CONFIRMED | UI |
| UI-12 | CONFIRMED | UI |
| UI-13 | CONFIRMED | UI |
| UI-14 | CONFIRMED | UI |
| UI-15 | PARTIAL | UI |
| PERF-H01 | CONFIRMED | PERF-PASS2 |
| PERF-H02 | CONFIRMED | PERF-PASS2 |
| PERF-H03 | CONFIRMED | PERF-PASS2 |
| PERF-H04 | OUT_OF_SCOPE | PERF-PASS2 |
| PERF-H05 | CONFIRMED | PERF-PASS2 |
| PERF-H06 | PARTIAL | PERF-PASS2 |
| PERF-H07 | CONFIRMED | PERF-PASS2 |
| PERF-H08 | CONFIRMED | PERF-PASS2 |
| PERF-H09 | CONFIRMED | PERF-PASS2 |
| PERF-H10 | PARTIAL | PERF-PASS2 |
| PERF-H11 | CONFIRMED | PERF-PASS2 |
| PERF-H12 | PARTIAL | PERF-PASS2 |
| CMP-01 | CONFIRMED | PERF-PASS2 |
| CMP-02 | CONFIRMED | PERF-PASS2 |
| CMP-03 | CONFIRMED | PERF-PASS2 |
| CMP-04 | CONFIRMED | PERF-PASS2 |
| CMP-05 | CONFIRMED | PERF-PASS2 |
| CMP-06 | CONFIRMED | PERF-PASS2 |
| CMP-07 | CONFIRMED | PERF-PASS2 |
| CMP-08 | CONFIRMED | PERF-PASS2 |
| CMP-09 | CONFIRMED | PERF-PASS2 |
| CMP-10 | PARTIAL | PERF-PASS2 |
| CMP-11 | CONFIRMED | PERF-PASS2 |
| CMP-12 | CONFIRMED | PERF-PASS2 |

---

*Generated 2026-07-25 — merge of domain `_verify/*` passes; no production code changes in this step.*
