extends Node3D

## Moon experiment entry — spherical VoxelLodTerrain + radial Field.
## Parity wiring with main; spawn probes follow GravityField, not world −Y.

## Preload (not class_name) so headless runs don't depend on the editor's
## global class cache having rescanned the new script.
const _NativeSdfGen := preload(
	"res://scripts/simulation/runtime/moon_native_sdf_generator.gd"
)

const MIN_WARMUP_FRAMES := 30
## Lunar g=1.62: settle can take a few seconds once a floor exists.
const MAX_SPAWN_SETTLE_FRAMES := 360
## Voxel trimesh colliders lag SDF (VT #677 / scale≠1). Wait for a cooked LOD0
## collider before seating so the player/vehicles land on the real surface
## instead of the SDF landing pad (which reads as "floating in the sky" over the
## lower visual mesh) or a coarse far-LOD collider (gaps → falling through).
## On Ø19 km the near-spawn collider takes several seconds to cook, so the old
## 1.5 s probe almost always fell back to the pad. The temp landing pad still
## backs this up if the collider never appears in time.
const PHYSICS_GROUND_TIMEOUT_MS := 8000
const PHYSICS_GROUND_TIMEOUT_LOAD_MS := 8000
const AUTOSAVE_INTERVAL_S := 90.0
## COOP-PERF-PLAYBOOK.md Phase 0: sample VT/Performance stats at ~7 Hz, not
## every frame — cheap reads, but no reason to reformat the string 200×/s.
const PERF_OVERLAY_SAMPLE_INTERVAL_S := 0.15
## Coalesce carve spam before writing digs; flush only after async save completes.
const DIG_PERSIST_DEBOUNCE_S := 1.5
const DIG_SAVE_TIMEOUT_MS := 15000
const LANDING_PAD_SIZE_M := Vector3(48.0, 4.0, 48.0)
## Cross-fade LOD mesh swaps (requires get_lod_fade_discard in terrain shader).
const TERRAIN_LOD_FADE_DURATION_S := 0.25
## Milliseconds to coalesce collider re-cooks after an edit. Modest on purpose:
## this is the gap between "the hole is visible" and "you can walk into it".
const TERRAIN_COLLISION_UPDATE_DELAY_MS := 100
## Detail normalmaps from LOD 2+ — illusion of geometry on distant blocks.
const TERRAIN_NORMALMAP_BEGIN_LOD := 2
const DEMO_ROVER_OFFSET_M := 32.0
const DEBUG_ROVER_SPAWN_OFFSET_M := 6.0
const DEMO_HOPPER_OFFSET_M := 68.0
const LAMP_POLE_SCENE := preload("res://scenes/props/lamp_pole.tscn")
const LAMP_POLE_OFFSETS_M: Array[Vector3] = [
	Vector3(6.0, 0.0, 4.0),
	Vector3(-5.0, 0.0, 7.0),
	Vector3(2.0, 0.0, -8.0),
]
## Shrink streaming during spawn so VT finishes local colliders first
## (full shell budget restored at world_ready).
const SPAWN_FOCUS_VIEW_DISTANCE_VOXELS := 512
## LOD0+LOD1 colliders — coarser shell often ready before LOD0 (VT #676).
## 3: coarse collider exists sooner under fast descents from orbit
## (LOD0-only cooking can't outrun a free fall — tunnelling through crust).
const SPAWN_COLLISION_LOD_COUNT := 3
## Display-only panorama (cinematics / legacy tools). Terrain and map globe
## sample analytic H(n) directly; bake runs in background after world_ready.
const MAP_HEIGHTMAP_SIZE := Vector2i(2048, 1024)

@onready var _terrain: Node3D = $VoxelTerrain
@onready var _boulder_instancer: VoxelInstancer = $VoxelTerrain/VoxelInstancer
@onready var _player: Node3D = $Player
@onready var _session: SimulationSession = $SimulationSession
@onready var _base_spawn: Node3D = $BaseSpawn
@onready var _gravity_field: GravityField = $GravityField
@onready var _loading: Label = $CanvasLayer/Loading
@onready var _coordinates: Label = $CanvasLayer/Coordinates
@onready var _hint: Label = $CanvasLayer/Hint
@onready var _perf_line: Label = $CanvasLayer/PerfLine

@export var debug_overlay := false
## Draws the streamer's own view of itself: one wire box per viewer, and where
## mesh vs collision actually exist. The "crust is drawn but there is no LOD0
## under you" family of bugs is a picture here instead of an afternoon of
## reading plugin sources — that is what it is for. Editor builds only
## (`debug_set_draw_enabled` is behind TOOLS_ENABLED), which is what we run.
@export var debug_terrain_draw := false
@export var playtest_cargo := true
## Enable after radial rover seating (phase 6). Off for early shell bring-up.
@export var spawn_demo_rover := true
## Flight hopper for POC-THRUSTERS-V0 manual hop/land checks.
@export var spawn_demo_hopper := true
## A few omni lamp poles near spawn — local lights + RT occluders.
@export var spawn_lamp_poles := true
## «На новых» = пара колесо+подвеска, испечённая визардом (authored). Прежнее
## значение — "колбаса на 12 колес, низкая".
## Длинная база + центр масс + батареи сбоку: меньше клевка на газе и кувырка на тормозе.
@export var demo_rover_phrase := "огромная колбаса на 12 колёсах, широкая, высокая, кокпит в центре, питание сбоку, два бура на морде"
@export var persist_digs := true
## VoxelInstancer decorative rocks (streams with terrain chunks).
@export var enable_boulder_instancer := true
## Multiplier on library densities; <0 = auto (reference Ø1 km → current diameter).
@export var boulder_density_scale := -1.0

@export_group("Planet generator")
## Preferred play path: analytic native SDF (MoonNativeSdfGenerator — same
## H(n) as the old bake, sampled per block in C++). No panorama projection →
## no pole pinch / longitude seam; scales past Ø1 km without a bake.
@export var use_native_sdf := true
## Editor override: res://resources/moon_planet_generator.tres (Voxel graph UI).
## Only consulted when the native path is off/unavailable.
@export var planet_graph: VoxelGeneratorGraph
## Legacy fallback: bake H(n) crust to a panorama heightmap and feed the
## native NODE_SDF_SPHERE_HEIGHTMAP (pole pinch at ±Y is inherent to it).
@export var use_baked_heightmap := true
## Bake/play resolution for NODE_SDF_SPHERE_HEIGHTMAP. 8192×4096 ≈ 0.38 m/texel
## (sub-voxel at scale 1.0) so bilinear sampling stays smooth without a runtime
## cubic upsample. Drop to 4096×2048 if memory/bake time is tight.
@export var heightmap_size := Vector2i(8192, 4096)
@export_subgroup("Knobs (only if Planet Graph is empty)")
@export_range(0.0, 80.0, 0.5, "or_greater") var height_amp_m := 22.0
@export_range(10.0, 400.0, 1.0, "or_greater") var noise_period_m := 95.0
@export var noise_seed := 5046367
## 0=FBM hills, 2=Ridged (docs eroded look with carve_eroded).
@export_enum("FBM:0", "Ridged:2") var fractal_type: int = 2
@export_range(1, 8) var noise_octaves := 4
## Negate height — ridged carves instead of puffing (Generators→Planet).
@export var carve_eroded := true

var _perf_overlay_accum := 0.0
## proc/phys are averaged over the sample window instead of a single snapshot:
## TIME_PROCESS is per render frame and TIME_PHYSICS_PROCESS is per physics
## tick, two different clocks that free-run at different rates (render can be
## 190 Hz while physics stays fixed at 60 Hz) — one-shot samples of each
## picked at an arbitrary instant do not add up to 1000/FPS and are not
## comparable to each other. Averaging both across the same window at least
## makes each number a true rate in its own clock.
var _perf_proc_ms_accum := 0.0
var _perf_proc_samples := 0
var _perf_phys_ms_accum := 0.0
var _perf_phys_ticks := 0
## Breakdown of our own GDScript inside the physics tick (SimulationSession +
## SimulationPhysicsProjection totals) — see get_last_tick_breakdown_us().
## What's left of phys after subtracting this is PhysicsServer3D::sync/
## flush_queries/step, i.e. the actual native Jolt cost.
var _perf_script_ms_accum := 0.0
var _perf_wheel_ms_accum := 0.0
var _perf_motion_sync_ms_accum := 0.0
var _perf_industry_ms_accum := 0.0
var _warmup_frames := 0
var _player_spawn_hint := Vector3.UP
var _player_spawn_pos := Vector3.ZERO
var _world_ready := false
var _debug_rover_spawn_busy := false
var _autosave_accum := 0.0
var _last_save_ms := 0
var _save_load_attempted := false
var _voxel_stream: VoxelStream
var _landing_pad: StaticBody3D
var _far_impostor: MeshInstance3D
var _player_camera: Camera3D
var _applied_view_distance := -1
var _digs_dirty := false
var _dig_persist_cooldown_s := 0.0
var _dig_persist_in_flight := false
var _quit_after_dig_persist := false
var _generator_is_native := false
var _native_generator: Object = null
var _map_heightmap_scheduled := false


