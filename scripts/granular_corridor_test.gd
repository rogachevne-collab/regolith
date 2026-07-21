extends Node3D
## Playable probe for the granular USP itself, not its rendering.
##
## Every granular decision so far measured *presentation* (grain shell, spoil
## shader, smoothing passes) — never the mechanic a collapsed passage is
## supposed to sell: walk up, the way is blocked by loose material, dig
## through it, it slows you and half-fills back in behind the bit. This scene
## builds exactly one such passage using nothing but production code paths
## (`WorldCommandGateway.apply_terrain_carve`, the same signal a real drill
## bite fires) and drops the player at its mouth.
##
## Bore the open run with the excavation service directly (no `terrain_modified`
## emitted, so no spoil scatters through it) and reserve `apply_terrain_carve`
## only for the ceiling bites at the choke — those are meant to notify
## `GranularVoxelWorld`, because a roof coming down and spoil landing where it
## falls is precisely the collapse this is testing, not a special case.
##
## `--diagnose` verifies clearance and dig-through headlessly, for a bot to
## check before a person plays it. The eye still gets the last word.

const _TerrainExcavationService := preload(
	"res://scripts/simulation/runtime/terrain_excavation_service.gd"
)

## `bootstrap.gd` points the voxel dig-stream and world-save path at
## `moon_experiment/gen_v<N>/` — the same on-disk save every normal scene on
## this generator version shares, `main.tscn` included. A first version of
## this scene carved straight into it: real tunnel, real roof collapse,
## permanently written to that shared `moon.sqlite`, discovered only after
## the fact by diffing file mtimes. `MoonTerrainParams.set_test_stream_label`
## is the project's own existing fix for exactly this — `test_moon_5km_flat`
## already uses it — so this scene now gets its own
## `moon_experiment/test_corridor_collapse/` and never touches `gen_v*` again.
## Set in `_enter_tree`, not `_ready`: it has to land before `bootstrap.gd`'s
## own `_ready` reads `MoonGeometry.world_save_path()`, and Godot delivers
## `NOTIFICATION_ENTER_TREE` root-to-leaves — entirely before any `_ready` — so
## a child's `_enter_tree` here still lands ahead of the parent's `_ready`.
const TEST_STREAM_LABEL := "test_corridor_collapse"

@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
@export var gateway_path: NodePath = NodePath("../WorldCommandGateway")
@export var player_path: NodePath = NodePath("../Player")
@export var base_spawn_path: NodePath = NodePath("../BaseSpawn")

## Where the mouth opens, how far the passage runs, and how it slopes down
## from the surface into a level run — a straight bore looks authored, and a
## ramped mouth is what an adit into a slope actually looks like.
const X_START := 3.0
const CORRIDOR_LENGTH := 14.0
const RAMP_LENGTH := 3.0
## Bore radius. Twice this is clear headroom with nothing collapsed — a
## capsule 0.3 m in radius and 1.8 m tall needs less than half of it.
const BORE_RADIUS_M := 1.3
const BORE_STEP_M := 0.7
## Rock left above the ceiling once the ramp reaches full depth, at the
## shallowest point sampled along the run — so the level run never breaches
## daylight partway down even if the ground rises.
const ROOF_MARGIN_M := 1.2

## Where the roof comes down. Off-centre so open passage remains on both
## sides — the point is walking up to a block, not spawning inside one.
const COLLAPSE_CENTER_X := X_START + RAMP_LENGTH + 5.0
const COLLAPSE_BITE_OFFSETS: Array[float] = [-0.8, 0.0, 0.8]
const COLLAPSE_BITE_RADIUS_M := 2.0
## Metres above the tunnel ceiling the bite is centred — enough to dip back
## into the open bore below so the fallen spoil has an unbroken drop to the
## floor rather than hanging on a ledge of its own dust.
const COLLAPSE_BITE_HEIGHT_ABOVE_CEILING_M := 0.5

const SAMPLE_Z_OFFSETS: Array[float] = [-0.9, -0.45, 0.0, 0.45, 0.9]
## Simulated bites while clearing the block in `--diagnose`, matching the
## scale a hand drill actually works at.
const DIG_RADIUS_M := 0.6
const DIG_ATTEMPTS := 24

