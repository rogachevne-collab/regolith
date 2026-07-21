class_name GranularVoxelRegion
extends RefCounted
## One box of flowing loose material, placed somewhere on the planet.
##
## Ties together the three pieces that make the volumetric granular layer work
## in a world rather than in a demo:
##
##   * `GranularAnchor` — the frame. The field's own "down" is -Y and stays
##     that way; what turns is the box. Gravity is radial on a planetoid, so
##     the anchor's Y is the local up, and over a box this size that is exact
##     enough to ignore: on a 9.5 km body the radial swings 0.14 degrees across
##     24 metres, a fraction of one cell.
##   * `GranularVoxelField` — the simulation, unchanged and unaware of any of
##     this.
##   * a rock oracle — the field asks whether a cell is solid, and the answer
##     comes from the world's own voxel terrain, so material rests on real
##     ground and falls when that ground is carved away.
##
## Deliberately not a Node: the region is simulation, and it works with no
## rendering at all. Presentation attaches to it, not the other way round.

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/granular_voxel_region.gd"
)

const DEFAULT_CELLS := 96
const DEFAULT_CELL_SIZE_M := 0.25
## Occupancy above which a voxel of the world counts as rock to stand on.
## `TerrainExcavationService.sdf_occupancy` is the same measure the excavation
## path already uses to weigh dug volume, so "full" means one thing project
## wide.
const SOLID_OCCUPANCY := 0.5
## Ceiling on how wide one delivery spreads. A meteorite's worth of material
## would otherwise size itself a footprint bigger than the region.
const MAX_DEPOSIT_RADIUS_CELLS := 16
## How far a column looks down for its own ground before giving up and filling
## where it is. Short: this runs per column of every deposit.
const GROUND_SEARCH_CELLS := 12

var anchor: GranularAnchor
## The simulation, which is now the native `GranularVoxelField` from the
## `regolith_moon_bake` extension rather than the script of the same name.
## The script survives as `GranularVoxelFieldScript`, and it is the
## specification: `scenes/test_granular_field_parity.tscn` holds the two to
## identical output, cell for cell and sweep for sweep, across a pour, a
## starved budget, an undermining and the mutators.
##
## The native class took the name rather than sitting beside it under its own,
## because a field declared as one-or-the-other has to be untyped — and in a
## project that treats inference-from-Variant as an error, one untyped `var`
## turned into seventeen broken expressions downstream. Keeping the name keeps
## every annotation and every call site exactly as it was.
var field: GranularVoxelField
## Cell in the field that the anchor's origin corresponds to. The field counts
## from a corner and the anchor is centred, so this is the shift between them.
var _centre_cell := Vector3i.ZERO


## Build a region centred on a world point, with local up taken from the
## gravity field there. `terrain` and `voxel_tool` may be null, in which case
## nothing is solid until `field.set_solid` says so — which is what the
## headless tests use.
static func create(
	centre_world: Vector3,
	up: Vector3,
	terrain: Node3D = null,
	voxel_tool: VoxelTool = null,
	cells: int = DEFAULT_CELLS,
	cell_size: float = DEFAULT_CELL_SIZE_M
) -> GranularVoxelRegion:
	var region: GranularVoxelRegion = _SCRIPT.new()
	var span := maxi(cells, 1)
	region.anchor = GranularAnchor.create(
		centre_world, up, span, span, cell_size
	)
	region.field = GranularVoxelField.create(
		Vector3i(span, span, span), cell_size
	)
	region._centre_cell = Vector3i(span / 2, span / 2, span / 2)
	if terrain != null and voxel_tool != null:
		region.field.solid_query = func(cell: Vector3i) -> bool:
			return region._cell_is_rock(cell, terrain, voxel_tool)
	return region