func is_world_ready() -> bool:
	return _world_ready


## While a client is connected to a host (COOP-HOST-V0), its local session world
## is a replica of the host's — saving it would overwrite this machine's own
## single-player save with someone else's world. CoopSession flips this on join
## and off on leave/disconnect (leave reloads the scene anyway).
var _coop_persistence_inhibited := false


func set_coop_persistence_inhibited(inhibited: bool) -> void:
	_coop_persistence_inhibited = inhibited


## Flush this machine's own single-player progress once, then stop persisting —
## called by CoopSession the moment a join is accepted, before the host snapshot
## replaces the local world.
func save_now_then_inhibit_persistence() -> void:
	await _persist_world(true)
	_coop_persistence_inhibited = true


## Host join catch-up: push pending digs to SQLite before reading the file for
## CH_BULK. Does not touch world JSON / granular sidecar cadence beyond digs.
func flush_digs_for_coop_join() -> void:
	if _coop_persistence_inhibited:
		return
	_digs_dirty = true
	_dig_persist_cooldown_s = 0.0
	await _persist_digs_durable()


## Host: bytes of moon.sqlite + live granular snapshot for join bulk.
## Call after flush_digs_for_coop_join. Empty sqlite when no dig stream file.
func capture_coop_terrain_bulk() -> Dictionary:
	var sqlite := PackedByteArray()
	var db_path := MoonTerrainParams.stream_database_path()
	if FileAccess.file_exists(db_path):
		sqlite = FileAccess.get_file_as_bytes(db_path)
	var granular := {}
	var granular_world := get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
	if granular_world != null and granular_world.has_method(&"capture_field_snapshot"):
		granular = granular_world.capture_field_snapshot()
	return {"sqlite": sqlite, "granular": granular}


## Client: write host dig DB to a session replica (not personal gen_vN), swap
## terrain.stream onto it, kick viewers so loaded shells re-read digs. Granular
## restore is memory-only — persistence stays inhibited.
func apply_coop_terrain_bulk(sqlite_bytes: PackedByteArray, granular: Dictionary) -> bool:
	if not (_terrain is VoxelLodTerrain):
		return false
	var applied_db := false
	if not sqlite_bytes.is_empty():
		var replica_dir := CoopTerrainBulk.REPLICA_DIR
		var abs_dir := ProjectSettings.globalize_path(replica_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)
		var replica_path := CoopTerrainBulk.replica_database_path()
		var file := FileAccess.open(replica_path, FileAccess.WRITE)
		if file == null:
			push_warning(
				"Coop: cannot write terrain bulk replica %s" % replica_path
			)
			return false
		file.store_buffer(sqlite_bytes)
		file.close()
		var stream := VoxelStreamSQLite.new()
		stream.database_path = replica_path
		## Replica is host truth for this session — do not grow it with local gen.
		stream.save_generator_output = false
		var lod := _terrain as VoxelLodTerrain
		lod.stream = stream
		_voxel_stream = stream
		_kick_voxel_viewers_for_stream_reload()
		applied_db = true
		print(
			"Coop: applied host dig-stream bulk (%d bytes) → %s"
			% [sqlite_bytes.size(), replica_path]
		)
	if not granular.is_empty():
		var granular_world := get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
		if granular_world != null and granular_world.has_method(&"restore_field_snapshot"):
			var n: int = int(granular_world.restore_field_snapshot(granular))
			print("Coop: restored %d granular region(s) from host bulk" % n)
	return applied_db or not granular.is_empty()


func _kick_voxel_viewers_for_stream_reload() -> void:
	## Client join only needs the local viewer — host proxies are host-side.
	var viewer := _find_voxel_viewer()
	if viewer == null:
		return
	var dist := viewer.view_distance
	viewer.view_distance = maxi(dist / 4, 8)
	viewer.view_distance = dist


## Re-drop the local player near a world point using the existing settle
## machinery (COOP-HOST-V0 join: land the client next to the host). Async.
func reseat_player_near(target_world: Vector3) -> void:
	var dir := target_world.normalized()
	if dir.length_squared() < 0.000001:
		dir = _player_spawn_hint
	_player_spawn_hint = dir
	if _player.has_method("set_spawn_locked"):
		_player.set_spawn_locked(true)
	var hold := MoonGeometry.spawn_hold_point(dir)
	_player.global_position = hold
	_set_spawn_streaming_focus(true)
	var resolved := await _resolve_spawn_with_floor(
		hold,
		_gravity_field.probe_direction_toward_ground(hold),
		MoonGeometry.surface_point(dir),
		PHYSICS_GROUND_TIMEOUT_LOAD_MS
	)
	_player.call("begin_spawn_settle", resolved)
	var settle_frames := 0
	while not _player.call("is_spawn_settled"):
		await get_tree().physics_frame
		settle_frames += 1
		if settle_frames >= MAX_SPAWN_SETTLE_FRAMES:
			_player.call("set_spawn_ready", _snap_spawn_to_ground(_player.global_position))
			break
	_resync_player_camera()
	_set_spawn_streaming_focus(false)


func _ready() -> void:
	## Hold quit until dig SQLite save+flush finishes (cave/base must survive reload).
	get_tree().auto_accept_quit = false
	WorldPersistence.save_path_override = MoonGeometry.world_save_path()
	_loading.visible = true
	_coordinates.visible = debug_overlay
	_hint.visible = debug_overlay
	_perf_line.visible = debug_overlay
	_register_perf_overlay_console_command()
	_loading.text = "Луна..."
	_configure_terrain()
	_configure_dig_stream()
	_configure_boulder_instancer()
	_configure_far_impostor()
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_flight_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	var gateway := get_node_or_null("WorldCommandGateway")
	if gateway != null and gateway.has_signal("terrain_modified"):
		gateway.terrain_modified.connect(_on_terrain_modified)
	# Sintered loose material becomes rock — mark the dig stream dirty so the
	# new solid persists to SQLite exactly like a carve does.
	if gateway != null and gateway.has_signal("terrain_deposited"):
		gateway.terrain_deposited.connect(_on_terrain_deposited)
	_player_spawn_hint = _player.global_position
	if _player_spawn_hint.length_squared() <= 0.000001:
		_player_spawn_hint = Vector3.UP
	else:
		_player_spawn_hint = _player_spawn_hint.normalized()
	if not _generator_is_native:
		## Equirectangular heightmap fallback: keep spawn off the ±Y pole
		## singularity where all longitude texels converge into a pinch/star.
		## The analytic generator has no poles — spawn anywhere.
		_player_spawn_hint = _away_from_pole(_player_spawn_hint).normalized()
	## Point VoxelViewer at the saved spot from frame 0 so stream isn't at
	## the default spawn while we still intend to load.
	var early_saved := _peek_saved_player_position()
	if _is_usable_saved_player_position(early_saved):
		_player_spawn_hint = early_saved.normalized()
	if _base_spawn != null:
		_base_spawn.global_position = MoonGeometry.surface_point(_player_spawn_hint)
	## Publish the landing site once the hint is final. The starting ore lenses
	## are placed relative to it, and until this was set the drill resolved them
	## as absent while the map drew them around the player.
	MoonMaterialField.set_spawn_world(
		MoonGeometry.surface_point(_player_spawn_hint)
	)
	if _player.has_method("set_spawn_locked"):
		_player.set_spawn_locked(true)
	_player.global_position = MoonGeometry.spawn_hold_point(_player_spawn_hint)
	_place_when_ground_exists()


func _physics_process(_delta: float) -> void:
	if not debug_overlay:
		return
	_perf_phys_ms_accum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_perf_phys_ticks += 1
	if _session == null or _session.projection == null:
		return
	var proj_us: Dictionary = _session.projection.get_last_tick_breakdown_us()
	var sess_us: Dictionary = _session.get_last_tick_breakdown_us()
	_perf_script_ms_accum += (
		float(proj_us.get("total", 0)) + float(sess_us.get("total", 0))
	) / 1000.0
	_perf_wheel_ms_accum += float(proj_us.get("wheel_bodies_per_wheel", 0)) / 1000.0
	_perf_motion_sync_ms_accum += float(proj_us.get("motion_sync", 0)) / 1000.0
	_perf_industry_ms_accum += float(sess_us.get("industry_tick", 0)) / 1000.0


