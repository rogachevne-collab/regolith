extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless gate for the one-node PartAuthoringRoot: baking a WHEEL / SUSPENSION
## from a few fields + markers must emit a COMPLETE, valid ElementArchetype
## (footprint, colliders, pads, tuning, drive axis) with zero hand math.


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "PART-AUTHORING")
	var tests: Array[Callable] = [
		_test_wheel_bakes_valid,
		_test_suspension_bakes_valid,
		_test_wheel_needs_one_marker,
		_test_forward_axis_auto_perpendicular,
		_test_bake_saves_and_reloads,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("PART-AUTHORING: PASS")
	get_tree().quit(0)


func _fail(message: String) -> bool:
	push_error("PART-AUTHORING FAIL: %s" % message)
	print("PART-AUTHORING: FAIL — %s" % message)
	get_tree().quit(1)
	return false


func _make_root(kind: PartAuthoringRoot.PartKind) -> PartAuthoringRoot:
	var root := PartAuthoringRoot.new()
	root.part_kind = kind
	add_child(root)
	return root


func _add_marker(
	root: PartAuthoringRoot,
	kind: MountPadMarker.SocketKind,
	cell: Vector3i,
	face: OrientationUtil.Face
) -> void:
	var marker := MountPadMarker.new()
	marker.socket_kind = kind
	root.add_child(marker)
	marker.position = _face_center(cell, face)


func _face_center(cell: Vector3i, face: OrientationUtil.Face) -> Vector3:
	return (
		GridMetric.cell_center_meters(cell)
		+ Vector3(OrientationUtil.face_to_vector(face)) * GridMetric.HALF_CELL_SIZE_M
	)


func _count_pads(archetype: ElementArchetype, tag: String) -> int:
	var count := 0
	for pad: StructuralMountPad in archetype.structural_mount_pads:
		if pad.socket_tag == tag:
			count += 1
	return count


func _test_wheel_bakes_valid() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.WHEEL)
	root.part_id = "test_wheel"
	root.wheel_radius_m = 0.5
	root.wheel_drive_torque_n_m = 80.0
	_add_marker(
		root,
		MountPadMarker.SocketKind.WHEEL_PLUG,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.POS_Y
	)
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	if not errors.is_empty():
		root.free()
		return _fail("wheel build errors: %s" % [errors])
	if archetype == null:
		root.free()
		return _fail("wheel build returned null")
	var validation := BlueprintValidator.validate_archetype(archetype)
	var wheel_errors := archetype.wheel_definition.validate(archetype)
	root.free()
	if not validation.ok:
		return _fail("wheel archetype invalid: %s" % [validation.errors])
	if not wheel_errors.is_empty():
		return _fail("wheel definition invalid: %s" % [wheel_errors])
	if _count_pads(archetype, "wheel_plug") != 1:
		return _fail("wheel should expose exactly one wheel_plug pad")
	if not is_equal_approx(archetype.wheel_definition.radius_m, 0.5):
		return _fail("wheel radius not carried through")
	if archetype.colliders.size() != 1:
		return _fail("1-cell wheel should have 1 auto collider")
	return true


func _test_suspension_bakes_valid() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.SUSPENSION)
	root.part_id = "test_susp"
	root.size_cells = Vector3i(1, 2, 1)
	_add_marker(
		root,
		MountPadMarker.SocketKind.STRUCTURAL,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.POS_X
	)
	_add_marker(
		root,
		MountPadMarker.SocketKind.WHEEL_SOCKET,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.NEG_Y
	)
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	if not errors.is_empty():
		root.free()
		return _fail("suspension build errors: %s" % [errors])
	var validation := BlueprintValidator.validate_archetype(archetype)
	var susp_errors := archetype.suspension_definition.validate(archetype)
	var socket_face := archetype.suspension_definition.wheel_socket_face
	root.free()
	if not validation.ok:
		return _fail("suspension archetype invalid: %s" % [validation.errors])
	if not susp_errors.is_empty():
		return _fail("suspension definition invalid: %s" % [susp_errors])
	if _count_pads(archetype, "wheel_socket") != 1:
		return _fail("suspension should expose exactly one wheel_socket")
	if _count_pads(archetype, "") < 1:
		return _fail("suspension should expose a structural pad")
	if socket_face != OrientationUtil.Face.NEG_Y:
		return _fail("suspension socket face should follow the marker (NEG_Y)")
	return true


func _test_wheel_needs_one_marker() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.WHEEL)
	root.part_id = "test_wheel_two"
	_add_marker(
		root,
		MountPadMarker.SocketKind.WHEEL_PLUG,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.POS_Y
	)
	_add_marker(
		root,
		MountPadMarker.SocketKind.WHEEL_PLUG,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.POS_Z
	)
	var errors: Array[String] = []
	root._build_archetype(errors)
	root.free()
	var joined := " ".join(errors)
	if joined.find("маркер") < 0:
		return _fail("two markers on a wheel should error, got %s" % [errors])
	return true


func _test_forward_axis_auto_perpendicular() -> bool:
	# Plug on +X: the tool must pick a forward axis perpendicular to it.
	var root := _make_root(PartAuthoringRoot.PartKind.WHEEL)
	root.part_id = "test_wheel_x"
	_add_marker(
		root,
		MountPadMarker.SocketKind.WHEEL_PLUG,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.POS_X
	)
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	var forward := OrientationUtil.face_to_vector(
		archetype.wheel_definition.forward_axis_face
	)
	var wheel_errors := archetype.wheel_definition.validate(archetype)
	root.free()
	if forward.x != 0:
		return _fail("forward axis not perpendicular to +X plug: %s" % [forward])
	if not wheel_errors.is_empty():
		return _fail("auto forward axis failed validation: %s" % [wheel_errors])
	return true


func _test_bake_saves_and_reloads() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.WHEEL)
	root.part_id = "tmp_saved_wheel"
	root.save_dir = "user://authored_test/"
	_add_marker(
		root,
		MountPadMarker.SocketKind.WHEEL_PLUG,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.POS_Y
	)
	var result := root.bake()
	root.free()
	if not bool(result.get("ok", false)):
		return _fail("bake failed: %s" % [result])
	var path := "user://authored_test/tmp_saved_wheel.tres"
	var reloaded := ResourceLoader.load(
		path, "", ResourceLoader.CACHE_MODE_IGNORE
	) as ElementArchetype
	if reloaded == null:
		return _fail("saved wheel did not reload")
	if reloaded.wheel_definition == null:
		return _fail("saved wheel lost its wheel_definition")
	if reloaded.archetype_id != "tmp_saved_wheel":
		return _fail("saved wheel id mismatch: %s" % reloaded.archetype_id)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return true
