class_name GranularVoxelRegionView
extends Node3D
## Draws and collides one `GranularVoxelRegion` by handing its material to a
## second, finer `VoxelTerrain`.
##
## The plugin does the meshing and the collision in C++, which is the whole
## reason loose material lives in a terrain rather than in a mesh built here:
## a marching-cubes pass over a 0.25 m field in GDScript would not survive a
## frame. All this node does is copy changed cells across and get out of the
## way.
##
## Presentation only. The region simulates with no view attached at all — that
## is how the radial behaviour is tested headless.

const _SURFACE_SHADER_PATH := "res://resources/granular_surface.gdshader"
## The crust's own photo, not a regolith stand-in. `u_tex_mean` in the shader is
## this texture's measured mean luminance, so swapping either without the other
## puts the whole heap at the wrong brightness.
const _ALBEDO_PATH := "res://resources/textures/ground103/albedo.png"
const _NORMAL_PATH := "res://resources/textures/ground103/normal.png"

## Edge of the cube written in one paste. Matches the plugin's data block size,
## so a paste lands on one block instead of straddling several and dirtying all
## of them.
const FLUSH_CHUNK := 16
## Spare blocks kept around the field's own extent, so the terrain has somewhere
## to put the surface of material sitting right against the border.
const BOUNDS_MARGIN_CELLS := 8
## Frames to let the terrain stream its blocks in before the first write. A
## paste into a block that has not loaded is dropped without a word, which
## looked exactly like the simulation producing nothing at all.
const STREAMING_WARMUP_FRAMES := 30
## Fill per second the chips move toward what the cell actually holds. The field
## itself steps in jumps — a sweep moves material by a fraction of a cell and
## sweeps are not frames — so following it exactly is following a staircase.
const GRAIN_SETTLE_RATE := 2.5

## How much a cell's fill must change before its chips are laid again. Nothing
## on the field moves the stones except this, so it is the whole of the answer
## to "why does the heap shimmer": below it, a cell settling by fractions is
## left exactly as it stands.
const GRAIN_RELAY_MASS_DELTA := 0.12

## The two ways of drawing the same field, switched independently.
##
## They cost in different currencies, and which one is affordable is decided by
## how much material is on screen, not by taste. A mesh costs by *volume*: one
## buffer and one draw call per chunk however much is in it, meshed in the
## plugin's C++. Grains cost by *surface area*: a heap of fifty cubic metres is
## about nineteen hundred shell cells and forty thousand instances, each one
## eighty triangles with a shadow, at any distance. Small spoil favours grains,
## large masses favour the mesh, and there is no setting of either that changes
## which way those two curves bend.
##
## The mesh was off for a while because it read as dough. That verdict was
## reached against a material whose texture period is 3.6 m — one cycle of the
## photograph across a whole heap, i.e. no detail at all at the scale the eye
## reads granularity. That is the same fault that made the first pass of chips
## come out as scattered coal, and it was a property of the material, not of
## marching cubes. The surface has not had a fair look since it was fixed.
const DRAW_SURFACE_MESH := true

## Whether loose material is also drawn as instanced chips.
##
## On top of the mesh rather than instead of it, if both are on: the surface
## carries the mass and the silhouette, the chips break the skin so it cannot
## read as one continuous substance. That hybrid is the expensive option and
## the best-looking one, and it is one boolean away in either direction.
##
## On, and now it has a second job that decided it. `RENDER_MIN_FILL` pulls the
## mesh back off the fringe, because a quarter-metre isosurface cannot draw a
## one-cell-thick scatter — it turns every sparse cell into an isolated plate,
## which is what the black flags standing around a drill site were. Pulling the
## mesh back does not draw the scatter, it only stops lying about it, so
## something has to. Chips are that something, and a thin scatter is the cheap
## end of their cost curve: they are dear on a large mass, which the mesh keeps,
## and cheap on exactly the sparse fringe the mesh has just given up.
const DRAW_GRAINS := true

## --- Surface reconstruction ------------------------------------------------
##
## A fill fraction is not a distance, and handing it to the mesher as one was
## what made a heap look like spilled clay. The isosurface of a near-binary
## occupancy field is a contour of a step function: ragged in plan, pitted
## where a cell inside the heap happened to sit below the level, and creased
## wherever the mesher read a slope off a quantity that has no slope. So
## occupancy is low-passed into something that behaves like a distance first,
## and the surface is drawn from that.