func _process(delta: float) -> void:
	_update_streaming_budget()
	_update_far_impostor()
	if _world_ready:
		_autosave_accum += delta
		if _autosave_accum >= AUTOSAVE_INTERVAL_S:
			_autosave_accum = 0.0
			_persist_world()
		if _digs_dirty and not _dig_persist_in_flight:
			if _dig_persist_cooldown_s > 0.0:
				_dig_persist_cooldown_s -= delta
			if _dig_persist_cooldown_s <= 0.0:
				_persist_digs_durable()
		# Poll action: _unhandled_input is often eaten by HUD/focus while
		# mouse is captured; same pattern as gameplay move axes.
		if (
			not _debug_rover_spawn_busy
			and Input.is_action_just_pressed(&"spawn_debug_rover")
		):
			_spawn_debug_rover_near_player()
	if not debug_overlay:
		return
	var player_position: Vector3 = _player.global_position
	_coordinates.text = (
		"Игрок:  %.1f, %.1f, %.1f"
	) % [
		player_position.x,
		player_position.y,
		player_position.z,
	]
	_perf_proc_ms_accum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_perf_proc_samples += 1
	_perf_overlay_accum += delta
	if _perf_overlay_accum < PERF_OVERLAY_SAMPLE_INTERVAL_S:
		return
	_perf_overlay_accum = 0.0
	_update_perf_overlay_line()


## COOP-PERF-PLAYBOOK.md Phase 0 (measurement only — no tuning here). Cheap
## reads of already-computed VT/Performance/coop counters, sampled at
## PERF_OVERLAY_SAMPLE_INTERVAL_S (AGENTS.md R9) — no per-frame allocation,
## no world scan (`voxel_viewers` is a group, not a tree walk).
##
## proc/phys are the average over the last window, not one instantaneous
## Performance sample — TIME_PROCESS/TIME_PHYSICS_PROCESS are two different
## clocks (render frame vs. fixed physics tick) that free-run at different
## rates, so a single snapshot of each does not add up to 1000/FPS.
## main_blk reads VoxelEngine's own main-thread task queue (VoxelEngine
## .get_stats()["tasks"]["main_thread"]) — that is the actual H1 metric
## (main-thread collider/mesh build backlog); VoxelLodTerrain.get_statistics()
## has no such key, it only has time_update_task (last update task's total
## time, ms here) which upd_ms reports as a "did VT do anything this tick"
## signal.
##
## active/pairs/islands (PHYSICS_3D_ACTIVE_OBJECTS/COLLISION_PAIRS/
## ISLAND_COUNT) are always 0 with Jolt: Godot docs — "Only supported when
## using GodotPhysics3D. This parameter is ignored when using Jolt Physics" —
## confirmed in engine source, JoltPhysicsServer3D::get_process_info
## (modules/jolt_physics/jolt_physics_server_3d.cpp) unconditionally
## `return 0`. Kept in the overlay only so nobody re-discovers this the hard
## way; they are not evidence of anything.
##
## script/engine splits `phys` using SimulationPhysicsProjection/
## SimulationSession's own tick timers: main/main.cpp's physics iteration
## runs PhysicsServer3D::sync + every node's _physics_process() (script,
## including ours) THEN PhysicsServer3D::step() (native Jolt) inside the same
## TIME_PHYSICS_PROCESS window, so the raw number cannot tell them apart on
## its own — see SimulationPhysicsProjection.get_last_tick_breakdown_us().
func _update_perf_overlay_line() -> void:
	if _perf_line == null or not (_terrain is VoxelLodTerrain):
		return
	var lod := _terrain as VoxelLodTerrain
	var stats := lod.get_statistics()
	var engine_tasks: Dictionary = VoxelEngine.get_stats().get("tasks", {})
	var coop := get_node_or_null("CoopSession")
	var peers := 0
	if coop != null and coop.has_method("peer_count"):
		peers = int(coop.call("peer_count"))
	var viewers := get_tree().get_nodes_in_group(&"voxel_viewers").size()
	var avg_proc_ms := (
		_perf_proc_ms_accum / float(_perf_proc_samples) if _perf_proc_samples > 0 else 0.0
	)
	var ticks := maxi(_perf_phys_ticks, 1)
	var avg_phys_ms := _perf_phys_ms_accum / float(ticks)
	var avg_script_ms := _perf_script_ms_accum / float(ticks)
	var avg_wheel_ms := _perf_wheel_ms_accum / float(ticks)
	var avg_motion_sync_ms := _perf_motion_sync_ms_accum / float(ticks)
	var avg_industry_ms := _perf_industry_ms_accum / float(ticks)
	var avg_engine_ms := maxf(avg_phys_ms - avg_script_ms, 0.0)
	_perf_line.text = (
		(
			"FPS %.0f | proc %.1fms | phys %.1fms = script %.1fms + engine≈%.1fms "
			+ "(wheel %.2f motion %.2f industry %.2f) (%d ticks) | main_blk %d | "
			+ "upd_ms %.2f | active %d | pairs %d | islands %d | peers %d | viewers %d"
		)
	) % [
		Performance.get_monitor(Performance.TIME_FPS),
		avg_proc_ms,
		avg_phys_ms,
		avg_script_ms,
		avg_engine_ms,
		avg_wheel_ms,
		avg_motion_sync_ms,
		avg_industry_ms,
		_perf_phys_ticks,
		int(engine_tasks.get("main_thread", 0)),
		float(stats.get("time_update_task", 0)) / 1000.0,
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		peers,
		viewers,
	]
	_perf_proc_ms_accum = 0.0
	_perf_proc_samples = 0
	_perf_phys_ms_accum = 0.0
	_perf_phys_ticks = 0
	_perf_script_ms_accum = 0.0
	_perf_wheel_ms_accum = 0.0
	_perf_motion_sync_ms_accum = 0.0
	_perf_industry_ms_accum = 0.0


## No hardcoded key (AGENTS.md conventions): toggled from LimboConsole like
## CoopSession's `host`/`join`/`coop_status`, not a new input action.
func _register_perf_overlay_console_command() -> void:
	if LimboConsole == null:
		return
	LimboConsole.register_command(
		_toggle_perf_overlay,
		"perf_overlay",
		"Coop perf: toggle main-thread collider budget overlay (COOP-PERF-PLAYBOOK.md)",
	)


