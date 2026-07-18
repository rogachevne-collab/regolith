extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")

func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "CONNECTED-BLOCK-VISUAL-POC")
	if not _test_isolated_mask_and_mesh():
		return
	if not _test_mesh_winding_and_normals():
		return
	if not _test_rim_covers_corners():
		return
	if not _test_adjacent_frames_merge():
		return
	if not _test_different_archetypes_do_not_merge():
		return
	if not _test_adjacent_large_frames_merge():
		return
	if not _test_adjacent_rover_frames_merge():
		return
	print("CONNECTED-BLOCK-VISUAL-POC: PASS")
	get_tree().quit(0)


func _test_isolated_mask_and_mesh() -> bool:
	var element := _make_element(1, Slice01Archetypes.frame(), Vector3i.ZERO)
	var mask := ConnectedBlockVisual.face_occlusion_mask(
		element,
		{Vector3i.ZERO: 1},
		{1: "frame"}
	)
	if mask != 0:
		return _fail("isolated frame should have empty occlusion mask")
	if ConnectedBlockVisual.visible_face_count(mask) != 6:
		return _fail("isolated frame should expose 6 faces")
	if ConnectedBlockVisual.visible_edge_count(mask) != 12:
		return _fail("isolated frame should expose 12 rim edges")
	var size := Vector3.ONE * GridMetric.CELL_SIZE_M
	var fill := ConnectedBlockVisual.make_fill_mesh(size, mask)
	var rim := ConnectedBlockVisual.make_rim_mesh(size, mask)
	if fill == null or fill.get_surface_count() != 1:
		return _fail("isolated fill mesh missing")
	if rim == null or rim.get_surface_count() != 1:
		return _fail("isolated rim mesh missing")
	## 6 faces × 2 tris × 3 verts = 36
	if fill.get_faces().size() != 36:
		return _fail(
			"isolated fill should have 12 tris (36 verts), got %d"
			% fill.get_faces().size()
		)
	## 6 faces × (4 strips + 4 corners) × 2 tris × 3 verts = 288
	if rim.get_faces().size() != 288:
		return _fail(
			"isolated rim should have 96 tris (288 verts), got %d"
			% rim.get_faces().size()
		)
	return true


func _test_mesh_winding_and_normals() -> bool:
	var size := Vector3.ONE * GridMetric.CELL_SIZE_M
	var fill := ConnectedBlockVisual.make_fill_mesh(size, 0)
	var rim := ConnectedBlockVisual.make_rim_mesh(size, 0)
	if not _assert_cw_outward_mesh(fill, "fill"):
		return false
	if not _assert_cw_outward_mesh(rim, "rim"):
		return false
	## Every cardinal outward must appear on the isolated fill.
	var normals := fill.surface_get_arrays(0)[Mesh.ARRAY_NORMAL] as PackedVector3Array
	var seen: Dictionary = {}
	for n: Vector3 in normals:
		var key := "%d_%d_%d" % [
			int(round(n.x)),
			int(round(n.y)),
			int(round(n.z)),
		]
		seen[key] = true
	for axis: String in ["1_0_0", "-1_0_0", "0_1_0", "0_-1_0", "0_0_1", "0_0_-1"]:
		if not seen.has(axis):
			return _fail("isolated fill missing outward normal %s" % axis)
	return true


func _test_rim_covers_corners() -> bool:
	var size := Vector3.ONE * GridMetric.CELL_SIZE_M
	var half := size * 0.5
	var rim := ConnectedBlockVisual.make_rim_mesh(size, 0)
	var aabb := rim.get_aabb()
	var tol := 0.002
	var expected_min := -half
	var expected_max := half
	if aabb.position.x > expected_min.x + tol:
		return _fail("rim aabb does not reach -X corner")
	if aabb.position.y > expected_min.y + tol:
		return _fail("rim aabb does not reach -Y corner")
	if aabb.position.z > expected_min.z + tol:
		return _fail("rim aabb does not reach -Z corner")
	var aabb_end := aabb.position + aabb.size
	if aabb_end.x < expected_max.x - tol:
		return _fail("rim aabb does not reach +X corner")
	if aabb_end.y < expected_max.y - tol:
		return _fail("rim aabb does not reach +Y corner")
	if aabb_end.z < expected_max.z - tol:
		return _fail("rim aabb does not reach +Z corner")
	return true


