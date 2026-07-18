class_name RecipeCatalog
extends RefCounted

## Recipe accessors. Authoritative values live in
## `res://resources/balance/game_balance.json` (Game Balance v0).

const EPSILON := 0.000001

const MACHINE_PROCESSOR := "processor"
const MACHINE_FABRICATOR := "fabricator"

## Compatibility alias for callers that still iterate `RecipeCatalog.RECIPES`.
static var RECIPES: Dictionary:
	get:
		return GameBalance.recipes()


static func has_recipe(recipe_id: String) -> bool:
	return GameBalance.recipes().has(recipe_id)


static func recipe_ids_for_machine(for_machine_id: String) -> PackedStringArray:
	var result := PackedStringArray()
	for recipe_id: String in _sorted_recipe_ids():
		if machine_archetype_id(recipe_id) == for_machine_id:
			result.append(recipe_id)
	return result


static func get_recipe(recipe_id: String) -> Dictionary:
	var recipe: Variant = GameBalance.recipes().get(recipe_id, {})
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
	var defaults: Variant = GameBalance.industry().get("default_recipes", {})
	if defaults is Dictionary:
		return str((defaults as Dictionary).get(for_machine_id, ""))
	return ""


static func _sorted_recipe_ids() -> PackedStringArray:
	var ids: Array = GameBalance.recipes().keys()
	ids.sort()
	var result := PackedStringArray()
	for recipe_id: Variant in ids:
		result.append(str(recipe_id))
	return result