func _toggle_perf_overlay() -> void:
	debug_overlay = not debug_overlay
	_coordinates.visible = debug_overlay
	_hint.visible = debug_overlay
	_perf_line.visible = debug_overlay
	_perf_overlay_accum = 0.0
	_perf_proc_ms_accum = 0.0
	_perf_proc_samples = 0
	_perf_phys_ms_accum = 0.0
	_perf_phys_ticks = 0
	_perf_script_ms_accum = 0.0
	_perf_wheel_ms_accum = 0.0
	_perf_motion_sync_ms_accum = 0.0
	_perf_industry_ms_accum = 0.0
	print("MoonExperiment: perf overlay %s" % ("ON" if debug_overlay else "OFF"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_request_quit_after_persist()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		_persist_world(true)


func _exit_tree() -> void:
	## Best-effort if Stop/kill skipped WM_CLOSE; no flush race here.
	_persist_world_snapshot_only(true)
	if (
		persist_digs
		and _terrain is VoxelLodTerrain
		and _digs_dirty
		and not _coop_persistence_inhibited
	):
		(_terrain as VoxelLodTerrain).save_modified_blocks()
	WorldPersistence.save_path_override = ""


func _configure_terrain() -> void:
	if not TerrainCompat.is_terrain(_terrain):
		push_error("Moon experiment terrain node is not VoxelTerrain/VoxelLodTerrain")
		return
	if _terrain is VoxelLodTerrain:
		var lod := _terrain as VoxelLodTerrain
		## Docs Generators→Planet: graph resource and/or knobs (see exports).
		lod.generator = _make_planet_generator()
		## Clipbox, not the default legacy octree. The octree system supports
		## exactly ONE viewer: `VoxelLodTerrain::get_local_viewer_pos` walks every
		## registered viewer and keeps whichever comes last ("TODO Support for
		## multiple viewers, this is a placeholder implementation"). At the time
		## this bit, `GranularVoxelRegionView` created a VoxelViewer per loose
		## material region (it meshes natively now and needs none), so the moon's
		## LODs followed a coin flip: settle around the sand, and LOD0 under the
		## player never gets requested at all (stats stayed blocked=0, io=0 while
		## digs returned `terrain_unavailable` and LOD1/2 colliders carried the
		## player). Clipbox pairs viewers individually, which is what it was added
		## upstream to do — and it stays: nothing guarantees the player's viewer
		## remains the only one.
		lod.streaming_system = VoxelLodTerrain.STREAMING_SYSTEM_CLIPBOX
		## ORDER MATTERS. `set_voxel_bounds` snaps the box to the octree size
		## (`mesh_block_size << (lod_count - 1)`) as it is at assignment time.
		## `set_mesh_block_size` re-snaps, but returns early when the value is
		## already the default (16), and `set_lod_count` never re-snaps at all.
		## Assigned first, the bounds get snapped against the *default* octree
		## size and keep it: ±11888 instead of a multiple of 8192. That, not the
		## arithmetic, is what made `32 + lod_count 10` cut the moon into cubes.
		lod.mesh_block_size = MoonGeometry.DEFAULT_MESH_BLOCK_SIZE
		lod.lod_count = MoonGeometry.DEFAULT_LOD_COUNT
		lod.voxel_bounds = MoonGeometry.voxel_bounds_aabb()
		lod.view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
		lod.generate_collisions = true
		lod.collision_lod_count = SPAWN_COLLISION_LOD_COUNT
		lod.lod_distance = MoonGeometry.DEFAULT_LOD_DISTANCE
		## Clipbox splits what octree took from one knob: `lod_distance` is LOD0
		## reach (and, streaming on, how far edits are allowed), this one is
		## every LOD above it.
		lod.secondary_lod_distance = MoonGeometry.DEFAULT_SECONDARY_LOD_DISTANCE
		lod.lod_fade_duration = TERRAIN_LOD_FADE_DURATION_S
		## Detail normalmaps need generator series generation, which script
		## generators don't support (VT asserts per tile). Graph fallback keeps
		## them; native path relies on real far-LOD geometry for now.
		lod.normalmap_enabled = not _generator_is_native
		lod.normalmap_begin_lod_index = TERRAIN_NORMALMAP_BEGIN_LOD
		lod.normalmap_tile_resolution_min = 4
		lod.normalmap_tile_resolution_max = 16
		lod.cache_generated_blocks = true
		lod.threaded_update_enabled = true
		## Trimesh cooking is the expensive half of a ring update, and every dig
		## re-cooks the blocks it touched. Default 0 re-cooks immediately, one
		## edit at a time; a delay coalesces a burst (drill held down, dozer
		## blade pushing) into fewer cooks. Cost is colliders lagging the visual
		## mesh by that long — keep it under a frame or two of gameplay.
		lod.collision_update_delay = TERRAIN_COLLISION_UPDATE_DELAY_MS
		_apply_terrain_debug_draw(lod)
	if _terrain.material != null:
		var mat: Material = (_terrain.material as Material).duplicate()
		_terrain.material = mat
		if mat is ShaderMaterial:
			var shader_mat := mat as ShaderMaterial
			_apply_planet_terrain_shader_params(shader_mat)
	_terrain.scale = Vector3.ONE * MoonGeometry.VOXEL_SCALE
	_ensure_player_viewer_for_planet()


## The four flags that answer "why is there no LOD0 here": which viewer the
## streamer is actually serving, and where mesh and collision each exist. The
## other eight flags stay off — they draw per-block boxes across the whole
## Ø19 km shell and bury the ones worth reading.
func _apply_terrain_debug_draw(lod: VoxelLodTerrain) -> void:
	if not debug_terrain_draw:
		return
	lod.debug_draw_enabled = true
	lod.debug_draw_viewer_clipboxes = true
	lod.debug_draw_loaded_visual_and_collision_blocks = true
	lod.debug_draw_volume_bounds = true
	lod.debug_draw_edit_boxes = true
	print("MoonExperiment: terrain debug draw on (clipboxes, blocks, bounds, edits)")


func _apply_planet_terrain_shader_params(shader_mat: ShaderMaterial) -> void:
	shader_mat.set_shader_parameter("u_radial_up", 1.0)
	shader_mat.set_shader_parameter("u_planet_radius", MoonGeometry.active_surface_radius_m())
	## Biome/macro are meter-periodic on dir*R inside the shader — do not shrink
	## u_biome_scale / u_large_scale with diameter (that flattened tri-biome into
	## one soup on Ø19 km). u_detail_scale stays world-triplanar metres.
	print(
		"MoonExperiment: terrain shader radial R=%.0f m"
		% MoonGeometry.active_surface_radius_m()
	)
	_apply_brightness_map(shader_mat)


## Display-only albedo brightness (dark maria + fresh-crater ray systems)
## baked natively (~1 s MT at startup); SDF untouched — no GENERATOR_VERSION.
func _apply_brightness_map(shader_mat: ShaderMaterial) -> void:
	if _native_generator == null or not _native_generator.has_method("bake_brightness_map"):
		return
	var img: Image = _native_generator.bake_brightness_map(1024, 512)
	if img == null:
		push_warning("MoonExperiment: brightness map bake failed")
		return
	var tex := ImageTexture.create_from_image(img)
	shader_mat.set_shader_parameter("u_moon_brightness", tex)
	shader_mat.set_shader_parameter("u_moon_brightness_on", 1.0)
	print("MoonExperiment: albedo brightness map applied (maria + rays)")


func _make_planet_generator() -> VoxelGenerator:
	if use_native_sdf:
		var native := _NativeSdfGen.new(MoonGeometry.radius_voxels())
		if native.is_native_ready():
			_generator_is_native = true
			_native_generator = native
			print("MoonExperiment: native SDF generator — %s" % native.describe())
			_print_nearest_cave_entrances(native)
			return native
		push_warning(
			"MoonExperiment: native SDF generator unavailable; falling back"
		)
	if planet_graph != null:
		var compile_result: Dictionary = planet_graph.compile()
		if not bool(compile_result.get("success", true)):
			push_error("planet_graph compile failed: %s" % str(compile_result))
		else:
			print("MoonExperiment: using planet_graph resource")
			return planet_graph
	if use_baked_heightmap:
		var height_image := MoonHeightmapUtil.ensure_heightmap(
			heightmap_size.x, heightmap_size.y
		)
		if height_image != null and height_image.get_width() > 0:
			return MoonSphereGeneratorFactory.create_play_heightmap(
				MoonGeometry.radius_voxels(), height_image, 1.0
			)
		push_warning("MoonExperiment: heightmap bake failed; falling back to noise graph")
	return MoonSphereGeneratorFactory.create_play(
		MoonGeometry.radius_voxels(),
		{
			"height_amp_m": height_amp_m,
			"noise_period_m": noise_period_m,
			"noise_seed": noise_seed,
			"fractal_type": fractal_type,
			"octaves": noise_octaves,
			"carve_eroded": carve_eroded,
		}
	)


func _schedule_map_heightmap_bake() -> void:
	## Only when the native generator owns terrain: the heightmap fallback
	## already baked a full-res EXR synchronously (don't race its file).
	if not _generator_is_native or _map_heightmap_scheduled:
		return
	_map_heightmap_scheduled = true
	if FileAccess.file_exists(MoonHeightmapUtil.heightmap_path()):
		return
	WorkerThreadPool.add_task(
		func() -> void:
			MoonHeightmapUtil.ensure_heightmap(
				MAP_HEIGHTMAP_SIZE.x, MAP_HEIGHTMAP_SIZE.y
			),
		false,
		"Moon map heightmap bake"
	)


func _away_from_pole(dir: Vector3) -> Vector3:
	## Tilt near-pole spawn directions down to ~37° latitude, same longitude.
	var n := dir.normalized()
	if absf(n.y) <= 0.7:
		return n
	var horiz := Vector2(n.x, n.z)
	if horiz.length() < 0.001:
		horiz = Vector2(1.0, 0.0)
	horiz = horiz.normalized()
	const LAT_Y := 0.6  # sin(~37°)
	var ring := sqrt(maxf(0.0, 1.0 - LAT_Y * LAT_Y))
	return Vector3(horiz.x * ring, signf(n.y) * LAT_Y, horiz.y * ring).normalized()


## Debug aid: caves cover ~0.1% of the surface — without coordinates nobody
## finds one. Prints the three skylights nearest the current player position.
func _print_nearest_cave_entrances(native: Object) -> void:
	if not native.has_method("cave_entrances"):
		return
	var entrances: PackedVector3Array = native.cave_entrances()
	if entrances.is_empty():
		return
	var origin := Vector3.UP * MoonGeometry.radius_voxels()
	if _player != null:
		origin = _player.global_position
	var by_dist: Array = []
	for p in entrances:
		by_dist.append([origin.distance_to(p), p])
	by_dist.sort_custom(func(a, b): return a[0] < b[0])
	print("MoonExperiment: %d caves generated" % entrances.size())
	for i in mini(3, by_dist.size()):
		var entry: Array = by_dist[i]
		print(
			"MoonExperiment: cave skylight %d — %.0f m away at %v"
			% [i + 1, entry[0], entry[1]]
		)


func _configure_dig_stream() -> void:
	if not (_terrain is VoxelLodTerrain):
		return
	var dir := MoonGeometry.dig_stream_directory()
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	## Fresh gen_v dir (no partial LOD scraps). Generator fills crust; digs persist.
	var stream := VoxelStreamSQLite.new()
	stream.database_path = MoonTerrainParams.stream_database_path()
	## Persist generated crust too: Ø19 km analytic gen is heavy; relaunch should
	## read SQLite instead of re-deriving the shell. GENERATOR_VERSION bump →
	## fresh DB. Digs are modified blocks and persist either way.
	##
	## Costs ~21784 blocks / 108 MB per session, and every one of those saves
	## goes on the same serial slot as block loads (`push_async_io_task`), so
	## this was a suspect for LOD0 not reaching the player. It is not: measured
	## in play, `VoxelEngine.get_stats()` showed an empty queue the whole time
	## LOD0 was missing (the cause was the streamer following the wrong viewer —
	## see `_configure_terrain`). Do not re-litigate this flag without a number.
	stream.save_generator_output = true
	_voxel_stream = stream
	var lod := _terrain as VoxelLodTerrain
	lod.stream = stream
	lod.full_load_mode_enabled = false
	lod.cache_generated_blocks = true
	print(
		"MoonExperiment: planet gen_v%d dig-stream=%s"
		% [MoonTerrainParams.GENERATOR_VERSION, stream.database_path]
	)


func _configure_boulder_instancer() -> void:
	if _boulder_instancer == null:
		return
	if not enable_boulder_instancer:
		_boulder_instancer.library = null
		return
	var source_lib := _boulder_instancer.library as VoxelInstanceLibrary
	if source_lib == null:
		push_warning("MoonExperiment: boulder library missing")
		return
	var density_scale := boulder_density_scale
	if density_scale < 0.0:
		density_scale = MoonGeometry.boulder_density_scale_for_decor()
	var library := source_lib.duplicate(true) as VoxelInstanceLibrary
	if library.get_all_item_ids().is_empty():
		push_warning("MoonExperiment: boulder library duplicate empty — using source")
		library = source_lib
	## Fewer tiers on LOD0 = less work when streaming; boulders on LOD1 mesh.
	const LOD_BY_NAME := {
		"pebble_a": 0, "pebble_b": 0,
		"pebble_c": 1, "rock_a": 1, "rock_b": 1,
		"boulder": 1, "boulder_flat": 1,
	}
	for id in library.get_all_item_ids():
		var item := library.get_item(id)
		var item_name: String = str(item.name)
		if LOD_BY_NAME.has(item_name):
			item.lod_index = LOD_BY_NAME[item_name]
		var item_generator: VoxelInstanceGenerator = item.generator
		if item_generator != null:
			item_generator = item_generator.duplicate() as VoxelInstanceGenerator
			item_generator.density *= density_scale
			if _generator_is_native:
				item_generator.snap_to_generator_sdf_enabled = false
			item.generator = item_generator
	_boulder_instancer.library = library
	var sample := library.get_item(0)
	var sample_density := -1.0
	if sample != null and sample.generator != null:
		sample_density = sample.generator.density
	print(
		"MoonExperiment: boulders items=%d density_scale=%.2f pebble_a=%.4f"
		% [library.get_all_item_ids().size(), density_scale, sample_density]
	)


func _sync_demo_spawn_anchor() -> void:
	if _base_spawn == null or _player == null:
		return
	var anchor := _player.global_position
	if anchor.length_squared() <= 0.000001:
		return
	_base_spawn.global_position = anchor


func _demo_spawn_hint_offset(local_axis: Vector3, offset_m: float) -> Vector3:
	var anchor := Vector3.ZERO
	if _player != null and _player.global_position.length_squared() > 0.000001:
		anchor = _player.global_position
	elif _base_spawn != null:
		anchor = _base_spawn.global_position
	else:
		anchor = MoonGeometry.surface_point(Vector3.UP)
	if _gravity_field == null:
		return anchor + local_axis * offset_m
	var basis := _gravity_field.tangent_basis_at(anchor)
	var world_axis := (
		basis.x * local_axis.x
		+ basis.y * local_axis.y
		+ basis.z * local_axis.z
	)
	if world_axis.length_squared() <= 0.000001:
		world_axis = basis.z
	return anchor + world_axis.normalized() * offset_m


func _persist_world(force := false) -> void:
	_persist_world_snapshot_only(force)
	if force:
		_digs_dirty = true
		_dig_persist_cooldown_s = 0.0
		await _persist_digs_durable()
	elif _digs_dirty and not _dig_persist_in_flight:
		_dig_persist_cooldown_s = 0.0
		_persist_digs_durable()


func _persist_world_snapshot_only(force := false) -> void:
	# Client of a coop host: never write the replicated world to the local save.
	if _coop_persistence_inhibited:
		return
	if not _world_ready or _session == null:
		return
	if (
		_player == null
		or not is_instance_valid(_player)
		or not _player.is_inside_tree()
	):
		return
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_save_ms < 5000:
		return
	if WorldPersistence.save(
		_session.world,
		_player,
		_coop_extra_player_poses_for_save()
	):
		_last_save_ms = now_ms
	_persist_granular()


## Save the un-sintered loose material beside the world snapshot, on the same
## cadence. Sintered material is already rock and saves with the terrain.
func _persist_granular() -> void:
	var granular := get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
	if granular != null:
		granular.save_field(MoonGeometry.granular_save_path())


func _request_quit_after_persist() -> void:
	_quit_after_dig_persist = true
	_persist_world_snapshot_only(true)
	_digs_dirty = true
	_dig_persist_cooldown_s = 0.0
	if _dig_persist_in_flight:
		return
	_persist_digs_durable()


## save_modified_blocks (async) → wait tracker → flush once.
## Avoids SQLite lock spam and incomplete cave walls on reload.
## DIG-01: a caller that finds a save already in flight must not return before
## it actually completes (waits below) — an early return here let a coop join
## capture stale sqlite while another flush was still writing.
func _persist_digs_durable() -> void:
	if _dig_persist_in_flight:
		while _dig_persist_in_flight:
			await get_tree().process_frame
		return
	# Coop client: skip the SQLite dig flush too, but still honor a pending quit
	# so leaving/closing never hangs.
	if not persist_digs or not (_terrain is VoxelLodTerrain) or _coop_persistence_inhibited:
		if _quit_after_dig_persist:
			get_tree().quit()
		return
	_dig_persist_in_flight = true
	var lod := _terrain as VoxelLodTerrain
	while true:
		_digs_dirty = false
		var tracker: VoxelSaveCompletionTracker = lod.save_modified_blocks()
		if tracker != null:
			var deadline_ms := Time.get_ticks_msec() + DIG_SAVE_TIMEOUT_MS
			while (
				is_inside_tree()
				and not tracker.is_complete()
				and not tracker.is_aborted()
			):
				if Time.get_ticks_msec() >= deadline_ms:
					push_warning(
						(
							"MoonExperiment: dig save timed out (%d tasks left)"
							% tracker.get_remaining_tasks()
						)
					)
					break
				await get_tree().process_frame
		if _voxel_stream != null:
			_voxel_stream.flush()
		if not _digs_dirty:
			break
	_dig_persist_in_flight = false
	if _quit_after_dig_persist:
		get_tree().quit()


func _on_terrain_modified(
	_removed_volume_m3: float,
	_dig_center: Vector3,
	_dig_radius_m: float,
	_dig_direction: Vector3
) -> void:
	_digs_dirty = true
	_dig_persist_cooldown_s = DIG_PERSIST_DEBOUNCE_S


## Sintered granular material wrote solid into the rock SDF. Same durability
## path as a carve — the plugin already marked the touched blocks modified, this
## just tells the autosave loop to flush them.
func _on_terrain_deposited(
	_deposit_center: Vector3,
	_deposit_radius_m: float
) -> void:
	_digs_dirty = true
	_dig_persist_cooldown_s = DIG_PERSIST_DEBOUNCE_S


func _begin_fresh_world(player_position: Vector3) -> void:
	if not IndustryStoreService.seed_player_starter_resources(
		_session.world,
		PlayerIdentity.local_uid()
	):
		push_error("Fresh world player starter resources seed failed")
	await _finish_world_entry(player_position)
	## Main map is intentionally bare on a fresh world — only the demo rover and
	## hopper (spawned in _finish_world_entry). The Slice-01 starter base is no
	## longer auto-placed; build it in-game instead.


func _finish_world_entry(player_position: Vector3) -> void:
	_align_sun_day_at(player_position)
	_player.call("begin_spawn_settle", player_position)
	_loading.text = "Посадка..."
	var settle_frames := 0
	while not _player.call("is_spawn_settled"):
		await get_tree().physics_frame
		settle_frames += 1
		if settle_frames >= MAX_SPAWN_SETTLE_FRAMES:
			var snap := _snap_spawn_to_ground(_player.global_position)
			push_warning(
				(
					"Spawn settle timed out after %d frames; snapping to %s"
					% [settle_frames, str(snap)]
				)
			)
			_player.call("set_spawn_ready", snap)
			break
	_loading.visible = false
	_world_ready = true
	_schedule_map_heightmap_bake()
	## Keep spawn-focus VD until demos finish — restoring 2048 here hitch-stacked
	## with vehicle compose.
	print(
		"MoonExperiment: world_ready player=%s r=%.2f"
		% [str(_player.global_position), _player.global_position.length()]
	)
	_resync_player_camera()
	_session.get_industry_simulation().bind_world(_session.world)
	_apply_playtest_cargo_if_enabled()
	_sync_demo_spawn_anchor()
	if spawn_demo_rover:
		await _spawn_demo_rover_near_player()
		for _i in 3:
			await get_tree().physics_frame
	if spawn_demo_hopper:
		await _spawn_demo_hopper_near_player()
	if spawn_lamp_poles:
		_spawn_lamp_poles_near_player()
	_set_spawn_streaming_focus(false)


func _finish_loaded_world_entry(spawn_position: Vector3) -> void:
	_align_sun_day_at(spawn_position)
	_player.call("set_spawn_ready", spawn_position)
	_resync_player_camera()
	_loading.visible = false
	_world_ready = true
	_schedule_map_heightmap_bake()
	_set_spawn_streaming_focus(false)
	print(
		(
			"MoonExperiment: world_ready (loaded) player=%s r=%.2f"
		)
		% [str(spawn_position), spawn_position.length()]
	)
	_session.get_industry_simulation().bind_world(_session.world)
	_apply_playtest_cargo_if_enabled()
	if spawn_lamp_poles:
		_spawn_lamp_poles_near_player()


func _align_sun_day_at(world_position: Vector3) -> void:
	var cycle := get_node_or_null("DayNightCycle") as DayNightCycle
	if cycle == null:
		return
	var up := world_position
	if up.length_squared() <= 0.000001:
		up = Vector3.UP
	cycle.align_noon_above(up)


func _apply_playtest_cargo_if_enabled() -> void:
	if not playtest_cargo or _session == null or _session.world == null:
		return
	if not IndustryStoreService.apply_playtest_cargo(
		_session.world,
		PlayerIdentity.local_uid()
	):
		push_error("Playtest cargo seed failed")


func _spawn_lamp_poles_near_player() -> void:
	if get_node_or_null("LampPoles") != null:
		return
	var root := Node3D.new()
	root.name = "LampPoles"
	add_child(root)
	var space := _physics_space_state()
	var placed := 0
	for local_off in LAMP_POLE_OFFSETS_M:
		var hint := _demo_spawn_hint_offset(local_off.normalized(), local_off.length())
		var up := Vector3.UP
		if _gravity_field != null:
			up = _gravity_field.up_at(hint)
		var ground := hint
		if space != null:
			var from := hint + up * 40.0
			var to := hint - up * 80.0
			var q := PhysicsRayQueryParameters3D.create(from, to)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				ground = hit["position"] as Vector3
		var pole: Node3D = LAMP_POLE_SCENE.instantiate()
		root.add_child(pole)
		var basis := Basis.IDENTITY
		if _gravity_field != null:
			basis = _gravity_field.tangent_basis_at(ground)
		pole.global_transform = Transform3D(basis, ground)
		placed += 1
	print("MoonExperiment: spawned %d lamp poles near player" % placed)


func _spawn_demo_rover_near_player() -> void:
	var hint := _demo_spawn_hint_offset(Vector3(0.0, 0.0, -1.0), DEMO_ROVER_OFFSET_M)
	await _spawn_rover_at_hint(hint, "Demo rover")


func _spawn_debug_rover_near_player() -> void:
	if _debug_rover_spawn_busy:
		return
	_debug_rover_spawn_busy = true
	print("MoonExperiment: U → spawn debug rover…")
	_set_debug_spawn_status("U: собираю ровер перед тобой…")
	# Seat on the aim point in front of the camera — do not wander for a
	# "best flat" patch (that parked the rover ~20m away while compose ran).
	var hint := _debug_rover_spawn_hint()
	await _spawn_rover_at_hint(hint, "Debug rover (U)", true)
	_debug_rover_spawn_busy = false


func _player_flat_forward() -> Vector3:
	if _player == null:
		return Vector3.FORWARD
	var forward := -_player.global_transform.basis.z
	if _gravity_field != null:
		var up := _gravity_field.up_at(_player.global_position)
		forward = forward - up * forward.dot(up)
	if forward.length_squared() <= 0.000001:
		var basis := _gravity_field.tangent_basis_at(_player.global_position)
		return -basis.z
	return forward.normalized()


func _debug_rover_spawn_hint() -> Vector3:
	var origin := _player.global_position
	var forward := _player_flat_forward()
	var camera: Camera3D = _player.get_node_or_null("Camera") as Camera3D
	if camera != null and camera.has_method("aim_transform"):
		var aim: Transform3D = camera.call("aim_transform")
		origin = aim.origin
		forward = -aim.basis.z
		if _gravity_field != null:
			var up := _gravity_field.up_at(origin)
			forward = (forward - up * forward.dot(up)).normalized()
			if forward.length_squared() <= 0.000001:
				forward = _player_flat_forward()
	return origin + forward * DEBUG_ROVER_SPAWN_OFFSET_M


func _set_debug_spawn_status(text: String) -> void:
	if _hint != null:
		_hint.text = text


func _spawn_rover_at_hint(
	hint: Vector3,
	label: String,
	immediate_hint: bool = false
) -> void:
	if _session == null:
		push_warning("%s spawn failed: no session" % label)
		return
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	if tool == null:
		push_warning("%s spawn failed: no voxel tool" % label)
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var space := _physics_space_state()
	var ground: Vector3 = Vector3(NAN, NAN, NAN)
	if immediate_hint:
		# Aim point may be mid-air; seat along gravity to the crust first.
		var surface_variant: Variant = RoverDemoSpawn._ground_point_along_field(
			_terrain,
			tool,
			space,
			hint
		)
		ground = surface_variant as Vector3 if surface_variant is Vector3 else hint
	else:
		for _attempt in 30:
			var flat_variant: Variant = RoverDemoSpawn.find_flat_ground_near(
				_terrain,
				tool,
				space,
				hint,
				24.0,
				3.0,
				false
			)
			if flat_variant is Vector3:
				ground = flat_variant as Vector3
				break
			await get_tree().physics_frame
		if not _is_finite_vec3(ground):
			ground = hint
			print("%s: no flat patch, seating at hint" % label)
	if not _is_finite_vec3(ground):
		push_warning("%s spawn failed: no ground near player" % label)
		_set_debug_spawn_status("%s: нет земли под точкой спавна" % label)
		return
	# Wheel locomotives are raycast-supported (solid wheel colliders off).
	# SDF seating before the voxel trimesh cooks → freefall through crust.
	ground = await _await_physics_ground_at(ground, label)
	if not _is_finite_vec3(ground):
		_set_debug_spawn_status("%s: нет physics-коллизии под точкой спавна" % label)
		return
	var phrase := demo_rover_phrase.strip_edges()
	var t0 := Time.get_ticks_msec()
	var result: Dictionary
	if phrase.is_empty():
		# Пустая фраза = дефолтная сборка тем же композером, что и по фразе.
		# Отдельного «демо-ровера» по зашитым клеткам больше нет.
		result = RoverComposer.spawn_on_terrain(
			_session,
			ground,
			null,
			RoverDemoSpawn.STORE_ID,
			_terrain,
			tool,
			space
		)
	else:
		result = RoverComposer.spawn_on_terrain_from_phrase(
			_session,
			ground,
			phrase,
			RoverDemoSpawn.STORE_ID,
			_terrain,
			tool,
			space
		)
	var body_pos := Vector3(NAN, NAN, NAN)
	var assembly_id := int(result.get("assembly_id", 0))
	if bool(result.get("ok", false)) and assembly_id > 0 and _session.projection != null:
		var body := _session.projection.get_physics_body(assembly_id)
		if body != null:
			body_pos = body.global_position
	var dist := (
		_player.global_position.distance_to(body_pos)
		if _is_finite_vec3(body_pos) and _player != null
		else -1.0
	)
	if not bool(result.get("ok", false)):
		push_warning(
			"%s spawn failed: %s %s"
			% [
				label,
				str(result.get("error", "unknown")),
				str(result.get("failures", [])),
			]
		)
		_set_debug_spawn_status(
			"%s FAIL: %s" % [label, str(result.get("error", "unknown"))]
		)
	else:
		print(
			(
				"MoonExperiment: %s spawned assembly_id=%d body=%s "
				+ "dist=%.1fm compose=%dms phrase='%s'"
			)
			% [
				label,
				assembly_id,
				str(body_pos),
				dist,
				Time.get_ticks_msec() - t0,
				phrase,
			]
		)
		_set_debug_spawn_status(
			"U: ровер #%d рядом (%.0fm). Собирался %dms."
			% [assembly_id, dist, Time.get_ticks_msec() - t0]
		)


func _spawn_demo_hopper_near_player() -> void:
	if _session == null or _base_spawn == null:
		return
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	if tool == null:
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var hint := _demo_spawn_hint_offset(Vector3(1.0, 0.0, 0.0), DEMO_HOPPER_OFFSET_M)
	var ground: Vector3 = Vector3(NAN, NAN, NAN)
	for _attempt in 90:
		var ground_variant: Variant = RoverDemoSpawn.find_flat_ground_near(
			_terrain,
			tool,
			_physics_space_state(),
			hint,
			12.0,
			4.0,
			true
		)
		if ground_variant is Vector3:
			ground = ground_variant as Vector3
			break
		await get_tree().physics_frame
	if not _is_finite_vec3(ground):
		push_warning("Demo hopper spawn failed: no flat ground near offset hint")
		return
	ground = await _await_physics_ground_at(ground, "Demo hopper")
	if not _is_finite_vec3(ground):
		return
	var result := HopperDemoSpawn.spawn_on_terrain(
		_session,
		ground,
		HopperDemoSpawn.STORE_ID,
		_terrain,
		tool,
		_physics_space_state()
	)
	if not bool(result.get("ok", false)):
		push_warning(
			"Demo hopper spawn failed: %s"
			% str(result.get("error", "unknown"))
		)
	else:
		print(
			"MoonExperiment: demo hopper spawned assembly_id=%d at %s"
			% [int(result.get("assembly_id", 0)), str(ground)]
		)


func _resync_player_camera() -> void:
	var head: Camera3D = _player.get_node_or_null("Camera") as Camera3D
	if head != null and head.has_method("snap_after_teleport"):
		head.call("snap_after_teleport")


func _finalize_loaded_world_after_entry() -> void:
	if not _world_ready:
		return
	WorldPersistence.finalize_loaded_world(_session.world)
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	if tool == null:
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	RoverDemoSpawn.reseat_parked_locomotives(
		_session,
		_terrain,
		tool,
		_physics_space_state()
	)
	# Un-sintered loose material from last session, back on top of the terrain it
	# was resting on. Only on a loaded world — a fresh one has no heaps to place.
	var granular := get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
	if granular != null:
		granular.load_field(MoonGeometry.granular_save_path())


func _place_when_ground_exists() -> void:
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var probe_origin := MoonGeometry.spawn_hold_point(_player_spawn_hint)
	var probe_dir := _gravity_field.probe_direction_toward_ground(probe_origin)
	_set_spawn_streaming_focus(true)

	while _warmup_frames < MIN_WARMUP_FRAMES:
		_warmup_frames += 1
		var pct: int = int(
			float(_warmup_frames) / float(MIN_WARMUP_FRAMES) * 100.0
		)
		_loading.text = "Загрузка луны... %d%%" % pct
		await get_tree().process_frame

	## Save path first: no "Стриминг луны..." at default spawn, short collider wait.
	if WorldPersistence.has_save() and not _save_load_attempted:
		_save_load_attempted = true
		_loading.text = "Загрузка сохранения..."
		await get_tree().process_frame
		var payload: Dictionary = WorldPersistence.read_payload()
		var simulation: Variant = payload.get("simulation", {})
		if (
			not payload.is_empty()
			and simulation is Dictionary
			and WorldPersistence.restore_snapshot_data(
				_session.world,
				simulation
			)
		):
			WorldPersistence.restore_players_from_payload(payload)
			var player_row := WorldPersistence.player_pose_row(
				PlayerIdentity.local_uid()
			)
			var saved_spawn := _resolve_saved_player_position(
				player_row,
				tool
			)
			_player.global_position = MoonGeometry.spawn_hold_point(saved_spawn)
			await get_tree().physics_frame
			var loaded_spawn := await _resolve_spawn_with_floor(
				MoonGeometry.spawn_hold_point(saved_spawn),
				_gravity_field.probe_direction_toward_ground(saved_spawn),
				saved_spawn,
				PHYSICS_GROUND_TIMEOUT_LOAD_MS
			)
			WorldPersistence.apply_player_view(
				_player,
				player_row,
				loaded_spawn
			)
			WorldPersistence.restore_map_markers_from_payload(payload)
			_finish_loaded_world_entry(loaded_spawn)
			call_deferred("_finalize_loaded_world_after_entry")
			return
		var rejected_backup := WorldPersistence.backup_rejected_save()
		WorldPersistence.clear_map_markers()
		WorldPersistence.clear_players()
		if rejected_backup.is_empty():
			push_warning(
				"Save rejected or corrupt; starting a fresh world."
			)
		else:
			push_warning(
				(
					"Save rejected or corrupt; backed up to %s; "
					+ "starting a fresh world."
				)
				% rejected_backup
			)

	## Fresh world (or rejected save): stream SDF, then wait for physics floor.
	if not WorldPersistence.has_save():
		WorldPersistence.clear_map_markers()
		WorldPersistence.clear_players()
	while true:
		var player_hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
			tool,
			_terrain,
			probe_origin,
			probe_dir,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if player_hit != null:
			var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
				_terrain,
				probe_origin,
				probe_dir,
				player_hit
			)
			var spawn_position := await _resolve_spawn_with_floor(
				probe_origin,
				probe_dir,
				sdf_point,
				PHYSICS_GROUND_TIMEOUT_MS
			)
			await _begin_fresh_world(spawn_position)
			return

		_loading.text = "Стриминг луны..."
		await get_tree().physics_frame


func _ensure_player_viewer_for_planet() -> void:
	var viewer := _find_voxel_viewer()
	if viewer == null:
		return
	viewer.requires_collisions = true
	viewer.requires_visuals = true
	## Effective range is min(terrain, viewer) — keep both at planet budget.
	viewer.view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
	_player_camera = _player.get_node_or_null("Camera") as Camera3D
	_applied_view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS


func _set_spawn_streaming_focus(enabled: bool) -> void:
	## Tight VD during spawn: local mesh/collider first. Full shell after ready.
	if not (_terrain is VoxelLodTerrain):
		return
	var lod := _terrain as VoxelLodTerrain
	var viewer := _find_voxel_viewer()
	var vd := (
		SPAWN_FOCUS_VIEW_DISTANCE_VOXELS
		if enabled
		else MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
	)
	lod.view_distance = vd
	if viewer != null:
		viewer.view_distance = vd
	_applied_view_distance = vd
	if enabled:
		print(
			"MoonExperiment: spawn streaming focus vd=%d collision_lod=%d"
			% [vd, SPAWN_COLLISION_LOD_COUNT]
		)


func _find_voxel_viewer() -> VoxelViewer:
	## On foot: child of player. In a vehicle: reparented to the world root.
	if _player != null:
		var under_player := _player.get_node_or_null("VoxelViewer") as VoxelViewer
		if under_player != null:
			return under_player
	return get_node_or_null("VoxelViewer") as VoxelViewer


func _update_streaming_budget() -> void:
	## Surface: keep the near-field shell small enough that LOD0 under the
	## viewer can finish. Altitude: blend toward |cam|+R so the planet LODs
	## instead of unloading. On Ø19 km, raw |cam|+R on foot was ~22k voxels —
	## the streamer never completed LOD0 outside the spawn-focus bake, so
	## collision_lod_count>1 was the only thing holding the player up.
	if not _world_ready:
		return
	if not (_terrain is VoxelLodTerrain):
		return
	if _player_camera == null:
		if _player != null:
			_player_camera = _player.get_node_or_null("Camera") as Camera3D
		if _player_camera == null:
			return
	var vd := MoonGeometry.view_distance_voxels_for_camera_distance(
		_player_camera.global_position.length()
	)
	if vd == _applied_view_distance:
		return
	_applied_view_distance = vd
	(_terrain as VoxelLodTerrain).view_distance = vd
	var viewer := _find_voxel_viewer()
	if viewer != null:
		viewer.view_distance = vd


func _configure_far_impostor() -> void:
	## Cheap sphere kept inside Camera.far, scaled to the real angular size.
	## Extreme Camera.far is not an option — breaks directional light culling.
	_far_impostor = MeshInstance3D.new()
	_far_impostor.name = "MoonFarImpostor"
	var sphere := SphereMesh.new()
	sphere.radius = MoonGeometry.active_surface_radius_m()
	sphere.height = MoonGeometry.active_surface_radius_m() * 2.0
	sphere.radial_segments = 48
	sphere.rings = 24
	_far_impostor.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.52)
	mat.roughness = 0.96
	mat.metallic = 0.0
	_far_impostor.material_override = mat
	_far_impostor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_far_impostor.visible = false
	add_child(_far_impostor)
	if _player_camera == null and _player != null:
		_player_camera = _player.get_node_or_null("Camera") as Camera3D


