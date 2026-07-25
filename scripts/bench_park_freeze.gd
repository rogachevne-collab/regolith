extends "res://scripts/bootstrap.gd"

## Headless bench: cost of an UNFROZEN (unparked) rover assembly vs a FROZEN
## (parked) one, isolating whether a seated player adds extra cost on top of
## the freeze/unfreeze transition itself. Reproduces the corrected repro:
## "FPS 190 -> 30 as soon as the vehicle is unparked, even standing still and
## even with nobody driving; re-engaging the parking brake restores 190
## immediately" (see docs/_verify/COOP-PERF-PLAYBOOK.md).
##
## Runs on a small Ø5 km test sphere (same VoxelLodTerrain/Clipbox config as
## the real planetoid, just cheap to generate) with the SAME 12-wheel demo
## rover phrase bootstrap.gd spawns in the real game by default.
##
## Run: godot --headless --path Y:\regolith res://scenes/bench_park_freeze.tscn

const TEST_DIAMETER_M := 5000.0
const TEST_STREAM_LABEL := "bench_park_freeze"
const TEST_LOD_COUNT := 8
const SETTLE_WAIT_S := 6.0
const PHASE_S := 5.0
const FREEZE_WAIT_S := 3.0

var _rover_assembly_id := 0
var _rover_spawned := false
var _results: Array[String] = []


func _enter_tree() -> void:
	MoonGeometry.set_test_diameter(TEST_DIAMETER_M)
	MoonTerrainParams.set_test_stream_label(TEST_STREAM_LABEL)


func _exit_tree() -> void:
	MoonGeometry.clear_test_diameter()
	MoonTerrainParams.clear_test_stream_label()


func _ready() -> void:
	use_native_sdf = false
	use_baked_heightmap = false
	height_amp_m = 0.0
	persist_digs = false
	spawn_demo_hopper = false
	spawn_lamp_poles = false
	debug_overlay = false
	super._ready()
	_configure_test_lod()
	call_deferred("_drive_bench")


func _make_planet_generator() -> VoxelGenerator:
	_generator_is_native = false
	return MoonSphereGeneratorFactory.create_play_fallback(MoonGeometry.radius_voxels())


func _configure_test_lod() -> void:
	if not (_terrain is VoxelLodTerrain):
		return
	var lod := _terrain as VoxelLodTerrain
	lod.lod_count = TEST_LOD_COUNT
	lod.normalmap_enabled = false


func _drive_bench() -> void:
	await _wait_until(func() -> bool: return is_world_ready(), 60.0)
	await _wait_until(func() -> bool: return _find_rover_assembly_id() > 0, 30.0)
	_rover_assembly_id = _find_rover_assembly_id()
	if _rover_assembly_id <= 0:
		print("BENCH_FAIL no rover assembly found")
		get_tree().quit(1)
		return
	print("BENCH_START rover_assembly_id=%d" % _rover_assembly_id)

	# Let the freshly-spawned rover auto-settle and auto-freeze under its own
	# default parking brake (matches production: spawn_on_terrain leaves
	# motion.frozen=false, _update_parking_freeze freezes it after
	# PARK_FREEZE_SETTLE_FRAMES quiet ticks).
	await _wait_seconds(SETTLE_WAIT_S)
	await _wait_until(func() -> bool: return _rover_is_frozen(), 20.0)
	print("BENCH_SETTLE frozen=%s" % str(_rover_is_frozen()))
	await _sample_phase("A_parked_no_seat")

	# B: unpark (disengage brake) with NOBODY seated.
	var locomotion := _session.world.get_locomotion_controller(_rover_assembly_id)
	locomotion.set_parking_brake(false)
	_session.projection.wake_assembly_bodies(_rover_assembly_id)
	await _sample_phase("B_unparked_no_seat")

	# Re-park, let it re-freeze, confirm return to baseline before the seated leg.
	locomotion.set_parking_brake(true)
	await _wait_until(func() -> bool: return _rover_is_frozen(), 20.0)
	print("BENCH_REPARK frozen=%s" % str(_rover_is_frozen()))
	await _sample_phase("C_reparked_no_seat")

	# D: seat the local player as driver (real seat path), still parked.
	var element_id := _find_cockpit_element_id(_rover_assembly_id)
	if element_id <= 0:
		print("BENCH_FAIL no cockpit element found")
		get_tree().quit(1)
		return
	var gateway: Node = get_node_or_null("WorldCommandGateway")
	var seat_result: Dictionary = gateway.call(
		"_enter_rover_seat", _player, element_id, _rover_assembly_id, true, false
	)
	print("BENCH_SEAT result=%s" % str(seat_result))
	await _wait_seconds(1.0)
	await _sample_phase("D_seated_parked")

	# E: unpark while seated (nobody touches drive/steer — pure stationary cost).
	locomotion.set_parking_brake(false)
	_session.projection.wake_assembly_bodies(_rover_assembly_id)
	await _sample_phase("E_seated_unparked")

	# F: re-park while seated — expect an immediate return to baseline.
	locomotion.set_parking_brake(true)
	await _wait_until(func() -> bool: return _rover_is_frozen(), 20.0)
	print("BENCH_REPARK2 frozen=%s" % str(_rover_is_frozen()))
	await _sample_phase("F_seated_reparked")

	# G: ACTUALLY DRIVING — full throttle, wheels turning, chassis moving.
	# The A-F legs above are all stationary; the acceptance bar is the moving
	# rover, not the idle-but-unfrozen one (an awake rover has to be cheap
	# whether or not anything on it is spinning).
	locomotion.set_parking_brake(false)
	_session.projection.wake_assembly_bodies(_rover_assembly_id)
	locomotion.set_drive_command(1.0)
	await _wait_seconds(2.0)  # let it actually get moving before sampling
	await _sample_phase("G_seated_driving")
	locomotion.set_drive_command(0.0)

	for line: String in _results:
		print(line)
	get_tree().quit(0)