## Range the SDF surface search marches through. Tight around the expected
## ~9500 m radius rather than the full altitude range: `is_area_editable`
## checked over hundreds of vertical metres almost never comes back true in
## one piece even once the ground itself is long since streamed in, because
## nothing is generated way up in vacuum for it to include.
const SURFACE_SEARCH_TOP_Y := 9560.0
const SURFACE_SEARCH_BOTTOM_Y := 9440.0

func _enter_tree() -> void:
	MoonTerrainParams.set_test_stream_label(TEST_STREAM_LABEL)


func _exit_tree() -> void:
	MoonTerrainParams.clear_test_stream_label()


var _terrain: Node3D
var _voxel_tool: VoxelTool
var _gateway: Node
var _granular_world: Node
var _excavation := _TerrainExcavationService.new()
var _tunnel_y := 0.0
var _ceiling_y := 0.0


func _ready() -> void:
	call_deferred("_setup")


func _setup() -> void:
	# `bootstrap.gd` runs a shrunk view distance and a coarse collision LOD
	# while it gets the player standing near spawn, and only widens streaming
	# back out once `is_world_ready()` — a fixed frame count guessed at that
	# and excavated onto voxel data that had not streamed in yet, so every
	# carve silently removed 0 m3. Wait for the real signal instead.
	await _wait_for_world_ready()
	for _i in 30:
		await get_tree().process_frame
	_terrain = get_node_or_null(terrain_path) as Node3D
	_gateway = get_node_or_null(gateway_path)
	if _terrain == null or _gateway == null:
		push_warning("GranularCorridorTest: terrain or gateway missing")
		return
	_voxel_tool = TerrainCompat.get_voxel_tool(_terrain)
	if _voxel_tool == null:
		push_warning("GranularCorridorTest: no voxel tool")
		return
	_granular_world = get_tree().get_first_node_in_group(&"granular_world")

	var surface_y: float = await _lowest_surface_y()
	_ceiling_y = surface_y - ROOF_MARGIN_M
	_tunnel_y = _ceiling_y - BORE_RADIUS_M
	var mouth_y := surface_y - BORE_RADIUS_M * 0.5

	await _bore_corridor(mouth_y)
	await _collapse_roof()
	await _place_player(mouth_y)

	print(
		"GranularCorridorTest: bored x=[%.1f, %.1f] at y=%.2f (ceiling %.2f), collapse at x=%.1f"
		% [
			X_START,
			X_START + CORRIDOR_LENGTH,
			_tunnel_y,
			_ceiling_y,
			COLLAPSE_CENTER_X,
		]
	)
	_maybe_diagnose()


## Poll the scene root's own readiness flag rather than guess a frame count.
## Falls back to a generous fixed wait if the root is not `bootstrap.gd` (a
## scene built without it), so this still degrades instead of hanging forever.
func _wait_for_world_ready() -> void:
	var root := get_tree().current_scene
	if root == null or not root.has_method(&"is_world_ready"):
		for _i in 180:
			await get_tree().process_frame
		return
	var waited_frames := 0
	while (
		not bool(root.call(&"is_world_ready"))
		and waited_frames < 1800
	):
		await get_tree().process_frame
		waited_frames += 1
	print(
		"GranularCorridorTest: world_ready after %d frames" % waited_frames
	)


## Surface height at a handful of points along the run, at z=0 — the lowest of
## them is what decides how deep the level section sits, so the roof stays
## covered even where the ground happens to rise.
##
## Read off the SDF directly rather than a physics raycast: `bootstrap.gd`
## drops a temporary landing pad collider near spawn — a wide, flat stand-in —
## while the real terrain collider streams in, and a physics ray at these
## coordinates hits *that*, not the ground, reporting a confident but wrong
## height around the pad rather than the true ~9500. The SDF has no
## stand-in: it is the same data `excavate` itself edits.
func _lowest_surface_y() -> float:
	var lowest := INF
	var samples := 6
	for i in samples:
		var x: float = X_START + CORRIDOR_LENGTH * float(i) / float(samples - 1)
		var y: float = await _surface_y_via_sdf(x, 0.0)
		if is_finite(y) and y < lowest:
			lowest = y
	return lowest if is_finite(lowest) else 9500.0


