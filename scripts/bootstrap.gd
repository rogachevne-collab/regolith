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
## «На новых» = пара колесо+подвеска, испечённая визардом (authored). Компактный
## 6-колёсный ровер с минимальным декором — меньше масса и шум на старте.
@export var demo_rover_phrase := "компактный ровер на 6 колёс, короткий, низкий, минимальный декор"
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
var _debug_platform_spawn_busy := false
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
	await BootstrapPersistenceService.persist_world(self, true)
	_coop_persistence_inhibited = true


## Host join catch-up: push pending digs to SQLite before reading the file for
## CH_BULK. Does not touch world JSON / granular sidecar cadence beyond digs.
func flush_digs_for_coop_join() -> void:
	if _coop_persistence_inhibited:
		return
	_digs_dirty = true
	_dig_persist_cooldown_s = 0.0
	await BootstrapPersistenceService.persist_digs_durable(self)


## Host: bytes of moon.sqlite + live granular snapshot for join bulk.
## Call after flush_digs_for_coop_join. Empty sqlite when no dig stream file.
func capture_coop_terrain_bulk() -> Dictionary:
	return BootstrapPersistenceService.capture_coop_terrain_bulk(self)


## Client: write host dig DB to a session replica (not personal gen_vN), swap
## terrain.stream onto it, kick viewers so loaded shells re-read digs. Granular
## restore is memory-only — persistence stays inhibited.
func apply_coop_terrain_bulk(sqlite_bytes: PackedByteArray, granular: Dictionary) -> bool:
	return BootstrapPersistenceService.apply_coop_terrain_bulk(
		self, sqlite_bytes, granular
	)


## Re-drop the local player near a world point using the existing settle
## machinery (COOP-HOST-V0 join: land the client next to the host). Async.
func reseat_player_near(target_world: Vector3) -> void:
	await BootstrapSpawnSettleService.reseat_player_near(self, target_world)


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
		_player_spawn_hint = BootstrapTerrainSetupService.away_from_pole(_player_spawn_hint).normalized()
	## Point VoxelViewer at the saved spot from frame 0 so stream isn't at
	## the default spawn while we still intend to load.
	var early_saved := BootstrapSpawnSettleService.peek_saved_player_position(self)
	if BootstrapSpawnSettleService.is_usable_saved_player_position(early_saved):
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
	BootstrapTerrainSetupService.update_streaming_budget(self)
	BootstrapTerrainSetupService.update_far_impostor(self)
	if _world_ready:
		_autosave_accum += delta
		if _autosave_accum >= AUTOSAVE_INTERVAL_S:
			_autosave_accum = 0.0
			BootstrapPersistenceService.persist_world(self)
		if _digs_dirty and not _dig_persist_in_flight:
			if _dig_persist_cooldown_s > 0.0:
				_dig_persist_cooldown_s -= delta
			if _dig_persist_cooldown_s <= 0.0:
				BootstrapPersistenceService.persist_digs_durable(self)
		# Poll action: _unhandled_input is often eaten by HUD/focus while
		# mouse is captured; same pattern as gameplay move axes.
		if (
			not _debug_rover_spawn_busy
			and Input.is_action_just_pressed(&"spawn_debug_rover")
		):
			BootstrapDemoSpawnService.spawn_debug_rover_near_player(self)
		if (
			not _debug_platform_spawn_busy
			and Input.is_action_just_pressed(&"spawn_debug_platform")
		):
			BootstrapDemoSpawnService.spawn_debug_platform_near_player(self)
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
		BootstrapPersistenceService.request_quit_after_persist(self)
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		BootstrapPersistenceService.persist_world(self, true)


func _exit_tree() -> void:
	## Best-effort if Stop/kill skipped WM_CLOSE; no flush race here.
	BootstrapPersistenceService.persist_world_snapshot_only(self, true)
	if (
		persist_digs
		and _terrain is VoxelLodTerrain
		and _digs_dirty
		and not _coop_persistence_inhibited
	):
		(_terrain as VoxelLodTerrain).save_modified_blocks()
	WorldPersistence.save_path_override = ""


func _configure_terrain() -> void:
	BootstrapTerrainSetupService.configure_terrain(self)