func _rover_is_frozen() -> bool:
	if _rover_assembly_id <= 0:
		return false
	var body := _session.projection.get_physics_body(_rover_assembly_id)
	return body is RigidBody3D and (body as RigidBody3D).freeze


func _find_rover_assembly_id() -> int:
	if _session == null or _session.world == null:
		return 0
	for assembly: SimulationAssembly in _session.world.list_assemblies():
		if assembly.tombstoned:
			continue
		if WheelSimulationService.is_locomotive_assembly(_session.world, assembly.assembly_id):
			return assembly.assembly_id
	return 0


func _find_cockpit_element_id(assembly_id: int) -> int:
	for element: SimulationElement in _session.world.list_elements():
		if element.assembly_id != assembly_id:
			continue
		if element.archetype_id == "cockpit":
			return element.element_id
	return 0


func _wait_until(condition: Callable, timeout_s: float) -> void:
	var deadline_ms := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not bool(condition.call()):
		if Time.get_ticks_msec() >= deadline_ms:
			return
		await get_tree().process_frame


func _wait_seconds(seconds: float) -> void:
	var deadline_ms := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_ms:
		await get_tree().process_frame


func _sample_phase(label: String) -> void:
	var fps: Array[float] = []
	var process_ms: Array[float] = []
	var physics_ms: Array[float] = []
	var active_objects: Array[int] = []
	var collision_pairs: Array[int] = []
	var island_count: Array[int] = []
	# Script-vs-engine split (PERF-COOP-REGRESS): TIME_PHYSICS_PROCESS is
	# PhysicsServer3D::sync/flush_queries + every node's _physics_process()
	# (ours included) + PhysicsServer3D::step() in ONE number (main/main.cpp
	# Main::iteration) — read our own tick timers to pull them apart.
	var proj_total_us: Array[int] = []
	var wheel_us: Array[int] = []
	var motion_sync_us: Array[int] = []
	var rope_us: Array[int] = []
	var sess_total_us: Array[int] = []
	var industry_us: Array[int] = []
	var native_gap_us: Array[int] = []

	var last_seq := -1
	var deadline_ms := Time.get_ticks_msec() + int(PHASE_S * 1000.0)
	while Time.get_ticks_msec() < deadline_ms:
		fps.append(Performance.get_monitor(Performance.TIME_FPS))
		process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		active_objects.append(int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)))
		collision_pairs.append(int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)))
		island_count.append(int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)))
		var proj_us: Dictionary = _session.projection.get_last_tick_breakdown_us()
		var sess_us: Dictionary = _session.get_last_tick_breakdown_us()
		# Dedupe: only count each physics tick once, not once per render poll
		# (render FPS can be several x physics Hz — see tick_seq doc comment).
		var seq: int = int(proj_us.get("tick_seq", -1))
		if seq != last_seq and seq >= 0:
			last_seq = seq
			proj_total_us.append(int(proj_us.get("total", 0)))
			wheel_us.append(int(proj_us.get("wheel_bodies_per_wheel", 0)))
			motion_sync_us.append(int(proj_us.get("motion_sync", 0)))
			rope_us.append(int(proj_us.get("cable", 0)))
			sess_total_us.append(int(sess_us.get("total", 0)))
			industry_us.append(int(sess_us.get("industry_tick", 0)))
			var gap: int = int(proj_us.get("native_gap_since_prev_tick", -1))
			if gap >= 0:
				native_gap_us.append(gap)
		await get_tree().process_frame

	var body := _session.projection.get_physics_body(_rover_assembly_id)
	var frozen := (body is RigidBody3D) and (body as RigidBody3D).freeze
	var avg_phys_ms := _avgf(physics_ms)
	var avg_script_ms := (_avgi(proj_total_us) + _avgi(sess_total_us)) / 1000.0
	var avg_native_gap_ms := _avgi(native_gap_us) / 1000.0
	_results.append(
		(
			"BENCH_RESULT %s fps_avg=%.1f fps_min=%.1f process_ms_avg=%.3f "
			+ "physics_ms_avg=%.3f(STALE:1Hz-max-hold,see-note) physics_ms_max=%.3f "
			+ "active_obj_avg=%.1f collision_pairs_avg=%.1f island_avg=%.1f frozen=%s"
		) % [
			label,
			_avgf(fps), _minf(fps),
			_avgf(process_ms),
			avg_phys_ms, _maxf(physics_ms),
			_avgi(active_objects),
			_avgi(collision_pairs),
			_avgi(island_count),
			str(frozen),
		]
	)
	# Performance.TIME_PHYSICS_PROCESS updates once/second to that second's
	# WORST tick and holds it (main/main.cpp Main::iteration, confirmed in
	# engine source) — not usable as a per-tick average. native_gap_ms below
	# is measured directly with Time.get_ticks_usec() and IS a true per-tick
	# average: wall time from "our script done" to "our script starts next
	# tick", which per the physics loop order is nav + PhysicsServer3D::step
	# (native Jolt) + message_queue/iteration_end + next tick's sync —
	# i.e. everything outside our own GDScript.
	_results.append(
		(
			"BENCH_SPLIT %s script_ms=%.3f native_gap_ms=%.3f (tick_total≈%.3f) "
			+ "[wheel=%.3f motion_sync=%.3f cable=%.3f industry=%.3f] n_ticks=%d"
		) % [
			label,
			avg_script_ms,
			avg_native_gap_ms,
			avg_script_ms + avg_native_gap_ms,
			_avgi(wheel_us) / 1000.0,
			_avgi(motion_sync_us) / 1000.0,
			_avgi(rope_us) / 1000.0,
			_avgi(industry_us) / 1000.0,
			proj_total_us.size(),
		]
	)
	_log_sleep_state(label)


