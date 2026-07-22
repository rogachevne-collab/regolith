class_name CableTensionUtil
extends RefCounted
## Rope physics. A cable never pushes and does nothing at all while it has
## slack; once the span reaches its rest length it becomes a max-distance
## constraint solved with one impulse per tick, and past the break threshold
## it snaps.
##
## Deliberately an impulse pair, not a Jolt joint: a joint would need a body on
## both ends (a rope to terrain has none), a fixed frame (rope direction turns
## freely) and would fight the actuator joints already on these bodies.

## Point-mass solve — the angular term of the effective mass is ignored, so the
## raw impulse over-corrects. Under-relaxing converges over a few ticks instead
## of ringing.
const RELAXATION := 0.55
## Ticks over which an overstretched rope reels its overshoot back in. This used
## to be a per-tick velocity bias of up to 8 m/s applied ON TOP of arresting the
## end, which is why a light object on a rope was not caught but launched: the
## rope handed back more momentum than the object arrived with.
const RECOVERY_TICKS := 12.0
## Ceiling on the reel-in, whatever the overshoot. Without it a rope that finds
## itself two metres over length tries to fix that inside a fifth of a second,
## which on a light body is a bigger kick than it arrived with. A rope catches
## first and takes up its slack afterwards, at walking pace.
const MAX_RECOVERY_SPEED := 1.0
## Rope strength. Past this the rope snaps. A force, not an impulse: impulse per
## tick scales with the frame time, so an impulse threshold quietly means
## something different at every frame rate.
const DEFAULT_BREAK_FORCE_N := 90000.0
## Below this the endpoint counts as immovable (frozen body / world anchor).
const MIN_MASS_KG := 0.001
## A rope end is tied to a point ON its block. If it resolves further away than
## this, the transform behind it is not trustworthy — a split child whose motion
## has not been seeded yet resolves near the world origin, kilometres out — and
## the rope must sit the tick out rather than act on it. Acting on it applied an
## impulse at a kilometre-long lever arm and threw whole rovers into the sky.
const MAX_LEVER_ARM_M := 120.0
## Ceiling on the speed a rope believes it has to arrest. Point velocity is
## v + ω × r, so a bad frame with a long lever arm reads as hundreds of m/s.
const MAX_ARREST_SPEED := 60.0
## How much of the measured length is written off as solver noise rather than
## believed as stretch, as a fraction of the rope's rest length.
##
## The length comes from a verlet rope that is pushed around by the world every
## tick; it is an estimate, not a measurement, and it sits a little above rest
## for any rope that touches anything. Believed to the millimetre, that residue
## became a permanent reel-in: a few centimetres of phantom stretch on a rope
## tied to a two-tonne machine is still kilonewtons, applied every tick for as
## long as the rope exists, which is what dragged machines across the ground
## and tore them apart. A rope that is genuinely loaded runs out by far more
## than a percent, so nothing real is lost.
##
## Only the reel-in is deadbanded. Arresting a separation stays instant, since
## that term is driven by relative velocity and is therefore zero at rest —
## it can catch a falling load without ever pulling on a resting one.
##
## Two percent because a rope draped over a block and pooled on the ground was
## measured reporting up to 1.16% of phantom stretch once the solved length is
## read instead of the collision-inflated one; the band sits clear of that.
const SLACK_TOLERANCE_FRACTION := 0.02


## Overshoot worth acting on: what is left of the stretch after the solver's own
## noise floor is written off. Also what decides whether a rope is loaded enough
## to be worth waking a parked body for.
static func effective_overshoot_m(
	measured_length_m: float,
	rest_length_m: float
) -> float:
	if rest_length_m <= 0.0:
		return 0.0
	return maxf(
		measured_length_m - rest_length_m
		- rest_length_m * SLACK_TOLERANCE_FRACTION,
		0.0
	)


## What actually resists a pull at one end, when that is not the end's own mass.
## A rope tied to a piston carriage is not tied to a 20 kg block of steel: the
## carriage is held on its axis by a motor joint, and behind that stands the
## machine the piston is bolted to. Solved as a free point mass, the lightest
## part of the rig set the strength of the whole rig — a 5 kN piston could
## transmit about 650 N, which is how a crane rigged to a two-tonne structure
## stretched its rope and lifted nothing. The projection fills this in (see
## SimulationPhysicsProjection._rope_endpoint_backing); an empty dictionary
## means "this end is just its own body", which is the case for every rope not
## tied to an actuator.
##   inverse_mass  — 1/kg of what backs the end; 0 = bolted to something grounded
##   force_cap_n   — most this end can transmit before its actuator gives way
##   reaction_body — where the pull lands; null = grounded, takes nothing
static func _endpoint_inverse_mass(
	body: RigidBody3D,
	backing: Dictionary
) -> float:
	if backing.has("inverse_mass"):
		return maxf(float(backing["inverse_mass"]), 0.0)
	return 1.0 / maxf(body.mass, MIN_MASS_KG)


