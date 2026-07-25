extends Node3D
## Drop a composed rover into a huge loose-material heap and assert coupling.
##
## Not a kernel `test_*.tscn` (R2): this exercises RigidBody × GranularBody ×
## region mould on a flat floor. Headless PASS/FAIL; open in the editor to watch.
##
## Usage:
##   godot --headless res://scenes/bench_granular_rover_heap.tscn

const LABEL := "ROVER_HEAP"
const CELLS := 96
const CELL_M := 0.25
## Several overlapping dumps — a mountain the compact 6-wheel can bury in.
const HEAP_DUMPS: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(2.5, 0.0, 0.0),
	Vector3(-2.5, 0.0, 0.0),
	Vector3(0.0, 0.0, 2.5),
	Vector3(0.0, 0.0, -2.5),
	Vector3(1.5, 0.0, 1.5),
	Vector3(-1.5, 0.0, -1.5),
]
const HEAP_PER_DUMP_M3 := 10.0
const HEAP_RADIUS_CELLS := 10
const SETTLE_TICKS := 90
const FALL_TICKS := 180
const DRIVE_TICKS := 120
const FLOOR_TOP_Y := -6.0
## Region centre so local y=0 sits on the floor top (half-span = 12 m).
const REGION_CENTRE := Vector3(0.0, FLOOR_TOP_Y + float(CELLS) * CELL_M * 0.5, 0.0)
const MIN_SUBMERGED := 0.08
const MIN_HEAP_M3 := 20.0
## Chassis must not free-fall through the heap onto the floor slab.
const MIN_CHASSIS_Y := FLOOR_TOP_Y + 0.35

var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _assembly_id := 0
var _region: GranularVoxelRegion
var _view: GranularVoxelRegionView
var _sweep_debt := 0.0


func _ready() -> void:
	add_to_group(GranularVoxelWorld.GROUP_NAME)
	HeadlessTestHarness.arm_watchdog(self, LABEL, 90.0)
	call_deferred("_run")


func _process(delta: float) -> void:
	if _region == null:
		return
	_sweep_debt += delta * GranularVoxelWorld.SETTLE_HZ
	var sweeps := mini(int(_sweep_debt), 8)
	if sweeps <= 0:
		return
	_sweep_debt -= float(sweeps)
	for _i in sweeps:
		_region.field.step(GranularVoxelWorld.CELL_BUDGET_PER_SWEEP)
	if _view != null:
		_view.flush()


func _run() -> void:
	_spawn_floor()
	_build_heap()
	for _i in SETTLE_TICKS:
		await get_tree().physics_frame
	var heap_m3 := _region.field.total_volume_m3()
	if heap_m3 < MIN_HEAP_M3:
		_fail("heap too small after deposit: %.2f m3" % heap_m3)
		return
	var surface := _region.dust_column_probe(Vector3(0.0, FLOOR_TOP_Y + 8.0, 0.0))
	if surface.w <= 0.0:
		_fail("heap has no dust column at centre")
		return
	print("%s: heap_m3=%.2f surface_y=%.2f" % [LABEL, heap_m3, surface.y])

	if not _build_rover(surface.y + 3.5):
		_fail("compose/project rover")
		return

	var locomotion := _world.get_locomotion_controller(_assembly_id)
	locomotion.activate()
	locomotion.set_parking_brake(false)
	_projection.wake_assembly_bodies(_assembly_id)

	var max_sub := 0.0
	var min_y := INF
	for _i in FALL_TICKS:
		await get_tree().physics_frame
		max_sub = maxf(max_sub, _max_submerged())
		var root := _projection.get_physics_body(_assembly_id) as RigidBody3D
		if root != null:
			min_y = minf(min_y, root.global_position.y)

	print(
		"%s: after_fall max_submerged=%.3f min_chassis_y=%.2f"
		% [LABEL, max_sub, min_y]
	)
	if max_sub < MIN_SUBMERGED:
		_fail("never submerged in heap (max=%.3f)" % max_sub)
		return
	if min_y < MIN_CHASSIS_Y:
		_fail("fell through heap onto floor (min_y=%.2f)" % min_y)
		return

	locomotion.set_drive_command(1.0)
	for _i in DRIVE_TICKS:
		await get_tree().physics_frame
	locomotion.set_drive_command(0.0)

	var sub_drive := _max_submerged()
	var root := _projection.get_physics_body(_assembly_id) as RigidBody3D
	var y_drive := root.global_position.y if root != null else -999.0
	var speed := root.linear_velocity.length() if root != null else 0.0
	print(
		"%s: after_drive submerged=%.3f chassis_y=%.2f speed=%.2f heap_m3=%.2f"
		% [LABEL, sub_drive, y_drive, speed, _region.field.total_volume_m3()]
	)
	if sub_drive < MIN_SUBMERGED * 0.5:
		_fail("lost coupling while driving (submerged=%.3f)" % sub_drive)
		return
	if y_drive < MIN_CHASSIS_Y:
		_fail("chassis under floor after drive (y=%.2f)" % y_drive)
		return

	print("%s: PASS" % LABEL)
	if _is_headless():
		get_tree().quit(0)


func _fail(message: String) -> void:
	printerr("%s: FAIL %s" % [LABEL, message])
	print("%s: FAIL %s" % [LABEL, message])
	get_tree().quit(1)


func _is_headless() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	for arg in OS.get_cmdline_args():
		if arg == "--headless":
			return true
	return false


func _spawn_floor() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 2.0, 400.0)
	shape.shape = box
	floor_body.add_child(shape)
	add_child(floor_body)
	floor_body.global_position = Vector3(0.0, FLOOR_TOP_Y - 1.0, 0.0)


