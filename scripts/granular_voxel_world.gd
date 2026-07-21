class_name GranularVoxelWorld
extends Node3D
## Flowing loose material in the actual world: what a drill breaks out of the
## rock becomes a volume of 0.25 m cells that falls, heaps and can be dug back
## up. Spec: `docs/specs/GRANULAR-V0.md`.
##
## Replaces the height-field approach (`granular_world.gd`, parked). The
## difference that matters is that material is a *volume* rather than a surface
## draped over the terrain: it can sit in a bore, against a face or in a
## tunnel, two heaps that meet are simply the same field, and there is no
## second surface fighting the ground for the same space.
##
## Regions are boxes placed where digging happens, each with local up along the
## radial. They are not a grid over the planet and never will be — only a few
## exist at once, around wherever the player is working.

## 96 cells at 0.25 m is a 24 m box, which leaves an 18 m core a cut can be
## served from (see `REGION_EDGE_MARGIN_M`). It was 64 — a 16 m box with a 10 m
## core — and that core is small enough to cross without noticing: step ten
## metres along a trench and the next cut opens a *second* region, whose field
## is independent of the first. Two heaps in one region are one field and merge;
## two heaps in different regions cannot flow into each other, do not support
## each other, and are drawn by different meshers, so they meet in a seam or
## interpenetrate. Widening the core is the cheap way to find out how much of
## that is a real problem before paying for stitching neighbouring fields
## together, which is a far larger commitment.
##
## Costs 8 bytes a cell: about 2 MB of field each at 64, about 7 MB at 96, so
## three of them is roughly 21 MB. The other cost is the terrain each one has to
## stream and mesh, which grows with the volume — 3.4x here — and is paid in a
## hitch when a region is created. Watch that before growing this again.
const REGION_CELLS := 96
const REGION_CELL_SIZE_M := 0.25
## Regions live only around active digging. More than this and the oldest goes.
const MAX_REGIONS := 3

## A cut is served by a region only if its spoil lands well clear of the
## border, otherwise the heap is cut in half by the edge of the box.
const REGION_EDGE_MARGIN_M := 2.0
## How far above the cut the box sits, so most of it is the open space spoil
## will occupy rather than the rock under it. Metres rather than a share of the
## span: how deep the rock goes and how high a heap stacks do not change when
## the box grows, so a share would spend the extra span on empty sky instead of
## on the working area, which is the only part that was short.
const REGION_LIFT_M := 4.0

## How much of a cut stays on the ground as spoil is a property of the material
## it was cut from — see `TerrainMaterialCatalog.spoil_fraction`. Plain rock
## leaves a thin apron at 0.35; an ore or ice lens leaves nearly all of it, and
## that is what makes a lens read as loose material rather than as more rock.
##
## It is about how buried a working face gets, not about hiding volume: what the
## tool carries off is credited separately by the yield path, and loose material
## can be dug back out (`dig_spoil`).
##
## Ceiling on what one cut may turn into spoil. A hand-drill bite at r = 1.0 is
## roughly 4 m³ of rock, so this only ever engages for impacts and rig carves —
## it exists so a single huge cut cannot try to fill a whole region at once.
const MAX_SPOIL_PER_BITE_M3 := 8.0
## Footprint one load is spread over. Still wider than it is tall — the same
## volume in a narrow column is a tower that has to collapse, and the collapse
## is what reads as material appearing above the ground — but only just.
const SPOIL_RADIUS_CELLS := 1
## Landing pattern of the throw: how many points the load is split across, how
## wide the cone opens, how far it carries, and how much of the direction is
## traded for local up so the spray clears the lip of the hole.
##
## Tightened, but do not expect much of it, and do not blame it for flat spoil.
## Measured over forty bites: a face worked from one spot heaps to the angle of
## repose whatever this pattern is — 1.5 m tall at ~37 deg, wide cone and narrow
## alike. Swept along, which is what a player actually does, the same spoil
## arrives as a low apron either way and the cone only decides how wide: 9.0 m
## at 12.5 deg before, 7.25 m at 15.4 deg now.
##
## The rest is arithmetic and no landing pattern can touch it. Seven cubic
## metres over a six-metre sweep is seventeen centimetres deep however it is
## thrown. Spoil reads as a crust because a broad shallow excavation returns a
## broad shallow pile; making it read as heaps means concentrating it — a bigger
## spoil fraction, or a delivery point that stops following the aim — and both
## of those are design decisions, not tuning. The per-material fraction is the
## first of those two levers.
const SPOIL_CONE_SAMPLES := 3
const SPOIL_CONE_SPREAD_DEG := 18.0
const SPOIL_THROW_M := 1.0
const SPOIL_THROW_LIFT := 0.45