static func _endpoint_force_cap(backing: Dictionary) -> float:
	return maxf(float(backing.get("force_cap_n", INF)), 0.0)


## Where the pull lands. Once an end is modelled as backed by the machine behind
## it, the reaction belongs to that machine and NOT to the carriage: the impulse
## is sized by the backing's mass, and dumping that on a 20 kg hook at a metre of
## lever arm spun it past the engine's angular ceiling in a single tick and tore
## the piston head off. A grounded backing takes nothing, like a world anchor.
static func _apply_end_impulse(
	body: RigidBody3D,
	backing: Dictionary,
	anchor: Vector3,
	impulse: Vector3
) -> void:
	var target := body
	if backing.has("inverse_mass"):
		target = backing.get("reaction_body") as RigidBody3D
	if target == null or target.freeze:
		return
	target.sleeping = false
	var offset := anchor - target.global_position
	# The rope's anchor sits on the carriage, which can be well away from the
	# machine now taking the load; past the sane lever arm apply it centrally
	# rather than inventing a torque out of the distance between two bodies.
	if offset.length() > MAX_LEVER_ARM_M:
		offset = Vector3.ZERO
	target.apply_impulse(impulse, offset)


## Applies one tick of rope tension between two endpoints. `body_a`/`body_b`
## may be null (world anchor) or frozen (parked/static assembly) — an immovable
## end simply takes no impulse. Returns the tension in newtons, 0 while the rope
## is slack. `backing_a`/`backing_b` describe an end held by an actuator rather
## than hanging free; see _endpoint_inverse_mass.
static func solve(
	anchor_a: Vector3,
	body_a: RigidBody3D,
	anchor_b: Vector3,
	body_b: RigidBody3D,
	rest_length_m: float,
	delta: float,
	link_break_force_n: float = 0.0,
	backing_a: Dictionary = {},
	backing_b: Dictionary = {}
) -> float:
	if delta <= 0.0 or rest_length_m <= 0.0:
		return 0.0
	var span := anchor_b - anchor_a
	var length := span.length()
	if length <= 0.000001 or length <= rest_length_m:
		return 0.0
	var direction := span / length
	return _pull(
		anchor_a,
		body_a,
		direction,
		anchor_b,
		body_b,
		-direction,
		length - rest_length_m,
		effective_overshoot_m(length, rest_length_m),
		delta,
		link_break_force_n,
		backing_a,
		backing_b
	)


## Same constraint, but measured along the rope as it actually lies in the
## world: `routed_length_m` is the sum of the solved segments (longer than the
## straight span whenever the rope is draped over something), and each end
## pulls along its own first segment. A rope hooked over a boulder therefore
## runs out of slack early and yanks toward the boulder, not through it.
static func solve_routed(
	anchor_a: Vector3,
	body_a: RigidBody3D,
	pull_dir_a: Vector3,
	anchor_b: Vector3,
	body_b: RigidBody3D,
	pull_dir_b: Vector3,
	routed_length_m: float,
	rest_length_m: float,
	delta: float,
	link_break_force_n: float = 0.0,
	backing_a: Dictionary = {},
	backing_b: Dictionary = {}
) -> float:
	if delta <= 0.0 or rest_length_m <= 0.0:
		return 0.0
	if (
		pull_dir_a.length_squared() <= 0.000001
		or pull_dir_b.length_squared() <= 0.000001
	):
		return solve(
			anchor_a,
			body_a,
			anchor_b,
			body_b,
			rest_length_m,
			delta,
			link_break_force_n,
			backing_a,
			backing_b
		)
	var overshoot := routed_length_m - rest_length_m
	if overshoot <= 0.0:
		return 0.0
	return _pull(
		anchor_a,
		body_a,
		pull_dir_a,
		anchor_b,
		body_b,
		pull_dir_b,
		overshoot,
		effective_overshoot_m(routed_length_m, rest_length_m),
		delta,
		link_break_force_n,
		backing_a,
		backing_b
	)


