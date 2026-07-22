class_name CableRopeSolver
extends RefCounted
## Verlet rope: particles, distance constraints, world collision.
##
## The analytic catenary it replaces could only ever describe a rope hanging in
## a vacuum — it went through rock, through machines, and slack drove it under
## the terrain. Particles that actually collide give the three things a rope
## has to do: drape over what is in the way, pile on the ground instead of
## sinking into it, and hang differently at every tension.
##
## Presentation/physics state only. The authoritative link keeps just its two
## anchors and its rest length; particle positions are rebuilt from those on
## load, so nothing here reaches a snapshot.

## Particle spacing target; the count is derived from the rope's rest length.
## Short enough that the rope reads as a rope rather than as a polyline — the
## relaxation sweep is Gauss-Seidel and updates in place, so a correction still
## travels the whole length within one pass and density costs propagation
## nothing. What it does cost is collision queries, hence the pass count below.
const SEGMENT_TARGET_M := 0.35
const MIN_PARTICLES := 6
const MAX_PARTICLES := 64
## Relaxation passes per step, alternating direction so both ends propagate.
const ITERATIONS := 16
## Collision runs every Nth relaxation pass (and always at the end). Two passes
## total: with segments this short, queries are the budget, not the arithmetic.
const COLLISION_EVERY := 8
## Bending resistance. Distance constraints alone care about neighbour spacing
## and nothing else, so a folded accordion satisfies them perfectly — and under
## 1.62 m/s² there is almost no gravity to shake it out. This pass pulls a
## particle toward the middle of its neighbours, scaled by how folded the joint
## actually is, so real sag is left alone and creases are ironed out.
const BEND_STIFFNESS := 0.35
## Air drag on the verlet velocity — kills the perpetual swing a lossless rope
## would keep forever in 1.62 m/s² gravity.
const DAMPING := 0.05
## This is armoured copper cable, not a ribbon, and 1.62 m/s² makes anything
## unweighted read as fabric. Mass itself is not the lever: with rigid distance
## constraints and equal particle masses it cancels out of both the hanging
## shape and the dynamics, exactly like a pendulum period. What sells weight is
## how decisively the thing falls, how little it flutters, and how much it
## resists being folded — so: heavier gravity for cables only.
const GRAVITY_SCALE := 3.0
## Internal friction of a thick cable, applied to VELOCITY, never to position:
## each particle is dragged toward the average velocity of its neighbours, so
## short-wavelength ripple dies while the rope as a whole keeps swinging. Doing
## this positionally would fight the length constraint and bring the jitter
## straight back.
const SEGMENT_FRICTION := 0.3
## Ceiling on the sag the initial shape is seeded with. The analytic curve for a
## very slack rope dips metres below the anchors, which would seed the rope
## underneath the floor it is supposed to land on — and nothing pushes a
## particle back out of geometry it never entered. Seed mild, let it fall.
const SEED_SAG_FRACTION := 0.3
## Rope thickness for collision; a bit fatter than the visual tube so it settles
## visibly on top of a surface rather than half inside it.
const COLLISION_RADIUS := 0.06
## Extra clearance added to every push-out. Without it a contact resolves to
## exactly touching, and the next length pass puts it right back inside.
const COLLISION_SKIN := 0.015
## Per-step motion clamp: a rope whose anchor teleports (split, respawn) must
## catch up over a few frames instead of exploding.
const MAX_STEP_M := 1.2
## An anchor jumping further than this in one tick is not motion, it is a
## topology event — the block was cut free, the assembly split, the world was
## restored. The old rope shape says nothing about the new situation, and the
## stale first segment would have the tension solver pull in a direction that
## no longer exists, so the rope is re-seeded from scratch.
const ANCHOR_TELEPORT_M := 2.0
## Terrain + assemblies. Not the player: a rope should not hang on you.
const COLLISION_MASK := 3
## A rope that has stopped moving keeps its shape whether or not it is asked
## again — so a settled one drops to checking every Nth tick instead of every
## tick. This is where the real saving is: most ropes in a world are lying
## still. It stays responsive to the world changing (dug ground, a machine
## driving past) within a fifth of a second.
const QUIESCENT_MOTION_M := 0.002
const QUIESCENT_AFTER_TICKS := 10
const QUIESCENT_STRIDE := 12
## And once it has been still for this long, the rope stops being simulated at
## all until something moves it. A verlet rope has no exact rest state — every
## pass leaves a fraction of a millimetre somewhere — so without a sleep it
## twitches for the rest of the session. Any anchor motion wakes it instantly.
const SLEEP_AFTER_TICKS := 45
## Velocity below this is not motion, it is solver residue. Zeroing it is what
## lets a rope actually arrive at rest instead of asymptotically approaching it.
const VELOCITY_EPSILON_M := 0.0004
## How folded a joint has to be before the bending pass touches it. A smoothly
## hanging rope has a slight fold at every single joint; nudging all of them
## every tick just fights the length constraint forever, which is exactly what
## kept ropes jittering.
const UNFOLD_THRESHOLD := 0.2
## Long-range attachment headroom: a particle may sit up to this multiple of
## its along-rope rest distance from an anchor before the LRA pass clamps it
## back. Distance constraints alone converge slowly near a heavily loaded
## anchor — Gauss-Seidel needs dozens of passes to squeeze the last stretch
## out — and ITERATIONS is nowhere near that under a sudden load spike or a
## heavy object on the free end. 1.0 would clamp every particle onto the exact
## chord distance and iron out real catenary sag along with the stretch; the
## headroom keeps the clamp inactive until the rope is genuinely overstretched.
const LRA_SLACK := 1.1


