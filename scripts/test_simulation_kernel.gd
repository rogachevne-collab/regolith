extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
const BAKED_FIXTURE_PATH := (
	"res://resources/blueprints/baked/kernel_fixture_valid.tres"
)
const BAKED_BASE_PATH := (
	"res://resources/blueprints/baked/slice01_base_minimal.tres"
)


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "KERNEL-V0")
	var tests: Array[Callable] = [
		_test_required_archetype_assets,
		_test_orientation_contract,
		_test_face_rotation,
		_test_multi_cell_rotation_and_colliders,
		_test_large_frame_fixture,
		_test_marker_preview_matches_occupancy,
		_test_valid_connected_bake,
		_test_deterministic_local_id_ordering,
		_test_overlap_and_local_id_diagnostics,
		_test_archetype_schema_diagnostics,
		_test_connectivity_diagnostics,
		_test_mount_pad_connectivity_policy,
		_test_baked_resources,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("KERNEL-V0: PASS")
	get_tree().quit(0)


func _test_required_archetype_assets() -> bool:
	var archetypes: Array[ElementArchetype] = (
		Slice01Archetypes.load_all_required()
	)
	if archetypes.size() != Slice01Archetypes.REQUIRED_IDS.size():
		return _fail(
			"required archetype assets loaded %d of %d"
			% [
				archetypes.size(),
				Slice01Archetypes.REQUIRED_IDS.size(),
			]
		)
	for index: int in range(archetypes.size()):
		var archetype: ElementArchetype = archetypes[index]
		var expected_id: String = Slice01Archetypes.REQUIRED_IDS[index]
		if archetype == null:
			return _fail("required archetype '%s' did not load" % expected_id)
		if archetype.archetype_id != expected_id:
			return _fail(
				"required archetype '%s' loaded as '%s'"
				% [expected_id, archetype.archetype_id]
			)
		var blueprint := BlueprintBaker.bake_from_placements(
			"validate_%s" % expected_id,
			[
				_make_placement(
					"subject",
					archetype,
					Vector3i.ZERO,
					0
				),
			]
		)
		if not BlueprintValidator.validate(blueprint).ok:
			return _fail(
				"committed archetype '%s' failed schema validation"
				% expected_id
			)
	return true


func _test_orientation_contract() -> bool:
	if OrientationUtil.ORIENTATION_COUNT != 24:
		return _fail("orientation count is not 24")
	if OrientationUtil.orientation_basis(0) != Basis.IDENTITY:
		return _fail("orientation 0 is not exact identity")

	var unique: Dictionary = {}
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		var basis: Basis = OrientationUtil.orientation_basis(index)
		var axes: Array[Vector3] = [basis.x, basis.y, basis.z]
		for axis: Vector3 in axes:
			if not _is_integer_unit_axis(axis):
				return _fail(
					"orientation %d has non-integer unit axis %s"
					% [index, axis]
				)
		if (
			not is_zero_approx(basis.x.dot(basis.y))
			or not is_zero_approx(basis.x.dot(basis.z))
			or not is_zero_approx(basis.y.dot(basis.z))
		):
			return _fail("orientation %d axes are not orthogonal" % index)
		if not is_equal_approx(basis.determinant(), 1.0):
			return _fail(
				"orientation %d determinant is %f"
				% [index, basis.determinant()]
			)
		var key := "%s|%s|%s" % [basis.x, basis.y, basis.z]
		if unique.has(key):
			return _fail("duplicate orientation basis at index %d" % index)
		unique[key] = true
	return true


func _test_face_rotation() -> bool:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		for face: OrientationUtil.Face in [
			OrientationUtil.Face.POS_X,
			OrientationUtil.Face.NEG_X,
			OrientationUtil.Face.POS_Y,
			OrientationUtil.Face.NEG_Y,
			OrientationUtil.Face.POS_Z,
			OrientationUtil.Face.NEG_Z,
		]:
			var expected: Vector3i = OrientationUtil.rotate_direction(
				OrientationUtil.face_to_vector(face),
				index
			)
			var rotated_face: OrientationUtil.Face = (
				OrientationUtil.rotate_face(face, index)
			)
			if OrientationUtil.face_to_vector(rotated_face) != expected:
				return _fail(
					"face rotation mismatch at orientation %d face %d"
					% [index, face]
				)
	if (
		OrientationUtil.rotate_face(OrientationUtil.Face.POS_X, 0)
		!= OrientationUtil.Face.POS_X
	):
		return _fail("identity orientation changes +X face")
	return true


func _test_multi_cell_rotation_and_colliders() -> bool:
	var beam: ElementArchetype = Slice01Archetypes.frame_beam()
	if beam.colliders.is_empty():
		return _fail("frame_beam has no collider")

	var origin := Vector3i(2, 0, -1)
	for orientation_index: int in range(OrientationUtil.ORIENTATION_COUNT):
		var cells: Array[Vector3i] = beam.get_occupied_cells(
			origin,
			orientation_index
		)
		if cells.size() != 4:
			return _fail("rotated frame_beam does not occupy four cells")
		for cell_index: int in range(1, cells.size()):
			var delta: Vector3i = cells[cell_index - 1] - cells[cell_index]
			if absi(delta.x) + absi(delta.y) + absi(delta.z) == 1:
				continue
			return _fail(
				"orientation %d beam cells are not adjacent"
				% orientation_index
			)
	return true


func _test_large_frame_fixture() -> bool:
	var large_frame: ElementArchetype = Slice01Archetypes.large_frame()
	if large_frame == null:
		return _fail("large_frame fixture is missing")
	if large_frame.footprint_cells.size() != 125:
		return _fail(
			"large_frame footprint has %d cells instead of 125"
			% large_frame.footprint_cells.size()
		)
	if (
		large_frame.colliders.size() != 1
		or not large_frame.colliders[0].size.is_equal_approx(
			Vector3(2.5, 2.5, 2.5)
		)
	):
		return _fail("large_frame collider is not a 2.5 m cube")
	var validation := _validate(
		"large_frame_fixture",
		[_make_placement(
			"large_frame_0",
			large_frame,
			Vector3i.ZERO,
			0
		)]
	)
	if not validation.ok:
		return _fail(
			"large_frame fixture rejected: %s"
			% ", ".join(validation.errors)
		)
	return true


func _test_marker_preview_matches_occupancy() -> bool:
	var marker := ElementMarker.new()
	marker.local_id = "preview"
	marker.archetype = Slice01Archetypes.frame_beam()
	var vertical_orientation := _find_orientation(
		Vector3i.RIGHT,
		Vector3i.UP
	)
	if vertical_orientation < 0:
		marker.free()
		return _fail("could not find +X to +Y orientation")
	marker.orientation_index = vertical_orientation
	var centers: Array[Vector3] = marker.preview_local_centers()
	var occupied: Array[Vector3i] = marker.archetype.get_occupied_cells(
		Vector3i.ZERO,
		vertical_orientation
	)
	if centers.size() != occupied.size():
		marker.free()
		return _fail("marker preview count differs from baked occupancy")
	for cell: Vector3i in occupied:
		if not centers.has(GridMetric.cell_center_meters(cell)):
			marker.free()
			return _fail("marker preview misses rotated cell %s" % cell)
	marker.free()
	return true


func _test_valid_connected_bake() -> bool:
	var baked: Dictionary = BlueprintBaker.validate_and_bake(
		"kernel_fixture_valid",
		_fixture_placements()
	)
	var validation: BlueprintValidationResult = baked["validation"]
	if not validation.ok:
		return _fail(
			"valid connected fixture rejected: %s"
			% ", ".join(validation.errors)
		)
	var blueprint: Blueprint = baked["blueprint"]
	var components: Array[Array] = (
		BlueprintConnectivity.connected_components(blueprint)
	)
	if components.size() != 1:
		return _fail("valid fixture has %d components" % components.size())
	var save_error: Error = BlueprintBaker.save_baked(blueprint)
	if save_error != OK:
		return _fail("valid fixture save failed with code %d" % save_error)
	return true


func _test_deterministic_local_id_ordering() -> bool:
	var shuffled: Array[BlueprintElementPlacement] = [
		_make_placement("c", Slice01Archetypes.frame(), Vector3i(2, 0, 0), 0),
		_make_placement("a", Slice01Archetypes.foundation(), Vector3i(0, 0, 0), 0),
		_make_placement("b", Slice01Archetypes.frame(), Vector3i(1, 0, 0), 0),
	]
	var first := BlueprintBaker.bake_from_placements(
		"ordering_fixture",
		shuffled
	)
	shuffled.reverse()
	var second := BlueprintBaker.bake_from_placements(
		"ordering_fixture",
		shuffled
	)
	if BlueprintBaker.fingerprint(first) != BlueprintBaker.fingerprint(second):
		return _fail("deterministic fingerprint mismatch")
	var ids: PackedStringArray = PackedStringArray()
	for placement: BlueprintElementPlacement in first.placements:
		ids.append(placement.local_id)
	if ids != PackedStringArray(["a", "b", "c"]):
		return _fail("sorted local_ids are %s" % [ids])
	for property: Dictionary in first.placements[0].get_property_list():
		if str(property.get("name", "")) == "element_id":
			return _fail("Blueprint placement still exposes runtime element_id")
	return true


func _test_overlap_and_local_id_diagnostics() -> bool:
	var overlap: BlueprintValidationResult = _validate(
		"overlap",
		[
			_make_placement(
				"left",
				Slice01Archetypes.frame(),
				Vector3i.ZERO,
				0
			),
			_make_placement(
				"right",
				Slice01Archetypes.frame(),
				Vector3i.ZERO,
				0
			),
		]
	)
	if overlap.ok or not _errors_contain(overlap, "cell overlap"):
		return _fail("overlap diagnostic missing")
	var duplicate_result: BlueprintValidationResult = _validate(
		"duplicate",
		[
			_make_placement(
				"dup",
				Slice01Archetypes.frame(),
				Vector3i.ZERO,
				0
			),
			_make_placement(
				"dup",
				Slice01Archetypes.frame(),
				Vector3i.RIGHT,
				0
			),
		]
	)
	if duplicate_result.ok or not _errors_contain(duplicate_result, "duplicate local_id"):
		return _fail("duplicate local_id diagnostic missing")
	var invalid_orientation: BlueprintValidationResult = _validate(
		"bad_orientation",
		[
			_make_placement(
				"bad",
				Slice01Archetypes.frame(),
				Vector3i.ZERO,
				99
			),
		]
	)
	if (
		invalid_orientation.ok
		or not _errors_contain(
			invalid_orientation,
			"invalid orientation_index"
		)
	):
		return _fail("invalid orientation diagnostic missing")
	return true


func _test_archetype_schema_diagnostics() -> bool:
	var bad: ElementArchetype = (
		Slice01Archetypes.cargo_store().duplicate(true) as ElementArchetype
	)
	bad.archetype_id = "bad_schema"
	bad.colliders = []
	var duplicate_requirement := BuildRequirement.new()
	duplicate_requirement.resource_id = "plate_metal"
	duplicate_requirement.amount = 0.0
	bad.build_requirements.append(duplicate_requirement)
	if bad.ports.is_empty():
		return _fail("schema fixture archetype has no ports")
	var duplicate_port: PortDefinition = bad.ports[0].duplicate(true)
	duplicate_port.local_cell = Vector3i(9, 0, 0)
	duplicate_port.compatibility_tags = PackedStringArray()
	bad.ports.append(duplicate_port)
	var result: BlueprintValidationResult = _validate(
		"bad_schema",
		[_make_placement("bad", bad, Vector3i.ZERO, 0)]
	)
	for expected: String in [
		"no collider pieces",
		"has no collider coverage",
		"duplicate port_id",
		"outside footprint",
		"no compatibility tags",
		"repeats build requirement",
		"amount must be positive",
	]:
		if not _errors_contain(result, expected):
			return _fail("schema diagnostic missing: %s" % expected)
	return true


func _test_connectivity_diagnostics() -> bool:
	var disconnected_placements: Array[BlueprintElementPlacement] = [
		_make_placement(
			"left",
			Slice01Archetypes.frame(),
			Vector3i.ZERO,
			0
		),
		_make_placement(
			"right",
			Slice01Archetypes.frame(),
			Vector3i(3, 0, 0),
			0
		),
	]
	var disconnected: BlueprintValidationResult = _validate(
		"disconnected",
		disconnected_placements
	)
	if (
		disconnected.ok
		or not _errors_contain(disconnected, "blueprint is disconnected")
	):
		return _fail("disconnected blueprint diagnostic missing")

	var allowed := BlueprintBaker.bake_from_placements(
		"allowed_disconnected",
		disconnected_placements
	)
	allowed.allow_disconnected = true
	if not BlueprintValidator.validate(allowed).ok:
		return _fail("allow_disconnected blueprint was rejected")

	return true


func _test_mount_pad_connectivity_policy() -> bool:
	var cargo_store: ElementArchetype = Slice01Archetypes.cargo_store()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var allow_baked: Blueprint = BlueprintBaker.bake_from_placements(
		"mount_pad_allow",
		[
			_make_placement("store", cargo_store, Vector3i.ZERO, 0),
			_make_placement("frame", frame, Vector3i(-1, 0, 1), 0),
		]
	)
	if not BlueprintValidator.validate(allow_baked).ok:
		return _fail("mount-pad-aligned blueprint rejected")
	if BlueprintConnectivity.connected_components(allow_baked).size() != 1:
		return _fail("mount-pad-aligned blueprint disconnected")

	var deny: BlueprintValidationResult = _validate(
		"mount_pad_deny",
		[
			_make_placement("store", cargo_store, Vector3i.ZERO, 0),
			_make_placement("frame", frame, Vector3i(0, 0, 3), 0),
		]
	)
	if deny.ok or not _errors_contain(deny, "disconnected"):
		return _fail("non-pad structural contact connected")

	var tagged_left: ElementArchetype = (
		Slice01Archetypes.frame().duplicate(true) as ElementArchetype
	)
	var tagged_right: ElementArchetype = (
		Slice01Archetypes.frame().duplicate(true) as ElementArchetype
	)
	for port: PortDefinition in tagged_right.ports:
		if port.kind == PortDefinition.Kind.MECHANICAL:
			port.compatibility_tags = PackedStringArray(["other_structure"])
	var full_surface: BlueprintValidationResult = _validate(
		"full_surface_tags_ignored",
		[
			_make_placement("left", tagged_left, Vector3i.ZERO, 0),
			_make_placement("right", tagged_right, Vector3i.RIGHT, 0),
		]
	)
	if not full_surface.ok:
		return _fail("FULL_SURFACE frames rejected despite tag mismatch")

	var beam: ElementArchetype = Slice01Archetypes.frame_beam()
	if GridSurfaceUtil.element_has_structural_surface(
		_preview_element(beam, Vector3i.ZERO, 0),
		"structural_1_0_0_px"
	):
		return _fail("internal multi-cell face exposed as structural surface")
	return true


func _preview_element(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> SimulationElement:
	var element := SimulationElement.new()
	element.archetype_id = archetype.archetype_id
	element.bind_archetype(archetype)
	element.origin_cell = origin_cell
	element.orientation_index = orientation_index
	return element


func _test_baked_resources() -> bool:
	for path: String in [BAKED_FIXTURE_PATH, BAKED_BASE_PATH]:
		if not ResourceLoader.exists(path):
			return _fail("baked resource missing at %s" % path)
		var loaded := load(path) as Blueprint
		if loaded == null:
			return _fail("failed to load baked resource %s" % path)
		var validation: BlueprintValidationResult = (
			BlueprintValidator.validate(loaded)
		)
		if not validation.ok:
			return _fail(
				"baked resource invalid: %s"
				% ", ".join(validation.errors)
			)
		if (
			BlueprintConnectivity.connected_components(loaded).size()
			!= 1
		):
			return _fail("baked resource is not one rigid assembly")
	return true


func _fixture_placements() -> Array[BlueprintElementPlacement]:
	return [
		_make_placement(
			"foundation_0",
			Slice01Archetypes.foundation(),
			Vector3i.ZERO,
			0
		),
		_make_placement(
			"frame_0",
			Slice01Archetypes.frame(),
			Vector3i(4, 0, 1),
			0
		),
		_make_placement(
			"beam_0",
			Slice01Archetypes.frame_beam(),
			Vector3i(5, 0, 1),
			0
		),
	]


func _make_placement(
	local_id: String,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> BlueprintElementPlacement:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = local_id
	placement.archetype = archetype
	placement.origin_cell = origin_cell
	placement.orientation_index = orientation_index
	return placement


func _validate(
	blueprint_id: String,
	placements: Array[BlueprintElementPlacement]
) -> BlueprintValidationResult:
	return BlueprintBaker.validate_and_bake(
		blueprint_id,
		placements
	)["validation"]


func _errors_contain(
	result: BlueprintValidationResult,
	needle: String
) -> bool:
	return ", ".join(result.errors).contains(needle)


func _find_orientation(
	from: Vector3i,
	to: Vector3i
) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.rotate_direction(from, index) == to:
			return index
	return -1


func _is_integer_unit_axis(axis: Vector3) -> bool:
	for component: float in [axis.x, axis.y, axis.z]:
		if (
			component != -1.0
			and component != 0.0
			and component != 1.0
		):
			return false
	return is_equal_approx(axis.length_squared(), 1.0)


func _fail(reason: String) -> bool:
	print("KERNEL-V0: FAIL %s" % reason)
	get_tree().quit(1)
	return false