func _build_heap() -> void:
	_region = GranularVoxelRegion.create(
		REGION_CENTRE, Vector3.UP, null, null, CELLS, CELL_M
	)
	for x in CELLS:
		for z in CELLS:
			_region.field.set_solid(x, 0, z, true)
			_region.field.set_solid(x, 1, z, true)
	var aim_y := FLOOR_TOP_Y + 0.5
	for offset: Vector3 in HEAP_DUMPS:
		_region.deposit_landing_at(
			Vector3(offset.x, aim_y, offset.z),
			HEAP_PER_DUMP_M3,
			HEAP_RADIUS_CELLS
		)
	_view = GranularVoxelRegionView.new()
	add_child(_view)
	_view.setup(_region)


## --- GranularVoxelWorld surface GranularBody expects (group granular_world) ---

func has_material_near(world_aabb: AABB, margin_m: float = -1.0) -> bool:
	if _region == null or not _region.has_spoil():
		return false
	var margin := margin_m if margin_m >= 0.0 else CELL_M
	return world_aabb.grow(margin).intersects(_region.spoil_world_aabb())


func dust_probe(world_point: Vector3) -> Vector4:
	if _region == null or not _region.covers(world_point):
		return Vector4.ZERO
	return _region.dust_column_probe(world_point)


func dust_probe_many(points: PackedVector3Array, out: PackedVector4Array) -> void:
	var n := points.size()
	out.resize(n)
	for i in n:
		out[i] = Vector4.ZERO
	if n == 0 or _region == null:
		return
	var frame := _region.world_transform()
	var inv := frame.affine_inverse()
	var span := float(CELLS) * CELL_M
	for i in n:
		var local: Vector3 = inv * points[i]
		if (
			local.x < 0.0 or local.x > span
			or local.y < 0.0 or local.y > span
			or local.z < 0.0 or local.z > span
		):
			continue
		var probe := _region.dust_column_probe_local(frame, local)
		if probe.w > 0.0:
			out[i] = probe


func mould_at(
	points: PackedVector3Array,
	radius_m: float,
	share: float,
	keep_fill: float,
	body_radius_m: float,
	lead: Vector3
) -> float:
	if _region == null or points.is_empty() or radius_m <= 0.0 or share <= 0.0:
		return 0.0
	var gathered := 0.0
	var centre := Vector3.ZERO
	for point: Vector3 in points:
		centre += point
		if _region.covers(point):
			gathered += _region.take_sphere(point, radius_m, share, keep_fill)
	if gathered <= 0.0:
		return 0.0
	centre /= float(points.size())
	var place := centre + lead
	if _region.covers(place):
		_region.place_ring(place, gathered, body_radius_m)
	else:
		_region.place_ring(centre, gathered, body_radius_m)
	return gathered


func _build_rover(drop_y: float) -> bool:
	_world = SimulationWorld.new()
	_world.ensure_resource_store(PlayerIdentity.store_id("player"))
	for resource_id: String in [
		"plate_metal", "girder", "mechanism", "conduit",
		"plate_basalt", "sintered_basalt", "plate_alloy",
	]:
		_world.set_resource_amount(
			PlayerIdentity.store_id("player"), resource_id, 800.0
		)
	_projection = SimulationPhysicsProjection.new()
	add_child(_projection)
	_projection.bind_world(_world)

	var intent := RoverIntent.from_phrase(
		"компактный ровер на 6 колёс, короткий, низкий, минимальный декор"
	)
	var composed := RoverComposer.compose(_world, intent)
	if not bool(composed.get("ok", false)):
		push_error(
			"%s compose failed: %s %s"
			% [LABEL, composed.get("error", ""), composed.get("failures", [])]
		)
		return false
	_assembly_id = int(composed["assembly_id"])

	for pair: Dictionary in WheelSimulationService.discover_pairs(_world, _assembly_id):
		if WheelSimulationService.is_complete_pair(pair):
			var wheel_id := int(pair.get("wheel_element_id", 0))
			var power := _world.ensure_industry_element_runtime(wheel_id)
			power.machine_enabled = true
			power.powered = true

	var locomotion := _world.get_locomotion_controller(_assembly_id)
	locomotion.mark_released_from_anchor()
	locomotion.set_parking_brake(true)
	_projection.project_assembly_now(
		_assembly_id,
		_world.get_assembly_raw(_assembly_id).motion.duplicate_state()
	)
	_place_assembly(Vector3(0.0, drop_y, 0.0))
	return true


func _place_assembly(world_pos: Vector3) -> void:
	var root := _projection.get_physics_body(_assembly_id) as RigidBody3D
	if root == null:
		return
	var delta := world_pos - root.global_position
	root.global_position = world_pos
	root.linear_velocity = Vector3.ZERO
	root.angular_velocity = Vector3.ZERO
	for record: Dictionary in _projection.list_wheel_constraint_records(_assembly_id):
		for key: String in ["wheel_body", "strut_body"]:
			var body := record.get(key) as RigidBody3D
			if body == null:
				continue
			body.global_position += delta
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO


func _max_submerged() -> float:
	var best := 0.0
	var roots: Array[Node] = []
	var root := _projection.get_physics_body(_assembly_id)
	if root != null:
		roots.append(root)
	for record: Dictionary in _projection.list_wheel_constraint_records(_assembly_id):
		for key: String in ["wheel_body", "strut_body"]:
			var body: Node = record.get(key)
			if body != null and not roots.has(body):
				roots.append(body)
	for body in roots:
		for child in body.find_children("*", "GranularBody", true, false):
			best = maxf(best, float(child.get("_submerged")))
	return best
