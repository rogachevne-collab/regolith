class_name XpbdCableRopeSolver
extends RefCounted
## Production cable facade over addons/ropes/core/xpbd_rope.gd — same static
## interface as [CableRopeSolver], plus gate-4 pin reactions on endpoint
## [RigidBody3D]s. Regolith uses this when [member SimulationPhysicsProjection.use_xpbd_cable_rope] is on; forces live here, not in [CableTensionUtil].
##
## Preview ([CableRoutingPreview]) may also call this with bodies omitted
## (reactions skipped, mesh-only).

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const RopeColliders := preload("res://addons/ropes/core/rope_colliders.gd")

const SEGMENT_TARGET_M := 0.35
const MIN_PARTICLES := 6
const MAX_PARTICLES := 64
const MASS_PER_M := 0.15
const RADIUS := 0.024
const SUBSTEPS := 32
const ITERATIONS := 2
const COLLISION_MASK := 3
const QUERY_MARGIN_M := 1.0
## How far ahead of each particle the moon is sampled. The crust is a concave
## mesh rebuilt as it is dug, so it never reaches the analytic collider set —
## it arrives as one contact plane per particle per tick instead (ADR 0006
## slice 2). Also the cable's speed limit against terrain.
const TERRAIN_PROBE_MARGIN_M := 0.3
const PIN_REACTION_RELAXATION := 0.55
const MAX_LEVER_ARM_M := 120.0
const LIFT_SKIN_M := 0.004
const SEED_LIFT_ATTEMPTS := 3


static func particle_count(rest_length_m: float, span_m: float) -> int:
	var length := maxf(rest_length_m, span_m)
	return clampi(
		int(ceil(length / SEGMENT_TARGET_M)) + 1, MIN_PARTICLES, MAX_PARTICLES
	)


