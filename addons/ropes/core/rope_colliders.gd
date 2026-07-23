extends RefCounted
# The narrow phase, shared by every solver core.
#
# This file exists because of one line in ADR 0008: "the moment the narrow
# phase forks per solver, that bet has been lost." Two cores with contacts is a
# maintenance cost taken on knowingly (ADR 0007); two cores with two *different*
# ideas of where a box's surface is would be a different and much worse thing —
# a bug reproducible in one solver and not the other, in geometry code where
# neither answer looks obviously wrong.
#
# So: everything here is pure geometry over the collider list the host caches
# once per tick (ADR 0006 decision 2). No positions are written, no constraint
# is solved, nothing here knows whether it is being asked by a dual method or a
# primal one. What each core does with a distance and a normal is its own
# business and stays in its own file.
#
# All functions are static. There is no state to own — the caller keeps the
# per-collider scratch arrays, because it knows how many colliders it has and
# when they changed.

## Collider shapes. The analytic set (ADR 0006 decision 9); concave meshes and
## the host's voxel terrain are slice 2 and arrive as another case here rather
## than as another code path in each core.
const SHAPE_PLANE := 0   # xform.basis.y = normal, xform.origin = point
const SHAPE_SPHERE := 1  # params.x = radius
const SHAPE_BOX := 2     # params = half extents

## Returned by [method probe] when the query has no answer — a point exactly at
## a sphere's centre, or an unsupported shape. Callers check `is_finite(w)`.
const NO_CONTACT := Vector4(0.0, 0.0, 0.0, INF)

## "Nothing near this particle" in a local-plane buffer: a zero normal.
const NO_PLANE := Vector4(0.0, 0.0, 0.0, 0.0)


## Bounding-sphere reject, once per step. Without it every sample is tested
## against every collider on every substep, so a rope hanging in mid-air pays
## full price for the ground five meters below it (measured: 2195 -> 1472
## us/step, ADR 0006). Fills `near` and returns false if nothing is in reach.
static func cull(colliders: Array[Dictionary], positions: PackedVector3Array,
		skin: float, motion: float, near: Array[bool]) -> bool:
	near.resize(colliders.size())
	var lo := positions[0]
	var hi := lo
	for i in positions.size():
		lo = lo.min(positions[i])
		hi = hi.max(positions[i])
	# Box against box, both of them real. Bounding spheres lie in both
	# directions here: a rope is a line, so its sphere is mostly empty, and a
	# gantry leg is a tall thin box, whose sphere is 4.8 m of nothing. Sphere
	# against sphere therefore called a pillar two metres to the rope's side
	# "near", and every particle then paid for a full probe against it, every
	# iteration of every substep. Measured on the gate 5 bench, that mistake
	# was most of a 22 ms frame.
	var rope_box := AABB(lo, hi - lo)
	var any := false
	for ci in colliders.size():
		var col: Dictionary = colliders[ci]
		var shape: int = col.shape
		var is_near := true
		if shape != SHAPE_PLANE:
			var params: Vector3 = col.params
			var xf: Transform3D = col.xform
			var travel: float = (xf.origin - (col.prev_xform as Transform3D).origin).length()
			var box: AABB
			if shape == SHAPE_SPHERE:
				box = AABB(xf.origin - Vector3.ONE * params.x, Vector3.ONE * params.x * 2.0)
			else:
				box = xf * AABB(-params, params * 2.0)
			# Margin covers this step's motion plus the contact skin, so a fast
			# rope cannot be culled into something it is about to hit.
			is_near = rope_box.intersects(box.grow(skin + motion + travel))
		near[ci] = is_near
		any = any or is_near
	return any


## Collider transforms at substep fraction `t`, interpolated from last tick's.
## A wall frozen for a whole tick teleports 1.7 m at 100 m/s and the rope ends
## up inside the rocket's hull; a wall that advances 5 cm per substep pushes it
## honestly (ADR 0006 decision 3).
static func interpolate(colliders: Array[Dictionary], t: float,
		near: Array[bool], xforms: Array[Transform3D],
		inverses: Array[Transform3D]) -> void:
	xforms.resize(colliders.size())
	inverses.resize(colliders.size())
	for ci in colliders.size():
		if not near[ci]:
			continue
		var col: Dictionary = colliders[ci]
		var prev: Transform3D = col.prev_xform
		var curr: Transform3D = col.xform
		var xf: Transform3D
		if prev == curr:
			xf = curr
		else:
			var q := Quaternion(prev.basis).slerp(Quaternion(curr.basis), t)
			xf = Transform3D(Basis(q), prev.origin.lerp(curr.origin, t))
		xforms[ci] = xf
		inverses[ci] = xf.affine_inverse()


