# Make testo great again

Research + concrete plan: why Regolith spoil reads as dough, what MudRunner
actually sells, and what to ship in order — without mutating CA truth.

Source canvas (live UI): Cursor project canvases /
`make-testo-great-again.canvas.tsx`.

Tags: **presentation only** · truth = `GranularVoxelField` @ 0.25 m · aligned
with `GRANULAR-V0` / `GRANULAR-V1`.

---

## Root cause (not “need finer CA”)

Production spoil is drawn as a second `VoxelTerrain` Transvoxel surface over
occupancy→SDF. Same mesher as rock → stone growth / clay blob. MudRunner never
did this: coarse truth + separate GPU stamp/shader layer. V0 already notes more
blur made tearing worse; finer cells alone will not fix the look.

MudRunner’s «CPU ≠ GPU нарочно» is the right architecture lesson — but the
first thing to steal is **identity of the resting pile** (material language +
grit silhouette), not the event VFX. Stream particles sell a second of motion;
the heap sits in frame the rest of the time.

| Area | Status |
|---|---|
| Voxel CA + dirty flush | exists |
| Shared planet material on spoil | exists (measured win) |
| Stream VFX asset | demo only (`granular_cascade.gd`) |
| Grain shell MultiMesh | spec’d |
| Wheel RT (planar, region-local) | missing; not a general 3D solution |

---

## Diagnosis: MudRunner vs us

| Layer | MudRunner / Spintires | Regolith today |
|---|---|---|
| Truth | 16×16 m heightfield blocks, empirical traction | `GranularVoxelField` fill @ 0.25 m (correct for volume) |
| Visual geometry | Lo-res mesh + 128² RT displace (≈12 cm/texel) | Occupancy blur → SDF → remesh (same as rock) |
| Material | Normal-driven blend + moisture/tint + track mask | **Same planet shader instance** as crust (correct after measured fix) |
| Motion sell | Slide offset (GB), particles, rigid mud chunks | CA cell hops; stream VFX only in cascade demo |
| Fake rule | CPU ≠ GPU on purpose (lead: vague physics link) | Contract OK; grain shell + event VFX not built on voxel path |

Sources: Game Developer Spintires mud article, 80.lv breakdown,
`GRANULAR-RESEARCH-SYNTHESIS`, `GRANULAR-V0` (grain shell), `GRANULAR-V1`
(dust ≠ debris, drop stone-growth mesh).

---

## What already exists (hooks)

### Production voxel path

- **Sim:** `granular_voxel_field.gd` / `region.gd` — dirty cells, deposit/dig
- **View:** `granular_voxel_region_view.gd` — `SMOOTH_PASSES=1`,
  `SURFACE_ISO=0.35`, **collisions off**; support via `dust_at`
- **Material:** live planet `ShaderMaterial` via `TerrainCompat` (shared
  instance — do not replace with a separate spoil palette)
- **World:** `granular_voxel_world.gd` in `main.tscn`

### Parked / demo toolkit

- **VFX:** `scenes/vfx/granular_stream_vfx.tscn` — Core+Haze; only
  `granular_cascade.gd` calls it
- **Heightfield:** `GranularFieldView` grain jitter + damp filter +
  `flowing_volume_m3` (not on voxel)
- **V0 plan:** MultiMesh shell ~10–15k on surface cells; particles on motion

---

## Impact vs cost (ship this order)

Order is **identity first, events third**. Cheap/low-risk for A1 is real, but
stream is a one-second event; the resting pile is what the eye sits on.

| # | Move | Kills which “testo” symptom | Cost | Risk |
|---|---|---|---|---|
| 1 | **A2:** planet shader + freshness uniforms (not a new spoil shader) | Fresh spoil reads as wrong palette / clay next to crust | ~hours | Low |
| 2 | **B1/B2:** grain shell MultiMesh + **binary** mesh threshold | Smooth clay silhouette; stone-growth body for thin heaps | 3–5 d | Med |
| 3 | **A1:** wire stream VFX to dig / spill / fall | Chunk falls as one fat hunk with no intermediate dust | 1–2 d | Low |
| 4 | **A3:** transfer/flow proxy → VFX rate + freshness drive | Static look while mass is moving | 2–3 d | Med |
| 5 | **C:** planar region RT tracks (explicitly not general) | No wheel readability on flat apron | 1 wk | Med–High |
| — | **Do NOT:** more smooth passes / finer CA / bilateral blur / particles as truth | Already proven worse / expensive | — | High waste |

