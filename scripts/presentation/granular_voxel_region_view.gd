class_name GranularVoxelRegionView
extends Node3D
## Draws one `GranularVoxelRegion`: a `MeshInstance3D` per chunk, meshed by the
## field's own native marching cubes (`GranularVoxelField.build_mesh_box`).
##
## This used to hand the material to a second, finer `VoxelTerrain` and let the
## plugin mesh it. That was the last granular cost standing after everything of
## ours went native: every paste makes the plugin rebuild the chunk's Transvoxel
## mesh on its own schedule, and a body moulding the field changes it every
## flush — a wall of remeshes measured at ~7-11 ms a frame while moulding, with
## our whole pipeline at ~2.6. The native mesher reads the same reconstructed
## field the paste path encoded, marches the same iso level, and hands the
## arrays straight to a mesh here — no encode, no paste, no plugin, no thread
## handoff, and the surface can no longer lag the stones by someone else's
## schedule.
##
## Presentation only. The region simulates with no view attached at all — that
## is how the radial behaviour is tested headless.

const _SURFACE_SHADER_PATH := "res://resources/granular_surface.gdshader"
## The crust's own photo, not a regolith stand-in. `u_tex_mean` in the shader is
## this texture's measured mean luminance, so swapping either without the other
## puts the whole heap at the wrong brightness.
const _ALBEDO_PATH := "res://resources/textures/ground103/albedo.png"
const _NORMAL_PATH := "res://resources/textures/ground103/normal.png"

## Edge of the cube one mesh covers, in cells. The unit the dirty list is
## bucketed by: a cell that moves remeshes its chunk and nothing else.
const FLUSH_CHUNK := 16
## Fill per second the chips move toward what the cell actually holds. The field
## itself steps in jumps — a sweep moves material by a fraction of a cell and
## sweeps are not frames — so following it exactly is following a staircase.
const GRAIN_SETTLE_RATE := 2.5
## Fill a growing cell must gain before its chips are laid again. The animation
## still ticks every frame, but the expensive re-lay only happens on these
## steps, so a cell grows in over about `1 / LAY_STEP` relays instead of one per
## frame. This is the whole reason `lay` stopped being the dominant granular
## cost; too large and the grow-in visibly steps, too small and the saving goes.
const LAY_STEP := 0.12
## The chip animation ticks at most this often — the flush rate, since the field
## it follows changes no faster. At 200 fps this alone is a near-sevenfold cut
## on how often the pass runs. Kept as a local constant rather than reaching for
## `GranularVoxelWorld.MESH_FLUSH_HZ`, which the view does not depend on.
const LAY_INTERVAL_S := 1.0 / 30.0

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

## Chunks remeshed in one flush.
##
## A heap arriving all at once dirties a dozen chunks in one frame, and a
## settling one keeps a handful hot at thirty flushes a second. Capping the
## count turns that spike into a flat line. Nothing is dropped — chunks that
## miss their turn stay in `_pending_chunks` and go next flush — so the cost is
## that a chunk can be a frame or two behind the field, which no eye catches.
##
## Eight survives from the paste era for a different reason than it was set:
## back then each unit was a handover to the plugin plus a Transvoxel remesh on
## its thread; now it is one native `build_mesh_box` at tens of microseconds.
## The cap stays only as a guard against a pathological burst.
const MESH_CHUNKS_PER_FLUSH := 8

## Flushes between surface remeshes. The chips refresh every flush; the surface
## catches up every this-many. Left at 1 — the native mesher is cheap enough to
## keep the surface exactly on the chips' clock, which is the whole point of
## it. The mechanism stays for an emergency knob.
const SURFACE_FLUSH_EVERY := 1

