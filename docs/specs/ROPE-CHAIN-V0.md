# ROPE-CHAIN-V0 — physical rope/chain as its own thing

Status: spec (step 1). Step 0 (the game solver can lift a mass-coupled body)
is proven — see `scenes/demo_cable_lift.tscn` and `XpbdCableRopeSolver`'s
`couple_mass_a/b`.

## Goal

A **mechanical** rope/chain the player runs with a dedicated tool: it tows,
lifts and drapes, it does **not** conduct power, and it moves the bodies it is
tied to (mass coupling), unlike the electric cable which only tugs back.

"Done" = with the rope tool, the player draws a taut rope from an anchored
point (base / stake) to a loose rover and it **lifts** the rover; draws one
between two rovers and it **tows**; the link survives save/load; and the
existing electric cable behaviour is byte-for-byte unchanged.

## The one architectural decision — DECIDED: field, not a second entity

Keep **one link struct** (`IndustryElectricLink`) with an explicit
`kind: ELECTRIC | MECHANICAL`, rather than a second entity class.
(Confirmed 2026-07-24.)

Why: at the DATA level the two share almost everything — two endpoints,
`rest_length_m`, `break_force_n`, `baked_path_local`, waypoints, stake anchors,
tube rendering. They differ only in BEHAVIOUR: network membership and coupling.
An explicit `kind` field is not the accidental coupling we are escaping (that
was `is_rope()` inferred from empty ports); it is a declared type. The
separation the player feels — a different tool, no conduction, real lifting —
is all behavioural and is genuinely split below.

Cost of the alternative (a separate `MechanicalLink` class): a second store, a
second serialization path, a second projection tick loop, for a struct that is
95% identical. Rejected unless a concrete need appears.

## Model

Add to `IndustryElectricLink`:

- `kind: int` — `ELECTRIC` (default, current behaviour) or `MECHANICAL`.
- Serialized in `to_dict` / `from_dict`. Absent in old saves ⇒ `ELECTRIC`.

A `MECHANICAL` link:
- is **never** added to the electric graph (`IndustryElectricGraph.rebuild`
  skips it; `link_still_valid` / `rope_link_count` unaffected for electric).
- needs no electric ports on its endpoints.
- mass-couples any end whose body is a live (non-frozen) `RigidBody3D`.

## Behaviour

### Coupling (the lift/tow) — and why it fixes the park conflict for free

In `SimulationPhysicsProjection._tick_one_xpbd_rope`, pass
`couple_mass_a/b > 0` (the endpoint body's mass) **only when
`link.kind == MECHANICAL`** and that end is a live RigidBody. Electric links
pass 0 → they still pin, exactly as now.

This is the whole fix for the `debug_cable_lift` regression ("a taut still rope
must leave a park alone"): that test's rope is ELECTRIC, so once coupling is
gated on `MECHANICAL`, electric ropes never couple and the park contract is
untouched. No special-case needed — the split IS the fix. Delete the
`debug_cable_lift` flag; coupling becomes a property of the kind.

Effective mass = `body.mass` for V0. Actuator-aware backing (a piston head
standing in for the chassis behind it) is a later refinement, not V0.

Reuse `XpbdCableRopeSolver`'s coupling (already there): `_drive_end`,
`_settle_end`, `_apply_proxy_reaction`, `LIFT_COUPLING`.

### Steady hold (defer, but note)

A lifted load held still should eventually let its body sleep so the physics
does not churn — the freeze/bake pattern applied to the body, not the rope.
V0 ships correctness (it lifts and holds); the body-sleep optimisation is a
follow-up, not a gate.

### Break

Mechanical break force is a real load threshold on the link's `break_force_n`.
Use the **smoothed** endpoint tension (a few frames), not a single sample — a
swinging load's tension genuinely spikes (see `test_hang_tension.gd`).

## Tool

A separate tool `&"rope"` alongside `&"connect"` in `tool_controller.gd`:
- same click-to-click chaining, slack wheel, throw range, preview.
- same terrain handling: an end on bare ground drives a stake
  (`CableStakeUtil`) — see Anchor.
- emits `connect_network` with `kind = MECHANICAL` (a new parameter on the
  command / `connect_rope`).
- its own hotbar slot.

Factor the shared routing out of `_handle_connect_click` rather than copy it.

## Anchor — the stake is shared

No new anchor type. A stake is just a driven ground element with a collider;
its electric port is only used by a conducting link. A mechanical rope ties to
the **same** stake and ignores the port (the stake stays out of the electric
graph because no electric link touches it). The "dig the ground out → stake
tears loose → link dies" logic already serves both.

## Save / load

`kind` rides `to_dict`/`from_dict`. A mechanical link restores as a mechanical
link. The baked shape (`baked_path_local`) persists for mechanical same-body
utility ropes exactly as for electric ones. NOTE: the stake snapshot
round-trip is currently broken (`INDUSTRY-V1: ropes must survive a snapshot
round trip`) — fix that first or in parallel, it blocks ground-anchored ropes
of either kind surviving a save.

## Render

Reuse the tube (`CableCurveUtil.build_tube_mesh`) via
`IndustryNetworkProjection`. A distinct material (chain/steel look) is polish,
not V0. Frozen-tint diagnostic applies the same.

## Out of scope for V0

- A second entity class / second store.
- Actuator-aware effective mass.
- Body-sleep-while-holding optimisation.
- Chain-specific visuals / links-that-clink.
- Two-way tow feel tuning beyond "it works and does not explode".

## Verification (measure, then play)

1. Headless: a MECHANICAL link through the real projection lifts a 300 kg rover
   and tows one between two bodies — the Step-0 result, now via the link, not a
   probe.
2. Save/load round-trips a MECHANICAL link (kind, endpoints, rest, baked).
3. `KERNEL-PROJECTION` and `INDUSTRY-PORTS` stay green — electric untouched.
4. Eye: draw a rope with the new tool, lift/tow a rover, watch the feel.

## Decisions — CONFIRMED (2026-07-24)

- **Field, not a second entity.** One `IndustryElectricLink` struct with a
  `kind` field. ✓
- **A MECHANICAL link does NOT conduct.** Electric and mechanical are disjoint;
  a chain is not a power cable. No "live tow cable" in V0. ✓
- **Fix the stake save bug first.** `INDUSTRY-V1: ropes must survive a snapshot
  round trip` is a prerequisite — ground-anchored ropes of either kind must
  survive a save before shipping. ✓