## Cells one region may step per sweep, and how often sweeps run. Wall clock
## for now; under coop this has to hang off the simulation's fixed tick or the
## number of sweeps follows the frame rate and peers diverge.
## DIAGNOSTIC — put this back to `true` when the question below is answered.
##
## Off, digging carves the world and undermines whatever rests on it, but makes
## no cuttings at all: no deposit, no rock oracle, no heap, nothing for the view
## to flush. Everything else about a bite is untouched, so the difference
## between this and `true` is exactly the cost of creating spoil.
##
## The question: a powerful bite hitches hard at the moment of extraction. Two
## candidates and no way to tell them apart from a profile alone — the granular
## placement, or the plugin remeshing the world chunks the drill just carved,
## which has nothing to do with any of this. Measured headless, placement came
## to about three milliseconds for three cubic metres, which is real but is not
## a drop from two hundred frames to fifteen. So it is worth one A/B rather than
## another round of me guessing.
##
## Off: hitch gone → it is the spoil, and the rock oracle gets batched.
## Off: hitch stays → it is the terrain carve, and none of the granular work
## touches it.
const SPOIL_FROM_DIGGING := true
## How far below the cut the bulk rock read reaches. Every column of a deposit
## looks down for its own ground, so the cells under the footprint are asked
## about too — priming only the footprint would leave that search paying the
## per-cell oracle it was meant to avoid.
const GROUND_PRIME_DEPTH_CELLS := 14
## Cell layers of a region whose rock is read in bulk per frame.
##
## The whole region is about 27 milliseconds to prime in one go, which is a
## dropped frame, so it goes a slice at a time and one region at a time. Four
## layers of a 96-cube is about 37000 cells, half a millisecond, and a region
## is fully known inside half a second — during which the lazy oracle still
## answers anything that is asked early, so nothing waits on this.
## Eight rather than four: a region is fully known in about a fifth of a
## second instead of half of one, and the window where a freshly created region
## still answers cell by cell is what the oracle count is made of. New regions
## appear exactly while digging, which is the worst possible moment for them to
## be slow.
const PRIME_LAYERS_PER_FRAME := 8

## How often the surface is rewritten, as opposed to how often the field moves.
##
## These were the same number and should never have been. The field steps at
## `SETTLE_HZ` — deliberately high, so material moves in small increments rather
## than visible hops — but every write makes the plugin remesh that chunk, and
## that cost is not ours to measure: it lands outside every timer in this file,
## in the plugin's own meshing. Measured in the game, the granular phases came
## to four to nine milliseconds of a twenty-three millisecond frame while
## digging, and the missing fifteen are the meshing our own flushes asked for.
##
## So the picture updates on its own clock. This is a straight trade and the eye
## has to settle it: lower is cheaper and coarser, higher is smoother and makes
## the plugin rebuild more. Sixty matches what it has been doing; thirty was the
## behaviour before any of the smoothness work and cost half as much.
const MESH_FLUSH_HZ := 30.0

var _flush_debt := 0.0

## DIAGNOSTIC — prints one line a second while anything is happening.
##
## Here because two rounds of fixing this from a headless proxy missed: the
## proxy puts a whole bite at 0.6 ms and the game still drops frames, so the
## cost is somewhere the proxy cannot see. Rather than guess a third time, the
## game measures itself and says which phase it is.
##
## Set to `false` when the answer is in.
const PROFILE_GRANULAR := true
const PROFILE_PERIOD_S := 1.0

