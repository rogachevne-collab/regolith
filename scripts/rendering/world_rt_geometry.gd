extends Node
class_name WorldRtGeometry
## Camera-relative world TLAS from VoxelLodTerrain *visual* mesh blocks.
## Versioned snapshot staging + double-buffered TLAS swap: old committed
## geometry stays live until a complete, overlap-free candidate is READY.
## Exact Transvoxel bake (CUSTOM0 + transition mask) via ViewmodelRtMesh.

const LABEL := "WorldRtGeometry"
const MAX_TLAS_INSTANCES := 2048
const MAX_BLAS_BUILDS_PER_FRAME := 8
## Throughput only — finish a valid generation between remesh storms.
## Not used as LOD synchronization / leopard hiding.
const MAX_BLAS_BUILDS_CATCHUP := 64
const RAY_SPAN_M := 96.0
const BOOTSTRAP_INTERVAL_S := 1.0
const MESH_STALE_S := 1.0
## Coalesce remesh/dig dirty hints; topology commits still restage immediately.
const CONTENT_RESTAGE_QUIET_FRAMES := 4
## Even if remesh signals keep resetting the quiet window, force a restage.
const CONTENT_RESTAGE_MAX_FRAMES := 20
## Backoff after an incomplete candidate (BLAS bake failure) — no per-frame spin.
const BAKE_FAIL_RETRY_FRAMES := 30
## Restage when camera crosses this many LOD0 mesh-block cells (Chebyshev).
const SPAN_CELL_RESTAGE_THRESHOLD := 1
## Active visual LODs only (inactive shells must never enter TLAS).
const MAX_RT_LOD := 2
const DIAG_CAP := 24

@export var enabled := true
@export var camera_path: NodePath = ^""
@export var terrain_path: NodePath = ^"/root/Main/VoxelTerrain"
@export var extra_mesh_roots: Array[NodePath] = []
@export var sun_path: NodePath = ^"/root/Main/DirectionalLight3D"

var rt_available := false
var _rd: RenderingDevice
var _camera: Camera3D
var _terrain: Node
var _sun: DirectionalLight3D
var _signals_hooked := false
var _use_mesh_block_api := false
var _use_topology_api := false

## Double-buffered world TLAS. Both RIDs live until shutdown.
var _tlas: Array[RID] = [RID(), RID()]
var _tlas_active_idx := 0
var _tlas_registered := false

## Committed visual snapshot currently published into the active TLAS.
## key -> { blas, buffers..., local_origin, content_hash, block_pos, lod }
var _committed_visual: Dictionary = {}
var _committed_revision := 0
var _committed_generation := 0

## Staging candidate built from a post-commit (or remesh) active snapshot.
var _staging_visual: Dictionary = {}
var _staging_revision := 0
var _staging_generation := 0
var _staging_pending: Array[Dictionary] = []
var _staging_active := false

## Coalesced dirty hints from per-block signals (not snapshot boundaries).
## Remesh/dig during staging invalidates that generation immediately; restart
## only after the quiet window (topology commit preempts and restarts now).
var _content_dirty := false
var _deferred_content_restage := false
var _frames_since_content_signal := 1000
## Frame when content first went dirty (not reset by further remesh signals).
var _content_dirty_since_frame := -1
## Keys whose visual mesh changed/removed — evict from committed immediately
## so dig holes never keep a stale RT lid while staging catches up.
var _dirty_keys: Dictionary = {}
var _topology_commit_pending := false
var _pending_topology_revision := 0
var _last_topology_revision := 0
var _bake_retry_after_frame := 0
var _span_restage_pending := false
var _last_span_cell := Vector3i(0x7fffffff, 0x7fffffff, 0x7fffffff)
var _committed_needs_rebuild := false

## { free_after_frame: int, bundles: Array[Dictionary] }
var _retire_queue: Array[Dictionary] = []

var _mesh_blas: Dictionary = {}
var _bootstrap_left := 0.0
var _frame := 0
var _now_s := 0.0
var _last_instance_count := -1
var _last_good_instance_count := 0
var _status_prints := 0
var _overlap_rejects := 0
var _bake_rejects := 0
var _stale_invalidations := 0
var _publish_count := 0


func _ready() -> void:
	_rd = RenderingServer.get_rendering_device()
	rt_available = (
		_rd != null
		and _rd.has_feature(RenderingDevice.SUPPORTS_RAY_QUERY)
		and _rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	)
	if not rt_available:
		print("%s: RT/ray-query unavailable — soft-disabled" % LABEL)
		return
	_camera = get_node_or_null(camera_path) as Camera3D
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
	_resolve_terrain()
	_sun = get_node_or_null(sun_path) as DirectionalLight3D
	var flags := RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT
	_tlas[0] = _rd.tlas_create(MAX_TLAS_INSTANCES, flags)
	_tlas[1] = _rd.tlas_create(MAX_TLAS_INSTANCES, flags)
	if not _tlas[0].is_valid() or not _tlas[1].is_valid():
		push_warning("%s: tlas_create failed" % LABEL)
		rt_available = false
		return
	_hook_terrain_signals()
	print("%s: ready (tlas ok, mesh_block_api=%s topology_api=%s)" % [
		LABEL, _use_mesh_block_api, _use_topology_api
	])


