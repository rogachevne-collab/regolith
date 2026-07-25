extends Node3D
## BISECT ORACLE — deterministic, headless, no human interaction.
##
## Spawns the demo rover on a flat static floor (same compose path as
## test_wheel_body_stand.gd), measures physics-step cost PARKED (frozen)
## vs UNPARKED (unfrozen, brake off, idle — no drive/steer input), and
## prints a single parseable line + exits 0 (no regression) or 1 (regression).
##
## Usage: godot --headless res://scenes/bench_regression_oracle.tscn
## Threshold: unparked/parked TIME_PHYSICS_PROCESS ratio >= 3.0 => FAIL (bad).

const SETTLE_TICKS := 90
const SAMPLE_TICKS := 120

var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _assembly_id := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_spawn_floor()
	if not _build_rover():
		print("ORACLE: FAIL build_rover")
		get_tree().quit(2)
		return

	# Let it settle onto the floor before measuring anything.
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame

	var locomotion := _world.get_locomotion_controller(_assembly_id)
	var root := _projection.get_physics_body(_assembly_id) as RigidBody3D

	# PARKED
	locomotion.set_parking_brake(true)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	var parked := await _sample()

	# UNPARKED — activate + brake off, but no drive/steer command at all.
	locomotion.activate()
	locomotion.set_parking_brake(false)
	_projection.wake_assembly_bodies(_assembly_id)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	var unparked := await _sample()

	var ratio: float = float(unparked["phys_ms"]) / maxf(float(parked["phys_ms"]), 0.001)
	print(
		(
			"ORACLE parked_phys_ms=%.3f unparked_phys_ms=%.3f ratio=%.2f "
			+ "parked_active=%d unparked_active=%d "
			+ "parked_pairs=%d unparked_pairs=%d "
			+ "parked_islands=%d unparked_islands=%d "
			+ "root_frozen_parked=%s root_frozen_unparked=%s"
		) % [
			parked["phys_ms"], unparked["phys_ms"], ratio,
			parked["active"], unparked["active"],
			parked["pairs"], unparked["pairs"],
			parked["islands"], unparked["islands"],
			str(parked.get("frozen", "?")), str(unparked.get("frozen", "?")),
		]
	)
	if ratio >= 3.0:
		print("ORACLE: BAD (regression) ratio=%.2f" % ratio)
		get_tree().quit(1)
	else:
		print("ORACLE: GOOD ratio=%.2f" % ratio)
		get_tree().quit(0)


func _sample() -> Dictionary:
	var root := _projection.get_physics_body(_assembly_id) as RigidBody3D
	var phys_sum := 0.0
	for _i: int in range(SAMPLE_TICKS):
		await get_tree().physics_frame
		phys_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	return {
		"phys_ms": phys_sum / float(SAMPLE_TICKS),
		"active": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		"pairs": int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		"islands": int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		"frozen": root.freeze if root != null else null,
	}


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
	floor_body.global_position = Vector3(0.0, -7.0, 0.0)


func _build_rover() -> bool:
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

	var intent := RoverIntent.defaults()
	var composed := RoverComposer.compose(_world, intent)
	if not bool(composed.get("ok", false)):
		push_error("oracle compose failed: %s %s" % [
			composed.get("error", ""), composed.get("failures", []),
		])
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
	var body := _projection.get_physics_body(_assembly_id) as RigidBody3D
	if body != null:
		body.global_position = Vector3(0.0, -4.0, 0.0)
	return true
