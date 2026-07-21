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
##
## PARKED — `enabled` is false in `main.tscn`, on purpose. Kept whole because
## the simulation underneath it is sound and worth reusing elsewhere; what
## failed is this integration, and the reason is structural rather than a bug
## list. A `GranularPatch` is a height field: a single-valued surface over a
## fixed tangent plane. Laid on top of voxel terrain in an open sandbox it
## competes with a surface that already exists, so the two disagree by
## centimetres wherever they touch (SDF raycast versus Transvoxel mesh), its
## rectangular border is a seam with nothing to hide it, it cannot describe a
## bore into a wall or material in a tunnel, and — worst — two patches that
## overlap have no shared truth, so one pile ignores the next and undermining
## a heap from a neighbouring patch leaves it standing in the air.
##
## The replacement is a volume rather than a surface: loose material as its own
## 0.25 m voxel field, meshed and collided by the voxel plugin, flowing under a
## mass-conserving cellular automaton. `GranularPatch` stays the reference for
## that automaton's physics — repose angle, stability hysteresis, exact volume
## conservation — and stays live in `granular_playground` / `granular_cascade`,
## where a patch legitimately owns its ground and looks the part.

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
## How often an actively-dug patch gets its whole base re-probed, on top of
## the disc around each individual cut. The disc keeps the immediate dig
## point honest with no latency; a sprawling excavation — a tunnel, a pit
## widened over many small bites moving around — outgrows that disc long
## before every corner of an 8 m patch has had a cut land near it, and the
## untouched cells just sit at whatever height they were first probed at
## while the real ground under them keeps changing.
const FULL_RESAMPLE_INTERVAL_MSEC := 800

## Thickness under which a cell carries no surface at all — no mesh quad, no
## collider. A patch in the world lies on top of terrain that already has a
## surface, so an empty cell must be absent rather than flat, or the layer
## shadows the rock everywhere it reaches.
##
## Set well above a dusting on purpose. The base under a cell is a raycast
## against the SDF and the rock beside it is a Transvoxel mesh, so the two
## agree only to within a few centimetres; anything thinner than that
## disagreement reads as a sheet hovering over the ground rather than as
## material lying on it. Below this the spoil is simply not drawn — the ground
## keeps its own surface, which is the honest picture at that thickness.
const MIN_PRESENCE_M := 0.06

## Steepest ground a patch will anchor on. A height field is a single-valued
## function over its tangent plane, so it simply cannot describe a wall, an
## overhang or a bore driven into a face — pushed onto one it renders the gap
## between neighbouring cells as a vertical curtain. Loose material would run
## off a slope this steep anyway (repose is ~33 degrees), so refusing to place
## a patch here costs nothing real: spoil from a face belongs on the floor
## below it, which is a different patch and its own step.
const MAX_FLOOR_SLOPE_DEG := 40.0
## Arm length for the slope test around a prospective patch centre.
const FLOOR_PROBE_SPAN_M := 0.75

## Group so the command gateway can find this node without a hard path.
const GROUP_NAME := &"granular_world"

## How much loose material one drill bite clears, relative to the same bite in
## rock. Spoil is already broken, so the bit goes through it faster — clearing
## your own heap is quick, not a second excavation.
const SPOIL_DIG_MULTIPLIER := 2.5

## Gap between the edge of a cut and where its cuttings are dropped, so the
## heap builds beside the working face rather than back down the hole.
const SPOIL_THROW_CLEARANCE_M := 0.9
## Arm length for reading the local downhill direction off the patch base.
const SPOIL_GRADIENT_SPAN_M := 0.75

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
	add_to_group(GROUP_NAME)
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
	var now_msec := Time.get_ticks_msec()
	if now_msec >= int(field.get("next_full_resample_msec", 0)):
		_resample_patch_fully(anchor, patch)
		field["next_full_resample_msec"] = now_msec + FULL_RESAMPLE_INTERVAL_MSEC
	# Throw the cuttings clear of the cut and let them heap, the way a muck
	# pile forms beside a face. Spreading each bite over a ring around its own
	# mouth was the mistake behind the "sheet laid over the landscape" look:
	# painted over that much footprint the spoil arrives already flat, and no
	# amount of settling turns a flat sheet back into a pile. Dropped on a
	# small footprint instead, the angle of repose does the shaping, which is
	# the whole reason the granular layer exists.
	var drop := _spoil_drop_point(anchor, patch, local, dig_radius_m)
	GranularSpoil.deposit_heap(patch, drop.x, drop.y, spoil)
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
	if not _is_floor_enough(anchor):
		return -1
	var patch := GranularPatch.create(
		PATCH_CELLS, PATCH_CELLS, PATCH_CELL_SIZE_M, PATCH_REPOSE_DEG
	)
	patch.min_presence_m = MIN_PRESENCE_M
	if not _lay_base(anchor, patch):
		return -1
	var view := GranularFieldView.new()
	add_child(view)
	view.setup(anchor, patch)
	_fields.append({
		"anchor": anchor,
		"patch": patch,
		"view": view,
		"next_full_resample_msec": (
			Time.get_ticks_msec() + FULL_RESAMPLE_INTERVAL_MSEC
		),
	})
	while _fields.size() > MAX_PATCHES:
		var oldest: GranularFieldView = _fields.pop_front()["view"]
		if is_instance_valid(oldest):
			oldest.queue_free()
	return _fields.size() - 1