func _exit_tree() -> void:
	_unhook_terrain_signals()
	_free_all()


func _process(delta: float) -> void:
	if not rt_available or not enabled:
		return
	_frame += 1
	_now_s = Time.get_ticks_msec() * 0.001
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return
	_resolve_terrain()
	_hook_terrain_signals()
	_process_retire_queue()
	_check_camera_span_footprint()
	_bootstrap_left -= delta
	if _bootstrap_left <= 0.0:
		_bootstrap_left = BOOTSTRAP_INTERVAL_S
		if _use_mesh_block_api:
			_bootstrap_check()
		_ensure_extra_mesh_blas()
	# Evict lids before staging so a new candidate cannot reuse dirty BLAS RIDs
	# that we are about to retire.
	_evict_dirty_from_committed()
	_flush_staging_triggers()
	_build_pending_staging_budget()
	_try_publish_staging()
	_rebuild_active_tlas()


func _resolve_terrain() -> void:
	if _terrain != null and is_instance_valid(_terrain):
		return
	_terrain = get_node_or_null(terrain_path)
	if _terrain == null:
		_terrain = get_tree().root.find_child("VoxelTerrain", true, false)
	_signals_hooked = false
	_use_mesh_block_api = false
	_use_topology_api = false


func _hook_terrain_signals() -> void:
	if _signals_hooked or _terrain == null or not is_instance_valid(_terrain):
		return
	_use_mesh_block_api = (
		_terrain.has_method("get_mesh_block_surface")
		and _terrain.has_method("get_meshed_block_positions_at_lod")
		and _terrain.has_method("mesh_block_local_origin")
		and _terrain.has_method("get_mesh_block_transition_mask")
		and _terrain.has_signal("mesh_block_visual_changed")
	)
	_use_topology_api = (
		_use_mesh_block_api
		and _terrain.has_method("get_mesh_visual_topology_revision")
		and _terrain.has_signal("mesh_block_visual_topology_committed")
	)
	if not _use_mesh_block_api:
		if _status_prints < 3:
			push_warning("%s: mesh-block API missing — rebuild libvoxel double DLL" % LABEL)
			_status_prints += 1
		return
	if not _terrain.mesh_block_visual_changed.is_connected(_on_mesh_block_visual_changed):
		_terrain.mesh_block_visual_changed.connect(_on_mesh_block_visual_changed)
	if not _terrain.mesh_block_visual_removed.is_connected(_on_mesh_block_visual_removed):
		_terrain.mesh_block_visual_removed.connect(_on_mesh_block_visual_removed)
	if _use_topology_api:
		if not _terrain.mesh_block_visual_topology_committed.is_connected(
			_on_mesh_block_visual_topology_committed
		):
			_terrain.mesh_block_visual_topology_committed.connect(
				_on_mesh_block_visual_topology_committed
			)
		_last_topology_revision = int(_terrain.call("get_mesh_visual_topology_revision"))
	elif _status_prints < 6:
		push_warning("%s: topology commit API missing — rebuild libvoxel double DLL" % LABEL)
		_status_prints += 1
	_signals_hooked = true


func _unhook_terrain_signals() -> void:
	if _terrain == null or not is_instance_valid(_terrain) or not _signals_hooked:
		_signals_hooked = false
		return
	if _terrain.mesh_block_visual_changed.is_connected(_on_mesh_block_visual_changed):
		_terrain.mesh_block_visual_changed.disconnect(_on_mesh_block_visual_changed)
	if _terrain.mesh_block_visual_removed.is_connected(_on_mesh_block_visual_removed):
		_terrain.mesh_block_visual_removed.disconnect(_on_mesh_block_visual_removed)
	if (
		_terrain.has_signal("mesh_block_visual_topology_committed")
		and _terrain.mesh_block_visual_topology_committed.is_connected(
			_on_mesh_block_visual_topology_committed
		)
	):
		_terrain.mesh_block_visual_topology_committed.disconnect(
			_on_mesh_block_visual_topology_committed
		)
	_signals_hooked = false


## Collision-free key (XOR int hashes collided under dense LOD shells).
func _chunk_key(block_pos: Vector3i, lod: int) -> String:
	return "%d:%d:%d:%d" % [block_pos.x, block_pos.y, block_pos.z, lod]


func _on_mesh_block_visual_topology_committed(revision: int) -> void:
	_topology_commit_pending = true
	_pending_topology_revision = int(revision)
	_last_topology_revision = int(revision)


func _on_mesh_block_visual_changed(block_pos: Vector3i, lod_index: int) -> void:
	if lod_index < 0 or lod_index > MAX_RT_LOD:
		return
	# Dirty hint only — never publish from mid-transaction per-block events.
	_mark_content_dirty(_chunk_key(block_pos, lod_index))