## Rounds of the three-tap kernel. One.
##
## Two was tried, to smooth the torn plan-view outline by two cells instead of
## one, and it made the tearing dramatically worse. It is worth knowing why,
## because it says something about the whole approach: widening the kernel
## spreads the fringe further out at values that sit near the threshold, and a
## sparse one-cell-thick fringe held near the threshold is precisely a factory
## for long thin slivers. The shards did not get fewer, they got longer. Cost
## 2.7x the flush for the privilege.
const SMOOTH_PASSES := 1
## Cells the kernel reaches, which is one per round. Also the padding every box
## needs, so this cannot be raised without the boxes growing with it.
const SMOOTH_RADIUS := SMOOTH_PASSES
## Fill a cell must hold before it is drawn at all, with the rest rescaled so
## nothing gains a second threshold. A cell sitting on rock is already carried
## a sixth of the way to the surface by the rock underneath it, so without a
## floor about a quarter fill is enough to turn a cell into a solid plate a
## quarter-metre across — and the fringe of a heap is one cell thick and noisy,
## so cells there flipped between nothing and a plate on a couple of percent of
## mass. That flicker is the torn edge, and the long black shards along it are
## its shadows, not its geometry.
##
## On, at 0.15, and the earlier verdict of "does not buy what it was for" is
## kept below because it is still half right.
##
## What it is still right about: a floor does not remove the boundary, it moves
## it. Wherever the mesh now ends there is a new outermost cell, and a quarter-
## metre isosurface ends in a quarter-metre facet whatever its value. Nothing
## here draws a scatter. That is why this is only half of the change and
## `DRAW_GRAINS` is the other half — the mesh is pulled back to where it is
## honest, and the chips own everything past it.
##
## What it was wrong about: that 0.06 established the knob was inert. It did
## not; it established that 0.06 is too timid to leave the zone. The floor is
## applied before the iso level and the remainder rescaled, and rock counts as
## full in the kernel, so a cell of loose material lying on rock is pulled up by
## the 1.0 underneath it. Through the three-tap kernel along the vertical, a
## quarter-full cell on rock reconstructs to 0.33 at no floor and 0.30 at 0.06,
## against an iso of 0.35 — still close enough to the line to flip on a couple
## of per cent of mass, which is exactly the plate flickering into existence.
## At 0.15 the same cell reconstructs to 0.245 and is gone for good, while a
## half-full cell still comes to 0.44 and draws. So the cut this makes is
## roughly "half a cell and up is mesh, a quarter and down is not".
##
## The old objection to raising it does not apply any more and should not be
## re-inherited: it said the mesher feeds collision, so a floor stops holding
## the player up. This terrain has `generate_collisions = false` — loose
## material carries a character through `dust_at` and the sinking in
## `character_motor`, which never asks the mesh anything. That measurement is
## older than the collider being turned off, and this is now a picture-only
## knob.
const RENDER_MIN_FILL := 0.15
## Weight of the centre cell against its two neighbours along each axis. Lower
## is smoother, but not much lower: a plain [1,2,1] tent blurs a one-cell layer
## down to exactly the iso level, so a heap one cell deep would render as a
## surface of zero thickness and effectively vanish.
const SMOOTH_CENTRE := 4.0
## Occupancy the surface is drawn at. Below a half on purpose. The outermost
## cells of a settled heap hold small fractions, and cutting at a half ends the
## heap in a quarter-metre cliff along a ragged contour — where loose material
## has a skirt that thins to nothing. This is the knob to turn if heaps read as
## too fat or too meagre; it trades apparent volume for how far the skirt runs.
const SURFACE_ISO := 0.35
## Restores roughly unit slope per cell to the low-passed field, which the
## mesher wants when it interpolates the crossing point along an edge. The blur
## spreads a full-to-empty step over about two cells, so undo that.
const SDF_GAIN := 2.0
## Units of the buffer's 16-bit SDF channel per unit of distance.
##
## Measured against the plugin, not assumed: writing 0.25 stores 16, 0.5 stores
## 32 and 1.0 stores 65, and `int(value * 65.535)` is the only scale that
## produces all three. A full box encoded this way and read back through
## `get_voxel_f` returns the same distances to within 0.007, which is the
## channel's own quantum — the per-voxel path had exactly the same error.
##
## Hand-encoding the channel is what allows the whole box to cross in one call,
## and it is also the shape the native port wants: the C++ side fills the same
## bytes, and nothing above it changes.
const SDF_S16_SCALE := 65.535

## Rebuild every box the old GDScript way as well and compare byte for byte.
##
## Off. This is the switch that proved the native reconstruction correct, kept
## because the proof has to be repeatable — the same arrangement as the field
## and its script twin, where the slow implementation stays as the thing the
## fast one is checked against. Turning it on costs the whole GDScript flush
## again, which is precisely what was removed, so it is a deliberate check and
## not a safety net.
const VERIFY_NATIVE_SDF := false

