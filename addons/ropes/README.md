# Ropes!

Physically based ropes for Godot 4. Target: XPBD solver in a C++ GDExtension,
believable rope behavior on low-end hardware. Works with stock Godot — no
engine fork, no custom physics server.

**Status: pre-alpha, gate 5.** Shipping today is the XPBD reference core in
GDScript (ADR 0002) with collision against the analytic shapes *and* against
concave / voxel geometry, mass-coupled `RigidBody3D` anchors, and `length` as
a live winch. A rope can hold a rover off the ground and reel it in. Next: the
C++ GDExtension port, which is still the production performance path — nothing
here is fast yet. AVBD (ADR 0007/0008) is parked.

`demos/gate5_lift.tscn` is the bench for all three: a concave trimesh floor, a
free rope draped over it, and a 300 kg rover winched off the ground by a rope
running to a kinematic piston head.

## Target usage

```
Player (RigidBody3D)
Crane (RigidBody3D)
Rope3D            length = 8.0, anchor_a = ../Crane, anchor_b = ../Player
```

Add a `Rope3D`, point its anchors at two nodes, press play. Free ends and
world collision (box/sphere/plane) work today. Anchors on `PhysicsBody3D`
receive reaction impulses from segment tension (gate 4).

## Public API

`Rope3D` is the only public node.

Properties:

- `length: float` — rest length, meters. Today cold: changing it re-seeds
  the rope and drops motion. Gate 5 makes pay-out / reel-in a smooth winch
  at anchor A (a tween on `length` then, not a snap)
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
- `concave_collision: bool` — also collide with geometry that has no analytic
  form: concave meshes, heightmaps, voxel terrain. One physics query per
  particle per tick, on the same `collision_mask`
- `probe_margin: float` — how far ahead of the rope that query looks, and
  therefore the rope's speed limit against such geometry: whatever it crosses
  in one tick beyond this margin was never sampled and is not there

Properties are hot or cold. Hot ones (length, stiffness, damping, drag,
budget, radius, collision) apply immediately. Cold ones (resolution, density,
end mass, anchors) change topology and re-seed the rope at the start of the
next physics tick, discarding its motion.

### Anchors are pins or masses

An anchor node the rope cannot move — a crane arm, an `AnimatableBody3D`
piston head, a frozen body, a bare `Node3D` — is a **kinematic pin**: the host
says where it is and the rope obeys.

An anchor that resolves to a live `RigidBody3D` (itself, or the nearest one
above it, so a `Marker3D` hook bolted under a chassis couples the chassis) is
**coupled by mass** instead. Its end particle carries the body's mass, so the
rope's own constraints have to hold the body up, and the momentum they spend
is handed back to the body each tick.

The difference is the whole reason a rope can lift anything. A kinematic end
has inverse mass 0, so the only mass the rope's constraints ever see is its
own fibre: a rope tied to a 500 kg rover reports the same tension as one tied
to a nail, and the reaction the rover gets is the weight of the rope.

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
- `segment_count() -> int` — `length * segments_per_meter`, rounded up
- `solver_iterations() -> int`, `tension_readout_warning() -> String` —
  size-envelope hooks for a core whose tension readout degrades with rope
  size (AVBD; parked). Both return nothing on the XPBD core shipping today,
  whose tension holds at every length measured.

## Open problems

A mass-coupled body does not hang steadily, it hangs in catches. Measured on
`demos/gate5_lift.tscn` (300 kg rover, 5 m rope, 0.6 kg/m, 60 Hz): the rover
holds its height to about ±5 cm and the tension readout swings between ~170 N
and ~2400 N rather than sitting at the rover's 2940 N weight. Budget buys
stretch, not steadiness — going from 16 substeps / 4 iterations to 32 / 8 cut
the rope's stretch under load from 1.0% to 0.2% and left the bob unchanged.
It looks like a load being caught and dropped each cycle rather than carried,
so read `get_segment_tension` as a spiky signal, and do not use a single
sample of it for a break check yet.

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

1. Public API draft (this document) — done
2. XPBD core, no collision — done (catenary, free fall, compliance,
   unilateral gates)
3. Collision, solved in the same constraint loop — done. Slice 1: the
   analytic set (box/sphere/plane, friction, moving colliders; regression
   test is the old rope's killer scenario: an asymmetric drape over a box
   must settle, hold, not creep, not penetrate, and slide off only at zero
   friction). Slice 2: concave shapes and voxel terrain, as one host-sampled
   contact plane per particle per tick
4. Two-way coupling with rigid bodies — done. A `RigidBody3D` anchor is
   coupled by mass, not pinned, so the rope carries it (Regolith's
   `XpbdCableRopeSolver` still pins: its cables run between parts of one
   machine, where two anchor reactions are a torque couple)
5. Winch on `length`, no re-seed — done
6. C++ GDExtension port of the XPBD core; performance, LOD, demos

AVBD remains a researched alternative for load-bearing mass ratios
(ADR 0007/0008, spikes under `spikes/`) but is not on the shipping path
while paused.

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