## World transform of the box, for anything that has to draw or collide it —
## a fine `VoxelTerrain` gets exactly this, and then a field cell and a voxel
## of that terrain are the same thing.
func world_transform() -> Transform3D:
	var half := float(field.size.x) * field.cell_size * 0.5
	return Transform3D(
		anchor.basis, anchor.center_world - anchor.basis * Vector3.ONE * half
	)


## Local up at the region, which is the direction material falls away from.
func up() -> Vector3:
	return anchor.basis.y


func cell_to_world(cell: Vector3i) -> Vector3:
	return world_transform() * (Vector3(cell) * field.cell_size)


func world_to_cell(world_point: Vector3) -> Vector3i:
	var local := world_transform().affine_inverse() * world_point
	return Vector3i(
		int(floor(local.x / field.cell_size)),
		int(floor(local.y / field.cell_size)),
		int(floor(local.z / field.cell_size))
	)


## Whether a world point falls inside the box, optionally requiring a margin of
## clear cells so a deposit is not cut in half by the border.
func covers(world_point: Vector3, margin_m: float = 0.0) -> bool:
	var local := world_transform().affine_inverse() * world_point
	var span := float(field.size.x) * field.cell_size
	return (
		local.x >= margin_m and local.x <= span - margin_m
		and local.y >= margin_m and local.y <= span - margin_m
		and local.z >= margin_m and local.z <= span - margin_m
	)


## Pour material in at a world point as a low dome, spread wide enough that it
## arrives at roughly the shape it would settle into. Returns the volume
## placed; anything short of what was asked is volume the caller still owes.
##
## The footprint grows with the load instead of being fixed. A fixed footprint
## turns a big delivery — fast drilling, a meteorite — into a tall narrow
## column, and the field then has to spend hundreds of sweeps toppling it,
## which is both most of its work and a comically slow wobble to watch. Sized
## from the volume, the same material lands two or three cells deep and only
## needs a nudge to sit right.
##
## Each column finds its own ground, so the heap drapes over uneven rock rather
## than hanging off whatever height the centre happened to land at.
func deposit_at(
	world_point: Vector3,
	volume_m3: float,
	min_radius_cells: int = 2,
	max_stack_cells: int = 3
) -> float:
	if volume_m3 <= 0.0:
		return 0.0
	var centre := world_to_cell(world_point)
	var cells_needed := volume_m3 / field.cell_volume_m3()
	# Radius that keeps the pile within `max_stack_cells` layers: a disc of
	# radius r holds about PI * r^2 cells per layer.
	var radius := maxi(
		min_radius_cells,
		int(ceil(sqrt(cells_needed / (PI * float(maxi(max_stack_cells, 1))))))
	)
	radius = mini(radius, MAX_DEPOSIT_RADIUS_CELLS)
	# Paraboloid weights: thickest at the middle, feathering to nothing at the
	# rim, which is close to what a settled heap looks like from the start.
	var columns: Array[Vector2i] = []
	var weights := PackedFloat32Array()
	var weight_total := 0.0
	var radius_sq := float(radius * radius)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var distance_sq := float(dx * dx + dz * dz)
			if distance_sq > radius_sq:
				continue
			var weight := 1.0 - distance_sq / (radius_sq + 1.0)
			columns.append(Vector2i(dx, dz))
			weights.append(weight)
			weight_total += weight
	if columns.is_empty() or weight_total <= 0.0:
		return 0.0
	var placed := 0.0
	var remaining := volume_m3
	for pass_index in 2:
		for k in columns.size():
			if remaining <= 0.0:
				break
			var column: Vector2i = columns[k]
			# Second pass mops up whatever the first could not place — a column
			# that hit rock or ran out of room hands its share to the rest,
			# rather than the load quietly shrinking.
			var share := (
				volume_m3 * weights[k] / weight_total
				if pass_index == 0
				else remaining
			)
			share = minf(share, remaining)
			if share <= 0.0:
				continue
			var ground := _ground_cell_below(
				Vector3i(centre.x + column.x, centre.y, centre.z + column.y),
				GROUND_SEARCH_CELLS
			)
			for dy in field.size.y:
				if share <= 0.0:
					break
				var accepted := field.deposit(
					ground.x, ground.y + dy, ground.z, share
				)
				placed += accepted
				remaining -= accepted
				share -= accepted
	return placed


