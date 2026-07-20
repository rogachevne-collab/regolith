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
## Where poured material comes to rest (the drained angle of repose).
const DEFAULT_REPOSE_DEG := 33.0
## How much steeper an undisturbed slope can stand before it lets go. Granular
## material is hysteretic: it yields at the angle of maximum stability and
## stops at the lower angle of repose, which is why a slope can sit metastable
## for a while and then collapse all at once.
const DEFAULT_STABILITY_MARGIN_DEG := 4.0
const MAX_RELAX_ITERATIONS := 128
const EPSILON_M := 1e-6
## Largest single-cell change in a sweep below which the patch counts as
## settled. Per cell, not summed over the patch: a discrete cone cannot sit
## exactly on the grid, so a fraction of a millimetre keeps shuffling near the
## crest forever, and a patch-wide sum never falls below any fixed threshold.
const SETTLE_MAX_CELL_M := 1e-3
## Damping on each transfer. Neighbours move in the same sweep, so handing over
## the full computed share lets the correction overshoot and ring.
const RELAX_DAMPING := 0.85

## Eight neighbours, each with its own distance. A four-neighbour stencil
## limits the step along the axes only, so the diagonal flank ends up about
## 1.41x steeper and piles come out as visible diamonds instead of cones.
const _NEIGHBOUR_DX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const _NEIGHBOUR_DZ: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]
## GDScript has no SQRT2 constant and a const array needs literals.
const _DIAGONAL := 1.4142135623730951
const _NEIGHBOUR_DISTANCE: Array[float] = [
	1.0, 1.0, 1.0, 1.0, _DIAGONAL, _DIAGONAL, _DIAGONAL, _DIAGONAL
]
const _NEIGHBOUR_COUNT := 8

## Avalanche front speed scales with sqrt(g * cell): lunar slumping is
## visibly slower than the same collapse on Earth, by the same factor a
## pendulum is. Dimensionless tuning coefficient.
const FLOW_SPEED_COEFF := 4.0
## Cap on sweeps per advance, so a long frame cannot spiral.
const MAX_SWEEPS_PER_ADVANCE := 8
## How far outside a footprint its displaced material is piled.
const RIM_WIDTH_CELLS := 1.6
## Gap between the cut disc and the heave annulus. Without it, spoil lands on
## the first cell outside the cut — and with a tight cut that is where a
## square load's corners rest, so the load perches on its own berm.
const HEAVE_GAP_CELLS := 1.0
## Fraction of a cell's mobilised material still moving one sweep later. Keeps
## an avalanche running past the point where the local slope alone would have
## stopped it, which is what makes it run out instead of just slumping.
const FLOW_PERSISTENCE := 0.55
## Bearing of freshly dumped spoil: pressure the surface carries before a load
## starts sinking, and stiffness with embedment. Tuned for readable game feel
## (a heavy crate beds in decimetres, not Apollo centimetres and not a
## half-metre shaft). Real lunar anchors are the sanity bounds, not targets.
const DEFAULT_BEARING_BASE_PA := 250.0
const DEFAULT_BEARING_GRADIENT_PA_PER_M := 12000.0
## How fast a load settles into material that cannot carry it. Bedding in is a
## slow yield, not a fall.
const SINK_SPEED_M_S := 0.5
## Ground level around a load is sampled this far beyond its own rim, or the
## reading is the spoil it just threw up and it concludes it has already sunk.
const GROUND_SAMPLE_MARGIN_CELLS := 2.0

var width: int = 0
var depth: int = 0
var cell_size: float = DEFAULT_CELL_SIZE_M
## tan(angle of repose): where moving material comes to rest.
var repose_tangent: float = tan(deg_to_rad(DEFAULT_REPOSE_DEG))
## tan(angle of maximum stability): where resting material lets go. Always
## >= `repose_tangent`; the gap is what a slope can hold in reserve.
var stability_tangent: float = tan(
	deg_to_rad(DEFAULT_REPOSE_DEG + DEFAULT_STABILITY_MARGIN_DEG)
)