## Shell cells reconsidered in one flush.
##
## The single most expensive thing in the granular renderer, and the only one
## that was not already rationed. Measured on a rover dropped into a heap:
## `flush 425.8 ms/s`, of which `chips` alone was 298.6 — against `sdf` at 7.1
## and `paste` at 2.4. Worst frame 31.6 ms, sixteen frames a second.
##
## It is expensive per cell rather than in bulk: `_refresh_shell_cell` asks the
## field for the cell's mass and then for six neighbours through `_is_open`,
## each of those two more binding calls. Fifteen-odd crossings into native code
## per cell, and a plunge dirties tens of thousands.
##
## At 512 a flush and thirty flushes a second, about fifteen thousand cells a
## second get reconsidered — which holds the cost near forty milliseconds a
## second instead of three hundred, and lets a violent collapse catch up over a
## second or two rather than in one frame nobody sees anyway.
##
## Raise it if stones visibly trail the surface after a collapse; lower it if a
## collapse still costs frames. The real fix is not this number — it is doing
## the whole classification in one native call instead of fifteen per cell, and
## then this budget stops mattering.
const SHELL_CELLS_PER_FLUSH := 512

## Fully outside. Reads as air whatever the gain.
##
## Tempting to set this to what an empty cell reconstructs to
## (`SURFACE_ISO * SDF_GAIN`) and then skip those cells, since the fill would
## already hold the answer. Measured (on the paste path, but the reconstruction
## is the same), it moved the surface half a cell: the value is also what the
## *rock* cells this pass refuses to draw are left holding, and how firmly they
## read as air decides where the crossing with the material resting on them
## lands.
const AIR_SDF := 1.0

var region: GranularVoxelRegion

## One `MeshInstance3D` per chunk that currently holds any surface, keyed by
## chunk coordinate. Created when a chunk first meshes something, freed when it
## meshes nothing — a region is mostly air and holds meshes only where the
## material is.
var _chunk_meshes: Dictionary = {}
## The region-localised surface material, shared by every chunk instance.
var _material: Material
var _last_flush_ms := 0.0
## The flush split, in microseconds, accumulated until read.
##
## `flush` was one number covering unrelated costs — rebuilding and marching
## the field in C++, committing the arrays to meshes, and re-laying the chips
## of every cell that moved. One number cannot say which of them to attack.
var prof_sdf_us := 0
var prof_mesh_us := 0
var prof_shell_us := 0
## The dirty-list bookkeeping: walking every cell that moved to queue its shell
## and grow its chunk's bounds, before any SDF or chip work. Unbudgeted and, on
## a collapse, the largest single cost — split out to confirm that.
var prof_prep_us := 0
## The per-frame chip-transform pass in `_process`, which is granular work but
## runs outside `flush` and so is in none of the split numbers above.
var prof_lay_us := 0
var _last_flush_cells := 0
var _last_flush_chunks := 0
var _last_pending_chunks := 0
## Chunks that have changed and not yet been remeshed, as a set. Held rather
## than remeshed the moment they are dirtied, so a burst is spread over frames
## instead of landing in one. A chunk is remeshed whole, so unlike the paste
## era there is no box to carry — membership is the whole of the debt.
var _pending_chunks: Dictionary = {}
## Flushes since the surface last remeshed, against `SURFACE_FLUSH_EVERY`.
var _surface_flush_debt := 0
## Shell cells that need reconsidering and have not had their turn: a queue and
## a flag per cell, exactly the arrangement `GranularVoxelField` uses for its
## own dirty list.
##
## This was a `Dictionary` keyed by cell index, and it cost more than the work
## it was scheduling. Every dirty cell writes seven entries — itself and six
## neighbours — and a collapse dirties thousands per flush, so the bookkeeping
## alone was measured at about eighty milliseconds a second: more than the SDF
## rebuild and the paste put together. A flag byte and an append are a couple of
## instructions, and draining no longer needs the second pass a dictionary
## needed to avoid erasing while iterating.
var _shell_queue: PackedInt32Array = PackedInt32Array()
var _shell_queued: PackedByteArray = PackedByteArray()
var _shell_cursor := 0

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
## What each animating cell was last actually laid at, so the grow-in re-lays
## only on meaningful steps rather than every frame. See `LAY_STEP`.
var _laid: Dictionary = {}
## Accumulated time since the chip animation last ran, so it ticks at the flush
## rate rather than the frame rate. See `_process`.
var _lay_debt := 0.0
## Shell cells currently drawn as backing — the plug layer behind the chips —
## rather than as chips. Membership is decided by `_refresh_shell_cell` from
## the field, and a cell flipping between the two kinds is re-laid even when
## its mass has not moved: same mass, entirely different picture.
var _backing: Dictionary = {}
## The mesh surface patch near each drawn cell — a point (cell units) and its
## outward normal — from `GranularVoxelField.sample_surface_patches`. Chips seat
## on this so a stone lands on the marching-cubes surface at any facing, top or
## wall, instead of on a per-cell fill height that rings a wall into layers.
## Filled as a cell is drawn, dropped as it clears; a zero normal (or absent)
## means "no trustworthy surface here — seat on the raw fill".
var _surface_pos: Dictionary = {}
var _surface_nrm: Dictionary = {}

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
	# The region's frame is this node's frame, so a field cell and a mesh unit
	# are the same thing and no coordinate maths is needed here.
	transform = region.world_transform()
	_build_surface(surface_material)


