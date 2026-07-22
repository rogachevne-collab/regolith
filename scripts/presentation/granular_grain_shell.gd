class_name GranularGrainShell
extends Node3D
## Loose material drawn as what it actually is: separate pieces.
##
## A marching-cubes surface over the same field is a continuous skin, and a
## continuous skin lit by the same shader as the rock reads as a stone growth
## however it is tuned — three passes of tuning it established that the hard way.
## Cuttings are discrete, and the only reliable way to say so is to draw
## discrete things.
##
## Presentation only, and derived: nothing here is truth, nothing here is asked
## about by the simulation or by the character's feet. `GranularVoxelField`
## says where material is, this says what it looks like, and if this node is
## deleted the game behaves identically.
##
## Only the *shell* is drawn — cells with something exposed next to them. Grains
## buried inside a heap are invisible by definition, and drawing them is the
## difference between thousands of instances and millions.
##
## Three MultiMeshes, not one. A MultiMesh draws one mesh, and one mesh at
## random attitudes is variety of *pose*, not of *silhouette* — every stone in
## the field was the same stone, and the eye eventually says so. Cells are dealt
## between three authored boulders by hash, so neighbouring cells break rock
## from different moulds.

## Pieces laid over a full cell of shell.
##
## This number is set by what the grains have to *do*, not by taste. They are
## the visible texture of the heap — overlapping angular chips is what rubble
## is — and twenty covers a quarter-metre cell densely without being a solid
## crust. Opacity is not their job any more: the plug behind them owns that,
## so a gap between chips is allowed and lands on the heap's own dark mass.
##
## Two earlier passes got this wrong in both directions. Six round ones per cell
## was a regular carpet of identical lumps — bubble wrap. Then one or two, which
## is a scatter you can see straight through. Neither failure was the count on
## its own: round and uniform reads as foam at any density.
##
## Twenty down to eight, and the reason is that the job changed. Twenty was set
## when chips were the whole picture and had to cover a full cell densely. They
## are not any more: `RENDER_MIN_FILL` hands the dense interior to the surface
## mesh and leaves the chips the thin fringe, where the count a cell actually
## uses is `20 * held` — one to five, never twenty.
##
## This is not a saving of the same order as the shadow switch, it is bigger in
## the place that was actually broken. Every cell reserves `SLOTS_PER_CELL`
## whatever it uses, and every reserved slot is submitted to the GPU (see
## `CAPACITY_PER_VARIANT`), so a fringe cell was paying for twenty-one instances
## to draw three. Measured: 2283 cells came to 47943 submitted instances at
## eighty primitives each. At eight the same cells come to 20547.
##
## Back up to twelve, spending what the skirt handed back. `DRAW_FINES` off
## stops the whole 0.02–0.04 band being drawn, and those cells were reserving a
## full `SLOTS_PER_CELL` each like any other — a fresh scatter is mostly that
## band, so the cells saved are many. Eight was picked against a shell that
## still carried them; thirteen slots against one that does not is a smaller
## bill than nine slots was, and twelve covers a cell properly where the chips
## are the only thing drawing it.
##
## Down to eight, because the chips are no longer what makes the heap read as
## dense. The surface shader's parallax pebbles carry the packed-stone crust now
## (see [[granular-crunchy-crust-stack]]), so the chips are accents on it — the
## coarse stones and the broken silhouette — not the substance itself. Twelve
## covered a cell as if it were the whole picture; eight scatters accents over a
## crust that is already dense, and cuts a third off both the slot bill and the
## per-cell lay.
const MAX_GRAINS_PER_CELL := 8
## One extra slot per cell holds the plug: a single lump filling a *buried*
## cell one layer behind the chips. Chips at any count cannot be opaque — a
## gap between convex stones is geometrically guaranteed — and behind a gap in
## the outermost layer there used to be nothing at all, which is why a pile
## read as hollow. The plug is what is behind the gaps: one instance doing the
## job a whole second shell layer of twenty was doing before.
##
## Strictly behind. The first version put the plug in the exposed cell itself,
## under that cell's own chips — and on a thin drilled scatter the chips do not
## cover their cell, so the ground grew pale quarter-metre pancakes. A plug is
## only ever seen through gaps, so it may only exist where every direct
## neighbour is full: one cell in. A one-cell-thick scatter has no such cells
## and gets none, which is right — a scatter is see-through because there is
## nothing inside it to show.
##
## In a *chip* cell the same slot holds the occasional boulder instead.
const SLOTS_PER_CELL := MAX_GRAINS_PER_CELL + 1
## Longest edge of the biggest ordinary chip. Sizes are rolled toward the small
## end, so this is the rare one, not the average.
const GRAIN_SIZE_M := 0.13
const GRAIN_SIZE_MIN_FRACTION := 0.35
## Extra sink of a chip toward the mesh under it, as a fraction of a cell — the
## fallback seating for cells with no mesh under them (the fringe).
##
## This was the whole seating correction once, and it was a fudge: putting the
## chips through the surface's own fill floor (`_seat_floor`) got most of the
## way, and this measured bias was "the rest of the way" — the low-pass and the
## iso level pulling the reconstructed surface off the raw fill height by a
## fraction of a cell, with no closed form worth writing.
##
## It does have a closed form: it is the surface `build_mesh_box` draws, and
## `lay` now receives that surface as a patch (`surface_pos`/`surface_nrm`) for
## every cell that has mesh near it and seats the chips on it. So this bias only
## applies on the fringe, where `RENDER_MIN_FILL` leaves no mesh and the stones
## lie on the raw fill — scaled by the seated fill so a fringe chip is not
## pushed into the rock.
const SEAT_SINK_CELLS := 0.16
## Nestle of a chip into the mesh crust it sits on, as a fraction of a cell, when
## the surface patch is known. Small and constant — the stone rests a little into
## the packed cobbles rather than perched on the highest one. Raise it if stones
## still float above the surface, lower it if they sink into it.
const SEAT_NESTLE_CELLS := 0.06
## How far, in cells, a cell's chips scatter across its surface patch's tangent
## plane. Kept under a cell: the patch is one point with one normal, and its flat
## tangent plane only matches the real (curved) surface close in — scatter wide
## and the outer stones float off the curvature onto air. Just under a cell still
## overlaps a neighbour's patch enough to read as continuous, without the float.
const PATCH_SPREAD_CELLS := 0.8
## A cell with less than this in it gets nothing at all. Low on purpose — the
## thin outer fraction of a heap is drawn as the fines skirt, and cutting the
## skirt off early is what made piles end in a hard line against clean ground.
const MIN_CELL_MASS := 0.02
## Below this fill a cell is not stones any more, it is the fines the stones
## ride out on: a few flat dusty flakes pressed into the ground, not chips.
## This is the skirt — the halo of settled dust a real pile sits in.
##
## Strictly below the old drawing floor of 0.05, so the skirt only ever adds
## to cells that used to be drawn as nothing. At 0.12 it *replaced* cells that
## used to be drawn as stones — a fresh drill scatter mostly holds five to
## thirty per cent fill, and half of it flipped from chips to flat flakes: a
## pool of pancakes where the cuttings had been.
const FINES_MASS := 0.04

