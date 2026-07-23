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
		_test_wheel_tire_cylinder_drives_hub,
		_test_suspension_bakes_valid,
		_test_suspension_travel_stick_drives_bake,
		_test_wheel_needs_one_marker,
		_test_forward_axis_auto_perpendicular,
		_test_bake_saves_and_reloads,
		_test_big_cube_full_surface,
		_test_generate_mounts_per_side,
		_test_generate_mounts_per_cell,
		_test_battery_bakes_valid,
		_test_power_source_bakes_valid,
		_test_battery_needs_electric_port,
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


func _add_electric_marker(
	root: PartAuthoringRoot,
	role: MountPadMarker.PortRole,
	cell: Vector3i,
	face: OrientationUtil.Face
) -> void:
	var marker := MountPadMarker.new()
	marker.socket_kind = MountPadMarker.SocketKind.ELECTRIC_PORT
	marker.port_role = role
	root.add_child(marker)
	marker.position = _face_center(cell, face)


func _find_port(archetype: ElementArchetype, port_id: String) -> PortDefinition:
	for port: PortDefinition in archetype.ports:
		if port.port_id == port_id:
			return port
	return null


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


## Цилиндр шины задаёт хаб качения и radius/width; точка plug остаётся стыком.
func _test_wheel_tire_cylinder_drives_hub() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.WHEEL)
	root.part_id = "test_wheel_tire"
	root.wheel_radius_m = 0.4
	var plug := _face_center(Vector3i(0, 0, 0), OrientationUtil.Face.NEG_X)
	var plug_marker := MountPadMarker.new()
	plug_marker.socket_kind = MountPadMarker.SocketKind.WHEEL_PLUG
	plug_marker.snap_to_face = false
	root.add_child(plug_marker)
	plug_marker.position = plug
	var tire := WheelTireMarker.new()
	root.add_child(tire)
	tire.position = plug + Vector3(0.2, 0.0, 0.0)
	tire.radius_m = 0.55
	tire.width_m = 0.42
	var hub_authored := tire.position
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	if not errors.is_empty():
		root.free()
		return _fail("tire cylinder build errors: %s" % [errors])
	var definition := archetype.wheel_definition
	var hub := WheelBodyProjectionUtil.axle_point_local(archetype)
	var mate := WheelBodyProjectionUtil.plug_point_local(archetype)
	root.free()
	if definition == null or not definition.hub_local_authored:
		return _fail("tire cylinder must author hub_local")
	if not is_equal_approx(definition.radius_m, 0.55):
		return _fail("tire radius not baked: %f" % definition.radius_m)
	if not is_equal_approx(definition.width_m, 0.42):
		return _fail("tire width not baked: %f" % definition.width_m)
	if not hub.is_equal_approx(hub_authored):
		return _fail("hub must be tire centre, got %s" % hub)
	if not mate.is_equal_approx(plug):
		return _fail("plug mate must stay on tip, got %s" % mate)
	if hub.is_equal_approx(mate):
		return _fail("hub and plug must differ when cylinder is offset")
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


