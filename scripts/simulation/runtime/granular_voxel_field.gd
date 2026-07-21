class_name GranularVoxelFieldScript
extends RefCounted
## Loose material as a *volume* of small voxels that flows, rather than a
## height field draped over the ground.
##
## Each cell stores a fill fraction in 0..1, so mass is a number that can be
## moved and counted — the reason a height field was used before, and the
## reason the terrain SDF cannot do this job itself (it stores distance, and
## relaxing it erodes instead of transporting). Unlike a height field this is
## single-valued in nothing: material can sit in a tunnel, against a wall, or
## under an overhang, and two heaps that meet are simply the same field.
##
## Deterministic by construction: fixed traversal order (the active list is
## sorted every sweep), no RNG — safe for host-authoritative coop and replay.
##
## Spike scope: one bounded box with `-Y` as down. The real thing chunks this
## and takes down from the radial, which changes which neighbour is "below"
## and nothing else about the rules.

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/granular_voxel_field.gd"
)

const DEFAULT_CELL_SIZE_M := 0.25
## A cell holding less than this is treated as empty: chasing the last
## fractions of a percent keeps cells active forever and the field never rests.
const MIN_MASS := 0.004
## Smallest transfer worth making when spreading. Falling has no such floor —
## anything unsupported must come down whatever its size — but spreading does,
## because a pile approaching its angle of repose otherwise trades vanishing
## slivers back and forth for thousands of sweeps after it already looks and
## behaves like a settled heap. The tail was most of the settling time and
## none of the result.
const MIN_SPREAD_TRANSFER := 0.02
const FULL := 1.0

## Share of what *can* fall that actually falls in one sweep, and share of the
## excess handed sideways-and-down. Both are per-sweep, so they set speed
## together with how often the field is stepped: at 1.0 material jumps a whole
## cell per sweep, which needs a low sweep rate to fall at a believable speed
## and therefore moves in visible steps. Fractions are smoother *and* free,
## because the mesher reads a partly filled cell as a surface partway through
## it — the picture moves under a voxel even though the grid did not.
##
## Together these are also the material's viscosity: a low `spread_rate` with
## a high `spread_min_difference` is dry sand holding a steep face; raise the
## first and drop the second and the same field behaves like slurry.
var fall_rate := 0.7
var spread_rate := 0.5
## A neighbour must be this much emptier before material moves into it.
## Without a threshold a pile keeps creeping outward one hair at a time and
## never stands at an angle at all.
var spread_min_difference := 0.08
## Flow along a level, costing no height. Sideways-and-down alone can only
## produce a 45 degree pile; this is what buys the extra horizontal travel a
## shallower angle needs. Its threshold is the friction that stops a heap from
## levelling out into a puddle — set `lateral_min_difference` to zero and the
## same field behaves like a liquid.
var lateral_rate := 0.12
var lateral_min_difference := 0.51

## Sideways-and-down neighbours: the four faces and the four diagonals, each
## one step down. Material that cannot fall straight takes these, and that is
## what builds a cone instead of a tower.
const _SPREAD_DX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const _SPREAD_DZ: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]
## Diagonals travel further for the same step down, so they get a smaller
## share; without this the pile comes out square instead of round.
const _SPREAD_WEIGHT: Array[float] = [
	1.0, 1.0, 1.0, 1.0, 0.7071, 0.7071, 0.7071, 0.7071
]
const _SPREAD_COUNT := 8

var size := Vector3i.ZERO
var cell_size := DEFAULT_CELL_SIZE_M

var _mass: PackedFloat32Array = PackedFloat32Array()
var _solid: PackedByteArray = PackedByteArray()
## Which `_solid` entries have actually been established. Rock in the world is
## a voxel field of its own with hundreds of thousands of cells under a patch
## this size, far too many to ask about up front — but only the handful of
## cells material is currently touching ever matter. So `solid_query` is asked
## on first use and the answer memoised here, and carving invalidates a box of
## it rather than the whole field.
var _solid_known: PackedByteArray = PackedByteArray()
## Answers "is this cell rock?" in field coordinates. Left null the field is
## self-contained and only `set_solid` decides, which is what the demos and
## tests use. A pure function of the cell, so caching it changes nothing about
## determinism.
var solid_query: Callable = Callable()
## Cells worth visiting next sweep. Everything at rest costs nothing, which is
## what makes a field of millions of cells affordable: only the handful that
## are still moving are ever touched.
var _active: PackedInt32Array = PackedInt32Array()
var _queued: PackedByteArray = PackedByteArray()
var _next: PackedInt32Array = PackedInt32Array()