## Ground pressure the surface carries before anything sinks into it.
var bearing_base_pa: float = DEFAULT_BEARING_BASE_PA
## How much more pressure the material carries per metre of embedment.
var bearing_gradient_pa_per_m: float = DEFAULT_BEARING_GRADIENT_PA_PER_M
## Relative compactness: scales bearing stiffness. Fresh dump ~1, fines softer,
## blocky spoil stiffer. Cheap stand-in for bulk density.
var density_scale: float = 1.0

var _base: PackedFloat32Array = PackedFloat32Array()
var _thickness: PackedFloat32Array = PackedFloat32Array()
var _blocked: PackedByteArray = PackedByteArray()
## Per-cell lid: material may not flow in above this height because a body is
## standing there. INF where nothing is in the way.
var _ceiling: PackedFloat32Array = PackedFloat32Array()
var _delta: PackedFloat32Array = PackedFloat32Array()
## Thickness currently mobilised per cell: material that is already sliding
## and therefore yields at the lower repose angle rather than the stability
## angle.
var _flowing: PackedFloat32Array = PackedFloat32Array()
var _flow_delta: PackedFloat32Array = PackedFloat32Array()
var _sweep_debt: float = 0.0
var _is_settled: bool = true


static func create(
	new_width: int,
	new_depth: int,
	new_cell_size: float = DEFAULT_CELL_SIZE_M,
	repose_deg: float = DEFAULT_REPOSE_DEG,
	stability_margin_deg: float = DEFAULT_STABILITY_MARGIN_DEG
) -> GranularPatch:
	var patch: GranularPatch = _SCRIPT.new()
	patch.width = maxi(new_width, 1)
	patch.depth = maxi(new_depth, 1)
	patch.cell_size = maxf(new_cell_size, 0.01)
	var repose := clampf(repose_deg, 1.0, 85.0)
	patch.repose_tangent = tan(deg_to_rad(repose))
	patch.stability_tangent = tan(
		deg_to_rad(clampf(repose + maxf(stability_margin_deg, 0.0), 1.0, 88.0))
	)
	var count := patch.width * patch.depth
	patch._base.resize(count)
	patch._thickness.resize(count)
	patch._blocked.resize(count)
	patch._ceiling.resize(count)
	patch._ceiling.fill(INF)
	patch._delta.resize(count)
	patch._flowing.resize(count)
	patch._flow_delta.resize(count)
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


## Cap how high material may stand in a cell, because a body occupies the
## space above it. Without this a body sitting in the material keeps
## displacing the same spoil that keeps slumping back underneath it, and
## ratchets itself down until it is buried.
func set_ceiling(x: int, z: int, height_m: float) -> void:
	if not in_bounds(x, z):
		return
	var i := index(x, z)
	_ceiling[i] = minf(_ceiling[i], height_m)
	if _base[i] + _thickness[i] > _ceiling[i]:
		# Material is standing where the body now is; it has to get out.
		_is_settled = false


## Lift every lid. Bodies move, so occupancy is rebuilt each tick. Does not
## wake the patch on its own — a settled patch under a body that never moved
## would otherwise sweep forever.
func clear_ceilings() -> void:
	_ceiling.fill(INF)


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


## How deep a load of the given ground pressure settles before the material
## carries it. Zero while the surface alone is strong enough, then linear in
## pressure: twice the load on the same footprint sinks roughly twice as far.
## `density_scale` stiffens the column the way denser spoil does.
func penetration_depth_m(pressure_pa: float) -> float:
	if pressure_pa <= bearing_base_pa:
		return 0.0
	var stiff := bearing_gradient_pa_per_m * maxf(density_scale, 0.05)
	return (pressure_pa - bearing_base_pa) / maxf(stiff, 1.0)