## Палка хода задаёт и точку гнезда (её низ), и suspension_travel_m (проекция
## на ось хода). Лишний маркер «гнездо колеса» при этом молча игнорируется, а
## не ломает бак вторым гнездом.
func _test_suspension_travel_stick_drives_bake() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.SUSPENSION)
	root.part_id = "test_susp_travel"
	root.size_cells = Vector3i(1, 2, 1)
	root.suspension_travel_m = 0.9  # инспекторное значение должно проиграть палке
	_add_marker(
		root,
		MountPadMarker.SocketKind.STRUCTURAL,
		Vector3i(0, 1, 0),
		OrientationUtil.Face.POS_X
	)
	_add_marker(
		root,
		MountPadMarker.SocketKind.WHEEL_SOCKET,
		Vector3i(0, 0, 0),
		OrientationUtil.Face.NEG_Z
	)
	var bottom := _face_center(Vector3i(0, 0, 0), OrientationUtil.Face.NEG_Y)
	var travel := SuspensionTravelMarker.new()
	root.add_child(travel)
	travel.position = bottom
	# Слегка косая палка: в бак должна уйти вертикальная составляющая (0.4),
	# а не её длина (~0.412).
	travel.top_offset = Vector3(0.1, 0.4, 0.0)

	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	if not errors.is_empty():
		root.free()
		return _fail("travel stick build errors: %s" % [errors])
	var definition := archetype.suspension_definition
	var susp_errors := definition.validate(archetype)
	var socket_pads: Array[StructuralMountPad] = []
	for pad: StructuralMountPad in archetype.structural_mount_pads:
		if pad.socket_tag == "wheel_socket":
			socket_pads.append(pad)
	var socket_count := socket_pads.size()
	var socket_pad: StructuralMountPad = (
		socket_pads[0] if socket_count == 1 else null
	)
	root.free()

	if not susp_errors.is_empty():
		return _fail("travel stick definition invalid: %s" % [susp_errors])
	if socket_count != 1:
		return _fail("travel stick should own the single socket, got %d" % socket_count)
	if not socket_pad.exact_point:
		return _fail("travel stick socket should be an exact point")
	if not socket_pad.local_position.is_equal_approx(bottom):
		return _fail(
			"socket should sit on the stick's low end, got %s" % socket_pad.local_position
		)
	if socket_pad.local_face != OrientationUtil.Face.NEG_Y:
		return _fail("socket face should follow the stick's low end (NEG_Y)")
	if not is_equal_approx(definition.suspension_travel_m, 0.4):
		return _fail(
			"travel should be the axis projection 0.4, got %f"
			% definition.suspension_travel_m
		)
	# Палка — физический предел стойки: пульт не должен предлагать игроку ход
	# длиннее, чем деталь вообще умеет.
	if not is_equal_approx(definition.max_travel_m, 0.4):
		return _fail(
			"max travel should be the stick itself, got %f"
			% definition.max_travel_m
		)
	if not is_equal_approx(
		definition.min_travel_m,
		PartAuthoringRoot.travel_tune_floor(0.4)
	):
		return _fail(
			"min travel should follow the stick, got %f" % definition.min_travel_m
		)
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


## The user's case: a 2.5 m cube = 5x5x5 cells. No markers, whole surface
## bolts on, and exactly ONE collider (not 125).
func _test_big_cube_full_surface() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.PLAIN)
	root.part_id = "test_cube"
	root.size_cells = Vector3i(5, 5, 5)
	root.mount_generation = PartAuthoringRoot.MountGeneration.FULL_SURFACE
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	var generated := root.generate_mounts()
	var validation := BlueprintValidator.validate_archetype(archetype)
	root.free()
	if not errors.is_empty():
		return _fail("cube build errors: %s" % [errors])
	if generated != 0:
		return _fail("full-surface mode should need 0 markers, made %d" % generated)
	if archetype.footprint_cells.size() != 125:
		return _fail("2.5 m cube should be 125 cells, got %d" % archetype.footprint_cells.size())
	if archetype.colliders.size() != 1:
		return _fail("cube should get 1 box collider, got %d" % archetype.colliders.size())
	if not validation.ok:
		return _fail("cube archetype invalid: %s" % [validation.errors])
	if (
		archetype.structural_surface_policy
		!= ElementArchetype.StructuralSurfacePolicy.FULL_SURFACE
	):
		return _fail("cube should use FULL_SURFACE policy")
	return true


func _test_generate_mounts_per_side() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.SUSPENSION)
	root.part_id = "test_gen_side"
	root.size_cells = Vector3i(1, 2, 1)
	root.mount_generation = PartAuthoringRoot.MountGeneration.PER_SIDE
	var generated := root.generate_mounts()
	var markers := root.collect_pad_markers()
	# The suspension guess must put a wheel socket on the bottom face.
	var sockets := 0
	for marker: MountPadMarker in markers:
		if marker.socket_kind == MountPadMarker.SocketKind.WHEEL_SOCKET:
			sockets += 1
	root.free()
	if generated != 6:
		return _fail("per-side should make 6 markers, got %d" % generated)
	if markers.size() != 6:
		return _fail("expected 6 marker children, got %d" % markers.size())
	if sockets != 1:
		return _fail("suspension guess should tag 1 wheel socket, got %d" % sockets)
	return true