func _sample_sdf(world_point: Vector3) -> float:
	var local := VoxelSpaceUtil.world_to_local(_terrain, world_point)
	return _voxel_tool.get_voxel_f(
		Vector3i(floori(local.x), floori(local.y), floori(local.z))
	)


## `get_voxel_f` on a block that has not streamed in yet does not error, it
## reads back a flat default (measured: exactly the `sdf <= 0` "solid" case),
## so a march that only sanity-checks its own starting point can walk clean
## off the edge of loaded data one sample later and call the first unloaded
## block "ground" — which is why the surface height read differently on
## almost every run despite carving the same coordinates. `is_area_editable`
## is the one honest answer to "is this data really here", and it is what
## `TerrainExcavationService.excavate` itself gates writes on, so waiting on
## it here matches what a real carve already trusts.
func _await_column_editable(x: float, z: float) -> void:
	var top_local := VoxelSpaceUtil.world_to_local(
		_terrain, Vector3(x, SURFACE_SEARCH_TOP_Y, z)
	)
	var bottom_local := VoxelSpaceUtil.world_to_local(
		_terrain, Vector3(x, SURFACE_SEARCH_BOTTOM_Y, z)
	)
	var margin := 2.0
	var lo := Vector3(
		minf(top_local.x, bottom_local.x) - margin,
		minf(top_local.y, bottom_local.y) - margin,
		minf(top_local.z, bottom_local.z) - margin
	)
	var hi := Vector3(
		maxf(top_local.x, bottom_local.x) + margin,
		maxf(top_local.y, bottom_local.y) + margin,
		maxf(top_local.z, bottom_local.z) + margin
	)
	var area := AABB(lo, hi - lo)
	for _attempt in 300:
		if _voxel_tool.is_area_editable(area):
			return
		await get_tree().process_frame
	push_warning(
		"GranularCorridorTest: column at x=%.1f never became editable" % x
	)


## Marches straight down through the SDF from well above the ground until it
## crosses into rock (`sdf <= 0`, the mesher's own inside test — see
## `GranularVoxelRegion._cell_is_rock`).
func _surface_y_via_sdf(x: float, z: float) -> float:
	await _await_column_editable(x, z)
	var y := SURFACE_SEARCH_TOP_Y
	while y > SURFACE_SEARCH_BOTTOM_Y:
		var next_y := y - 0.5
		if _sample_sdf(Vector3(x, next_y, z)) <= 0.0:
			return next_y
		y = next_y
	return SURFACE_SEARCH_BOTTOM_Y


## Silent bore: rock removal through the excavation service directly, not
## `apply_terrain_carve` — that emits `terrain_modified`, and every metre of an
## open corridor would otherwise scatter its own 35% spoil fraction through the
## passage it is meant to keep clear. The collapse is the one place spoil
## should appear, and it earns that through its own carve below.
func _bore_corridor(mouth_y: float) -> void:
	var length := CORRIDOR_LENGTH
	var steps := maxi(int(ceil(length / BORE_STEP_M)), 1)
	var total_removed := 0.0
	var stalls := 0
	for i in steps + 1:
		var t := float(i) / float(steps)
		var x := X_START + length * t
		var ramp_t := clampf((x - X_START) / RAMP_LENGTH, 0.0, 1.0)
		var y := lerpf(mouth_y, _tunnel_y, ramp_t)
		var result: Dictionary = await _excavate_with_retry(
			{
				"stamp_kind": &"sphere",
				"terrain": _terrain,
				"center": Vector3(x, y, 0.0),
				"radius": BORE_RADIUS_M,
				"sdf_scale": 1.0,
			}
		)
		total_removed += float(result.get("removed_volume_m3", 0.0))
		if StringName(result.get("status", &"")) == &"terrain_unavailable":
			stalls += 1
	print(
		"GranularCorridorTest: bore removed %.2f m3 over %d bites (%d never streamed in)"
		% [total_removed, steps + 1, stalls]
	)


