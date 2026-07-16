extends Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_isolated_mask_and_mesh():
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
	if fill.get_faces().size() != 36:
		return _fail(
			"isolated fill should have 12 tris (36 verts), got %d"
			% fill.get_faces().size()
		)
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
	if fill.get_faces().size() != 30:
		return _fail(
			"merged large fill should have 10 tris (30 verts), got %d"
			% fill.get_faces().size()
		)
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
	# Must not merge with base construction frame.
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