## Settle a load for one tick and return the height its underside now rests
## at. Material that cannot carry the pressure yields under it: the floor is
## lowered, the displaced spoil goes to the rim, and the column is lidded so
## it cannot slump back underneath. Everything that stands on loose material —
## a crate, a wheel, a landing pad — beds in through here.
func settle_load(
	center_x_m: float,
	center_z_m: float,
	radius_m: float,
	bottom_m: float,
	pressure_pa: float,
	delta_s: float
) -> float:
	var floor_height := bottom_m
	var ground := ground_level_around(center_x_m, center_z_m, radius_m)
	if not is_nan(ground):
		var remaining := penetration_depth_m(pressure_pa) - (ground - bottom_m)
		# Deadband: chasing the last fraction of a millimetre keeps cutting the
		# field every tick, so the patch never reports rest and everything
		# downstream of it rebuilds forever.
		if remaining > SETTLE_MAX_CELL_M:
			# Ease in: the material carries more the deeper the load goes, so
			# the last centimetres are slow. A constant rate that stops dead
			# reads as falling rather than as settling.
			floor_height -= minf(remaining, 1.0) * SINK_SPEED_M_S * delta_s
	imprint_disc(center_x_m, center_z_m, radius_m, floor_height)
	_lid_disc(center_x_m, center_z_m, radius_m, floor_height)
	return floor_height


## Undisturbed surface level around a load, sampled clear of its own rim and
## averaged over four directions so a load on a slope reads the slope rather
## than one side of it. NAN if nothing valid is in reach.
func ground_level_around(
	center_x_m: float,
	center_z_m: float,
	radius_m: float
) -> float:
	var reach := (
		radius_m
		+ (RIM_WIDTH_CELLS + HEAVE_GAP_CELLS + GROUND_SAMPLE_MARGIN_CELLS)
		* cell_size
	)
	var total := 0.0
	var samples := 0
	for offset: Vector2 in [
		Vector2(reach, 0.0),
		Vector2(-reach, 0.0),
		Vector2(0.0, reach),
		Vector2(0.0, -reach),
	]:
		var height := surface_height_at_m(
			center_x_m + offset.x, center_z_m + offset.y
		)
		if is_nan(height):
			continue
		total += height
		samples += 1
	return NAN if samples == 0 else total / float(samples)


## Lid exactly the load's footprint. Rounding it up to whole cells puts the
## rim the imprint just threw up under the lid, and the next sweep shoves it
## away — so a load bedding in leaves no ring and reads as falling through
## flat ground.
func _lid_disc(
	center_x_m: float,
	center_z_m: float,
	radius_m: float,
	height_m: float
) -> void:
	var center_x := center_x_m / cell_size
	var center_z := center_z_m / cell_size
	var radius_cells := radius_m / cell_size
	var reach := int(ceil(radius_cells))
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := int(round(center_x)) + dx
			var z := int(round(center_z)) + dz
			var offset_x := float(x) - center_x
			var offset_z := float(z) - center_z
			if offset_x * offset_x + offset_z * offset_z > radius_cells * radius_cells:
				continue
			set_ceiling(x, z, height_m)


