class_name GranularPatch
extends RefCounted
## Loose-material layer on top of solid ground: a local height field of
## thickness per cell, relaxed to a material angle of repose.
##
## The voxel SDF stores distance, not amount, so it cannot carry loose
## material without eroding it. This patch stores thickness in metres, so
## `deposit`/`take`/`relax` conserve volume exactly. Spec:
## `docs/specs/GRANULAR-V0.md`.
##
## Deterministic by construction: fixed traversal order, simultaneous update,
## no RNG — safe for host-authoritative coop and save/replay.

const _SCRIPT := preload("res://scripts/simulation/runtime/granular_patch.gd")

const DEFAULT_CELL_SIZE_M := 0.25
const DEFAULT_REPOSE_DEG := 33.0
const MAX_RELAX_ITERATIONS := 128
const EPSILON_M := 1e-6
## Total thickness moved in one sweep below which the patch counts as settled.
const SETTLE_TOTAL_M := 1e-4

## Four-neighbour offsets; diagonals would need a longer step and buy little.
const _NEIGHBOUR_DX: Array[int] = [1, -1, 0, 0]
const _NEIGHBOUR_DZ: Array[int] = [0, 0, 1, -1]

var width: int = 0
var depth: int = 0
var cell_size: float = DEFAULT_CELL_SIZE_M
## tan(angle of repose): the steepest surface step the material holds.
var repose_tangent: float = tan(deg_to_rad(DEFAULT_REPOSE_DEG))

var _base: PackedFloat32Array = PackedFloat32Array()
var _thickness: PackedFloat32Array = PackedFloat32Array()
var _blocked: PackedByteArray = PackedByteArray()
var _delta: PackedFloat32Array = PackedFloat32Array()


static func create(
	new_width: int,
	new_depth: int,
	new_cell_size: float = DEFAULT_CELL_SIZE_M,
	repose_deg: float = DEFAULT_REPOSE_DEG
) -> GranularPatch:
	var patch: GranularPatch = _SCRIPT.new()
	patch.width = maxi(new_width, 1)
	patch.depth = maxi(new_depth, 1)
	patch.cell_size = maxf(new_cell_size, 0.01)
	patch.repose_tangent = tan(deg_to_rad(clampf(repose_deg, 1.0, 85.0)))
	var count := patch.width * patch.depth
	patch._base.resize(count)
	patch._thickness.resize(count)
	patch._blocked.resize(count)
	patch._delta.resize(count)
	return patch


func cell_area_m2() -> float:
	return cell_size * cell_size


func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and x < width and z >= 0 and z < depth


func index(x: int, z: int) -> int:
	return z * width + x


func set_base_height(x: int, z: int, height_m: float) -> void:
	if in_bounds(x, z):
		_base[index(x, z)] = height_m


func base_height(x: int, z: int) -> float:
	return _base[index(x, z)] if in_bounds(x, z) else 0.0


func set_blocked(x: int, z: int, blocked: bool) -> void:
	if not in_bounds(x, z):
		return
	var i := index(x, z)
	_blocked[i] = 1 if blocked else 0
	if blocked:
		# Rock cannot hold loose material; drop it rather than leak volume
		# silently on the next relax.
		_thickness[i] = 0.0


func is_blocked(x: int, z: int) -> bool:
	return in_bounds(x, z) and _blocked[index(x, z)] != 0


func thickness_at(x: int, z: int) -> float:
	return _thickness[index(x, z)] if in_bounds(x, z) else 0.0


## Surface the player and colliders see. NAN on blocked cells (a hole).
func surface_height(x: int, z: int) -> float:
	if not in_bounds(x, z):
		return NAN
	var i := index(x, z)
	if _blocked[i] != 0:
		return NAN
	return _base[i] + _thickness[i]


func total_volume_m3() -> float:
	var sum := 0.0
	for i in _thickness.size():
		sum += _thickness[i]
	return sum * cell_area_m2()


## Add material at a cell. Returns the accepted volume (0 on blocked cells).
func deposit(x: int, z: int, volume_m3: float) -> float:
	if volume_m3 <= 0.0 or not in_bounds(x, z):
		return 0.0
	var i := index(x, z)
	if _blocked[i] != 0:
		return 0.0
	_thickness[i] += volume_m3 / cell_area_m2()
	return volume_m3