var _prof_bites := 0
var _prof_invalidate_us := 0
var _prof_prime_us := 0
var _prof_scatter_us := 0
var _prof_sweep_us := 0
var _prof_flush_us := 0
var _prof_frames := 0
var _prof_worst_frame_us := 0
var _prof_left := PROFILE_PERIOD_S


## One line a second, and only when there was work — so a quiet game says
## nothing and a drilling one says exactly where its milliseconds went.
func _report_profile(delta: float) -> void:
	var frame_us := (
		_prof_invalidate_us + _prof_prime_us + _prof_scatter_us
		+ _prof_sweep_us + _prof_flush_us
	)
	_prof_worst_frame_us = maxi(_prof_worst_frame_us, frame_us - _prof_last_total_us)
	_prof_last_total_us = frame_us
	_prof_frames += 1
	_prof_left -= delta
	if _prof_left > 0.0:
		return
	_prof_left = PROFILE_PERIOD_S
	var oracle := 0
	for entry: Dictionary in _regions:
		var region: GranularVoxelRegion = entry["region"]
		oracle += region.oracle_calls
		region.oracle_calls = 0
	if _prof_bites == 0 and _prof_sweep_us + _prof_flush_us < 1000:
		_reset_profile()
		return
	print(
		"[granular] %d bites | invalidate %.1f  prime %.1f  scatter %.1f  sweep %.1f  flush %.1f ms/s"
		% [
			_prof_bites,
			_prof_invalidate_us / 1000.0,
			_prof_prime_us / 1000.0,
			_prof_scatter_us / 1000.0,
			_prof_sweep_us / 1000.0,
			_prof_flush_us / 1000.0,
		]
	)
	# The active count is the one that decides how stepped settling looks: if it
	# stands above `CELL_BUDGET_PER_SWEEP`, cells are being reached in rotation
	# and each one moves at a fraction of the sweep rate.
	var active := 0
	for entry: Dictionary in _regions:
		var region: GranularVoxelRegion = entry["region"]
		active = maxi(active, region.field.pending_count())
	print(
		"[granular] worst frame %.2f ms | %d oracle calls/s | %d regions | %d active cells (budget %d)"
		% [
			_prof_worst_frame_us / 1000.0,
			oracle,
			_regions.size(),
			active,
			CELL_BUDGET_PER_SWEEP,
		]
	)
	_reset_profile()


var _prof_last_total_us := 0


func _reset_profile() -> void:
	_prof_bites = 0
	_prof_invalidate_us = 0
	_prof_prime_us = 0
	_prof_scatter_us = 0
	_prof_sweep_us = 0
	_prof_flush_us = 0
	_prof_frames = 0
	_prof_worst_frame_us = 0
	_prof_last_total_us = 0

## Cells one region may move per sweep.
##
## This, not the sweep rate, is what sets how often any *given* cell moves. A
## sweep takes the budget as a rotating window over the active set, so with 1600
## cells awake and a budget of 160 each one is reached every tenth sweep — at
## 120 Hz that is twelve hertz per cell, which is precisely how stepped the
## settling looked. Raising the rate did nothing for it, because the rate was
## never the constraint.
##
## And a budget below the queue does something worse than slow the picture: it
## stops the field ever coming to rest. A sweep takes its window and re-queues
## everything it did not reach, so with nine thousand cells awake and a budget
## of five hundred the backlog is permanent — measured in the game, nine
## thousand cells still active with nothing being dug, and thirty-odd
## milliseconds a second of sweeps and fifty of flush paid for ever.
##
## Which inverts what a budget is for. A settled heap costs nothing at all, by
## construction: no active cells, no dirty cells, no work. So a budget large
## enough to drain the queue is *cheaper* over any real span than one that
## keeps the heap permanently half-settled — it pays a burst and then stops,
## instead of paying a tax with no end.
##
## Two thousand across three regions at sixty hertz is a peak of a few hundred
## thousand visits a second, and only while there is that much to do. The
## profiler prints the real queue length, so the test is simple: after digging
## stops, `active cells` has to fall to zero. If it plateaus instead, the field
## is oscillating and no budget will fix it.
const CELL_BUDGET_PER_SWEEP := 2048
## Derived from the step size rather than set beside it, so material keeps
## falling at the same speed whatever the fineness is: quarter the movement per
## sweep, four times the sweeps. Setting these two independently is how the
## sand quietly becomes syrup.
const SETTLE_HZ := 30.0 / GranularVoxelRegion.STEP_FINENESS
## Ceiling on catching up after a hitch, so a dropped frame cannot turn into a
## burst that drops the next one too. At sixty frames a second the rate above
## already wants two sweeps every frame, so a cap of two would leave no slack
## at all and settling would quietly fall behind whenever the frame did. Eight
## is about nine tenths of a millisecond in the worst case, which is what the
## native field costs — the old cap of two was sized for a field that cost
## fifty times more per sweep.
const MAX_SWEEPS_PER_FRAME := 8