## Chunks written to the terrain in one flush.
##
## Every write makes the plugin remesh that chunk, and that is work this side
## cannot see or measure — headless does no meshing at all, which is why a
## per-bite breakdown came to 0.83 ms while the game still hitched. What the
## breakdown could not show is the count: a heap arriving all at once dirties a
## dozen chunks in one frame, and a settling one keeps a handful hot at sixty
## flushes a second.
##
## Capping the count turns that spike into a flat line. Nothing is dropped —
## chunks that miss their turn keep accumulating and go over next frame — so
## the cost is that a chunk can be a frame or two behind the field. At sixty
## frames a second that is invisible, and it is a far better trade than the
## alternative of flushing less often, which would coarsen *everything*
## including the settling the finer sweeps were bought for.
##
## Eight, not two. Two was tried against a hitch and did not touch it — and it
## turned out to be quantising the picture instead: a heap covering ten chunks
## had each of them rewritten once every five flushes, so every part of the
## surface updated at about twelve hertz however fast the field was stepping.
## That is exactly what "the settling still looks like ten hertz" was. The cap
## stays only as a guard against a pathological burst.
const MESH_CHUNKS_PER_FLUSH := 8

## Fully outside. Reads as air whatever the gain.
##
## Tempting to set this to what an empty cell reconstructs to
## (`SURFACE_ISO * SDF_GAIN`) and then skip writing those cells, since the fill
## would already hold the answer. Measured, it moved the surface half a cell:
## the value is also what the *rock* cells this pass refuses to draw are left
## holding, and how firmly they read as air decides where the crossing with the
## material resting on them lands. Two different meanings, one constant — not
## worth the three milliseconds.
const AIR_SDF := 1.0

var region: GranularVoxelRegion

var _terrain: VoxelTerrain
var _tool: VoxelTool
## Blocks are streamed in over a few frames; a paste into a block that does not
## exist yet writes nothing at all, silently. Everything is held back until the
## terrain reports itself ready, then flushed in one go.
var _streaming_ready := false
var _frames_waited := 0
var _last_flush_ms := 0.0
var _last_flush_cells := 0
var _last_flush_chunks := 0
var _last_pending_chunks := 0
## Chunks that have changed and not yet been written, against the box of them
## that needs rewriting. Held rather than flushed the moment they are dirtied,
## so a burst is spread over frames instead of landing in one.
var _pending_chunks: Dictionary = {}

## Scratch for the reconstruction, all indexed over the same work box, grown to
## the largest box seen and reused. The field is read into `_mass_box` and
## `_solid_box` in bulk — a script call per cell was most of the cost of drawing
## this at all — and the separable kernel ping-pongs `_occupancy` against
## `_scratch` over three passes, so the result lands in `_scratch`.
## The grains, and which cells currently have chips laid on them, against the
## fill they were laid for.
##
## Maintained cell by cell from the dirty list rather than rebuilt. Rebuilding
## the whole shell on a timer meant every stone in a heap was re-laid ten times
## a second whether or not anything near it had moved, and updates arriving in
## discrete jumps is exactly what a strobe is. Material that has come to rest is
## now never touched again, so there is nothing left for it to flicker with.
var _grains: GranularGrainShell
var _shell: Dictionary = {}
## Cells whose chips are still catching up with the field, against the fill they
## are heading for. Material arriving or draining moves the stones a step per
## frame instead of snapping them to a new layout the moment the cell crosses a
## threshold — which is what made the crushed rock look twitchy.
var _animating: Dictionary = {}
## Shell cells currently drawn as backing — the plug layer behind the chips —
## rather than as chips. Membership is decided by `_refresh_shell_cell` from
## the field, and a cell flipping between the two kinds is re-laid even when
## its mass has not moved: same mass, entirely different picture.
var _backing: Dictionary = {}

## The SDF channel of the paste buffer, encoded by hand and handed over whole.
## Kept between flushes so a settling heap is not reallocating it every frame.
var _sdf_bytes: PackedByteArray = PackedByteArray()

var _mass_box: PackedFloat32Array = PackedFloat32Array()
var _solid_box: PackedByteArray = PackedByteArray()
var _occupancy: PackedFloat32Array = PackedFloat32Array()
var _scratch: PackedFloat32Array = PackedFloat32Array()
## Which of the two the finished surface came to rest in, which depends on how
## many passes ran.
var _smoothed_in_scratch := false

static var _surface_material: Material


## `surface_material` is the world terrain's own material, so spoil is shaded by
## exactly what the ground is shaded by. Left null — the demo stands, which own
## their rock as plain boxes and have no planet shader to borrow — this falls
## back to a self-contained material.
func setup(
	new_region: GranularVoxelRegion,
	surface_material: Material = null
) -> void:
	region = new_region
	# The region's frame is the terrain's frame, so a field cell and a voxel of
	# this terrain are the same thing and no coordinate maths is needed here.
	transform = region.world_transform()
	_build_terrain(surface_material)