## Where one bite's cuttings land, in patch-local metres: clear of the cut and
## downhill, so the heap builds beside the hole instead of in it and creeps the
## way a real muck pile does. The gradient comes from the base under the patch,
## so on a slope the pile runs away downhill; on flat ground it falls back to a
## fixed direction rather than an arbitrary one, because two peers must build
## the same pile from the same dig.
func _spoil_drop_point(
	anchor: GranularAnchor,
	patch: GranularPatch,
	local: Vector3,
	dig_radius_m: float
) -> Vector2:
	var cell := anchor.cell_at(local.x, local.z)
	var step := maxi(int(round(SPOIL_GRADIENT_SPAN_M / patch.cell_size)), 1)
	var west := patch.base_height(maxi(cell.x - step, 0), cell.y)
	var east := patch.base_height(mini(cell.x + step, patch.width - 1), cell.y)
	var north := patch.base_height(cell.x, maxi(cell.y - step, 0))
	var south := patch.base_height(cell.x, mini(cell.y + step, patch.depth - 1))
	var downhill := Vector2(west - east, north - south)
	if downhill.length_squared() <= 0.0001:
		downhill = Vector2.RIGHT
	var throw_m := dig_radius_m + SPOIL_THROW_CLEARANCE_M
	return Vector2(local.x, local.z) + downhill.normalized() * throw_m


## Whether the ground around a prospective patch centre is flat enough to be a
## floor. Four probes on the tangent axes give the local gradient; anything
## steeper than `MAX_FLOOR_SLOPE_DEG` is a face, and a height field has no
## honest way to represent one.
func _is_floor_enough(anchor: GranularAnchor) -> bool:
	var half := anchor.half_extent()
	var heights := {}
	for axis: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		var offset := axis * FLOOR_PROBE_SPAN_M
		var height := _probe_base_at(
			anchor, half.x + offset.x, half.y + offset.y
		)
		if is_nan(height):
			# No floor found on one side: an edge, a void or a face. Not a
			# place to lay a patch.
			return false
		heights[axis] = height
	var run := FLOOR_PROBE_SPAN_M * 2.0
	var rise_x: float = absf(heights[Vector2.RIGHT] - heights[Vector2.LEFT])
	var rise_z: float = absf(heights[Vector2.DOWN] - heights[Vector2.UP])
	var slope := sqrt(rise_x * rise_x + rise_z * rise_z) / maxf(run, 0.001)
	return slope <= tan(deg_to_rad(MAX_FLOOR_SLOPE_DEG))


## Clear loose material where the player is drilling a heap, and report the
## volume actually taken so the caller can credit it as yield. Zero when no
## patch owns that point, which the caller must read as "nothing here to dig"
## rather than as a completed dig.
func dig_spoil(world_point: Vector3, radius_m: float) -> float:
	if radius_m <= 0.0:
		return 0.0
	for index in range(_fields.size() - 1, -1, -1):
		var field := _fields[index]
		var anchor: GranularAnchor = field["anchor"]
		if not anchor.covers(world_point):
			continue
		var patch: GranularPatch = field["patch"]
		var local := anchor.to_patch(world_point)
		var cell := anchor.cell_at(local.x, local.z)
		var wanted := (
			GranularSpoil.sphere_volume_m3(radius_m) * SPOIL_DIG_MULTIPLIER
		)
		var taken := patch.take(
			cell.x,
			cell.y,
			int(ceil(radius_m / patch.cell_size)),
			wanted
		)
		if taken <= 0.0:
			continue
		# Digging a heap shakes what is left of it loose, so the pile slumps
		# into the bite instead of standing as a cliff the bit just cut.
		patch.mobilize(local.x, local.z, radius_m * 2.0)
		var view: GranularFieldView = field["view"]
		view.snap()
		_touch(index)
		return taken
	return 0.0


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
			if dx * dx + dz * dz > reach * reach:
				continue
			_resample_cell(anchor, patch, center.x + dx, center.y + dz)


## Same healing as `_resample_base`, over the whole patch instead of a disc.
## Cheap enough (one raycast per cell, ~1000 cells) to run on a fixed cadence
## rather than every dig — see `FULL_RESAMPLE_INTERVAL_MSEC`.
func _resample_patch_fully(anchor: GranularAnchor, patch: GranularPatch) -> void:
	for z in patch.depth:
		for x in patch.width:
			_resample_cell(anchor, patch, x, z)


func _resample_cell(
	anchor: GranularAnchor,
	patch: GranularPatch,
	x: int,
	z: int
) -> void:
	if not patch.in_bounds(x, z) or patch.is_blocked(x, z):
		return
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
	return _probe_base_at(
		anchor,
		float(x) * patch.cell_size,
		float(z) * patch.cell_size
	)


## Same probe at arbitrary patch-local metres, so the floor test can sample
## between cells before a patch exists.
func _probe_base_at(
	anchor: GranularAnchor,
	x_m: float,
	z_m: float
) -> float:
	var origin := anchor.to_world(x_m, z_m, BASE_PROBE_UP_M)
	if _voxel_tool.get_voxel_f(
		VoxelSpaceUtil.world_cell_from_point(_terrain, origin)
	) <= OPEN_SPACE_SDF:
		return NAN
	var down := -anchor.up()
	var hit := VoxelSpaceUtil.raycast_world(
		_voxel_tool,
		_terrain,
		origin,
		down,
		BASE_PROBE_UP_M + BASE_PROBE_DOWN_M
	)
	if hit == null:
		return NAN
	# Go through the shared hit-point helper rather than subtracting the raw
	# distance: it already carries the terrain-scale correction every other
	# SDF-derived point in the project uses, and reading the height off the
	# anchor keeps the answer in the same frame the patch stores bases in.
	return anchor.height_above_plane(
		VoxelSpaceUtil.raycast_hit_world_point(_terrain, origin, down, hit)
	)


## Keep the most recently dug patch last, so the cap frees the face the player
## walked away from rather than the one under their feet.
func _touch(index: int) -> void:
	if index < 0 or index >= _fields.size() - 1:
		return
	_fields.append(_fields.pop_at(index))