## Whether the fines skirt is drawn at all.
##
## Off. The skirt was invented when chips were the entire renderer and a pile
## had to be talked down into the ground by something, because nothing else was
## drawing the contact. That job now belongs to the surface mesh, which beds
## into the rock properly, so the skirt is no longer buying the thing it was
## built for.
##
## And it was never sound. `_lay_fines` puts its flakes on the floor of their
## own cell — `float(y) * cell_size` — without asking what, if anything, is
## underneath: it takes no fill and no support. A cell anywhere in the fines
## band gets its discs wherever it happens to be, including in mid-air, and the
## band is 0.02 to 0.04 where material is still moving. That is the pale flat
## flakes that drift about and hang in the air. Wearing full dust colour, which
## is what makes them read as white, is the last touch.
##
## Turning them on again means giving `_lay_fines` the seated fill and a support
## test first. The knob is here rather than the code deleted because the skirt
## is a real idea — a heap really does thin out to dust at its edge — and what
## is wrong with it is the placement, not the intent.
const DRAW_FINES := false
## Mass below which a cell is drawn as nothing at all, and so never takes slots.
## With the skirt off this rises to the fines threshold, because the band below
## it now has no picture to draw.
const MIN_DRAWN_MASS := FINES_MASS if not DRAW_FINES else MIN_CELL_MASS

## The occasional real boulder, a landmark among the chips. Rare by design:
## one stone two to three cells wide sells the size hierarchy of the whole
## heap, and two of them next to each other sell a texture instead.
const BOULDER_CHANCE := 0.05
const BOULDER_MIN_M := 0.22
const BOULDER_MAX_M := 0.38
## A boulder needs mass under it — a monolith standing in a thin scatter reads
## as dropped there, not dug up.
const BOULDER_MIN_MASS := 0.5