## Share of the drill's radius it actually swallows. The rest it shoves aside.
const SPOIL_COLLECT_RADIUS := 0.45
## Fill a cell needs before the aim will call it a target. Below this there is
## material in the air but nothing anybody would say they are pointing at.
const DUST_AIM_MIN_FILL := 0.2

## Footprint a tipped-out load is spread over. Wider than a drill's spray: a
## scoop is emptied deliberately in one place, and a narrow column would only
## have to collapse again.
const DUMP_RADIUS_CELLS := 2

## Group the command gateway looks in to route drilling into loose material.
const GROUP_NAME := &"granular_world"

## Dust and grit thrown off the bit. Presentation only, and the only part of
## this that has any motion in it: the field has no momentum, so a cut deposits
## its spoil already landed and the flight between the two is entirely this.
## One pooled stream — a drill works one hole at a time.
const STREAM_VFX := preload("res://scenes/vfx/granular_stream_vfx.tscn")
## Seconds the stream keeps going after the last cut. Long enough to bridge the
## gap between bites while drilling, short enough to stop when the trigger does.
const STREAM_LINGER_S := 0.25
## Fresh spoil: `granular_surface.gdshader`, Ground103 only.
## (StandardMaterial3D has no usable UVs on VoxelTerrain → washed-out white.)
##
## Was the planet's own Transvoxel shader, which is built for a crust and drew
## a heap as one continuous substance with a torn quarter-metre outline. The
## mesh is the same; the stones and the dissolved silhouette are in the
## fragment stage now. `spoil_material.tres` is the old one, kept so this is a
## one-line revert.
const SPOIL_MATERIAL_PATH := "res://resources/spoil_material_grain.tres"

@export var gateway_path: NodePath = NodePath("../WorldCommandGateway")
@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
## Off by default so a scene opts in rather than every scene that owns a
## gateway inheriting a second terrain it never asked for.
@export var enabled := false

var _terrain: Node3D
var _voxel_tool: VoxelTool
var _gravity_field: GravityField
var _sweep_debt := 0.0
var _stream: GranularStreamVfx
var _stream_left := 0.0
var _material_field := MoonMaterialField.new()
## Spoil that had nowhere to go: a region too full to take it, or a region
## evicted while still holding material. Counted rather than quietly absorbed,
## because a heap that stops growing while you are still cutting reads as a bug
## and the only way to tell the difference is a number.
var _spoil_dropped_m3 := 0.0
## Least recently dug first. Each entry: `{ "region", "view" }`.
var _regions: Array[Dictionary] = []


func _ready() -> void:
	if not enabled:
		set_process(false)
		return
	_terrain = get_node_or_null(terrain_path) as Node3D
	if _terrain != null:
		_voxel_tool = TerrainCompat.get_voxel_tool(_terrain)
	var gateway := get_node_or_null(gateway_path) as WorldCommandGateway
	if gateway == null or _voxel_tool == null:
		push_warning(
			"GranularVoxelWorld: no gateway or terrain; loose material is off"
		)
		set_process(false)
		return
	add_to_group(GROUP_NAME)
	gateway.terrain_modified.connect(_on_terrain_modified)
	call_deferred("_bind_gravity_field")


func _bind_gravity_field() -> void:
	_gravity_field = GravityField.find_in_tree(self)


