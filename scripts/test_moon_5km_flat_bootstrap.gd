extends "res://scripts/bootstrap.gd"

## Test yard: Ø5 km smooth sphere, radial gravity, piston debug overlay.
## Run: ./run.sh res://scenes/test_moon_5km_flat.tscn

const TEST_DIAMETER_M := 5000.0
const TEST_STREAM_LABEL := "test_5km_flat_sphere"
## Coarsest block at lod 9 = 4096 > bounds half ~3125 at scale 1.0; lod 8 = 2048.
const TEST_LOD_COUNT := 8
const _PistonDebug := preload(
	"res://scripts/debug/piston_debug_instrumentation.gd"
)

@export var spawn_demo_piston_rig := true
@export var demo_piston_phrase := "буровой манипулятор с подачей и запястьем"
@export var piston_debug_enabled := true
## Self-driving regression: extend the rig piston, weld a frame onto the base
## while extended, then report how far the piston was disturbed (log file).
@export var auto_weld_regression := true

var _piston_rig_spawned := false
var _piston_debug: Node
var _rig_assembly_id := 0
var _weld_test_count := 0
var _regression_phase := 0
var _regression_timer := 0.0
var _regression_ext_before := 0.0
var _regression_max_dev := 0.0
var _regression_max_v := 0.0
var _weld_last_element_id := 0


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
	enable_boulder_instancer = false
	persist_digs = false
	spawn_demo_rover = false
	spawn_demo_hopper = false
	debug_overlay = true
	super._ready()
	_configure_test_gravity_area()
	_configure_test_lod()
	_attach_piston_debug()


func _process(delta: float) -> void:
	super._process(delta)
	if spawn_demo_piston_rig and is_world_ready() and not _piston_rig_spawned:
		_piston_rig_spawned = true
		call_deferred("_spawn_demo_piston_rig")
	_tick_weld_regression(delta)


func _rig_piston_joint() -> SimulationJoint:
	if _session == null or _rig_assembly_id <= 0:
		return null
	for joint: SimulationJoint in _session.world.list_joints():
		if (
			joint.assembly_id == _rig_assembly_id
			and joint.kind == SimulationJoint.Kind.PISTON
		):
			return joint
	return null


func _tick_weld_regression(delta: float) -> void:
	if not auto_weld_regression or _rig_assembly_id <= 0:
		return
	var joint := _rig_piston_joint()
	if joint == null or joint.motor == null:
		return
	match _regression_phase:
		0:
			var command := SetActuatorTargetCommand.new()
			command.joint_id = joint.joint_id
			command.mode = SimulationMotorState.ControlMode.POSITION
			command.target_position_m = 1.5
			command.speed_limit_mps = -1.0
			command.enabled = true
			var result := _session.world.apply_set_actuator_target(command)
			print(
				"TestYard REGRESSION: extend to 1.5 -> %s"
				% str(result.get("reason", ""))
			)
			_regression_phase = 1
		1:
			if joint.motor.observed_position_m >= 1.45:
				_regression_phase = 2
				_regression_timer = 0.0
		2:
			_regression_timer += delta
			if _regression_timer >= 1.5:
				_regression_ext_before = joint.motor.observed_position_m
				_regression_max_dev = 0.0
				_regression_max_v = 0.0
				_weld_test_frame_on_rig()
				_regression_phase = 3
				_regression_timer = 0.0
		3:
			_regression_timer += delta
			_regression_max_dev = maxf(
				_regression_max_dev,
				absf(
					joint.motor.observed_position_m - _regression_ext_before
				)
			)
			_regression_max_v = maxf(
				_regression_max_v,
				absf(joint.motor.observed_velocity_mps)
			)
			if _regression_timer >= 2.0:
				print(
					"TestYard REGRESSION weld: ext_before=%.3f max_dev=%.4f max_v=%.4f -> %s"
					% [
						_regression_ext_before,
						_regression_max_dev,
						_regression_max_v,
						(
							"PASS"
							if _regression_max_dev < 0.03
							and _regression_max_v < 0.1
							else "FAIL"
						),
					]
				)
				_regression_phase = 4
				_regression_timer = 0.0
		4:
			# Dismantle the welded frame: forces a FULL reprojection while the
			# piston is extended — must reseed from live poses, not snap home.
			var dismantle := DismantleElementCommand.new()
			dismantle.element_id = _weld_last_element_id
			dismantle.expected_assembly_revision = (
				_session.world.get_assembly_raw(_rig_assembly_id)
				.topology_revision
			)
			dismantle.store_id = PlayerIdentity.store_id("player")
			var dismantle_result := (
				_session.world.apply_structural_command_now(dismantle)
			)
			print(
				"TestYard REGRESSION: dismantle e=%d -> %s"
				% [_weld_last_element_id, dismantle_result.reason]
			)
			_regression_ext_before = joint.motor.observed_position_m
			_regression_max_dev = 0.0
			_regression_max_v = 0.0
			_regression_phase = 5
			_regression_timer = 0.0
		5:
			_regression_timer += delta
			_regression_max_dev = maxf(
				_regression_max_dev,
				absf(
					joint.motor.observed_position_m - _regression_ext_before
				)
			)
			_regression_max_v = maxf(
				_regression_max_v,
				absf(joint.motor.observed_velocity_mps)
			)
			if _regression_timer >= 2.0:
				print(
					"TestYard REGRESSION reproject: ext_before=%.3f max_dev=%.4f max_v=%.4f -> %s"
					% [
						_regression_ext_before,
						_regression_max_dev,
						_regression_max_v,
						(
							"PASS"
							if _regression_max_dev < 0.05
							and _regression_max_v < 0.15
							else "FAIL"
						),
					]
				)
				_regression_phase = 6