## Fill a backing cell must hold before its plug is drawn. The plug's width is
## fixed — it has to seal against its neighbours — so its shape is set by its
## height, and height follows fill: a buried cell holding a twentieth came out
## as a quarter-metre plate two centimetres thick, spun to a random heading.
## Those were the thin slivers lying around the scatter. Below this there is
## nothing behind the front layer worth hiding anyway.
const PLUG_MIN_MASS := 0.3

## Instances reserved up front, per mesh variant. `instance_count` cannot be
## grown without throwing away everything already written, and everything
## already written is precisely what must not be disturbed — so the room is
## taken once and slots are handed out of it.
##
## Unused slots are collapsed to a zero basis, which costs no pixels. It is NOT
## true, as this said before, that the GPU never looks at them: `_take_slot`
## raises `visible_instance_count` to the high-water mark, and below that mark
## is precisely what gets drawn. A collapsed slot is still an instance fetched,
## transformed and counted. Slots are therefore the unit this renderer is
## billed in, not chips — which is also why `report` counts them and says so.
const CAPACITY_PER_VARIANT := 16000

## Cell index to an encoded (base slot, variant) pair: `base * VARIANTS +
## variant`. A cell keeps its slots for as long as it has chips in them, which
## is what makes a settled heap free to draw *and* still: nothing rewrites it,
## so nothing about it can flicker.
var _slots: Dictionary = {}
var _instances: Array[MultiMeshInstance3D] = []
var _multimeshes: Array[MultiMesh] = []
var _free: Array[Array] = []
var _high_water: PackedInt32Array = PackedInt32Array()
var _last_write_ms := 0.0


## Fill the surface mesh subtracts before it looks for its isosurface — the
## view's `RENDER_MIN_FILL`. Chips are seated through the same subtraction so
## they land on the mesh rather than above it; left at zero they seat on the
## raw fill, which is correct when nothing else is drawing the cell.
var _seat_floor := 0.0


## `up` is the region's local up, which the chip shader needs to know which way
## is down before it can shade an underside. `seat_floor` is the surface's fill
## floor — see `_seat_floor`.
func setup(local_up: Vector3, seat_floor := 0.0) -> void:
	_seat_floor = clampf(seat_floor, 0.0, 0.95)
	_load_meshes()
	# Their own material, and this is the one place that is right. The rule that
	# spoil must not have its own lighting language is about a *surface*
	# competing with the ground; small separate objects need a material that
	# works on small separate objects. Handing them the planet's terrain shader
	# is what made them come out as scattered coal.
	var chip := ShaderMaterial.new()
	chip.shader = load(_SHADER_PATH) as Shader
	chip.set_shader_parameter("u_up", local_up.normalized())
	# The ground's own rock photos, so a chip is the same substance as the
	# crust it was cut from. Missing, the shader falls back to flat colour —
	# worse, but standing.
	var albedo := load(_ALBEDO_TEXTURE_PATH) as Texture2D
	if albedo != null:
		chip.set_shader_parameter("u_albedo", albedo)
	var normal := load(_NORMAL_TEXTURE_PATH) as Texture2D
	if normal != null:
		chip.set_shader_parameter("u_normal", normal)
	for mesh in _meshes:
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		multimesh.mesh = mesh
		multimesh.instance_count = CAPACITY_PER_VARIANT
		multimesh.visible_instance_count = 0
		var node := MultiMeshInstance3D.new()
		node.multimesh = multimesh
		node.material_override = chip
		# Off, because the chips are laid from `_process`, not from physics.
		#
		# With interpolation on, the engine keeps a previous and a current
		# transform for every instance and blends them each rendered frame, so it
		# can smooth motion sampled at the physics rate. Chips are not sampled at
		# the physics rate — they are written directly whenever a cell's fill
		# changes — so there is nothing to interpolate, and writing them from
		# outside physics is exactly what the "MultiMesh interpolation triggered
		# from outside physics process" warning was flagging. Turning it off ends
		# the warning and drops the per-instance blend the engine was doing for
		# nothing.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		# Off, and this is the single most expensive line in the granular
		# renderer when it is on. Measured on the stand, one region holding
		# 63 m3 as 47943 chips: 15358103 primitives a frame with chip shadows,
		# 3852752 without. Three quarters of all the geometry in the frame was
		# the directional light's cascades redrawing every chip once per split.
		# Without them a chip costs its own 80 primitives and nothing more.
		#
		# What is given up is less than it sounds, because the chips are not
		# what casts the heap's shadow — the surface mesh under them is, and it
		# keeps its own shadow. What goes is each stone's individual shadow on
		# its neighbours, and the chip shader already draws that: `u_base_shade`
		# darkens a chip toward its base, which is what makes a dense cluster
		# read as one mass, and its own comment notes it costs nothing.
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Chips stop being drawn past this, and the surface mesh carries the
		# heap alone from there.
		#
		# This is the half of the cost the shadow measurement does not reach.
		# One heap in front of the camera is affordable either way; the frame
		# rate goes when a session has dug all around and a dozen old heaps are
		# still laying out their full shell at eighty metres, where a 7 cm chip
		# is well under a pixel. The two renderers were always meant to split
		# this way — the header of `granular_voxel_region_view` says small spoil
		# favours grains and large masses favour the mesh — and until now
		# nothing actually made the handover happen.
		#
		# Unmeasured, unlike the line above: the stand has one heap and cannot
		# show the case this is for. Judge it in a dug-out world, and if distant
		# heaps visibly shed their stones, this is the number to raise.
		node.visibility_range_end = 30.0
		node.visibility_range_end_margin = 6.0
		node.visibility_range_fade_mode = (
			GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		)
		add_child(node)
		_instances.append(node)
		_multimeshes.append(multimesh)
		_free.append([])
		_high_water.append(0)


