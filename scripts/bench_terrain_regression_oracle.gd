extends Node3D
## BISECT ORACLE (real terrain) — deterministic, headless, no human interaction.
##
## Boots the real game scene (main.tscn / bootstrap.gd), waits for world_ready
## (which auto-spawns the demo rover on real VoxelLodTerrain, same as live
## play), then measures physics-step cost PARKED (frozen) vs UNPARKED
## (unfrozen, brake off, idle — no drive/steer input) on that exact assembly.
##
## Usage: godot --headless res://scenes/bench_terrain_regression_oracle.tscn
## Prints: ORACLE-TERRAIN ... and exits 0 (no regression) / 1 (regression) /
## 2 (setup failed — e.g. no demo rover found).

const MainScene := preload("res://scenes/main.tscn")
const SETTLE_TICKS := 90
const SAMPLE_TICKS := 120
const READY_TIMEOUT_MS := 120000

var _bootstrap: Node3D
var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _assembly_id := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_bootstrap = MainScene.instantiate()
	add_child(_bootstrap)

	var deadline := Time.get_ticks_msec() + READY_TIMEOUT_MS
	while not bool(_bootstrap.call("is_world_ready")):
		await get_tree().process_frame
		if Time.get_ticks_msec() > deadline:
			print("ORACLE-TERRAIN: FAIL world never became ready")
			get_tree().quit(2)
			return

	var session := _bootstrap.get_node("SimulationSession")
	_world = session.world
	_projection = session.projection

	if not _find_demo_rover():
		print("ORACLE-TERRAIN: FAIL no demo rover assembly found")
		get_tree().quit(2)
		return

	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame

	var locomotion := _world.get_locomotion_controller(_assembly_id)

	locomotion.set_parking_brake(true)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	var parked := await _sample()

	locomotion.activate()
	locomotion.set_parking_brake(false)
	_projection.wake_assembly_bodies(_assembly_id)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	var unparked := await _sample()

	var ratio: float = float(unparked["phys_ms"]) / maxf(float(parked["phys_ms"]), 0.001)
	print(
		(
			"ORACLE-TERRAIN parked_phys_ms=%.3f unparked_phys_ms=%.3f ratio=%.2f "
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
		print("ORACLE-TERRAIN: BAD (regression) ratio=%.2f" % ratio)
		get_tree().quit(1)
	else:
		print("ORACLE-TERRAIN: GOOD ratio=%.2f" % ratio)
		get_tree().quit(0)


func _find_demo_rover() -> bool:
	for assembly: SimulationAssembly in _world.list_assemblies():
		if assembly.tombstoned:
			continue
		var locomotion := _world.get_locomotion_controller(assembly.assembly_id)
		if locomotion != null:
			_assembly_id = assembly.assembly_id
			return true
	return false


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
