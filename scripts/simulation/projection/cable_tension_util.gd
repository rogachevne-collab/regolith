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


## Applies one tick of rope tension between two endpoints. `body_a`/`body_b`
## may be null (world anchor) or frozen (parked/static assembly) — an immovable
## end simply takes no impulse. Returns the tension in newtons, 0 while the rope
## is slack.
static func solve(
	anchor_a: Vector3,
	body_a: RigidBody3D,
	anchor_b: Vector3,
	body_b: RigidBody3D,
	rest_length_m: float,
	delta: float
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
		delta
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
	delta: float
) -> float:
	if delta <= 0.0 or rest_length_m <= 0.0:
		return 0.0
	if (
		pull_dir_a.length_squared() <= 0.000001
		or pull_dir_b.length_squared() <= 0.000001
	):
		return solve(anchor_a, body_a, anchor_b, body_b, rest_length_m, delta)
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
		delta
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
	delta: float
) -> float:
	var movable_a := _is_movable(body_a)
	var movable_b := _is_movable(body_b)
	if not movable_a and not movable_b:
		return 0.0
	var inverse_mass_a := (1.0 / maxf(body_a.mass, MIN_MASS_KG)) if movable_a else 0.0
	var inverse_mass_b := (1.0 / maxf(body_b.mass, MIN_MASS_KG)) if movable_b else 0.0
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
	var arrest_speed := maxf(separating_speed, 0.0)
	var recovery_speed := minf(
		overshoot_m / (RECOVERY_TICKS * delta),
		MAX_RECOVERY_SPEED
	)
	var impulse_ns := (
		RELAXATION * (arrest_speed + recovery_speed) / inverse_mass_sum
	)
	if impulse_ns <= 0.000001:
		return 0.0
	if movable_a:
		body_a.sleeping = false
		body_a.apply_impulse(
			pull_dir_a * impulse_ns,
			anchor_a - body_a.global_position
		)
	if movable_b:
		body_b.sleeping = false
		body_b.apply_impulse(
			pull_dir_b * impulse_ns,
			anchor_b - body_b.global_position
		)
	return impulse_ns / delta


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
