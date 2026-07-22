class_name GranularBody
extends Node3D
## Coupling between a rigid body and loose material: what it feels standing in
## a heap, and what the heap feels back. Hang one under any `RigidBody3D` —
## rover, crate, dozer blade, debris. It knows nothing about archetypes.
##
## One quantity drives all of it: how much of the body is below the surface of
## the material. Support, resistance and ploughing are three readings of that
## same number, which is why they belong in one component rather than three.
##
## Loose material is a medium, not a surface. That is the standing decision in
## this project — the granular terrain carries `generate_collisions = false` on
## purpose, because a collider can only ever say "holds you up" and never "gives
## way under you". So nothing here is a contact: a body sinks until the material
## it displaces supports it, and drags while it moves through what is left.
##
## What this does NOT replace is `GranularPressSource` on a wheel. A rut is a
## contact-patch effect, not a submersion one: the wheels here are raycast, the
## rover is a single body, and the tyre's contact patch sits a wheel radius
## below any part of the chassis. Nothing sampled from the body's own volume
## reaches it. Ruts and ploughing are different phenomena and stay separate.

## Samples per axis over the body's box. Twenty-seven points at three, which is
## enough to tell "a corner is in the heap" from "the whole thing is buried" and
## cheap enough to do many times a second. Costs almost nothing where there is
## no material: `dust_at` is a few bounds checks when no region covers a point.
@export var samples_per_axis := 3
## How often the material is sampled. Forces are applied every physics frame
## from the last sample — sampling at the physics rate is wasted work, but
## applying forces at the sample rate would make the body buzz.
@export var sample_hz := 30.0
## How often material is actually shoved aside.
##
## Thirty, up from ten, and affordable only because moulding stopped ringing
## every sample separately: the whole body now costs one deposit ring per tick
## instead of one per submerged point, so three times the rate is still a
## fraction of the old bill. Ten was visibly stepped — material moved in jerks
## as a machine drove through it — and the answer to that was never to go lower
## still, it was to make a tick cheap enough to afford more of them.
##
## Matched by `sample_hz` on purpose. Pressing more often than the body is
## measured just presses the same stale points twice.
@export var press_hz := 30.0
## Bulk density of the loose material, kilograms per cubic metre. Support is the
## weight of what the body displaces, which is the only reading that makes
## density mean anything: a rover is far denser than regolith and must sink into
## a heap, an empty crate is not and must ride high in it.
##
## The first version scaled support by the body's own mass instead, and that is
## worth recording because of how it failed. At full submersion it cancelled the
## body's weight exactly — every object, whatever its density, went neutrally
## buoyant. A rover driving into a big heap became weightless and glided through
## it with no load on its wheels and nothing to stop it, while a small heap
## submerged it only partly and behaved fine. "The big pile ignored me" was that
## bug, and no amount of drag would have covered it.
@export var material_density_kg_m3 := 1500.0
## Scales the support, for tuning against the rest of the feel. One is the
## honest displaced weight.
@export var support := 1.0
## Resistance proportional to speed, in newtons per metre per second at full
## submersion. The viscous half.
@export var drag := 1200.0
## Resistance that does not care how fast the body is going, in newtons at full
## submersion. This is the half that actually stops a vehicle.
##
## Granular material has a yield point: below a threshold shear it does not flow
## at all, which is why deep sand is impassable rather than merely slow. A drag
## proportional to velocity can never bring anything to rest — it only decays
## the speed — so on its own it produced a rover that sailed through a heap
## slightly slower. This is the term that makes a big pile a wall and a thin
## drift something to be driven over.
@export var yield_force := 9000.0
## How hard the body shoves material out of its way. Zero leaves the heap
## untouched and the body merely wading through it.
@export var plough := 1.0
## Share of the material at each submerged sample that one press moves. Large,
## unlike a wheel's: a body is not nudging the ground, it is standing where the
## material wants to be, and the cavity should form in a moment rather than over
## a second of leaning on it.
@export var mould_share := 0.5
## Fill a pressed cell may keep under a body.
##
## Was near zero, on the argument that a chassis occupies its space so nothing
## may remain inside it. That is true of one plunge and false of a machine that
## drives: at half a cell per press, thirty times a second, a rover empties
## everything under itself within a second and then rolls around inside the
## tunnel it dug. With nothing left to be submerged in there is no support, no
## resistance and no moulding — the heap appears to stop noticing the vehicle
## entirely, which is exactly what it looked like.
##
## The floor is the same crude stand-in for compaction the wheels use, and a
## body needs one for the same reason: it is traffic too. Lower than a wheel's,
## because a hull really does shoulder material aside rather than merely pack
## it, but never near zero. Displacement has to reach an equilibrium depth and
## stop, or every pass is an excavation.
@export var mould_keep_fill := 0.3
## Where the displaced material is put, between a ring around the body and a
## heap driven ahead of it. Zero parts the material sideways, which is a chassis
## wading in; one drives it all forward, which is a dozer blade building a
## windrow. Anything with a working face wants this near the top.
@export var plough_bias := 0.35
@export var enabled := true