## Cells whose mass changed since the last flush. Whatever renders this field
## only has to touch these — a settled heap of thousands of cells costs the
## renderer nothing per tick, the same way it costs the simulation nothing.
var _dirty: PackedInt32Array = PackedInt32Array()
var _dirty_flag: PackedByteArray = PackedByteArray()

## Scratch for `_spread`, sized to the neighbour count once and reused. See
## the note there: allocating these per call dominated the sweep.
var _spread_targets: PackedInt32Array = PackedInt32Array()
var _spread_shares: PackedFloat32Array = PackedFloat32Array()

var _last_active_count := 0
## Where the next budgeted sweep starts in the sorted active list. Keeps a
## backlog from starving the same cells sweep after sweep.
var _budget_cursor := 0


static func create(
	new_size: Vector3i,
	new_cell_size: float = DEFAULT_CELL_SIZE_M
) -> GranularVoxelFieldScript:
	var field: GranularVoxelFieldScript = _SCRIPT.new()
	field.size = Vector3i(
		maxi(new_size.x, 1), maxi(new_size.y, 1), maxi(new_size.z, 1)
	)
	field.cell_size = maxf(new_cell_size, 0.01)
	var count := field.size.x * field.size.y * field.size.z
	field._mass.resize(count)
	field._solid.resize(count)
	field._queued.resize(count)
	field._dirty_flag.resize(count)
	field._solid_known.resize(count)
	field._spread_targets.resize(_SPREAD_COUNT)
	field._spread_shares.resize(_SPREAD_COUNT)
	return field


func in_bounds(x: int, y: int, z: int) -> bool:
	return (
		x >= 0 and x < size.x
		and y >= 0 and y < size.y
		and z >= 0 and z < size.z
	)


func index(x: int, y: int, z: int) -> int:
	return (y * size.z + z) * size.x + x


func cell_volume_m3() -> float:
	return cell_size * cell_size * cell_size


func set_solid(x: int, y: int, z: int, solid: bool) -> void:
	if not in_bounds(x, y, z):
		return
	var i := index(x, y, z)
	_solid[i] = 1 if solid else 0
	# Stated explicitly, so it is not overwritten by a later lazy query.
	_solid_known[i] = 1


func is_solid(x: int, y: int, z: int) -> bool:
	return in_bounds(x, y, z) and _solid_at(index(x, y, z))


## Rock at a cell, asking `solid_query` the first time and remembering the
## answer. Everything in the stepping rules goes through here.
func _solid_at(i: int) -> bool:
	if _solid_known[i] == 0:
		_solid_known[i] = 1
		_solid[i] = 0
		if solid_query.is_valid():
			var y := i / (size.x * size.z)
			var z := (i / size.x) % size.z
			var x := i % size.x
			if bool(solid_query.call(Vector3i(x, y, z))):
				_solid[i] = 1
	return _solid[i] != 0


## Forget what was known about rock in a box of cells and wake anything lying
## there. This is what a carve calls: dig out from under a heap and the heap
## has to discover it is no longer supported, which is exactly the case that
## used to leave material standing in the air.
func invalidate_solid(from_cell: Vector3i, to_cell: Vector3i) -> void:
	var lo := Vector3i(
		maxi(mini(from_cell.x, to_cell.x), 0),
		maxi(mini(from_cell.y, to_cell.y), 0),
		maxi(mini(from_cell.z, to_cell.z), 0)
	)
	var hi := Vector3i(
		mini(maxi(from_cell.x, to_cell.x), size.x - 1),
		mini(maxi(from_cell.y, to_cell.y), size.y - 1),
		mini(maxi(from_cell.z, to_cell.z), size.z - 1)
	)
	for y in range(lo.y, hi.y + 1):
		for z in range(lo.z, hi.z + 1):
			for x in range(lo.x, hi.x + 1):
				var i := index(x, y, z)
				# Forgetting is free; waking is not. Only cells that actually
				# hold material can have lost their support, and only they need
				# to re-check — an empty cell has nothing to drop. Waking the
				# whole box instead meant a single drill bite queued tens of
				# thousands of cells, nearly all of them empty, and that storm
				# was what the frame rate was paying for while digging.
				_solid_known[i] = 0
				if _mass[i] > 0.0:
					_wake(x, y, z)


