class_name BlueprintBaker
extends RefCounted

const BAKED_DIR := "res://resources/blueprints/baked/"
const ERR_VALIDATION_FAILED := 30


static func bake_from_placements(
	blueprint_id: String,
	placements: Array[BlueprintElementPlacement]
) -> Blueprint:
	var blueprint := Blueprint.new()
	blueprint.blueprint_id = blueprint_id
	blueprint.version = 1
	blueprint.placements = _sorted_copy(placements)
	return blueprint


static func bake_from_authoring_root(root: BlueprintAuthoringRoot) -> Blueprint:
	var placements: Array[BlueprintElementPlacement] = []
	for marker: ElementMarker in root.collect_markers():
		var placement := marker.to_placement()
		if placement != null:
			placements.append(placement)
	return bake_from_placements(root.blueprint_id, placements)


static func validate_and_bake(
	blueprint_id: String,
	placements: Array[BlueprintElementPlacement]
) -> Dictionary:
	var blueprint := bake_from_placements(blueprint_id, placements)
	var validation: BlueprintValidationResult = BlueprintValidator.validate(
		blueprint
	)
	return {
		"blueprint": blueprint,
		"validation": validation,
	}


static func baked_resource_path(blueprint_id: String) -> String:
	return "%s%s.tres" % [BAKED_DIR, blueprint_id]


static func save_baked(blueprint: Blueprint) -> Error:
	var validation: BlueprintValidationResult = BlueprintValidator.validate(
		blueprint
	)
	if not validation.ok:
		push_error(
			"Blueprint bake rejected: %s" % ", ".join(validation.errors)
		)
		return ERR_VALIDATION_FAILED
	var path := baked_resource_path(blueprint.blueprint_id)
	_ensure_baked_dir()
	return ResourceSaver.save(blueprint, path)


static func fingerprint(blueprint: Blueprint) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append(blueprint.blueprint_id)
	parts.append(str(blueprint.version))
	for placement: BlueprintElementPlacement in blueprint.placements:
		var archetype_id := ""
		if placement.archetype != null:
			archetype_id = placement.archetype.archetype_id
		parts.append(
			"%s|%s|%s|%d" % [
				placement.local_id,
				archetype_id,
				placement.origin_cell,
				placement.orientation_index,
			]
		)
	return "|".join(parts)


static func _sorted_copy(
	placements: Array[BlueprintElementPlacement]
) -> Array[BlueprintElementPlacement]:
	var sorted: Array[BlueprintElementPlacement] = placements.duplicate()
	sorted.sort_custom(
		func(a: BlueprintElementPlacement, b: BlueprintElementPlacement) -> bool:
			return a.compare_sort_key(b)
	)
	return sorted


static func _ensure_baked_dir() -> void:
	var absolute := ProjectSettings.globalize_path(BAKED_DIR)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)
