# Changelog

## 0.1.0-dev (unreleased)

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