func _build_terrain(surface_material: Material) -> void:
	var material := (
		surface_material if surface_material != null else _fallback_material()
	)
	if DRAW_GRAINS:
		_grains = GranularGrainShell.new()
		add_child(_grains)
		# The chips are seated through the surface's own fill floor, so the two
		# renderers put material at the same height instead of the stones
		# standing proud of the mesh they are meant to be lying on.
		_grains.setup(region.up(), RENDER_MIN_FILL if DRAW_SURFACE_MESH else 0.0)
	if not DRAW_SURFACE_MESH:
		return
	var field := region.field
	_terrain = VoxelTerrain.new()
	_terrain.scale = Vector3.ONE * field.cell_size
	_terrain.mesher = VoxelMesherTransvoxel.new()
	# Everything starts as air: this terrain holds only what the field puts in
	# it, never any of the world's own rock.
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = -100000.0
	_terrain.generator = generator
	# No collider. Loose material is a medium, not a surface: what carries a
	# character is `GranularVoxelWorld.dust_at` and the sinking in
	# `character_motor`, which can express "holds you up, and gives way under
	# you" — a collision shape can only ever express the first half. Doing only
	# the first half to a ten-centimetre scattering is what threw the player
	# into the air every time they drilled under their own feet, and what put a
	# solid wall between the drill and the rock it was aimed at.
	#
	# The mesh stays for now, as something to look at. It is a placeholder: this
	# surface is what reads as a stone growth rather than as cuttings, and
	# `GRANULAR-V1.md` replaces it with instanced grains.
	_terrain.generate_collisions = false
	_terrain.set_bounds(
		AABB(
			Vector3.ONE * -BOUNDS_MARGIN_CELLS,
			Vector3(field.size) + Vector3.ONE * BOUNDS_MARGIN_CELLS * 2.0
		)
	)
	_terrain.material_override = _localise(material)
	add_child(_terrain)
	var viewer := VoxelViewer.new()
	viewer.view_distance = maxi(field.size.x, field.size.z) + BOUNDS_MARGIN_CELLS * 2
	_terrain.add_child(viewer)
	_tool = _terrain.get_voxel_tool()
	_tool.channel = VoxelBuffer.CHANNEL_SDF


## Push everything the field has changed into the terrain. Cheap when nothing
## moved, which is most of the time: a settled heap reports no dirty cells at
## all, however many cells it occupies.
func flush() -> void:
	# Only the mesh has to wait for the terrain to stream its blocks in. Grains
	# are drawn by this node and can start on the first cell.
	if DRAW_SURFACE_MESH and not _streaming_ready:
		if _tool == null:
			return
		_frames_waited += 1
		if _frames_waited < STREAMING_WARMUP_FRAMES:
			return
		_streaming_ready = true
	var dirty := region.field.take_dirty()
	if dirty.is_empty() and _pending_chunks.is_empty():
		_last_flush_cells = 0
		_last_flush_chunks = 0
		return
	var started := Time.get_ticks_usec()
	var size := region.field.size
	var plane := size.x * size.z
	# Group by chunk, but remember how much of each chunk actually moved. A
	# whole 16-cube buffer is four thousand cells to read and hand over, and a
	# settling heap usually touches a handful of them — paying the full cube
	# per chunk was most of the cost of drawing this at all.
	var bounds := {}
	# A cell that moved changes whether its neighbours are still buried, and the
	# shell reaches two cells in — chips, then the plug layer behind them — so
	# the cells have to be reconsidered that far out as well. Only worth
	# collecting when something draws them.
	var touched := {}
	for i: int in dirty:
		var cell := Vector3i(i % size.x, i / plane, (i / size.x) % size.z)
		if DRAW_GRAINS:
			touched[i] = true
			# One cell out, or two when there is a plug layer back there to
			# reconsider. With the plugs off the second ring is six more cell
			# tests per dirty cell for an answer nothing reads.
			for step in ([1, 2] if PLUGS_BEHIND_CHIPS else [1]):
				if cell.x >= step:
					touched[i - step] = true
				if cell.x < size.x - step:
					touched[i + step] = true
				if cell.z >= step:
					touched[i - size.x * step] = true
				if cell.z < size.z - step:
					touched[i + size.x * step] = true
				if cell.y >= step:
					touched[i - plane * step] = true
				if cell.y < size.y - step:
					touched[i + plane * step] = true
		if not DRAW_SURFACE_MESH:
			continue
		var chunk := Vector3i(
			cell.x / FLUSH_CHUNK, cell.y / FLUSH_CHUNK, cell.z / FLUSH_CHUNK
		)
		if bounds.has(chunk):
			var box: AABB = bounds[chunk]
			bounds[chunk] = box.expand(Vector3(cell))
		else:
			bounds[chunk] = AABB(Vector3(cell), Vector3.ZERO)
	# Merge this frame's chunks into whatever is still owed. A chunk waiting its
	# turn keeps growing rather than being replaced, so nothing that moved is
	# ever dropped — it is only ever drawn a frame or two later.
	for chunk: Vector3i in bounds:
		if _pending_chunks.has(chunk):
			var held: AABB = _pending_chunks[chunk]
			_pending_chunks[chunk] = held.merge(bounds[chunk])
		else:
			_pending_chunks[chunk] = bounds[chunk]
	# Only so many chunks go over per frame. Each paste makes the plugin remesh
	# that chunk, and a heap appearing all at once dirties a dozen of them in the
	# same frame — which is the hitch reported as the spoil "spawning". Spreading
	# them costs a chunk being a frame or two stale, which no eye can catch at
	# sixty a second, and turns a spike into a flat line.
	var done := 0
	var drawn: Array[Vector3i] = []
	for chunk: Vector3i in _pending_chunks:
		if done >= MESH_CHUNKS_PER_FLUSH:
			break
		_flush_box(_pending_chunks[chunk])
		drawn.append(chunk)
		done += 1
	for chunk in drawn:
		_pending_chunks.erase(chunk)
	_last_flush_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_last_flush_cells = dirty.size()
	_last_flush_chunks = done
	_last_pending_chunks = _pending_chunks.size()
	for index: int in touched:
		_refresh_shell_cell(index)