func _test_adjacent_frames_merge() -> bool:
	var left := _make_element(1, Slice01Archetypes.frame(), Vector3i.ZERO)
	var right := _make_element(2, Slice01Archetypes.frame(), Vector3i.RIGHT)
	var occupancy := {
		Vector3i.ZERO: 1,
		Vector3i.RIGHT: 2,
	}
	var archetypes := {1: "frame", 2: "frame"}
	var left_mask := ConnectedBlockVisual.face_occlusion_mask(
		left,
		occupancy,
		archetypes
	)
	var right_mask := ConnectedBlockVisual.face_occlusion_mask(
		right,
		occupancy,
		archetypes
	)
	if not ConnectedBlockVisual.is_face_occluded(
		left_mask,
		OrientationUtil.Face.POS_X
	):
		return _fail("left frame +X should be occluded by neighbour")
	if not ConnectedBlockVisual.is_face_occluded(
		right_mask,
		OrientationUtil.Face.NEG_X
	):
		return _fail("right frame -X should be occluded by neighbour")
	if ConnectedBlockVisual.visible_face_count(left_mask) != 5:
		return _fail("merged frame should expose 5 faces")
	if ConnectedBlockVisual.visible_edge_count(left_mask) != 8:
		return _fail("merged frame should expose 8 rim edges")
	var size := Vector3.ONE * GridMetric.CELL_SIZE_M
	var fill := ConnectedBlockVisual.make_fill_mesh(size, left_mask)
	var rim := ConnectedBlockVisual.make_rim_mesh(size, left_mask)
	if fill.get_faces().size() != 30:
		return _fail(
			"merged fill should have 10 tris (30 verts), got %d"
			% fill.get_faces().size()
		)
	if not _assert_cw_outward_mesh(fill, "merged fill"):
		return false
	## Seam fill must reach the occluded +X face plane (no rim-width gap).
	var fill_aabb := fill.get_aabb()
	var half := size * 0.5
	if fill_aabb.position.x + fill_aabb.size.x < half.x - 0.001:
		return _fail("merged fill does not reach +X seam")
	## Outer perimeter rim must still reach ±Y/±Z corners.
	var rim_aabb := rim.get_aabb()
	if rim_aabb.position.y > -half.y + 0.002:
		return _fail("merged rim lost -Y coverage")
	if rim_aabb.position.y + rim_aabb.size.y < half.y - 0.002:
		return _fail("merged rim lost +Y coverage")
	return true


func _test_different_archetypes_do_not_merge() -> bool:
	var metal := _make_element(1, Slice01Archetypes.frame(), Vector3i.ZERO)
	var basalt := _make_element(
		2,
		Slice01Archetypes.load_required("frame_basalt"),
		Vector3i.RIGHT
	)
	var occupancy := {
		Vector3i.ZERO: 1,
		Vector3i.RIGHT: 2,
	}
	var archetypes := {1: "frame", 2: "frame_basalt"}
	var mask := ConnectedBlockVisual.face_occlusion_mask(
		metal,
		occupancy,
		archetypes
	)
	if ConnectedBlockVisual.is_face_occluded(mask, OrientationUtil.Face.POS_X):
		return _fail("frame must not merge with frame_basalt")
	if ConnectedBlockVisual.visible_edge_count(mask) != 12:
		return _fail("non-merged neighbour must keep full rim")
	return true


func _test_adjacent_large_frames_merge() -> bool:
	var left := _make_element(
		1,
		Slice01Archetypes.large_frame(),
		Vector3i.ZERO
	)
	var right := _make_element(
		2,
		Slice01Archetypes.large_frame(),
		Vector3i(5, 0, 0)
	)
	var occupancy: Dictionary = {}
	var archetypes := {1: "large_frame", 2: "large_frame"}
	for cell: Vector3i in left.get_archetype().get_occupied_cells(
		left.origin_cell,
		left.orientation_index
	):
		occupancy[cell] = 1
	for cell: Vector3i in right.get_archetype().get_occupied_cells(
		right.origin_cell,
		right.orientation_index
	):
		occupancy[cell] = 2
	var left_mask := ConnectedBlockVisual.face_occlusion_mask(
		left,
		occupancy,
		archetypes
	)
	if not ConnectedBlockVisual.is_face_occluded(
		left_mask,
		OrientationUtil.Face.POS_X
	):
		return _fail("large_frame +X should be occluded by neighbour")
	if ConnectedBlockVisual.visible_face_count(left_mask) != 5:
		return _fail("merged large_frame should expose 5 faces")
	if ConnectedBlockVisual.visible_edge_count(left_mask) != 8:
		return _fail("merged large_frame should expose 8 rim edges")
	var size := Vector3.ONE * 2.5
	var fill := ConnectedBlockVisual.make_fill_mesh(size, left_mask)
	var rim := ConnectedBlockVisual.make_rim_mesh(size, left_mask)
	if fill.get_faces().size() != 30:
		return _fail(
			"merged large fill should have 10 tris (30 verts), got %d"
			% fill.get_faces().size()
		)
	if not _assert_cw_outward_mesh(fill, "large fill"):
		return false
	if not _assert_cw_outward_mesh(rim, "large rim"):
		return false
	return true