func _apply_terrain_debug_draw(lod: VoxelLodTerrain) -> void:
	BootstrapTerrainSetupService.apply_terrain_debug_draw(self, lod)


func _apply_planet_terrain_shader_params(shader_mat: ShaderMaterial) -> void:
	BootstrapTerrainSetupService.apply_planet_terrain_shader_params(self, shader_mat)


func _apply_brightness_map(shader_mat: ShaderMaterial) -> void:
	BootstrapTerrainSetupService.apply_brightness_map(self, shader_mat)


func _make_planet_generator() -> VoxelGenerator:
	if use_native_sdf:
		var native := _NativeSdfGen.new(MoonGeometry.radius_voxels())
		if native.is_native_ready():
			_generator_is_native = true
			_native_generator = native
			print("MoonExperiment: native SDF generator — %s" % native.describe())
			BootstrapTerrainSetupService.print_nearest_cave_entrances(self, native)
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
	BootstrapTerrainSetupService.schedule_map_heightmap_bake(self)


func _away_from_pole(dir: Vector3) -> Vector3:
	return BootstrapTerrainSetupService.away_from_pole(dir)


func _print_nearest_cave_entrances(native: Object) -> void:
	BootstrapTerrainSetupService.print_nearest_cave_entrances(self, native)


func _configure_dig_stream() -> void:
	BootstrapPersistenceService.configure_dig_stream(self)


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
	BootstrapDemoSpawnService.sync_demo_spawn_anchor(self)


func _demo_spawn_hint_offset(local_axis: Vector3, offset_m: float) -> Vector3:
	return BootstrapDemoSpawnService.demo_spawn_hint_offset(self, local_axis, offset_m)


func _persist_world(force := false) -> void:
	await BootstrapPersistenceService.persist_world(self, force)


func _persist_world_snapshot_only(force := false) -> void:
	BootstrapPersistenceService.persist_world_snapshot_only(self, force)


func _persist_granular() -> void:
	BootstrapPersistenceService.persist_granular(self)


func _request_quit_after_persist() -> void:
	BootstrapPersistenceService.request_quit_after_persist(self)


func _persist_digs_durable() -> void:
	await BootstrapPersistenceService.persist_digs_durable(self)


func _on_terrain_modified(
	_removed_volume_m3: float,
	_dig_center: Vector3,
	_dig_radius_m: float,
	_dig_direction: Vector3
) -> void:
	BootstrapPersistenceService.on_terrain_modified(
		self,
		_removed_volume_m3,
		_dig_center,
		_dig_radius_m,
		_dig_direction
	)


func _on_terrain_deposited(
	_deposit_center: Vector3,
	_deposit_radius_m: float
) -> void:
	BootstrapPersistenceService.on_terrain_deposited(
		self, _deposit_center, _deposit_radius_m
	)


func _begin_fresh_world(player_position: Vector3) -> void:
	await BootstrapSpawnSettleService.begin_fresh_world(self, player_position)


func _finish_world_entry(player_position: Vector3) -> void:
	await BootstrapSpawnSettleService.finish_world_entry(self, player_position)


func _finish_loaded_world_entry(spawn_position: Vector3) -> void:
	BootstrapSpawnSettleService.finish_loaded_world_entry(self, spawn_position)


func _align_sun_day_at(world_position: Vector3) -> void:
	BootstrapSpawnSettleService.align_sun_day_at(self, world_position)


func _apply_playtest_cargo_if_enabled() -> void:
	BootstrapDemoSpawnService.apply_playtest_cargo_if_enabled(self)


func _spawn_lamp_poles_near_player() -> void:
	BootstrapDemoSpawnService.spawn_lamp_poles_near_player(self)


func _spawn_demo_rover_near_player() -> void:
	await BootstrapDemoSpawnService.spawn_demo_rover_near_player(self)


func _spawn_debug_rover_near_player() -> void:
	await BootstrapDemoSpawnService.spawn_debug_rover_near_player(self)


func _player_flat_forward() -> Vector3:
	return BootstrapDemoSpawnService.player_flat_forward(self)


func _debug_rover_spawn_hint() -> Vector3:
	return BootstrapDemoSpawnService.debug_rover_spawn_hint(self)