func _on_mesh_block_visual_removed(block_pos: Vector3i, lod_index: int) -> void:
	if lod_index < 0 or lod_index > MAX_RT_LOD:
		return
	_mark_content_dirty(_chunk_key(block_pos, lod_index))


func _mark_content_dirty(key: String) -> void:
	_dirty_keys[key] = true
	_content_dirty = true
	_frames_since_content_signal = 0
	if _content_dirty_since_frame < 0:
		_content_dirty_since_frame = _frame
	# New content supersedes bake-failure backoff.
	_bake_retry_after_frame = 0


## Drop stale BLAS lids immediately. Staging still builds the replacement;
## until publish, a hole (CSM) beats a phantom RT shadow over a dig.
func _evict_dirty_from_committed() -> void:
	if _dirty_keys.is_empty() or _committed_visual.is_empty():
		return
	var retired: Array[Dictionary] = []
	for key in _dirty_keys.keys():
		if not _committed_visual.has(key):
			continue
		var old_e: Dictionary = _committed_visual[key]
		_committed_visual.erase(key)
		retired.append(old_e)
		_committed_needs_rebuild = true
	if retired.is_empty():
		return
	var delay := 1
	if _rd != null:
		delay = maxi(1, int(_rd.get_frame_delay()))
	_retire_queue.append({
		"free_after_frame": _frame + delay,
		"bundles": retired,
	})
	if _status_prints < DIAG_CAP:
		_status_prints += 1
		print(
			"%s: evict dirty lids=%d committed_left=%d"
			% [LABEL, retired.size(), _committed_visual.size()]
		)


## Drop the current staging generation without touching committed / active TLAS.
## Stage-owned BLAS retire once; reused committed RIDs are left alone.
func _invalidate_staging(reason: String) -> void:
	if not _staging_active and _staging_visual.is_empty() and _staging_pending.is_empty():
		return
	var gen := _staging_generation
	_dispose_staging_unique_bundles()
	_staging_pending.clear()
	_staging_visual.clear()
	_staging_active = false
	# Bump so any bake already popped this frame cannot publish under the old gen.
	_staging_generation += 1
	_stale_invalidations += 1
	if _status_prints < DIAG_CAP:
		_status_prints += 1
		print(
			"%s: invalidate staging gen=%d reason=%s (committed rev=%d stays live)"
			% [LABEL, gen, reason, _committed_revision]
		)


func _current_topology_revision() -> int:
	var rev := _last_topology_revision
	if _use_topology_api and _terrain != null and is_instance_valid(_terrain):
		rev = int(_terrain.call("get_mesh_visual_topology_revision"))
		_last_topology_revision = rev
	return rev


func _flush_staging_triggers() -> void:
	if not _use_mesh_block_api:
		return
	_frames_since_content_signal += 1
	# Topology commit always preempts quiet-window / bake backoff.
	if _topology_commit_pending:
		var rev := _pending_topology_revision
		_topology_commit_pending = false
		_content_dirty = false
		_deferred_content_restage = false
		_span_restage_pending = false
		_bake_retry_after_frame = 0
		_content_dirty_since_frame = -1
		_begin_staging(rev)
		return
	# Remesh/dig while staging: kill this generation before build/publish run.
	if _staging_active and _content_dirty:
		_content_dirty = false
		_deferred_content_restage = true
		_invalidate_staging("content dirty")
		return
	if _staging_active:
		return
	# Camera near-field footprint changed — restage immediately (reuse keeps it cheap).
	if _span_restage_pending:
		_span_restage_pending = false
		_content_dirty = false
		_begin_staging(_current_topology_revision())
		return
	if not _content_dirty and not _deferred_content_restage:
		return
	if _frame < _bake_retry_after_frame:
		return
	var quiet_ok := _frames_since_content_signal >= CONTENT_RESTAGE_QUIET_FRAMES
	var max_wait := (
		_content_dirty_since_frame >= 0
		and (_frame - _content_dirty_since_frame) >= CONTENT_RESTAGE_MAX_FRAMES
	)
	if not quiet_ok and not max_wait:
		return
	_content_dirty = false
	_deferred_content_restage = false
	_content_dirty_since_frame = -1
	_begin_staging(_current_topology_revision())


func _mesh_block_size_voxels() -> int:
	if _terrain != null and is_instance_valid(_terrain) and _terrain.has_method("get_mesh_block_size"):
		return maxi(int(_terrain.call("get_mesh_block_size")), 1)
	return 16


func _camera_span_cell() -> Vector3i:
	if _camera == null or _terrain == null or not is_instance_valid(_terrain):
		return _last_span_cell
	var local := (_terrain as Node3D).to_local(_camera.global_position)
	var bs := float(_mesh_block_size_voxels())
	return Vector3i(
		int(floor(local.x / bs)),
		int(floor(local.y / bs)),
		int(floor(local.z / bs))
	)


func _chebyshev_i(a: Vector3i, b: Vector3i) -> int:
	return maxi(maxi(absi(a.x - b.x), absi(a.y - b.y)), absi(a.z - b.z))