func _build_surface(surface_material: Material) -> void:
	var material := (
		surface_material if surface_material != null else _fallback_material()
	)
	if DRAW_GRAINS:
		var field_cells := region.field.size
		_shell_queued.resize(field_cells.x * field_cells.y * field_cells.z)
		_grains = GranularGrainShell.new()
		add_child(_grains)
		# The chips are seated through the surface's own fill floor, so the two
		# renderers put material at the same height instead of the stones
		# standing proud of the mesh they are meant to be lying on.
		_grains.setup(region.up(), RENDER_MIN_FILL if DRAW_SURFACE_MESH else 0.0)
	if not DRAW_SURFACE_MESH:
		return
	# No collider, deliberately, same as the terrain this replaces had none.
	# Loose material is a medium, not a surface: what carries a character is
	# `GranularVoxelWorld.dust_at` and the sinking in `character_motor`, which
	# can express "holds you up, and gives way under you" — a collision shape
	# can only ever express the first half. Doing only the first half to a
	# ten-centimetre scattering is what threw the player into the air every
	# time they drilled under their own feet, and what put a solid wall between
	# the drill and the rock it was aimed at.
	_material = _localise(material)


## Redraw everything the field has changed. Cheap when nothing moved, which is
## most of the time: a settled heap reports no dirty cells at all, however many
## cells it occupies.
func flush() -> void:
	var started := Time.get_ticks_usec()
	var t_prep := started
	# The whole per-dirty-cell walk in one native pass: the shell expansion with
	# its neighbour rings and dedup, and the per-chunk bounds. This was the
	# largest single granular cost on a collapse (129 of 194 ms/s, more than the
	# SDF rebuild and the paste put together) and all of it was integer
	# bookkeeping the field can do over its own dirty list in C++. Clears the
	# dirty list, so it stands in for take_dirty rather than following it.
	var shell_radius := (2 if PLUGS_BEHIND_CHIPS else 1) if DRAW_GRAINS else 0
	var prep: Dictionary = region.field.take_dirty_prep(FLUSH_CHUNK, shell_radius)
	var shell: PackedInt32Array = prep["shell"]
	var chunks: PackedInt32Array = prep["chunks"]
	# The shell queue and pending chunks are work owed too. Without them a heap
	# that comes to rest with cells still waiting would stall them there for
	# good: nothing is dirty any more, so nothing would return to finish them.
	if (
		shell.is_empty()
		and chunks.is_empty()
		and _pending_chunks.is_empty()
		and _shell_cursor >= _shell_queue.size()
	):
		_last_flush_cells = 0
		_last_flush_chunks = 0
		return
	if DRAW_GRAINS:
		# Native deduplicated within this flush; the flag dedups against cells
		# still queued from earlier flushes that have not drained yet.
		for index in shell:
			if _shell_queued[index] == 0:
				_shell_queued[index] = 1
				_shell_queue.append(index)
	if DRAW_SURFACE_MESH:
		# Nine ints per chunk: chunk x,y,z, then the min and max cell that
		# moved in it. Only the chunk matters now — the native mesher remeshes
		# a chunk whole, so the box the prep still reports is left unused.
		var c := 0
		while c < chunks.size():
			_pending_chunks[Vector3i(chunks[c], chunks[c + 1], chunks[c + 2])] = true
			c += 9
	prof_prep_us += Time.get_ticks_usec() - t_prep
	_surface_flush_debt += 1
	var done := 0
	if _surface_flush_debt >= SURFACE_FLUSH_EVERY:
		_surface_flush_debt = 0
		var drawn: Array[Vector3i] = []
		for chunk: Vector3i in _pending_chunks:
			if done >= MESH_CHUNKS_PER_FLUSH:
				break
			_mesh_chunk(chunk)
			drawn.append(chunk)
			done += 1
		for chunk in drawn:
			_pending_chunks.erase(chunk)
	_last_flush_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_last_flush_cells = shell.size()
	_last_flush_chunks = done
	_last_pending_chunks = _pending_chunks.size()
	# Budgeted exactly like the chunks above, and for the same reason measured
	# the same way. Re-laying chips was 298 of the 425 ms/s a big collapse cost
	# — a worst frame of 31 ms and sixteen frames a second — because every cell
	# reconsidered asks the field about itself and its six neighbours, and a
	# plunge into a heap reconsiders tens of thousands of them in one go.
	#
	# Nothing is dropped: cells that miss their turn keep their place in the set
	# and go next flush. The cost is that stones can be a moment behind the
	# surface after something violent, which is the cheapest thing in the whole
	# renderer to be wrong about — they are cosmetic, and the mesh under them
	# carries the shape meanwhile.
	var t_shell := Time.get_ticks_usec()
	var stop := mini(_shell_cursor + SHELL_CELLS_PER_FLUSH, _shell_queue.size())
	# This flush's budget of cells gathered once, so the field is asked about all
	# of them in a single native call rather than a dozen binding calls each. The
	# decision from the answer stays here, in cheap dictionary work — see
	# `_apply_shell_cell`.
	var batch := _shell_queue.slice(_shell_cursor, stop)
	for index in batch:
		_shell_queued[index] = 0
	_shell_cursor = stop
	if not batch.is_empty():
		var sampled: Dictionary = region.field.sample_shell(
			batch, PLUGS_BEHIND_CHIPS
		)
		var masses: PackedFloat32Array = sampled["mass"]
		var opens: PackedFloat32Array = sampled["open"]
		var backs: PackedFloat32Array = sampled["back"]
		# The mesh surface as an oriented patch (point + normal) near each cell,
		# from the same reconstruction the mesher marches, so chips seat on the
		# surface at any facing — top or wall. One batched native call beside the
		# shell sample, not one per cell.
		var patches: Dictionary = (
			region.field.sample_surface_patches(
				batch, RENDER_MIN_FILL, SMOOTH_CENTRE, SURFACE_ISO
			) if DRAW_SURFACE_MESH else {}
		)
		var patch_pos: PackedVector3Array = patches.get("pos", PackedVector3Array())
		var patch_nrm: PackedVector3Array = patches.get("normal", PackedVector3Array())
		var have_patch := not patch_nrm.is_empty()
		for k in batch.size():
			var back_open := backs[k] if PLUGS_BEHIND_CHIPS else 1e9
			var sp := patch_pos[k] if have_patch else Vector3.ZERO
			var sn := patch_nrm[k] if have_patch else Vector3.ZERO
			_apply_shell_cell(batch[k], masses[k], opens[k], back_open, sp, sn)
	# Drained: drop the whole run at once rather than erasing entry by entry.
	if _shell_cursor >= _shell_queue.size():
		_shell_queue.clear()
		_shell_cursor = 0
	prof_shell_us += Time.get_ticks_usec() - t_shell


