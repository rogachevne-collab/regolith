class_name RecipeCatalog
extends RefCounted

const EPSILON := 0.000001

const MACHINE_PROCESSOR := "processor"
const MACHINE_FABRICATOR := "fabricator"

const RECIPES: Dictionary = {
	"crush_regolith": {
		"machine": MACHINE_PROCESSOR,
		"inputs": {"raw_regolith": 1.0},
		"outputs": {"regolith_fines": 1.0},
		"duration_s": 6.0,
		"power_w": 200.0,
	},
	"sinter_basalt": {
		"machine": MACHINE_PROCESSOR,
		"inputs": {"regolith_fines": 2.0},
		"outputs": {"sintered_basalt": 1.0},
		"duration_s": 8.0,
		"power_w": 250.0,
	},
	"calcine_fines": {
		"machine": MACHINE_PROCESSOR,
		"inputs": {"regolith_fines": 2.0},
		"outputs": {"calcined_oxide": 1.0},
		"duration_s": 10.0,
		"power_w": 400.0,
	},
	"reduce_oxide": {
		"machine": MACHINE_FABRICATOR,
		"inputs": {"calcined_oxide": 1.0},
		"outputs": {"metal_ingot": 1.0},
		"duration_s": 12.0,
		"power_w": 600.0,
	},
	"sinter_component": {
		"machine": MACHINE_FABRICATOR,
		"inputs": {"metal_ingot": 1.0},
		"outputs": {"construction_component": 1.0},
		"duration_s": 10.0,
		"power_w": 500.0,
	},
}


static func has_recipe(recipe_id: String) -> bool:
	return RECIPES.has(recipe_id)


static func recipe_ids_for_machine(for_machine_id: String) -> PackedStringArray:
	var result := PackedStringArray()
	for recipe_id: String in _sorted_recipe_ids():
		if machine_archetype_id(recipe_id) == for_machine_id:
			result.append(recipe_id)
	return result


static func get_recipe(recipe_id: String) -> Dictionary:
	var recipe: Variant = RECIPES.get(recipe_id, {})
	if recipe is Dictionary:
		return recipe
	return {}


static func machine_archetype_id(recipe_id: String) -> String:
	return str(get_recipe(recipe_id).get("machine", ""))


static func inputs(recipe_id: String) -> Dictionary:
	var recipe := get_recipe(recipe_id)
	var raw: Variant = recipe.get("inputs", {})
	return raw if raw is Dictionary else {}


static func outputs(recipe_id: String) -> Dictionary:
	var recipe := get_recipe(recipe_id)
	var raw: Variant = recipe.get("outputs", {})
	return raw if raw is Dictionary else {}


static func duration_s(recipe_id: String) -> float:
	return maxf(float(get_recipe(recipe_id).get("duration_s", 0.0)), 0.0)


static func power_w(recipe_id: String) -> float:
	return maxf(float(get_recipe(recipe_id).get("power_w", 0.0)), 0.0)


static func default_recipe_for_machine(for_machine_id: String) -> String:
	var defaults: Variant = IndustryArchetypeProfile.DEFAULT_RECIPES.get(
		for_machine_id,
		""
	)
	return str(defaults)


static func _sorted_recipe_ids() -> PackedStringArray:
	var ids: Array = RECIPES.keys()
	ids.sort()
	var result := PackedStringArray()
	for recipe_id: Variant in ids:
		result.append(str(recipe_id))
	return result


