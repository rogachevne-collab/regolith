extends Node

## One-shot: ./run.sh --headless res://scenes/compose_rover_oneshot.tscn -- <phrase>
## Without args uses a default demo phrase.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var phrase := _phrase_from_args()
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.local_store_id())
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
			PlayerIdentity.local_store_id(),
			item_id,
			800.0
		)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	var intent := RoverIntent.from_phrase(phrase)
	var result := RoverComposer.compose(world, intent)
	print("ROVER-COMPOSE-ONESHOT phrase=%s" % phrase)
	print("ROVER-COMPOSE-ONESHOT intent=%s" % intent.to_dict())
	if bool(result.get("ok", false)):
		var assembly_id := int(result.get("assembly_id", 0))
		RoverLoadReport.print_lines(
			RoverLoadReport.analyze(world, assembly_id, intent)
		)
		print(
			"ROVER-COMPOSE-ONESHOT: PASS assembly_id=%d wheels=%s"
			% [
				int(result.get("assembly_id", 0)),
				result.get("validate", {}).get("complete_wheel_pairs", "?"),
			]
		)
		world.free()
		get_tree().quit(0)
		return
	print(
		"ROVER-COMPOSE-ONESHOT: FAIL error=%s failures=%s"
		% [result.get("error", ""), result.get("failures", [])]
	)
	world.free()
	get_tree().quit(1)


func _phrase_from_args() -> String:
	var parts: PackedStringArray = OS.get_cmdline_user_args()
	if parts.is_empty():
		return "низкий длинный ровер с 6 колесами, кокпит спереди"
	return " ".join(parts)
