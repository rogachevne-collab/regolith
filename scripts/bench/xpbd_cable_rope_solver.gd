class_name XpbdCableRopeSolver
extends RefCounted
## Drop-in facade over addons/ropes/core/xpbd_rope.gd matching
## CableRopeSolver's own static interface — create_state / step / path /
## pull_direction / routed_length_m, same signatures, same Dictionary-shaped
## state — so a call site can point here instead without changing shape.
##
## PREVIEW-ONLY as of 2026-07-23: wired into cable_routing_preview.gd behind a
## toggle. Nowhere near simulation_physics_projection.gd's production tick,
## and it must not be, yet: scripts/bench (run against scenes/bench_ropes.tscn)
## measured this core going up to 1.15 m INSIDE a box collider in scenarios
## that mirror a cable draped on or routed through a machine — the exact
## phantom-length disease CableRopeSolver.routed_length_m's own docstring
## describes curing once already ("a rope merely lying on a machine reported
## over a metre of stretch and the tension solver hauled on the machine
## without pause"). A preview never applies force to anything, so it is safe
## to look at regardless — the player may well SEE that same penetration here
## too, which is expected and useful, not a sign the wiring is wrong.
##
## Seeding is naive by comparison to the original: a straight line plus the
## core's own anti-buckling jitter, no sag-shaped seed curve and no
## ray-cast-and-lift-out-of-geometry pass (CableRopeSolver._seed_point /
## _lift_out_of_geometry). A rope aimed straight through a block is born
## buried here and has to solve its own way out, where the reference seeds it
## already clear. Good enough to look at; not a claim the seeding is equal.

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

## Matches CableRopeSolver's own density and range exactly, so a side-by-side
## comparison is about the solver, not about one rope being simulated coarser
## than the other.
const SEGMENT_TARGET_M := 0.35
const MIN_PARTICLES := 6
const MAX_PARTICLES := 64
## A power/data cable, not a tow rope — thin and light. No canonical value
## exists yet for industrial cables (IndustryElectricLink carries no mass
## field); picked to look right at ROPE_RADIUS, not measured against anything.
const MASS_PER_M := 0.15
## Matches cable_routing_preview.gd's own ROPE_RADIUS.
const RADIUS := 0.024
const SUBSTEPS := 8
const ITERATIONS := 1
## Matches CableRopeSolver.COLLISION_MASK.
const COLLISION_MASK := 3
const QUERY_MARGIN_M := 1.0


static func particle_count(rest_length_m: float, span_m: float) -> int:
	var length := maxf(rest_length_m, span_m)
	return clampi(
		int(ceil(length / SEGMENT_TARGET_M)) + 1, MIN_PARTICLES, MAX_PARTICLES
	)