func _process(delta: float) -> void:
	_sweep_debt += delta * SETTLE_HZ
	var sweeps := mini(int(_sweep_debt), MAX_SWEEPS_PER_FRAME)
	if sweeps > 0:
		_sweep_debt -= float(sweeps)
	# Rewriting a chunk makes the plugin remesh it and rebuild its collider, so
	# flushing every frame pays for pictures the simulation has not produced:
	# the field only moves at `SETTLE_HZ`, and between sweeps there is nothing
	# new to show. Only worth doing on frames that actually stepped.
	if _stream != null:
		_stream_left = maxf(_stream_left - delta, 0.0)
		_stream.set_active(_stream_left > 0.0)
	# Learn the rock a slice at a time, before anything asks about it a cell at
	# a time. Cheap and bounded, and once a region is through it the oracle
	# falls silent — which is the difference between sweeps costing what the
	# native field costs and sweeps costing what a GDScript callback costs.
	var t_prime_bg := Time.get_ticks_usec()
	for entry: Dictionary in _regions:
		var region: GranularVoxelRegion = entry["region"]
		if not region.prime_rock_step(PRIME_LAYERS_PER_FRAME):
			break
	_prof_prime_us += Time.get_ticks_usec() - t_prime_bg
	_flush_debt += delta * MESH_FLUSH_HZ
	var should_flush := sweeps > 0 and _flush_debt >= 1.0
	if should_flush:
		_flush_debt = fmod(_flush_debt, 1.0)
	var t_sweep := Time.get_ticks_usec()
	for entry: Dictionary in _regions:
		var region: GranularVoxelRegion = entry["region"]
		for _i in sweeps:
			if region.field.is_settled():
				break
			region.field.step(CELL_BUDGET_PER_SWEEP)
	_prof_sweep_us += Time.get_ticks_usec() - t_sweep
	var t_flush := Time.get_ticks_usec()
	if should_flush:
		for entry: Dictionary in _regions:
			var view: GranularVoxelRegionView = entry["view"]
			view.flush()
	_prof_flush_us += Time.get_ticks_usec() - t_flush
	if PROFILE_GRANULAR:
		_report_profile(delta)


## Every carve in the world arrives here, whatever made it. Two things happen:
## the rock that vanished stops supporting anything that was resting on it, and
## the volume it had becomes loose material beside the cut.
func _on_terrain_modified(
	removed_volume_m3: float,
	dig_center: Vector3,
	dig_radius_m: float,
	dig_direction: Vector3
) -> void:
	if dig_radius_m <= 0.0:
		return
	_prof_bites += 1
	# Support first, and for *every* region that reaches the cut — a heap can
	# straddle a border, and the one that was undermined is not always the one
	# the new spoil belongs to.
	# Forgetting the disturbed rock and re-reading it, plus the ground the spoil
	# is about to land on, as one box per region. Two separate reads over
	# overlapping boxes is what this used to be, and the game put that at forty
	# milliseconds a second.
	var prime_radius := maxf(
		dig_radius_m * 2.0,
		dig_radius_m + SPOIL_THROW_M + float(SPOIL_RADIUS_CELLS) * REGION_CELL_SIZE_M
	)
	var t_invalidate := Time.get_ticks_usec()
	for entry: Dictionary in _regions:
		var region: GranularVoxelRegion = entry["region"]
		if region.covers(dig_center):
			region.invalidate_rock(
				dig_center,
				dig_radius_m * 2.0,
				prime_radius,
				GROUND_PRIME_DEPTH_CELLS
			)
	_prof_invalidate_us += Time.get_ticks_usec() - t_invalidate
	if not SPOIL_FROM_DIGGING:
		return
	# What the cut was made of decides how much of it stays. Sampled here rather
	# than shipped along the signal: the material field is a pure function of
	# position, so every emitter — hand drill, impact, rig — is covered without
	# inventing a material for the two that never resolve one, and under coop
	# two peers computing it independently cannot disagree. The sample belongs
	# to `dig_center`, which is where the spoil is placed.
	var material_id := _material_field.material_id_at_world(dig_center)
	var spoil := removed_volume_m3 * TerrainMaterialCatalog.spoil_fraction(material_id)
	if spoil <= 0.000001:
		return
	spoil = minf(spoil, MAX_SPOIL_PER_BITE_M3)
	var index := _region_index_for(dig_center, dig_radius_m)
	if index < 0:
		_spoil_dropped_m3 += spoil
		return
	var target: GranularVoxelRegion = _regions[index]["region"]
	# Read the rock the whole cone is about to land on in one go. Without this
	# every one of the thousand-odd cells a bite touches asks the terrain for
	# itself, eight voxel reads at a time, in this frame — which is what made a
	# big cut hitch while the spoil appeared.
	var t_scatter := Time.get_ticks_usec()
	var accepted := _scatter_spoil(
		target, dig_center, dig_radius_m, dig_direction, spoil
	)
	_prof_scatter_us += Time.get_ticks_usec() - t_scatter
	_spoil_dropped_m3 += maxf(spoil - accepted, 0.0)
	_touch(index)


