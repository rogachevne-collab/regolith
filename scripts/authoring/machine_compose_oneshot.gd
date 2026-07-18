extends Node

## One-shot: ./run.sh --headless res://scenes/compose_machine_oneshot.tscn -- <phrase>


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var phrase := _phrase_from_args()
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	for item_id: String in [
		"plate_metal",
		"girder",
		"mechanism",
		"conduit",
		"plate_basalt",
		"sintered_basalt",
		"plate_alloy",
	]:
		world.set_resource_amount("player", item_id, 2000.0)
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		world.get_archetype_registry().register(archetype)
	var intent := MachineIntent.from_phrase(phrase)
	var result := MachineComposer.compose(world, intent)
	print("MACHINE-COMPOSE-ONESHOT phrase=%s" % phrase)
	print("MACHINE-COMPOSE-ONESHOT intent=%s" % intent.to_dict())
	if bool(result.get("ok", false)):
		print(
			"MACHINE-COMPOSE-ONESHOT: PASS assembly_id=%d driven=%s"
			% [
				int(result.get("assembly_id", 0)),
				result.get("validate", {}).get("driven_count", "?"),
			]
		)
		world.free()
		get_tree().quit(0)
		return
	print(
		"MACHINE-COMPOSE-ONESHOT: FAIL error=%s failures=%s"
		% [result.get("error", ""), result.get("failures", [])]
	)
	world.free()
	get_tree().quit(1)


func _phrase_from_args() -> String:
	var parts: PackedStringArray = OS.get_cmdline_user_args()
	if parts.is_empty():
		return "буровой манипулятор"
	return " ".join(parts)