func _check_camera_span_footprint() -> void:
	if not _use_mesh_block_api or _camera == null or _terrain == null:
		return
	var cell := _camera_span_cell()
	if _last_span_cell.x == 0x7fffffff:
		_last_span_cell = cell
		return
	if _chebyshev_i(cell, _last_span_cell) < SPAN_CELL_RESTAGE_THRESHOLD:
		return
	_last_span_cell = cell
	_span_restage_pending = true
	# In-flight candidate was captured for a different near-field footprint.
	if _staging_active:
		_invalidate_staging("camera span")


func _bootstrap_check() -> void:
	if _terrain == null or _camera == null:
		return
	if _terrain.has_method("is_area_meshed"):
		var local := (_terrain as Node3D).to_local(_camera.global_position)
		var area := AABB(local - Vector3.ONE * 16.0, Vector3.ONE * 32.0)
		var meshed := false
		if _terrain is VoxelLodTerrain:
			meshed = bool(_terrain.call("is_area_meshed", area, 0))
		else:
			meshed = bool(_terrain.call("is_area_meshed", area))
		if not meshed:
			return
	if _use_topology_api:
		var rev := int(_terrain.call("get_mesh_visual_topology_revision"))
		if rev != _last_topology_revision:
			_last_topology_revision = rev
			_topology_commit_pending = true
			_pending_topology_revision = rev
			return
	# Initial fill / recover if nothing committed and nothing staging.
	if _committed_visual.is_empty() and not _staging_active and not _deferred_content_restage:
		_deferred_content_restage = true
		_frames_since_content_signal = CONTENT_RESTAGE_QUIET_FRAMES


func _begin_staging(topology_revision: int) -> void:
	if _terrain == null or _camera == null:
		return
	# Quietly replace any prior candidate; committed TLAS stays live.
	if _staging_active or not _staging_visual.is_empty() or not _staging_pending.is_empty():
		_dispose_staging_unique_bundles()
		_staging_pending.clear()
		_staging_visual.clear()
		_staging_active = false
	_staging_generation += 1
	var gen := _staging_generation
	_staging_revision = topology_revision
	_staging_active = true
	_last_span_cell = _camera_span_cell()
	_span_restage_pending = false

	var max_lod := 0
	if _terrain.has_method("get_lod_count"):
		max_lod = mini(MAX_RT_LOD, maxi(int(_terrain.call("get_lod_count")) - 1, 0))

	var reused := 0
	var need_build := 0
	var omitted_empty := 0
	for lod in range(max_lod + 1):
		var positions: Array = _terrain.call("get_meshed_block_positions_at_lod", lod)
		for pos_v in positions:
			if typeof(pos_v) != TYPE_VECTOR3I:
				continue
			var block_pos: Vector3i = pos_v
			var local_origin: Vector3 = _terrain.call("mesh_block_local_origin", block_pos, lod)
			var world_origin := (_terrain as Node3D).to_global(local_origin)
			if world_origin.distance_to(_camera.global_position) > RAY_SPAN_M:
				continue
			var surface: Array = _terrain.call("get_mesh_block_surface", block_pos, lod)
			var transition_mask := int(_terrain.call("get_mesh_block_transition_mask", block_pos, lod))
			var extracted := ViewmodelRtMesh.extract_from_surface_arrays(surface, transition_mask)
			var key := _chunk_key(block_pos, lod)
			# Omit empty bake (transition-culled / transient) rather than rejecting
			# the whole near-field candidate — a reject left pre-dig lids hanging.
			if extracted.is_empty():
				omitted_empty += 1
				_dirty_keys[key] = true
				continue
			var content_hash: int = int(extracted["content_hash"])
			var entry := {
				"key": key,
				"block_pos": block_pos,
				"lod": lod,
				"local_origin": local_origin,
				"content_hash": content_hash,
				"ready": false,
				"blas": RID(),
				"vertex_buffer": RID(),
				"index_buffer": RID(),
				"vertex_array": RID(),
				"index_array": RID(),
				"owned": false,
			}
			if _try_reuse_committed_blas(entry, content_hash):
				entry["ready"] = true
				reused += 1
			else:
				_staging_pending.append({
					"generation": gen,
					"key": key,
					"content_hash": content_hash,
					"floats": extracted["floats"],
					"indices": extracted["indices"],
					"local_origin": local_origin,
					"block_pos": block_pos,
					"lod": lod,
				})
				need_build += 1
			_staging_visual[key] = entry

	var desired := _staging_visual.size()
	# No-op remesh/span restage: geometry identical, but advance revision ownership.
	if (
		need_build == 0
		and desired > 0
		and desired == reused
		and _dirty_keys.is_empty()
		and _staging_matches_committed()
	):
		_committed_revision = topology_revision
		_committed_generation = gen
		_staging_visual.clear()
		_staging_pending.clear()
		_staging_active = false
		if _status_prints < DIAG_CAP:
			_status_prints += 1
			print(
				"%s: noop adopt rev=%d gen=%d chunks=%d (no TLAS swap)"
				% [LABEL, _committed_revision, _committed_generation, desired]
			)
		return

	if _status_prints < DIAG_CAP:
		_status_prints += 1
		print(
			"%s: stage rev=%d gen=%d desired=%d reused=%d pending=%d omit_empty=%d dirty=%d"
			% [
				LABEL,
				topology_revision,
				gen,
				desired,
				reused,
				need_build,
				omitted_empty,
				_dirty_keys.size(),
			]
		)


