class_name GranularWorld
extends Node3D
## Loose material in the real world: every cut the voxel terrain reports turns
## into spoil on a `GranularPatch` beside the hole.
##
## Until now excavated rock vanished — the SDF lost volume and the yield went
## straight to a store, so digging left no trace on the ground. This node is
## the join: it listens to `WorldCommandGateway.terrain_modified`, anchors a
## patch on the tangent plane at the cut (local up is the radial, not global Y)
## and piles the cuttings around the mouth. Spec: `docs/specs/GRANULAR-V0.md`.

## Grid per patch. 32 cells at 0.25 m is 8 m across: wide enough to hold the
## spoil of a session's worth of hand drilling at one working face, small
## enough that laying its base costs a thousand voxel raycasts once.
const PATCH_CELLS := 32
const PATCH_CELL_SIZE_M := 0.25
const PATCH_REPOSE_DEG := 33.0

## Patches are kept only around where the player is actually working. Digging
## your way across the moon would otherwise accumulate height fields forever.
const MAX_PATCHES := 6

## A cut is only served by a patch that can hold its whole spoil ring clear of
## the border, or the ring comes out cut in half against the edge.
const PATCH_EDGE_MARGIN_M := 1.0
## How far off a patch's tangent plane a cut may be and still belong to it.
## Past this the cut is somewhere else in the vertical sense — the floor of a
## shaft is not the surface it was sunk from — and gets its own patch.
const PATCH_SLAB_HALF_HEIGHT_M := 2.5

## Base probe: start this far above the tangent plane and look this far down
## for solid ground under each cell. Wide enough to clear a corner cell on a
## 45-degree slope across the whole patch (half-extent ~4 m, so worst-case
## corner-to-centre relief is ~5.5 m) with headroom for real terrain being
## rougher than a plane; a cell that still finds nothing is a genuine
## overhang or void, not just an underestimated window.
const BASE_PROBE_UP_M := 4.0
const BASE_PROBE_DOWN_M := 10.0
## SDF value above which a probe origin counts as open space. Starting a probe
## inside rock reports the face at zero distance and would lay the base at
## probe height, so those cells are handled as "no floor" instead.
const OPEN_SPACE_SDF := 0.05
## Every dig re-probes at least this wide a disc around itself, regardless of
## how small the cut was. A hand-drill bite is a couple of cells across, so
## without a floor a patch only ever heals the few cells directly under the
## bit; digging out a wider area over many small bites would leave the cells
## between visits standing at whatever height they were first probed at —
## floating once the real ground beneath has since been carved away.
const RESAMPLE_REACH_MIN_CELLS := 8

@export var gateway_path: NodePath = NodePath("../WorldCommandGateway")
@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
## Off by default so a scene opts in rather than every scene that happens to
## own a gateway inheriting a height field it never asked for.
@export var enabled := false

var _terrain: Node3D
var _voxel_tool: VoxelTool
var _gravity_field: GravityField
var _gravity := 1.62
## Least recently dug first. Each entry: `{ "anchor", "patch", "view" }`.
var _fields: Array[Dictionary] = []


func _ready() -> void:
	if not enabled:
		set_process(false)
		return
	_gravity = float(
		ProjectSettings.get_setting("physics/3d/default_gravity", 1.62)
	)
	_terrain = get_node_or_null(terrain_path) as Node3D
	if _terrain != null:
		_voxel_tool = TerrainCompat.get_voxel_tool(_terrain)
	var gateway := get_node_or_null(gateway_path) as WorldCommandGateway
	if gateway == null or _voxel_tool == null:
		push_warning("GranularWorld: no gateway or terrain; loose material is off")
		set_process(false)
		return
	gateway.terrain_modified.connect(_on_terrain_modified)
	call_deferred("_bind_gravity_field")


func _bind_gravity_field() -> void:
	_gravity_field = GravityField.find_in_tree(self)
	if _gravity_field != null:
		_gravity = _gravity_field.gravity_strength


func _process(delta: float) -> void:
	for field: Dictionary in _fields:
		var patch: GranularPatch = field["patch"]
		if not patch.is_settled():
			# Settling runs on wall-clock time under the local gravity, so lunar
			# material slumps at lunar speed instead of at frame rate.
			patch.advance(delta, _gravity)
		var view: GranularFieldView = field["view"]
		view.refresh(delta, _gravity)


## Every carve in the world lands here, whatever made it: hand drill,
## stationary drill, an impact. The volume the SDF lost becomes loose material
## beside the cut instead of disappearing.
func _on_terrain_modified(
	removed_volume_m3: float,
	dig_center: Vector3,
	dig_radius_m: float
) -> void:
	var spoil := GranularSpoil.spoil_volume_m3(removed_volume_m3)
	if spoil <= 0.000001 or dig_radius_m <= 0.0:
		return
	var index := _field_index_for(dig_center, dig_radius_m)
	if index < 0:
		return
	var field := _fields[index]
	var anchor: GranularAnchor = field["anchor"]
	var patch: GranularPatch = field["patch"]
	var local := anchor.to_patch(dig_center)
	# The rock under the cut has just moved, so the base the patch stands on is
	# stale exactly where the spoil is about to land.
	_resample_base(anchor, patch, local, dig_radius_m)
	# The ring has to clear the whole disc that just got resampled, not just
	# this bite's own small footprint — a hand drill fires every ~0.15 s into
	# roughly the same spot, and a ring sized to one bite lands right back at
	# the mouth of the hole the previous bite made. The hole would fill itself
	# faster than the bit could widen it and choke on its own cuttings.
	var clearance_m := maxf(
		dig_radius_m, float(RESAMPLE_REACH_MIN_CELLS) * patch.cell_size
	)
	GranularSpoil.deposit_ring(patch, local.x, local.z, clearance_m, spoil)
	var view: GranularFieldView = field["view"]
	view.snap()
	_touch(index)


