class_name GameBalance
extends RefCounted

## Authoritative Game Balance v0 loader.
## Single edit surface: `res://resources/balance/game_balance.json`.
## See `docs/specs/GAME-BALANCE-V0.md` and `docs/cheatsheets/game-balance.md`.

const PATH := "res://resources/balance/game_balance.json"
const EXPECTED_VERSION := 1

const _ACTUATOR_KEYS := [
	"piston",
	"rotor",
	"hinge",
	"wheel",
	"suspension",
	"thruster",
	"gyro",
]

static var _root: Dictionary = {}
static var _loaded := false
static var _applied_archetype_ids: Dictionary = {}


static func ensure_loaded() -> void:
	if _loaded:
		return
	if not FileAccess.file_exists(PATH):
		push_error("GameBalance missing: %s" % PATH)
		_root = {}
		_loaded = true
		return
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		push_error("GameBalance open failed: %s" % PATH)
		_root = {}
		_loaded = true
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("GameBalance JSON root must be an object: %s" % PATH)
		_root = {}
		_loaded = true
		return
	_root = parsed
	var version := int(_root.get("version", 0))
	if version != EXPECTED_VERSION:
		push_warning(
			"GameBalance version %d (expected %d) at %s"
			% [version, EXPECTED_VERSION, PATH]
		)
	_loaded = true


static func reload_for_tests() -> void:
	_loaded = false
	_root = {}
	_applied_archetype_ids.clear()
	ensure_loaded()


static func root() -> Dictionary:
	ensure_loaded()
	return _root


static func items() -> Dictionary:
	return _section("items")


static func recipes() -> Dictionary:
	return _section("recipes")


static func industry() -> Dictionary:
	return _section("industry")


static func electric() -> Dictionary:
	return _section("electric")


static func construction() -> Dictionary:
	return _section("construction")


static func starter() -> Dictionary:
	return _section("starter")


static func elements() -> Dictionary:
	return _section("elements")


## ParameterCatalog (CONTROL-ACTIONS-V0): статичная мета настраиваемых уставок —
## подпись, единица, шаг нуджа, точность, куда писать. Границы (min/max) НЕ здесь:
## они per-instance и берутся живыми из состояния элемента (authored-лимиты).
static func parameters() -> Dictionary:
	return _section("parameters")


static func parameter_entry(param_id: String) -> Dictionary:
	if param_id.is_empty():
		return {}
	var entry: Variant = parameters().get(param_id, {})
	return entry if entry is Dictionary else {}


static func parameter_step(param_id: String, fallback: float) -> float:
	var entry := parameter_entry(param_id)
	if entry.is_empty():
		return fallback
	return float(entry.get("step", fallback))


## Множитель отображения: внутренняя единица → показанная (Н → кН, рад → °).
static func parameter_display_scale(param_id: String) -> float:
	var entry := parameter_entry(param_id)
	if entry.is_empty():
		return 1.0
	return float(entry.get("display_scale", 1.0))


static func element_entry(archetype_id: String) -> Dictionary:
	if archetype_id.is_empty():
		return {}
	var entry: Variant = elements().get(archetype_id, {})
	return entry if entry is Dictionary else {}


static func has_element(archetype_id: String) -> bool:
	return elements().has(archetype_id)


static func industry_float(path: PackedStringArray, fallback: float) -> float:
	var cursor: Variant = industry()
	for key: String in path:
		if not cursor is Dictionary:
			return fallback
		cursor = (cursor as Dictionary).get(key, null)
	if cursor == null:
		return fallback
	return float(cursor)


static func industry_bool(path: PackedStringArray, fallback: bool) -> bool:
	var cursor: Variant = industry()
	for key: String in path:
		if not cursor is Dictionary:
			return fallback
		cursor = (cursor as Dictionary).get(key, null)
	if cursor == null:
		return fallback
	return bool(cursor)


static func industry_int(path: PackedStringArray, fallback: int) -> int:
	return int(industry_float(path, float(fallback)))


static func construction_float(key: String, fallback: float) -> float:
	return float(construction().get(key, fallback))


static func electric_defaults() -> Dictionary:
	var defaults: Variant = electric().get("defaults", {})
	return defaults if defaults is Dictionary else {}


static func electric_archetypes() -> Dictionary:
	var archetypes: Variant = electric().get("archetypes", {})
	return archetypes if archetypes is Dictionary else {}


static func apply_element(archetype: ElementArchetype) -> void:
	if archetype == null or archetype.archetype_id.is_empty():
		return
	ensure_loaded()
	var archetype_id := archetype.archetype_id
	if _applied_archetype_ids.get(archetype_id, false):
		return
	var entry := element_entry(archetype_id)
	if entry.is_empty():
		return
	if entry.has("mass_kg"):
		archetype.mass_kg = float(entry["mass_kg"])
	if entry.has("max_integrity"):
		archetype.max_integrity = float(entry["max_integrity"])
	if entry.has("build_requirements"):
		archetype.build_requirements = _build_requirements(
			entry["build_requirements"]
		)
	_apply_definition_overlay(archetype.piston_definition, entry.get("piston", {}))
	_apply_definition_overlay(archetype.rotor_definition, entry.get("rotor", {}))
	_apply_definition_overlay(archetype.hinge_definition, entry.get("hinge", {}))
	_apply_definition_overlay(archetype.wheel_definition, entry.get("wheel", {}))
	_apply_definition_overlay(
		archetype.suspension_definition,
		entry.get("suspension", {})
	)
	_apply_definition_overlay(
		archetype.thruster_definition,
		entry.get("thruster", {})
	)
	_apply_definition_overlay(archetype.gyro_definition, entry.get("gyro", {}))
	_apply_definition_overlay(archetype.battery_definition, entry.get("battery", {}))
	_apply_definition_overlay(
		archetype.power_source_definition,
		entry.get("power_source", {})
	)
	_applied_archetype_ids[archetype_id] = true


