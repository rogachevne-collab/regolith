# Ropes!

Physically based ropes for Godot 4. XPBD solver in a C++ GDExtension, aimed at
believable rope behavior on low-end hardware. Works with stock Godot — no
engine fork, no custom physics server.

**Status: pre-alpha.** This is a public API draft; the simulation core is not
written yet.

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
- `radius: float` — visual and collision radius, meters
- `anchor_a`, `anchor_b: NodePath` — `Node3D` an end is pinned to; a
  `PhysicsBody3D` also receives reaction impulses; empty path = free end
- `collision_enabled: bool`, `collision_mask: int`

Methods:

- `get_particle_count() -> int`
- `get_particles() -> PackedVector3Array` — global space, index 0 at anchor A
- `get_segment_tension(i: int) -> float` — Newtons, from the solver's Lagrange
  multipliers, not estimated from geometry

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
2. XPBD core, no collision — hang and swing verified against the analytic
   catenary and pendulum period
3. Collision, solved in the same constraint loop
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