## Index of the patch that owns a cut, creating one when nothing covers it.
## -1 when the ground there cannot be probed at all.
func _field_index_for(dig_center: Vector3, dig_radius_m: float) -> int:
	var margin := dig_radius_m + PATCH_EDGE_MARGIN_M
	for index in range(_fields.size() - 1, -1, -1):
		var anchor: GranularAnchor = _fields[index]["anchor"]
		if not anchor.covers(dig_center, margin):
			continue
		if absf(anchor.height_above_plane(dig_center)) > PATCH_SLAB_HALF_HEIGHT_M:
			continue
		return index
	return _create_field(dig_center)


## Returns the new patch's index, or -1 when the cut has no probeable ground
## around it — mid-air, or terrain that is not streamed in yet.
func _create_field(dig_center: Vector3) -> int:
	var anchor := GranularAnchor.create(
		dig_center, _up_at(dig_center), PATCH_CELLS, PATCH_CELLS, PATCH_CELL_SIZE_M
	)
	var patch := GranularPatch.create(
		PATCH_CELLS, PATCH_CELLS, PATCH_CELL_SIZE_M, PATCH_REPOSE_DEG
	)
	if not _lay_base(anchor, patch):
		return -1
	var view := GranularFieldView.new()
	add_child(view)
	view.setup(anchor, patch)
	_fields.append({"anchor": anchor, "patch": patch, "view": view})
	while _fields.size() > MAX_PATCHES:
		var oldest: GranularFieldView = _fields.pop_front()["view"]
		if is_instance_valid(oldest):
			oldest.queue_free()
	return _fields.size() - 1


func _up_at(world_point: Vector3) -> Vector3:
	if _gravity_field != null:
		return _gravity_field.up_at(world_point)
	return GravityField.resolve_up(self, world_point)


## Probe the solid ground under every cell once, at creation. Cells with no
## floor become blocked: material stays out of them and the collider gets a
## hole, the honest answer for a cell hanging over a void. False when nothing
## was found anywhere, so the caller can drop a patch of pure holes rather than
## pay for its collider.
func _lay_base(anchor: GranularAnchor, patch: GranularPatch) -> bool:
	var found := 0
	for z in patch.depth:
		for x in patch.width:
			var base_height := _probe_base(anchor, patch, x, z)
			if is_nan(base_height):
				patch.set_blocked(x, z, true)
				continue
			patch.set_base_height(x, z, base_height)
			found += 1
	return found > 0


## Re-probe the cells a cut just went through. Material lying on them keeps its
## thickness and rides the floor down, which is what makes digging under a heap
## collapse it into the hole. A cell the cut opened right through drops to the
## bottom of the probe rather than turning into a collider hole: blocking it
## would delete the spoil standing on it, and volume that disappears is the one
## thing this whole layer exists to prevent.
func _resample_base(
	anchor: GranularAnchor,
	patch: GranularPatch,
	local: Vector3,
	dig_radius_m: float
) -> void:
	var reach := maxi(
		int(ceil(dig_radius_m / patch.cell_size)) + 1,
		RESAMPLE_REACH_MIN_CELLS
	)
	var center := anchor.cell_at(local.x, local.z)
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := center.x + dx
			var z := center.y + dz
			if dx * dx + dz * dz > reach * reach:
				continue
			if not patch.in_bounds(x, z) or patch.is_blocked(x, z):
				continue
			var base_height := _probe_base(anchor, patch, x, z)
			patch.set_base_height(
				x,
				z,
				-BASE_PROBE_DOWN_M if is_nan(base_height) else base_height
			)


## Height of solid ground under a cell, in patch-local metres along local up.
## NAN when the probe finds no floor within reach or starts inside rock.
func _probe_base(
	anchor: GranularAnchor,
	patch: GranularPatch,
	x: int,
	z: int
) -> float:
	var origin := anchor.to_world(
		float(x) * patch.cell_size,
		float(z) * patch.cell_size,
		BASE_PROBE_UP_M
	)
	if _voxel_tool.get_voxel_f(
		VoxelSpaceUtil.world_cell_from_point(_terrain, origin)
	) <= OPEN_SPACE_SDF:
		return NAN
	var hit := VoxelSpaceUtil.raycast_world(
		_voxel_tool,
		_terrain,
		origin,
		-anchor.up(),
		BASE_PROBE_UP_M + BASE_PROBE_DOWN_M
	)
	if hit == null:
		return NAN
	return BASE_PROBE_UP_M - VoxelSpaceUtil.raycast_hit_world_distance(_terrain, hit)


## Keep the most recently dug patch last, so the cap frees the face the player
## walked away from rather than the one under their feet.
func _touch(index: int) -> void:
	if index < 0 or index >= _fields.size() - 1:
		return
	_fields.append(_fields.pop_at(index))
