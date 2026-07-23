# 0004: Make illegal states unrepresentable, not merely unreachable

Date: 2026-07-23. Status: accepted.

## Context

A review found several defects that shared one shape: a valid-looking API
that could be called in an order producing nonsense.

- The renderer was configured with a segment count separately from being fed
  particle snapshots, so re-seeding the rope left it configured for a new
  topology while still holding old data — and its own size guard could not
  see the mismatch.
- `move_pin()` meant two different things: "the anchor traveled here" and
  "the anchor jumped here". A 1000 m jump produced a 5.5e4 m/s transient.
- Node properties were copied into the solver only during `rebuild()`, so
  `rope.damping = 1.0` at runtime was a silent no-op — while the class
  documentation singled out only `length` as needing a rebuild.
- `step(0.0)` and `mass_per_meter = 0` each produced all-NaN state in one
  step.

## Decision

Fix the shape, not the instances.

1. **Renderer topology is derived from data.** `configure()` takes visual
   parameters only; `push_state()` notices a particle-count change and
   rebuilds its own buffers. There is no configured-but-unfed state to
   desync, so no call order can produce one.
2. **Travel and teleport are different operations.** `move_pin(index, to,
   velocity)` carries the anchor's real velocity, which is also the damping
   reference for its neighbors. `teleport(delta)` rigidly moves the whole
   rope, preserving shape and velocities, manufacturing no constraint
   violation. The ambiguity was in the API, not in the math — so no
   correction clamp was added; a clamp would have silently converted "you
   left the solver's validity domain" into plausible-looking garbage.
3. **Properties are typed hot or cold.** Hot (stiffness, damping, drag,
   budget, radius) apply immediately through setters. Cold (length,
   resolution, density, end mass, anchors) change topology and re-seed at
   the start of the next physics tick — a defined point, never mid-frame.
   Silent no-ops are gone in both directions.
4. **Preconditions are stated and enforced.** `dt > 0` and positive masses
   are asserted in debug and clamped in release. The core is the contract
   the C++ port must satisfy, so its domain must be written down.
5. **Arrays are borrowed, uniformly.** Every public array is valid until the
   next `step()`; callers copy what they keep. Packed arrays are reference
   types in this build, so relying on copy semantics would have been an
   accident waiting for the port.

## Consequences

- The validity domain is now documented rather than defended by fudge
  factors: violations are assumed small relative to a segment's rest length
  per substep, and `teleport()` exists for the legitimate way out.
- A max-velocity safety rail (Obi ships one) is deliberately NOT added yet.
  Revisit at gate 3, when contacts can inject energy and the rail would
  guard a real mechanism rather than a hypothetical one.