## Walk the chips toward what the field holds, a step a frame.
##
## Only cells still catching up cost anything, and a heap that has come to rest
## has none — so this is a per-frame pass over a handful of cells, not over the
## heap.
func _process(delta: float) -> void:
	if _animating.is_empty() or _grains == null:
		return
	# The chips follow the field, and the field only changes at the flush rate.
	# Re-laying faster than that is redrawing the same answer: at 200 fps the
	# animation ran nearly seven times per field update for nothing. Gated to the
	# flush rate, the whole accumulated interval is handed to `move_toward` so the
	# grow-in covers the same ground in fewer, larger steps.
	_lay_debt += delta
	if _lay_debt < LAY_INTERVAL_S:
		return
	var lay_delta := _lay_debt
	_lay_debt = 0.0
	# Timed because it is a pass over every animating cell laying up to a dozen
	# instances each, and it is in none of the flush numbers. If the granular
	# flush is small but a plunge still drops frames, this is where to look.
	var t_lay := Time.get_ticks_usec()
	var step := GRAIN_SETTLE_RATE * lay_delta
	var settled: Array[int] = []
	for index: int in _animating:
		var target: float = _animating[index]
		var shown: float = move_toward(float(_shell.get(index, 0.0)), target, step)
		_shell[index] = shown
		var done := is_equal_approx(shown, target)
		# Re-lay only when the chips have actually grown by a visible amount, not
		# every frame the animation ticks. The stones' positions are a hash of
		# the cell and slot and do not move as a cell fills — only their count
		# and height do — so re-laying on a fill change of a hair recomputes an
		# identical layout dozens of times as a cell grows in. That was the whole
		# of the `lay` cost: at 288 ms/s it was the single most expensive thing in
		# the granular renderer, a cell settling over 24 to 80 frames re-laid
		# every one of them. Laying on quantised steps grows a cell in over a
		# handful of relays and looks the same in motion. The final step is always
		# laid, so a cell always lands exactly on its target.
		var last: float = _laid.get(index, -1.0)
		if done or last < 0.0 or absf(shown - last) >= LAY_STEP:
			_grains.lay(
				region, index, shown, _backing.has(index),
				_surface_pos.get(index, Vector3.ZERO),
				_surface_nrm.get(index, Vector3.ZERO)
			)
			_laid[index] = shown
		if done:
			settled.append(index)
	for index in settled:
		_animating.erase(index)
		_laid.erase(index)
	prof_lay_us += Time.get_ticks_usec() - t_lay