func _test_adjacent_rover_frames_merge() -> bool:
	var left := _make_element(
		1,
		Slice01Archetypes.rover_frame(),
		Vector3i.ZERO
	)
	var right := _make_element(
		2,
		Slice01Archetypes.rover_frame(),
		Vector3i.RIGHT
	)
	var occupancy := {
		Vector3i.ZERO: 1,
		Vector3i.RIGHT: 2,
	}
	var archetypes := {1: "rover_frame", 2: "rover_frame"}
	var left_mask := ConnectedBlockVisual.face_occlusion_mask(
		left,
		occupancy,
		archetypes
	)
	if not ConnectedBlockVisual.is_face_occluded(
		left_mask,
		OrientationUtil.Face.POS_X
	):
		return _fail("rover_frame +X should be occluded by neighbour")
	if ConnectedBlockVisual.visible_face_count(left_mask) != 5:
		return _fail("merged rover_frame should expose 5 faces")
	if ConnectedBlockVisual.visible_edge_count(left_mask) != 8:
		return _fail("merged rover_frame should expose 8 rim edges")
	## Must not merge with base construction frame.
	var base := _make_element(3, Slice01Archetypes.frame(), Vector3i.LEFT)
	occupancy[Vector3i.LEFT] = 3
	archetypes[3] = "frame"
	var mixed := ConnectedBlockVisual.face_occlusion_mask(
		left,
		occupancy,
		archetypes
	)
	if ConnectedBlockVisual.is_face_occluded(mixed, OrientationUtil.Face.NEG_X):
		return _fail("rover_frame must not merge with construction frame")
	return true


func _assert_cw_outward_mesh(mesh: ArrayMesh, label: String) -> bool:
	if mesh == null or mesh.get_surface_count() < 1:
		return _fail("%s mesh missing surface" % label)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if verts.size() < 3 or verts.size() != normals.size():
		return _fail("%s mesh has invalid vertex/normal arrays" % label)
	if verts.size() % 3 != 0:
		return _fail("%s mesh vertex count not divisible by 3" % label)
	for i in range(0, verts.size(), 3):
		var a: Vector3 = verts[i]
		var b: Vector3 = verts[i + 1]
		var c: Vector3 = verts[i + 2]
		var n: Vector3 = normals[i]
		if not n.is_equal_approx(normals[i + 1]) or not n.is_equal_approx(
			normals[i + 2]
		):
			return _fail("%s triangle %d has mismatched normals" % [label, i / 3])
		if n.length() < 0.9:
			return _fail("%s triangle %d has non-unit normal" % [label, i / 3])
		var geo: Vector3 = (b - a).cross(c - a)
		## Godot front face = clockwise from outside ⇒ geometric normal · outward < 0.
		if geo.dot(n) >= 0.0:
			return _fail(
				"%s triangle %d is not clockwise from outside (geo·n=%s)"
				% [label, i / 3, str(geo.dot(n))]
			)
	return true


func _make_element(
	element_id: int,
	archetype: ElementArchetype,
	origin_cell: Vector3i
) -> SimulationElement:
	var element := SimulationElement.new()
	element.element_id = element_id
	element.archetype_id = archetype.archetype_id
	element.bind_archetype(archetype)
	element.origin_cell = origin_cell
	element.orientation_index = 0
	return element


func _fail(message: String) -> bool:
	push_error("CONNECTED-BLOCK-VISUAL-POC FAIL: %s" % message)
	get_tree().quit(1)
	return false