## Lay the pieces for one cell. Deterministic: the same cell always produces the
## same stones in the same places, so re-laying a cell that has not really
## changed is a no-op to the eye, and two peers draw one heap.
## `mass` is the fill the chips should be drawn for, which is not always what
## the cell holds this instant: the view walks it toward the truth so material
## grows and drains instead of snapping between layouts.
## `backing` marks a buried cell one layer behind the chips: it gets the plug
## and no chips at all, since nothing of it is ever seen but what shows
## through the gaps in the layer in front.
## `surface_pos` / `surface_nrm` are the mesh surface patch near this cell — a
## point in cell units and its outward normal — from
## `GranularVoxelField.sample_surface_patches`. The chips seat on this patch, so
## they cling to the surface at any facing: bedded into the top, clinging to a
## wall, hanging under an overhang. A zero normal (the default, and what the
## fringe reports) means the field could not orient a surface here, and the
## stones fall back to the raw-fill seating along +Y.
func lay(
	region: GranularVoxelRegion, index: int, mass: float, backing := false,
	surface_pos := Vector3.ZERO, surface_nrm := Vector3.ZERO
) -> void:
	if _multimeshes.is_empty():
		return
	var variants := _multimeshes.size()
	var encoded: int = _slots.get(index, -1)
	var variant: int
	var base: int
	if encoded < 0:
		variant = int(_unit(index * 41 + 19) * float(variants)) % variants
		base = _take_slot(variant)
		if base < 0:
			return
		_slots[index] = base * variants + variant
	else:
		variant = encoded % variants
		base = encoded / variants
	var started := Time.get_ticks_usec()
	var multimesh := _multimeshes[variant]
	var mesh_scale := _mesh_scales[variant]
	var mesh_offset := _mesh_offsets[variant]
	var field := region.field
	var cell_size := field.cell_size
	var plane := field.size.x * field.size.z
	var x := index % field.size.x
	var y := index / plane
	var z := (index / field.size.x) % field.size.z
	var held := minf(mass, 1.0)
	# How much of this cell's height actually holds material. Chips are spread
	# through it, so a part full cell reads as a thin scatter lying on the
	# ground rather than as stones floating half a cell up.
	#
	# Put through the surface's own floor first, because the mesh underneath is
	# not drawn at the raw fill either — `RENDER_MIN_FILL` subtracts a floor and
	# rescales what is left, and the isosurface is found in *that*. Seating the
	# stones on the raw fill instead left them standing slightly proud of the
	# mesh, by exactly the height the floor had lowered it. Reading the same
	# number keeps the two agreeing whatever the floor is set to later, which a
	# hand-tuned offset would not.
	#
	# A cell holding less than the floor seats at zero, which is right rather
	# than a special case: there is no mesh in that cell at all, so its stones
	# are lying on the rock.
	var seated := (
		maxf(held - _seat_floor, 0.0) / maxf(1.0 - _seat_floor, 0.001)
	)
	var fill := seated * cell_size
	# The surface patch the stones seat on. When the field could orient a surface
	# here, the chips scatter across it on its own tangent plane and poke out
	# along its normal — so a wall's stones cling to the wall instead of laddering
	# up it in per-cell rings. On the fringe, where there is no mesh, `on_patch`
	# is false and the stones fall back to the cell's own fill top along +Y.
	var on_patch := surface_nrm != Vector3.ZERO
	var pos_m := surface_pos * cell_size
	var tan_a := Vector3.ZERO
	var tan_b := Vector3.ZERO
	if on_patch:
		# Any two axes spanning the surface: cross the normal with whichever
		# world axis it is least aligned to, so the basis never degenerates.
		var ref := Vector3.UP if absf(surface_nrm.y) < 0.9 else Vector3.RIGHT
		tan_a = surface_nrm.cross(ref).normalized()
		tan_b = surface_nrm.cross(tan_a)
	if backing:
		if held < PLUG_MIN_MASS:
			multimesh.set_instance_transform(base, _EMPTY)
		else:
			_lay_plug(
				multimesh, base, index, x, y, z, cell_size, fill, mesh_scale, mesh_offset
			)
		for g in MAX_GRAINS_PER_CELL:
			multimesh.set_instance_transform(base + 1 + g, _EMPTY)
		_last_write_ms += float(Time.get_ticks_usec() - started) / 1000.0
		return
	if held < FINES_MASS:
		# The view stops offering these cells when the skirt is off, so this is
		# belt and braces — but cheap, and the alternative if one ever slipped
		# through is flakes hanging in the air.
		if not DRAW_FINES:
			for g in SLOTS_PER_CELL:
				multimesh.set_instance_transform(base + g, _EMPTY)
			_last_write_ms += float(Time.get_ticks_usec() - started) / 1000.0
			return
		_lay_fines(multimesh, base, index, x, y, z, cell_size, mesh_scale, mesh_offset)
		_last_write_ms += float(Time.get_ticks_usec() - started) / 1000.0
		return
	# The occasional boulder, in the slot a plug would use. Chips answer "what
	# is this material"; a boulder answers "how big does it come", and a heap
	# with only one answer in it is what read as cheap.
	if held >= BOULDER_MIN_MASS and _unit(index * 29 + 1) < BOULDER_CHANCE:
		_lay_boulder(
			multimesh, base, index, x, y, z, cell_size, fill,
			pos_m, surface_nrm, mesh_scale, mesh_offset
		)
	else:
		multimesh.set_instance_transform(base, _EMPTY)
	# Character of this patch of ground, sampled coarser than the cell grid.
	# Cells rolling their sizes independently is a lattice generator: nearly
	# every cell lands one near-maximum chip, and near-maxima spaced one cell
	# apart are rows the eye snaps to, along every axis at once. Patches four
	# cells wide make coarse and fine *areas*, and areas have no period.
	var patch := _unit(
		(x >> 2) * 73856093 ^ (y >> 2) * 19349663 ^ (z >> 2) * 83492791
	)
	var size_mult := 0.7 + 0.6 * patch
	# How much a cell gets follows how much is in it, so a full cell is covered
	# and a cell holding a fifth is a thin scatter. A little jitter on top, or
	# the count steps visibly from cell to cell; coarse patches carry fewer,
	# bigger stones, fine patches more, smaller ones.
	var shown := clampi(
		int(round(
			float(MAX_GRAINS_PER_CELL)
			* held
			* (0.75 + 0.5 * _unit(index * 9781))
			* (1.2 - 0.4 * patch)
		)),
		1,
		MAX_GRAINS_PER_CELL
	)
	for g in MAX_GRAINS_PER_CELL:
		var slot := base + 1 + g
		if g >= shown:
			multimesh.set_instance_transform(slot, _EMPTY)
			continue
		var seed := index * MAX_GRAINS_PER_CELL + g
		var size_roll := _unit(seed * 3 + 2)
		# Squared, so most chips are small and the big ones are occasional. A
		# flat distribution reads as gravel poured out of a bag.
		var size := GRAIN_SIZE_M * size_mult * (
			GRAIN_SIZE_MIN_FRACTION
			+ (1.0 - GRAIN_SIZE_MIN_FRACTION) * size_roll * size_roll
		)
		# Chips fill the part of the cell that has material in it, not just its
		# top face. A cell exposed on its side is a wall of the heap, and giving
		# every one of its chips the same height left horizontal bands with
		# daylight between them — which is why a pile read as a hollow dome
		# rather than as a pile. Biased upward, because the exposed face usually
		# is up, but never only there.
		var rise := _unit(seed * 3 + 4)
		# How deep in the material this chip is lying, which is what the shader
		# turns into a dust coating. Deep chips merge into the mass, proud ones
		# stay stones — that is what makes a dense cluster cohere without making
		# anything bigger.
		multimesh.set_instance_custom_data(
			slot,
			Color(held * rise * rise, 0.0, _unit(seed * 11 + 9), 0.0)
		)
		var origin: Vector3
		if on_patch:
			# Scattered across the surface patch on its own tangent plane, then
			# pushed out along its normal — some stones proud, some half-buried
			# (`rise`), all clinging to the surface whichever way it faces. This
			# is what stops a wall's chips laddering into per-cell rings: there is
			# no per-cell height any more, only the one continuous surface.
			var a := (_unit(seed * 3 + 0) - 0.5) * PATCH_SPREAD_CELLS * cell_size
			var b := (_unit(seed * 3 + 1) - 0.5) * PATCH_SPREAD_CELLS * cell_size
			# The stone's centre sits *below* the surface, so it lies half-buried
			# in the crust with only its top out — never perched on top. Deeper by
			# `rise`, so a cell is a bed of stones sunk to varying depth, not a
			# layer floating at one height. Nothing is pushed proud of the surface.
			var sink := size * (0.15 + 0.35 * rise) + SEAT_NESTLE_CELLS * cell_size
			origin = pos_m + tan_a * a + tan_b * b - surface_nrm * sink
		else:
			# Fringe fallback: no mesh under the cell, so seat on the raw fill
			# top along +Y with the old measured bias. Spread past the cell's own
			# border by a seventh either side.
			var sink := SEAT_SINK_CELLS * seated * cell_size
			origin = Vector3(
				(float(x) - 0.15 + 1.3 * _unit(seed * 3 + 0)) * cell_size,
				(
					float(y) * cell_size
					+ fill * (1.0 - rise * rise)
					- minf(size * 0.45, fill * 0.6)
					- sink
				),
				(float(z) - 0.15 + 1.3 * _unit(seed * 3 + 1)) * cell_size
			)
		var basis := Basis(
			Quaternion(
				Vector3(
					_unit(seed * 7 + 3) * 2.0 - 1.0,
					_unit(seed * 7 + 5) * 2.0 - 1.0,
					_unit(seed * 7 + 11) * 2.0 - 1.0
				).normalized(),
				_unit(seed * 7 + 13) * TAU
			)
		# Three different edge lengths, then turned to a random attitude: a
		# broken chip, not a pebble. Uniform scaling on a round mesh was the
		# whole reason the first pass read as foam.
		).scaled(
			Vector3(
				size,
				size * (0.35 + 0.4 * _unit(seed * 13 + 1)),
				size * (0.6 + 0.5 * _unit(seed * 13 + 7))
			) * mesh_scale
		)
		# The mesh's own body is offset from its origin, and that offset turns
		# with the chip.
		multimesh.set_instance_transform(
			slot, Transform3D(basis, origin + basis * mesh_offset)
		)
	_last_write_ms += float(Time.get_ticks_usec() - started) / 1000.0