## Walk the chips toward what the field holds, a step a frame.
##
## Only cells still catching up cost anything, and a heap that has come to rest
## has none — so this is a per-frame pass over a handful of cells, not over the
## heap.
func _process(delta: float) -> void:
	if _animating.is_empty() or _grains == null:
		return
	var step := GRAIN_SETTLE_RATE * delta
	var settled: Array[int] = []
	for index: int in _animating:
		var target: float = _animating[index]
		var shown: float = move_toward(float(_shell.get(index, 0.0)), target, step)
		_shell[index] = shown
		_grains.lay(region, index, shown, _backing.has(index))
		if is_equal_approx(shown, target):
			settled.append(index)
	for index in settled:
		_animating.erase(index)


## Decide what one cell's chips should be now, and touch the grains only if the
## answer changed.
##
## The fill threshold matters as much as the membership test: a cell whose
## material shifted by a hair would otherwise have its stones re-laid, and
## stones that jump a millimetre every frame are the flicker seen from a
## distance. Material genuinely on the move crosses it and is re-laid; material
## settling by fractions is left alone.
func _refresh_shell_cell(index: int) -> void:
	if _grains == null:
		return
	var field := region.field
	var size := field.size
	var plane := size.x * size.z
	var x := index % size.x
	var y := index / plane
	var z := (index / size.x) % size.z
	var mass := field.mass_at(x, y, z)
	# A cell that already has stones on it judges "am I still exposed" by a
	# slacker rule than one deciding to grow them. Without that gap the test is
	# a knife edge: a *neighbour* drifting either side of `OPEN_MIN_MASS` flips
	# this cell between exposed and buried, and each flip is a full relay — the
	# stones vanish and a plug appears in a different place, or the other way
	# round, several times a second. That is the handful of pieces that twitch
	# while the heap around them lies still. The relay delta above cannot catch
	# it because this cell's own mass never moved at all.
	var held := _shell.has(index)
	var facing := _faces_open(x, y, z, held)
	if mass < GranularGrainShell.MIN_CELL_MASS or (
		not facing and not (PLUGS_BEHIND_CHIPS and _backs_open(x, y, z))
	):
		_animating.erase(index)
		_backing.erase(index)
		if _shell.erase(index):
			_grains.clear_cell(index)
		return
	# Chips if anything open touches this cell, the plug behind them if open is
	# only two away. The kind changing is a full relay even at identical mass —
	# a cell buried under fresh spoil trades its twenty chips for one plug.
	var was_backing := _backing.has(index)
	var is_backing := not facing
	if is_backing:
		_backing[index] = true
	else:
		_backing.erase(index)
	var laid: float = _shell.get(index, -1.0)
	if laid < 0.0:
		# New cell: chips grow in from nothing rather than appearing whole.
		_shell[index] = 0.0
	elif was_backing == is_backing and absf(mass - laid) < GRAIN_RELAY_MASS_DELTA:
		return
	_animating[index] = mass


## Whether this cell touches anything open — the chip layer.
##
## The shell is still two cells deep, but the layers are no longer the same
## thing drawn twice. The outer one is chips. The one behind it is a single
## plug per cell, standing where the gaps in the chips land: stones behind the
## stones, at a twenty-first of the instances the second layer of chips spent
## on that job — and unlike a second layer of chips it cannot itself have gaps.
##
## Cells deeper than that stay undrawn, which is what keeps this in the
## thousands of instances rather than the millions.
## `held` says this cell already has stones laid, which slackens the test — see
## `_refresh_shell_cell` for why the two answers must differ.
func _faces_open(x: int, y: int, z: int, held := false) -> bool:
	var limit := OPEN_MIN_MASS_HELD if held else OPEN_MIN_MASS
	return (
		_is_open(x + 1, y, z, limit)
		or _is_open(x - 1, y, z, limit)
		or _is_open(x, y + 1, z, limit)
		or _is_open(x, y - 1, z, limit)
		or _is_open(x, y, z + 1, limit)
		or _is_open(x, y, z - 1, limit)
	)


