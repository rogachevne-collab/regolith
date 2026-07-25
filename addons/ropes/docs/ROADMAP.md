# Roadmap to 0.1.0

Written 2026-07-25, after a gap analysis against what shipping rope products
promise (Obi Rope, Rope Toolkit, Ultimate Rope Editor, verlet-rope-4, and the
`Rope3D` engine proposal godotengine/godot-proposals#3704).

## Where we stand

Gates 1-5 are done: the XPBD reference core in GDScript, collision against
analytic *and* concave/voxel geometry, mass-coupled `RigidBody3D` anchors,
`length` as a live winch. A rope holds a 300 kg rover off the ground and
reels it in.

The physics is ahead of the field. The *plugin* is not: `plugin.gd` is a
three-line stub, `Rope3D` disables its own processing in the editor, the
renderer hardcodes a debug material, there are zero signals in the whole
addon, and anchors are cold so nothing can be hooked up at runtime without
throwing the rope's motion away.

## Positioning, which decides what gets cut

Every rope addon in the Godot ecosystem is **decorative**: Verlet, looks
right, carries nothing. Ours is **load-bearing** — it holds a rover and
reports the force in newtons at every segment. That is the one thing nobody
else offers, and it is already built.

So the release is not "another rope addon, but ours." It is: *the rope you
can hang something off.* Anything that protects that claim ships. Anything
that dilutes it waits.

Two consequences:

- Exact tension (`get_segment_tension`) is the headline feature, and it is
  the natural input to breaking — gate 9 is the payoff of work already done.
- Concave/voxel collision and the published mass-ratio envelope stay in the
  README as evidence, not footnotes. Obi's attachment docs say "keep the
  particle/rigidbody mass ratio small"; we print the table instead.

## Table stakes we do not have

Not a wishlist — each one is promised by at least two of the four products
studied, and their absence is what a new user hits in the first ten minutes:

| Expectation | Who promises it | Us today |
|---|---|---|
| Simulation/preview in the editor | Obi, verlet-rope-4, Ultimate, Rope Toolkit | nothing renders until Play |
| Tearing / cutting at runtime | Obi (`Tear`, tear resistance N), Rope Toolkit (`SplitAt`) | none |
| Named attachment types, runtime attach/detach | Rope Toolkit (4 types + a demo scene), Obi (static/dynamic + break force) | 2 cold `NodePath`s |
| Textured spline mesh (UV tiling, normal map) | verlet-rope-4, Obi | debug vertex colors, no UVs |
| Self-collision | Obi (per-actor checkbox, plus inter-actor in one solver) | a coil passes through itself |
| Culling / sleeping / global budget | Obi (camera culling, modular solver), verlet-rope-4 (visibility culling) | every rope solves every tick |
| Wind | verlet-rope-4, proposal #3704 | `apply_impulse` by hand |
| Use-case demo scenes | Rope Toolkit (crane, bridge, swing, ring), Ultimate (4 scenes) | `gate2_playground`, `gate5_lift` |

## Order of work

Gates 1-5 keep their numbers — they are referenced across the ADRs and the
changelog. The C++ port, previously gate 6, moves to the end: most of what
follows lives in `Rope3D`, the renderer and the plugin script, and the port
cannot invalidate any of it.

Two gates do reach into the solver, and they are placed early on purpose,
while the collision work is still warm:

- **Gate 8 (self-collision + bending)** is a direct continuation of gate 3,
  not a new subsystem. ADR 0006's decision 2 — cache the *sources*, not the
  contacts; rebuild them once per tick, evaluate distance analytically every
  substep — describes a particle broadphase exactly as well as it describes
  the collider cache. The contact response, friction included, is already
  source-agnostic (`_note_contact`, `_solve_contact_velocities`), and ADR
  0001's founding rule means a new constraint type is a row in the existing
  loop, not a phase beside it.
- **Gate 9 (breaking/cutting)** changes topology, so it is designed with the
  port in mind: one documented rebuild path, reused by cut, break and winch,
  not ad-hoc array surgery.

### Gate 0 — debt, blocks release

The one real open problem: a very compliant rope carrying a heavy weight does
not settle. At `stretch_compliance` 0.005 m/N with 10 kg the peak-velocity
envelope holds a limit cycle instead of decaying, and stretch grows (358% at
8 s, 526% at 15 s). Stiff ropes at the same load decay normally, so this is
specific to the soft-constraint regime, and it is unexplained.

Ships either explained and fixed, or with `stretch_compliance` clamped to the
regime we can stand behind and the limit documented. Shipping a knob that
silently diverges is not an option.

### Gate 6 — visible in the editor

- `@icon` on `Rope3D`; the node is recognisable in the Add Node dialog
- `EditorNode3DGizmoPlugin`: the rope drawn at edit time, handles on the
  anchors and on `length`
- `preview` property: `SHAPE` (analytic catenary between the resolved
  anchors, the default) or `SIMULATE` (the real solver, budget-limited,
  auto-paused once quiescent)

Why the analytic default: the editor has no running physics space, so a
faithful in-editor simulation cannot see colliders and would preview a
different rope than the game shows. A catenary is honest about being a
sketch. `SIMULATE` stays available for free ropes where it is truthful.

Acceptance: drop `Rope3D` into an empty scene, set two anchors, see the
drape and drag it — without pressing Play.

### Gate 7 — it looks like a rope

- `material: Material` on the node; the renderer stops owning
  `material_override`. Default is a plain rope material, not the tension ramp
- UVs along the rope with `uv_scale` tiling, plus normals and tangents so a
  normal map works
- tension colouring becomes `debug_draw_tension`, off by default
- `radial_segments` exposed; distance LOD on radial and curve subdivision
- end caps
- mesh buffers reused instead of rebuilt each frame

Acceptance: a rope texture tiles without a seam and without twist over a
twisted rope; changing the material in the inspector takes effect live.

### Gate 8 — it collides with itself

The continuation of gate 3, and the last piece of "the rope is a real object"
rather than a curve that happens to avoid the world.

- particle broadphase: a uniform spatial hash over particle positions, built
  once per tick with a margin covering the tick's motion, exactly as the
  collider cache is built — pairs, not contacts, are what gets cached
- self-contact as a constraint row in the same loop, symmetric: both sides
  carry mass, unlike a collider plane with one infinite-mass side. Friction
  comes free — `_note_contact` and `_solve_contact_velocities` do not care
  where a contact came from
- neighbour exclusion: pairs within ±k indices are the distance constraint's
  job, not contact's
- inter-rope contact falls out of the same hash when ropes share a solver
  budget (gate 11); ship it if it is free, defer it if it is not
- **bending resistance** as a second new constraint row over (i-1, i, i+1),
  with a compliance knob and a dead zone. Self-contact alone stops a rope
  passing through itself; it does not give a knot that holds or a coil that
  stacks — those need a rope that resists being folded to zero radius

Acceptance, in that order of ambition: a rope dropped on the floor piles
instead of intersecting itself; a rope wrapped twice around a bar shows two
distinct turns under load; with bending on, an overhand knot pulled tight
holds and does not slip through itself.

If bending proves expensive on the GDScript core, it — and only it — drops
to after the port; the roadmap does not slip for it.

### Gate 9 — it breaks and it cuts

- `break_force: float` (N) on the rope body and per attachment; `tear_rate`
  (particles/frame, Obi's guard against everything failing in one tick)
- `cut(particle: int)` and `split_at(distance_m: float) -> Rope3D` — the
  second half comes back as a new sibling node
- signals: `broke(particle)`, `cut_at(particle)`, `tension_exceeded(particle,
  newtons)`
- one documented topology-rebuild path in the core, reused by cut, break and
  the winch

Acceptance: 300 kg on a 2000 N rope parts; cut a settled rope in the middle
and both halves keep simulating, total length is conserved, the load falls.

### Gate 10 — it hooks up at runtime

- anchors become hot: rebinding an anchor keeps the rope's shape and motion
- `attach(particle, node, compliance, break_force)` / `detach(id)` for
  mid-rope attachments
- `closest_particle(world_position) -> int` — the helper grappling, grabbing
  and cutting all need
- the four attachment types named and documented the way Rope Toolkit does:
  pin rope to node, pin node to rope, pull body to rope, two-way coupling

Acceptance: a demo hooks a flying crate mid-air, releases it, and the rope
never teleports.

### Gate 11 — it scales

- sleeping: a quiescent rope stops solving; woken by contact, impulse, or a
  moving anchor
- visibility culling with a policy (pause / decimate) rather than a hard stop
- a solver-global budget (substeps, damping) with per-rope override, matching
  Obi's precedent and this README's own "Open API questions" leaning
- distance LOD on `segments_per_meter`

Acceptance: 30 ropes in a scene hold frame rate; sleeping ropes cost zero,
measured, in the bench.

### Gate 12 — state and wind

- `get_state()` / `set_state()` so a save round-trips shape *and* motion
- wind: a shared noise resource plus per-rope `wind_force`, the shape
  verlet-rope-4 uses and #3704 asks for

Acceptance: save and load in a demo restores the rope mid-swing; one wind
resource moves a whole scene of ropes.

### Gate 13 — showcase and release

- demo scenes named after what people build: grappling hook, crane with a
  pulley, rope bridge, hanging decor (the first two are #3704's stated use
  cases)
- README: Installation, the supported Godot version, a three-step quickstart,
  animated captures
- CI: the headless `tests/` suite on every push
- Asset Library packaging; changelog cut for a release rather than a diary

Acceptance: a clean project plus this addon plus one demo, running, with no
step not written down.

### Gate 14 — C++ GDExtension port

The production performance path. The GDScript core stays as the reference
implementation the port is diffed against: the existing `tests/` suite is the
contract, and both cores must pass it identically before the switch.

Target for the release note: the same numbers the field publishes — Rope
Toolkit advertises ~0.2 ms on job threads and ~0.7 ms on the main thread with
collisions.

Moves earlier if gate 11 cannot reach 30 ropes in GDScript; that is the one
trigger that reorders this plan.

## Not in 0.1.0

Stated so they stop being ambient guilt: 2D ropes, closed loops, cloth,
deterministic/networked simulation, and AVBD (ADR 0007/0008 — researched,
parked, off the shipping path). Rope-to-rope contact is conditional: it comes
free with gate 8's hash or it waits.