func _update_far_impostor() -> void:
	if _far_impostor == null:
		return
	if _player_camera == null:
		if _player != null:
			_player_camera = _player.get_node_or_null("Camera") as Camera3D
		if _player_camera == null:
			_far_impostor.visible = false
			return
	var cam_pos := _player_camera.global_position
	var real_dist := cam_pos.length()
	if real_dist < MoonGeometry.FAR_IMPOSTOR_START_M or real_dist < 1.0:
		_far_impostor.visible = false
		return
	var visual_dist: float = minf(
		MoonGeometry.FAR_IMPOSTOR_VISUAL_DIST_M,
		_player_camera.far * 0.45,
	)
	if visual_dist < 1.0:
		_far_impostor.visible = false
		return
	## Angular size match: R_vis / d_vis = R_real / d_real → scale = d_vis / d_real.
	var toward_planet := -cam_pos / real_dist
	_far_impostor.global_position = cam_pos + toward_planet * visual_dist
	_far_impostor.scale = Vector3.ONE * (visual_dist / real_dist)
	_far_impostor.visible = true


func _peek_saved_player_position() -> Vector3:
	if not WorldPersistence.has_save():
		return Vector3.ZERO
	var payload: Dictionary = WorldPersistence.read_payload()
	if payload.is_empty():
		return Vector3.ZERO
	WorldPersistence.restore_players_from_payload(payload)
	var row := WorldPersistence.player_pose_row(PlayerIdentity.local_uid())
	var position_data: Variant = row.get("position", [])
	if position_data is Array and position_data.size() >= 3:
		return Vector3(
			float(position_data[0]),
			float(position_data[1]),
			float(position_data[2]),
		)
	return Vector3.ZERO