func _set_debug_spawn_status(text: String) -> void:
	BootstrapDemoSpawnService.set_debug_spawn_status(self, text)


func _spawn_rover_at_hint(
	hint: Vector3,
	label: String,
	immediate_hint: bool = false
) -> void:
	await BootstrapDemoSpawnService.spawn_rover_at_hint(
		self, hint, label, immediate_hint
	)


func _spawn_demo_hopper_near_player() -> void:
	await BootstrapDemoSpawnService.spawn_demo_hopper_near_player(self)


func _resync_player_camera() -> void:
	BootstrapSpawnSettleService.resync_player_camera(self)


func _finalize_loaded_world_after_entry() -> void:
	BootstrapSpawnSettleService.finalize_loaded_world_after_entry(self)


func _place_when_ground_exists() -> void:
	await BootstrapSpawnSettleService.place_when_ground_exists(self)


func _ensure_player_viewer_for_planet() -> void:
	BootstrapTerrainSetupService.ensure_player_viewer_for_planet(self)


func _set_spawn_streaming_focus(enabled: bool) -> void:
	BootstrapTerrainSetupService.set_spawn_streaming_focus(self, enabled)


func _find_voxel_viewer() -> VoxelViewer:
	return BootstrapTerrainSetupService.find_voxel_viewer(self)


func _update_streaming_budget() -> void:
	BootstrapTerrainSetupService.update_streaming_budget(self)


func _configure_far_impostor() -> void:
	BootstrapTerrainSetupService.configure_far_impostor(self)


func _update_far_impostor() -> void:
	BootstrapTerrainSetupService.update_far_impostor(self)


func _peek_saved_player_position() -> Vector3:
	return BootstrapSpawnSettleService.peek_saved_player_position(self)


## Host CoopSession last-pose cache for cold `players{}` (guests). Empty offline.
func _coop_extra_player_poses_for_save() -> Dictionary:
	return BootstrapPersistenceService.coop_extra_player_poses_for_save(self)


func _await_physics_ground_at(
	hint: Vector3,
	label: String,
	timeout_ms: int = PHYSICS_GROUND_TIMEOUT_MS
) -> Vector3:
	return await BootstrapSpawnSettleService.await_physics_ground_at(
		self, hint, label, timeout_ms
	)


func _resolve_spawn_with_floor(
	origin: Vector3,
	direction: Vector3,
	sdf_point: Vector3,
	timeout_ms: int = PHYSICS_GROUND_TIMEOUT_MS
) -> Vector3:
	return await BootstrapSpawnSettleService.resolve_spawn_with_floor(
		self, origin, direction, sdf_point, timeout_ms
	)


func _install_landing_pad(surface: Vector3) -> Vector3:
	return BootstrapSpawnSettleService.install_landing_pad(self, surface)


func _remove_landing_pad() -> void:
	BootstrapSpawnSettleService.remove_landing_pad(self)


func _retire_landing_pad_when_voxel_floor_ready(surface: Vector3) -> void:
	await BootstrapSpawnSettleService.retire_landing_pad_when_voxel_floor_ready(
		self, surface
	)


func _is_spawn_area_meshed(world_hint: Vector3) -> bool:
	return BootstrapSpawnSettleService.is_spawn_area_meshed(self, world_hint)


func _is_finite_vec3(v: Vector3) -> bool:
	return BootstrapSpawnSettleService.is_finite_vec3(v)


func _snap_spawn_to_ground(near_position: Vector3) -> Vector3:
	return BootstrapSpawnSettleService.snap_spawn_to_ground(self, near_position)


func _spawn_position_from_voxel_hit(
	origin: Vector3,
	direction: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	return BootstrapSpawnSettleService.spawn_position_from_voxel_hit(
		self, origin, direction, hit
	)


func _physics_space_state() -> PhysicsDirectSpaceState3D:
	return BootstrapSpawnSettleService.physics_space_state(self)


func _resolve_saved_player_position(
	row: Variant,
	tool: VoxelTool
) -> Vector3:
	return BootstrapSpawnSettleService.resolve_saved_player_position(self, row, tool)


func _is_usable_saved_player_position(pos: Vector3) -> bool:
	return BootstrapSpawnSettleService.is_usable_saved_player_position(pos)