## Whether anything open sits two away — the plug layer, when nothing is open
## nearer. Never seen except through the gaps in the chips standing in front.
func _backs_open(x: int, y: int, z: int) -> bool:
	return (
		_is_open(x + 2, y, z, OPEN_MIN_MASS)
		or _is_open(x - 2, y, z, OPEN_MIN_MASS)
		or _is_open(x, y + 2, z, OPEN_MIN_MASS)
		or _is_open(x, y - 2, z, OPEN_MIN_MASS)
		or _is_open(x, y, z + 2, OPEN_MIN_MASS)
		or _is_open(x, y, z - 2, OPEN_MIN_MASS)
	)


## Mass below which a cell counts as open for the exposure test. Deliberately
## not `GranularGrainShell.MIN_CELL_MASS`, which is lower: the shell draws the
## fines skirt from almost nothing, but almost nothing must still count as
## open, or every skirt cell would bury the cell beside it and pull plugs up
## to the surface of a thin scatter.
const OPEN_MIN_MASS := 0.05
## The same test for a cell that is already drawn. Higher, so more counts as
## open and a cell keeps its stones through a neighbour wobbling around the
## line above. The gap is the hysteresis band and nothing else decides how wide
## it is — too narrow and the twitching comes back, too wide and stones linger
## a moment on cells that genuinely got buried.
const OPEN_MIN_MASS_HELD := 0.09


## Whether the plug layer behind the chips is drawn at all.
##
## Off whenever the surface mesh is on, which is now the normal case. The plug
## exists because chips cannot be opaque — a gap between convex stones is
## geometrically guaranteed — and behind a gap there used to be nothing, which
## is why a pile once read as hollow. There is something behind them now: the
## mesh, which is opaque and already drawn. Every plug was therefore geometry
## sealed inside a solid surface, invisible by construction.
##
## The saving is not the one instance it draws, it is the twenty-one slots its
## cell reserves to draw it — and slots are what this renderer is billed in.
const PLUGS_BEHIND_CHIPS := not DRAW_SURFACE_MESH


## Open means neither material nor rock — past the edge of the region counts,
## so a heap against the border still gets a face.
func _is_open(x: int, y: int, z: int, limit: float) -> bool:
	return (
		region.field.mass_at(x, y, z) < limit
		and not region.field.is_solid(x, y, z)
	)


## Write back the part of the field that moved, rebuilt as a surface rather
## than copied across as occupancy.
##
## The written box is padded past the cells that actually changed — by the
## mesher's one-cell overlap plus the kernel's reach, because a cell that moved
## changes the reconstructed surface everywhere the kernel can see it. That pad
## used to be clamped back inside the chunk, which left the border cells of the
## neighbouring chunk holding a surface built from material that had since gone:
## straight-edged seams across a heap, running along block boundaries. Crossing
## into the next block costs a remesh there, and that remesh is the point.
func _flush_box(dirty_box: AABB) -> void:
	var size := region.field.size
	var pad := 1 + SMOOTH_RADIUS
	var lo := (Vector3i(dirty_box.position) - Vector3i.ONE * pad).clamp(
		Vector3i.ZERO, size - Vector3i.ONE
	)
	var hi := (Vector3i(dirty_box.end) + Vector3i.ONE * pad).clamp(
		Vector3i.ZERO, size - Vector3i.ONE
	)
	var extent := hi - lo + Vector3i.ONE
	# The whole reconstruction in one native call: occupancy, the separable
	# blur, and the encode into the buffer's 16-bit channel. This is what the
	# frame was going into — measured on a one-and-a-half cubic metre collapse,
	# the field's sweeps cost 0.106 ms a frame and this cost 3.450, worst frame
	# 15.69. Ninety-seven per cent of the granular frame, all of it per-voxel
	# GDScript, none of it reachable by a better choice of API.
	var bytes: PackedByteArray = region.field.build_sdf_box(
		lo,
		extent,
		SMOOTH_PASSES,
		SMOOTH_CENTRE,
		RENDER_MIN_FILL,
		SURFACE_ISO,
		SDF_GAIN,
		AIR_SDF,
		SDF_S16_SCALE
	)
	if VERIFY_NATIVE_SDF:
		_verify_against_script_path(lo, extent, bytes)
	var buffer := VoxelBuffer.new()
	buffer.create(extent.x, extent.y, extent.z)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, bytes)
	_tool.paste(lo, buffer, 1 << VoxelBuffer.CHANNEL_SDF)