func _staging_matches_committed() -> bool:
	if _staging_visual.size() != _committed_visual.size():
		return false
	for key in _staging_visual.keys():
		if not _committed_visual.has(key):
			return false
		var a: Dictionary = _staging_visual[key]
		var b: Dictionary = _committed_visual[key]
		if int(a.get("content_hash", 0)) != int(b.get("content_hash", 0)):
			return false
		var blas: RID = a.get("blas", RID())
		if not blas.is_valid() or blas != b.get("blas", RID()):
			return false
	return true


func _try_reuse_committed_blas(entry: Dictionary, content_hash: int) -> bool:
	var key := str(entry["key"])
	# Dig/remesh marked this key dirty — never keep the pre-edit BLAS lid.
	if _dirty_keys.has(key):
		return false
	if not _committed_visual.has(key):
		return false
	var src: Dictionary = _committed_visual[key]
	if int(src.get("content_hash", 0)) != content_hash:
		return false
	var blas: RID = src.get("blas", RID())
	if not blas.is_valid():
		return false
	# Share RIDs with committed — ownership stays with committed until swap.
	entry["blas"] = blas
	entry["vertex_buffer"] = src.get("vertex_buffer", RID())
	entry["index_buffer"] = src.get("index_buffer", RID())
	entry["vertex_array"] = src.get("vertex_array", RID())
	entry["index_array"] = src.get("index_array", RID())
	entry["owned"] = false
	return true


func _build_pending_staging_budget() -> void:
	if not _staging_active:
		return
	var budget := MAX_BLAS_BUILDS_PER_FRAME
	if _staging_pending.size() > MAX_BLAS_BUILDS_PER_FRAME:
		budget = mini(MAX_BLAS_BUILDS_CATCHUP, _staging_pending.size())
	var built := 0
	while built < budget and not _staging_pending.is_empty():
		if not _staging_active:
			return
		var job: Dictionary = _staging_pending.pop_front()
		var gen: int = int(job.get("generation", -1))
		if gen != _staging_generation:
			continue
		var key := str(job["key"])
		if not _staging_visual.has(key):
			continue
		var floats := job["floats"] as PackedFloat32Array
		var indices := job["indices"] as PackedInt32Array
		var baked := ViewmodelRtMesh.bake_blas_from_arrays(_rd, floats, indices)
		if baked.is_empty():
			_reject_incomplete_candidate(
				"bake failure",
				"pos=%s lod=%d verts=%d idx=%d gen=%d"
				% [
					str(job.get("block_pos", Vector3i.ZERO)),
					int(job.get("lod", -1)),
					floats.size() / 3,
					indices.size(),
					gen,
				]
			)
			return
		if gen != _staging_generation or not _staging_active or not _staging_visual.has(key):
			_free_bundle_rids(baked)
			built += 1
			continue
		var entry: Dictionary = _staging_visual[key]
		if int(entry.get("content_hash", 0)) != int(job["content_hash"]):
			_free_bundle_rids(baked)
			built += 1
			continue
		entry["blas"] = baked["blas"]
		entry["vertex_buffer"] = baked["vertex_buffer"]
		entry["index_buffer"] = baked.get("index_buffer", RID())
		entry["vertex_array"] = baked.get("vertex_array", RID())
		entry["index_array"] = baked.get("index_array", RID())
		entry["local_origin"] = job["local_origin"]
		entry["block_pos"] = job.get("block_pos", entry.get("block_pos", Vector3i.ZERO))
		entry["lod"] = int(job.get("lod", entry.get("lod", 0)))
		entry["ready"] = true
		entry["owned"] = true
		_staging_visual[key] = entry
		built += 1


func _reject_incomplete_candidate(reason: String, detail: String) -> void:
	_bake_rejects += 1
	_bake_retry_after_frame = _frame + BAKE_FAIL_RETRY_FRAMES
	_deferred_content_restage = true
	_content_dirty = false
	if _status_prints < DIAG_CAP:
		_status_prints += 1
		print(
			"%s: candidate rejected due to %s (%s); committed rev=%d stays live; retry_after=%d"
			% [LABEL, reason, detail, _committed_revision, _bake_retry_after_frame]
		)
	_invalidate_staging(reason)


func _staging_ready_counts() -> Vector2i:
	var ready := 0
	var desired := _staging_visual.size()
	for key in _staging_visual.keys():
		var e: Dictionary = _staging_visual[key]
		if bool(e.get("ready", false)) and (e.get("blas", RID()) as RID).is_valid():
			ready += 1
	return Vector2i(desired, ready)