## Pour material in where it would come to rest, rather than where it was
## released. Walks down from the given point to the first cell with something
## under it, then fills from there.
##
## This is the difference between a heap that appears and one that visibly
## rains down. Material released in the air has to be carried to the ground by
## the simulation, and that descent is both the bulk of the field's work — a
## falling cell wakes its neighbours on every step of the way — and the thing
## that reads as slow, stepped motion, because a sweep moves material by a
## fraction of a cell and sweeps are not frames. Placing it where it lands
## costs a short walk down a column and leaves the field only the settling,
## which is what it is actually good at. The flight belongs to the VFX.
func deposit_landing_at(
	world_point: Vector3,
	volume_m3: float,
	radius_cells: int = 2,
	max_drop_cells: int = 48
) -> float:
	# `deposit_at` already grounds each of its columns; this drops the whole
	# delivery to the surface first, so a throw aimed above a slope lands on
	# the slope rather than spreading at the height it was aimed at.
	return deposit_at(
		cell_to_world(_ground_cell_below(world_to_cell(world_point), max_drop_cells)),
		volume_m3,
		radius_cells
	)


## First cell at or below `from_cell` that has support underneath it — rock, or
## material already resting. Returns `from_cell` when it is already supported,
## and the lowest cell reached when nothing supports anything within reach.
func _ground_cell_below(from_cell: Vector3i, max_drop_cells: int) -> Vector3i:
	var cell := from_cell
	for _step in max_drop_cells:
		var below := cell - Vector3i(0, 1, 0)
		if below.y < 0:
			return cell
		if field.is_solid(below.x, below.y, below.z):
			return cell
		if field.mass_at(below.x, below.y, below.z) >= 1.0:
			return cell
		cell = below
	return cell


## What is standing in the column through a world point: how much material there
## is, and where its surface sits.
##
## This is what lets loose material carry a character without being a collider.
## A heap is a medium, not a step: you stand on top of it, you sink into it
## under your own weight, and how far you sink is bounded by how much of it
## there is. All three of those are this one query, and none of them is a
## surface — which is the whole point, because a surface is what was picking the
## player up off a ten-centimetre scattering.
##
## `depth_m` is the material compressed solid, so it answers "how far *can* I
## sink here" directly: twenty centimetres of dust cannot swallow more than
## twenty centimetres. Empty when the column holds nothing.
func dust_column_at(world_point: Vector3) -> Dictionary:
	var frame := world_transform()
	var local := frame.affine_inverse() * world_point
	# Blended across the four columns around the point rather than read off the
	# nearest one. Taking the nearest makes the surface a staircase with a
	# quarter-metre step every quarter metre walked, and a body carried on it is
	# jolted up at every one — which is what made a scattering of chippings feel
	# like it had colliders. Loose material has no such edges.
	var fx := local.x / field.cell_size - 0.5
	var fz := local.z / field.cell_size - 0.5
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var depth := 0.0
	var height := 0.0
	var carried := 0.0
	for dz in 2:
		for dx in 2:
			var weight := (
				(tx if dx == 1 else 1.0 - tx)
				* (tz if dz == 1 else 1.0 - tz)
			)
			if weight <= 0.0:
				continue
			var column := _column_at(x0 + dx, z0 + dz)
			if column.x <= 0.0:
				continue
			# Depth is left un-normalised, so it fades out at the edge of a heap
			# the way the material itself does. Height is normalised, or the
			# surface would dive toward the ground wherever a neighbouring
			# column happened to be empty.
			depth += column.x * weight
			height += column.y * weight
			carried += weight
	if carried <= 0.0:
		return {}
	return {
		"depth_m": depth,
		# Directly above or below the point asked about, not at the corner of a
		# cell — the caller is standing somewhere specific.
		"surface": frame * Vector3(local.x, height / carried, local.z),
	}