## The plug behind the chip layer: the mass a gap between stones opens onto.
func _lay_plug(
	multimesh: MultiMesh,
	base: int,
	index: int,
	x: int,
	y: int,
	z: int,
	cell_size: float,
	fill: float,
	mesh_scale: float,
	mesh_offset: Vector3
) -> void:
	multimesh.set_instance_custom_data(
		base, Color(1.0, 1.0, _unit(index * 17 + 13), 0.0)
	)
	# One mesh at one attitude in the centre of every cell is a parade
	# ground: identical lumps in perfect rows, and the rows are the grid.
	# The same medicine the chips take — a deterministic spin, unequal sizes,
	# a sidestep off centre — with the turn kept to the vertical axis and the
	# footprint kept oversize, so however a plug is turned its cell stays
	# sealed against its neighbours. Height varies only downward: the top of
	# the cell is where the chips in front begin, and a plug must end under
	# them, not among them.
	var yaw := _unit(index * 17 + 5) * TAU
	var girth := cell_size * (1.06 + 0.18 * _unit(index * 17 + 7))
	var depth := maxf(fill * (0.82 + 0.18 * _unit(index * 17 + 11)), 0.02)
	var plug_basis := Basis(Vector3.UP, yaw).scaled(
		Vector3(girth, depth, girth) * mesh_scale
	)
	var plug_origin := Vector3(
		(float(x) + 0.42 + 0.16 * _unit(index * 17 + 3)) * cell_size,
		float(y) * cell_size + depth * 0.5,
		(float(z) + 0.42 + 0.16 * _unit(index * 17 + 9)) * cell_size
	)
	multimesh.set_instance_transform(
		base, Transform3D(plug_basis, plug_origin + plug_basis * mesh_offset)
	)