## Decide what one cell's chips should be now, from facts the field already
## handed over, and touch the grains only if the answer changed.
##
## `mass` is the cell's own fill. `open` and `back` are the smallest neighbour
## fill one and two cells out, from `GranularVoxelField.sample_shell` — the
## field queries that used to be a dozen binding calls per cell are that one
## batched call now, and what is left here is the cheap stateful decision.
##
## The fill threshold matters as much as the membership test: a cell whose
## material shifted by a hair would otherwise have its stones re-laid, and
## stones that jump a millimetre every frame are the flicker seen from a
## distance. Material genuinely on the move crosses it and is re-laid; material
## settling by fractions is left alone.
func _apply_shell_cell(
	index: int, mass: float, open: float, back: float,
	surface_pos: Vector3, surface_nrm: Vector3
) -> void:
	if _grains == null:
		return
	# A cell that already has stones on it judges "am I still exposed" by a
	# slacker rule than one deciding to grow them. Without that gap the test is
	# a knife edge: a *neighbour* drifting either side of `OPEN_MIN_MASS` flips
	# this cell between exposed and buried, and each flip is a full relay — the
	# stones vanish and a plug appears in a different place, or the other way
	# round, several times a second. That is the handful of pieces that twitch
	# while the heap around them lies still. The relay delta above cannot catch
	# it because this cell's own mass never moved at all.
	var held := _shell.has(index)
	var facing := open < (OPEN_MIN_MASS_HELD if held else OPEN_MIN_MASS)
	# No mesh surface here means nothing for a chip to lie on. This is the fringe:
	# cells holding between the chip floor and `RENDER_MIN_FILL`, where the mesh
	# has pulled back and left no isosurface — so the field hands back a zero
	# normal. Drawing a chip there seats it at its raw cell position, up to a
	# whole cell (0.25 m) proud of where the mesh actually ends. Head-on that is
	# foreshortened to "a little high"; at the silhouette it is seen edge-on and
	# reads as stones hanging in the air off the heap. So a cell with no surface
	# draws nothing, and every chip that is drawn has a surface under it.
	var no_surface := DRAW_SURFACE_MESH and surface_nrm == Vector3.ZERO
	if no_surface or mass < GranularGrainShell.MIN_DRAWN_MASS or (
		not facing and not (PLUGS_BEHIND_CHIPS and back < OPEN_MIN_MASS)
	):
		_animating.erase(index)
		_laid.erase(index)
		_backing.erase(index)
		_surface_pos.erase(index)
		_surface_nrm.erase(index)
		if _shell.erase(index):
			_grains.clear_cell(index)
		return
	# The mesh surface patch near this cell, kept for the chip lay in `_process`
	# (which runs on its own clock and cannot re-query the field).
	_surface_pos[index] = surface_pos
	_surface_nrm[index] = surface_nrm
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


