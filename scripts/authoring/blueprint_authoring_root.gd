@tool
class_name BlueprintAuthoringRoot
extends Node3D

@export var blueprint_id: String = ""
@export var bake_now: bool = false:
	set(value):
		bake_now = value
		if value and Engine.is_editor_hint():
			_perform_bake()
			bake_now = false

@export var last_bake_diagnostics: PackedStringArray = PackedStringArray()


func collect_markers() -> Array[ElementMarker]:
	var markers: Array[ElementMarker] = []
	for child: Node in get_children():
		var marker := child as ElementMarker
		if marker != null:
			markers.append(marker)
	return markers


func bake() -> Dictionary:
	last_bake_diagnostics = PackedStringArray()
	if blueprint_id.is_empty():
		last_bake_diagnostics.append("blueprint_id is empty")
		return {"ok": false}

	var placements: Array[BlueprintElementPlacement] = []
	for marker: ElementMarker in collect_markers():
		var marker_issues: PackedStringArray = marker.get_diagnostics()
		for issue: String in marker_issues:
			last_bake_diagnostics.append("%s: %s" % [marker.name, issue])
		var placement := marker.to_placement()
		if placement != null:
			placements.append(placement)

	if placements.is_empty():
		last_bake_diagnostics.append("no valid placements collected")
		return {"ok": false}

	var baked: Dictionary = BlueprintBaker.validate_and_bake(
		blueprint_id,
		placements
	)
	var validation: BlueprintValidationResult = baked["validation"]
	for error: String in validation.errors:
		last_bake_diagnostics.append(error)
	for warning: String in validation.warnings:
		last_bake_diagnostics.append("warning: %s" % warning)

	if not validation.ok:
		return {"ok": false, "validation": validation}

	var blueprint: Blueprint = baked["blueprint"]
	var save_error: Error = BlueprintBaker.save_baked(blueprint)
	if save_error != OK:
		last_bake_diagnostics.append(
			"ResourceSaver failed with code %d" % save_error
		)
		return {"ok": false, "validation": validation}

	last_bake_diagnostics.append(
		"baked %d placements to %s"
		% [
			blueprint.placements.size(),
			BlueprintBaker.baked_resource_path(blueprint_id),
		]
	)
	return {
		"ok": true,
		"blueprint": blueprint,
		"validation": validation,
		"path": BlueprintBaker.baked_resource_path(blueprint_id),
	}


func _perform_bake() -> void:
	var result: Dictionary = bake()
	if not bool(result.get("ok", false)):
		push_warning(
			"Blueprint bake failed for '%s': %s"
			% [blueprint_id, ", ".join(last_bake_diagnostics)]
		)