func _try_publish_staging() -> void:
	if not _staging_active:
		return
	if not _staging_pending.is_empty():
		return
	var publish_gen := _staging_generation
	var counts := _staging_ready_counts()
	var desired := counts.x
	var ready := counts.y
	if ready != desired:
		return
	# Never replace a good TLAS with an empty/transient candidate.
	# Also skip publishing a vacuous empty snapshot (initial no-mesh frames).
	if desired == 0:
		_invalidate_staging("empty candidate")
		return
	if _snapshot_has_parent_child_overlap(_staging_visual):
		_overlap_rejects += 1
		if _status_prints < DIAG_CAP:
			_status_prints += 1
			print(
				"%s: overlap reject rev=%d gen=%d desired=%d rejects=%d"
				% [LABEL, _staging_revision, publish_gen, desired, _overlap_rejects]
			)
		_deferred_content_restage = true
		_frames_since_content_signal = 0
		_invalidate_staging("overlap")
		return
	# Generation must still be the one we finished building (no mid-frame invalidate).
	if not _staging_active or publish_gen != _staging_generation:
		return
	if not _publish_inactive_tlas():
		return
	if not _staging_active or publish_gen != _staging_generation:
		return
	_finalize_publish()


func _snapshot_has_parent_child_overlap(snapshot: Dictionary) -> bool:
	# Index coarser LOD keys for O(n) descendant checks. Arithmetic >> matches
	# VT parent mapping for negative block coordinates (floor-div by 2).
	var by_lod: Array = []
	for _i in range(MAX_RT_LOD + 1):
		by_lod.append({})
	for key in snapshot.keys():
		var e: Dictionary = snapshot[key]
		var lod := int(e.get("lod", -1))
		if lod < 0 or lod > MAX_RT_LOD or not e.has("block_pos"):
			continue
		(by_lod[lod] as Dictionary)[e["block_pos"] as Vector3i] = true
	for lod in range(1, MAX_RT_LOD + 1):
		var coarse: Dictionary = by_lod[lod]
		if coarse.is_empty():
			continue
		for finer_lod in range(0, lod):
			var fine: Dictionary = by_lod[finer_lod]
			var shift := lod - finer_lod
			for fpos_v in fine.keys():
				var fpos: Vector3i = fpos_v
				var parent := _block_parent_at_lod(fpos, shift)
				if coarse.has(parent):
					return true
	return false


func _block_parent_at_lod(block_pos: Vector3i, levels: int) -> Vector3i:
	var p := block_pos
	for _i in range(levels):
		p = Vector3i(p.x >> 1, p.y >> 1, p.z >> 1)
	return p


func _publish_inactive_tlas() -> bool:
	var inactive := 1 - _tlas_active_idx
	var tlas: RID = _tlas[inactive]
	if not tlas.is_valid() or _camera == null:
		return false
	var cam_inv := _camera.global_transform.affine_inverse()
	var instances: Array[RDAccelerationStructureInstance] = []
	_append_snapshot_instances(cam_inv, instances, _staging_visual)
	_append_extra_mesh_instances(cam_inv, instances)
	if instances.is_empty() and _last_good_instance_count > 0 and not _committed_visual.is_empty():
		return false
	var build_err := _rd.tlas_build(tlas, instances)
	if build_err != OK:
		if _status_prints < DIAG_CAP:
			_status_prints += 1
			push_error("%s: tlas_build(inactive) failed err=%d instances=%d" % [
				LABEL, build_err, instances.size()
			])
		return false
	RenderingServer.set_world_tlas(tlas)
	_tlas_registered = true
	_tlas_active_idx = inactive
	if instances.size() > 0:
		_last_good_instance_count = instances.size()
	_last_instance_count = instances.size()
	return true


func _finalize_publish() -> void:
	var old_committed: Dictionary = _committed_visual
	var new_committed: Dictionary = {}
	var reused_blas: Dictionary = {}
	for key in _staging_visual.keys():
		var e: Dictionary = _staging_visual[key]
		var blas: RID = e.get("blas", RID())
		if not bool(e.get("ready", false)) or not blas.is_valid():
			continue
		# Detach into a fresh dict so later staging clears cannot mutate committed.
		new_committed[key] = {
			"blas": blas,
			"vertex_buffer": e.get("vertex_buffer", RID()),
			"index_buffer": e.get("index_buffer", RID()),
			"vertex_array": e.get("vertex_array", RID()),
			"index_array": e.get("index_array", RID()),
			"local_origin": e.get("local_origin", Vector3.ZERO),
			"content_hash": int(e.get("content_hash", 0)),
			"block_pos": e.get("block_pos", Vector3i.ZERO),
			"lod": int(e.get("lod", 0)),
		}
		reused_blas[blas.get_id()] = true

	var retire_bundles: Array[Dictionary] = []
	for key in old_committed.keys():
		var old_e: Dictionary = old_committed[key]
		var old_blas: RID = old_e.get("blas", RID())
		if old_blas.is_valid() and reused_blas.has(old_blas.get_id()):
			continue
		retire_bundles.append(old_e)

	_committed_visual = new_committed
	_committed_revision = _staging_revision
	_committed_generation = _staging_generation
	_staging_visual.clear()
	_staging_pending.clear()
	_staging_active = false
	_publish_count += 1
	_committed_needs_rebuild = true
	# Snapshot is authoritative — clear dig dirty marks so reuse can resume.
	_dirty_keys.clear()
	_content_dirty_since_frame = -1

	if not retire_bundles.is_empty():
		var delay := 1
		if _rd != null:
			delay = maxi(1, int(_rd.get_frame_delay()))
		_retire_queue.append({
			"free_after_frame": _frame + delay,
			"bundles": retire_bundles,
		})

	if _status_prints < DIAG_CAP:
		_status_prints += 1
		print(
			"%s: publish rev=%d gen=%d chunks=%d tlas=%d retire=%d"
			% [
				LABEL,
				_committed_revision,
				_committed_generation,
				_committed_visual.size(),
				_tlas_active_idx,
				retire_bundles.size(),
			]
		)