## Bilinear surface height at patch-local metres — what anything standing on
## the material actually rests on, between cell centres. NAN if the sample
## falls on rock or outside the patch.
func surface_height_at_m(x_m: float, z_m: float) -> float:
	var fx := x_m / cell_size
	var fz := z_m / cell_size
	if fx < 0.0 or fz < 0.0 or fx > float(width - 1) or fz > float(depth - 1):
		return NAN
	var x0 := int(fx)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, width - 1)
	var z1 := mini(z0 + 1, depth - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var top_left := surface_height(x0, z0)
	var top_right := surface_height(x1, z0)
	var bottom_left := surface_height(x0, z1)
	var bottom_right := surface_height(x1, z1)
	if (
		is_nan(top_left)
		or is_nan(top_right)
		or is_nan(bottom_left)
		or is_nan(bottom_right)
	):
		return NAN
	return lerpf(
		lerpf(top_left, top_right, tx),
		lerpf(bottom_left, bottom_right, tx),
		tz
	)


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
	_is_settled = false
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
	_is_settled = false
	return removed * cell_area_m2()


## Press a rigid footprint into the material. Everything inside the disc that
## sits above `bottom_height_m` is cut away and piled in a rim outside it —
## displacement, not deletion. The heave starts past a small gap so a square
## load's corners do not sit on the spoil ring. Spoil is weighted toward the
## outer flank of the annulus (a cheap stand-in for a broad heave). Conserves
## volume exactly: if there is nowhere to put the spoil, nothing is cut.
##
## Coordinates are patch-local metres.
func imprint_disc(
	center_x_m: float,
	center_z_m: float,
	radius_m: float,
	bottom_height_m: float
) -> float:
	if radius_m <= 0.0:
		return 0.0
	var center_x := center_x_m / cell_size
	var center_z := center_z_m / cell_size
	var radius_cells := radius_m / cell_size
	var rim_inner := radius_cells + HEAVE_GAP_CELLS
	var rim_outer := rim_inner + RIM_WIDTH_CELLS
	var reach := int(ceil(rim_outer)) + 1
	var footprint := PackedInt32Array()
	var cut := PackedFloat32Array()
	var rim := PackedInt32Array()
	var rim_weight := PackedFloat32Array()
	var weight_total := 0.0
	var displaced_thickness := 0.0
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := int(round(center_x)) + dx
			var z := int(round(center_z)) + dz
			if not in_bounds(x, z):
				continue
			var i := index(x, z)
			if _blocked[i] != 0:
				continue
			var offset_x := float(x) - center_x
			var offset_z := float(z) - center_z
			var distance := sqrt(offset_x * offset_x + offset_z * offset_z)
			if distance <= radius_cells:
				var over := (_base[i] + _thickness[i]) - bottom_height_m
				if over <= 0.0:
					continue
				var removed := minf(over, _thickness[i])
				if removed <= EPSILON_M:
					continue
				footprint.append(i)
				cut.append(removed)
				displaced_thickness += removed
			elif distance > rim_inner and distance <= rim_outer:
				# Prefer the outer flank so the berm reads as heave, not a
				# knife-edge ring pressed against the footprint.
				var weight := (distance - rim_inner) + 0.25
				rim.append(i)
				rim_weight.append(weight)
				weight_total += weight
	if displaced_thickness <= EPSILON_M or rim.is_empty() or weight_total <= 0.0:
		return 0.0
	for k in footprint.size():
		_thickness[footprint[k]] -= cut[k]
	for k in rim.size():
		var i: int = rim[k]
		_thickness[i] += displaced_thickness * (rim_weight[k] / weight_total)
		# Spoil thrown out of a footprint lands loose, not compacted.
		_flowing[i] = _thickness[i]
	_is_settled = false
	return displaced_thickness * cell_area_m2()


## Disturb an area: mobilised material yields at the repose angle instead of
## the higher stability angle, so a slope that was standing metastable lets go.
## This is the hook for blasting, impacts, drilling and a collapsing roof.
func mobilize(center_x_m: float, center_z_m: float, radius_m: float) -> void:
	if radius_m <= 0.0:
		return
	var center_x := center_x_m / cell_size
	var center_z := center_z_m / cell_size
	var radius_cells := radius_m / cell_size
	var reach := int(ceil(radius_cells)) + 1
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := int(round(center_x)) + dx
			var z := int(round(center_z)) + dz
			if not in_bounds(x, z):
				continue
			var offset_x := float(x) - center_x
			var offset_z := float(z) - center_z
			if offset_x * offset_x + offset_z * offset_z > radius_cells * radius_cells:
				continue
			var i := index(x, z)
			if _blocked[i] != 0 or _thickness[i] <= EPSILON_M:
				continue
			_flowing[i] = _thickness[i]
			_is_settled = false


## How much material is currently sliding, in cubic metres.
func flowing_volume_m3() -> float:
	var sum := 0.0
	for i in _flowing.size():
		sum += _flowing[i]
	return sum * cell_area_m2()


## Redistribute everything steeper than the angle of repose. Returns the
## number of iterations spent; fewer than `max_iterations` means it settled.
func relax(max_iterations: int = MAX_RELAX_ITERATIONS) -> int:
	var resting_step := repose_tangent * cell_size
	var yield_step := stability_tangent * cell_size
	var over := PackedFloat32Array()
	over.resize(_NEIGHBOUR_COUNT)
	var neighbour := PackedInt32Array()
	neighbour.resize(_NEIGHBOUR_COUNT)
	var iterations := 0
	while iterations < max_iterations:
		_is_settled = false
		iterations += 1
		_delta.fill(0.0)
		_flow_delta.fill(0.0)
		var largest_move := 0.0
		for z in depth:
			for x in width:
				var i := index(x, z)
				if _blocked[i] != 0:
					continue
				var thickness := _thickness[i]
				if thickness <= EPSILON_M:
					continue
				var height := _base[i] + thickness
				# Material already sliding keeps going down to the repose
				# angle; material at rest has to be pushed past the higher
				# stability angle before it lets go at all.
				var step_per_metre := (
					resting_step if _flowing[i] > EPSILON_M else yield_step
				)
				var over_total := 0.0
				var lower_count := 0
				for k in _NEIGHBOUR_COUNT:
					over[k] = 0.0
					neighbour[k] = -1
					var nx: int = x + _NEIGHBOUR_DX[k]
					var nz: int = z + _NEIGHBOUR_DZ[k]
					if not in_bounds(nx, nz):
						continue
					var ni := index(nx, nz)
					if _blocked[ni] != 0:
						continue
					# A cell already filled to its lid cannot take any more:
					# this is what stops spoil from flowing back under a body.
					if _base[ni] + _thickness[ni] >= _ceiling[ni]:
						continue
					# Each neighbour holds its own slope over its own distance.
					var max_step: float = step_per_metre * _NEIGHBOUR_DISTANCE[k]
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
					RELAX_DAMPING * over_total / float(lower_count + 1)
				)
				if move_total <= EPSILON_M:
					continue
				for k in _NEIGHBOUR_COUNT:
					if neighbour[k] < 0:
						continue
					var share := move_total * (over[k] / over_total)
					_delta[i] -= share
					_delta[neighbour[k]] += share
					# Both ends are moving now, so both stay mobilised.
					_flow_delta[i] += share
					_flow_delta[neighbour[k]] += share
		for i in _thickness.size():
			var change := _delta[i]
			if change != 0.0:
				# The largest single-cell change in the sweep decides rest.
				_thickness[i] = maxf(_thickness[i] + change, 0.0)
				largest_move = maxf(largest_move, absf(change))
			# Mobilisation fades unless it was fed again this sweep.
			_flowing[i] = minf(
				_flowing[i] * FLOW_PERSISTENCE + _flow_delta[i], _thickness[i]
			)
		if largest_move <= SETTLE_MAX_CELL_M:
			# Material that has come to rest regains its static strength, so
			# the pile now stands until something disturbs it again. Without
			# this a settled heap keeps a trace of mobilisation forever and
			# can never be metastable a second time.
			_flowing.fill(0.0)
			_is_settled = true
			break
	return iterations


