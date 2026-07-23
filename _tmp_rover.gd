extends SceneTree

func _initialize() -> void:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	for item: String in ["plate_metal","girder","mechanism","conduit","plate_basalt","sintered_basalt","plate_alloy"]:
		world.set_resource_amount(PlayerIdentity.store_id("player"), item, 800.0)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)

	print("authored pair: %s" % [Slice01Archetypes.authored_wheel_pair()])
	var intent := RoverIntent.from_phrase("ровер на 4 колёсах на новых колёсах и подвесках")
	print("intent: %s" % [intent.to_dict()])
	var result := RoverComposer.compose(world, intent)
	print("ok: %s  error: %s" % [result.get("ok"), result.get("error", "")])
	if result.has("failures"):
		print("failures: %s" % [result["failures"]])
	var ids: Dictionary = result.get("element_ids", {})
	for key: String in ids.keys():
		if not (key.begins_with("wheel_") or key.begins_with("suspension_")):
			continue
		var element := world.get_element(int(ids[key]))
		if element == null:
			continue
		print("  %s: %s origin %s ori %d cells %s" % [
			key, element.archetype_id, element.origin_cell,
			element.orientation_index, element.occupied_cells()
		])
	world.free()
	quit(0)