var _body: RigidBody3D
var _granular_world: Node
var _samples: PackedVector3Array = PackedVector3Array()
var _extent := 0.5
## Volume of the body's own box, which is what it displaces when fully buried.
var _volume := 1.0
## Radius one sample presses over — half the spacing between them, so the
## presses tile the body's box instead of overlapping into one blob or leaving
## gaps between themselves.
var _sample_radius := 0.3
## Sample points currently below the surface, in world space.
var _wet_points: PackedVector3Array = PackedVector3Array()
var _sample_debt := 0.0
var _press_debt := 0.0
## Last reading, held between samples and applied every frame.
var _submerged := 0.0
var _centroid := Vector3.ZERO
var _up := Vector3.UP


func _ready() -> void:
	_body = _find_body()
	if _body == null:
		push_warning("GranularBody: no RigidBody3D above %s" % get_path())
		set_physics_process(false)


func _physics_process(delta: float) -> void:
	if not enabled or _body == null:
		return
	_sample_debt += delta * sample_hz
	if _sample_debt >= 1.0:
		_sample_debt = fmod(_sample_debt, 1.0)
		# Built here rather than in `_ready`, and retried until it takes: an
		# assembly has no collision shapes yet when its node enters the tree —
		# they arrive with `build_from`, and a rebuild can replace them. Reading
		# the box once at startup would measure an empty body forever.
		if _samples.is_empty():
			_build_samples()
		_resample()
	if _samples.is_empty():
		return
	if _submerged <= 0.0:
		return
	# Applied every frame from the held reading, so the body is pushed smoothly
	# rather than kicked once per sample.
	var offset := _centroid - _body.global_position
	var gravity := GravityField.resolve_gravity_accel(self, _centroid).length()
	# The weight of the material this body is standing in the place of. Dense
	# things sink through it, light things ride on it, and neither is a case
	# anybody had to write.
	var displaced := _volume * _submerged
	# Capped at the body's own weight, and that cap is the physics rather than a
	# safety rail.
	#
	# Buoyancy is a fluid law. Loose material does not push a body out of it —
	# it stops giving way. Dry sand holds a stone up and leaves it there; it
	# does not float it to the surface, however light the stone is. So the
	# material may cancel weight and never exceed it.
	#
	# Without the cap this launched things, and a rover is exactly the case that
	# exposes it: a vehicle is mostly frame and air, a few hundred kilos per
	# cubic metre against regolith's fifteen hundred. Read as a fluid it is
	# violently buoyant and fires itself off the heap — which is what "bounced
	# like it hit a rock" was. Read as a granular medium it simply rests on top,
	# which is what a light thing on sand does.
	var lift: float = minf(
		displaced * material_density_kg_m3 * gravity * support,
		_body.mass * gravity
	)
	_body.apply_force(_up * lift, offset)
	var velocity := _body.linear_velocity
	var speed := velocity.length()
	if speed > 0.001:
		# Viscous and yield terms together. Capped at what would bring the body
		# to rest inside one step: past that it would not stop the body but
		# reverse it, and a rover spat backwards out of a heap is a worse bug
		# than one that drives through it.
		var resist := _submerged * (drag * speed + yield_force)
		var stopping := speed * _body.mass / maxf(delta, 0.0001)
		_body.apply_force(-(velocity / speed) * minf(resist, stopping), offset)
	if plough <= 0.0:
		return
	_press_debt += delta * press_hz
	if _press_debt < 1.0:
		return
	_press_debt = fmod(_press_debt, 1.0)
	_shove()