## True once a relax sweep found nothing left to move. Deposits and scoops
## clear it, so callers can drive settling until the patch reports rest.
func is_settled() -> bool:
	return _is_settled


## Relaxation sweeps per second at a given gravity. The avalanche front
## advances about one cell per sweep, so tying the rate to sqrt(g / cell)
## makes lunar material slump ~2.5x slower than the same collapse on Earth
## instead of at whatever the frame rate happens to be.
func settle_rate_hz(gravity_m_s2: float) -> float:
	return FLOW_SPEED_COEFF * sqrt(maxf(gravity_m_s2, 0.01) / cell_size)


## Advance settling by wall-clock time under a gravity field. Returns the
## sweeps actually run; leftover time is carried, so the same delta sequence
## always produces the same result.
func advance(delta_s: float, gravity_m_s2: float) -> int:
	if delta_s <= 0.0:
		return 0
	_sweep_debt += delta_s * settle_rate_hz(gravity_m_s2)
	var sweeps := mini(int(_sweep_debt), MAX_SWEEPS_PER_ADVANCE)
	if sweeps <= 0:
		return 0
	_sweep_debt -= float(sweeps)
	return relax(sweeps)


## Volume sitting on border cells: material pressed against the walls when
## spill is not drained. Useful as a diagnostic that the patch is too small.
func edge_pressure_m3() -> float:
	var sum := 0.0
	for z in depth:
		for x in width:
			if x != 0 and z != 0 and x != width - 1 and z != depth - 1:
				continue
			sum += _thickness[index(x, z)]
	return sum * cell_area_m2()