## Host CoopSession last-pose cache for cold `players{}` (guests). Empty offline.
func _coop_extra_player_poses_for_save() -> Dictionary:
	var coop := get_node_or_null("CoopSession")
	if coop == null or not coop.has_method("export_cold_poses"):
		return {}
	var poses: Variant = coop.call("export_cold_poses")
	if poses is Dictionary:
		return poses as Dictionary
	return {}


## Wait until a cooked voxel collider exists under `hint` (SDF alone is not
## enough for raycast-wheel locomotives). Returns physics surface or NaN.
func _await_physics_ground_at(
	hint: Vector3,
	label: String,
	timeout_ms: int = PHYSICS_GROUND_TIMEOUT_MS
) -> Vector3:
	if not _is_finite_vec3(hint) or _gravity_field == null:
		return Vector3(NAN, NAN, NAN)
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction := _gravity_field.probe_direction_toward_ground(origin)
	var wait_start_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start_ms < timeout_ms:
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if _is_finite_vec3(physics_point):
			var waited := Time.get_ticks_msec() - wait_start_ms
			if waited > 0:
				print(
					"MoonExperiment: %s physics ground ready at %s (waited %d ms)"
					% [label, str(physics_point), waited]
				)
			return physics_point
		await get_tree().physics_frame
	push_warning(
		"%s: physics collider not ready near %s after %d ms"
		% [label, str(hint), timeout_ms]
	)
	return Vector3(NAN, NAN, NAN)


