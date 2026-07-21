extends Node
## Volume bookkeeping for soft-material spoil and the hand scoop.
##
## These guard arithmetic only: that material neither multiplies nor vanishes
## without being counted. Whether an opened lens *reads* as flowing material is
## a question for the running game — see docs/specs/GRANULAR-V1.md.

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")

const LABEL := "GRANULAR-LENS-SCOOP"
const CELLS := 24
const CELL := 0.25
const EPS := 0.000001


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, LABEL)
	var tests: Array[Callable] = [
		_test_rock_spoil_fraction_is_unchanged,
		_test_lens_materials_leave_more_behind_than_rock,
		_test_every_material_declares_a_spoil_fraction,
		_test_deposit_reports_what_it_could_not_take,
		_test_scoop_budget_is_exact,
		_test_scoop_takes_everything_when_the_heap_is_small,
		_test_scoop_then_dump_conserves_volume,
		_test_zero_budget_takes_nothing,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


func _fail(message: String) -> bool:
	printerr("%s: FAIL %s" % [LABEL, message])
	get_tree().quit(1)
	return false


func _region() -> GranularVoxelRegion:
	# No terrain and no tool: nothing is solid until said so, so the arithmetic
	# is not entangled with rock sampling. A floor just under the centre cell is
	# still needed — a deposit walks down to the first support, and without one
	# every heap lands on the floor of the box instead of where it was aimed.
	var region := GranularVoxelRegion.create(
		Vector3(0.0, 0.0, 0.0), Vector3.UP, null, null, CELLS, CELL
	)
	var floor_y := CELLS / 2 - 1
	for x: int in CELLS:
		for z: int in CELLS:
			region.field.set_solid(x, floor_y, z, true)
	return region


func _test_rock_spoil_fraction_is_unchanged() -> bool:
	var rock := TerrainMaterialCatalog.spoil_fraction(
		TerrainMaterialCatalog.MAT_MARE_REGOLITH
	)
	if absf(rock - 0.35) > EPS:
		return _fail("plain regolith spoil fraction moved: %f" % rock)
	return true


func _test_lens_materials_leave_more_behind_than_rock() -> bool:
	var rock := TerrainMaterialCatalog.spoil_fraction(
		TerrainMaterialCatalog.MAT_MARE_REGOLITH
	)
	for material_id: String in [
		TerrainMaterialCatalog.MAT_ILMENITE,
		TerrainMaterialCatalog.MAT_ANORTHITE,
		TerrainMaterialCatalog.MAT_OLIVINE,
		TerrainMaterialCatalog.MAT_PYROXENE,
		TerrainMaterialCatalog.MAT_ICE_LENS,
	]:
		var lens := TerrainMaterialCatalog.spoil_fraction(material_id)
		if lens <= rock:
			return _fail(
				"%s leaves no more spoil than rock: %f" % [material_id, lens]
			)
	return true


func _test_every_material_declares_a_spoil_fraction() -> bool:
	for material_id: String in TerrainMaterialCatalog.material_ids():
		var fraction := TerrainMaterialCatalog.spoil_fraction(material_id)
		if fraction < 0.0 or fraction > 1.0:
			return _fail(
				"%s spoil fraction out of range: %f" % [material_id, fraction]
			)
	return true


func _test_deposit_reports_what_it_could_not_take() -> bool:
	var region := _region()
	# Far more than the box can hold, so the shortfall is certain.
	var asked := float(CELLS * CELLS * CELLS) * pow(CELL, 3.0) * 4.0
	var accepted := region.deposit_landing_at(Vector3.ZERO, asked, 2)
	if accepted > asked + EPS:
		return _fail("accepted more than asked: %f > %f" % [accepted, asked])
	if accepted >= asked - EPS:
		return _fail("an overfull region reported no shortfall")
	if absf(region.field.total_volume_m3() - accepted) > 0.0001:
		return _fail(
			"field holds %f but reported taking %f"
			% [region.field.total_volume_m3(), accepted]
		)
	return true


func _test_scoop_budget_is_exact() -> bool:
	var region := _region()
	var placed := region.deposit_landing_at(Vector3.ZERO, 2.0, 3)
	if placed <= 0.5:
		return _fail("fixture heap too small: %f" % placed)
	var budget := 0.15
	var taken := region.dig_at(Vector3.ZERO, 1.5, budget)
	if absf(taken - budget) > 0.0001:
		return _fail("budgeted dig took %f, wanted %f" % [taken, budget])
	if absf(region.field.total_volume_m3() - (placed - taken)) > 0.0001:
		return _fail("heap did not shrink by exactly what was taken")
	return true


func _test_scoop_takes_everything_when_the_heap_is_small() -> bool:
	var region := _region()
	var placed := region.deposit_landing_at(Vector3.ZERO, 0.02, 1)
	var taken := region.dig_at(Vector3.ZERO, 2.0, 10.0)
	if absf(taken - placed) > 0.0001:
		return _fail("took %f from a heap of %f" % [taken, placed])
	if region.field.total_volume_m3() > 0.0001:
		return _fail("material left behind after an unbounded dig")
	return true


func _test_scoop_then_dump_conserves_volume() -> bool:
	var source := _region()
	var placed := source.deposit_landing_at(Vector3.ZERO, 1.0, 3)
	var carried := source.dig_at(Vector3.ZERO, 1.0, 0.1)
	if carried <= 0.0:
		return _fail("scooped nothing from a heap of %f" % placed)
	var sink := _region()
	var delivered := sink.deposit_landing_at(Vector3.ZERO, carried, 2)
	var total := source.field.total_volume_m3() + sink.field.total_volume_m3()
	# Anything the sink refused is still in the scoop, so it counts too.
	var in_hand := carried - delivered
	if absf(total + in_hand - placed) > 0.0001:
		return _fail(
			"volume drifted: %f in fields + %f carried vs %f placed"
			% [total, in_hand, placed]
		)
	return true


func _test_zero_budget_takes_nothing() -> bool:
	var region := _region()
	var placed := region.deposit_landing_at(Vector3.ZERO, 0.5, 2)
	if region.dig_at(Vector3.ZERO, 1.0, 0.0) != 0.0:
		return _fail("a full scoop still took material")
	if absf(region.field.total_volume_m3() - placed) > 0.0001:
		return _fail("heap changed on a zero-budget dig")
	return true