static func validate() -> PackedStringArray:
	ensure_loaded()
	var errors := PackedStringArray()
	if _root.is_empty():
		errors.append("balance root is empty")
		return errors
	if int(_root.get("version", 0)) != EXPECTED_VERSION:
		errors.append(
			"unsupported balance version %s" % str(_root.get("version", 0))
		)
	var item_ids := items()
	if item_ids.is_empty():
		errors.append("items section is empty")
	for item_id: Variant in item_ids.keys():
		var entry: Variant = item_ids[item_id]
		if not entry is Dictionary:
			errors.append("item '%s' must be an object" % str(item_id))
			continue
		var item: Dictionary = entry
		for key: String in [
			"category",
			"mass_per_unit_kg",
			"volume_per_unit_l",
			"unit",
		]:
			if not item.has(key):
				errors.append("item '%s' missing %s" % [str(item_id), key])
		if float(item.get("mass_per_unit_kg", 0.0)) <= 0.0:
			errors.append("item '%s' mass_per_unit_kg must be > 0" % str(item_id))
		if float(item.get("volume_per_unit_l", 0.0)) <= 0.0:
			errors.append(
				"item '%s' volume_per_unit_l must be > 0" % str(item_id)
			)
	for recipe_id: Variant in recipes().keys():
		var recipe_variant: Variant = recipes()[recipe_id]
		if not recipe_variant is Dictionary:
			errors.append("recipe '%s' must be an object" % str(recipe_id))
			continue
		var recipe: Dictionary = recipe_variant
		for bag_key: String in ["inputs", "outputs"]:
			var bag: Variant = recipe.get(bag_key, {})
			if not bag is Dictionary:
				errors.append(
					"recipe '%s'.%s must be an object" % [str(recipe_id), bag_key]
				)
				continue
			for resource_id: Variant in (bag as Dictionary).keys():
				if not item_ids.has(str(resource_id)):
					errors.append(
						"recipe '%s' references unknown item '%s'"
						% [str(recipe_id), str(resource_id)]
					)
	const PARAMETER_COMMANDS := [
		"configure_actuator",
		"configure_wheel",
		"configure_suspension",
	]
	for param_id: Variant in parameters().keys():
		var param_variant: Variant = parameters()[param_id]
		if not param_variant is Dictionary:
			errors.append("parameter '%s' must be an object" % str(param_id))
			continue
		var param: Dictionary = param_variant
		for key: String in ["label", "unit", "step", "command", "field", "target"]:
			if not param.has(key):
				errors.append("parameter '%s' missing %s" % [str(param_id), key])
		if float(param.get("step", 0.0)) <= 0.0:
			errors.append("parameter '%s' step must be > 0" % str(param_id))
		var command := str(param.get("command", ""))
		if not command.is_empty() and not command in PARAMETER_COMMANDS:
			errors.append(
				"parameter '%s' unknown command '%s'" % [str(param_id), command]
			)
		var target := str(param.get("target", ""))
		if not target.is_empty() and not target in ["joint", "element"]:
			errors.append(
				"parameter '%s' target must be joint|element" % str(param_id)
			)
	for archetype_id: Variant in elements().keys():
		var element_variant: Variant = elements()[archetype_id]
		if not element_variant is Dictionary:
			errors.append("element '%s' must be an object" % str(archetype_id))
			continue
		var element: Dictionary = element_variant
		if float(element.get("mass_kg", 0.0)) <= 0.0:
			errors.append("element '%s' mass_kg must be > 0" % str(archetype_id))
		var requirements: Variant = element.get("build_requirements", [])
		if requirements is Array:
			for requirement_variant: Variant in requirements:
				if not requirement_variant is Dictionary:
					continue
				var requirement: Dictionary = requirement_variant
				var resource_id := str(requirement.get("resource_id", ""))
				if not resource_id.is_empty() and not item_ids.has(resource_id):
					errors.append(
						"element '%s' BOM references unknown item '%s'"
						% [str(archetype_id), resource_id]
					)
		for actuator_key: String in _ACTUATOR_KEYS:
			if (
				element.has(actuator_key)
				and not element[actuator_key] is Dictionary
			):
				errors.append(
					"element '%s'.%s must be an object"
					% [str(archetype_id), actuator_key]
				)
	return errors


static func _section(name: String) -> Dictionary:
	ensure_loaded()
	var section: Variant = _root.get(name, {})
	return section if section is Dictionary else {}


static func _build_requirements(raw: Variant) -> Array[BuildRequirement]:
	var result: Array[BuildRequirement] = []
	if not raw is Array:
		return result
	for row_variant: Variant in raw:
		if not row_variant is Dictionary:
			continue
		var row: Dictionary = row_variant
		var requirement := BuildRequirement.new()
		requirement.resource_id = str(row.get("resource_id", ""))
		requirement.amount = float(row.get("amount", 0.0))
		result.append(requirement)
	return result


static func _apply_definition_overlay(definition: Resource, overlay: Variant) -> void:
	if definition == null or not overlay is Dictionary:
		return
	var fields: Dictionary = overlay
	for key_variant: Variant in fields.keys():
		var key := str(key_variant)
		if key.is_empty() or not key in definition:
			continue
		definition.set(key, fields[key_variant])
