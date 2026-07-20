extends Node
## Granular v0 core logic: volume conservation, angle of repose, blocked
## cells, determinism. Spec: docs/specs/GRANULAR-V0.md.

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")

const LABEL := "GRANULAR-V0"
const GRID := 25
const CELL := 0.25
const REPOSE_DEG := 33.0
const RELAX_CAP := 200


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, LABEL)
	var tests: Array[Callable] = [
		_test_volume_conserved,
		_test_repose_angle,
		_test_pile_is_not_a_diamond,
		_test_settling_is_slower_under_lunar_gravity,
		_test_steep_base_slides,
		_test_blocked_cells_are_walls,
		_test_height_map_holes,
		_test_deterministic,
		_test_take_never_exceeds_available,
		_test_metastable_slope_holds_until_disturbed,
		_test_avalanche_rests_at_repose_not_stability,
		_test_surface_sampled_between_cells,
		_test_ceiling_keeps_material_out_from_under_a_body,
		_test_bearing_capacity_sinks_heavier_loads_deeper,
		_test_load_settles_to_its_bearing_depth,
		_test_denser_material_sinks_less,
		_test_imprint_displaces_into_a_rim,
		_test_imprint_ignores_material_below_the_footprint,
		_test_imprint_heave_starts_outside_the_footprint,
		_test_spill_edge_conserves_volume_to_another_patch,
		_test_spill_edge_prefers_the_lip,
		_test_anchor_round_trips_world_and_patch_metres,
		_test_anchor_up_is_radial_on_a_planetoid,
		_test_anchor_coverage_needs_room_for_the_spoil_ring,
		_test_dig_spoil_conserves_the_removed_volume,
		_test_dig_spoil_lands_around_the_cut_not_in_it,
		_test_dig_spoil_off_grid_is_reported_as_undelivered,
		_test_empty_cells_are_holes_when_the_patch_lies_on_terrain,
		_test_dropped_spoil_builds_a_heap_not_a_sheet,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


func _new_patch() -> GranularPatch:
	return GranularPatch.create(GRID, GRID, CELL, REPOSE_DEG)


func _center() -> int:
	return GRID / 2


func _test_volume_conserved() -> bool:
	var patch := _new_patch()
	var poured := 0.0
	poured += patch.deposit(_center(), _center(), 0.25)
	poured += patch.deposit(_center() + 3, _center() - 2, 0.1)
	if absf(patch.total_volume_m3() - poured) > 1e-4:
		return _fail("deposit lost volume: %f vs %f" % [patch.total_volume_m3(), poured])
	patch.relax(RELAX_CAP)
	var after := patch.total_volume_m3()
	if absf(after - poured) > 1e-4:
		return _fail("relax changed volume: %f -> %f" % [poured, after])
	return true


func _test_repose_angle() -> bool:
	var patch := _new_patch()
	# Enough volume for a flank several cells long: an eight-neighbour pile is
	# a real cone rather than an L1 pyramid, so it spreads wider and sits
	# lower than the same load did on a four-neighbour stencil.
	patch.deposit(_center(), _center(), 0.6)
	var iterations := patch.relax(RELAX_CAP)
	if iterations >= RELAX_CAP:
		return _fail("pile did not settle within %d iterations" % RELAX_CAP)
	var expected := tan(deg_to_rad(REPOSE_DEG))
	var max_step := expected * CELL
	var crest := patch.thickness_at(_center(), _center())
	if crest < max_step * 3.0:
		return _fail("crest too flat to measure a flank: %f m" % crest)
	# A settled pile rests *at* the repose angle: every flank step must be no
	# steeper than one repose step, and the steps near the crest must actually
	# reach it rather than slumping flatter.
	var upper_step := 0.0
	for k in range(1, GRID - _center() - 1):
		var here := patch.thickness_at(_center() + k, _center())
		if here <= 0.02:
			break
		var step := here - patch.thickness_at(_center() + k + 1, _center())
		if step > max_step * 1.01:
			return _fail(
				"flank steeper than repose at cell %d: step %f > %f"
				% [k, step, max_step]
			)
		if k == 1:
			upper_step = step
	if upper_step < max_step * 0.9:
		return _fail(
			"flank slumped below repose: step %f, expected ~%f"
			% [upper_step, max_step]
		)
	print(
		"%s: repose %.1f deg measured (target %.1f), crest %.2f m, %d iterations"
		% [
			LABEL,
			rad_to_deg(atan(upper_step / CELL)),
			REPOSE_DEG,
			crest,
			iterations,
		]
	)
	return true


## A four-neighbour stencil limits the slope along the axes only, so the
## diagonal flank runs ~30% short and the pile is a visible diamond.
func _test_pile_is_not_a_diamond() -> bool:
	var patch := _new_patch()
	patch.deposit(_center(), _center(), 0.4)
	patch.relax(RELAX_CAP)
	var axis_reach := 0.0
	for k in range(1, GRID - _center() - 1):
		if patch.thickness_at(_center() + k, _center()) <= 0.02:
			break
		axis_reach = float(k) * CELL
	var diagonal_reach := 0.0
	for k in range(1, GRID - _center() - 1):
		if patch.thickness_at(_center() + k, _center() + k) <= 0.02:
			break
		diagonal_reach = float(k) * CELL * sqrt(2.0)
	if axis_reach <= 0.0 or diagonal_reach <= 0.0:
		return _fail("pile too small to measure: %f / %f" % [axis_reach, diagonal_reach])
	var ratio := diagonal_reach / axis_reach
	if absf(ratio - 1.0) > 0.2:
		return _fail(
			"pile is anisotropic: diagonal/axis reach %f (%f m vs %f m)"
			% [ratio, diagonal_reach, axis_reach]
		)
	return true


## Flow rate must come from gravity, not from the frame rate: the same
## collapse on the Moon takes sqrt(9.81 / 1.62) ~ 2.46x longer.
func _test_settling_is_slower_under_lunar_gravity() -> bool:
	var lunar := _settle_seconds(1.62)
	var earth := _settle_seconds(9.81)
	if lunar <= 0.0 or earth <= 0.0:
		return _fail("pile settled instantly: %f / %f" % [lunar, earth])
	var ratio := lunar / earth
	var expected := sqrt(9.81 / 1.62)
	if absf(ratio - expected) > expected * 0.2:
		return _fail(
			"lunar settling %f x earth, expected ~%f" % [ratio, expected]
		)
	return true


func _settle_seconds(gravity: float) -> float:
	var patch := _new_patch()
	patch.deposit(_center(), _center(), 0.4)
	var step := 1.0 / 60.0
	var elapsed := 0.0
	for _frame in 4000:
		patch.advance(step, gravity)
		elapsed += step
		if patch.is_settled():
			return elapsed
	return 0.0


func _test_steep_base_slides() -> bool:
	var patch := _new_patch()
	# 45 deg base, descending along +x — steeper than the repose angle, so
	# nothing may stay where it was dropped.
	for z in GRID:
		for x in GRID:
			patch.set_base_height(x, z, -float(x) * CELL)
	patch.deposit(_center(), _center(), 0.25)
	patch.relax(RELAX_CAP)
	if patch.thickness_at(_center(), _center()) > 0.01:
		return _fail(
			"material stayed on a 45 deg slope: %f m"
			% patch.thickness_at(_center(), _center())
		)
	var low_edge := 0.0
	for z in GRID:
		low_edge += patch.thickness_at(GRID - 1, z)
	if low_edge * patch.cell_area_m2() < 0.1:
		return _fail("material did not reach the low edge: %f m3" % low_edge)
	return true


func _test_blocked_cells_are_walls() -> bool:
	var patch := _new_patch()
	var wall_x := _center()
	for z in GRID:
		patch.set_blocked(wall_x, z, true)
	patch.deposit(wall_x - 4, _center(), 0.25)
	patch.relax(RELAX_CAP)
	if patch.thickness_at(wall_x, _center()) != 0.0:
		return _fail("material entered a blocked cell")
	for z in GRID:
		for x in range(wall_x + 1, GRID):
			if patch.thickness_at(x, z) > 0.0:
				return _fail("material crossed the wall at %d,%d" % [x, z])
	if absf(patch.total_volume_m3() - 0.25) > 1e-4:
		return _fail("wall leaked volume: %f" % patch.total_volume_m3())
	return true


func _test_height_map_holes() -> bool:
	var patch := _new_patch()
	patch.set_blocked(2, 3, true)
	patch.deposit(5, 5, 0.05)
	var data := patch.height_map_data()
	if data.size() != GRID * GRID:
		return _fail("height map size %d" % data.size())
	if not is_nan(data[patch.index(2, 3)]):
		return _fail("blocked cell must be NAN for HeightMapShape3D")
	if is_nan(data[patch.index(5, 5)]):
		return _fail("open cell must not be NAN")
	if not is_nan(patch.surface_height(2, 3)):
		return _fail("surface_height must be NAN on blocked cells")
	return true


func _test_deterministic() -> bool:
	var a := _new_patch()
	var b := _new_patch()
	for patch: GranularPatch in [a, b]:
		patch.deposit(_center(), _center(), 0.2)
		patch.deposit(_center() + 2, _center() + 1, 0.15)
		patch.set_blocked(_center() - 3, _center(), true)
		patch.relax(RELAX_CAP)
		patch.take(_center(), _center(), 2, 0.05)
		patch.relax(RELAX_CAP)
	if a.thickness_data() != b.thickness_data():
		return _fail("identical command sequences diverged")
	return true


func _test_take_never_exceeds_available() -> bool:
	var patch := _new_patch()
	patch.deposit(_center(), _center(), 0.2)
	patch.relax(RELAX_CAP)
	var partial := patch.take(_center(), _center(), 3, 0.05)
	if absf(partial - 0.05) > 1e-4:
		return _fail("partial take removed %f instead of 0.05" % partial)
	var rest := patch.take(_center(), _center(), GRID, 10.0)
	if rest > 0.15 + 1e-4:
		return _fail("take returned more than the patch held: %f" % rest)
	if patch.total_volume_m3() > 1e-4:
		return _fail("patch not empty after a full scoop: %f" % patch.total_volume_m3())
	return true


## Granular material is hysteretic: an undisturbed slope stands steeper than
## the angle it comes to rest at, and lets go all at once when disturbed.
## Without that, a slope can never sit metastable and a cave-in cannot be an
## event — it would just be continuous slumping.
func _test_metastable_slope_holds_until_disturbed() -> bool:
	var patch := GranularPatch.create(GRID, GRID, CELL, REPOSE_DEG, 6.0)
	# A bed lying on a base tilted between the two angles: steeper than
	# repose (33), gentler than stability (39).
	var slope := tan(deg_to_rad(36.0)) * CELL
	for z in GRID:
		for x in GRID:
			patch.set_base_height(x, z, -float(x) * slope)
			patch.deposit(x, z, 0.15 * patch.cell_area_m2())
	patch.relax(RELAX_CAP)
	var resting := patch.thickness_data()
	var held := patch.thickness_at(_center(), _center())
	if held < 0.14:
		return _fail("metastable slope let go on its own: %f m left" % held)
	# Control: left alone it keeps standing however long it is relaxed.
	patch.relax(RELAX_CAP)
	var undisturbed := _transported(resting, patch.thickness_data())
	if undisturbed > 1e-3:
		return _fail("undisturbed slope crept: %f m moved" % undisturbed)
	patch.mobilize(float(_center()) * CELL, float(_center()) * CELL, 1.5)
	patch.relax(RELAX_CAP)
	var slid := _transported(resting, patch.thickness_data())
	if slid < 0.05:
		return _fail("disturbed slope barely moved: %f m" % slid)
	# Material flows *through* the middle of a uniform slide at a steady rate,
	# so its thickness barely changes there. The signature is the scarp at the
	# head of the disturbed zone and the accumulation below its toe.
	var scarp := patch.thickness_at(_center() - 5, _center())
	var toe := patch.thickness_at(_center() + 5, _center())
	if scarp >= held:
		return _fail("no scarp at the head of the slide: %f m" % scarp)
	if toe <= held:
		return _fail("nothing piled up below the slide: %f m" % toe)
	return true


## Total thickness that changed hands between two states, in metres.
func _transported(before: PackedFloat32Array, after: PackedFloat32Array) -> float:
	var sum := 0.0
	for i in before.size():
		sum += absf(after[i] - before[i])
	return sum * 0.5


## Once moving, material must run out to the repose angle rather than
## stopping at the steeper angle that first let it go.
func _test_avalanche_rests_at_repose_not_stability() -> bool:
	var patch := GranularPatch.create(GRID, GRID, CELL, REPOSE_DEG, 6.0)
	patch.deposit(_center(), _center(), 0.6)
	patch.relax(RELAX_CAP)
	if patch.flowing_volume_m3() > 1e-3:
		return _fail(
			"material still sliding after settling: %f m3"
			% patch.flowing_volume_m3()
		)
	var step := (
		patch.thickness_at(_center() + 1, _center())
		- patch.thickness_at(_center() + 2, _center())
	)
	var repose_step := tan(deg_to_rad(REPOSE_DEG)) * CELL
	var stability_step := tan(deg_to_rad(REPOSE_DEG + 6.0)) * CELL
	if step > (repose_step + stability_step) * 0.5:
		return _fail(
			"pile rested at the stability angle (%f), not repose (%f): %f"
			% [stability_step, repose_step, step]
		)
	if step < repose_step * 0.85:
		return _fail(
			"pile rested flatter than repose: %f vs %f" % [step, repose_step]
		)
	return true


## Anything standing on the material rests between cell centres, so the
## sampled height has to interpolate rather than snap to a cell.
func _test_surface_sampled_between_cells() -> bool:
	var patch := _new_patch()
	patch.deposit(4, 4, 0.4 * patch.cell_area_m2())
	patch.deposit(5, 4, 0.8 * patch.cell_area_m2())
	var midpoint := patch.surface_height_at_m(4.5 * CELL, 4.0 * CELL)
	if absf(midpoint - 0.6) > 1e-4:
		return _fail("midpoint height %f, expected 0.6" % midpoint)
	if absf(patch.surface_height_at_m(4.0 * CELL, 4.0 * CELL) - 0.4) > 1e-4:
		return _fail("sample on a cell centre must equal that cell")
	if not is_nan(patch.surface_height_at_m(-1.0, 0.0)):
		return _fail("sample outside the patch must be NAN")
	patch.set_blocked(5, 4, true)
	if not is_nan(patch.surface_height_at_m(4.5 * CELL, 4.0 * CELL)):
		return _fail("sample touching rock must be NAN")
	return true


## A body occupies its column, so spoil may not slump back underneath it.
## Without the lid a body sitting in the material re-displaces the same spoil
## every tick and ratchets itself under.
func _test_ceiling_keeps_material_out_from_under_a_body() -> bool:
	var patch := _new_patch()
	# A pile next to a cell that a body is standing in, at ground level.
	patch.deposit(_center() - 1, _center(), 1.0)
	patch.set_ceiling(_center(), _center(), 0.0)
	patch.relax(RELAX_CAP)
	var under_body := patch.thickness_at(_center(), _center())
	if under_body > 1e-4:
		return _fail("material flowed under the body: %f m" % under_body)
	if absf(patch.total_volume_m3() - 1.0) > 1e-4:
		return _fail("the lid ate volume: %f m3" % patch.total_volume_m3())
	# Lift the body and the pile is free to spread again.
	patch.clear_ceilings()
	patch.relax(RELAX_CAP)
	if patch.thickness_at(_center(), _center()) <= 1e-4:
		return _fail("material did not return once the body left")
	return true


## Loose material carries a limited pressure: light loads rest on the surface,
## heavier ones settle in until the material around them carries the rest.
func _test_bearing_capacity_sinks_heavier_loads_deeper() -> bool:
	var patch := _new_patch()
	if patch.penetration_depth_m(patch.bearing_base_pa * 0.5) != 0.0:
		return _fail("a load below bearing capacity must not sink")
	var light := patch.penetration_depth_m(patch.bearing_base_pa + 1000.0)
	var heavy := patch.penetration_depth_m(patch.bearing_base_pa + 4000.0)
	if light <= 0.0:
		return _fail("a load over capacity must sink: %f m" % light)
	if heavy <= light * 3.5:
		return _fail(
			"four times the excess load must sink about four times as deep:"
			+ " %f vs %f m" % [heavy, light]
		)
	return true


## Drive the whole bedding-in loop the way a body does, with no physics
## engine involved: a heavy load must reach the depth its pressure allows and
## a light one must stay on the surface.
func _settle_depth(pressure_pa: float) -> float:
	var patch := _new_patch()
	var middle := float(_center()) * CELL
	for z in GRID:
		for x in GRID:
			patch.deposit(x, z, 0.7 * patch.cell_area_m2())
	patch.relax(RELAX_CAP)
	var bottom := patch.surface_height_at_m(middle, middle)
	for _tick in 400:
		patch.clear_ceilings()
		bottom = patch.settle_load(
			middle, middle, 0.3, bottom, pressure_pa, 1.0 / 60.0
		)
		patch.relax(2)
	return patch.ground_level_around(middle, middle, 0.3) - bottom


func _test_load_settles_to_its_bearing_depth() -> bool:
	var reference := _new_patch()
	var heavy_pressure := 2250.0
	var expected := reference.penetration_depth_m(heavy_pressure)
	# Spectacle band: readable decimetres, not Apollo cm and not a shaft.
	if expected < 0.08 or expected > 0.25:
		return _fail(
			"heavy-load target depth out of game band: %f m" % expected
		)
	var heavy := _settle_depth(heavy_pressure)
	if absf(heavy - expected) > expected * 0.25:
		return _fail(
			"heavy load bedded in %f m, expected ~%f" % [heavy, expected]
		)
	var light := _settle_depth(reference.bearing_base_pa * 0.5)
	if light > 0.02:
		return _fail("load under bearing capacity sank %f m" % light)
	return true


func _test_denser_material_sinks_less() -> bool:
	var soft := _new_patch()
	soft.density_scale = 0.55
	var firm := _new_patch()
	firm.density_scale = 2.5
	var pressure := 2250.0
	var soft_z := soft.penetration_depth_m(pressure)
	var firm_z := firm.penetration_depth_m(pressure)
	if soft_z <= firm_z * 1.5:
		return _fail(
			"denser spoil must carry more: soft %f vs firm %f" % [soft_z, firm_z]
		)
	return true


## A body pressed into the material must displace it, not delete it: the rut
## it leaves has to show up as a raised rim around the footprint.
func _test_imprint_displaces_into_a_rim() -> bool:
	var patch := _new_patch()
	var middle := float(_center()) * CELL
	# A flat 20 cm bed over the middle of the patch.
	for z in range(_center() - 5, _center() + 6):
		for x in range(_center() - 5, _center() + 6):
			patch.deposit(x, z, 0.2 * patch.cell_area_m2())
	var before := patch.total_volume_m3()
	var displaced := patch.imprint_disc(middle, middle, 0.5, 0.05)
	if displaced <= 0.0:
		return _fail("imprint displaced nothing")
	if absf(patch.total_volume_m3() - before) > 1e-4:
		return _fail(
			"imprint changed total volume: %f -> %f"
			% [before, patch.total_volume_m3()]
		)
	if patch.thickness_at(_center(), _center()) > 0.051:
		return _fail(
			"footprint not pressed down: %f m"
			% patch.thickness_at(_center(), _center())
		)
	var rim := patch.thickness_at(_center() + 3, _center())
	if rim <= 0.2:
		return _fail("no rim raised outside the footprint: %f m" % rim)
	return true


## Pressing above the surface must not scoop anything out from under it.
func _test_imprint_ignores_material_below_the_footprint() -> bool:
	var patch := _new_patch()
	var middle := float(_center()) * CELL
	for z in range(_center() - 4, _center() + 5):
		for x in range(_center() - 4, _center() + 5):
			patch.deposit(x, z, 0.1 * patch.cell_area_m2())
	var before := patch.thickness_data()
	if patch.imprint_disc(middle, middle, 0.5, 0.5) != 0.0:
		return _fail("imprint above the surface still cut material")
	if patch.thickness_data() != before:
		return _fail("imprint above the surface changed the field")
	return true


## Spoil must not land on the first cell outside the cut — that is where a
## square load's corners rest, and perching there stops bedding in.
func _test_imprint_heave_starts_outside_the_footprint() -> bool:
	var patch := _new_patch()
	var middle := float(_center()) * CELL
	for z in range(_center() - 6, _center() + 7):
		for x in range(_center() - 6, _center() + 7):
			patch.deposit(x, z, 0.2 * patch.cell_area_m2())
	# Playground cut radius (circumscribed + half cell): cut reaches cell +2,
	# one-cell heave gap leaves cell +3 clean, berm lands on cell +4.
	var radius_m := 0.6 * 0.7071 + CELL * 0.5
	patch.imprint_disc(middle, middle, radius_m, 0.05)
	if patch.thickness_at(_center() + 2, _center()) > 0.06:
		return _fail(
			"support cut too shallow: %f m"
			% patch.thickness_at(_center() + 2, _center())
		)
	var gap_cell := _center() + 3
	if patch.thickness_at(gap_cell, _center()) > 0.22:
		return _fail(
			"heave landed in the gap cell: %f m"
			% patch.thickness_at(gap_cell, _center())
		)
	var berm_cell := _center() + 4
	if patch.thickness_at(berm_cell, _center()) <= 0.2:
		return _fail(
			"no heave outside the gap: %f m"
			% patch.thickness_at(berm_cell, _center())
		)
	return true


## Spill removes volume from the source and the caller can deposit it on a
## catch patch — total mass across both is conserved.
func _test_spill_edge_conserves_volume_to_another_patch() -> bool:
	var shelf := GranularPatch.create(8, 8, CELL, REPOSE_DEG)
	var floor := GranularPatch.create(8, 8, CELL, REPOSE_DEG)
	# Load the lip so there is something to drain.
	for z in 8:
		shelf.deposit(7, z, 0.15 * shelf.cell_area_m2())
	var before := shelf.total_volume_m3() + floor.total_volume_m3()
	var spilled := 0.0
	for _tick in 40:
		var events := shelf.spill_edge(0.05)
		for event: Dictionary in events:
			var volume: float = event["volume_m3"]
			spilled += volume
			floor.deposit(0, clampi(int(event["z_m"] / CELL), 0, 7), volume)
	var after := shelf.total_volume_m3() + floor.total_volume_m3()
	if absf(after - before) > 1e-4:
		return _fail("spill changed total volume: %f -> %f" % [before, after])
	if spilled <= 0.02:
		return _fail("spill moved almost nothing: %f m3" % spilled)
	if floor.total_volume_m3() + 1e-4 < spilled:
		return _fail("catch patch missing spilled volume")
	return true


## Interior cells must not spill — only the open lip.
func _test_spill_edge_prefers_the_lip() -> bool:
	var patch := _new_patch()
	patch.deposit(_center(), _center(), 0.4)
	patch.relax(RELAX_CAP)
	var before_center := patch.thickness_at(_center(), _center())
	var events := patch.spill_edge(1.0)
	for event: Dictionary in events:
		var x := int(round(float(event["x_m"]) / CELL))
		var z := int(round(float(event["z_m"]) / CELL))
		if x > 0 and z > 0 and x < GRID - 1 and z < GRID - 1:
			return _fail("spill event from interior cell %d,%d" % [x, z])
	if patch.thickness_at(_center(), _center()) < before_center - 0.02:
		return _fail("spill ate the interior crest")
	return true


## A patch is a tangent plane somewhere on a sphere, so every gameplay
## coordinate crosses the anchor twice. It has to come back unchanged.
func _test_anchor_round_trips_world_and_patch_metres() -> bool:
	var center := Vector3(120.0, -3400.0, 87.0)
	var anchor := GranularAnchor.create(center, center.normalized(), GRID, GRID, CELL)
	for point: Vector3 in [
		anchor.to_world(0.0, 0.0, 0.0),
		anchor.to_world(1.75, 4.25, 0.6),
		anchor.to_world(float(GRID - 1) * CELL, 0.5, -0.3),
	]:
		var local := anchor.to_patch(point)
		var back := anchor.to_world(local.x, local.z, local.y)
		if back.distance_to(point) > 1e-3:
			return _fail("anchor round trip drifted %f m" % back.distance_to(point))
	return true


## Local up follows the radial, not global Y — otherwise material on the far
## side of the moon slides sideways off its own patch.
func _test_anchor_up_is_radial_on_a_planetoid() -> bool:
	var center := Vector3(0.0, -9500.0, 0.0)
	var up := center.normalized()
	var anchor := GranularAnchor.create(center, up, GRID, GRID, CELL)
	if anchor.up().dot(up) < 0.9999:
		return _fail("anchor up is not the radial: %s" % str(anchor.up()))
	if anchor.up().dot(Vector3.UP) > -0.9999:
		return _fail("anchor up should point away from the centre, at the pole")
	# The tangent axes must actually be tangent, or heights leak into the plane.
	if absf(anchor.basis.x.dot(up)) > 1e-5 or absf(anchor.basis.z.dot(up)) > 1e-5:
		return _fail("anchor tangent axes are not perpendicular to up")
	var above := anchor.to_world(1.0, 1.0, 0.75)
	if absf(anchor.height_above_plane(above) - 0.75) > 1e-4:
		return _fail("height above the tangent plane does not survive the trip")
	return true


func _test_anchor_coverage_needs_room_for_the_spoil_ring() -> bool:
	var anchor := GranularAnchor.create(Vector3.ZERO, Vector3.UP, GRID, GRID, CELL)
	var span := float(GRID - 1) * CELL
	if not anchor.covers(anchor.to_world(span * 0.5, span * 0.5, 0.0), 1.0):
		return _fail("the centre of a patch must be covered")
	if anchor.covers(anchor.to_world(0.1, span * 0.5, 0.0), 1.0):
		return _fail("a cut on the lip must not claim a patch that cannot hold it")
	# Coverage is about the grid only. A cut directly above or below the patch
	# still projects onto it, and it is `height_above_plane` that tells the two
	# apart — a shaft floor is not the surface it was sunk from.
	var overhead := anchor.to_world(span * 0.5, span * 0.5, 40.0)
	if not anchor.covers(overhead, 1.0):
		return _fail("a point straight above the patch should project onto it")
	if absf(anchor.height_above_plane(overhead) - 40.0) > 1e-3:
		return _fail("height above the plane did not separate the two levels")
	return true


## The whole point of the layer: rock the SDF loses reappears as loose material.
func _test_dig_spoil_conserves_the_removed_volume() -> bool:
	var patch := _new_patch()
	var removed := 0.18
	var spoil := GranularSpoil.spoil_volume_m3(removed)
	var accepted := GranularSpoil.deposit_ring(
		patch, float(_center()) * CELL, float(_center()) * CELL, 0.35, spoil
	)
	if absf(accepted - spoil) > 1e-5:
		return _fail("spoil ring accepted %f of %f m3" % [accepted, spoil])
	if absf(patch.total_volume_m3() - spoil) > 1e-4:
		return _fail("patch holds %f, dig produced %f" % [patch.total_volume_m3(), spoil])
	patch.relax(RELAX_CAP)
	if absf(patch.total_volume_m3() - spoil) > 1e-4:
		return _fail("settling lost the spoil")
	return true


## Cuttings heap around the mouth. Dropped into the bore they would just fall
## back down it, and the hole would refill itself as fast as it was dug.
func _test_dig_spoil_lands_around_the_cut_not_in_it() -> bool:
	var patch := _new_patch()
	var cut_radius := 0.5
	var center_m := float(_center()) * CELL
	GranularSpoil.deposit_ring(patch, center_m, center_m, cut_radius, 0.2)
	if patch.thickness_at(_center(), _center()) > 1e-6:
		return _fail("spoil landed in the cut itself")
	var ring_cell := _center() + int(round(cut_radius / CELL))
	if patch.thickness_at(ring_cell, _center()) <= 1e-6:
		return _fail("nothing landed on the rim of the cut")
	if patch.is_settled():
		return _fail("fresh cuttings must be mobilised, not laid at rest")
	return true


## Spoil that does not fit is volume the caller still owes. Reporting it as
## delivered is exactly the silent loss this layer replaced.
func _test_dig_spoil_off_grid_is_reported_as_undelivered() -> bool:
	var patch := _new_patch()
	var accepted := GranularSpoil.deposit_ring(
		patch, -20.0, -20.0, 0.3, 0.2
	)
	if accepted != 0.0:
		return _fail("a cut off the grid reported %f m3 delivered" % accepted)
	if patch.total_volume_m3() > 1e-9:
		return _fail("a cut off the grid still put material on the patch")
	return true


## A patch laid over existing terrain is a second surface on top of a first
## one. Where it holds no material it must be absent, not flat — a flat empty
## cell shadows the rock underneath, and that is what put a translucent sheet
## over the whole dig site and a vertical curtain down every slope.
func _test_empty_cells_are_holes_when_the_patch_lies_on_terrain() -> bool:
	var patch := _new_patch()
	patch.min_presence_m = 0.02
	# Ground that falls away steeply, the shape that produced the curtains.
	for z in GRID:
		for x in GRID:
			patch.set_base_height(x, z, -float(x) * 0.5)
	if patch.has_presence(_center(), _center()):
		return _fail("an empty cell claims to be a surface")
	var empty_map := patch.height_map_data()
	for i in empty_map.size():
		if not is_nan(empty_map[i]):
			return _fail("an empty patch still produced a collider surface")
	patch.deposit(_center(), _center(), 0.3 * patch.cell_area_m2())
	if not patch.has_presence(_center(), _center()):
		return _fail("a cell holding real material is not a surface")
	# The default stays as the demos rely on it: a patch that *is* the ground
	# collides everywhere, empty or not.
	var owns_ground := _new_patch()
	owns_ground.set_base_height(0, 0, 1.0)
	if is_nan(owns_ground.height_map_data()[0]):
		return _fail("a patch that owns its ground lost its empty cells")
	return true


## Repeated drops on one spot must grow a cone standing well above its own
## skirt, not creep outward as a flat sheet. This is the difference between
## loose material and a decal: a sheet is already at rest when it lands, so no
## amount of settling can turn it back into a pile.
func _test_dropped_spoil_builds_a_heap_not_a_sheet() -> bool:
	var patch := _new_patch()
	var center_m := float(_center()) * CELL
	var poured := 0.0
	for _drop in 24:
		poured += GranularSpoil.deposit_heap(patch, center_m, center_m, 0.05)
		patch.advance(0.1, 1.62)
	if absf(patch.total_volume_m3() - poured) > 1e-4:
		return _fail(
			"heap lost volume: %f vs %f" % [patch.total_volume_m3(), poured]
		)
	patch.relax(RELAX_CAP)
	var crest := patch.thickness_at(_center(), _center())
	if crest <= 0.15:
		return _fail("heap never rose: crest %.3f m" % crest)
	# A cone, not a plate: two metres out it must have thinned right down.
	var skirt := patch.thickness_at(_center() + int(2.0 / CELL), _center())
	if skirt >= crest * 0.5:
		return _fail(
			"spoil spread as a sheet: crest %.3f m, skirt %.3f m" % [crest, skirt]
		)
	return true


func _fail(message: String) -> bool:
	push_error(message)
	print("%s: FAIL - %s" % [LABEL, message])
	get_tree().quit(1)
	return false