## Retries while the terrain reports its data as not yet streamed in, rather
## than trusting the first attempt — see `_raycast_down_y` for the same
## streaming-lag problem on the physics side of this scene.
func _excavate_with_retry(request: Dictionary) -> Dictionary:
	var result := {}
	for _attempt in 300:
		result = _excavation.excavate(_voxel_tool, request)
		if StringName(result.get("status", &"")) != &"terrain_unavailable":
			return result
		await get_tree().process_frame
	return result


## Roof comes down through the real drilling path on purpose: this is meant to
## exercise the same `terrain_modified` -> spoil -> settle chain a live bite
## does, not a shortcut that seeds mass directly.
func _collapse_roof() -> void:
	if not _gateway.has_method(&"apply_terrain_carve"):
		push_warning("GranularCorridorTest: gateway has no apply_terrain_carve")
		return
	var bite_y := _ceiling_y + COLLAPSE_BITE_HEIGHT_ABOVE_CEILING_M
	for offset: float in COLLAPSE_BITE_OFFSETS:
		var request := {
			"stamp_kind": &"sphere",
			"center": Vector3(COLLAPSE_CENTER_X + offset, bite_y, 0.0),
			"radius": COLLAPSE_BITE_RADIUS_M,
		}
		# `apply_terrain_carve` only returns the volume, not a status, so a
		# flat 0 here is read as "not streamed yet" and retried — there is
		# real rock above this bore everywhere it is aimed, so an honest
		# "nothing to remove" is not expected at this spot.
		var removed := 0.0
		for _attempt in 300:
			removed = float(_gateway.call(&"apply_terrain_carve", request))
			if removed > 0.0:
				break
			await get_tree().process_frame
		print(
			"GranularCorridorTest: ceiling bite at x=%.1f removed %.2f m3"
			% [COLLAPSE_CENTER_X + offset, removed]
		)


## Places the player at the mouth and holds them there on a scratch platform
## of our own until the real terrain collider at that spot exists.
##
## `bootstrap.gd` does exactly this at the original spawn point — a temporary
## landing pad, retired once "voxel floor ready" — because trimesh colliders
## lag the SDF by seconds (its own comment: VT #677). It only ever checks
## readiness back at *that* original hint, though, so teleporting the player
## somewhere else (here) drops them onto ground with no such guarantee: the
## first version of this scene did exactly that and the player fell through
## the freshly-carved, not-yet-collidable mouth into the open tunnel below,
## with nothing in view — indistinguishable from nothing being there at all.
func _place_player(mouth_y: float) -> void:
	var entry := Vector3(X_START - 1.5, mouth_y + BORE_RADIUS_M + 1.0, 0.0)
	var base_spawn := get_node_or_null(base_spawn_path) as Node3D
	if base_spawn != null:
		base_spawn.global_position = entry
	var player := get_node_or_null(player_path) as Node3D
	if player == null:
		return
	_install_entry_pad(entry)
	player.global_position = entry
	# Face down the corridor, toward +X — the run sits on the equator, where
	# local up is world +Y, so no basis rotation is needed to aim the player.
	player.look_at(entry + Vector3(1.0, 0.0, 0.0), Vector3.UP)
	await _await_real_terrain_then_retire_pad(entry)


const _ENTRY_PAD_SIZE := Vector3(3.0, 1.0, 3.0)
## Matches the player capsule (`CapsuleShape_player` in player.tscn): height
## 1.8 m, so half that plus a hair of clearance so the capsule does not spawn
## embedded in the pad.
const _ENTRY_PAD_CLEARANCE_M := 0.95
var _entry_pad: StaticBody3D


func _install_entry_pad(entry: Vector3) -> void:
	_remove_entry_pad()
	var body := StaticBody3D.new()
	body.name = "CorridorEntryPad"
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = _ENTRY_PAD_SIZE
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	var top_y := entry.y - _ENTRY_PAD_CLEARANCE_M
	body.global_position = Vector3(entry.x, top_y - box.size.y * 0.5, entry.z)
	_entry_pad = body


func _remove_entry_pad() -> void:
	if _entry_pad != null and is_instance_valid(_entry_pad):
		_entry_pad.queue_free()
	_entry_pad = null


