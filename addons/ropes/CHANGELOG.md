# Changelog

## 0.1.0-dev (unreleased)

- A rope no longer cuts through the block it is tied to. `Rope3D` used to
  exclude its anchor bodies from collision entirely, so a swinging load passed
  straight through its own cable. The exemption was on the wrong object: it
  belongs to the attachment POINTS, not to the body. Pins were already exempt
  by inverse mass 0; proxies now are too, in the core, because a proxy stands
  for a body the physics engine is already colliding on its own and the host
  discards its solved position anyway. Everything between the two ends is
  entitled to lie against the hull like any other surface. Measured on the
  gate 5 bench with the rover kicked into a swing: deepest approach into the
  block went from unbounded to +3.5 mm outside its face.
- Gate 5 bench: the rover's lifting eye stands proud of the hull instead of
  sitting flush with it. An attachment flush with a face means the rope leaves
  the body tangent to it, so the first segment grazes the surface on every
  swing and the rendered tube reads as sunk into the block — geometry asking
  for it, not a contact failure. With the lug the rope stays 22 cm clear.

- Collision broadphase was costing more than the solver it feeds: the gate 5
  bench ran at 38.8 ms a frame, and 22 ms of that was contact detection
  proving, twenty thousand times a tick, that a rope was not touching a pillar
  two metres to its left. Two fixes, both measured on that scene, together
  38.8 ms -> 6.9 ms a frame with the simulation bit-identical (same rover
  height to the millimetre after 14 s):
  - `RopeColliders.cull` compares real boxes instead of bounding spheres.
    Spheres lied in both directions: a rope is a line, so its sphere is mostly
    empty, and a gantry leg is a tall thin box whose sphere is 4.8 m of
    nothing. Everything in the scene read as "near"; now the scenery is
    rejected outright.
  - `XPBDRope._solve_contacts` rejects each sample against the collider's
    bounding sphere before the exact probe. The rope-wide cull only ever
    decided whether a collider is near the rope AT ALL; after it said yes,
    every particle paid for a full probe, every iteration of every substep.
  Neither changes what a contact is or how it is solved. The cost was
  proportional to substeps x iterations x colliders x particles, which is why
  it was invisible at gate 3's budget and fatal at gate 5's.

- Gate 3 slice 2 — collision with geometry that has no analytic form: concave
  meshes, heightmaps, voxel terrain. The host samples the world once per tick
  per particle (`RopeColliders.sample_local_planes`) and hands the core a
  contact plane each (`XPBDRope.local_planes`), solved as ordinary unilateral
  rows in the same loop, sharing the friction and velocity passes with the
  analytic shapes. The analytic pass keeps its shapes; whatever it already
  solves is excluded from the probe, because the same wall solved twice is
  the same wall with twice the friction. Limits, stated rather than
  discovered later: a plane per particle resolves nothing sharper than the
  particle spacing, and `probe_margin` is a speed limit — a rope crossing more
  than that in one tick meets a wall nobody sampled. Regolith's cables get the
  moon this way too (`XpbdCableRopeSolver`, 0.3 m margin).
- Gate 4 slice 2 — a `RigidBody3D` anchor is coupled by mass instead of
  pinned, which is what makes a rope able to lift. A pin has inverse mass 0,
  so the only mass a rope's constraints ever saw was its own fibre: tied to a
  300 kg rover it reported the same tension as tied to a nail, and handed the
  rover the weight of the rope. The end particle now carries the body's mass
  (`attach_proxy`), the constraint chain has to hold it up, and the momentum
  that costs is handed back each tick, minus gravity — the host's physics
  engine already applies that to the body, and leaving it in makes every rope
  a second gravity well. The anchor node no longer has to *be* the body: the
  nearest `RigidBody3D` above it is used, so a `Marker3D` hook couples its
  chassis. Frozen bodies stay pins, and switch back live.
- Gate 5 — `length` is a winch. Assigning it pays rope out or reels it in
  without re-seeding: shape, motion, pins, hooks and coupled bodies all
  survive (`XPBDRope.set_rest_length`). Lumped masses follow the new length,
  because a rope reeled in to a third of its length that still weighs the same
  hangs wrong and reads wrong. Resolution does not follow — the rope keeps the
  segment count it was seeded with, so a rope winched far past its original
  length gets coarse and the host decides when that deserves a `rebuild()`.
- New bench `demos/gate5_lift.tscn`: concave trimesh ground, a free rope
  draped over it, and a 300 kg rover lifted off it by a winch running to a
  kinematic piston head. Measured on it: the rover leaves the ground, holds
  height to ±5 cm, and the rope stretches 1.0% under load at 16 substeps / 4
  iterations, 0.2% at 32 / 8. The bob is unchanged by budget and is in the
  README's open problems.

- AVBD's beta derivation no longer reads the segment's own live multiplier
  (`core/avbd_rope.gd`, `_beta_for`'s call sites in `_substep` and
  `_update_contact_duals`). It used to be `maxf(lambda, floor)`, which is a
  closed loop — lambda feeds beta, beta sets how hard the next dual update
  may raise lambda — and was the mechanism behind three separate clamps
  added earlier the same day (the length guard's iteration ladder,
  `PENALTY_RAMP_MAX` on contacts, `MAX_GUESS_STRETCH` on the impulse path):
  each one narrowed a symptom of this loop without closing it. Now beta is
  driven only by the static weight the rope (+ payload) must carry.
  Measured, not assumed — full numbers on `_beta_for`'s docstring: the
  length guard's calibration is unchanged and under-budget tension error
  shrank by 2-6 orders of magnitude (`spike_g_length_guard.gd`), guarded
  AVBD contact settling improved on every metric (`spike_i_avbd_contacts.gd`
  guarded case), and the realistic impulse range is unchanged
  (`spike_j_impulse.gd`, 0.5-20 N*s). Cost: a single impulse far outside
  that range (>= 100 N*s to a 0.1 kg particle, i.e. >= 1000 m/s) now dies
  sooner than before (200 N*s ceiling -> 100 N*s), and the same
  `length_guard = false` + hand-picked-iterations mode `spike_i` uses to
  measure the guard is more fragile too — both costs land outside this
  file's supported envelope (guard on, realistic impulse), never inside it.
