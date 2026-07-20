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
		_test_steep_base_slides,
		_test_blocked_cells_are_walls,
		_test_height_map_holes,
		_test_deterministic,
		_test_take_never_exceeds_available,
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
	patch.deposit(_center(), _center(), 0.25)
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


func _fail(message: String) -> bool:
	push_error(message)
	print("%s: FAIL - %s" % [LABEL, message])
	get_tree().quit(1)
	return false