func _test_generate_mounts_per_cell() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.PLAIN)
	root.part_id = "test_gen_cell"
	root.size_cells = Vector3i(2, 1, 1)
	root.mount_generation = PartAuthoringRoot.MountGeneration.PER_CELL
	var generated := root.generate_mounts()
	root.free()
	# 2x1x1 box: 10 external cell faces (2 cells x 6 faces - 2 shared).
	if generated != 10:
		return _fail("per-cell on 2x1x1 should make 10 markers, got %d" % generated)
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


func _test_battery_bakes_valid() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.BATTERY)
	root.part_id = "test_battery"
	root.size_cells = Vector3i(2, 3, 2)
	root.battery_capacity_kwh = 6.0
	root.battery_charge_w = 300.0
	root.battery_discharge_w = 400.0
	_add_electric_marker(
		root,
		MountPadMarker.PortRole.IN,
		Vector3i(0, 1, 0),
		OrientationUtil.Face.NEG_Z
	)
	_add_electric_marker(
		root,
		MountPadMarker.PortRole.OUT,
		Vector3i(0, 1, 1),
		OrientationUtil.Face.POS_Z
	)
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	if not errors.is_empty():
		root.free()
		return _fail("battery build errors: %s" % [errors])
	if archetype == null:
		root.free()
		return _fail("battery build returned null")
	var validation := BlueprintValidator.validate_archetype(archetype)
	var battery_errors := archetype.battery_definition.validate(archetype)
	var power_in := _find_port(archetype, "power_in")
	var power_out := _find_port(archetype, "power_out")
	root.free()
	if not validation.ok:
		return _fail("battery archetype invalid: %s" % [validation.errors])
	if not battery_errors.is_empty():
		return _fail("battery definition invalid: %s" % [battery_errors])
	if not archetype.roles.has("Tank"):
		return _fail("battery should have role 'Tank', got %s" % [archetype.roles])
	if power_in == null or power_in.kind != PortDefinition.Kind.ELECTRIC:
		return _fail("battery missing electric power_in port")
	if power_out == null or power_out.kind != PortDefinition.Kind.ELECTRIC:
		return _fail("battery missing electric power_out port")
	if not is_equal_approx(archetype.battery_definition.capacity_kwh, 6.0):
		return _fail("battery capacity not carried through")
	return true


func _test_power_source_bakes_valid() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.POWER_SOURCE)
	root.part_id = "test_power_source"
	root.size_cells = Vector3i(3, 3, 3)
	root.source_output_w = 1500.0
	_add_electric_marker(
		root,
		MountPadMarker.PortRole.OUT,
		Vector3i(1, 1, 2),
		OrientationUtil.Face.POS_Z
	)
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	if not errors.is_empty():
		root.free()
		return _fail("power source build errors: %s" % [errors])
	var validation := BlueprintValidator.validate_archetype(archetype)
	var source_errors := archetype.power_source_definition.validate(archetype)
	var power_out := _find_port(archetype, "power_out")
	root.free()
	if not validation.ok:
		return _fail("power source archetype invalid: %s" % [validation.errors])
	if not source_errors.is_empty():
		return _fail("power source definition invalid: %s" % [source_errors])
	if not archetype.roles.has("Source"):
		return _fail("power source should have role 'Source', got %s" % [archetype.roles])
	if power_out == null or power_out.kind != PortDefinition.Kind.ELECTRIC:
		return _fail("power source missing electric power_out port")
	if not is_equal_approx(archetype.power_source_definition.output_w, 1500.0):
		return _fail("power source output_w not carried through")
	return true


func _test_battery_needs_electric_port() -> bool:
	var root := _make_root(PartAuthoringRoot.PartKind.BATTERY)
	root.part_id = "test_battery_no_port"
	root.size_cells = Vector3i(2, 3, 2)
	var errors: Array[String] = []
	var archetype := root._build_archetype(errors)
	var battery_errors := (
		archetype.battery_definition.validate(archetype)
		if archetype != null and archetype.battery_definition != null
		else ["no battery_definition built"]
	)
	root.free()
	if battery_errors.is_empty():
		return _fail("battery with no electric marker should fail validation")
	return true