func _resolve_spawn_with_floor(
	origin: Vector3,
	direction: Vector3,
	sdf_point: Vector3,
	timeout_ms: int = PHYSICS_GROUND_TIMEOUT_MS
) -> Vector3:
	_loading.text = "Стриминг коллизии луны..."
	var wait_start_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start_ms < timeout_ms:
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if _is_finite_vec3(physics_point):
			print(
				"MoonExperiment: physics ground ready at %s (waited %d ms)"
				% [str(physics_point), Time.get_ticks_msec() - wait_start_ms]
			)
			var up := _gravity_field.up_at(physics_point)
			_player_spawn_pos = (
				physics_point + up * MoonGeometry.SPAWN_CLEARANCE_M
			)
			return _player_spawn_pos
		var meshed_hint := sdf_point if _is_finite_vec3(sdf_point) else origin
		if _is_spawn_area_meshed(meshed_hint):
			_loading.text = "Коллизия луны..."
		else:
			_loading.text = "Стриминг коллизии луны..."
		await get_tree().physics_frame

	var surface := sdf_point
	if not _is_finite_vec3(surface):
		surface = MoonGeometry.surface_point(_player_spawn_hint)
	print(
		"MoonExperiment: voxel collider pending; landing pad at %s (waited %d ms)"
		% [str(surface), timeout_ms]
	)
	_player_spawn_pos = _install_landing_pad(surface)
	return _player_spawn_pos