Row formerly “alpha-fade coarse mesh”: superseded by B2 binary threshold.
Hiding/skipping mesh for thin cells is **Low** risk — spoil terrain no longer
collides; feet use `dust_at`.

---

## Phase order: A2 → B → A1 → A3 → C

### A2 — Planet shader + freshness (not a new spoil shader)

**Measured fact:** spoil looked like dough *because* it had its own material
(own tone, own frequency, no planet grading). Sharing the planet shader
instance fixed colour (“цвет попал”). A dedicated `spoil_surface.gdshader`
risks regressing that defect.

Difference between settled and freshly excavated regolith is **roughness,
normal response, slight darkening** — not another palette or lighting model.

1. Keep `TerrainCompat.get_surface_material` / shared planet `ShaderMaterial`
   on spoil terrain.
2. Extend the **existing** planet `.gdshader` with uniforms (or vertex COLOR)
   for freshness: roughness bump, normal scale, slight darken — driven by
   deposit age / fill / later flow proxy.
3. Playground fallback may stay `StandardMaterial3D` for the stand only; do
   not treat that as the world material target.
4. Headless: `./run.sh --headless res://scenes/main.tscn` — shader compile
   clean; eye check next to crust (no second palette).

### B1 — Surface shell extractor

1. From `GranularVoxelField`: cells with mass ≥ MIN and ≥1 empty / air face
   (or neighbor below threshold) → shell list.
2. Deterministic `hash(cell_id)` → 1–N grain transforms inside cell (jitter <
   `cell_size`), scale from mass fraction.
3. Rebuild shell only for dirty cells / dirty AABB — not full region every frame.

Files: new `granular_grain_shell.gd` under `presentation/`; driven by
RegionView or World after flush.

### B2 — MultiMesh + binary mesh threshold (no alpha fade)

**V0 / V1:** Mesh gives body for thick dust; grit silhouette needs instances.
Do not smooth between grains (mercury). Particles = flight only; resting =
deterministic MultiMesh. Target ~10–15k surface instances, not volume.

**Anti-pattern: alpha-fade under grains.** Dissolving the marching-cubes
surface under instances buys transparency sort + ghost crust; under hard lunar
shadows that is worse than either extreme. It also fights V1: thin dust is
**not geometry**.

1. `MultiMeshInstance3D`: low-poly pebble mesh; **same planet material** (+
   freshness uniforms from A2).
2. **Binary:** do not remesh / do not write cells below a thickness (or fill)
   threshold. Mesh exists only where dust has real body; everything thinner is
   grains only. Safety is the threshold, not alpha.
3. Collision already off; `dust_at` remains truth for feet — skipping thin mesh
   is Low risk.
4. Eye gate: apron reads as grit, not modelling clay; thick heap still has a
   solid body mesh; no ghost crust.

### B3 later — Virtual 0.125 LOD (optional)

Only after B1–B2: subdivide shell cells visually without changing CA. Skip if
MultiMesh already sells silhouette.

### A1 — Dig / pour / fall → GranularStreamVfx

Asset already declarative (R4). Only caller today: `granular_cascade.gd`.
Port after identity (A2+B) so the resting pile is already right.

1. Hooks on `GranularVoxelWorld` / Region: mass removed (`dig_at`), deposited
   (`deposit_*`), large fall (unsupported transfer > threshold).
2. Pool 1–N streams; `aim()` from edge centroid toward gravity (region up
   negated); rate from Δmass / flow proxy.
3. Kill particles after CA has restacked (V1 handoff — no double-volume blink).
4. Eye check: ledge pour shows stream between shelf and heap; logs clean.

Files: `granular_voxel_world.gd`, `granular_stream_vfx.*`, playground.

### A3 — Motion signal without full mobilize port