- Measured what the length guard is actually taxing, and it is the primal
  step, not the beta derivation (`spikes/spike_h_direct_primal.gd`). AVBD's
  primal Hessian is already block tridiagonal — particle i couples to i-1 and
  i+1 and to nothing else — so replacing the Gauss-Seidel sweep with an exact
  block-Thomas solve (`spikes/avbd_direct_rope.gd`, which overrides
  `_primal_sweep` and nothing else) collapses the guard's rule to the iteration
  floor across a 16x range in fineness: 20 m under 250 kg goes from 32
  iterations to 8, 5 m at 16 segments per metre from 64 to 8. Two pinned ends
  and a fully slack rope, the two cases a frozen active set should break, came
  back indistinguishable from the sweep. Not a clean win, though: on jitter it
  is 40x quieter at 20 m and *worse* at 50 m, where it plateaus near 3.4 mm
  while the sweep keeps falling to 1.53 mm — and damping the step to fix that
  diverges, because the dual and the derived beta both assume the primal step
  reaches its minimum. Not shipped; ADR 0008 records what contacts must avoid
  doing so that it stays available.
- AVBD length guard (ADR 0007). The AVBD core's tension readout degrades with
  rope size while its stretch column stays immaculate — 200 segments over 25 m
  read +10154% and looked perfect — so the failure was invisible in everything
  but the number the addon exists to deliver. Measured the bound
  (`spikes/spike_g_length_guard.gd`) and found the obvious hypothesis wrong:
  it is not the segment count, it is *fineness*, `segments / segment_length`.
  Refining a rope is more dangerous than lengthening it. `iterations` is now
  raised to the measured rule automatically, floored at 8, capped at 96, and a
  rope past the cap warns in the inspector and the log instead of quietly
  reporting nonsense. Clamped inside the core too, so the core cannot be driven
  outside its envelope by a caller who never read the docs. New test
  `test_length_guard.gd`; rule and cost in the research note.
- Per-rope gravity (`use_project_gravity`, `gravity`) and a lay direction
  for free ropes (`lay_direction`), both hot. Playground: G toggles
  Moon/Earth gravity live, and a second cube carries the same rope draped
  free, for comparison with the anchored one.
- Gate 3 slice 1 — collision (ADR 0006): contacts as unilateral constraint
  rows in the same iteration loop; colliders cached once per tick, analytic
  SDF narrow phase (box/sphere/plane) every substep with transform
  interpolation from body velocities; Coulomb friction from accumulated
  contact lambda with a physical stick/slide split (stuck grabs everything,
  sliding is inelastic in approach only); restitution 0. Neighbouring
  particles now respect the rope's own thickness (min separation of two
  radii) — without it a rope dropped end-first collapsed to a point. New
  `friction` knob; `collision_enabled`/`collision_mask` now live.
  Regression test `test_drape.gd`; playground grew a cube, a draped rope
  and an edge-drop rope.

- Test harness (`tests/rope_test.gd`): shared checks and a guaranteed
  `quit()`; the runner adds a hard per-test OS timeout, so a hung or crashed
  test is reported within seconds instead of spinning the engine forever.
- New tests closing the review's coverage gap — the two things that make
  this XPBD rather than PBD: `test_compliance.gd` (stretch == compliance x
  tension, per segment) and `test_unilateral.gd` (a rope pulls, never
  pushes; and it is still alive in the stretch direction).
- Mass-ratio baseline benchmark (`bench/mass_ratio_bench.gd`) and the
  measured envelope in the README; state-of-the-art survey in
  `docs/research/mass-ratio-state-of-the-art.md`.
- Damping split into internal fiber friction (`damping`, Galilean invariant)
  and air resistance (`drag`), replacing global velocity decay (ADR 0003).
- Red-black constraint sweeps: deterministic, order-independent, parallel-
  ready for the C++ port (ADR 0005).
- API invariants (ADR 0004): renderer topology derives from pushed state,
  `teleport()` split from anchor travel, anchor velocity feeds damping,
  hot/cold property taxonomy with immediate or next-tick application,
  `dt > 0` and positive-mass preconditions, borrowed-array contract.
- Tension now readable for a compliant segment between two pinned ends.
- New test: `test_free_fall.gd` — analytic free fall, damping invariance,
  analytic linear drag, solver determinism.
- Renderer v2: seamless tube swept along a Catmull-Rom curve through the
  particles (parallel-transport frames, smooth per-vertex tension gradient)
  instead of a cylinder per segment.
- Gate 2: XPBD reference core (stretch constraints, unilateral, compliance,
  substeps, Lagrange-multiplier tension), tension-colored interpolated
  renderer, catenary test (sag + tension vs analytic), visual playground
  with pokeable hanging weights.
- New API: `stretch_compliance`, `end_mass`, budget knobs, `apply_impulse`,
  `get_render_particles`, `rebuild`.
- Addon skeleton; `Rope3D` public API draft.