func _install_landing_pad(surface: Vector3) -> Vector3:
	_remove_landing_pad()
	var up := _gravity_field.up_at(surface)
	var surface_basis := _gravity_field.tangent_basis_at(surface)
	var body := StaticBody3D.new()
	body.name = "MoonLandingPad"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = LANDING_PAD_SIZE_M
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	## Top face of the box sits on the SDF surface.
	body.global_transform = Transform3D(
		surface_basis,
		surface - up * (LANDING_PAD_SIZE_M.y * 0.5)
	)
	_landing_pad = body
	call_deferred("_retire_landing_pad_when_voxel_floor_ready", surface)
	return surface + up * MoonGeometry.SPAWN_CLEARANCE_M


func _remove_landing_pad() -> void:
	if _landing_pad != null and is_instance_valid(_landing_pad):
		_landing_pad.queue_free()
	_landing_pad = null


func _retire_landing_pad_when_voxel_floor_ready(surface: Vector3) -> void:
	var origin := MoonGeometry.spawn_hold_point(surface)
	var direction := _gravity_field.probe_direction_toward_ground(origin)
	var deadline_ms := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline_ms:
		if _landing_pad == null or not is_instance_valid(_landing_pad):
			return
		var exclude: Array[RID] = []
		exclude.append(_landing_pad.get_rid())
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M,
			1,
			exclude
		)
		if _is_finite_vec3(physics_point):
			print(
				"MoonExperiment: voxel floor ready, retiring landing pad at %s"
				% str(physics_point)
			)
			_remove_landing_pad()
			return
		await get_tree().create_timer(0.5).timeout
	push_warning("Landing pad kept: voxel collider never appeared under spawn")


func _is_spawn_area_meshed(world_hint: Vector3) -> bool:
	if not (_terrain is VoxelLodTerrain):
		return false
	var lod := _terrain as VoxelLodTerrain
	var local := VoxelSpaceUtil.world_to_local(_terrain, world_hint)
	var area := AABB(local - Vector3.ONE * 4.0, Vector3.ONE * 8.0)
	return lod.is_area_meshed(area, 0)


func _is_finite_vec3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func _snap_spawn_to_ground(near_position: Vector3) -> Vector3:
	var hint := near_position
	if hint.length_squared() <= 0.000001:
		hint = _player_spawn_hint
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction := _gravity_field.probe_direction_toward_ground(origin)
	var exclude: Array[RID] = []
	if _landing_pad != null and is_instance_valid(_landing_pad):
		exclude.append(_landing_pad.get_rid())
	var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
		_physics_space_state(),
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M,
		1,
		exclude
	)
	var surface := physics_point
	if not _is_finite_vec3(surface):
		## Prefer the temp pad / any collider including the pad.
		surface = VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
	if not _is_finite_vec3(surface):
		var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
		if tool != null:
			tool.channel = VoxelBuffer.CHANNEL_SDF
			var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
				tool,
				_terrain,
				origin,
				direction,
				MoonGeometry.GROUND_PROBE_DISTANCE_M
			)
			if hit != null:
				surface = VoxelSpaceUtil.raycast_hit_world_point(
					_terrain,
					origin,
					direction,
					hit
				)
	if not _is_finite_vec3(surface):
		surface = MoonGeometry.surface_point(hint)
	if _landing_pad == null:
		return _install_landing_pad(surface)
	var up := _gravity_field.up_at(surface)
	return surface + up * MoonGeometry.SPAWN_CLEARANCE_M


func _spawn_position_from_voxel_hit(
	origin: Vector3,
	direction: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
		_terrain,
		origin,
		direction,
		hit
	)
	var surface := VoxelSpaceUtil.resolve_ground_surface_along_ray(
		_physics_space_state(),
		origin,
		direction,
		sdf_point,
		MoonGeometry.GROUND_PROBE_DISTANCE_M
	)
	var up := _gravity_field.up_at(surface)
	_player_spawn_pos = surface + up * MoonGeometry.SPAWN_CLEARANCE_M
	return _player_spawn_pos


func _physics_space_state() -> PhysicsDirectSpaceState3D:
	if _terrain == null or not _terrain.is_inside_tree():
		return null
	return _terrain.get_world_3d().direct_space_state


func _resolve_saved_player_position(
	row: Variant,
	tool: VoxelTool
) -> Vector3:
	if row is Dictionary:
		var position_data: Variant = (row as Dictionary).get("position", [])
		if position_data is Array and position_data.size() >= 3:
			var saved := Vector3(
				float(position_data[0]),
				float(position_data[1]),
				float(position_data[2]),
			)
			if _is_usable_saved_player_position(saved):
				return saved
	var hint := _player_spawn_hint
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction := _gravity_field.probe_direction_toward_ground(origin)
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		_terrain,
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M
	)
	if hit != null:
		return _spawn_position_from_voxel_hit(origin, direction, hit)
	return MoonGeometry.surface_point(hint) + (
		_gravity_field.up_at(hint) * MoonGeometry.SPAWN_CLEARANCE_M
	)


func _is_usable_saved_player_position(pos: Vector3) -> bool:
	if not pos.is_finite():
		return false
	# Reject near-origin flat-world leftovers if a wrong save is loaded.
	if pos.length() < MoonGeometry.active_surface_radius_m() * 0.5:
		return false
	## Relief is active_surface_radius_m ± HEIGHT_CLAMP_M; reject stale saves.
	var min_r := (
		MoonGeometry.active_surface_radius_m()
		- MoonTerrainParams.HEIGHT_CLAMP_M
		- 10.0
	)
	var max_r := (
		MoonGeometry.active_surface_radius_m()
		+ MoonTerrainParams.HEIGHT_CLAMP_M
		+ MoonGeometry.SPAWN_SKY_OFFSET_M
	)
	var r := pos.length()
	if r < min_r or r > max_r:
		return false
	## Reject saved positions sitting on the equirectangular pole pinch (±Y);
	## fall back to the off-pole fresh spawn instead.
	return absf(pos.normalized().y) <= 0.7