## Throw the cuttings back out of the hole in a cone, the way a bit spits
## material at whoever is holding it.
##
## This places where the ejecta *lands*, not how it flies: the field has no
## momentum, only falling and spreading, so ballistics belong to the VFX and
## the landing pattern belongs here. Spread over several points along the cone
## rather than one, with most of the volume near the mouth and less further
## out, which is roughly how a throw distributes.
##
## Deterministic: the sample pattern is a fixed spiral, no RNG, so two peers
## build the same heap from the same cut.
##
## With no direction to work from — an impact, a separation pass — it falls
## back to dropping the load into the void the cut just opened. `deposit`
## refuses cells that are still rock and fills upward, so material settles
## into the hole and stacks past the surface only once that is full.
##
## Returns the volume the field actually took. A full region accepts less than
## it was handed, and that shortfall is the caller's to account for — at a
## third of the cut it was rare enough to ignore, but a lens that stays put
## almost entirely will find the edges of a region regularly.
func _scatter_spoil(
	region: GranularVoxelRegion,
	dig_center: Vector3,
	dig_radius_m: float,
	dig_direction: Vector3,
	volume_m3: float
) -> float:
	if dig_direction.length_squared() <= 0.000001:
		return region.deposit_landing_at(
			dig_center, volume_m3, SPOIL_RADIUS_CELLS
		)
	# Back out of the hole, and lifted a little along local up so the spray
	# clears the lip instead of burying itself in the face it came from.
	var up := region.up()
	var back := (-dig_direction.normalized() + up * SPOIL_THROW_LIFT).normalized()
	var side := back.cross(up)
	if side.length_squared() <= 0.000001:
		side = back.cross(Vector3.RIGHT)
	side = side.normalized()
	var other := back.cross(side).normalized()
	var spread := tan(deg_to_rad(SPOIL_CONE_SPREAD_DEG))
	var accepted := 0.0
	var weight_total := 0.0
	var weights := PackedFloat32Array()
	for k in SPOIL_CONE_SAMPLES:
		# Nearer the mouth gets more, as a throw does.
		var weight := 1.0 - 0.6 * (float(k) / float(SPOIL_CONE_SAMPLES))
		weights.append(weight)
		weight_total += weight
	for k in SPOIL_CONE_SAMPLES:
		var t := float(k) / float(maxi(SPOIL_CONE_SAMPLES - 1, 1))
		# Golden angle: an even spiral over the cone without any randomness.
		var angle := float(k) * 2.399963
		var radial := sqrt(t) * spread
		var direction := (
			back + (side * cos(angle) + other * sin(angle)) * radial
		).normalized()
		var distance := dig_radius_m + SPOIL_THROW_M * (0.25 + 0.75 * t)
		# Landed, not released: the cone says where the throw ends up, and
		# putting it straight there spares the field the descent — which was
		# most of its work and all of the visible stepping.
		accepted += region.deposit_landing_at(
			dig_center + direction * distance,
			volume_m3 * weights[k] / weight_total,
			SPOIL_RADIUS_CELLS
		)
	return accepted