## Where the body currently stands in the material, as one reading.
func _resample() -> void:
	_submerged = 0.0
	_wet_points.clear()
	var world := _world()
	if world == null:
		return
	var frame := _body.global_transform
	_up = GravityField.resolve_up(self, _body.global_position)
	var wet := 0
	var sum := Vector3.ZERO
	for local: Vector3 in _samples:
		var point := frame * local
		var column := Dictionary(world.call(&"dust_at", point))
		if column.is_empty():
			continue
		var surface: Vector3 = column["surface"]
		# Below the surface of the material, not merely near it. Without this a
		# body flying over a heap would read as buried in it.
		if (surface - point).dot(_up) <= 0.0:
			continue
		wet += 1
		sum += point
		# Kept, not just counted: these are where the body is actually in the
		# material, and so where it has to be moulded out of it.
		_wet_points.append(point)
	if wet == 0:
		return
	_submerged = float(wet) / float(_samples.size())
	_centroid = sum / float(wet)


## Push material out of the body's way, ahead of it or around it.
## Push material out of the body's way — at every submerged sample, not at one
## point in the middle of it.
##
## Pressing once at the centroid was a single sphere the size of the whole body,
## and the heap could only ever take that one shape: material shifted, but never
## looked like anything had been driven into it. The samples already describe
## the body's box, so pressing at each of them moulds a cavity of roughly the
## right shape — a wide machine leaves a wide trough, a long one a long one, and
## nothing has to be told which is which.
##
## The floor is near zero here rather than the world's bedding value: a chassis
## occupies its space, so material inside it is not compacted, it is *gone*. The
## wheels keep the bedding floor, because a wheel really does compact.
func _shove() -> void:
	var world := _world()
	if world == null or _wet_points.is_empty():
		return
	var travel := _body.linear_velocity
	var lead := Vector3.ZERO
	if plough_bias > 0.0 and travel.length_squared() > 0.01:
		# Displaced ahead of the body rather than under it, so a working face
		# builds a heap in front instead of quietly eating what it drives into.
		lead = travel.normalized() * (_sample_radius * 2.0 * plough_bias)
	world.call(
		&"mould_at",
		_wet_points,
		_sample_radius,
		clampf(mould_share * plough, 0.0, 1.0),
		mould_keep_fill,
		_extent,
		lead
	)


## Sample points on a grid through the body's own box.
##
## The box, not the shapes: what is wanted is "how much of this is in the
## material", and a body that is roughly a box — which a rover is — loses
## nothing to the approximation. It also means anything with a collider works
## without knowing what shape it has.
func _build_samples() -> void:
	var box := _local_bounds()
	if box.size.length_squared() <= 0.0:
		return
	_extent = maxf(box.size.length() * 0.25, 0.1)
	# Displaced volume comes from here, so support tracks the size of the thing
	# rather than a guess: a crate and a rover differ by their box and nothing
	# else has to know.
	_volume = maxf(box.size.x * box.size.y * box.size.z, 0.001)
	var n := maxi(samples_per_axis, 1)
	var step := box.size / float(n)
	# Half the spacing, so neighbouring presses meet rather than overlap or
	# leave ridges of untouched material between them.
	_sample_radius = maxf(step.length() * 0.5, 0.15)
	for ix in n:
		for iy in n:
			for iz in n:
				_samples.append(
					box.position
					+ Vector3(
						step.x * (float(ix) + 0.5),
						step.y * (float(iy) + 0.5),
						step.z * (float(iz) + 0.5)
					)
				)


## Union of the body's collision shapes, in the body's own frame. Built once —
## `get_debug_mesh` is far too slow to do per frame, and a body's shapes do not
## move under it.
func _local_bounds() -> AABB:
	var box := AABB()
	var started := false
	for child in _body.find_children("*", "CollisionShape3D", true, false):
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null or shape_node.disabled:
			continue
		var mesh := shape_node.shape.get_debug_mesh()
		if mesh == null:
			continue
		var local := _body.global_transform.affine_inverse() * (
			shape_node.global_transform
		)
		var shape_box := local * mesh.get_aabb()
		if started:
			box = box.merge(shape_box)
		else:
			box = shape_box
			started = true
	return box


func _find_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		var body := node as RigidBody3D
		if body != null:
			return body
		node = node.get_parent()
	return null


## Found by group, so a scene with no loose material simply never finds one.
func _world() -> Node:
	if _granular_world != null and is_instance_valid(_granular_world):
		return _granular_world
	_granular_world = get_tree().get_first_node_in_group(&"granular_world")
	return _granular_world