static func create_state(
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_length_m: float,
	up: Vector3 = Vector3.UP,
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
		_lift_out_of_geometry(sim, space_state, up)
		var gathered := RopeColliders.gather_from_space(
			sim.positions, space_state, COLLISION_MASK, QUERY_MARGIN_M, {}
		)
		sim.colliders = gathered.colliders
		_sample_terrain(sim, space_state)
	return {"sim": sim, "_collider_prev": {}}


## The moon, once per tick, per particle. Analytic colliders are excluded so a
## boulder already solved as a box is not also solved as a plane.
static func _sample_terrain(sim: XPBDRope, space_state: PhysicsDirectSpaceState3D) -> void:
	sim.local_planes = RopeColliders.sample_local_planes(
		sim.positions,
		space_state,
		COLLISION_MASK,
		RADIUS,
		TERRAIN_PROBE_MARGIN_M,
		RopeColliders.body_rids(sim.colliders)
	)


static func step(
	state: Dictionary,
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_length_m: float,
	gravity: Vector3,
	delta: float,
	space_state: PhysicsDirectSpaceState3D = null,
	collide_shapes: bool = true,
	body_a: RigidBody3D = null,
	body_b: RigidBody3D = null,
	backing_a: Dictionary = {},
	backing_b: Dictionary = {},
	break_force_n: float = 0.0
) -> Dictionary:
	var result := {
		"tension_n": 0.0,
		"snapped": false,
		"overshoot_m": 0.0,
	}
	var sim: XPBDRope = state.get("sim")
	if sim == null or delta <= 0.0:
		return result
	var wanted := particle_count(rest_length_m, anchor_a.distance_to(anchor_b))
	if wanted != sim.segment_count() + 1:
		var fresh: Dictionary = create_state(
			anchor_a, anchor_b, rest_length_m, -gravity, space_state
		)
		sim = fresh.sim
		state["sim"] = sim
		state["_collider_prev"] = fresh.get("_collider_prev", {})
	elif not is_equal_approx(sim.rest_length(), rest_length_m):
		# Winch: rest length and lumped mass follow the reel without re-seeding
		# (the re-seed above only happens when the particle count itself moves).
		sim.set_rest_length(rest_length_m)
	sim.gravity = gravity
	var pin_vel_a := _pin_velocity(body_a, anchor_a)
	var pin_vel_b := _pin_velocity(body_b, anchor_b)
	sim.move_pin(0, anchor_a, pin_vel_a)
	sim.move_pin(sim.segment_count(), anchor_b, pin_vel_b)
	if collide_shapes and space_state != null:
		var prev_cache: Dictionary = state.get("_collider_prev", {})
		var gathered := RopeColliders.gather_from_space(
			sim.positions, space_state, COLLISION_MASK, QUERY_MARGIN_M, prev_cache
		)
		state["_collider_prev"] = gathered.cache
		sim.colliders = gathered.colliders
		_sample_terrain(sim, space_state)
	elif not collide_shapes:
		sim.colliders = []
		sim.local_planes = PackedVector4Array()
	sim.step(delta)
	result.overshoot_m = CableTensionUtil.effective_overshoot_m(
		routed_length_m(state), rest_length_m
	)
	result.tension_n = sim.endpoint_tension_n()
	if result.overshoot_m <= 0.0:
		result.tension_n = 0.0
		return result
	if break_force_n > 0.0 and result.tension_n > CableTensionUtil.break_force_n(break_force_n):
		result.snapped = true
		return result
	# TEMP (gate-4 ship): same RigidBody both ends — e.g. battery↔distributor on
	# one rover chassis. Pin reactions at two anchors become a torque couple and
	# flip the machine. Mesh + electric link stay; forces wait for a real
	# intra-assembly policy (or CableTensionUtil-style soft catch).
	if body_a != null and body_a == body_b:
		return result
	_apply_pin_reaction(sim, 0, anchor_a, body_a, backing_a, delta)
	_apply_pin_reaction(sim, sim.segment_count(), anchor_b, body_b, backing_b, delta)
	return result


static func path(state: Dictionary) -> PackedVector3Array:
	var sim: XPBDRope = state.get("sim")
	return sim.positions.duplicate() if sim != null else PackedVector3Array()


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


static func routed_length_m(state: Dictionary) -> float:
	var sim: XPBDRope = state.get("sim")
	return sim.total_polyline_length() if sim != null else 0.0


static func _pin_velocity(body: RigidBody3D, anchor: Vector3) -> Vector3:
	if body == null or body.freeze:
		return Vector3.ZERO
	return body.linear_velocity + body.angular_velocity.cross(anchor - body.global_position)


static func _apply_pin_reaction(
	sim: XPBDRope,
	pin_index: int,
	anchor: Vector3,
	body: RigidBody3D,
	backing: Dictionary,
	delta: float
) -> void:
	if body == null or body.freeze or delta <= 0.0:
		return
	var impulse := sim.pin_reaction_impulse(pin_index) * PIN_REACTION_RELAXATION
	if impulse.length_squared() <= 1e-12:
		return
	var tension_n := impulse.length() / delta
	var force_cap_n := maxf(float(backing.get("force_cap_n", INF)), 0.0)
	if tension_n > force_cap_n:
		impulse = impulse.normalized() * force_cap_n * delta
		if impulse.length_squared() <= 1e-12:
			return
	var target := body
	if backing.has("inverse_mass"):
		target = backing.get("reaction_body") as RigidBody3D
	if target == null or target.freeze:
		return
	target.sleeping = false
	var offset := anchor - target.global_position
	if offset.length() > MAX_LEVER_ARM_M:
		offset = Vector3.ZERO
	target.apply_impulse(impulse, offset)


static func _lift_out_of_geometry(
	sim: XPBDRope,
	space_state: PhysicsDirectSpaceState3D,
	_up: Vector3
) -> void:
	if space_state == null:
		return
	var query_shape := SphereShape3D.new()
	query_shape.radius = RADIUS + LIFT_SKIN_M
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = query_shape
	params.collision_mask = COLLISION_MASK
	params.collide_with_bodies = true
	params.collide_with_areas = false
	for i in sim.positions.size():
		if sim.is_pinned(i):
			continue
		var lifted := sim.positions[i]
		for _attempt in SEED_LIFT_ATTEMPTS:
			params.transform = Transform3D(Basis.IDENTITY, lifted)
			var rest: Dictionary = space_state.get_rest_info(params)
			if rest.is_empty():
				break
			var normal: Vector3 = rest.get("normal", Vector3.ZERO)
			if normal.length_squared() <= 1e-6:
				break
			lifted = (
				rest.get("point", lifted)
				+ normal * (RADIUS + LIFT_SKIN_M)
			)
		sim.positions[i] = lifted