## Signed distance from `p` to one collider's surface, and the outward normal
## there, packed as (normal.xyz, distance).
##
## Packed into a Vector4 rather than returned as a Dictionary on purpose: this
## runs per sample per collider per substep, and a Dictionary would allocate on
## every one of those. Vector4 is a value type and costs nothing.
##
## Negative distance means inside. [constant NO_CONTACT] means no answer.
static func probe(shape: int, params: Vector3, xf: Transform3D,
		inv_xf: Transform3D, p: Vector3) -> Vector4:
	var dist: float
	var n: Vector3
	match shape:
		SHAPE_PLANE:
			n = xf.basis.y
			dist = (p - xf.origin).dot(n)
		SHAPE_SPHERE:
			var v := p - xf.origin
			var vl := v.length()
			if vl < 1e-12:
				return NO_CONTACT
			n = v / vl
			dist = vl - params.x
		SHAPE_BOX:
			var local := inv_xf * p
			var q := local.abs() - params
			if q.x > 0.0 or q.y > 0.0 or q.z > 0.0:
				var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
				dist = outside.length()
				var n_local := (outside / dist) * local.sign()
				n = xf.basis * n_local
			else:
				# Inside: push out through the nearest face.
				dist = maxf(q.x, maxf(q.y, q.z))
				var n_local := Vector3.ZERO
				if q.x >= q.y and q.x >= q.z:
					n_local.x = signf(local.x)
				elif q.y >= q.z:
					n_local.y = signf(local.y)
				else:
					n_local.z = signf(local.z)
				n = xf.basis * n_local
		_:
			return NO_CONTACT
	return Vector4(n.x, n.y, n.z, dist)


## Velocity of a collider's surface at world point `p` — a contact against a
## moving body must be solved against the surface's velocity, not against zero,
## or a rope inside an accelerating rocket is wrong in the one case ADR 0006
## was written for.
static func surface_velocity(col: Dictionary, xf: Transform3D, p: Vector3) -> Vector3:
	return (col.linear_velocity as Vector3) \
			+ (col.angular_velocity as Vector3).cross(p - xf.origin)


## Broadphase gather for hosts (Rope3D, Regolith cable facade). Returns
## { colliders: Array[Dictionary], cache: Dictionary } where cache maps
## "%instance_id:owner_id" → this tick's transform for next tick's
## prev_xform (ADR 0006 moving colliders).
static func gather_from_space(
		positions: PackedVector3Array,
		space_state: PhysicsDirectSpaceState3D,
		collision_mask: int,
		margin_m: float,
		prev_cache: Dictionary,
		exclude: Array[RID] = []
) -> Dictionary:
	var out: Array[Dictionary] = []
	var next_cache := {}
	if positions.is_empty() or space_state == null:
		return {"colliders": out, "cache": next_cache}
	var lo := positions[0]
	var hi := lo
	for p: Vector3 in positions:
		lo = lo.min(p)
		hi = hi.max(p)
	var center := (lo + hi) * 0.5
	var query_shape := SphereShape3D.new()
	query_shape.radius = (hi - lo).length() * 0.5 + margin_m

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = query_shape
	query.transform = Transform3D(Basis.IDENTITY, center)
	query.collision_mask = collision_mask
	query.exclude = exclude

	var hits := space_state.intersect_shape(query, 16)
	for hit: Dictionary in hits:
		var obj := hit.collider as CollisionObject3D
		if obj == null:
			continue
		var shape_index: int = int(hit.get("shape", -1))
		if shape_index < 0:
			continue
		var resolved := _resolve_owner_shape(obj, shape_index)
		if resolved.is_empty():
			continue
		var owner_id: int = int(resolved.owner_id)
		var shape_res := resolved.shape as Shape3D
		if shape_res == null:
			continue
		# Owner transform only — shape_owner_get_shape_transform is not in 4.8;
		# matches bench adapter and Regolith's one-shape-per-owner colliders.
		var xf: Transform3D = (
			obj.global_transform * obj.shape_owner_get_transform(owner_id)
		)
		var entry := {}
		if shape_res is BoxShape3D:
			entry.shape = SHAPE_BOX
			entry.params = (shape_res as BoxShape3D).size * 0.5
		elif shape_res is SphereShape3D:
			entry.shape = SHAPE_SPHERE
			entry.params = Vector3((shape_res as SphereShape3D).radius, 0, 0)
		elif shape_res is WorldBoundaryShape3D:
			var plane := (shape_res as WorldBoundaryShape3D).plane
			var n := (xf.basis * plane.normal).normalized()
			var point := xf * (plane.normal * plane.d)
			entry.shape = SHAPE_PLANE
			entry.params = Vector3.ZERO
			xf = Transform3D(_basis_from_y(n), point)
		else:
			continue
		entry.xform = xf
		# Body RID so a host running the local-plane pass can exclude what it
		# already solves analytically: the same wall solved twice is the same
		# wall with twice the friction.
		entry.body_rid = hit.get("rid", RID())
		var key := "%d:%d" % [obj.get_instance_id(), owner_id]
		entry.prev_xform = prev_cache.get(key, xf)
		next_cache[key] = xf
		var body := obj as RigidBody3D
		entry.linear_velocity = body.linear_velocity if body else Vector3.ZERO
		entry.angular_velocity = body.angular_velocity if body else Vector3.ZERO
		out.append(entry)
	return {"colliders": out, "cache": next_cache}


