extends Node
## Spike: can we pull terrain collider triangles for BLAS baking?
## Usage: attach to a scene with VoxelTerrain/VoxelLodTerrain + VoxelViewer,
## or run as child of main after world ready.

const LABEL := "TERRAIN_COLLIDER_RT_PROBE"
const MAX_WAIT_S := 45.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var terrain := _find_terrain()
	if terrain == null:
		print("%s: FAIL no VoxelTerrain/VoxelLodTerrain" % LABEL)
		get_tree().quit(2)
		return

	print("%s: terrain=%s class=%s" % [LABEL, terrain.get_path(), terrain.get_class()])
	print("%s: authored children:" % LABEL)
	for c in terrain.get_children():
		print("  %s (%s)" % [c.name, c.get_class()])

	var cam := get_viewport().get_camera_3d()
	var origin := Vector3(0.0, 80.0, 0.0)
	if cam != null:
		origin = cam.global_position + Vector3(0.0, 2.0, 0.0)
	var to := origin + Vector3(0.0, -200.0, 0.0)

	var space: PhysicsDirectSpaceState3D = terrain.get_world_3d().direct_space_state
	var hit: Dictionary = {}
	var t0 := Time.get_ticks_msec()
	while hit.is_empty():
		if (Time.get_ticks_msec() - t0) * 0.001 > MAX_WAIT_S:
			print("%s: FAIL timeout waiting for physics hit from %s" % [LABEL, origin])
			get_tree().quit(3)
			return
		await get_tree().physics_frame
		hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(origin, to))

	var collider: Object = hit["collider"]
	print(
		"%s: hit collider=%s class=%s shape=%s rid=%s"
		% [LABEL, collider, collider.get_class(), hit.get("shape", -1), hit.get("rid", RID())]
	)

	var body_rid: RID = hit["rid"]
	var shape_index := int(hit.get("shape", 0))
	var shape_rid := PhysicsServer3D.body_get_shape(body_rid, shape_index)
	var shape_type := PhysicsServer3D.shape_get_type(shape_rid)
	print("%s: shape_type=%s (CONCAVE_POLYGON=%s)" % [
		LABEL, shape_type, PhysicsServer3D.SHAPE_CONCAVE_POLYGON
	])

	if shape_type != PhysicsServer3D.SHAPE_CONCAVE_POLYGON:
		print("%s: FAIL expected concave polygon shape" % LABEL)
		get_tree().quit(5)
		return

	var data: Variant = PhysicsServer3D.shape_get_data(shape_rid)
	if typeof(data) != TYPE_DICTIONARY or not (data as Dictionary).has("faces"):
		print("%s: FAIL shape_get_data missing faces: %s" % [LABEL, data])
		get_tree().quit(6)
		return

	var faces: PackedVector3Array = data["faces"]
	var tris := faces.size() / 3
	var body_xf: Transform3D = PhysicsServer3D.body_get_state(
		body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM
	)
	print("%s: OK triangles=%d verts=%d body_origin=%s" % [
		LABEL, tris, faces.size(), body_xf.origin
	])

	# Sample a few world-space verts to confirm transform is usable for BLAS.
	if faces.size() >= 3:
		var w0 := body_xf * faces[0]
		var w1 := body_xf * faces[1]
		var w2 := body_xf * faces[2]
		print("%s: sample_tri_world=%s %s %s" % [LABEL, w0, w1, w2])

	get_tree().quit(0 if tris > 0 else 7)


func _find_terrain() -> Node:
	var root := get_tree().root
	for n in root.find_children("*", "VoxelLodTerrain", true, false):
		return n
	for n in root.find_children("*", "VoxelTerrain", true, false):
		return n
	return null