## Loose material standing in the column at a world point — `depth_m` and the
## world point of its `surface`, or empty when there is none. See
## `GranularVoxelRegion.dust_column_at`: this is how a character is carried by
## a heap without the heap being a collider.
##
## Called every physics frame by anything that walks, so it stays a column walk
## and nothing more. Most of the time no region covers the point at all and this
## costs a handful of bounds checks.
func dust_at(world_point: Vector3) -> Dictionary:
	for index in range(_regions.size() - 1, -1, -1):
		var region: GranularVoxelRegion = _regions[index]["region"]
		if not region.covers(world_point):
			continue
		var column := region.dust_column_at(world_point)
		if not column.is_empty():
			return column
	return {}


## Point the spoil stream at where the cuttings are going and keep it alive a
## moment. Spawned on first use rather than up front, so a scene that never digs
## never pays for it.
func _emit_stream(
	origin: Vector3,
	direction: Vector3,
	volume_m3: float
) -> void:
	if _stream == null:
		_stream = STREAM_VFX.instantiate() as GranularStreamVfx
		if _stream == null:
			return
		add_child(_stream)
	_stream.global_position = origin
	# Wider and faster for a bigger bite, within reason: a rig taking half a
	# cubic metre should visibly throw more than a hand drill nibbling.
	_stream.aim(
		direction,
		12.0,
		0.9,
		1.8 + minf(volume_m3 * 6.0, 2.0),
		0.06 + minf(volume_m3 * 1.5, 0.14)
	)
	_stream_left = STREAM_LINGER_S


## Clear loose material where a drill is working a heap, and report the volume
## taken so the caller can credit it as yield. Zero when there is nothing
## there — which the caller must read as "nothing to dig", not as a dig done.
## Called by `WorldCommandGateway` when the aim lands on spoil.
func dig_spoil(world_point: Vector3, radius_m: float) -> float:
	for index in range(_regions.size() - 1, -1, -1):
		var region: GranularVoxelRegion = _regions[index]["region"]
		if not region.covers(world_point):
			continue
		# A bit working loose material mostly parts it. What it swallows is the
		# narrow core it is actually cutting, and that is what comes back as
		# yield; the rest goes sideways and stays in the world. Collecting the
		# lot would make clearing spoil strictly better than leaving it, and the
		# split that decides how buried a face gets would stop meaning anything.
		var taken := region.dig_at(world_point, radius_m * SPOIL_COLLECT_RADIUS)
		var pushed := region.push_at(world_point, radius_m)
		if taken <= 0.0 and pushed <= 0.0:
			continue
		_touch(index)
		return taken
	return 0.0


## Take loose material into a carried tool, up to what it can still hold.
## Returns the volume taken, which the caller must add to its load — this is the
## only record that the material left the world.
##
## Unlike `dig_spoil`, this collects everything inside the sphere rather than a
## narrow core, and does not shove the rest aside: a scoop is for gathering, a
## bit mostly parts what it meets. It is also the reason `dig_at` grew a budget
## — a scoop that reports more than its capacity has lost the difference.
func scoop_spoil(
	world_point: Vector3,
	radius_m: float,
	max_volume_m3: float
) -> float:
	if max_volume_m3 <= 0.000001:
		return 0.0
	for index in range(_regions.size() - 1, -1, -1):
		var region: GranularVoxelRegion = _regions[index]["region"]
		if not region.covers(world_point):
			continue
		var taken := region.dig_at(world_point, radius_m, max_volume_m3)
		if taken <= 0.0:
			continue
		_touch(index)
		return taken
	return 0.0


## Put a carried load back into the world. Returns what the field accepted;
## anything short of that is still in the tool and must stay there, or the
## volume is gone with nothing to show for it.
##
## Creates a region if none covers the spot — you can carry material somewhere
## the drill has never been, and it has to land there.
func dump_load(world_point: Vector3, volume_m3: float) -> float:
	if volume_m3 <= 0.000001:
		return 0.0
	var index := _region_index_for(world_point, DUMP_RADIUS_CELLS * REGION_CELL_SIZE_M)
	if index < 0:
		return 0.0
	var region: GranularVoxelRegion = _regions[index]["region"]
	var accepted := region.deposit_landing_at(
		world_point, volume_m3, DUMP_RADIUS_CELLS
	)
	if accepted > 0.0:
		_touch(index)
	return accepted