## Scoop material from a disc of cells (a bucket). Takes proportionally from
## what is there and returns the volume actually removed, never more than the
## patch holds.
func take(x: int, z: int, radius_cells: int, volume_m3: float) -> float:
	if volume_m3 <= 0.0:
		return 0.0
	var radius := maxi(radius_cells, 0)
	var cells: PackedInt32Array = PackedInt32Array()
	var available := 0.0
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dz * dz > radius * radius:
				continue
			var cx := x + dx
			var cz := z + dz
			if not in_bounds(cx, cz):
				continue
			var i := index(cx, cz)
			if _blocked[i] != 0 or _thickness[i] <= EPSILON_M:
				continue
			cells.append(i)
			available += _thickness[i]
	if cells.is_empty() or available <= EPSILON_M:
		return 0.0
	var wanted_thickness := volume_m3 / cell_area_m2()
	var ratio := minf(wanted_thickness / available, 1.0)
	var removed := 0.0
	for i: int in cells:
		var amount := _thickness[i] * ratio
		_thickness[i] -= amount
		removed += amount
	return removed * cell_area_m2()


## Redistribute everything steeper than the angle of repose. Returns the
## number of iterations spent; fewer than `max_iterations` means it settled.
func relax(max_iterations: int = MAX_RELAX_ITERATIONS) -> int:
	var max_step := repose_tangent * cell_size
	var over := PackedFloat32Array()
	over.resize(4)
	var neighbour := PackedInt32Array()
	neighbour.resize(4)
	var iterations := 0
	while iterations < max_iterations:
		iterations += 1
		_delta.fill(0.0)
		var moved := 0.0
		for z in depth:
			for x in width:
				var i := index(x, z)
				if _blocked[i] != 0:
					continue
				var thickness := _thickness[i]
				if thickness <= EPSILON_M:
					continue
				var height := _base[i] + thickness
				var over_total := 0.0
				var lower_count := 0
				for k in 4:
					over[k] = 0.0
					neighbour[k] = -1
					var nx: int = x + _NEIGHBOUR_DX[k]
					var nz: int = z + _NEIGHBOUR_DZ[k]
					if not in_bounds(nx, nz):
						continue
					var ni := index(nx, nz)
					if _blocked[ni] != 0:
						continue
					var excess := (height - (_base[ni] + _thickness[ni])) - max_step
					if excess <= 0.0:
						continue
					over[k] = excess
					neighbour[k] = ni
					over_total += excess
					lower_count += 1
				if over_total <= 0.0:
					continue
				# Split the excess over the lower neighbours *and* the cell
				# itself: giving each neighbour its full excess overshoots,
				# because every transfer lowers this cell too. Never move
				# more than the cell holds, so thickness stays non-negative
				# and volume is conserved exactly.
				var move_total := minf(
					thickness,
					over_total / float(lower_count + 1)
				)
				if move_total <= EPSILON_M:
					continue
				for k in 4:
					if neighbour[k] < 0:
						continue
					var share := move_total * (over[k] / over_total)
					_delta[i] -= share
					_delta[neighbour[k]] += share
				moved += move_total
		for i in _thickness.size():
			if _delta[i] != 0.0:
				_thickness[i] = maxf(_thickness[i] + _delta[i], 0.0)
		if moved <= SETTLE_TOTAL_M:
			break
	return iterations


## Volume sitting on border cells: material that would spill out of the patch
## if spill-down existed. Non-zero means the patch is too small (Granular v0
## treats borders as walls).
func edge_pressure_m3() -> float:
	var sum := 0.0
	for z in depth:
		for x in width:
			if x != 0 and z != 0 and x != width - 1 and z != depth - 1:
				continue
			sum += _thickness[index(x, z)]
	return sum * cell_area_m2()


## Height field for `HeightMapShape3D.map_data`. Blocked cells become NAN,
## which both Jolt and GodotPhysics read as a hole in the collider.
func height_map_data() -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(_thickness.size())
	for i in _thickness.size():
		data[i] = NAN if _blocked[i] != 0 else _base[i] + _thickness[i]
	return data


## Raw thickness copy, for tests and snapshot serialization.
func thickness_data() -> PackedFloat32Array:
	return _thickness.duplicate()
