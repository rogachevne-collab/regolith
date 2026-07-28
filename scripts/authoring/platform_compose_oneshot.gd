extends Node

## One-shot: compose 6×8 platform. Headless smoke for PlatformComposer.

const _PlatformComposer := preload("res://scripts/authoring/platform_composer.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := SimulationWorld.new()
	world.ensure_resource_store(AssemblyBuildHelper.AUTHORING_STORE_ID)
	for item_id: String in [
		"plate_metal",
		"girder",
		"mechanism",
		"conduit",
		"plate_basalt",
		"sintered_basalt",
		"plate_alloy",
	]:
		world.set_resource_amount(
			AssemblyBuildHelper.AUTHORING_STORE_ID,
			item_id,
			20000.0
		)
	var result: Dictionary = _PlatformComposer.compose(
		world, GridTransform.identity(), AssemblyBuildHelper.AUTHORING_STORE_ID
	)
	print("PLATFORM-COMPOSE-ONESHOT clearance=%.2f" % _PlatformComposer.wheel_clearance_m())
	if bool(result.get("ok", false)):
		var assembly_id := int(result.get("assembly_id", 0))
		var assembly := world.get_assembly_raw(assembly_id)
		var element_count := (
			assembly.element_ids.size() if assembly != null else 0
		)
		print(
			"PLATFORM-COMPOSE-ONESHOT: PASS assembly_id=%d elements=%d"
			% [assembly_id, element_count]
		)
		world.free()
		get_tree().quit(0)
		return
	print(
		"PLATFORM-COMPOSE-ONESHOT: FAIL error=%s"
		% result.get("error", "")
	)
	world.free()
	get_tree().quit(1)