## Rebuild the same box the old way and complain if a single byte differs.
##
## Off in play, and the reason the script path below is still here rather than
## deleted: it is the specification the native reconstruction was written
## against, the same arrangement as `GranularVoxelField` and its script twin.
## Turning this on costs the whole GDScript flush again, so it is a check to
## run deliberately, not a safety net to leave on.
func _verify_against_script_path(
	lo: Vector3i,
	extent: Vector3i,
	native_bytes: PackedByteArray
) -> void:
	var work_extent := extent + Vector3i.ONE * (SMOOTH_RADIUS * 2)
	_reconstruct(lo - Vector3i.ONE * SMOOTH_RADIUS, work_extent)
	_encode_reconstructed(lo, extent, work_extent)
	if _sdf_bytes == native_bytes:
		return
	var differing := 0
	for i in mini(_sdf_bytes.size(), native_bytes.size()):
		if _sdf_bytes[i] != native_bytes[i]:
			differing += 1
	push_error(
		"native SDF differs from the script path at %s extent %s: %d of %d bytes"
		% [str(lo), str(extent), differing, _sdf_bytes.size()]
	)


## Low-pass the occupancy over a box into something with a gradient worth
## reading. Result is indexed over `work_extent` and lands in whichever array
## `_smoothed_in_scratch` names.
##
## Rock is asked for here and memoised by the field, so a region pays for the
## ground under a heap once, over the cells material has actually reached.
func _reconstruct(work_lo: Vector3i, work_extent: Vector3i) -> void:
	var field := region.field
	var total := work_extent.x * work_extent.y * work_extent.z
	if _occupancy.size() < total:
		_occupancy.resize(total)
		_scratch.resize(total)
	_mass_box = field.copy_mass_box(work_lo, work_extent)
	_solid_box = field.copy_solid_box(work_lo, work_extent)
	# Rock counts as full. Without it the low-pass thins the heap out exactly
	# where it meets the ground, and material ends in a feathered lip hanging
	# over the rock instead of sitting in it — the dark line drawn around every
	# pile.
	var floor_scale := 1.0 / (1.0 - RENDER_MIN_FILL)
	for i in total:
		if _solid_box[i] != 0:
			_occupancy[i] = 1.0
		else:
			_occupancy[i] = maxf(_mass_box[i] - RENDER_MIN_FILL, 0.0) * floor_scale
	# Separable: passes of three taps each, never one pass of twenty-seven.
	var strides := [1, work_extent.x, work_extent.x * work_extent.z]
	var axis_sizes := [work_extent.x, work_extent.z, work_extent.y]
	# Each pass writes into the other array, so after an odd number of them the
	# answer is in `_scratch` and after an even number it is back in
	# `_occupancy`. Tracked rather than assumed — the pass count is a knob.
	_smoothed_in_scratch = false
	for _round in SMOOTH_PASSES:
		for axis in 3:
			if _smoothed_in_scratch:
				_blur_axis(
					_scratch, _occupancy, total, strides[axis], axis_sizes[axis]
				)
			else:
				_blur_axis(
					_occupancy, _scratch, total, strides[axis], axis_sizes[axis]
				)
			_smoothed_in_scratch = not _smoothed_in_scratch


## One pass of the separable kernel along whichever axis `stride` steps. Ends
## are clamped rather than wrapped, which is why the work box carries a ring the
## written box does not use.
##
## Walked line by line rather than by computing each cell's coordinate back out
## of its index, which cost a divide and a modulo per cell — and this runs three
## times over every cell of every box that moves.
func _blur_axis(
	source: PackedFloat32Array,
	target: PackedFloat32Array,
	total: int,
	stride: int,
	axis_size: int
) -> void:
	var scale := 1.0 / (SMOOTH_CENTRE + 2.0)
	var span := stride * axis_size
	var tail := (axis_size - 1) * stride
	for base in range(0, total, span):
		for offset in stride:
			var start := base + offset
			var last := start + tail
			var i := start
			while i <= last:
				var sum := source[i] * SMOOTH_CENTRE
				sum += source[i - stride] if i > start else source[i]
				sum += source[i + stride] if i < last else source[i]
				target[i] = sum * scale
				i += stride


