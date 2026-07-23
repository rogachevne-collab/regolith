# Changelog

## 0.1.0-dev (unreleased)

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