## One column, as `(depth in metres, surface height in the region's frame)`.
## Zero depth means the column holds nothing.
func _column_at(cell_x: int, cell_z: int) -> Vector2:
	if (
		cell_x < 0 or cell_x >= field.size.x
		or cell_z < 0 or cell_z >= field.size.z
	):
		return Vector2.ZERO
	var filled := 0.0
	var top_cell := -1
	var top_mass := 0.0
	for y in field.size.y:
		var mass := field.mass_at(cell_x, y, cell_z)
		if mass <= 0.0:
			continue
		filled += mass
		top_cell = y
		top_mass = mass
	if top_cell < 0:
		return Vector2.ZERO
	# The topmost cell is usually part full, and rounding it up to the cell
	# boundary is a quarter-metre lie the player would feel as a step at the
	# edge of every heap.
	return Vector2(
		filled * field.cell_size,
		(float(top_cell) + top_mass) * field.cell_size
	)


## Fill fraction at a world point, for anything that has to find material
## without a collider to hit — the aim, for one.
func mass_at_world(world_point: Vector3) -> float:
	var cell := world_to_cell(world_point)
	return field.mass_at(cell.x, cell.y, cell.z)


## Points a push spreads what it moved over. A ring rather than one spot: a bit
## working into a heap parts it, it does not build a second heap on one side.
const PUSH_RING_SAMPLES := 6


## Shove material aside instead of destroying it. Takes a share out of a sphere
## and puts every cubic centimetre of it back down in a ring just outside,
## grounded, so the field settles it into the shape a parted heap has.
##
## Volume is conserved exactly — this is the tool that makes spoil something you
## manage rather than something you delete. Returns how much was moved.
func push_at(world_point: Vector3, radius_m: float, share := 0.5) -> float:
	var centre := world_to_cell(world_point)
	var reach := int(ceil(radius_m / field.cell_size))
	var gathered := 0.0
	for dy in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				if dx * dx + dy * dy + dz * dz > reach * reach:
					continue
				gathered += field.take_fraction(
					centre.x + dx, centre.y + dy, centre.z + dz, share
				)
	if gathered <= 0.0:
		return 0.0
	# Around the contact in the tangent plane, so material goes sideways rather
	# than up: the bit parts a heap, it does not launch it.
	var side := anchor.basis.x
	var other := anchor.basis.z
	var ring := radius_m + field.cell_size * 2.0
	var each := gathered / float(PUSH_RING_SAMPLES)
	for k in PUSH_RING_SAMPLES:
		var angle := TAU * float(k) / float(PUSH_RING_SAMPLES)
		deposit_landing_at(
			world_point + (side * cos(angle) + other * sin(angle)) * ring,
			each,
			1
		)
	return gathered


## Clear loose material in a sphere — a bucket, a drill, a pickup. Returns the
## volume taken.
##
## `budget_m3` caps the haul, for a tool with a capacity rather than a tool that
## simply clears. The cell that would exceed it is taken in part, so the number
## returned is exactly the budget rather than the nearest whole cell above it —
## a scoop that reports more than it can hold has already lost the volume it
## claims to be carrying. Left unbounded, this behaves exactly as before.
func dig_at(
	world_point: Vector3,
	radius_m: float,
	budget_m3: float = INF
) -> float:
	if budget_m3 <= 0.0:
		return 0.0
	var centre := world_to_cell(world_point)
	var reach := int(ceil(radius_m / field.cell_size))
	var cell_volume := field.cell_volume_m3()
	var taken := 0.0
	for dy in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				if dx * dx + dy * dy + dz * dz > reach * reach:
					continue
				var cx := centre.x + dx
				var cy := centre.y + dy
				var cz := centre.z + dz
				if is_inf(budget_m3):
					taken += field.take(cx, cy, cz)
					continue
				var here := field.mass_at(cx, cy, cz) * cell_volume
				if here <= 0.0:
					continue
				var room := budget_m3 - taken
				if here <= room:
					taken += field.take(cx, cy, cz)
					if budget_m3 - taken <= 0.000001:
						return taken
					continue
				# Partial bite: `take_fraction` may still empty the cell when
				# what would be left is a sliver, which is its own rule and is
				# reported honestly in what it returns.
				taken += field.take_fraction(cx, cy, cz, room / here)
				return taken
	return taken