## The fines skirt: a nearly-empty cell at the edge of a heap drawn as a few
## flat dusty flakes pressed into the ground. This is what lets a pile sit *in*
## the ground instead of stopping against it — the material really does thin
## out this far, and stones are the wrong picture for it.
func _lay_fines(
	multimesh: MultiMesh,
	base: int,
	index: int,
	x: int,
	y: int,
	z: int,
	cell_size: float,
	mesh_scale: float,
	mesh_offset: Vector3
) -> void:
	multimesh.set_instance_transform(base, _EMPTY)
	var flakes := 2 + int(round(2.0 * _unit(index * 31 + 3)))
	for g in MAX_GRAINS_PER_CELL:
		var slot := base + 1 + g
		if g >= flakes:
			multimesh.set_instance_transform(slot, _EMPTY)
			continue
		var seed := index * MAX_GRAINS_PER_CELL + g
		# Fully dusted: a flake is fines, not stone, and wears the ground's
		# own colour.
		multimesh.set_instance_custom_data(
			slot, Color(1.0, 0.0, _unit(seed * 11 + 9), 0.0)
		)
		var width := 0.09 + 0.08 * _unit(seed * 3 + 2)
		# Flat on purpose, and thin enough that its edge is a couple of
		# centimetres of shadow, not a wall. The first attempt at drawing
		# almost-nothing was a quarter-metre pancake; this is a patch of dust.
		var thick := width * 0.18
		var basis := Basis(
			Vector3.UP, _unit(seed * 7 + 13) * TAU
		).scaled(
			Vector3(width, thick, width * (0.7 + 0.4 * _unit(seed * 13 + 7)))
			* mesh_scale
		)
		var origin := Vector3(
			(float(x) - 0.15 + 1.3 * _unit(seed * 3 + 0)) * cell_size,
			float(y) * cell_size + thick * 0.25,
			(float(z) - 0.15 + 1.3 * _unit(seed * 3 + 1)) * cell_size
		)
		multimesh.set_instance_transform(
			slot, Transform3D(basis, origin + basis * mesh_offset)
		)