func _rebuild_active_tlas() -> void:
	var tlas: RID = _tlas[_tlas_active_idx]
	if not tlas.is_valid() or _camera == null:
		return
	if _committed_visual.is_empty() and _mesh_blas.is_empty():
		# Dig may have evicted everything in-span; still clear the live TLAS.
		if _committed_needs_rebuild and _tlas_registered:
			_rd.tlas_build(tlas, [])
			_committed_needs_rebuild = false
			_last_instance_count = 0
		return
	var cam_inv := _camera.global_transform.affine_inverse()
	var instances: Array[RDAccelerationStructureInstance] = []
	_append_snapshot_instances(cam_inv, instances, _committed_visual)
	_append_extra_mesh_instances(cam_inv, instances)
	if instances.is_empty() and _last_good_instance_count > 0 and not _committed_needs_rebuild:
		return
	var build_err := _rd.tlas_build(tlas, instances)
	if build_err != OK:
		if _status_prints < DIAG_CAP:
			_status_prints += 1
			push_error("%s: tlas_build failed err=%d instances=%d" % [LABEL, build_err, instances.size()])
		return
	_committed_needs_rebuild = false
	if instances.size() > 0:
		_last_good_instance_count = instances.size()
	if not _tlas_registered:
		RenderingServer.set_world_tlas(tlas)
		_tlas_registered = true
	if instances.size() != _last_instance_count and _status_prints < DIAG_CAP:
		_last_instance_count = instances.size()
		_status_prints += 1
		var counts := _staging_ready_counts() if _staging_active else Vector2i(0, 0)
		print(
			(
				"%s: tlas_instances=%d committed=%d staging=%d/%d rev=%d/%d idx=%d api=%s"
				% [
					LABEL,
					instances.size(),
					_committed_visual.size(),
					counts.y,
					counts.x,
					_committed_revision,
					_staging_revision,
					_tlas_active_idx,
					_use_topology_api,
				]
			)
		)


func _append_snapshot_instances(
	cam_inv: Transform3D,
	instances: Array[RDAccelerationStructureInstance],
	snapshot: Dictionary
) -> void:
	if _terrain == null or not is_instance_valid(_terrain) or snapshot.is_empty():
		return
	var terrain_xf := (_terrain as Node3D).global_transform
	var cam_pos := _camera.global_position
	# Deterministic MAX_TLAS truncation: finest LOD first, then nearer.
	var keys: Array = snapshot.keys()
	keys.sort_custom(func(a, b):
		var ea: Dictionary = snapshot[a]
		var eb: Dictionary = snapshot[b]
		var lod_a := int(ea.get("lod", 0))
		var lod_b := int(eb.get("lod", 0))
		if lod_a != lod_b:
			return lod_a < lod_b
		var oa: Vector3 = ea.get("local_origin", Vector3.ZERO)
		var ob: Vector3 = eb.get("local_origin", Vector3.ZERO)
		var da := terrain_xf * oa
		var db := terrain_xf * ob
		return da.distance_squared_to(cam_pos) < db.distance_squared_to(cam_pos)
	)
	var mesh_reserve := mini(_mesh_blas.size(), MAX_TLAS_INSTANCES / 4)
	var terrain_cap := MAX_TLAS_INSTANCES - mesh_reserve
	for key in keys:
		if instances.size() >= terrain_cap:
			break
		var entry: Dictionary = snapshot[key]
		var blas: RID = entry.get("blas", RID())
		if not blas.is_valid():
			continue
		var local_origin: Vector3 = entry.get("local_origin", Vector3.ZERO)
		var inst := RDAccelerationStructureInstance.new()
		inst.blas = blas
		inst.mask = 0xFF
		inst.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT
		inst.transform = cam_inv * terrain_xf * Transform3D(Basis(), local_origin)
		instances.append(inst)


