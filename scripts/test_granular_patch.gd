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
		_test_imprint_displaces_into_a_rim,
		_test_imprint_ignores_material_below_the_footprint,
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


func _fail(message: String) -> bool:
	push_error(message)
	print("%s: FAIL - %s" % [LABEL, message])
	get_tree().quit(1)
	return false