## Fresh rope, seeded on the analytic hanging curve rather than on the straight
## line between the anchors. Seeding it straight is what produced accordions:
## the length constraint then has to invent somewhere to put the extra rope, and
## with no preferred direction it buckles sideways in a single pass.
static func create_state(
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_length_m: float,
	up: Vector3 = Vector3.UP,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	var span := anchor_a.distance_to(anchor_b)
	var count := particle_count(rest_length_m, span)
	var sag := minf(
		CableCurveUtil.sag_depth_m(span, rest_length_m),
		span * SEED_SAG_FRACTION
	)
	var hang := up
	if hang.length_squared() <= 0.000001:
		hang = Vector3.UP
	else:
		hang = hang.normalized()
	var positions := PackedVector3Array()
	positions.resize(count)
	for index: int in range(count):
		var t := float(index) / float(count - 1)
		var chord_point := anchor_a.lerp(anchor_b, t)
		positions[index] = _seed_point(
			space_state,
			chord_point,
			chord_point - hang * (sag * 4.0 * t * (1.0 - t))
		)
	return {
		"positions": positions,
		"previous": positions.duplicate(),
		"segment_rest": rest_length_m / float(count - 1),
		"rest_length_m": rest_length_m,
	}


## Seeds the rope draped instead of buried: the sagged position is only used if
## the way down to it is clear, otherwise the particle is born on the first
## surface in between. A particle seeded inside geometry cannot be rescued —
## a push-out from deep inside is as likely to shove it through the far side.
static func _seed_point(
	space_state: PhysicsDirectSpaceState3D,
	chord_point: Vector3,
	sagged_point: Vector3
) -> Vector3:
	if space_state == null or chord_point.is_equal_approx(sagged_point):
		return sagged_point
	var query := PhysicsRayQueryParameters3D.create(chord_point, sagged_point)
	query.collision_mask = COLLISION_MASK
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = space_state.intersect_ray(query)
	if hit.is_empty():
		return sagged_point
	var normal: Vector3 = hit.get("normal", Vector3.ZERO)
	if normal.length_squared() <= 0.000001:
		return chord_point
	return hit.get("position", chord_point) + normal * COLLISION_RADIUS


static func particle_count(rest_length_m: float, span_m: float) -> int:
	var length := maxf(rest_length_m, span_m)
	return clampi(
		int(ceil(length / SEGMENT_TARGET_M)) + 1,
		MIN_PARTICLES,
		MAX_PARTICLES
	)


## One physics step. `space_state` may be null (headless): the rope then still
## hangs and swings, it just does not collide with anything.
static func step(
	state: Dictionary,
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_length_m: float,
	gravity: Vector3,
	delta: float,
	space_state: PhysicsDirectSpaceState3D = null
) -> void:
	if delta <= 0.0:
		return
	var up := Vector3.UP
	if gravity.length_squared() > 0.000001:
		up = -gravity.normalized()
	_resize_if_needed(state, anchor_a, anchor_b, rest_length_m, up, space_state)
	var positions: PackedVector3Array = state["positions"]
	var previous: PackedVector3Array = state["previous"]
	var count := positions.size()
	if count < 2:
		return
	# Motion is measured BEFORE anything is integrated, and sleeping returns
	# before anything is integrated too. Sleeping after the integration step was
	# strictly worse than not sleeping at all: gravity still moved the rope and
	# the constraints that would have held it were the part being skipped, so a
	# "settled" rope drifted downward a fraction of a millimetre per tick,
	# forever. Anchors moving counts as motion — the machine driving away is
	# exactly when a rope must not be treated as settled.
	var motion := maxf(
		positions[0].distance_to(anchor_a),
		positions[count - 1].distance_to(anchor_b)
	)
	for index: int in range(1, count - 1):
		motion = maxf(motion, positions[index].distance_to(previous[index]))
	if not is_equal_approx(float(state.get("solved_rest_m", -1.0)), rest_length_m):
		motion = INF
	if motion > ANCHOR_TELEPORT_M:
		var reseeded := create_state(
			anchor_a,
			anchor_b,
			rest_length_m,
			up,
			space_state
		)
		state["positions"] = reseeded["positions"]
		state["previous"] = reseeded["previous"]
		state["segment_rest"] = reseeded["segment_rest"]
		state["rest_length_m"] = rest_length_m
		state["solved_rest_m"] = rest_length_m
		state["quiescent_ticks"] = 0
		return
	state["solved_rest_m"] = rest_length_m
	var quiescent := int(state.get("quiescent_ticks", 0))
	quiescent = quiescent + 1 if motion < QUIESCENT_MOTION_M else 0
	state["quiescent_ticks"] = quiescent
	if quiescent > SLEEP_AFTER_TICKS:
		positions[0] = anchor_a
		positions[count - 1] = anchor_b
		previous[0] = anchor_a
		previous[count - 1] = anchor_b
		state["positions"] = positions
		state["previous"] = previous
		return
	var collide_now := space_state != null and (
		quiescent < QUIESCENT_AFTER_TICKS
		or quiescent % QUIESCENT_STRIDE == 0
	)
	var gravity_step := gravity * GRAVITY_SCALE * delta * delta
	for index: int in range(1, count - 1):
		var velocity := (positions[index] - previous[index]) * (1.0 - DAMPING)
		var speed := velocity.length()
		if speed > MAX_STEP_M:
			velocity = velocity.normalized() * MAX_STEP_M
		elif speed < VELOCITY_EPSILON_M:
			velocity = Vector3.ZERO
		previous[index] = positions[index]
		positions[index] += velocity + gravity_step
	positions[0] = anchor_a
	positions[count - 1] = anchor_b
	previous[0] = anchor_a
	previous[count - 1] = anchor_b
	var segment_rest := float(state["segment_rest"])
	_unfold(positions, count, segment_rest)
	# Collision is interleaved with relaxation, not tacked on after it. Run last
	# and the length constraint simply drags the particle back inside on the
	# next step; run it in the middle too and the two agree on where the rope
	# ends up.
	for iteration: int in range(ITERATIONS):
		_relax(positions, count, segment_rest, iteration % 2 == 0)
		_clamp_lra(positions, count, segment_rest)
		if (
			collide_now
			and iteration % COLLISION_EVERY == COLLISION_EVERY - 1
			and iteration < ITERATIONS - 1
		):
			_resolve_collisions(positions, previous, count, space_state)
	if collide_now:
		_resolve_collisions(positions, previous, count, space_state)
	_smooth_velocities(positions, previous, count)
	state["positions"] = positions
	state["previous"] = previous


static func path(state: Dictionary) -> PackedVector3Array:
	var positions: Variant = state.get("positions", PackedVector3Array())
	if positions is PackedVector3Array:
		return positions
	return PackedVector3Array()


## Direction the rope pulls at the anchor: the first segment, not the straight
## line to the far end. A rope draped over a rock pulls toward the rock.
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


## Length the rope actually takes through the world. Wrapped around an obstacle
## it is longer than the straight span, which is exactly what makes a wrapped
## rope run out of slack sooner.
static func routed_length_m(state: Dictionary) -> float:
	var positions := path(state)
	var length := 0.0
	for index: int in range(positions.size() - 1):
		length += positions[index].distance_to(positions[index + 1])
	return length


## Only a change in particle COUNT is worth rebuilding for. Rebuilding whenever
## the rest length moved threw the rope away every frame while the wheel or the
## cursor changed the span, and a rope reborn each frame can never settle — that
## is what the zigzag was. A new rest length just re-targets the segments and
## the running solve absorbs it.
static func _resize_if_needed(
	state: Dictionary,
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_length_m: float,
	up: Vector3,
	space_state: PhysicsDirectSpaceState3D
) -> void:
	var positions: PackedVector3Array = state.get(
		"positions",
		PackedVector3Array()
	)
	var wanted := particle_count(
		rest_length_m,
		anchor_a.distance_to(anchor_b)
	)
	if positions.size() != wanted:
		if positions.size() >= 2:
			# Resample the rope that already exists instead of seeding a new
			# one. The particle count changes constantly while the free end is
			# being dragged around, and a rope reseeded on every threshold
			# crossing visibly snaps back.
			var resampled := _resample(positions, wanted)
			state["positions"] = resampled
			state["previous"] = resampled.duplicate()
		else:
			var rebuilt := create_state(
				anchor_a,
				anchor_b,
				rest_length_m,
				up,
				space_state
			)
			state["positions"] = rebuilt["positions"]
			state["previous"] = rebuilt["previous"]
	state["segment_rest"] = rest_length_m / float(maxi(wanted - 1, 1))
	state["rest_length_m"] = rest_length_m


## Same curve, different number of particles: walk the existing polyline by arc
## length and drop `wanted` points along it, so the shape survives a resize.
static func _resample(
	positions: PackedVector3Array,
	wanted: int
) -> PackedVector3Array:
	var total := 0.0
	for index: int in range(positions.size() - 1):
		total += positions[index].distance_to(positions[index + 1])
	var result := PackedVector3Array()
	result.resize(wanted)
	result[0] = positions[0]
	result[wanted - 1] = positions[positions.size() - 1]
	if total <= 0.000001 or wanted < 3:
		for index: int in range(1, wanted - 1):
			result[index] = positions[0].lerp(
				positions[positions.size() - 1],
				float(index) / float(wanted - 1)
			)
		return result
	var walked := 0.0
	var source := 0
	for index: int in range(1, wanted - 1):
		var target := total * float(index) / float(wanted - 1)
		while (
			source < positions.size() - 2
			and walked + positions[source].distance_to(positions[source + 1])
			< target
		):
			walked += positions[source].distance_to(positions[source + 1])
			source += 1
		var segment := positions[source].distance_to(positions[source + 1])
		var t := 0.0 if segment <= 0.000001 else (target - walked) / segment
		result[index] = positions[source].lerp(
			positions[source + 1],
			clampf(t, 0.0, 1.0)
		)
	return result


## Internal friction: pull each particle's velocity toward its neighbours' average.
## Position is untouched, so this cannot argue with the length constraint — it
## only removes the short-wavelength difference between neighbouring particles,
## which is exactly what reads as flapping fabric.
static func _smooth_velocities(
	positions: PackedVector3Array,
	previous: PackedVector3Array,
	count: int
) -> void:
	if count < 3:
		return
	var velocities := PackedVector3Array()
	velocities.resize(count)
	for index: int in range(count):
		velocities[index] = positions[index] - previous[index]
	for index: int in range(1, count - 1):
		var neighbour_average := (
			velocities[index - 1] + velocities[index + 1]
		) * 0.5
		previous[index] = positions[index] - velocities[index].lerp(
			neighbour_average,
			SEGMENT_FRICTION
		)


## Iron out creases. `chord` is the distance a particle's two neighbours keep
## from each other: at 2·segment_rest the joint is straight, at 0 it is folded
## back on itself. Smoothing scales with that fold, so a hanging curve keeps its
## curvature and only accordion joints get pulled straight.
static func _unfold(
	positions: PackedVector3Array,
	count: int,
	segment_rest: float
) -> void:
	if count < 3 or segment_rest <= 0.000001:
		return
	for index: int in range(1, count - 1):
		var chord := positions[index + 1].distance_to(positions[index - 1])
		var folded := 1.0 - clampf(chord / (2.0 * segment_rest), 0.0, 1.0)
		if folded <= UNFOLD_THRESHOLD:
			continue
		var middle := (positions[index - 1] + positions[index + 1]) * 0.5
		positions[index] = positions[index].lerp(
			middle,
			BEND_STIFFNESS * folded
		)


## Long-range attachment: clamps every interior particle to a sphere around
## each anchor sized by its along-rope rest distance, so a chain segment can
## never end up carrying more stretch than the rope between it and an anchor
## actually has. Unilateral — only a particle already outside its sphere is
## touched — so a slack, sagging rope sits inside both spheres and this pass
## is a no-op for it; it only ever bites once the rope is genuinely taut.
static func _clamp_lra(
	positions: PackedVector3Array,
	count: int,
	segment_rest: float
) -> void:
	if count < 3 or segment_rest <= 0.000001:
		return
	var anchor_a := positions[0]
	var anchor_b := positions[count - 1]
	for index: int in range(1, count - 1):
		_clamp_to_anchor(
			positions, index, anchor_a, float(index) * segment_rest * LRA_SLACK
		)
		_clamp_to_anchor(
			positions,
			index,
			anchor_b,
			float(count - 1 - index) * segment_rest * LRA_SLACK
		)


static func _clamp_to_anchor(
	positions: PackedVector3Array,
	index: int,
	anchor: Vector3,
	max_distance: float
) -> void:
	if max_distance <= 0.000001:
		return
	var offset := positions[index] - anchor
	var distance_sq := offset.length_squared()
	if distance_sq <= max_distance * max_distance:
		return
	positions[index] = anchor + offset * (max_distance / sqrt(distance_sq))


## Rigid segments, ends pinned: a segment with one pinned end hands its whole
## correction to the free particle, otherwise the rope would slide off its
## anchors under load. Passes alternate direction — a one-way sweep drags the
## whole rope toward whichever end it starts from.
static func _relax(
	positions: PackedVector3Array,
	count: int,
	segment_rest: float,
	forward: bool
) -> void:
	for step: int in range(count - 1):
		var index := step if forward else count - 2 - step
		var span := positions[index + 1] - positions[index]
		var length := span.length()
		if length <= 0.000001:
			continue
		var correction := span * ((length - segment_rest) / length)
		var first_pinned := index == 0
		var second_pinned := index + 1 == count - 1
		if first_pinned and second_pinned:
			continue
		if first_pinned:
			positions[index + 1] -= correction
		elif second_pinned:
			positions[index] += correction
		else:
			positions[index] += correction * 0.5
			positions[index + 1] -= correction * 0.5


## Push the rope out of whatever it is inside — segment by segment, not point
## by point. A chain of spheres 0.7 m apart has 0.7 m of nothing between each
## pair, and every edge, beam and block corner slips through that gap; the
## capsule covering the whole segment is what a rope actually is.
static func _resolve_collisions(
	positions: PackedVector3Array,
	previous: PackedVector3Array,
	count: int,
	space_state: PhysicsDirectSpaceState3D
) -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = COLLISION_RADIUS
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = capsule
	params.collision_mask = COLLISION_MASK
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var sphere := SphereShape3D.new()
	sphere.radius = COLLISION_RADIUS
	var point_params := PhysicsShapeQueryParameters3D.new()
	point_params.shape = sphere
	point_params.collision_mask = COLLISION_MASK
	point_params.collide_with_bodies = true
	point_params.collide_with_areas = false
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = COLLISION_MASK
	ray.collide_with_areas = false
	ray.collide_with_bodies = true
	# Sweep first: a particle falling faster than the geometry is thick would
	# otherwise pass clean through it between two overlap tests.
	for index: int in range(1, count - 1):
		var travel := positions[index] - previous[index]
		if travel.length_squared() <= 0.000001:
			continue
		ray.from = previous[index]
		ray.to = positions[index] + travel.normalized() * COLLISION_RADIUS
		var swept: Dictionary = space_state.intersect_ray(ray)
		if swept.is_empty():
			continue
		var swept_normal: Vector3 = swept.get("normal", Vector3.ZERO)
		if swept_normal.length_squared() <= 0.000001:
			continue
		positions[index] = (
			swept.get("position", positions[index])
			+ swept_normal * COLLISION_RADIUS
		)
		previous[index] = positions[index]
	for index: int in range(count - 1):
		var start := positions[index]
		var end := positions[index + 1]
		var span := end - start
		var length := span.length()
		if length <= 0.000001:
			continue
		capsule.height = length + COLLISION_RADIUS * 2.0
		params.transform = Transform3D(
			_capsule_basis(span / length),
			(start + end) * 0.5
		)
		var contacts: Array[Vector3] = space_state.collide_shape(params, 6)
		var push := _deepest_push(contacts)
		if push.length_squared() <= 0.0000001:
			continue
		# Both free ends take the whole correction, not half each: the length
		# constraint pulls the segment straight back in between passes, and a
		# half-resolved contact never wins that argument. A skin on top so the
		# rope settles clear of the surface instead of grazing it forever.
		push += push.normalized() * COLLISION_SKIN
		if index > 0:
			_displace(positions, previous, index, push)
		if index + 1 < count - 1:
			_displace(positions, previous, index + 1, push)
	# Finally the particles themselves, so a resting rope settles ON a surface
	# instead of grazing it.
	for index: int in range(1, count - 1):
		point_params.transform = Transform3D(Basis.IDENTITY, positions[index])
		var rest: Dictionary = space_state.get_rest_info(point_params)
		if rest.is_empty():
			continue
		var normal: Vector3 = rest.get("normal", Vector3.ZERO)
		if normal.length_squared() <= 0.000001:
			continue
		var point: Vector3 = rest.get("point", positions[index])
		var target := point + normal * COLLISION_RADIUS
		# Kill the velocity into the surface, keep what slides along it, so a
		# slack rope settles and lies still instead of buzzing on the ground.
		var velocity := target - previous[index]
		positions[index] = target
		previous[index] = target - velocity.slide(normal)


## Largest depenetration among the reported contacts. `collide_shape` hands back
## pairs (point on our shape, point on theirs); the difference is how far this
## contact wants the rope moved.
static func _deepest_push(contacts: Array[Vector3]) -> Vector3:
	var push := Vector3.ZERO
	var deepest := 0.0
	var index := 0
	while index + 1 < contacts.size():
		var candidate := contacts[index + 1] - contacts[index]
		var depth := candidate.length()
		if depth > deepest:
			deepest = depth
			push = candidate
		index += 2
	return push


static func _displace(
	positions: PackedVector3Array,
	previous: PackedVector3Array,
	index: int,
	push: Vector3
) -> void:
	positions[index] += push
	previous[index] += push


## Capsules are modelled along local Y; point that at the segment.
static func _capsule_basis(direction: Vector3) -> Basis:
	var up := direction
	var reference := Vector3.RIGHT
	if absf(up.dot(reference)) > 0.95:
		reference = Vector3.FORWARD
	var side := reference.cross(up).normalized()
	# Right-handed: z = x × y. A mirrored basis has determinant −1 and the
	# physics server does not take kindly to being handed one.
	return Basis(side, up, side.cross(up).normalized())