## The rare boulder: one stone bigger than its cell, sunk to its waist.
func _lay_boulder(
	multimesh: MultiMesh,
	base: int,
	index: int,
	x: int,
	y: int,
	z: int,
	cell_size: float,
	fill: float,
	pos_m: Vector3,
	surface_nrm: Vector3,
	mesh_scale: float,
	mesh_offset: Vector3
) -> void:
	var size := BOULDER_MIN_M + (BOULDER_MAX_M - BOULDER_MIN_M) * _unit(index * 29 + 7)
	# Lightly dusted — it has been sitting in the spoil, not dropped onto it.
	multimesh.set_instance_custom_data(
		base, Color(0.35, 0.0, _unit(index * 29 + 13), 0.0)
	)
	var basis := Basis(
		Quaternion(
			Vector3(
				_unit(index * 29 + 3) * 2.0 - 1.0,
				_unit(index * 29 + 5) * 2.0 - 1.0,
				_unit(index * 29 + 11) * 2.0 - 1.0
			).normalized(),
			_unit(index * 29 + 17) * TAU
		)
	).scaled(
		Vector3(
			size,
			size * (0.6 + 0.3 * _unit(index * 29 + 19)),
			size * (0.75 + 0.35 * _unit(index * 29 + 23))
		) * mesh_scale
	)
	# Sunk to its waist in the surface: its centre a bit inside the patch along
	# the normal, so a bit over a quarter of it stands proud whichever way the
	# surface faces. On the fringe (no patch) it falls back to the fill top.
	var origin: Vector3
	if surface_nrm != Vector3.ZERO:
		origin = pos_m - surface_nrm * (size * 0.28)
	else:
		origin = Vector3(
			(float(x) + 0.2 + 0.6 * _unit(index * 29 + 27)) * cell_size,
			float(y) * cell_size + fill - size * 0.28,
			(float(z) + 0.2 + 0.6 * _unit(index * 29 + 31)) * cell_size
		)
	multimesh.set_instance_transform(
		base, Transform3D(basis, origin + basis * mesh_offset)
	)