## Tell the region that the world's rock changed inside a sphere, so anything
## resting on it re-checks its support. This is what a carve calls.
func invalidate_rock(world_point: Vector3, radius_m: float) -> void:
	var centre := world_to_cell(world_point)
	var reach := int(ceil(radius_m / field.cell_size)) + 1
	field.invalidate_solid(
		centre - Vector3i.ONE * reach, centre + Vector3i.ONE * reach
	)


## Rock under a field cell, read from the world's voxel terrain.
##
## Sampled with trilinear interpolation rather than by reading the voxel the
## cell happens to sit in. The terrain is metre-scale and the field is 0.25 m,
## so a nearest-voxel answer quantises the ground to a whole metre — and since
## the mesher places its surface *between* lattice points, material then rests
## on a floor that can be most of a metre away from the rock anyone can see.
## That is the "everything sits slightly above the ground" artefact.
##
## Eight samples per cell is fine: the field caches every answer and only ever
## asks about cells material is actually touching.
func _cell_is_rock(
	cell: Vector3i,
	terrain: Node3D,
	voxel_tool: VoxelTool
) -> bool:
	# Solid is `occupancy >= 0.5`, and occupancy is `0.5 - sdf`, so this is
	# exactly `sdf <= 0` — the mesher's own inside/outside test.
	#
	# Asked at the cell's centre, not at the corner it is indexed from. A corner
	# test calls a cell rock only once its *lowest* face is buried, so material
	# comes to rest a whole cell above the ground it can see, every time, in the
	# same direction — which is what made everything look like it was hovering
	# slightly. At the centre the error is half a cell and falls both ways.
	return _sampled_sdf(cell_centre_world(cell), terrain, voxel_tool) <= 0.0


## Middle of a cell in world space. `cell_to_world` gives the corner the cell is
## indexed from, which is the right thing for placing geometry and the wrong
## thing for asking what a cell *is*.
func cell_centre_world(cell: Vector3i) -> Vector3:
	return world_transform() * (
		(Vector3(cell) + Vector3.ONE * 0.5) * field.cell_size
	)


func _sampled_sdf(
	world_point: Vector3,
	terrain: Node3D,
	voxel_tool: VoxelTool
) -> float:
	var local := VoxelSpaceUtil.world_to_local(terrain, world_point)
	var base := Vector3i(floori(local.x), floori(local.y), floori(local.z))
	var t := local - Vector3(base)
	var c000 := voxel_tool.get_voxel_f(base)
	var c100 := voxel_tool.get_voxel_f(base + Vector3i(1, 0, 0))
	var c010 := voxel_tool.get_voxel_f(base + Vector3i(0, 1, 0))
	var c110 := voxel_tool.get_voxel_f(base + Vector3i(1, 1, 0))
	var c001 := voxel_tool.get_voxel_f(base + Vector3i(0, 0, 1))
	var c101 := voxel_tool.get_voxel_f(base + Vector3i(1, 0, 1))
	var c011 := voxel_tool.get_voxel_f(base + Vector3i(0, 1, 1))
	var c111 := voxel_tool.get_voxel_f(base + Vector3i(1, 1, 1))
	return lerpf(
		lerpf(lerpf(c000, c100, t.x), lerpf(c010, c110, t.x), t.y),
		lerpf(lerpf(c001, c101, t.x), lerpf(c011, c111, t.x), t.y),
		t.z
	)
