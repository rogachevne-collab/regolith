# Ropes!

Physically based ropes for Godot 4. XPBD solver in a C++ GDExtension, aimed at
believable rope behavior on low-end hardware. Works with stock Godot — no
engine fork, no custom physics server.

**Status: pre-alpha, gate 3 slice 1.** XPBD core as a reference GDScript
implementation (ADR 0002) with collision: contacts solved in the same
constraint loop, analytic narrow phase against box/sphere/plane colliders
cached once per tick, moving-collider transform interpolation, Coulomb
friction with honest stick/slide split (ADR 0006). Concave shapes and voxel
terrain are the next slice; anchors remain one-way kinematic pins (rigid-body
reaction is gate 4). Visual playground: demos/gate2_playground.tscn.

## Target usage

```
Player (RigidBody3D)
Crane (RigidBody3D)
Rope3D            length = 8.0, anchor_a = ../Crane, anchor_b = ../Player
```

Add a `Rope3D`, point its anchors at two nodes, press play. Free ends, world
collision and two-way forces on rigid bodies work out of the box.

## Public API

`Rope3D` is the only public node.

Properties:

- `length: float` — rest length, meters; mutable at runtime — the rope pays
  out / reels in at anchor A (the winch end), so a winch is just a tween on
  `length`
- `segments_per_meter: float` — simulation resolution
- `mass_per_meter: float` — linear density, kg/m
- `radius: float` — visual and collision radius, meters. Keep particle
  spacing (`1 / segments_per_meter`) within a few radii: contact is enforced
  at particles, so a coarse rope bent over a sharp edge shows its rendered
  tube cutting the corner. Measured on a 3.5 cm rope over a box edge: 20 cm
  spacing sinks the tube 2.2 cm, 10 cm spacing sinks it 0.9 cm.
- `anchor_a`, `anchor_b: NodePath` — `Node3D` an end is pinned to; a
  `PhysicsBody3D` also receives reaction impulses (gate 4); empty path =
  free end
- `use_project_gravity: bool`, `gravity: Vector3` — follow the project's
  gravity, or set your own for a gravity zone, another planet or zero-g
- `stretch_compliance: float` — m/N; 0 = as stiff as the budget allows
- `end_mass: float` — lumped mass in kg on the free B end (hook, weight)
- `damping: float` — 1/s, internal fiber friction: decays the relative
  velocity of neighboring particles, so it resists stretching, bending and
  vibration but can never slow a rope that falls or flies as a whole
- `drag: float` — 1/s, air resistance: decays absolute velocity and does
  impose a terminal speed of gravity/drag. 0 = vacuum (ADR 0003)
- `substeps`, `iterations` — budget knobs, per-rope for now (leaning:
  solver-global)
- `collision_enabled: bool`, `collision_mask: int`
- `friction: float` — Coulomb coefficient; static friction is what makes a
  wrap hold and a laid cable stay put

Properties are hot or cold. Hot ones (stiffness, damping, drag, budget,
radius) apply immediately. Cold ones (length, resolution, density, end mass,
anchors) change topology and re-seed the rope at the start of the next
physics tick, discarding its motion.

Methods:

- `get_particle_count() -> int`
- `get_particles() -> PackedVector3Array` — global space, physics rate,
  index 0 at anchor A
- `get_render_particles() -> PackedVector3Array` — interpolated for the
  current frame; attach visuals to these
- `get_segment_tension(i: int) -> float` — Newtons, from the solver's Lagrange
  multipliers, not estimated from geometry
- `apply_impulse(particle: int, impulse: Vector3)` — poke, grab, wind
- `teleport(delta: Vector3)` — rigidly move the rope, preserving shape and
  motion; use when an anchor jumps rather than travels
- `rebuild()` — re-seed immediately instead of waiting for the next tick

## Open problem

A very compliant rope carrying a heavy weight does not settle: at
`stretch_compliance` 0.005 m/N with 10 kg the peak-velocity envelope holds a
limit cycle instead of decaying, and the stretch keeps growing (358% at 8 s,
526% at 15 s under Earth gravity). Stiff ropes at the same load decay
normally, so this is specific to the soft-constraint regime. Unexplained;
do not treat high-compliance ropes as trustworthy yet.

## Known envelope

With `stretch_compliance = 0` the achieved stiffness depends on the solver
budget: heavy payloads on light ropes converge slowly, because a dual solver
like XPBD is ill-conditioned in mass ratio by construction (see
docs/research/mass-ratio-state-of-the-art.md).

Measured steady-state stretch, 4 m / 2 kg rope, 20 segments, g = 9.8, 60 Hz
(`bench/mass_ratio_bench.gd`; cost is GDScript reference, per step):

| payload | ratio | sub=8 | sub=16 | sub=32 | sub=64 |
|---|---|---|---|---|---|
| 2 kg | 1:1 | 0.60% | 0.15% | 0.04% | 0.01% |
| 20 kg | 10:1 | 4.38% | 1.07% | 0.27% | 0.07% |
| 200 kg | 100:1 | 38.4% | 10.2% | 2.60% | 0.65% |
| 2000 kg | 1000:1 | 234% | 107% | 26.1% | 6.05% |
| cost | | 150 us | 300 us | 600 us | 1200 us |

Two rules read off the table: stretch is roughly linear in mass ratio, and
roughly **inversely quadratic in substeps** — each doubling of substeps
costs 2x and buys 4x less stretch. So the budget needed for a target
accuracy grows only as the square root of the mass ratio.

Practical consequence: at 100:1 (a rover on a cable) 32 substeps already
gives 2.6% and 64 gives 0.65%, which in C++ is a fraction of a millisecond.
Ratios beyond ~1000:1 are where plain XPBD stops paying, and where the
candidates in the research note become worth their complexity.

## Design rules

1. The core is pure math over particle arrays (C++ GDExtension, no scene-tree
   access). Stretch, contact and attachment constraints are solved in one
   XPBD loop — no separate phases that can disagree.
2. Simulation steps on the fixed physics tick; rendering interpolates and
   never feeds anything back into simulation.
3. The world is reached only through public physics API (space queries,
   impulses on `RigidBody3D`). No engine patches.

## Roadmap

1. Public API draft (this document)
2. XPBD core, no collision — verified against the analytic catenary (shape
   and tension), analytic free fall (damping model, determinism), the
   compliance constitutive relation, and unilateral behavior
3. Collision, solved in the same constraint loop — slice 1 done
   (box/sphere/plane, friction, moving colliders; regression test is the
   old rope's killer scenario: an asymmetric drape over a box must settle,
   hold, not creep, not penetrate, and slide off only at zero friction);
   slice 2 is concave shapes / voxel terrain
4. Two-way coupling with rigid bodies
5. Performance, LOD, demos

## Open API questions

Informed by the Obi Rope precedent (docs/research/obi-rope-api-notes.md):

- Stiffness/damping — leaning: per-rope stretch compliance in m/N (0 =
  as stiff as the budget allows); damping and the quality dial (substeps)
  are solver-global, not per rope
- Mid-rope attachments — leaning: v1, as a list of
  {offset_m, node, compliance, break_force}
- Breaking / cutting — leaning: break_force (N) on attachments first;
  tearing the rope body itself later
- Winch limits of the `length` design (accepted for v0): feeding at anchor B
  needs a future `feed_end` enum; two simultaneous winches or mid-rope
  feeding cannot be expressed by a single total length — if ever needed,
  add additive methods on top, don't break `length`. A stalling winch
  (motor force limit) is game-side: read `get_segment_tension()` and decide

## License

MIT