static func create_state(
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_length_m: float,
	_up: Vector3 = Vector3.UP,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	var count := particle_count(rest_length_m, anchor_a.distance_to(anchor_b))
	var sim := XPBDRope.new()
	sim.setup(count - 1, rest_length_m, MASS_PER_M)
	sim.radius = RADIUS
	sim.substeps = SUBSTEPS
	sim.iterations = ITERATIONS
	sim.lay_line(anchor_a, anchor_b, 0.0001)
	sim.pin(0)
	sim.pin(count - 1)
	if space_state != null:
		sim.colliders = _gather_colliders(sim.positions, space_state)
	return {"sim": sim}


static func step(
	state: Dictionary,
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_length_m: float,
	gravity: Vector3,
	delta: float,
	space_state: PhysicsDirectSpaceState3D = null,
	collide_shapes: bool = true
) -> void:
	var sim: XPBDRope = state.get("sim")
	if sim == null or delta <= 0.0:
		return
	var wanted := particle_count(rest_length_m, anchor_a.distance_to(anchor_b))
	if wanted != sim.segment_count() + 1:
		# Only a particle-COUNT change reseeds — same rule as
		# CableRopeSolver._resize_if_needed. A rope reseeded every time the
		# slack wheel or a dragged free end nudges the rest length can never
		# settle; that was the routing jitter this rule already fixed once.
		var fresh: Dictionary = create_state(
			anchor_a, anchor_b, rest_length_m, gravity, space_state
		)
		sim = fresh.sim
		state["sim"] = sim
	else:
		var seg_rest := rest_length_m / float(sim.segment_count())
		if not is_equal_approx(sim.rest_lengths[0], seg_rest):
			for j in sim.rest_lengths.size():
				sim.rest_lengths[j] = seg_rest
	sim.gravity = gravity
	sim.move_pin(0, anchor_a)
	sim.move_pin(sim.segment_count(), anchor_b)
	if collide_shapes and space_state != null:
		sim.colliders = _gather_colliders(sim.positions, space_state)
	elif not collide_shapes:
		sim.colliders = []
	sim.step(delta)


static func path(state: Dictionary) -> PackedVector3Array:
	var sim: XPBDRope = state.get("sim")
	return sim.positions.duplicate() if sim != null else PackedVector3Array()


## Direction the rope pulls at the anchor: the first (or last) segment, not
## the straight line to the far end — identical contract to
## CableRopeSolver.pull_direction, unused by the preview today but kept so
## this facade is a complete stand-in, not a partial one that only happens to
## cover the preview's call sites.
static func pull_direction(state: Dictionary, from_end_a: bool) -> Vector3:
	var positions := path(state)
	if positions.size() < 2:
		return Vector3.ZERO
	var anchor := positions[0] if from_end_a else positions[positions.size() - 1]
	var neighbour := (
		positions[1] if from_end_a else positions[positions.size() - 2]
	)
	var direction := neighbour - anchor
	if direction.length_squared() <= 0.000001:
		return Vector3.ZERO
	return direction.normalized()


## The drawn polyline. Safe to read directly here — unlike CableRopeSolver's
## routed_length_m, which deliberately reads a separately-cached
## solved_length_m instead of the raw path (see that function's own
## docstring): XPBD solves distance AND contact constraints in the same
## iteration loop (ADR 0006 in addons/ropes), so by the time step() returns,
## the path and the constraint forces already agree. There is no second,
## collision-inflated shape for this number to fall out of sync with.
static func routed_length_m(state: Dictionary) -> float:
	var sim: XPBDRope = state.get("sim")
	return sim.total_polyline_length() if sim != null else 0.0


## Ported from Rope3D._gather_colliders / RopeBenchXpbdAdapter — same shape
## conversion for the same reason: a different narrow phase here would mean
## this facade is not actually measuring the core production would run.
static func _gather_colliders(
	positions: PackedVector3Array, space_state: PhysicsDirectSpaceState3D
) -> Array[Dictionary]:
	if positions.is_empty():
		return []
	var lo := positions[0]
	var hi := lo
	for p: Vector3 in positions:
		lo = lo.min(p)
		hi = hi.max(p)
	var center := (lo + hi) * 0.5
	var query_shape := SphereShape3D.new()
	query_shape.radius = (hi - lo).length() * 0.5 + QUERY_MARGIN_M

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = query_shape
	query.transform = Transform3D(Basis.IDENTITY, center)
	query.collision_mask = COLLISION_MASK

	var out: Array[Dictionary] = []
	var hits := space_state.intersect_shape(query, 16)
	for hit: Dictionary in hits:
		var obj := hit.collider as CollisionObject3D
		if obj == null:
			continue
		var owner_id: int = obj.shape_find_owner(hit.shape)
		var shape_res := obj.shape_owner_get_shape(owner_id, 0)
		var xf := obj.global_transform * obj.shape_owner_get_transform(owner_id)
		var entry := {}
		if shape_res is BoxShape3D:
			entry.shape = XPBDRope.SHAPE_BOX
			entry.params = (shape_res as BoxShape3D).size * 0.5
		elif shape_res is SphereShape3D:
			entry.shape = XPBDRope.SHAPE_SPHERE
			entry.params = Vector3((shape_res as SphereShape3D).radius, 0, 0)
		elif shape_res is WorldBoundaryShape3D:
			var plane := (shape_res as WorldBoundaryShape3D).plane
			var n := (xf.basis * plane.normal).normalized()
			var point := xf * (plane.normal * plane.d)
			entry.shape = XPBDRope.SHAPE_PLANE
			entry.params = Vector3.ZERO
			xf = Transform3D(_basis_from_y(n), point)
		else:
			continue
		entry.xform = xf
		entry.prev_xform = xf
		var body := obj as RigidBody3D
		entry.linear_velocity = body.linear_velocity if body else Vector3.ZERO
		entry.angular_velocity = body.angular_velocity if body else Vector3.ZERO
		out.append(entry)
	return out


static func _basis_from_y(y: Vector3) -> Basis:
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 1e-6:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	return Basis(x, y, x.cross(y))
