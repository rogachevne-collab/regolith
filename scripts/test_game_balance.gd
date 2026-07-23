extends Node

## Kernel acceptance for docs/specs/GAME-BALANCE-V0.md.


func _ready() -> void:
	var errors := _run()
	if errors.is_empty():
		print("GAME-BALANCE-V0: PASS")
		get_tree().quit(0)
	else:
		for error: String in errors:
			push_error(error)
		print("GAME-BALANCE-V0: FAIL")
		get_tree().quit(1)


func _run() -> PackedStringArray:
	var errors := PackedStringArray()
	GameBalance.reload_for_tests()
	for error: String in GameBalance.validate():
		errors.append(error)

	var items := GameBalance.items()
	if not items.has("construction_component"):
		errors.append("missing construction_component item")
	if not is_equal_approx(
		float(items["construction_component"].get("mass_per_unit_kg", 0.0)),
		2.5
	):
		errors.append("construction_component mass drifted from v1 fixture")

	if not ResourceCatalog.has_resource("raw_regolith"):
		errors.append("ResourceCatalog does not see balance items")
	if not RecipeCatalog.has_recipe("crush_regolith"):
		errors.append("RecipeCatalog does not see balance recipes")
	if not is_equal_approx(IndustryArchetypeProfile.player_carry_capacity_l(), 100.0):
		errors.append("player carry capacity not loaded from balance")
	if not is_equal_approx(IndustryArchetypeProfile.drill_carve_radius_m(), 1.25):
		errors.append("stationary drill carve radius not loaded from balance")

	var piston := Slice01Archetypes.piston_base()
	if piston == null:
		errors.append("failed to load piston_base archetype")
		return errors
	if not is_equal_approx(piston.mass_kg, 40.0):
		errors.append("piston_base mass_kg not applied from balance")
	if piston.piston_definition == null:
		errors.append("piston_base missing piston_definition")
	elif not is_equal_approx(piston.piston_definition.force_limit_n, 30000.0):
		errors.append("piston force_limit_n not applied from balance")
	if piston.build_requirements.is_empty():
		errors.append("piston_base BOM empty after balance apply")
	elif not is_equal_approx(piston.build_requirements[0].amount, 4.0):
		errors.append("piston_base BOM amount not applied from balance")

	for archetype_id: String in Slice01Archetypes.REQUIRED_IDS:
		if not GameBalance.has_element(archetype_id):
			errors.append("balance missing required element '%s'" % archetype_id)

	for archetype_id: String in [
		"piston_base",
		"rotor_base",
		"hinge_base",
		"stationary_drill",
	]:
		if not GameBalance.has_element(archetype_id):
			errors.append("balance missing element '%s'" % archetype_id)

	var weld := SimulationElement.weld_repair_integrity_fraction()
	if not is_equal_approx(weld, 0.25):
		errors.append("weld repair fraction not loaded from balance")
	var refund := GameBalance.construction_float("dismantle_refund_fraction", -1.0)
	if not is_equal_approx(refund, 0.5):
		errors.append("dismantle refund fraction missing from balance")

	return errors