## This cell has no chips any more — collapse them and hand the slots back.
func clear_cell(index: int) -> void:
	var encoded: int = _slots.get(index, -1)
	if encoded < 0:
		return
	var variants := _multimeshes.size()
	var variant := encoded % variants
	var base := encoded / variants
	var multimesh := _multimeshes[variant]
	for g in SLOTS_PER_CELL:
		multimesh.set_instance_transform(base + g, _EMPTY)
	_slots.erase(index)
	_free[variant].append(base)


## Slots for one cell out of its variant's pool, reused before any new ground
## is broken so the visible range stays compact.
func _take_slot(variant: int) -> int:
	var free: Array = _free[variant]
	if not free.is_empty():
		return free.pop_back()
	if _high_water[variant] + SLOTS_PER_CELL > CAPACITY_PER_VARIANT:
		return -1
	var base := _high_water[variant]
	_high_water[variant] = base + SLOTS_PER_CELL
	_multimeshes[variant].visible_instance_count = _high_water[variant]
	return base


func report() -> String:
	var used := 0
	for variant in _multimeshes.size():
		used += _high_water[variant] - _free[variant].size() * SLOTS_PER_CELL
	# Slots, not chips. They differ by a factor of `SLOTS_PER_CELL` and reading
	# one as the other is how "47943 chips" was once quoted for 2283 cells.
	# Slots are the honest number anyway: every one of them is drawn.
	var out := "%d cells / %d slots %.2f ms" % [
		_slots.size(), used, _last_write_ms
	]
	_last_write_ms = 0.0
	return out


const _EMPTY := Transform3D(
	Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO
)


## Deterministic 0..1 from an integer. Integer mixing rather than `sin`: the
## sine trick loses its nerve at large arguments, and cell indices reach the
## hundreds of thousands.
static func _unit(value: int) -> float:
	var h := value & 0x7fffffff
	h = (h ^ 61) ^ (h >> 16)
	h = (h + (h << 3)) & 0x7fffffff
	h = h ^ (h >> 4)
	h = (h * 0x27d4eb2d) & 0x7fffffff
	h = h ^ (h >> 15)
	return float(h & 0xffff) / 65535.0


const _SHADER_PATH := "res://resources/granular_chip.gdshader"
const _ALBEDO_TEXTURE_PATH := "res://resources/textures/ground103/albedo.png"
const _NORMAL_TEXTURE_PATH := "res://resources/textures/ground103/normal.png"
## The world's own boulders, shrunk. Eighty triangles of authored rock beats
## any primitive: a cube read as chopped, a smooth ball read as foam, and a
## generated one is a guess at a shape somebody already drew properly.
const _CHIP_MESH_PATHS: Array[String] = [
	"res://resources/props/lunar_boulder_mesh_small_0.tres",
	"res://resources/props/lunar_boulder_mesh_small_1.tres",
	"res://resources/props/lunar_boulder_mesh_small_2.tres",
]

static var _meshes: Array[Mesh] = []
## Metres per unit of each mesh's longest side, so `GRAIN_SIZE_M` keeps
## meaning "longest edge of the chip" whatever the source mesh happens to be.
static var _mesh_scales: PackedFloat32Array = PackedFloat32Array()
## Where each mesh sits relative to its own origin. The boulders rest on their
## origin rather than being centred on it, and the shader shades a chip's
## underside by measuring from that origin — uncorrected, every chip would be
## treated as if its whole body were above its own centre.
static var _mesh_offsets: PackedVector3Array = PackedVector3Array()


static func _load_meshes() -> void:
	if not _meshes.is_empty():
		return
	for path in _CHIP_MESH_PATHS:
		var loaded := load(path) as Mesh
		if loaded == null:
			continue
		var box := loaded.get_aabb()
		var scale := 1.0 / maxf(
			maxf(box.size.x, box.size.y), maxf(box.size.z, 0.001)
		)
		_meshes.append(loaded)
		_mesh_scales.append(scale)
		_mesh_offsets.append(-(box.position + box.size * 0.5) * scale)
	if _meshes.is_empty():
		var fallback := SphereMesh.new()
		fallback.radius = 0.5
		fallback.height = 1.0
		fallback.radial_segments = 6
		fallback.rings = 3
		_meshes.append(fallback)
		_mesh_scales.append(1.0)
		_mesh_offsets.append(Vector3.ZERO)