func mass_at(x: int, y: int, z: int) -> float:
	return _mass[index(x, y, z)] if in_bounds(x, y, z) else 0.0


## A box of mass, cells outside the field reading as empty — so a caller may
## ask for a box that hangs over the edge.
##
## For anything that reads whole neighbourhoods — a renderer rebuilding a
## surface — this is the difference between one script call and one per cell,
## and per-cell calls were most of the cost of drawing the field at all.
##
## Returned rather than written into a caller's array, which is what this used
## to do. The native field cannot offer that shape at all: a packed array
## handed to a bound method arrives as a copy, so writing into it would never
## reach the caller. One signature both implementations can honour is worth
## more than the allocation it costs here, on a path that is being retired.
func copy_mass_box(lo: Vector3i, extent: Vector3i) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var total := extent.x * extent.y * extent.z
	if out.size() < total:
		out.resize(total)
	var i := 0
	for y in extent.y:
		var cy := lo.y + y
		for z in extent.z:
			var cz := lo.z + z
			if cy < 0 or cy >= size.y or cz < 0 or cz >= size.z:
				for _x in extent.x:
					out[i] = 0.0
					i += 1
				continue
			var row := (cy * size.z + cz) * size.x
			for x in extent.x:
				var cx := lo.x + x
				out[i] = (
					_mass[row + cx] if cx >= 0 and cx < size.x else 0.0
				)
				i += 1
	return out


## A box of rock as 0/1. Cells outside the
## field read as empty. Unknown cells are established through `solid_query` and
## memoised exactly as `is_solid` would, so this is the same answer in bulk —
## but the common case, a cell already known, costs no call at all.
func copy_solid_box(lo: Vector3i, extent: Vector3i) -> PackedByteArray:
	var out := PackedByteArray()
	var total := extent.x * extent.y * extent.z
	if out.size() < total:
		out.resize(total)
	var i := 0
	for y in extent.y:
		var cy := lo.y + y
		for z in extent.z:
			var cz := lo.z + z
			if cy < 0 or cy >= size.y or cz < 0 or cz >= size.z:
				for _x in extent.x:
					out[i] = 0
					i += 1
				continue
			var row := (cy * size.z + cz) * size.x
			for x in extent.x:
				var cx := lo.x + x
				if cx < 0 or cx >= size.x:
					out[i] = 0
				else:
					var j := row + cx
					out[i] = (
						_solid[j] if _solid_known[j] != 0
						else (1 if _solid_at(j) else 0)
					)
				i += 1
	return out


## Total loose material held, in cubic metres.
func total_volume_m3() -> float:
	var sum := 0.0
	for i in _mass.size():
		sum += _mass[i]
	return sum * cell_volume_m3()


func active_count() -> int:
	return _last_active_count


## At rest only when nothing is moving *and* nothing is queued to move. A
## deposit lands in the pending queue, so checking the current list alone
## reports rest on the very tick material was poured in.
func is_settled() -> bool:
	return _active.is_empty() and _next.is_empty()


## Add material to a cell, up to what it can hold. Returns the volume the cell
## accepted, so a caller pouring more than fits knows what it still owes.
func deposit(x: int, y: int, z: int, volume_m3: float) -> float:
	if volume_m3 <= 0.0 or not in_bounds(x, y, z):
		return 0.0
	var i := index(x, y, z)
	if _solid_at(i):
		return 0.0
	var room := FULL - _mass[i]
	if room <= 0.0:
		return 0.0
	var added: float = minf(volume_m3 / cell_volume_m3(), room)
	_mass[i] += added
	_mark_dirty(i)
	_wake(x, y, z)
	return added * cell_volume_m3()


## Remove everything a cell holds and return the volume taken — a bucket, a
## drill, a conveyor pickup. Wakes the neighbourhood so the heap above slumps
## into the bite instead of standing over it as a cliff.
func take(x: int, y: int, z: int) -> float:
	if not in_bounds(x, y, z):
		return 0.0
	var i := index(x, y, z)
	var mass := _mass[i]
	if mass <= 0.0:
		return 0.0
	_mass[i] = 0.0
	_mark_dirty(i)
	_wake(x, y, z)
	return mass * cell_volume_m3()