## Rebuild one chunk's mesh from the field, whole.
##
## Whole, not just the cells that moved: a mesh replaces, it cannot paste. The
## native mesher reads its own padding past the chunk — the marching overlap
## plus the kernel's reach — so a cell that moved on the border reshapes the
## surface in the neighbouring chunk too; that neighbour is in the dirty list
## in its own right (the prep expands by the shell radius), and two chunks
## evaluating the same border cells from the same field land on bit-identical
## seam vertices. The straight-edged seams the paste path once had cannot come
## back by construction.
func _mesh_chunk(chunk: Vector3i) -> void:
	var size := region.field.size
	var lo := chunk * FLUSH_CHUNK
	var extent := (size - lo).min(Vector3i.ONE * FLUSH_CHUNK)
	if extent.x <= 0 or extent.y <= 0 or extent.z <= 0:
		return
	# Reconstruction and marching cubes in one native call, arrays out. What
	# used to be here — encode to a 16-bit channel, paste, and a Transvoxel
	# remesh on the plugin's thread that no timer of ours could see — is gone.
	var t_sdf := Time.get_ticks_usec()
	var arrays: Array = region.field.build_mesh_box(
		lo,
		extent,
		SMOOTH_PASSES,
		SMOOTH_CENTRE,
		RENDER_MIN_FILL,
		SURFACE_ISO,
		SDF_GAIN,
		AIR_SDF
	)
	prof_sdf_us += Time.get_ticks_usec() - t_sdf
	# The commit: handing the arrays to the mesh, which uploads to the GPU.
	var t_mesh := Time.get_ticks_usec()
	var instance: MeshInstance3D = _chunk_meshes.get(chunk)
	if arrays.is_empty():
		# A chunk the surface has left entirely — most of a region, most of the
		# time. No node at all, rather than an empty mesh.
		if instance != null:
			_chunk_meshes.erase(chunk)
			instance.queue_free()
		prof_mesh_us += Time.get_ticks_usec() - t_mesh
		return
	if instance == null:
		instance = MeshInstance3D.new()
		instance.mesh = ArrayMesh.new()
		instance.material_override = _material
		# Vertices arrive in cell units of the region's frame; the scale is the
		# only transform a chunk needs.
		instance.scale = Vector3.ONE * region.field.cell_size
		add_child(instance)
		_chunk_meshes[chunk] = instance
	var mesh := instance.mesh as ArrayMesh
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	prof_mesh_us += Time.get_ticks_usec() - t_mesh


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
	# The same warp and detail the game's material carries
	# (`spoil_material_grain.tres`), so a bench shows what the game shows.
	#
	# POM is off: its parallax recesses the visible surface inward, more at
	# grazing angles, and the instanced chips sit on the true geometry — so with
	# POM on the stones float above the apparent surface, worst at the
	# silhouette. The pebble field still shades as cobbles through the normal;
	# only the view-dependent depth (which the chips cannot follow) is gone.
	material.set_shader_parameter("u_pom_steps", 0)
	material.set_shader_parameter("u_warp_amp", 0.3)
	material.set_shader_parameter("u_warp_freq", 0.7)
	material.set_shader_parameter("u_detail_amount", 0.5)
	_surface_material = material
	return _surface_material