## First point along a ray where loose material stands, or empty.
##
## Marched rather than raycast, because there is nothing to raycast: material is
## a medium and has no collider. Half a cell a step is finer than the field it
## is sampling, and the walk stops at whatever the aim already found — so this
## only ever runs over the stretch in front of the rock.
func raycast_dust(
	origin: Vector3,
	direction: Vector3,
	max_distance: float
) -> Dictionary:
	if _regions.is_empty() or max_distance <= 0.0:
		return {}
	var step := REGION_CELL_SIZE_M * 0.5
	var travelled := 0.0
	while travelled <= max_distance:
		var point := origin + direction * travelled
		for index in range(_regions.size() - 1, -1, -1):
			var region: GranularVoxelRegion = _regions[index]["region"]
			if not region.covers(point):
				continue
			if region.mass_at_world(point) >= DUST_AIM_MIN_FILL:
				return {"point": point, "distance": travelled}
		travelled += step
	return {}


## Index of the region that owns a cut, creating one when nothing covers it.
func _region_index_for(dig_center: Vector3, dig_radius_m: float) -> int:
	var margin := dig_radius_m + REGION_EDGE_MARGIN_M
	for index in range(_regions.size() - 1, -1, -1):
		var region: GranularVoxelRegion = _regions[index]["region"]
		if region.covers(dig_center, margin):
			return index
	return _create_region(dig_center)


func _create_region(dig_center: Vector3) -> int:
	var up := (
		_gravity_field.up_at(dig_center)
		if _gravity_field != null
		else GravityField.resolve_up(self, dig_center)
	)
	var centre := dig_center + up * REGION_LIFT_M
	var region := GranularVoxelRegion.create(
		centre, up, _terrain, _voxel_tool, REGION_CELLS, REGION_CELL_SIZE_M
	)
	var view := GranularVoxelRegionView.new()
	add_child(view)
	view.setup(region, _make_spoil_material())
	_regions.append({"region": region, "view": view})
	while _regions.size() > MAX_REGIONS:
		var evicted: Dictionary = _regions.pop_front()
		# Whatever the retired region still held goes with it. That is the one
		# place material genuinely vanishes from the world, so count it here
		# rather than let a heap quietly disappear when the player walks back.
		var retired: GranularVoxelRegion = evicted["region"]
		if retired != null and retired.field != null:
			_spoil_dropped_m3 += retired.field.total_volume_m3()
		var oldest: GranularVoxelRegionView = evicted["view"]
		if is_instance_valid(oldest):
			oldest.queue_free()
	return _regions.size() - 1


## Volume that never made it into the field: cuts with no region to take them,
## regions too full to accept, and heaps lost with an evicted region. A debug
## readout, and the difference between "the heap stopped growing" being a
## design limit and being a bug.
func dropped_spoil_m3() -> float:
	return _spoil_dropped_m3


## Planet Transvoxel shader + Ground103 textures. Copy radial uniforms from the
## live terrain material so world-space triplanar matches the crust.
func _make_spoil_material() -> Material:
	var loaded: Material = load(SPOIL_MATERIAL_PATH) as Material
	if loaded == null:
		return TerrainCompat.get_surface_material(_terrain)
	var spoil_mat: Material = loaded.duplicate()
	var planet_mat := TerrainCompat.get_surface_material(_terrain)
	if spoil_mat is ShaderMaterial and planet_mat is ShaderMaterial:
		var spoil_shader := spoil_mat as ShaderMaterial
		var planet_shader := planet_mat as ShaderMaterial
		var radial: Variant = planet_shader.get_shader_parameter("u_radial_up")
		var radius: Variant = planet_shader.get_shader_parameter("u_planet_radius")
		if radial != null:
			spoil_shader.set_shader_parameter("u_radial_up", radial)
		if radius != null:
			spoil_shader.set_shader_parameter("u_planet_radius", radius)
	return spoil_mat


## Keep the most recently used region last, so the cap frees the face the
## player walked away from rather than the one under their feet.
func _touch(index: int) -> void:
	if index < 0 or index >= _regions.size() - 1:
		return
	_regions.append(_regions.pop_at(index))