## One contact plane per particle for everything the analytic set cannot
## express: concave meshes, heightmaps, and the reason this exists at all — a
## voxel planet, whose surface is a marching-cubes crust rebuilt as you dig it
## (ADR 0006 slice 2).
##
## Design, in one line: ask the physics server where the surface is once per
## tick, per particle; let the core solve a plane every substep. The
## alternative — asking the server inside the substep loop — is the same query
## 32 times per particle per tick for geometry that moved by nothing.
##
## The probe is a sphere of `radius + probe_margin`, so a surface is found
## before the rope reaches it and the core has a plane ready when it does.
## `probe_margin` is therefore also the speed limit: a rope crossing more than
## that in one tick meets a wall nobody sampled.
##
## Returns the buffer to ASSIGN to [member XPBDRope.local_planes], or an empty
## one when nothing was found — which the core reads as "skip the pass", so a
## rope in mid-air costs nothing beyond the queries. Returned rather than
## filled in place because a [PackedVector4Array] handed to a function is a
## copy, and an out-parameter here would silently discard every plane.
##
## Costs one shape query per particle per tick; hosts with long ropes should
## probe on the mask that actually holds terrain rather than on everything.
static func sample_local_planes(
		positions: PackedVector3Array,
		space_state: PhysicsDirectSpaceState3D,
		collision_mask: int,
		radius: float,
		probe_margin: float,
		exclude: Array[RID]
) -> PackedVector4Array:
	var out_planes := PackedVector4Array()
	var count := positions.size()
	if count == 0 or space_state == null:
		return out_planes
	out_planes.resize(count)
	out_planes.fill(NO_PLANE)
	var probe := SphereShape3D.new()
	probe.radius = maxf(radius + probe_margin, 0.001)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = exclude
	var any := false
	for i in count:
		query.transform = Transform3D(Basis.IDENTITY, positions[i])
		var rest := space_state.get_rest_info(query)
		if rest.is_empty():
			continue
		var n: Vector3 = rest.get("normal", Vector3.ZERO)
		if n.length_squared() < 1e-12:
			continue
		n = n.normalized()
		# The plane through the surface point the server reported. Degenerate
		# triangles in a voxel mesh can report a point at infinity; a plane
		# constant that is not finite would poison every substep.
		var point: Vector3 = rest.get("point", positions[i])
		var d := n.dot(point)
		if not is_finite(d):
			continue
		out_planes[i] = Vector4(n.x, n.y, n.z, d)
		any = true
	return out_planes if any else PackedVector4Array()


## Body RIDs behind a gathered analytic collider list, for excluding them from
## [method sample_local_planes].
static func body_rids(colliders: Array[Dictionary]) -> Array[RID]:
	var out: Array[RID] = []
	for col: Dictionary in colliders:
		var rid: RID = col.get("body_rid", RID())
		if rid.is_valid() and not out.has(rid):
			out.append(rid)
	return out


## Map a physics-server shape index from intersect_shape to owner-local data.
static func _resolve_owner_shape(obj: CollisionObject3D, shape_index: int) -> Dictionary:
	var owner_id := obj.shape_find_owner(shape_index)
	if owner_id < 0:
		return {}
	var count := obj.shape_owner_get_shape_count(owner_id)
	for si in count:
		if obj.shape_owner_get_shape_index(owner_id, si) == shape_index:
			return {
				"owner_id": owner_id,
				"local_idx": si,
				"shape": obj.shape_owner_get_shape(owner_id, si),
			}
	return {}


static func _basis_from_y(y: Vector3) -> Basis:
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 1e-6:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	return Basis(x, y, x.cross(y))