## Record that a cell's mass changed, for whatever draws the field.
## Remove part of what a cell holds and hand it back, rather than all of it.
##
## `take` empties a cell, which is what a scoop does. A tool that shoves
## material aside needs the other half of that: a share out, to be put down
## somewhere else. The volume is returned so the caller can place exactly what
## it removed and the field stays honest about how much there is.
func take_fraction(x: int, y: int, z: int, fraction: float) -> float:
	if fraction <= 0.0 or not in_bounds(x, y, z):
		return 0.0
	var i := index(x, y, z)
	var mass := _mass[i]
	if mass <= 0.0:
		return 0.0
	var removed := minf(mass, mass * fraction)
	# Leaving a sliver behind keeps a cell active for hundreds of sweeps for
	# nothing, the same reason `MIN_MASS` exists at all.
	if mass - removed < MIN_MASS:
		removed = mass
	_mass[i] = mass - removed
	_touch(i)
	_wake(x, y, z)
	return removed * cell_volume_m3()


func _mark_dirty(i: int) -> void:
	if _dirty_flag[i] != 0:
		return
	_dirty_flag[i] = 1
	_dirty.append(i)


## Hand over the cells that changed since the last call and start a new batch.
func take_dirty() -> PackedInt32Array:
	var batch := _dirty
	for i: int in batch:
		_dirty_flag[i] = 0
	_dirty = PackedInt32Array()
	return batch


## Queue a single cell for the next sweep. The `_queued` flag makes this
## idempotent, so callers can touch the same cell freely.
func _touch(i: int) -> void:
	if _queued[i] != 0:
		return
	_queued[i] = 1
	_next.append(i)


## Wake a cell and its six face neighbours. Face-only on purpose: waking all
## 26 surrounding cells was the single most expensive thing this field did —
## roughly four times the work for no extra correctness, because a diagonal
## neighbour is always reached through a face neighbour on the following
## sweep anyway. The cell above matters most: it is the one that has just lost
## its support and has to come down.
func _wake(x: int, y: int, z: int) -> void:
	if not in_bounds(x, y, z):
		return
	_touch(index(x, y, z))
	if x > 0:
		_touch(index(x - 1, y, z))
	if x < size.x - 1:
		_touch(index(x + 1, y, z))
	if y > 0:
		_touch(index(x, y - 1, z))
	if y < size.y - 1:
		_touch(index(x, y + 1, z))
	if z > 0:
		_touch(index(x, y, z - 1))
	if z < size.z - 1:
		_touch(index(x, y, z + 1))


## One settling sweep, visiting at most `max_cells`. Returns the number of
## cells visited, so a caller can see the cost as well as the result.
##
## The cap is what keeps a large collapse from blowing a frame: whatever does
## not fit is carried to the next sweep rather than dropped, so the material
## settles a little slower under load instead of stalling the game. Volume is
## unaffected either way.
func step(max_cells: int = 0) -> int:
	if _next.is_empty() and _active.is_empty():
		_last_active_count = 0
		return 0
	if not _next.is_empty():
		_active = _next
		_next = PackedInt32Array()
	# Sorted so the result never depends on the order cells happened to be
	# woken in — two peers must reach the same pile from the same dig, and the
	# carry-over below has to take a stable prefix for the same reason.
	# Sorted, and it earns its cost. The index is y-major, so this walks the
	# backlog bottom-up: material below moves out of the way before the cell
	# above is asked to come down, and a column resolves in far fewer sweeps.
	# Measured without it the suite ran *slower* (1550 sweeps against 1466,
	# worst sweep 6.00 ms against 5.43) — the sort was never the bottleneck it
	# looked like.
	var order := _active
	order.sort()
	_active = PackedInt32Array()
	var count := order.size()
	var budget := count if max_cells <= 0 else mini(max_cells, count)
	for k in count:
		_queued[order[k]] = 0
	# Take the budget as a window that rotates between sweeps, not as the first
	# N of a sorted list. The index is y-major, so a sorted prefix is always the
	# lowest cells: with a backlog bigger than the budget the top of a falling
	# column was never reached at all and simply hung in the air. The cursor is
	# ordinary state, so the traversal stays deterministic.
	var start := 0 if count == 0 else _budget_cursor % count
	for k in budget:
		_step_cell(order[(start + k) % count])
	for k in range(budget, count):
		# Carried, not dropped: re-queue through the normal path so the next
		# sweep picks it up exactly once.
		_touch(order[(start + k) % count])
	_budget_cursor = 0 if count == 0 else (start + budget) % count
	_last_active_count = budget
	return budget