## How much of a cell is currently mobilised (sliding), metres of thickness.
func flowing_thickness_at(x: int, z: int) -> float:
	return _flowing[index(x, z)] if in_bounds(x, z) else 0.0


## Open-edge bit mask for `spill_edge`: 1 = -X, 2 = +X, 4 = -Z, 8 = +Z.
const EDGE_NEG_X := 1
const EDGE_POS_X := 2
const EDGE_NEG_Z := 4
const EDGE_POS_Z := 8
const EDGE_ALL := 15

## Drain material across selected open edges. Removes volume from those lip
## cells and returns spill events the caller must route downward. Each event:
## `{ "x_m", "z_m", "volume_m3", "out_x", "out_z" }` in patch-local metres.
## Closed edges stay walls. Caps total volume per call.
func spill_edge(max_volume_m3: float, open_mask: int = EDGE_ALL) -> Array:
	var events: Array = []
	if max_volume_m3 <= EPSILON_M or open_mask == 0:
		return events
	var candidates: Array = []
	var weight_total := 0.0
	for z in depth:
		for x in width:
			var out_x := 0.0
			var out_z := 0.0
			if x == 0 and (open_mask & EDGE_NEG_X) != 0:
				out_x -= 1.0
			elif x == width - 1 and (open_mask & EDGE_POS_X) != 0:
				out_x += 1.0
			if z == 0 and (open_mask & EDGE_NEG_Z) != 0:
				out_z -= 1.0
			elif z == depth - 1 and (open_mask & EDGE_POS_Z) != 0:
				out_z += 1.0
			if out_x == 0.0 and out_z == 0.0:
				continue
			var i := index(x, z)
			if _blocked[i] != 0 or _thickness[i] <= EPSILON_M:
				continue
			var out_len := sqrt(out_x * out_x + out_z * out_z)
			out_x /= out_len
			out_z /= out_len
			# Sliding spoil leaves fast; a resting berm against the lip still
			# bleeds slowly, or a cone pressed to the wall would never leave.
			var weight := _flowing[i] * 3.0 + _thickness[i] * 0.2
			if weight <= EPSILON_M:
				continue
			candidates.append({
				"i": i,
				"x": x,
				"z": z,
				"out_x": out_x,
				"out_z": out_z,
				"weight": weight,
			})
			weight_total += weight
	if candidates.is_empty() or weight_total <= 0.0:
		return events
	var budget_thickness := max_volume_m3 / cell_area_m2()
	var removed_thickness := 0.0
	for entry: Dictionary in candidates:
		if removed_thickness >= budget_thickness:
			break
		var i: int = entry["i"]
		var share := budget_thickness * (float(entry["weight"]) / weight_total)
		var take_th := minf(_thickness[i], share)
		if take_th <= EPSILON_M:
			continue
		_thickness[i] -= take_th
		_flowing[i] = maxf(_flowing[i] - take_th, 0.0)
		removed_thickness += take_th
		var volume := take_th * cell_area_m2()
		events.append({
			"x_m": float(entry["x"]) * cell_size,
			"z_m": float(entry["z"]) * cell_size,
			"volume_m3": volume,
			"out_x": float(entry["out_x"]),
			"out_z": float(entry["out_z"]),
		})
	if removed_thickness > EPSILON_M:
		_is_settled = false
	return events


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