func _ensure_extra_mesh_blas() -> void:
	var roots: Array[Node] = []
	for path in extra_mesh_roots:
		var root := get_node_or_null(path)
		if root != null:
			roots.append(root)
	for node in get_tree().get_nodes_in_group("world_rt_mesh"):
		if node is Node and not roots.has(node):
			roots.append(node)
	for root in roots:
		var meshes := ViewmodelRtMesh.collect_mesh_instances(root)
		for mi in meshes:
			if not mi.is_visible_in_tree():
				continue
			var id := mi.get_instance_id()
			if _mesh_blas.has(id):
				_mesh_blas[id]["last_seen_s"] = _now_s
				continue
			var baked := ViewmodelRtMesh.bake_blas(_rd, [mi] as Array[MeshInstance3D], mi)
			if baked.is_empty():
				continue
			_mesh_blas[id] = {
				"blas": baked["blas"],
				"vertex_buffer": baked["vertex_buffer"],
				"index_buffer": baked.get("index_buffer", RID()),
				"vertex_array": baked.get("vertex_array", RID()),
				"index_array": baked.get("index_array", RID()),
				"node": mi,
				"last_seen_s": _now_s,
			}


func _append_extra_mesh_instances(
	cam_inv: Transform3D, instances: Array[RDAccelerationStructureInstance]
) -> void:
	var mesh_stale: Array[int] = []
	for id in _mesh_blas.keys():
		var entry: Dictionary = _mesh_blas[id]
		var mi: MeshInstance3D = entry.get("node") as MeshInstance3D
		if mi == null or not is_instance_valid(mi):
			mesh_stale.append(int(id))
			continue
		if mi.is_visible_in_tree():
			entry["last_seen_s"] = _now_s
		elif _now_s - float(entry.get("last_seen_s", 0.0)) > MESH_STALE_S:
			mesh_stale.append(int(id))
			continue
		var blas: RID = entry.get("blas", RID())
		if not blas.is_valid():
			continue
		var inst := RDAccelerationStructureInstance.new()
		inst.blas = blas
		inst.mask = 0xFF
		inst.flags = (
			RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT
			| RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT
		)
		inst.transform = cam_inv * mi.global_transform
		instances.append(inst)
		if instances.size() >= MAX_TLAS_INSTANCES:
			break
	for id in mesh_stale:
		_free_mesh_entry(id)


func _dispose_staging_unique_bundles() -> void:
	if _staging_visual.is_empty():
		return
	var committed_blas: Dictionary = {}
	for key in _committed_visual.keys():
		var c: Dictionary = _committed_visual[key]
		var blas: RID = c.get("blas", RID())
		if blas.is_valid():
			committed_blas[blas.get_id()] = true
	var retire: Array[Dictionary] = []
	for key in _staging_visual.keys():
		var e: Dictionary = _staging_visual[key]
		if not bool(e.get("owned", false)):
			continue
		var blas: RID = e.get("blas", RID())
		if not blas.is_valid() or committed_blas.has(blas.get_id()):
			continue
		retire.append(e)
	if retire.is_empty():
		return
	var delay := 1
	if _rd != null:
		delay = maxi(1, int(_rd.get_frame_delay()))
	_retire_queue.append({
		"free_after_frame": _frame + delay,
		"bundles": retire,
	})


func _process_retire_queue() -> void:
	while not _retire_queue.is_empty():
		var item: Dictionary = _retire_queue[0]
		if int(item.get("free_after_frame", 0)) > _frame:
			break
		_retire_queue.remove_at(0)
		var bundles: Array = item.get("bundles", [])
		for bundle_v in bundles:
			if typeof(bundle_v) != TYPE_DICTIONARY:
				continue
			_free_bundle_rids(bundle_v)


func _free_bundle_rids(bundle: Dictionary) -> void:
	if _rd == null:
		return
	# Dependency-safe order: arrays → blas → buffers (RD also frame-defers).
	for k in ["vertex_array", "index_array", "blas", "index_buffer", "vertex_buffer"]:
		var rid: RID = bundle.get(k, RID())
		if rid.is_valid():
			_rd.free_rid(rid)


func _free_mesh_entry(id: int) -> void:
	if not _mesh_blas.has(id):
		return
	var entry: Dictionary = _mesh_blas[id]
	_free_bundle_rids(entry)
	_mesh_blas.erase(id)


func _free_all() -> void:
	if _rd == null:
		return
	if _tlas_registered:
		RenderingServer.set_world_tlas(RID())
		_tlas_registered = false
	_staging_pending.clear()
	_dispose_staging_unique_bundles()
	_staging_visual.clear()
	_staging_active = false
	for item in _retire_queue:
		var bundles: Array = item.get("bundles", [])
		for bundle_v in bundles:
			if typeof(bundle_v) == TYPE_DICTIONARY:
				_free_bundle_rids(bundle_v)
	_retire_queue.clear()
	for key in _committed_visual.keys():
		_free_bundle_rids(_committed_visual[key])
	_committed_visual.clear()
	for id in _mesh_blas.keys():
		_free_mesh_entry(int(id))
	for i in range(_tlas.size()):
		if _tlas[i].is_valid():
			_rd.free_rid(_tlas[i])
			_tlas[i] = RID()
