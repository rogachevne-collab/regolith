class_name BootstrapPersistenceService
extends RefCounted

## Must match bootstrap.gd constants.
const DIG_PERSIST_DEBOUNCE_S := 1.5
const DIG_SAVE_TIMEOUT_MS := 15000


static func configure_dig_stream(bootstrap) -> void:
	if not (bootstrap._terrain is VoxelLodTerrain):
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
	bootstrap._voxel_stream = stream
	var lod := bootstrap._terrain as VoxelLodTerrain
	lod.stream = stream
	lod.full_load_mode_enabled = false
	lod.cache_generated_blocks = true
	print(
		"MoonExperiment: planet gen_v%d dig-stream=%s"
		% [MoonTerrainParams.GENERATOR_VERSION, stream.database_path]
	)


static func persist_world(bootstrap, force := false) -> void:
	persist_world_snapshot_only(bootstrap, force)
	if force:
		bootstrap._digs_dirty = true
		bootstrap._dig_persist_cooldown_s = 0.0
		await persist_digs_durable(bootstrap)
	elif bootstrap._digs_dirty and not bootstrap._dig_persist_in_flight:
		bootstrap._dig_persist_cooldown_s = 0.0
		persist_digs_durable(bootstrap)


static func persist_world_snapshot_only(bootstrap, force := false) -> void:
	# Client of a coop host: never write the replicated world to the local save.
	if bootstrap._coop_persistence_inhibited:
		return
	if not bootstrap._world_ready or bootstrap._session == null:
		return
	if (
		bootstrap._player == null
		or not is_instance_valid(bootstrap._player)
		or not bootstrap._player.is_inside_tree()
	):
		return
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - bootstrap._last_save_ms < 5000:
		return
	if WorldPersistence.save(
		bootstrap._session.world,
		bootstrap._player,
		coop_extra_player_poses_for_save(bootstrap)
	):
		bootstrap._last_save_ms = now_ms
	persist_granular(bootstrap)


## Save the un-sintered loose material beside the world snapshot, on the same
## cadence. Sintered material is already rock and saves with the terrain.
static func persist_granular(bootstrap) -> void:
	var granular := bootstrap.get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
	if granular != null:
		granular.save_field(MoonGeometry.granular_save_path())


static func request_quit_after_persist(bootstrap) -> void:
	bootstrap._quit_after_dig_persist = true
	persist_world_snapshot_only(bootstrap, true)
	bootstrap._digs_dirty = true
	bootstrap._dig_persist_cooldown_s = 0.0
	if bootstrap._dig_persist_in_flight:
		return
	persist_digs_durable(bootstrap)


## save_modified_blocks (async) → wait tracker → flush once.
## Avoids SQLite lock spam and incomplete cave walls on reload.
## DIG-01: a caller that finds a save already in flight must not return before
## it actually completes (waits below) — an early return here let a coop join
## capture stale sqlite while another flush was still writing.
static func persist_digs_durable(bootstrap) -> void:
	if bootstrap._dig_persist_in_flight:
		while bootstrap._dig_persist_in_flight:
			await bootstrap.get_tree().process_frame
		return
	# Coop client: skip the SQLite dig flush too, but still honor a pending quit
	# so leaving/closing never hangs.
	if (
		not bootstrap.persist_digs
		or not (bootstrap._terrain is VoxelLodTerrain)
		or bootstrap._coop_persistence_inhibited
	):
		if bootstrap._quit_after_dig_persist:
			bootstrap.get_tree().quit()
		return
	bootstrap._dig_persist_in_flight = true
	var lod := bootstrap._terrain as VoxelLodTerrain
	while true:
		bootstrap._digs_dirty = false
		var tracker: VoxelSaveCompletionTracker = lod.save_modified_blocks()
		if tracker != null:
			var deadline_ms := Time.get_ticks_msec() + DIG_SAVE_TIMEOUT_MS
			while (
				bootstrap.is_inside_tree()
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
				await bootstrap.get_tree().process_frame
		if bootstrap._voxel_stream != null:
			bootstrap._voxel_stream.flush()
		if not bootstrap._digs_dirty:
			break
	bootstrap._dig_persist_in_flight = false
	if bootstrap._quit_after_dig_persist:
		bootstrap.get_tree().quit()


static func on_terrain_modified(
	bootstrap,
	_removed_volume_m3: float,
	_dig_center: Vector3,
	_dig_radius_m: float,
	_dig_direction: Vector3
) -> void:
	bootstrap._digs_dirty = true
	bootstrap._dig_persist_cooldown_s = DIG_PERSIST_DEBOUNCE_S


## Sintered granular material wrote solid into the rock SDF. Same durability
## path as a carve — the plugin already marked the touched blocks modified, this
## just tells the autosave loop to flush them.
static func on_terrain_deposited(
	bootstrap,
	_deposit_center: Vector3,
	_deposit_radius_m: float
) -> void:
	bootstrap._digs_dirty = true
	bootstrap._dig_persist_cooldown_s = DIG_PERSIST_DEBOUNCE_S


## Host: bytes of moon.sqlite + live granular snapshot for join bulk.
## Call after flush_digs_for_coop_join. Empty sqlite when no dig stream file.
static func capture_coop_terrain_bulk(bootstrap) -> Dictionary:
	var sqlite := PackedByteArray()
	var db_path := MoonTerrainParams.stream_database_path()
	if FileAccess.file_exists(db_path):
		sqlite = FileAccess.get_file_as_bytes(db_path)
	var granular := {}
	var granular_world := bootstrap.get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
	if granular_world != null and granular_world.has_method(&"capture_field_snapshot"):
		granular = granular_world.capture_field_snapshot()
	return {"sqlite": sqlite, "granular": granular}


## Client: write host dig DB to a session replica (not personal gen_vN), swap
## terrain.stream onto it, kick viewers so loaded shells re-read digs. Granular
## restore is memory-only — persistence stays inhibited.
static func apply_coop_terrain_bulk(
	bootstrap,
	sqlite_bytes: PackedByteArray,
	granular: Dictionary
) -> bool:
	if not (bootstrap._terrain is VoxelLodTerrain):
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
		var lod := bootstrap._terrain as VoxelLodTerrain
		lod.stream = stream
		bootstrap._voxel_stream = stream
		kick_voxel_viewers_for_stream_reload(bootstrap)
		applied_db = true
		print(
			"Coop: applied host dig-stream bulk (%d bytes) → %s"
			% [sqlite_bytes.size(), replica_path]
		)
	if not granular.is_empty():
		var granular_world := bootstrap.get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
		if granular_world != null and granular_world.has_method(&"restore_field_snapshot"):
			var n: int = int(granular_world.restore_field_snapshot(granular))
			print("Coop: restored %d granular region(s) from host bulk" % n)
	return applied_db or not granular.is_empty()


static func kick_voxel_viewers_for_stream_reload(bootstrap) -> void:
	## Client join only needs the local viewer — host proxies are host-side.
	var viewer: VoxelViewer = bootstrap._find_voxel_viewer()
	if viewer == null:
		return
	var dist: int = viewer.view_distance
	viewer.view_distance = maxi(dist / 4, 8)
	viewer.view_distance = dist


## Host CoopSession last-pose cache for cold `players{}` (guests). Empty offline.
static func coop_extra_player_poses_for_save(bootstrap) -> Dictionary:
	var coop: Node = bootstrap.get_node_or_null("CoopSession")
	if coop == null or not coop.has_method("export_cold_poses"):
		return {}
	var poses: Variant = coop.call("export_cold_poses")
	if poses is Dictionary:
		return poses as Dictionary
	return {}
