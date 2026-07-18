extends Node

## Headless acceptance for docs/specs/TERRAIN-MATERIALS-V1.md catalogs / yield / H₂ cycle.

const EPSILON := 0.000001
const _Catalog := preload(
	"res://scripts/simulation/runtime/terrain_material_catalog.gd"
)
const _Field := preload(
	"res://scripts/simulation/runtime/moon_material_field.gd"
)
const _Source := preload(
	"res://scripts/simulation/runtime/terrain_material_source.gd"
)


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var failed := 0
	failed += 0 if _test_catalog_indices_unique() else 1
	failed += 0 if _test_resource_catalog_has_ores_and_gases() else 1
	failed += 0 if _test_legacy_ids_removed() else 1
	failed += 0 if _test_mare_yield() else 1
	failed += 0 if _test_ilmenite_yield_mix() else 1
	failed += 0 if _test_hydrogen_cycle_net() else 1
	failed += 0 if _test_electrolyzer_recipe_machine() else 1
	if not _test_material_field_deterministic():
		failed += 1
	failed += 0 if _test_map_deposit_overlay() else 1
	if failed == 0:
		print("TERRAIN-MATERIALS: PASS")
		get_tree().quit(0)
	else:
		push_error("TERRAIN-MATERIALS: FAIL (%d)" % failed)
		get_tree().quit(1)


func _test_map_deposit_overlay() -> bool:
	var spawn := Vector3(MoonGeometry.SURFACE_RADIUS_M, 0.0, 0.0)
	var tex := MoonMapDepositOverlay.build_texture(spawn)
	if tex == null or tex.get_width() < 8 or tex.get_height() < 8:
		push_error("deposit overlay texture missing")
		return false
	var img := tex.get_image()
	if img == null:
		push_error("deposit overlay image missing")
		return false
	var lens_pixels := 0
	for y in mini(img.get_height(), 32):
		for x in mini(img.get_width(), 32):
			if img.get_pixel(x, y).a > 0.05:
				lens_pixels += 1
	if lens_pixels <= 0:
		push_error("deposit overlay has no lens pixels near sample window")
		return false
	var legend := MoonMapDepositOverlay.legend_rows()
	if legend.size() < 5:
		push_error("deposit legend incomplete")
		return false
	return true


func _test_catalog_indices_unique() -> bool:
	var seen: Dictionary = {}
	for material_id: String in _Catalog.material_ids():
		var idx := _Catalog.voxel_index_of(material_id)
		if seen.has(idx):
			push_error("duplicate voxel_index %d" % idx)
			return false
		seen[idx] = material_id
	return seen.size() >= 7


func _test_resource_catalog_has_ores_and_gases() -> bool:
	for item_id: String in [
		"ore_mare_regolith",
		"ore_ilmenite",
		"ore_ice",
		"water",
		"oxygen",
		"hydrogen",
		"plate_metal",
		"mechanism",
	]:
		if not ResourceCatalog.has_resource(item_id):
			push_error("missing item %s" % item_id)
			return false
	return true


func _test_legacy_ids_removed() -> bool:
	for item_id: String in [
		"raw_regolith",
		"calcined_oxide",
		"metal_ingot",
		"construction_component",
	]:
		if ResourceCatalog.has_resource(item_id):
			push_error("legacy item still present: %s" % item_id)
			return false
	for recipe_id: String in [
		"crush_regolith",
		"calcine_fines",
		"reduce_oxide",
		"sinter_component",
	]:
		if RecipeCatalog.has_recipe(recipe_id):
			push_error("legacy recipe still present: %s" % recipe_id)
			return false
	return true


func _test_mare_yield() -> bool:
	var source: TerrainMaterialSource = _Source.new()
	var yields := source.yield_for_excavation(
		1.0,
		{_Catalog.MAT_MARE_REGOLITH: 1.0}
	)
	var amounts := source.amounts_from_yields(yields)
	if not amounts.has("ore_mare_regolith"):
		push_error("mare yield missing ore_mare_regolith")
		return false
	var expected_mass := 1.0 * 1500.0 * 0.01
	var expected_amount := expected_mass / 2.0
	if absf(float(amounts["ore_mare_regolith"]) - expected_amount) > 0.0001:
		push_error(
			"mare amount %.6f != %.6f"
			% [float(amounts["ore_mare_regolith"]), expected_amount]
		)
		return false
	return true


func _test_ilmenite_yield_mix() -> bool:
	var source: TerrainMaterialSource = _Source.new()
	var yields := source.yield_for_excavation(
		1.0,
		{_Catalog.MAT_ILMENITE: 1.0}
	)
	var amounts := source.amounts_from_yields(yields)
	if not amounts.has("ore_ilmenite") or not amounts.has("ore_mare_regolith"):
		push_error("ilmenite mix incomplete: %s" % str(amounts))
		return false
	var dominant := source.dominant_resource_id(yields)
	if dominant != "ore_ilmenite":
		push_error("dominant should be ore_ilmenite, got %s" % dominant)
		return false
	return true


func _test_hydrogen_cycle_net() -> bool:
	## reduce: -1 H2 +1 water; electrolyze: -1 water +1 H2 +0.5 O2 → ΔH2=0, ΔO2>0
	var reduce_in := RecipeCatalog.inputs("reduce_ilmenite_h2")
	var reduce_out := RecipeCatalog.outputs("reduce_ilmenite_h2")
	var elec_in := RecipeCatalog.inputs("electrolyze_water")
	var elec_out := RecipeCatalog.outputs("electrolyze_water")
	if float(reduce_in.get("hydrogen", 0.0)) != 1.0:
		push_error("reduce should consume 1 hydrogen")
		return false
	if float(reduce_out.get("water", 0.0)) != 1.0:
		push_error("reduce should produce 1 water")
		return false
	if float(elec_in.get("water", 0.0)) != 1.0:
		push_error("electrolyze should consume 1 water")
		return false
	var dh2 := (
		float(elec_out.get("hydrogen", 0.0))
		- float(reduce_in.get("hydrogen", 0.0))
	)
	var do2 := float(elec_out.get("oxygen", 0.0))
	if absf(dh2) > EPSILON:
		push_error("Path B ΔH2 should be 0, got %.4f" % dh2)
		return false
	if do2 <= EPSILON:
		push_error("Path B ΔO2 should be > 0")
		return false
	if RecipeCatalog.machine_archetype_id("electrolyze_water") != "electrolyzer":
		push_error("electrolyze_water must target electrolyzer")
		return false
	return true


func _test_electrolyzer_recipe_machine() -> bool:
	if not IndustryArchetypeProfile.is_recipe_machine("electrolyzer"):
		push_error("electrolyzer not a recipe machine")
		return false
	if (
		IndustryArchetypeProfile.DEFAULT_RECIPES.get("electrolyzer", "")
		!= "electrolyze_water"
	):
		push_error("bad electrolyzer default recipe")
		return false
	return true


func _test_material_field_deterministic() -> bool:
	var field: MoonMaterialField = _Field.new()
	var spawn := Vector3(MoonGeometry.SURFACE_RADIUS_M, 0.0, 0.0)
	var a := field.material_id_at_world(spawn, spawn)
	var b := field.material_id_at_world(spawn, spawn)
	if a != b:
		push_error("field not deterministic")
		return false
	## Below surface near spawn should hit overlay band.
	var deep := spawn.normalized() * (MoonGeometry.SURFACE_RADIUS_M - 10.0)
	var deep_id := field.material_id_at_world(deep, spawn)
	if deep_id.is_empty():
		push_error("empty material id")
		return false
	return true
