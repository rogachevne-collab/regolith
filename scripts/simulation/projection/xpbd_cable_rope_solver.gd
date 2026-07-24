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
## Internal fibre friction, 1/s. The core defaults to 0.5, which is right for a
## free rope in vacuum — it rings forever because on the moon there is nothing
## to stop it. A cable strapped along a machine is not that rope: it is
## sheathed, clipped and rubbing on everything it passes, and its pins are
## driven by a chassis that never stops jittering, so every tick puts a little
## energy back in. Without this a cable on a rover wobbles for as long as the
## rover exists. Galilean by construction (ADR 0003): it damps stretching,
## bending and vibration, never a rope swinging as a whole, so a cable lifting
## a load still swings.
const DAMPING := 4.0
const COLLISION_MASK := 3
## Terrain only — the crust, not machines. The plane cache exists because it
## survives between ticks, and that is only true of geometry that does not
## move: a plane taken off a rover's flank is stored in world space and is
## wrong the instant the rover shifts a millimetre, so the cable gets shoved
## toward a wall that is no longer there, every tick, forever. Machine surfaces
## belong to the analytic pass, which interpolates their transforms properly.
const TERRAIN_COLLISION_MASK := 1
const QUERY_MARGIN_M := 1.0
## How far ahead of each particle the moon is sampled. The crust is a concave
## mesh rebuilt as it is dug, so it never reaches the analytic collider set —
## it arrives as one contact plane per particle per tick instead (ADR 0006
## slice 2). Also the cable's speed limit against terrain.
const TERRAIN_PROBE_MARGIN_M := 0.5
const PIN_REACTION_RELAXATION := 0.55
## Along-rope velocity matching for a mass-coupled end (see Rope3D.lift_coupling):
## an inextensible rope forces both ends to share their along-rope velocity, and
## enforcing it removes the bounce a heavy hung load otherwise sits in. 1.0 =
## full match; the perpendicular swing is left free.
const LIFT_COUPLING := 1.0
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
	sim.damping = DAMPING
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
		TERRAIN_COLLISION_MASK,
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
	break_force_n: float = 0.0,
	collide_world: bool = true,
	couple_mass_a: float = 0.0,
	couple_mass_b: float = 0.0
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
	var seg := sim.segment_count()
	# A coupled end (couple_mass > 0) is a mass-carrying proxy that the rope can
	# LIFT — the physical rope/chain case. A zero mass is a kinematic pin, which
	# only tugs back via a reaction impulse — the electric cable case, unchanged.
	_drive_end(sim, 0, anchor_a, body_a, couple_mass_a)
	_drive_end(sim, seg, anchor_b, body_b, couple_mass_b)
	if not collide_world:
		# A cable with both ends on one body is strapped to that body, and its
		# only collider worth fighting is that same body — which jitters on its
		# suspension every tick, shoving the cable and pumping in energy it can
		# never shed, so it wobbles forever and never settles enough to freeze.
		# It is an internal hop between two fixed points on one chassis; it has
		# nothing to hang over. Skipping collision lets it settle to its pure
		# catenary (then freeze), and costs nothing — which was the point.
		sim.colliders = []
		sim.local_planes = PackedVector4Array()
	elif space_state != null:
		# Terrain every tick, whatever the budget says. The budget is there to
		# ration the analytic gather, and rationing the GROUND is what makes a
		# slack cable sink: it sags a little on each tick it is skipped, and
		# once it is deeper than the probe reaches, nothing ever finds it
		# again — the cable is simply inside the moon from then on. Shapes can
		# wait their turn; the crust cannot.
		_sample_terrain(sim, space_state)
	if collide_world and collide_shapes and space_state != null:
		var prev_cache: Dictionary = state.get("_collider_prev", {})
		var gathered := RopeColliders.gather_from_space(
			sim.positions, space_state, COLLISION_MASK, QUERY_MARGIN_M, prev_cache
		)
		state["_collider_prev"] = gathered.cache
		sim.colliders = gathered.colliders
	elif not collide_shapes:
		sim.colliders = []
		# The terrain planes are deliberately NOT cleared. Collision is
		# round-robin on a budget, so a cable goes several ticks between turns
		# — and a cable lying on the ground needs the ground on every one of
		# them. Clear them and it sinks through the crust while it waits, then
		# gets slammed back out when its turn comes: a tension spike out of
		# nowhere, which the player sees as a cable that snapped for no reason.
		# The moon does not move. A plane sampled two ticks ago is still where
		# the ground is, and the particles have travelled centimetres.
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
	_settle_end(sim, 0, anchor_a, body_a, backing_a, couple_mass_a, delta)
	_settle_end(sim, seg, anchor_b, body_b, backing_b, couple_mass_b, delta)
	return result


# --- mass-coupled ends -------------------------------------------------------
#
# A pin only lets the rope report a tension and tug the body back with a
# reaction impulse; it can never make the body FOLLOW the rope, so a pinned end
# cannot be lifted. A proxy is the same particle made dynamic and given the
# body's mass, so the rope's constraints have to hold the body up and the
# momentum they spend is handed straight back — that is what makes a rope tow
# and lift. couple_mass == 0 keeps the pin behaviour byte for byte.


static func _drive_end(
	sim: XPBDRope, index: int, anchor: Vector3, body: RigidBody3D, couple_mass: float
) -> void:
	var vel := _pin_velocity(body, anchor)
	if couple_mass > 0.0 and body != null and not body.freeze:
		if not sim.is_proxy(index):
			sim.attach_proxy(index, maxf(couple_mass, 0.001))
		sim.seat_proxy(index, anchor, vel)
	else:
		if sim.is_proxy(index):
			sim.pin(index)
		sim.move_pin(index, anchor, vel)


static func _settle_end(
	sim: XPBDRope, index: int, anchor: Vector3,
	body: RigidBody3D, backing: Dictionary, couple_mass: float, delta: float
) -> void:
	if couple_mass > 0.0 and body != null and not body.freeze:
		_apply_proxy_reaction(sim, index, anchor, body, delta)
	else:
		_apply_pin_reaction(sim, index, anchor, body, backing, delta)


static func _apply_proxy_reaction(
	sim: XPBDRope, index: int, anchor: Vector3, body: RigidBody3D, delta: float
) -> void:
	if body == null or body.freeze or delta <= 0.0:
		return
	body.sleeping = false
	var offset := anchor - body.global_position
	if offset.length() > MAX_LEVER_ARM_M:
		offset = Vector3.ZERO
	var impulse := sim.proxy_momentum(index)
	if impulse.length_squared() > 1e-12:
		body.apply_impulse(impulse, offset)
	# Along-rope velocity matching: kill the along-rope bounce, keep the swing.
	var dir := _end_dir(sim, index)
	if dir != Vector3.ZERO:
		var v_body := _pin_velocity(body, anchor)
		var v_end: Vector3 = sim.velocities[index]
		var dv := dir * (dir.dot(v_end - v_body) * LIFT_COUPLING)
		if dv.length_squared() > 1e-12:
			body.apply_impulse(dv * body.mass, offset)
	# Rendered end back on the hook, whatever the stand-in did while solving.
	sim.reseat_proxy(index, anchor)


## Unit direction of the segment at an end — the axis tension acts along.
static func _end_dir(sim: XPBDRope, index: int) -> Vector3:
	var neighbour := index - 1 if index >= sim.segment_count() else index + 1
	if neighbour < 0 or neighbour >= sim.positions.size():
		return Vector3.ZERO
	var d: Vector3 = sim.positions[neighbour] - sim.positions[index]
	return d.normalized() if d.length_squared() > 1e-12 else Vector3.ZERO


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