Heightfield has `_flowing` + `flowing_volume_m3`. Voxel field has dirty +
transfers but no presentation flux.

1. Track per-sweep transfer mass or dirty Δmass > ε; expose a
   `flowing_volume_m3()`-like API on region.
2. Drive stream intensity + **freshness uniforms** (not a second albedo).
3. Do not port full `GranularPatch` mobilize/`settle_load` here — feel/physics
   track, separate from “testo” look.

---

## Phase C — planar MudRunner tracks (explicitly not general)

MudRunner RT works because truth is a **2D heightfield** on 16×16 m blocks —
it maps to a 2D texture without seams or frame choice. Our truth is
**volumetric**, on a sphere, and exists for cases with **no** 2D
parameterization: material in a bore, against a wall, in a tunnel.

A planar RT **per region** is possible — the region has a local-up frame —
but that sells tracks only on the **flat apron / local patch** case. Record
that explicitly; do not treat C as the general spoil-track solution.

| Step | Action | Notes |
|---|---|---|
| C1 | Per-region Image/SubViewport 128² in region local XZ | R height offset, A track blend; wheel/foot contact |
| C2 | Sample in **planet** spoil path (uniforms / second sampler) | Darken + normal perturb; no POM until C1 reads |
| C3 | Slide offset RG + ping-pong blur | MudRunner GB; presentation only |
| C4 | Partial collision imprint (optional) | Only if tracks must affect wheels |

Spec refs: `GRANULAR-RESEARCH-SYNTHESIS` P3 #16–17. Do not drive CA from RT.
For bore/wall/tunnel tracks — separate problem (decal shells, local UV, or
skip until needed).

---

## Out of scope for “testo” look (do not mix into A/B)

**Separate tracks** (still required before spoil feels real — see DoD)

- Full mobilize / `settle_load` on voxel
- Scoop → processor haul loop
- Persistence / region LRU fix (V1 sink)
- **Dig dust along aim via field query** — volumetric spoil has **no collider**
  and no spoil body; physical ray has nothing to hit. Old wording
  «Drill `KIND_GRANULAR` on spoil body» is obsolete. Interaction is a field
  probe along the reticle, not a body kind.

**Anti-patterns** (yesterday’s dead ends — do not re-enter)

- `SMOOTH_PASSES` > 1 (proven worse; sparse fringe → longer slivers)
- Bilateral / liquid-style blur between grains (reads as mercury)
- Finer CA “for beauty”
- `GPUParticles` as volume truth
- **Separate spoil palette / lighting model** (regressed colour vs planet)
- **Alpha-fade of Transvoxel under grains** (sort ghosts + fights V1)

---

## Suggested sprint board

- [ ] A2: Planet shader freshness uniforms (roughness / normal / slight darken)
- [ ] B1: Surface shell extractor from dirty cells (deterministic hash)
- [ ] B2: MultiMesh grains + **binary** thickness threshold (no remesh below)
- [ ] A1: Hook `granular_stream_vfx` to voxel dig/deposit/fall
- [ ] A3: Transfer/flow proxy → VFX rate + freshness drive
- [ ] Eye gate: apron grit + thick body + ledge stream; no double-volume blink
- [ ] Interaction track (parallel, blocks “testo defeated”): dig along aim via
      field query; visible reaction (mobilize / remove / stream)
- [ ] C: Planar region RT tracks only after A/B pass; never claim general 3D

---

## Definition of done

**Look**

- Human in main/playground: spoil reads as grit/regolith next to crust, not
  modelling clay or a second palette.
- Thick heaps have body mesh; thin cover is grains only (no ghost alpha crust).
- Falling mass can show stream between detach and land; CA volume unchanged.
- No SCRIPT ERROR; shader compiles headless.

**Touch** (blocks calling “testo” defeated)

- A pretty pile you cannot affect still reads fake. Interaction stays a
  separate implementation track, but DoD is not met until the player can hit
  the heap with the drill (field query along aim) and see a reaction —
  mass move/remove and/or stream — not a no-op against invisible air.

Kernel tests only if A3 (or dig query) touches field API contracts — then
`run_one` relevant + `run_tests` if kernel changed.