## PHYSICS_3D_ACTIVE_OBJECTS/COLLISION_PAIRS/ISLAND_COUNT are Jolt no-ops
## (Godot docs: "Only supported when using GodotPhysics3D. This parameter is
## ignored when using Jolt Physics" — confirmed in engine source,
## JoltPhysicsServer3D::get_process_info always `return 0`). Read
## RigidBody3D.sleeping directly on the chassis + every wheel body instead —
## that is the only way to see Jolt's actual sleep state with this backend.
func _log_sleep_state(label: String) -> void:
	var root := _session.projection.get_physics_body(_rover_assembly_id) as RigidBody3D
	if root == null:
		return
	var root_speed := root.linear_velocity.length()
	var root_ang := root.angular_velocity.length()
	var wheel_count := 0
	var wheel_sleeping_count := 0
	var wheel_speed_max := 0.0
	for record: Dictionary in _session.projection.list_wheel_constraint_records(_rover_assembly_id):
		var wheel_body := record.get("wheel_body") as RigidBody3D
		if wheel_body == null:
			continue
		wheel_count += 1
		if wheel_body.sleeping:
			wheel_sleeping_count += 1
		wheel_speed_max = maxf(wheel_speed_max, wheel_body.angular_velocity.length())
	print(
		(
			"BENCH_SLEEP %s root_sleeping=%s root_can_sleep=%s root_lin_v=%.4f "
			+ "root_ang_v=%.4f wheels=%d wheels_sleeping=%d wheel_ang_v_max=%.4f"
		) % [
			label,
			str(root.sleeping), str(root.can_sleep),
			root_speed, root_ang,
			wheel_count, wheel_sleeping_count, wheel_speed_max,
		]
	)


func _avgf(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


func _minf(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var m: float = values[0]
	for v in values:
		m = minf(m, v)
	return m


func _maxf(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var m: float = values[0]
	for v in values:
		m = maxf(m, v)
	return m


func _avgi(values: Array[int]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0
	for v in values:
		total += v
	return float(total) / float(values.size())
