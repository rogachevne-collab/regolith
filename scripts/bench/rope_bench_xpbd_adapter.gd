class_name RopeBenchXpbdAdapter
extends RefCounted
## Bench adapter for the Ropes! addon's XPBD core (addons/ropes/core/xpbd_rope.gd).
##
## Lives on the game side of the fence, same as RopeBenchVerletAdapter: the
## bench must not know this exists any more than it knows about the verlet
## rope it already judges. Every dial below is left at the core's own default
## — which is also Rope3D's own exported default — so this measures what a
## freshly authored Rope3D produces out of the box, not a hand-tuned best case.
##
## reported_length() uses total_polyline_length(), the drawn shape, NOT a
## separately-tracked "solved length" the way the verlet adapter deliberately
## avoids CableRopeSolver's raw polyline (see that adapter's own comment, and
## cable-rope-fix-status in project memory: routed_length_m() used to read a
## polyline inflated by collision AFTER the tension solve had already run,
## manufacturing 1.5 m of phantom stretch). XPBD does not have that seam:
## distance and contact constraints iterate in the SAME loop (ADR 0006), so by
## the time step() returns, positions and lambdas already agree — there is no
## separate "solved" shape to fall out of sync with the drawn one.

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const SEGMENTS_PER_M := 4.0
const MASS_PER_M := 0.5
const RADIUS := 0.02

## Query margin beyond the rope's own bounding sphere, meters. Mirrors
## Rope3D._gather_colliders' maxf(length * 0.25, 1.0); a bench rope is short
## enough that the flat 1 m floor is what actually applies everywhere.
const QUERY_MARGIN_M := 1.0


func create(
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_m: float,
	space: PhysicsDirectSpaceState3D
) -> Variant:
	var sim := XPBDRope.new()
	var segments := maxi(2, int(round(rest_m * SEGMENTS_PER_M)))
	sim.setup(segments, rest_m, MASS_PER_M)
	sim.radius = RADIUS
	sim.lay_line(anchor_a, anchor_b)
	sim.pin(0)
	sim.pin(segments)
	# Gathered ONCE: every RopeBench world is StaticBody3D that never moves,
	# so xform == prev_xform is exact, not an approximation. A scenario with a
	# moving collider would need this re-run per tick the way Rope3D does it.
	sim.colliders = _gather_colliders(sim.positions, space)
	return sim


func step(
	handle: Variant,
	anchor_a: Vector3,
	anchor_b: Vector3,
	_rest_m: float,
	gravity: Vector3,
	delta: float
) -> void:
	var sim: XPBDRope = handle
	sim.gravity = gravity
	# Bench scenarios never move an anchor mid-run today, so this is a no-op
	# after the first call — kept anyway because the adapter contract passes
	# fresh anchors every step and a future moving-anchor scenario should not
	# have to touch this file to start working.
	sim.move_pin(0, anchor_a)
	sim.move_pin(sim.segment_count(), anchor_b)
	sim.step(delta)


func points(handle: Variant) -> PackedVector3Array:
	return (handle as XPBDRope).positions.duplicate()


func reported_length(handle: Variant) -> float:
	return (handle as XPBDRope).total_polyline_length()


## XPBDRope has no sleep system of its own — every particle integrates every
## tick regardless of how still the rope is, unlike CableRopeSolver's real
## quiescent_ticks gate. This reports "at rest" (same yardstick the bench's
## own settle-time measurement uses), not "costs nothing" — the throughput
## row's awake/N count and step_ms should be read with that asymmetry in
## mind, not as a like-for-like sleep comparison.
func is_asleep(handle: Variant) -> bool:
	var sim: XPBDRope = handle
	return sim.max_speed() * RopeBench.STEP_S < RopeBench.SETTLED_MOTION_M


## Ported from Rope3D._gather_colliders (nodes/rope_3d.gd): same shape
## conversion, same reasoning, because a bench that judged a different narrow
## phase than production would be measuring the wrong thing. Trimmed to what
## it needs here — no exclude list (bench anchors are never physics bodies)
## and no previous-transform cache (colliders are gathered once, so this
## tick's transform IS last tick's).
func _gather_colliders(
	positions: PackedVector3Array,
	space: PhysicsDirectSpaceState3D
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

	var out: Array[Dictionary] = []
	var hits := space.intersect_shape(query, 16)
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
			push_warning("RopeBenchXpbdAdapter: unsupported collider shape %s, skipped"
					% (shape_res.get_class() if shape_res else "<null>"))
			continue
		entry.xform = xf
		entry.prev_xform = xf
		var body := obj as RigidBody3D
		entry.linear_velocity = body.linear_velocity if body else Vector3.ZERO
		entry.angular_velocity = body.angular_velocity if body else Vector3.ZERO
		out.append(entry)
	return out


func _basis_from_y(y: Vector3) -> Basis:
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 1e-6:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	return Basis(x, y, x.cross(y))
