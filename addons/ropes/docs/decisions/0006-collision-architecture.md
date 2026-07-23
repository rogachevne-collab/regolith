# 0006: Collision architecture

Date: 2026-07-23. Status: accepted.

Driven by the host project's stated requirements: realistic, fast on CPU,
must not pass through edges, can be wrapped around a box and stay alive,
collides with statics and dynamics, behaves attached to a moving vehicle or
an accelerating rocket (including a rope INSIDE the rocket).

## Decisions

1. **Contacts are constraint rows in the same iteration loop** as distance
   constraints (this is ADR 0001's founding principle — the old rope died of
   a separate collision phase). A contact is a unilateral plane constraint
   at the shape's closest point, compliance 0.
2. **Cache colliders, not contacts.** Once per physics tick the host asks
   the engine which bodies are near the rope (one broadphase query). Every
   substep the core evaluates exact signed distance to those cached shapes
   analytically — the engine is not involved in the hot loop. This is what
   lets a wrap around a box work: a frozen contact plane cannot represent
   "the particle went around the edge"; a live SDF can.
3. **Collider transforms interpolate across substeps** from the body's
   linear and angular velocity. A wall frozen for a whole tick teleports
   1.7 m at 100 m/s and the rope ends up inside the rocket's hull; a wall
   that advances 5 cm per substep pushes the rope honestly. This is the
   rope-inside-a-rocket case and it costs one transform lerp per collider
   per substep.
4. **Detection samples: particles plus segment midpoints,** corrections
   distributed to the two end particles by barycentric weight. Pure
   particle-only detection leaves gaps an edge can slip through; sample
   spacing (half a segment) is the honest resolution limit, and true
   capsule-vs-shape narrow phase is a C++ port refinement, not a GDScript
   reference concern. Temporal tunneling is bounded by substeps: at 32
   substeps a 20 m/s rope moves 1 cm per substep.
5. **Friction ships with collision, not after.** Coulomb model at the
   velocity stage: tangential velocity relative to the CONTACT SURFACE
   (which may be moving — rocket) is clamped by mu * N, with N taken from
   the accumulated contact lambda — the honest normal force, same
   bookkeeping as tension. Static friction below the cap zeroes tangential
   velocity exactly: this is what makes a wrap hold and a rope stay where
   it was laid.
6. **Restitution is 0 and the velocity fix runs once per particle after all
   its contacts.** Both halves are scars from the old rope: perfectly
   elastic contact meant a rope on a box never went quiescent, and damping
   per-contact instead of per-particle made it worse (measured back then).
7. **Gate 3 is one-way coupling:** static AND dynamic bodies move the rope
   (dynamics enter as moving colliders with real velocities); the rope
   pushes nothing back yet. Reaction impulses are gate 4, so convergence
   bugs and solver-vs-solver bugs never overlap.
8. **Self-contact: the neighbour case ships now, the general case is
   deferred.** Adjacent particles are held at least `2 * radius` apart —
   the rope has thickness against ITSELF, not only against the world, and
   a real rope cannot fold through its own body. Without it the model was
   inconsistent (radius r against the world, radius 0 against itself) and
   a rope dropped end-first collapsed to a single point: measured polyline
   length 4.0 m -> 0.0 m in under 3 s. A squashed segment carries no
   tension, so the multiplier and the tension readback are untouched.
   General pair-wise self-contact (spatial hash) remains its own gate;
   until then a pile does not spread laterally, it just cannot vanish.
9. **Unsupported shapes are skipped** with a one-time warning. Slice 1
   covers plane, sphere, box — the analytic set. Concave meshes and the
   host's voxel terrain need engine queries per substep or a local SDF
   cache; that is slice 2 and may need a host-side adapter.
10. **The C++ core computes in double internally regardless of engine
    precision** (from the rocket discussion: float32 at 10 km quantizes a
    25 cm segment length to ~0.5% noise via catastrophic cancellation).
    Float exists only at the API boundary. A per-rope local frame was
    considered and REJECTED: it cannot restore precision the engine's own
    float32 data never had, and it multiplies frame-convention bug surface.
    "Simulate in carrier-local space" may return later as an opt-in feature
    (Obi precedent), not as the foundation.

## Measured findings (2026-07-23, while closing the gate test)