## Polls a physics ray at the entry point until it hits the *real* terrain
## collider specifically (not our own scratch pad, not `bootstrap.gd`'s
## landing pad, which sits over the original spawn hint and may not even
## reach out here) — then retires the pad. Times out rather than hanging
## forever if streaming stalls; the pad is left in place as a fallback so the
## player has something to stand on regardless.
func _await_real_terrain_then_retire_pad(entry: Vector3) -> void:
	var origin := entry + Vector3(0.0, 2.0, 0.0)
	var target := entry + Vector3(0.0, -3.0, 0.0)
	for _attempt in 600:
		var query := PhysicsRayQueryParameters3D.create(origin, target)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if (
			not hit.is_empty()
			and TerrainCompat.is_terrain_collider(hit.get("collider"), _terrain)
		):
			_remove_entry_pad()
			print(
				"GranularCorridorTest: real terrain collider ready at the mouth, pad retired"
			)
			return
		await get_tree().process_frame
	push_warning(
		"GranularCorridorTest: real terrain collider at the mouth never appeared; leaving the scratch pad in place"
	)


## `--diagnose`: sample clearance at the choke and prove it can be dug back
## open, headlessly. Confirms the mechanic exists before anyone has to look at
## it — the look is a separate, later question.
func _maybe_diagnose() -> void:
	if not OS.get_cmdline_user_args().has("--diagnose"):
		return
	# The field only advances on `GranularVoxelWorld`'s own `_process`, at
	# `SETTLE_HZ` — give the collapse time to actually come to rest before
	# measuring it, or the numbers are mid-fall and meaningless. Also gives
	# any fall-through-the-floor problem at the mouth time to show up as a
	# player position far from where they were placed, rather than passing
	# quietly because nothing was still falling yet when it was checked.
	for _i in 360:
		await get_tree().process_frame
	var player := get_node_or_null(player_path) as Node3D
	if player != null:
		print(
			"GranularCorridorTest: player at %s (expected near x=%.1f)"
			% [str(player.global_position), X_START - 1.5]
		)
	print("GranularCorridorTest: --- before digging ---")
	_report_clearance()
	if _granular_world == null or not _granular_world.has_method(&"dig_spoil"):
		push_warning("GranularCorridorTest: no granular world to dig against")
		get_tree().quit(1)
		return
	var total_removed := 0.0
	var dig_point := Vector3(COLLAPSE_CENTER_X, _tunnel_y, 0.0)
	for attempt in DIG_ATTEMPTS:
		var removed := float(
			_granular_world.call(&"dig_spoil", dig_point, DIG_RADIUS_M)
		)
		total_removed += removed
		if removed <= 0.0 and attempt > 2:
			break
		for _i in 20:
			await get_tree().process_frame
	print(
		"GranularCorridorTest: dug %.3f m3 over %d bites"
		% [total_removed, DIG_ATTEMPTS]
	)
	print("GranularCorridorTest: --- after digging ---")
	_report_clearance()
	print("GranularCorridorTest: PASS")
	get_tree().quit(0)


## Depth and clearance across the choke's cross-section — the same
## `dust_at`/`dust_column_at` a walking character reads, so this is the exact
## signal that decides whether a body can stand upright there.
func _report_clearance() -> void:
	if _granular_world == null or not _granular_world.has_method(&"dust_at"):
		print("GranularCorridorTest: no granular world to sample")
		return
	var min_clearance := INF
	var max_depth := 0.0
	for z: float in SAMPLE_Z_OFFSETS:
		var point := Vector3(COLLAPSE_CENTER_X, _tunnel_y, z)
		var column := Dictionary(_granular_world.call(&"dust_at", point))
		if column.is_empty():
			print("GranularCorridorTest: z=%.2f empty" % z)
			continue
		var depth: float = column["depth_m"]
		var surface: Vector3 = column["surface"]
		var clearance := _ceiling_y - surface.y
		min_clearance = minf(min_clearance, clearance)
		max_depth = maxf(max_depth, depth)
		print(
			"GranularCorridorTest: z=%.2f depth=%.2f m surface_y=%.2f clearance=%.2f m"
			% [z, depth, surface.y, clearance]
		)
	if is_finite(min_clearance):
		print(
			"GranularCorridorTest: min clearance %.2f m (capsule needs ~1.8 m), max depth %.2f m"
			% [min_clearance, max_depth]
		)