## A rope catches; it does not throw. The impulse is capped at exactly what
## arrests the separation, plus a gentle reel-in of the overshoot spread over
## RECOVERY_TICKS. Anything beyond that would hand kinetic energy back to the
## endpoint, which is what smashed small objects tied to masts.
static func _pull(
	anchor_a: Vector3,
	body_a: RigidBody3D,
	pull_dir_a: Vector3,
	anchor_b: Vector3,
	body_b: RigidBody3D,
	pull_dir_b: Vector3,
	overshoot_m: float,
	reel_in_overshoot_m: float,
	delta: float,
	link_break_force_n: float,
	backing_a: Dictionary = {},
	backing_b: Dictionary = {}
) -> float:
	var movable_a := _is_movable(body_a) and _anchor_is_sane(body_a, anchor_a)
	var movable_b := _is_movable(body_b) and _anchor_is_sane(body_b, anchor_b)
	if not movable_a and not movable_b:
		return 0.0
	var inverse_mass_a := (
		_endpoint_inverse_mass(body_a, backing_a) if movable_a else 0.0
	)
	var inverse_mass_b := (
		_endpoint_inverse_mass(body_b, backing_b) if movable_b else 0.0
	)
	var inverse_mass_sum := inverse_mass_a + inverse_mass_b
	if inverse_mass_sum <= 0.000001:
		return 0.0
	# Speed at which the two ends are still feeding rope out, each measured
	# against its own pull direction.
	var separating_speed := 0.0
	if movable_a:
		separating_speed -= _point_velocity(body_a, anchor_a).dot(pull_dir_a)
	if movable_b:
		separating_speed -= _point_velocity(body_b, anchor_b).dot(pull_dir_b)
	var arrest_speed := minf(maxf(separating_speed, 0.0), MAX_ARREST_SPEED)
	# Reel-in works off the deadbanded overshoot, arrest off the raw one: see
	# SLACK_TOLERANCE_FRACTION. A rope lying still therefore pulls with exactly
	# nothing, while one being run out still stops the load the moment it moves.
	var recovery_speed := 0.0
	if reel_in_overshoot_m > 0.0:
		recovery_speed = minf(
			reel_in_overshoot_m / (RECOVERY_TICKS * delta),
			MAX_RECOVERY_SPEED
		)
	var impulse_ns := (
		RELAXATION * (arrest_speed + recovery_speed) / inverse_mass_sum
	)
	if impulse_ns <= 0.000001:
		return 0.0
	var tension_n := impulse_ns / delta
	# A rope can never pull harder than whatever is holding its end. Past the
	# motor's rating the piston gives way instead of the load coming up, so the
	# number the player dialled in as kN is the number that reaches the load —
	# and the rope cannot snap on a force its own winch could not produce.
	var force_cap_n := minf(
		_endpoint_force_cap(backing_a),
		_endpoint_force_cap(backing_b)
	)
	if tension_n > force_cap_n:
		tension_n = force_cap_n
		impulse_ns = force_cap_n * delta
		if impulse_ns <= 0.000001:
			return 0.0
	if tension_n > break_force_n(link_break_force_n):
		# Snap INSTEAD of pulling, never after. Applying the impulse first and
		# checking the threshold afterwards meant the one tick that broke the
		# rope was also the tick it hit hardest — which is how a rover being cut
		# loose ended up in orbit with its cables torn off.
		return tension_n
	if movable_a:
		_apply_end_impulse(body_a, backing_a, anchor_a, pull_dir_a * impulse_ns)
	if movable_b:
		_apply_end_impulse(body_b, backing_b, anchor_b, pull_dir_b * impulse_ns)
	return tension_n


## Is this anchor plausibly on this body? See MAX_LEVER_ARM_M.
static func _anchor_is_sane(body: RigidBody3D, anchor: Vector3) -> bool:
	if body == null:
		return false
	return anchor.distance_to(body.global_position) <= MAX_LEVER_ARM_M


static func break_force_n(link_break_force_n: float) -> float:
	if link_break_force_n > 0.0:
		return link_break_force_n
	return DEFAULT_BREAK_FORCE_N


static func _is_movable(body: RigidBody3D) -> bool:
	return body != null and not body.freeze


## Velocity of the material point the rope is tied to, not of the body origin —
## a rope on the rim of a spinning rotor must feel the rim.
static func _point_velocity(body: RigidBody3D, point: Vector3) -> Vector3:
	if body == null:
		return Vector3.ZERO
	return (
		body.linear_velocity
		+ body.angular_velocity.cross(point - body.global_position)
	)