func _step_cell(i: int) -> void:
	var mass := _mass[i]
	# Only genuinely empty cells are skipped. Skipping everything under
	# `MIN_MASS` stranded the residues that spreading leaves behind: specks far
	# too small to be worth a transfer, but with nothing underneath them, left
	# hanging in the air forever. They fall whole instead (see below) and merge
	# into whatever they land on, so nothing accumulates and nothing hovers.
	if mass <= 0.0:
		return
	var x := i % size.x
	var z := (i / size.x) % size.z
	var y := i / (size.x * size.z)
	# Straight down first: nothing spreads sideways while it can still fall.
	if y > 0:
		var below := index(x, y - 1, z)
		if not _solid_at(below):
			var room := FULL - _mass[below]
			if room > 0.0:
				var movable: float = minf(mass, room)
				var moved: float = movable * fall_rate
				# A residue too small to be worth a fraction still has nothing
				# holding it up, so it goes down whole rather than not at all.
				# Gating this on the same threshold as everything else left
				# specks of material hanging in the air permanently — visible
				# as a thin drizzle that never lands.
				if moved < MIN_MASS:
					moved = movable
				if moved > 0.0:
					_mass[i] -= moved
					_mass[below] += moved
					_mark_dirty(i)
					_mark_dirty(below)
					_wake(x, y, z)
					_wake(x, y - 1, z)
					mass = _mass[i]
					if mass < MIN_MASS:
						return
	if y <= 0:
		return
	# Resting on something. Two ways out, and the balance between them is what
	# sets the angle of repose.
	#
	# Sideways-and-down moves one cell out for one cell down, which is 45
	# degrees and nothing else — it is the steepest a pile can be and, on its
	# own, also the shallowest. Real regolith rests nearer 33, so material also
	# has to travel *along* a level: at 33 degrees it goes about 1.5 cells out
	# per cell down, and the only way to buy that extra horizontal distance is
	# a transfer that costs no height.
	#
	# Each is gated by its own difference threshold, which is the friction. Drop
	# the lateral threshold to zero and the pile levels out like a liquid; raise
	# it and the pile stands steeper. That pair is the material.
	_spread(i, x, y, z, mass, y - 1, spread_rate, spread_min_difference)
	mass = _mass[i]
	if mass > 0.0:
		_spread(i, x, y, z, mass, y, lateral_rate, lateral_min_difference)


## Hand mass from a cell to its eight horizontal neighbours on level `to_y`,
## in proportion to how much emptier each one is. Shared by the two spreading
## modes because they differ only in the level they target and how freely they
## let material go.
func _spread(
	i: int,
	x: int,
	y: int,
	z: int,
	mass: float,
	to_y: int,
	rate: float,
	min_difference: float
) -> void:
	if rate <= 0.0:
		return
	# Scratch buffers reused across calls rather than allocated per cell. This
	# runs twice for every cell of every sweep, and two fresh arrays each time
	# was the single most expensive thing the field did — far more than the
	# arithmetic they held.
	var targets := _spread_targets
	var shares := _spread_shares
	var count := 0
	var share_total := 0.0
	for k in _SPREAD_COUNT:
		var nx: int = x + _SPREAD_DX[k]
		var nz: int = z + _SPREAD_DZ[k]
		if not in_bounds(nx, to_y, nz):
			continue
		var ni := index(nx, to_y, nz)
		if _solid_at(ni):
			continue
		var difference := mass - _mass[ni]
		if difference <= min_difference:
			continue
		var share: float = difference * _SPREAD_WEIGHT[k]
		targets[count] = ni
		shares[count] = share
		count += 1
		share_total += share
	if count == 0 or share_total <= 0.0:
		return
	# Never hand out more than the cell holds, and split the excess over the
	# targets *and* this cell, so a transfer cannot overshoot into a hole that
	# the next sweep has to undo.
	var budget: float = minf(
		mass, rate * share_total / float(count + 1)
	)
	if budget < MIN_SPREAD_TRANSFER:
		return
	for k in count:
		var ni: int = targets[k]
		var amount: float = budget * (shares[k] / share_total)
		var room := FULL - _mass[ni]
		if room <= 0.0:
			continue
		amount = minf(amount, room)
		if amount <= 0.0:
			continue
		_mass[i] -= amount
		_mass[ni] += amount
		_mark_dirty(i)
		_mark_dirty(ni)
		_wake(ni % size.x, ni / (size.x * size.z), (ni / size.x) % size.z)
	_wake(x, y, z)