func _make_planet_generator() -> VoxelGenerator:
	_generator_is_native = false
	print(
		"TestMoon5kmFlat: plain SDF sphere R=%.0f m"
		% MoonGeometry.active_surface_radius_m()
	)
	return MoonSphereGeneratorFactory.create_play_fallback(
		MoonGeometry.radius_voxels()
	)


func _configure_test_gravity_area() -> void:
	var shape_node := get_node_or_null(
		"MoonGravityArea/CollisionShape3D"
	) as CollisionShape3D
	if shape_node == null or not shape_node.shape is SphereShape3D:
		return
	(shape_node.shape as SphereShape3D).radius = MoonGeometry.gravity_area_radius_m()


func _configure_boulder_instancer() -> void:
	if _boulder_instancer != null:
		_boulder_instancer.queue_free()
		_boulder_instancer = null


func _configure_test_lod() -> void:
	if not (_terrain is VoxelLodTerrain):
		return
	var lod := _terrain as VoxelLodTerrain
	lod.lod_count = TEST_LOD_COUNT
	lod.normalmap_enabled = false


func _attach_piston_debug() -> void:
	if not piston_debug_enabled:
		return
	_piston_debug = _PistonDebug.new()
	_piston_debug.name = "PistonDebugInstrumentation"
	_piston_debug.session_path = NodePath("../SimulationSession")
	_piston_debug.player_path = NodePath("../Player")
	_piston_debug.enabled = true
	_piston_debug.overlay_enabled = true
	_piston_debug.log_status_changes = true
	add_child(_piston_debug)


func _spawn_demo_piston_rig() -> void:
	if _session == null or _player == null:
		return
	var offset := _player.global_transform.basis.x * 18.0
	var spawn_pos := _player.global_position + offset
	var tool := TerrainCompat.get_voxel_tool(_terrain)
	var space_state := get_world_3d().direct_space_state
	var result := MachineComposer.spawn_on_terrain_from_phrase(
		_session,
		spawn_pos,
		demo_piston_phrase,
		PlayerIdentity.store_id("player"),
		_terrain,
		tool,
		space_state
	)
	if not bool(result.get("ok", false)):
		push_warning(
			"TestMoon5kmFlat: piston rig spawn failed: %s"
			% str(result.get("error", result))
		)
		return
	_rig_assembly_id = int(result.get("assembly_id", 0))
	if _piston_debug != null:
		_piston_debug.focus_assembly_id = _rig_assembly_id
	print(
		"TestMoon5kmFlat: piston rig assembly_id=%d"
		% _rig_assembly_id
	)


## F9 — weld a frame onto the rig base (reprojection regression test: an
## extended/sagged piston elsewhere in the assembly must not snap or kick).
func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or key.keycode != KEY_F9:
		return
	_weld_test_frame_on_rig()


func _weld_test_frame_on_rig() -> void:
	if _session == null or _rig_assembly_id <= 0:
		return
	var world: SimulationWorld = _session.world
	var assembly := world.get_assembly_raw(_rig_assembly_id)
	if assembly == null:
		print("TestYard: rig assembly missing")
		return
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 500.0)
	# Successive presses stack frames sideways off the mast base.
	var candidates: Array[Vector3i] = [
		Vector3i(0, 1 + _weld_test_count, 2),
		Vector3i(0, 1 + _weld_test_count, -2),
		Vector3i(2, 1 + _weld_test_count, 0),
	]
	for origin_cell: Vector3i in candidates:
		var command := PlaceElementCommand.new()
		command.assembly_id = _rig_assembly_id
		command.expected_assembly_revision = assembly.topology_revision
		command.archetype = Slice01Archetypes.frame()
		command.origin_cell = origin_cell
		command.orientation_index = 0
		command.store_id = PlayerIdentity.store_id("player")
		print("TestYard: weld attempt @ %s" % origin_cell)
		var result := world.apply_structural_command_now(command)
		print(
			"TestYard: weld frame @ %s -> %s"
			% [origin_cell, result.reason]
		)
		if result.is_ok():
			_weld_test_count += 1
			_weld_last_element_id = int(result.data.get("element_id", 0))
			return
