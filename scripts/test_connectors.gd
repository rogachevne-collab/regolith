extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless gate for the connector data model: synthesis from legacy pads /
## full surface must reproduce the exact structural surface (same ids), the
## rule table must replace the hardcoded tag ladder, and authored connectors
## must win over synthesis.


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "CONNECTORS")
	var tests: Array[Callable] = [
		_test_full_surface_synthesis,
		_test_pad_synthesis_keeps_ids,
		_test_exact_point_pad_becomes_anchor,
		_test_rule_table_pairs,
		_test_default_table_loads_from_tres,
		_test_authored_connectors_win,
		_test_cache_invalidation,
		_test_metric_transform_all_orientations,
		_test_pose_offset_moves_anchor_and_collider,
		_test_wheel_anchor_uses_exact_point,
		_test_pose_offset_serialization_roundtrip,
		_test_precise_attach_offset_alignment,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("CONNECTORS: PASS")
	get_tree().quit(0)


func _fail(message: String) -> bool:
	push_error("CONNECTORS FAIL: %s" % message)
	print("CONNECTORS: FAIL — %s" % message)
	get_tree().quit(1)
	return false


func _make_frame_archetype() -> ElementArchetype:
	var archetype := ElementArchetype.new()
	archetype.archetype_id = "test_frame"
	archetype.roles = PackedStringArray(["Frame"])
	archetype.footprint_cells = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	return archetype


func _test_full_surface_synthesis() -> bool:
	var archetype := _make_frame_archetype()
	var connectors := archetype.effective_connectors()
	# 2x1x1 box: 10 external faces (12 minus the 2 shared between the cells).
	if connectors.size() != 10:
		return _fail(
			"full-surface 2x1x1 expected 10 connectors, got %d"
			% connectors.size()
		)
	for connector: ConnectorDefinition in connectors:
		if not connector.is_grid:
			return _fail("full-surface connector must be grid")
		if connector.normalized_tag() != "structural":
			return _fail("full-surface connector tag must normalize to structural")
		var expected_id := GridSurfaceUtil.structural_id_for(
			connector.grid_cell,
			connector.grid_face
		)
		if connector.id != expected_id:
			return _fail(
				"connector id %s != structural id %s"
				% [connector.id, expected_id]
			)
		var expected_center := FootprintUtil.face_center_local(
			connector.grid_cell,
			connector.grid_face
		)
		if not connector.local_position.is_equal_approx(expected_center):
			return _fail("grid connector position must be the face centre")
	return true


func _test_pad_synthesis_keeps_ids() -> bool:
	var archetype := ElementArchetype.new()
	archetype.archetype_id = "test_wheel"
	archetype.structural_surface_policy = (
		ElementArchetype.StructuralSurfacePolicy.MOUNT_PADS
	)
	var pad := StructuralMountPad.new()
	pad.local_cell = Vector3i(0, 1, 0)
	pad.local_face = OrientationUtil.Face.POS_Y
	pad.socket_tag = "wheel_plug"
	archetype.structural_mount_pads = [pad]
	var connectors := archetype.effective_connectors()
	if connectors.size() != 1:
		return _fail("pad synthesis expected 1 connector, got %d" % connectors.size())
	var connector: ConnectorDefinition = connectors[0]
	if connector.id != GridSurfaceUtil.structural_id_for(
		pad.local_cell,
		pad.local_face
	):
		return _fail("pad connector id must reuse the structural id scheme")
	if connector.tag != "wheel_plug":
		return _fail("pad connector must keep its socket tag")
	if not connector.symmetric:
		return _fail("wheel_plug connector should default to symmetric")
	if not connector.local_direction.is_equal_approx(Vector3.UP):
		return _fail("POS_Y pad connector direction must be +Y")
	return true


func _test_exact_point_pad_becomes_anchor() -> bool:
	var pad := StructuralMountPad.new()
	pad.local_cell = Vector3i.ZERO
	pad.local_face = OrientationUtil.Face.POS_X
	pad.exact_point = true
	pad.local_position = Vector3(0.4, 0.31, 0.17)
	var connector := ConnectorDefinition.from_pad(pad)
	if not connector.local_position.is_equal_approx(pad.local_position):
		return _fail("exact-point pad must become the connector anchor")
	if not connector.is_grid:
		return _fail("pad-born connector still bridges to the grid")
	return true


func _test_rule_table_pairs() -> bool:
	var table := ConnectorRuleTable.default_table()
	if not table.compatible("", ""):
		return _fail("empty tags (plain structural) must mate")
	if not table.compatible("structural", ""):
		return _fail("'structural' and empty tag are the same tag")
	if not table.compatible("wheel_socket", "wheel_plug"):
		return _fail("wheel_socket must mate wheel_plug")
	if not table.compatible("wheel_plug", "wheel_socket"):
		return _fail("rule pairs must be symmetric")
	if table.compatible("wheel_plug", "wheel_plug"):
		return _fail("wheel_plug must not mate itself")
	if table.compatible("structural", "wheel_socket"):
		return _fail("structural must not mate wheel_socket")
	return true


func _test_default_table_loads_from_tres() -> bool:
	if not ResourceLoader.exists(ConnectorRuleTable.DEFAULT_TABLE_PATH):
		return _fail("default rule table resource missing")
	var loaded: Resource = load(ConnectorRuleTable.DEFAULT_TABLE_PATH)
	if not (loaded is ConnectorRuleTable):
		return _fail("connector_rules.tres did not load as ConnectorRuleTable")
	if (loaded as ConnectorRuleTable).rules.size() < 2:
		return _fail("default rule table must ship structural + wheel rules")
	return true


func _test_authored_connectors_win() -> bool:
	var archetype := _make_frame_archetype()
	var authored := ConnectorDefinition.new()
	authored.id = "hub"
	authored.local_position = Vector3(0.5, 0.25, 0.25)
	authored.local_direction = Vector3.RIGHT
	authored.tag = "wheel_plug"
	archetype.connectors = [authored]
	var connectors := archetype.effective_connectors()
	if connectors.size() != 1 or connectors[0] != authored:
		return _fail("authored connectors must suppress synthesis")
	return true


func _test_metric_transform_all_orientations() -> bool:
	# The metric mapping must send a face centre exactly where cell topology
	# says that face is — for every one of the 24 orientations. A corner
	# pivot passes identity but drifts ±half a cell under negative axes.
	var origin := Vector3i(3, -2, 5)
	var local_cell := Vector3i(1, 0, 2)
	for orientation: int in range(OrientationUtil.ORIENTATION_COUNT):
		for face: OrientationUtil.Face in FootprintUtil.FACE_ORDER:
			var metric := GridPoseUtil.element_metric_transform(
				origin,
				orientation
			)
			var mapped: Vector3 = metric * FootprintUtil.face_center_local(
				local_cell,
				face
			)
			var world_cell := origin + OrientationUtil.rotate_cell(
				local_cell,
				orientation
			)
			var expected := (
				GridMetric.cell_center_meters(world_cell)
				+ Vector3(OrientationUtil.rotate_direction(
					OrientationUtil.face_to_vector(face),
					orientation
				)) * GridMetric.HALF_CELL_SIZE_M
			)
			if not mapped.is_equal_approx(expected):
				return _fail(
					"metric transform drifted at orientation %d face %d: %s != %s"
					% [orientation, face, mapped, expected]
				)
	return true


func _test_pose_offset_moves_anchor_and_collider() -> bool:
	var origin := Vector3i(1, 0, -4)
	var orientation := 7
	var offset := Transform3D(Basis.IDENTITY, Vector3(0.1, -0.05, 0.02))
	var point := Vector3(0.3, 0.4, 0.1)
	var without: Vector3 = GridPoseUtil.element_metric_transform(
		origin,
		orientation
	) * point
	var with_offset: Vector3 = GridPoseUtil.element_metric_transform(
		origin,
		orientation,
		offset
	) * point
	var moved := with_offset - without
	var expected_move: Vector3 = (
		OrientationUtil.orientation_basis(orientation) * offset.origin
	)
	if not moved.is_equal_approx(expected_move):
		return _fail(
			"pose offset must move metric points by the rotated offset: %s != %s"
			% [moved, expected_move]
		)
	var delta := GridPoseUtil.element_pose_delta(origin, orientation, offset)
	if not (delta * without).is_equal_approx(with_offset):
		return _fail("pose delta conjugation must equal metric composition")
	if GridPoseUtil.element_pose_delta(
		origin,
		orientation,
		Transform3D.IDENTITY
	) != Transform3D.IDENTITY:
		return _fail("identity pose offset must produce identity delta")
	return true


func _test_wheel_anchor_uses_exact_point() -> bool:
	var archetype := ElementArchetype.new()
	archetype.archetype_id = "test_suspension"
	archetype.structural_surface_policy = (
		ElementArchetype.StructuralSurfacePolicy.MOUNT_PADS
	)
	var pad := StructuralMountPad.new()
	pad.local_cell = Vector3i.ZERO
	pad.local_face = OrientationUtil.Face.NEG_Y
	pad.socket_tag = "wheel_socket"
	pad.exact_point = true
	pad.local_position = Vector3(0.25, -0.12, 0.25)
	archetype.structural_mount_pads = [pad]
	var element := SimulationElement.new()
	element.origin_cell = Vector3i(2, 1, 0)
	element.orientation_index = 5
	element.archetype_id = archetype.archetype_id
	element.bind_archetype(archetype)
	var anchor := WheelProjectionUtil.mount_pad_anchor_assembly_local(
		element,
		"wheel_socket"
	)
	if anchor.is_empty():
		return _fail("wheel anchor not found via connectors")
	var expected: Vector3 = GridPoseUtil.element_metric_transform(
		element.origin_cell,
		element.orientation_index
	) * pad.local_position
	if not (anchor["origin"] as Vector3).is_equal_approx(expected):
		return _fail(
			"wheel anchor must sit at the exact connector point: %s != %s"
			% [anchor["origin"], expected]
		)
	return true


func _test_pose_offset_serialization_roundtrip() -> bool:
	var element := SimulationElement.new()
	element.element_id = 42
	element.pose_offset = Transform3D(
		Basis(Vector3.UP, 0.3),
		Vector3(0.07, 0.0, -0.11)
	)
	var restored := SimulationElement.from_dict(element.to_dict())
	if not restored.pose_offset.is_equal_approx(element.pose_offset):
		return _fail("pose_offset must round-trip through to_dict/from_dict")
	var plain := SimulationElement.new()
	if plain.to_dict().has("pose_offset"):
		return _fail("identity pose_offset must not be serialized")
	return true


func _test_precise_attach_offset_alignment() -> bool:
	# Suspension: wheel_socket pad on NEG_Y with an exact hub-slot point.
	var suspension := ElementArchetype.new()
	suspension.archetype_id = "test_susp_precise"
	suspension.structural_surface_policy = (
		ElementArchetype.StructuralSurfacePolicy.MOUNT_PADS
	)
	var socket := StructuralMountPad.new()
	socket.local_cell = Vector3i.ZERO
	socket.local_face = OrientationUtil.Face.NEG_Y
	socket.socket_tag = "wheel_socket"
	socket.exact_point = true
	socket.local_position = Vector3(0.31, -0.08, 0.22)
	suspension.structural_mount_pads = [socket]
	var suspension_element := SimulationElement.new()
	suspension_element.origin_cell = Vector3i(4, 3, -1)
	suspension_element.orientation_index = 0
	suspension_element.archetype_id = suspension.archetype_id
	suspension_element.bind_archetype(suspension)
	# Wheel: plug pad on POS_Y with the exact point at the wheel centre.
	var wheel := ElementArchetype.new()
	wheel.archetype_id = "test_wheel_precise"
	wheel.structural_surface_policy = (
		ElementArchetype.StructuralSurfacePolicy.MOUNT_PADS
	)
	var plug := StructuralMountPad.new()
	plug.local_cell = Vector3i.ZERO
	plug.local_face = OrientationUtil.Face.POS_Y
	plug.socket_tag = "wheel_plug"
	plug.exact_point = true
	plug.local_position = Vector3(0.25, 0.4, 0.25)
	wheel.structural_mount_pads = [plug]
	var wheel_origin := Vector3i(4, 2, -1)
	var wheel_orientation := 0
	var offset := ConstructionPlacement.precise_attach_pose_offset(
		suspension_element,
		FootprintUtil.structural_id_for(socket.local_cell, socket.local_face),
		wheel,
		wheel_origin,
		wheel_orientation,
		FootprintUtil.structural_id_for(plug.local_cell, plug.local_face)
	)
	if offset == Transform3D.IDENTITY:
		return _fail("precise pads must produce a non-identity pose offset")
	var socket_world: Vector3 = GridPoseUtil.element_metric_transform(
		suspension_element.origin_cell,
		suspension_element.orientation_index
	) * socket.local_position
	var plug_world: Vector3 = GridPoseUtil.element_metric_transform(
		wheel_origin,
		wheel_orientation,
		offset
	) * plug.local_position
	if not plug_world.is_equal_approx(socket_world):
		return _fail(
			"precise attach must join the exact points: %s != %s"
			% [plug_world, socket_world]
		)
	# Plain face-centred pads must keep the grid pose untouched.
	socket.exact_point = false
	plug.exact_point = false
	suspension.invalidate_connector_cache()
	wheel.invalidate_connector_cache()
	var plain := ConstructionPlacement.precise_attach_pose_offset(
		suspension_element,
		FootprintUtil.structural_id_for(socket.local_cell, socket.local_face),
		wheel,
		wheel_origin,
		wheel_orientation,
		FootprintUtil.structural_id_for(plug.local_cell, plug.local_face)
	)
	if plain != Transform3D.IDENTITY:
		return _fail("plain grid pads must keep identity pose offset")
	return true


func _test_cache_invalidation() -> bool:
	var archetype := _make_frame_archetype()
	var before := archetype.effective_connectors().size()
	archetype.footprint_cells = [Vector3i(0, 0, 0)]
	archetype.invalidate_connector_cache()
	var after := archetype.effective_connectors().size()
	if before != 10 or after != 6:
		return _fail(
			"cache invalidation expected 10 -> 6 connectors, got %d -> %d"
			% [before, after]
		)
	return true