- **Two-corner ratchet lock.** Frictionless material flow around TWO sharp
  90-degree corners jams at 20 cm particle spacing (a placed 2.1x-imbalanced
  drape just sits there); at 10 cm it flows; a SINGLE corner flows even at
  20 cm. Known polyline-discretization artifact: the inextensible rope
  cannot pay the periodic path-length cost of vertices popping over two
  corners at once. Friction masks it in practice; the capsule narrow phase
  in the C++ port should relax it. The drape test runs at 10 cm.
- **Corner chords are entitled to hug the edge.** A 10-20 cm segment bent
  90 degrees over a sharp edge MUST cut the corner with its chord; fighting
  that with midpoint contacts is wrong by construction. Rule: midpoint
  samples only act when at least one endpoint is contact-free (their job is
  the edge-into-the-gap case); particles keep the full radius, chords may
  come closer but never enter the solid. The test checks exactly that split.
- **Stuck contacts grab everything; sliding contacts stay inelastic in
  approach only.** Killing only approach velocity leaves the
  projection-manufactured separation speed alive — measured as a limit
  cycle GROWING 0.02 -> 0.05 m/s on a settled drape (the old rope's
  never-sleeps disease, reproduced). Killing both directions
  unconditionally froze corners so hard even a frictionless rope stopped
  sliding (measured). The physical split fixes both: when static friction
  wins, stiction zeroes all relative velocity; when sliding, only approach
  dies so velocity can rotate around corners. No tuning knobs involved.

- **A perfectly straight rope never buckles, and nothing inside the solver
  can fix that.** A rope dropped exactly end-first telescoped into a needle
  (polyline 4.0 m -> 1.4 m, horizontal spread exactly 0.000). Both obvious
  remedies were checked and REJECTED on the reasoning: a collinear column at
  two-radii spacing has no self-intersections (self-contact sees nothing to
  fix) and zero bend angle everywhere (bending constraints are satisfied).
  The mechanism is Euler buckling, the model has the instability, and the
  seed simply is not available: gravity is identical per particle, the box
  is axis-aligned, red-black sweeps produce no lateral component, and the
  arithmetic is bit-identical across particles. So the seed is supplied
  where it physically belongs — in the rope's SHAPE at seeding time, as a
  deterministic 0.1 mm deviation from straightness (`lay_line(a, b,
  jitter)`), never inside `step()`. Measured: 0.01 mm already converts the
  needle into a 30 cm-wide heap. Analytic tests pass jitter = 0 for exact
  lines.

- **Visible penetration at a sharp edge is the tube radius, not a contact
  failure, and it does not run away.** Measured over 60 s on a rope bent
  over a box corner: the centreline chord holds a FIXED clearance (0.0135 m
  at 20 cm spacing, 0.0256 m at 10 cm) and never drifts; particles are
  always a full radius clear. What the eye sees is the rendered tube — with
  radius 0.035 m around a chord 0.0135 m from the edge, 2.15 cm of tube is
  inside the box. On a free (unpinned) rope the clearance dips while the
  rope settles around the corner (worst 0.0023 m at t=25 s) and then
  RECOVERS (0.0106 m by t=60 s) — settling, not creep.
  The honest lever is particle spacing relative to rope radius, which is why
  Obi ties resolution to thickness: halving the spacing halved the tube
  sink. Segment (capsule) narrow phase in the C++ port removes it properly.

- **Cost is dominated by sample count, and colliders are culled per step.**
  Measured in the GDScript reference: a 77-segment rope against two
  colliders costs 5.8 ms per step — a third of a 60 Hz frame, for one rope,
  and identical under lunar and Earth gravity (this is resolution, not
  dynamics). A bounding-sphere reject per collider, once per step with a
  margin for this step's motion, removes the whole per-substep per-particle
  loop for anything out of reach: an airborne rope with the ground six
  meters below dropped from 2195 to 1472 us/step. The remaining floor is
  the solver itself, which is what the native core is for.

## Consequences

- Contact solve order is fixed and deterministic, but contacts are not
  order-independent between colliders the way red-black distance sweeps are
  (ADR 0005); determinism is still bit-exact, which is what the test pins.
- The GDScript reference will be slow with collision enabled (analytic SDF
  per sample per substep). That is accepted: the reference pins behavior at
  low resolution; "fast on CPU" is proven by the port.
- The gate test is the old rope's killer scenario, promoted to a regression
  test: a rope draped asymmetrically over a box must settle, stay, not
  penetrate, not creep, and slide off only when friction is zero.