## Turn the reconstructed field into the bytes of a 16-bit SDF channel.
##
## Kept as the reference the native path is checked against, not as the path
## anything runs. See `_verify_against_script_path`.
func _encode_reconstructed(
	lo: Vector3i,
	extent: Vector3i,
	work_extent: Vector3i
) -> void:
	var smoothed := _scratch if _smoothed_in_scratch else _occupancy
	var stride_z := work_extent.x
	var stride_y := work_extent.x * work_extent.z
	# The whole channel is built here and handed over in one call, where it used
	# to go voxel by voxel through `set_voxel_f`.
	#
	# This buys nothing today, and the measurement saying so is the reason to
	# keep it. Over eight thousand voxels: the bare loop costs 0.17 ms, the loop
	# with its array reads and arithmetic 0.38, `encode_s16` per voxel takes it
	# to 0.66 and `set_voxel_f` per voxel to 0.99 — while handing the finished
	# channel over whole costs 0.0005. Swapping the write is therefore a wash,
	# because in GDScript the loop *is* the cost and no choice of API touches it.
	#
	# What it changes is the ceiling for the native port. With the loop in C++
	# at hundredths of a millisecond, eight thousand binding calls would be a
	# floor of six tenths — the port would be capped by the very last thing it
	# could not move. One handover has no such floor, and the bytes it wants are
	# the bytes built here.
	var total := extent.x * extent.y * extent.z
	if _sdf_bytes.size() != total * 2:
		_sdf_bytes.resize(total * 2)
	# Every voxel is written, air included, so cells the field has emptied are
	# cleared rather than left holding whatever was written last time. That is
	# what the `fill_f` before the walk used to do.
	var air := int(AIR_SDF * SDF_S16_SCALE)
	for y in extent.y:
		for z in extent.z:
			# The written box sits inside the work box by the kernel's radius,
			# so walking one row of it is walking one row of the scratch.
			var wi := (
				(y + SMOOTH_RADIUS) * stride_y
				+ (z + SMOOTH_RADIUS) * stride_z
				+ SMOOTH_RADIUS
			)
			# The buffer's own layout, which is not the field's: y runs fastest,
			# then x, then z. Measured against the plugin rather than assumed.
			var vi := (y + extent.y * extent.x * z) * 2
			for x in extent.x:
				# Rock belongs to the world's own terrain, which already draws
				# it; claiming it here too would be a second surface in the same
				# place. The exception is rock directly under material, which
				# this one does claim, so a heap's underside is buried in the
				# ground rather than stopping exactly at it — an edge that lands
				# on the rock is an edge with a shadow under it.
				#
				# Under, and only under. Claiming rock beside material as well
				# put a solid cell where the cell above it is air, so its top
				# face got drawn — at the cell boundary, which is up to half a
				# cell above the ground the metre-scale terrain actually shows.
				# That was a lip one cell wide ringing every heap, quantised to
				# the grid: the sawtooth along the rim.
				var encoded := air
				if _solid_box[wi] == 0 or _mass_box[wi + stride_y] > 0.0:
					var distance := clampf(
						(SURFACE_ISO - smoothed[wi]) * SDF_GAIN, -1.0, 1.0
					)
					encoded = int(distance * SDF_S16_SCALE)
				_sdf_bytes.encode_s16(vi, encoded)
				wi += 1
				vi += extent.y * 2


func flush_report() -> String:
	return "%d cells / %d chunks (+%d waiting) %.2f ms   %s" % [
		_last_flush_cells,
		_last_flush_chunks,
		_last_pending_chunks,
		_last_flush_ms,
		_grains.report() if _grains != null else "no grains"
	]


## Give the material this region's own frame.
##
## The surface shader builds its stones in region-local metres, not world ones:
## shader varyings are float32 whatever the engine does with doubles on the CPU,
## and a world position out on a 9.5 km radius arrives quantised to about a
## millimetre — with nothing left over for the fractional part of a coordinate
## divided by seven centimetres. A region box is a couple of dozen metres
## across, so in its own frame the field is exact. This is the only thing that
## has to be told
## per region, and it is why the material is duplicated rather than shared.
##
## Anything that is not a ShaderMaterial passes through untouched.
func _localise(material: Material) -> Material:
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return material
	var own := shader_material.duplicate() as ShaderMaterial
	own.set_shader_parameter(
		"u_local_from_world", region.world_transform().affine_inverse()
	)
	own.set_shader_parameter("u_up", region.up())
	return own


## Stand-in for scenes with no planet shader to borrow — the demo stands, which
## own their rock as plain boxes. In the world this is not used: spoil is
## regolith, the ground is regolith, and shading them with two different
## materials is what made a heap read as a different substance dropped on the
## Moon rather than as part of it.
##
## The same surface shader the world uses, so what a bench scene shows is what
## the game shows. That matters more than it sounds: every real fault in this
## material was found by looking at it, and a demo stand that draws spoil some
## other way is a demo stand that cannot find one.
##
## Triplanar is not a preference here: the mesher emits no UVs at all, so a
## plain textured material comes out as flat colour.
static func _fallback_material() -> Material:
	if _surface_material != null:
		return _surface_material
	var material := ShaderMaterial.new()
	material.shader = load(_SURFACE_SHADER_PATH) as Shader
	material.set_shader_parameter("u_albedo", load(_ALBEDO_PATH) as Texture2D)
	material.set_shader_parameter("u_normal", load(_NORMAL_PATH) as Texture2D)
	_surface_material = material
	return _surface_material
