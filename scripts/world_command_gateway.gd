class_name WorldCommandGateway
extends Node

signal command_completed(command_id: int, result: Dictionary)

# A flat, gravity-upright block bottom cannot follow bumpy/sloped terrain, so the
# aim hit (near, highest footprint edge) leaves the rest of the base floating. We
# reseat a first-on-ground block onto the LOWEST terrain point under its whole
# footprint (plus a hairline embed) so no corner ever floats above the surface.
const GROUND_SEAT_EMBED := 0.02
const _GROUND_SEAT_SAMPLES: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(-0.5, -0.5),
	Vector2(0.5, -0.5),
	Vector2(-0.5, 0.5),
	Vector2(0.5, 0.5),
]

@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
@export var placed_blocks_path: NodePath = NodePath("../PlacedBlocks")
@export var simulation_session_path: NodePath = NodePath("../SimulationSession")

signal terrain_modified(removed_volume_m3: float, dig_center: Vector3, dig_radius_m: float)

var _terrain: Node3D
var _placed_blocks: Node
var _voxel_tool: VoxelTool
var _session: SimulationSession
var _queue: Array[Dictionary] = []
var _flush_scheduled := false
var _next_command_id := 1
var _archetype_cache: Dictionary = {}
var _snap_face_cache := ConstructionSnapFaceCache.new()
var _snap_resolver := ConstructionSnapResolver.new()
var _resolve_result_cache_key: String = ""
var _resolve_result_cache: Dictionary = {}
var _snap_event_bound := false
var _excavation := TerrainExcavationService.new()
var _material_source := TerrainMaterialSource.new()
var _hand_drill_last_bite_center: Variant = null
var _hand_drill_last_bite_msec := 0
var _rover_seat_player: Node3D
var _rover_seat_assembly_id := 0
var _rover_seat_element_id := 0


func _ready() -> void:
	_terrain = get_node(terrain_path)
	_placed_blocks = get_node(placed_blocks_path)
	_session = get_node_or_null(simulation_session_path) as SimulationSession
	_voxel_tool = TerrainCompat.get_voxel_tool(_terrain)
	_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	add_to_group(&"world_command_gateway")
	for archetype_id: String in ToolController.CONSTRUCTION_ARCHETYPES:
		_get_archetype(archetype_id)
	var piston_head := Slice01Archetypes.piston_head()
	if piston_head != null:
		_archetype_cache["piston_head"] = piston_head
	_snap_resolver.bind_cache(_snap_face_cache)
	call_deferred("_bind_snap_cache_events")
	call_deferred("_bind_terrain_contact_probe")


func _bind_terrain_contact_probe() -> void:
	if _session == null or _session.world == null:
		return
	_session.world.set_terrain_contact_probe(
		_probe_assembly_terrain_contact
	)


func _probe_assembly_terrain_contact(
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	var space_state: PhysicsDirectSpaceState3D = _physics_space_state()
	return TerrainAnchorProbe.touching_element_ids(
		_voxel_tool,
		_session.world,
		assembly,
		elements,
		space_state,
		_terrain
	)


func submit(command: Dictionary) -> int:
	var queued := command.duplicate(true)
	var command_id := _next_command_id
	_next_command_id += 1
	queued["id"] = command_id
	_queue.append(queued)
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush")
	return command_id


func _flush() -> void:
	_flush_scheduled = false
	while not _queue.is_empty():
		var command: Dictionary = _queue.pop_front()
		var command_id: int = command["id"]
		var result := _execute(command)
		result["command_kind"] = command.get("kind", StringName())
		command_completed.emit(
			command_id,
			result
		)


func _execute(command: Dictionary) -> Dictionary:
	if not command.has("kind") or not command.has("target"):
		return _result(&"invalid_target")
	var target: Dictionary = command["target"]
	if not bool(target.get("valid", false)):
		return _result(&"no_target")

	match StringName(command["kind"]):
		&"voxel_remove":
			return _remove_voxel(command, target)
		&"damage_element":
			return _damage_element(command, target)
		&"place_block":
			return _place_block(command, target)
		&"toggle_control_seat":
			return _toggle_control_seat(command, target)
		&"construction_apply":
			return _construction_apply(command, target)
		&"weld_element":
			return _weld_element(command, target)
		&"dismantle_element":
			return _dismantle_element(command, target)
		&"transfer_resource":
			return _transfer_resource(command, target)
		&"connect_network":
			return _connect_network(command, target)
		&"disconnect_network":
			return _disconnect_network(command, target)
		&"set_machine_enabled":
			return _set_machine_enabled(command, target)
		&"enqueue_recipe":
			return _enqueue_recipe(command, target)
		&"dequeue_recipe":
			return _dequeue_recipe(command, target)
		&"collect_world_loot":
			return _collect_world_loot(command)
		&"set_actuator_target":
			return _set_actuator_target(command, target)
		&"configure_actuator":
			return _configure_actuator(command, target)
		&"configure_wheel":
			return _configure_wheel(command, target)
		&"configure_suspension":
			return _configure_suspension(command, target)
		_:
			return _result(&"invalid_target")


func _remove_voxel(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if StringName(target["target_kind"]) != InteractionHit.KIND_VOXEL:
		return _result(&"invalid_target")
	var parameters: Dictionary = command.get("parameters", {})
	var radius := clampf(
		float(
			parameters.get(
				"radius",
				IndustryArchetypeProfile.hand_drill_carve_radius_m()
			)
		),
		0.05,
		2.0
	)
	var metadata: Dictionary = target.get("metadata", {})
	var direction := Vector3(
		metadata.get("aim_direction", Vector3.FORWARD)
	).normalized()
	var contact_point := Vector3(target["point"])
	var bite_center := contact_point - direction * (
		radius - IndustryArchetypeProfile.hand_drill_bite_depth_m()
	)
	var sdf_scale := IndustryArchetypeProfile.hand_drill_sdf_scale()
	var total_removed_m3 := 0.0
	var now_msec := Time.get_ticks_msec()
	var use_path_sweep := false
	if _hand_drill_last_bite_center is Vector3:
		var span_m := bite_center.distance_to(_hand_drill_last_bite_center)
		var gap_ms := now_msec - _hand_drill_last_bite_msec
		use_path_sweep = (
			span_m > 0.0001
			and span_m <= IndustryArchetypeProfile.hand_drill_path_max_span_m()
			and gap_ms <= IndustryArchetypeProfile.hand_drill_path_max_gap_ms()
		)
	if use_path_sweep:
		var sweep := _excavation.excavate(
			_voxel_tool,
			{
				"stamp_kind": &"path",
				"terrain": _terrain,
				"points": PackedVector3Array([
					_hand_drill_last_bite_center,
					bite_center,
				]),
				"radii": PackedFloat32Array([radius, radius]),
				"sdf_scale": sdf_scale,
			}
		)
		total_removed_m3 += float(sweep["removed_volume_m3"])
	var excavation := _excavation.excavate(
		_voxel_tool,
		{
			"stamp_kind": &"sphere",
			"terrain": _terrain,
			"center": bite_center,
			"radius": radius,
			"sdf_scale": sdf_scale,
		}
	)
	total_removed_m3 += float(excavation["removed_volume_m3"])
	if total_removed_m3 > 0.000001:
		_hand_drill_last_bite_center = bite_center
		_hand_drill_last_bite_msec = now_msec
		_notify_terrain_modified(total_removed_m3, bite_center, radius)
	else:
		_hand_drill_last_bite_center = null
	var removed_m3 := total_removed_m3
	if removed_m3 > 0.000001:
		_route_hand_drill_yield(
			contact_point,
			_material_source.yield_for_removed_volume(
				removed_m3,
				IndustryArchetypeProfile.terrain_collectible_fraction()
			)
		)
	return _result(
		StringName(excavation["status"]),
		{
			"point": target["point"],
			"removed_volume_m3": removed_m3,
		}
	)


func _route_hand_drill_yield(
	center: Vector3,
	yields: Array[Dictionary]
) -> void:
	if _session == null or _session.world == null:
		return
	var store := _session.world.get_resource_store(
		IndustryStoreService.PLAYER_STORE_ID
	)
	for yield_entry: Dictionary in yields:
		var resource_id := String(yield_entry.get("resource_id", ""))
		var remaining_mass_kg := float(yield_entry.get("mass_kg", 0.0))
		var unit_mass := ResourceCatalog.mass_per_unit_kg(resource_id)
		if resource_id.is_empty() or remaining_mass_kg <= 0.000001:
			continue
		if store != null and unit_mass > 0.000001:
			var max_units := ResourceCatalog.max_addable_amount_player(
				store,
				resource_id
			)
			var credited_units := minf(
				remaining_mass_kg / unit_mass,
				max_units
			)
			if credited_units > 0.000001:
				store.add(resource_id, credited_units)
				remaining_mass_kg = maxf(
					remaining_mass_kg - credited_units * unit_mass,
					0.0
				)
		if remaining_mass_kg > 0.000001:
			_session.world.add_world_loot_pile(
				center,
				resource_id,
				remaining_mass_kg
			)


func apply_terrain_carve(
	op: Dictionary,
	volume_budget_m3: float = INF
) -> float:
	var request := op.duplicate(true)
	request["terrain"] = _terrain
	request["volume_budget_m3"] = volume_budget_m3
	if not request.has("sdf_scale"):
		request["sdf_scale"] = TerrainExcavationService.DEFAULT_SDF_SCALE
	var removed := float(
		_excavation.excavate(_voxel_tool, request).get("removed_volume_m3", 0.0)
	)
	if removed > 0.000001:
		_notify_terrain_modified(
			removed,
			_dig_center_from_request(request),
			_dig_radius_from_request(request)
		)
	return removed


func _dig_center_from_request(request: Dictionary) -> Vector3:
	match StringName(request.get("stamp_kind", &"sphere")):
		&"path":
			var points: PackedVector3Array = request.get("points", PackedVector3Array())
			if points.is_empty():
				return Vector3.ZERO
			return points[points.size() - 1]
		_:
			return request.get("center", Vector3.ZERO)


func _dig_radius_from_request(request: Dictionary) -> float:
	match StringName(request.get("stamp_kind", &"sphere")):
		&"path":
			var radii: PackedFloat32Array = request.get("radii", PackedFloat32Array())
			if radii.is_empty():
				return 0.0
			return float(radii[radii.size() - 1])
		_:
			return float(request.get("radius", 0.0))


func _notify_terrain_modified(
	removed_volume_m3: float,
	dig_center: Vector3 = Vector3.ZERO,
	dig_radius_m: float = 0.0
) -> void:
	terrain_modified.emit(removed_volume_m3, dig_center, dig_radius_m)


func stationary_drill_has_terrain_contact(element_id: int) -> bool:
	return not _stationary_drill_contact(element_id).is_empty()


func carve_stationary_drill(element_id: int) -> float:
	var contact := _stationary_drill_contact(element_id)
	if contact.is_empty():
		return 0.0
	var radius := IndustryArchetypeProfile.drill_carve_radius_m()
	var direction: Vector3 = contact["direction"]
	var center: Vector3 = (
		contact["point"]
		+ direction
		* radius
		* IndustryArchetypeProfile.drill_carve_center_offset_factor()
	)
	var removed := float(
		_excavation.excavate(
			_voxel_tool,
			{
				"stamp_kind": &"sphere",
				"terrain": _terrain,
				"center": center,
				"radius": radius,
				"sdf_scale": IndustryArchetypeProfile.hand_drill_sdf_scale(),
			}
		).get("removed_volume_m3", 0.0)
	)
	if removed > 0.000001:
		_notify_terrain_modified(removed, center, radius)
	return removed


func _stationary_drill_contact(element_id: int) -> Dictionary:
	if _session == null or _session.world == null or _voxel_tool == null:
		return {}
	var element := _session.world.get_element(element_id)
	if element == null or element.archetype_id != "stationary_drill":
		return {}
	var working_frame := _stationary_drill_working_frame(element)
	if working_frame == Transform3D.IDENTITY:
		return {}
	# The authored working face is local +X. Presentation uses the same axis.
	var local_direction := OrientationUtil.rotate_direction(
		Vector3i.RIGHT,
		element.orientation_index
	)
	var direction := (
		working_frame.basis * Vector3(local_direction)
	).normalized()
	var local_tip := (
		GridPoseUtil.oriented_footprint_pivot(
			element.get_archetype(),
			element.origin_cell,
			element.orientation_index
		)
		+ Vector3(local_direction)
		* IndustryArchetypeProfile.drill_head_offset_m()
	)
	var tip := working_frame * local_tip
	var sdf_hit := _stationary_drill_sdf_contact_along_axis(tip, direction)
	if not sdf_hit.is_empty():
		return sdf_hit
	var probe_start := tip - direction * 0.08
	var reach := IndustryArchetypeProfile.drill_contact_reach_m() + 0.08
	var physics_hit := TerrainAnchorProbe.raycast_terrain(
		_physics_space_state(),
		_terrain,
		probe_start,
		direction,
		reach
	)
	if not physics_hit.is_empty():
		return {
			"point": physics_hit["position"],
			"direction": direction,
		}
	var back_hit := TerrainAnchorProbe.raycast_terrain(
		_physics_space_state(),
		_terrain,
		tip,
		-direction,
		0.35
	)
	if not back_hit.is_empty():
		return {
			"point": back_hit["position"],
			"direction": direction,
		}
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		_voxel_tool,
		_terrain,
		probe_start,
		direction,
		reach
	)
	if hit == null:
		return {}
	return {
		"point": VoxelSpaceUtil.raycast_hit_world_point(
			_terrain,
			probe_start,
			direction,
			hit
		),
		"direction": direction,
	}


func _stationary_drill_working_frame(element: SimulationElement) -> Transform3D:
	var body := _stationary_drill_physics_body(element)
	if body != null:
		return body.global_transform
	if _session == null or _session.world == null or element == null:
		return Transform3D.IDENTITY
	return _session.world.element_group_motion(element.element_id).transform


func _stationary_drill_physics_body(
	element: SimulationElement
) -> PhysicsBody3D:
	if _session == null or _session.projection == null:
		return null
	var record: Dictionary = _session.projection.get_element_projection(
		element.element_id
	)
	return record.get("body") as PhysicsBody3D


func _stationary_drill_sdf_contact_along_axis(
	tip: Vector3,
	direction: Vector3
) -> Dictionary:
	var axis := direction.normalized()
	for along_m: float in [0.0, -0.12, -0.25, 0.12, 0.25]:
		var sample := tip + axis * along_m
		var sample_cell: Vector3i = VoxelSpaceUtil.world_cell_from_point(
			_terrain,
			sample
		)
		if (
			TerrainExcavationService.sdf_occupancy(
				_voxel_tool.get_voxel_f(sample_cell)
			)
			> 0.0
		):
			return {"point": sample, "direction": direction}
	return {}


func get_voxel_tool() -> VoxelTool:
	return _voxel_tool


func _place_block(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var source: Node3D = command.get("source")
	if source == null:
		return _result(&"not_ready")
	var cell: Vector3i = _placed_blocks.call(
		"placement_cell_from_hit",
		Vector3(target["point"]),
		Vector3(target["normal"])
	)
	if not _placed_blocks.call("try_place", cell, source):
		return _result(&"blocked", {"cell": cell})
	return _result(&"ok", {"cell": cell})


func _toggle_control_seat(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var metadata: Dictionary = target.get("metadata", {})
	if (
		StringName(target["target_kind"])
		!= InteractionHit.KIND_CONTROL_SEAT
	):
		if (
			str(metadata.get("archetype_id", "")) == "cockpit"
			and int(metadata.get("element_id", 0)) > 0
		):
			var source: Node3D = command.get("source")
			if source == null:
				return _result(&"not_ready")
			if _is_rover_seated(source):
				return _exit_rover_seat(source)
			return _enter_rover_seat(source, metadata)
		return _result(&"invalid_target")
	var source: Node3D = command.get("source")
	if source == null:
		return _result(&"not_ready")
	if _is_rover_seated(source):
		return _exit_rover_seat(source)
	var vehicle: Object = target.get("collider")
	if metadata.has("element_id"):
		return _enter_rover_seat(source, metadata)
	if (
		vehicle == null
		or not vehicle.has_method("handle_interact")
	):
		return _result(&"not_ready")
	if not vehicle.call("handle_interact", source):
		return _result(&"blocked")
	return _result(&"ok")


func is_rover_seated(player: Node = null) -> bool:
	if player == null:
		player = _rover_seat_player
	return (
		player != null
		and _rover_seat_assembly_id > 0
		and player.has_method("is_in_vehicle")
		and player.call("is_in_vehicle")
	)


func tick_rover_locomotion_input() -> void:
	if _session == null:
		return
	var assembly_id := _resolve_active_rover_assembly_id()
	if assembly_id <= 0:
		return
	var locomotion := _session.world.get_locomotion_controller(assembly_id)
	if Input.is_action_just_pressed(&"toggle_parking_brake"):
		_toggle_rover_parking_brake(assembly_id, locomotion)
	if locomotion.is_parking_brake():
		# Latched Space: same commands every tick, no wheel-tick special cases.
		locomotion.set_drive_command(0.0)
		locomotion.set_steering_command(0.0)
		locomotion.set_brake_command(1.0)
		_wake_rover_body(assembly_id)
		return
	var drive := (
		Input.get_action_strength(&"move_forward")
		- Input.get_action_strength(&"move_back")
	)
	var steer := Input.get_axis(&"move_right", &"move_left")
	locomotion.set_drive_command(drive)
	locomotion.set_steering_command(steer)
	locomotion.set_brake_command(
		1.0 if Input.is_action_pressed(&"jump") else 0.0
	)
	if locomotion.has_active_input():
		_wake_rover_body(assembly_id)


func _toggle_rover_parking_brake(
	assembly_id: int,
	locomotion: AssemblyLocomotionController
) -> void:
	if locomotion.is_parking_brake():
		locomotion.set_parking_brake(false)
		_wake_rover_body(assembly_id)
		return
	var body := _session.projection.get_physics_body(assembly_id)
	var linear := Vector3.ZERO
	var angular := Vector3.ZERO
	if body is RigidBody3D:
		var rigid := body as RigidBody3D
		linear = rigid.linear_velocity
		angular = rigid.angular_velocity
	var eps := AssemblyLocomotionController.PARKING_BRAKE_SPEED_EPS
	if linear.length() >= eps or angular.length() >= eps:
		command_completed.emit(0, _result(&"parking_brake_needs_stop"))
		return
	locomotion.set_parking_brake(true)
	_wake_rover_body(assembly_id)


func _resolve_active_rover_assembly_id() -> int:
	if _rover_seat_assembly_id > 0:
		return _rover_seat_assembly_id
	var player := _rover_seat_player
	if player == null:
		return 0
	if (
		player.has_method("is_in_vehicle")
		and not player.call("is_in_vehicle")
	):
		return 0
	if player.has_method("current_vehicle"):
		var vehicle: Node = player.call("current_vehicle")
		if vehicle != null and vehicle.has_meta("assembly_id"):
			return int(vehicle.get_meta("assembly_id"))
	return 0


func _is_rover_seated(player: Node3D) -> bool:
	return (
		is_rover_seated(player)
		and _rover_seat_element_id > 0
	)


func _enter_rover_seat(
	player: Node3D,
	metadata: Dictionary
) -> Dictionary:
	if _session == null or _session.projection == null:
		return _result(&"not_ready")
	var element_id := int(metadata.get("element_id", 0))
	var assembly_id := int(metadata.get("assembly_id", 0))
	if element_id <= 0 or assembly_id <= 0:
		return _result(&"invalid_target")
	if not WheelSimulationService.is_locomotive_assembly(
		_session.world,
		assembly_id
	):
		return _result(&"blocked", {"detail": &"not_locomotive"})
	var body := (
		_session.projection.get_element_projection(element_id).get("body")
		as PhysicsBody3D
	)
	if body == null:
		return _result(&"not_ready")
	var element := _session.world.get_element(element_id)
	if element == null:
		return _result(&"invalid_target")
	var seat_offset: Vector3 = WheelPlacementUtil.seat_offset_local(element)
	_prepare_rover_for_drive(assembly_id)
	body = (
		_session.projection.get_element_projection(element_id).get("body")
		as PhysicsBody3D
	)
	if body == null or not is_instance_valid(body):
		return _result(&"not_ready")
	if player.has_method("set_gameplay_input_enabled"):
		player.call("set_gameplay_input_enabled", false)
	if player.has_method("enter_vehicle"):
		player.call("enter_vehicle", body, seat_offset)
	_rover_seat_player = player
	_rover_seat_assembly_id = assembly_id
	_rover_seat_element_id = element_id
	# Activate may replace StaticBody→RigidBody and free mesh children;
	# rebuild visuals onto the live body (wheels need module meshes first).
	if _session.visuals != null:
		_session.visuals.rebuild_assembly(assembly_id)
	if _session.piston_visuals != null:
		_session.piston_visuals.rebuild_assembly(assembly_id)
	if _session.wheel_visuals != null:
		_session.wheel_visuals.rebuild_assembly(assembly_id)
	return _result(&"ok", {
		"assembly_id": assembly_id,
		"element_id": element_id,
	})


func _prepare_rover_for_drive(assembly_id: int) -> void:
	if _session == null or _session.world == null or assembly_id <= 0:
		return
	var world := _session.world
	world.get_locomotion_controller(assembly_id).activate()
	_ensure_rover_power_network(world, assembly_id)
	IndustryElectricBudget.apply_tick(world, 0.25)
	_wake_rover_body(assembly_id)
	if not _rover_has_powered_wheel(world, assembly_id):
		push_warning(
			"Rover %d: wheels have no distributor power — check battery wire"
			% assembly_id
		)


func _rover_has_powered_wheel(
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	for pair: Dictionary in WheelSimulationService.discover_pairs(
		world,
		assembly_id
	):
		if not WheelSimulationService.is_complete_pair(pair):
			continue
		var wheel_element: SimulationElement = pair.get("wheel_element")
		if wheel_element == null:
			continue
		var runtime := world.ensure_industry_element_runtime(
			wheel_element.element_id
		)
		if runtime.machine_enabled and runtime.powered:
			return true
	return false


func _ensure_rover_power_network(
	world: SimulationWorld,
	assembly_id: int
) -> void:
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	var battery_id := 0
	var distributor_id := 0
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null or not element.is_operational():
			continue
		match element.archetype_id:
			"power_battery_small", "power_battery":
				battery_id = element_id
			"power_distributor_small", "power_distributor":
				distributor_id = element_id
	if battery_id <= 0 or distributor_id <= 0:
		return
	if not IndustryElectricBudget.is_element_on_supplied_network(
		world,
		distributor_id
	):
		world.connect_network(
			battery_id,
			"power_out",
			distributor_id,
			"power_in"
		)
	var battery := world.get_element(battery_id)
	if battery == null:
		return
	var battery_runtime := world.ensure_industry_element_runtime(battery_id)
	if battery_runtime.battery_kwh <= 0.001:
		battery_runtime.battery_kwh = IndustryElectricProfile.battery_max_kwh(
			battery
		)


func _wake_rover_body(assembly_id: int) -> void:
	if _session == null or _session.projection == null or assembly_id <= 0:
		return
	var body := _session.projection.get_physics_body(assembly_id)
	if body is StaticBody3D:
		var assembly := _session.world.get_assembly_raw(assembly_id)
		if assembly != null:
			var motion := assembly.motion.duplicate_state()
			_session.projection.project_assembly_now(assembly_id, motion)
			body = _session.projection.get_physics_body(assembly_id)
	if body is RigidBody3D:
		var rigid := body as RigidBody3D
		rigid.freeze = false
		rigid.sleeping = false


func _exit_rover_seat(player: Node3D) -> Dictionary:
	if _session == null or _rover_seat_assembly_id <= 0:
		return _result(&"not_ready")
	var assembly_id := _rover_seat_assembly_id
	var body := (
		_session.projection.get_element_projection(
			_rover_seat_element_id
		).get("body") as PhysicsBody3D
	)
	var exit_position := player.global_position
	if body != null:
		var element := _session.world.get_element(_rover_seat_element_id)
		if element != null:
			var seat_offset: Vector3 = WheelPlacementUtil.seat_offset_local(element)
			var seat_world: Vector3 = body.global_transform * seat_offset
			exit_position = (
				seat_world
				+ body.global_transform.basis.x * 1.2
				+ GravityField.resolve_up(body, seat_world) * 0.15
			)
	if player.has_method("exit_vehicle"):
		player.call("exit_vehicle", exit_position)
	if player.has_method("set_gameplay_input_enabled"):
		player.call("set_gameplay_input_enabled", true)
	var locomotion := _session.world.get_locomotion_controller(assembly_id)
	locomotion.set_drive_command(0.0)
	locomotion.set_steering_command(0.0)
	if locomotion.is_parking_brake():
		locomotion.set_brake_command(1.0)
	else:
		locomotion.set_brake_command(0.0)
	# Keep activated so floating wheel phys continues (coast or parking lock).
	_session.projection.sync_body_motion_now(assembly_id)
	_rover_seat_player = null
	_rover_seat_assembly_id = 0
	_rover_seat_element_id = 0
	return _result(&"ok")


func preview_construction(
	target: Dictionary,
	archetype_id: String,
	orientation_index: int,
	held_ground_pivot: Vector3 = Vector3(INF, INF, INF),
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Dictionary:
	if _session == null:
		return {
			"valid": false,
			"reason": &"not_ready",
		}
	var archetype := _get_archetype(archetype_id)
	return _seat_ground_plan(
		ConstructionPlacement.plan(
			_session.world,
			target,
			archetype,
			orientation_index,
			"player",
			held_ground_pivot,
			held_attach_pivot
		)
	)


func baseline_ground_pivot(
	target: Dictionary,
	archetype_id: String
) -> Vector3:
	if _session == null:
		return Vector3(INF, INF, INF)
	return ConstructionPlacement.baseline_ground_pivot(
		_session.world,
		target,
		_get_archetype(archetype_id)
	)


func resolve_construction_placement(params: Dictionary) -> Dictionary:
	var archetype_id := str(params.get("archetype_id", "frame"))
	var orientation_index := int(params.get("orientation_index", 0))
	var direct_hit: Dictionary = params.get("direct_hit", {})
	var manual_index := int(params.get("manual_candidate_index", -1))
	var held_ground_pivot: Vector3 = params.get(
		"held_ground_pivot",
		Vector3(INF, INF, INF)
	)
	var held_attach_pivot: Vector3 = params.get(
		"held_attach_pivot",
		Vector3(INF, INF, INF)
	)
	if _session == null:
		var plan := preview_construction(
			direct_hit,
			archetype_id,
			orientation_index,
			held_ground_pivot,
			held_attach_pivot
		)
		var selected_index := 0 if bool(plan.get("valid", false)) else -1
		return {
			"candidates": [],
			"selected_index": selected_index,
			"selected_target": (
				direct_hit if selected_index >= 0 else {}
			),
			"selected_plan": plan,
			"sticky_key": "",
			"stats": ConstructionSnapResolver._empty_stats(),
		}
	_bind_snap_cache_events()
	var cache_key := _resolve_cache_key(params)
	if manual_index < 0 and cache_key == _resolve_result_cache_key:
		return _resolve_result_cache.duplicate(true)
	var archetype := _get_archetype(archetype_id)
	var result := _snap_resolver.resolve({
		"world": _session.world,
		"archetype": archetype,
		"orientation_index": orientation_index,
		"store_id": str(params.get("store_id", "player")),
		"ray_origin": params.get("ray_origin", Vector3.ZERO),
		"ray_direction": params.get("ray_direction", Vector3.FORWARD),
		"camera": params.get("camera"),
		"direct_hit": direct_hit,
		"manual_candidate_index": manual_index,
		"held_ground_pivot": held_ground_pivot,
		"held_attach_pivot": held_attach_pivot,
	})
	result["selected_plan"] = _seat_ground_plan(
		result.get("selected_plan", {})
	)
	if manual_index < 0:
		_resolve_result_cache_key = cache_key
		_resolve_result_cache = result.duplicate(true)
	return result


func snap_cache_generation() -> int:
	return _snap_face_cache.generation


func snap_resolve_stats() -> Dictionary:
	return _snap_resolver.last_stats.duplicate(true)


func reset_construction_snap() -> void:
	_snap_resolver.reset_sticky()
	_clear_resolve_result_cache()


func _clear_resolve_result_cache() -> void:
	_resolve_result_cache_key = ""
	_resolve_result_cache = {}


func _bind_snap_cache_events() -> void:
	if _session == null or _session.world == null:
		return
	_snap_face_cache.bind_world(_session.world)
	if _snap_event_bound:
		return
	_session.world.structural_event.connect(_on_structural_event_for_snap)
	_snap_event_bound = true


func _on_structural_event_for_snap(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored", &"assembly_spawned", &"assembly_changed", &"assembly_removed", &"assembly_split", &"assembly_merged":
			_snap_face_cache.apply_structural_event(event)
			_clear_resolve_result_cache()


func _resolve_cache_key(params: Dictionary) -> String:
	var ray_origin: Vector3 = params.get("ray_origin", Vector3.ZERO)
	var ray_direction: Vector3 = Vector3(
		params.get("ray_direction", Vector3.FORWARD)
	).normalized()
	var direct_hit: Dictionary = params.get("direct_hit", {})
	var target_id := StringName(direct_hit.get("target_id", &""))
	var aim_step := _aim_quantize_step_for_id(str(params.get("archetype_id", "frame")))
	return "%d|%s|%s|%s|%d|%s|%s|%s|%s" % [
		_snap_face_cache.generation,
		_quantize_vec3(ray_origin, aim_step),
		_quantize_vec3(ray_direction, aim_step * 0.5),
		params.get("archetype_id", "frame"),
		int(params.get("orientation_index", 0)),
		target_id,
		str(bool(direct_hit.get("valid", false))),
		_pivot_cache_token(params.get("held_ground_pivot", Vector3(INF, INF, INF))),
		_pivot_cache_token(params.get("held_attach_pivot", Vector3(INF, INF, INF))),
	]


static func _quantize_vec3(value: Vector3, step: float) -> Vector3:
	if step <= 0.0:
		return value
	return Vector3(
		snapped(value.x, step),
		snapped(value.y, step),
		snapped(value.z, step),
	)


static func _pivot_cache_token(value: Variant) -> String:
	var pivot := Vector3(value)
	if not pivot.is_finite():
		return "unset"
	return str(_quantize_vec3(pivot, 0.05))


func _aim_quantize_step_for_id(archetype_id: String) -> float:
	var archetype := _get_archetype(archetype_id)
	if archetype != null and archetype.footprint_cells.size() >= 64:
		return 0.12
	return 0.04


func construction_resource_amount() -> float:
	if _session == null:
		return 0.0
	var store := _session.world.get_resource_store("player")
	return (
		store.amount("construction_component")
		if store != null else 0.0
	)


## Read-only accessor for presentation (HUD Inventory / StoreView). Returns the
## authoritative store so the HUD can render its amounts; the HUD only reads it
## and never mutates simulation state (see docs/specs/HUD-UI-01.md).
func resource_store(store_id: String) -> SimulationResourceStore:
	if _session == null:
		return null
	return _session.world.get_resource_store(store_id)


## Authoritative terminal inventory snapshot (INDUSTRY-V1 § Terminal inventory).
## Resolves player store, keyed element stores, and internal buffers. Unknown or
## unresolved ids return `{"valid": false, "reason": ...}` without mutating state.
func store_snapshot(store_id: String) -> Dictionary:
	if _session == null or _session.world == null:
		return StoreSnapshotBuilder.failure(&"not_ready")
	return StoreSnapshotBuilder.build(_session.world, store_id)


func player_inventory() -> PlayerInventoryRegistry:
	if _session == null or _session.world == null:
		return null
	return _session.world.ensure_player_inventory()


func player_inventory_revision() -> int:
	if _session == null or _session.world == null:
		return 0
	return _session.world.get_player_inventory_revision()


func assign_player_hotbar_instance(
	page: int,
	slot: int,
	instance_id: String
) -> bool:
	if _session == null or _session.world == null:
		return false
	return _session.world.assign_player_hotbar_instance(page, slot, instance_id)


func archetype_display_name(archetype_id: String) -> String:
	var archetype := _get_archetype(archetype_id)
	var gateway_name := ""
	if archetype != null and not archetype.display_name.is_empty():
		gateway_name = archetype.display_name
	return HudTokens.archetype_label(archetype_id, gateway_name)


func _damage_element(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		_session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return _result(&"invalid_target")
	var metadata: Dictionary = target.get("metadata", {})
	var element_id := int(metadata.get("element_id", 0))
	var parameters: Dictionary = command.get("parameters", {})
	var amount := float(parameters.get("damage", 0.0))
	var refund_fraction := float(parameters.get("refund_fraction_on_destroy", 0.0))
	var store_id := str(parameters.get("store_id", ""))
	return apply_damage(element_id, amount, refund_fraction, store_id)


func apply_damage(
	element_id: int,
	amount: float,
	refund_fraction_on_destroy: float = 0.0,
	store_id: String = ""
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var element := _session.world.get_element(element_id)
	if element == null:
		return _result(&"invalid_target")
	var command := DamageElementCommand.new()
	command.element_id = element_id
	command.expected_state_revision = element.state_revision
	command.damage = amount
	command.refund_fraction_on_destroy = refund_fraction_on_destroy
	command.store_id = store_id
	return _structural_result(
		_session.world.apply_structural_command_now(command)
	)


func _construction_apply(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _place_block(command, target)
	var parameters: Dictionary = command.get("parameters", {})
	var target_kind := StringName(target.get("target_kind", &""))
	var construction_mode := StringName(
		parameters.get("construction_mode", &"context")
	)
	var archetype_id := str(parameters.get("archetype_id", "frame"))
	var orientation_index := int(parameters.get("orientation_index", 0))
	var placement_plan: Dictionary = parameters.get("placement_plan", {})

	if (
		construction_mode == &"place"
		and not placement_plan.is_empty()
	):
		if bool(placement_plan.get("valid", false)):
			return _apply_place_plan(placement_plan)
		return _result(
			_map_structural_reason(
				StringName(placement_plan.get("reason", &"invalid_target"))
			),
			placement_plan.get("data", {})
		)

	if target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		var metadata: Dictionary = target.get("metadata", {})
		var element := _session.world.get_element(
			int(metadata.get("element_id", 0))
		)
		if element == null:
			return _result(&"invalid_target")
		if (
			construction_mode == &"repair"
			or (
				construction_mode == &"context"
				and (
					element.is_broken()
					or (
						element.get_archetype() != null
						and element.integrity
						< element.get_archetype().max_integrity
					)
				)
			)
		):
			var repair := RepairElementCommand.new()
			repair.element_id = element.element_id
			repair.expected_state_revision = element.state_revision
			repair.store_id = "player"
			repair.max_material_amount = 1.0
			return _structural_result(
				_session.world.apply_structural_command_now(repair)
			)
		var place_plan := preview_construction(
			target,
			archetype_id,
			orientation_index
		)
		if bool(place_plan.get("valid", false)):
			return _apply_place_plan(place_plan)
		if construction_mode == &"repair":
			return _result(&"not_damaged")
		return _result(
			_map_structural_reason(
				StringName(place_plan.get("reason", &"invalid_target"))
			),
			place_plan.get("data", {})
		)

	var plan := preview_construction(
		target,
		archetype_id,
		orientation_index
	)
	if not bool(plan.get("valid", false)):
		return _result(
			_map_structural_reason(
				StringName(plan.get("reason", &"invalid_target"))
			),
			plan.get("data", {})
		)
	return _apply_place_plan(plan)


func _weld_element(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		_session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return _result(&"invalid_target")
	var metadata: Dictionary = target.get("metadata", {})
	var element := _session.world.get_element(
		int(metadata.get("element_id", 0))
	)
	if element == null:
		return _result(&"invalid_target")
	if element.is_complete():
		return _result(&"already_complete")
	if element.is_broken():
		return _result(&"element_broken")
	var weld := WeldElementCommand.new()
	weld.element_id = element.element_id
	weld.expected_state_revision = element.state_revision
	weld.store_id = "player"
	weld.max_material_amount = 1.0
	return _structural_result(
		_session.world.apply_structural_command_now(weld)
	)


func _apply_place_plan(plan: Dictionary) -> Dictionary:
	var place := plan.get("command") as PlaceElementCommand
	var result := _session.world.apply_structural_command_now(place)
	return _structural_result(result)


## Reseats a first-on-ground placement so its footprint rests on the lowest
## terrain sample beneath it along Field down. Only shifts the continuous root;
## the discrete grid frame (topology) is untouched. Non-ground plans (attaching
## to an existing assembly) and invalid plans pass through unchanged.
func _seat_ground_plan(plan: Dictionary) -> Dictionary:
	if _voxel_tool == null or not bool(plan.get("valid", false)):
		return plan
	var command := plan.get("command") as PlaceElementCommand
	if command == null or command.assembly_id != 0:
		return plan
	var archetype := plan.get("archetype") as ElementArchetype
	if archetype == null:
		return plan
	var root: Transform3D = plan.get(
		"assembly_world_transform", Transform3D.IDENTITY
	)
	var origin_cell: Vector3i = plan.get("origin_cell", Vector3i.ZERO)
	var orientation_index := int(plan.get("orientation_index", 0))
	var footprint := AABB()
	var has_box := false
	for collider: ColliderDefinition in archetype.colliders:
		var box := GridPoseUtil.collider_world_aabb(
			root, origin_cell, orientation_index, collider
		)
		if not has_box:
			footprint = box
			has_box = true
		else:
			footprint = footprint.merge(box)
	if not has_box:
		return plan
	var center := footprint.position + footprint.size * 0.5
	var up := GravityField.resolve_up(self, center)
	var down := -up
	var half := footprint.size * 0.5
	var half_along_up := (
		absf(up.x) * half.x
		+ absf(up.y) * half.y
		+ absf(up.z) * half.z
	)
	var bottom_along_up := center.dot(up) - half_along_up
	var probe_lift := half_along_up + 1.0
	var probe_distance := probe_lift + 4.0
	var field := GravityField.find_in_tree(self)
	var frame: Basis = (
		field.tangent_basis_at(center)
		if field != null
		else Basis.looking_at(Vector3.FORWARD, Vector3.UP)
	)
	var lowest_along_up := INF
	for sample: Vector2 in _GROUND_SEAT_SAMPLES:
		var sample_point := (
			center
			+ frame.x * (sample.x * footprint.size.x * 0.5)
			+ frame.z * (sample.y * footprint.size.z * 0.5)
		)
		var probe_from := sample_point + up * probe_lift
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			probe_from,
			down,
			probe_distance
		)
		if (
			is_finite(physics_point.x)
			and is_finite(physics_point.y)
			and is_finite(physics_point.z)
		):
			lowest_along_up = minf(lowest_along_up, physics_point.dot(up))
			continue
		var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
			_voxel_tool,
			_terrain,
			probe_from,
			down,
			probe_distance
		)
		if hit == null:
			continue
		var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
			_terrain,
			probe_from,
			down,
			hit
		)
		lowest_along_up = minf(lowest_along_up, sdf_point.dot(up))
	if is_inf(lowest_along_up):
		return plan
	var delta := (lowest_along_up - GROUND_SEAT_EMBED) - bottom_along_up
	if absf(delta) < 0.0001:
		return plan
	var shift := up * delta
	var seated := plan.duplicate(true)
	var seated_root := root.translated(shift)
	seated["assembly_world_transform"] = seated_root
	seated["preview_root_transform"] = seated_root
	var seated_command := seated.get("command") as PlaceElementCommand
	if seated_command != null:
		seated_command.initial_motion = AssemblyMotionState.new()
		seated_command.initial_motion.transform = seated_root
	var world_transform: Transform3D = plan.get(
		"world_transform", root
	)
	seated["world_transform"] = world_transform.translated(shift)
	return seated


func _physics_space_state() -> PhysicsDirectSpaceState3D:
	if _terrain == null or not _terrain.is_inside_tree():
		return null
	return _terrain.get_world_3d().direct_space_state


func _get_archetype(archetype_id: String) -> ElementArchetype:
	if not _archetype_cache.has(archetype_id):
		_archetype_cache[archetype_id] = Slice01Archetypes.load_required(
			archetype_id
		)
	return _archetype_cache[archetype_id] as ElementArchetype


func apply_transfer_resource(command: TransferResourceCommand) -> Dictionary:
	if _session == null or command == null:
		return _result(&"not_ready")
	var result := _session.apply_transfer_resource(command)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"amount": float(result.get("amount", 0.0)),
			"from_store_id": command.from_store_id,
			"to_store_id": command.to_store_id,
			"resource_id": command.resource_id,
		}
	)


func apply_connect_network(
	element_a_id: int,
	element_b_id: int,
	port_a_id: String = "",
	port_b_id: String = "",
	waypoints: PackedVector3Array = PackedVector3Array()
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var diagnosis := IndustryElectricPortUtil.diagnose_electric_pair(
		_session.world,
		element_a_id,
		element_b_id,
		port_a_id,
		port_b_id,
		waypoints
	)
	var pair: Dictionary = diagnosis.get("pair", {})
	if pair.is_empty():
		var reason: StringName = diagnosis.get("reason", &"incompatible_connection")
		if reason == &"ok":
			reason = &"incompatible_connection"
		return _result(reason)
	var resolved_a := int(pair.get("element_a_id", element_a_id))
	var resolved_b := int(pair.get("element_b_id", element_b_id))
	var resolved_port_a := (
		port_a_id if not port_a_id.is_empty() else str(pair["port_a_id"])
	)
	var resolved_port_b := (
		port_b_id if not port_b_id.is_empty() else str(pair["port_b_id"])
	)
	var element_a := _session.world.get_element(resolved_a)
	var element_b := _session.world.get_element(resolved_b)
	if element_a == null or element_b == null:
		return _result(&"invalid_target")
	var assembly_a := _session.world.get_assembly(element_a.assembly_id)
	var assembly_b := _session.world.get_assembly(element_b.assembly_id)
	var command := ConnectNetworkCommand.new()
	command.element_a_id = resolved_a
	command.port_a_id = resolved_port_a
	command.element_b_id = resolved_b
	command.port_b_id = resolved_port_b
	command.waypoints = waypoints
	if assembly_a != null:
		command.expected_revision_a = assembly_a.topology_revision
	if assembly_b != null:
		command.expected_revision_b = assembly_b.topology_revision
	var result := _session.world.apply_structural_command_now(command)
	if result == null:
		return _result(&"not_ready")
	if result.is_ok():
		return _result(&"ok", result.data)
	return _result(_connect_failure_reason(result.reason), result.data)


func _connect_network(
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	var parameters: Dictionary = command.get("parameters", {})
	return apply_connect_network(
		int(parameters.get("element_a_id", 0)),
		int(parameters.get("element_b_id", 0)),
		str(parameters.get("port_a_id", "")),
		str(parameters.get("port_b_id", "")),
		PackedVector3Array(parameters.get("waypoints", PackedVector3Array()))
	)


func _connect_failure_reason(reason: StringName) -> StringName:
	match reason:
		StructuralCommandResult.REASON_DUPLICATE_CONNECTION:
			return &"duplicate_connection"
		StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
			return &"incompatible_connection"
		StructuralCommandResult.REASON_CABLE_TOO_LONG:
			return &"cable_too_long"
		StructuralCommandResult.REASON_ENDPOINT_NOT_WIREABLE:
			return &"endpoint_not_wireable"
		StructuralCommandResult.REASON_ELEMENT_INCOMPLETE:
			return &"element_incomplete"
		StructuralCommandResult.REASON_ELEMENT_BROKEN:
			return &"element_broken"
		_:
			return _map_structural_reason(reason)


func _disconnect_network(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var link_id := int(
		parameters.get(
			"link_id",
			target.get("metadata", {}).get("electric_link_id", 0)
		)
	)
	if link_id <= 0:
		return _result(&"invalid_target")
	return _structural_result(
		_session.world.disconnect_network(0, "", 0, "", link_id)
	)


func _transfer_resource(
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var transfer := TransferResourceCommand.new()
	transfer.from_store_id = str(parameters.get("from_store_id", ""))
	transfer.to_store_id = str(parameters.get("to_store_id", ""))
	transfer.resource_id = str(parameters.get("resource_id", ""))
	transfer.amount = float(parameters.get("amount", 0.0))
	transfer.instance_id = str(parameters.get("instance_id", ""))
	return apply_transfer_resource(transfer)


func _set_machine_enabled(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var machine := SetMachineEnabledCommand.new()
	machine.element_id = int(
		parameters.get(
			"element_id",
			target.get("metadata", {}).get("element_id", 0)
		)
	)
	machine.enabled = bool(parameters.get("enabled", true))
	var result := _session.apply_set_machine_enabled(machine)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{"element_id": machine.element_id, "enabled": machine.enabled}
	)


func _enqueue_recipe(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var recipe := EnqueueRecipeCommand.new()
	recipe.element_id = int(
		parameters.get(
			"element_id",
			target.get("metadata", {}).get("element_id", 0)
		)
	)
	recipe.recipe_id = str(parameters.get("recipe_id", ""))
	var result := _session.apply_enqueue_recipe(recipe)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{"element_id": recipe.element_id, "recipe_id": recipe.recipe_id}
	)


func _dequeue_recipe(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var dequeue := DequeueRecipeCommand.new()
	dequeue.element_id = int(
		parameters.get(
			"element_id",
			target.get("metadata", {}).get("element_id", 0)
		)
	)
	var result := _session.apply_dequeue_recipe(dequeue)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{"element_id": dequeue.element_id}
	)


func _set_actuator_target(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var metadata: Dictionary = target.get("metadata", {})
	var actuator := SetActuatorTargetCommand.new()
	actuator.joint_id = int(
		parameters.get(
			"joint_id",
			metadata.get(
				"piston_joint_id",
				metadata.get(
					"rotor_joint_id",
					metadata.get("hinge_joint_id", 0)
				)
			)
		)
	)
	actuator.mode = int(
		parameters.get(
			"mode",
			SimulationMotorState.ControlMode.STOP
		)
	)
	actuator.target_position_m = float(
		parameters.get("target_position_m", 0.0)
	)
	actuator.target_velocity_mps = float(
		parameters.get("target_velocity_mps", 0.0)
	)
	actuator.speed_limit_mps = float(
		parameters.get("speed_limit_mps", -1.0)
	)
	actuator.enabled = bool(parameters.get("enabled", true))
	var result := _session.apply_set_actuator_target(actuator)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"joint_id": actuator.joint_id,
			"status_name": result.get("status_name", &""),
		}
	)


func _configure_actuator(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var metadata: Dictionary = target.get("metadata", {})
	var configure := ConfigureActuatorCommand.new()
	configure.joint_id = int(
		parameters.get(
			"joint_id",
			metadata.get(
				"piston_joint_id",
				metadata.get(
					"rotor_joint_id",
					metadata.get("hinge_joint_id", 0)
				)
			)
		)
	)
	configure.extend_velocity_mps = float(
		parameters.get("extend_velocity_mps", -1.0)
	)
	configure.retract_velocity_mps = float(
		parameters.get("retract_velocity_mps", -1.0)
	)
	configure.force_limit_n = float(parameters.get("force_limit_n", -1.0))
	configure.lower_limit_m = float(parameters.get("lower_limit_m", -1.0))
	configure.upper_limit_m = float(parameters.get("upper_limit_m", -1.0))
	configure.lower_limit_set = parameters.has("lower_limit_m")
	configure.upper_limit_set = parameters.has("upper_limit_m")
	var result := _session.apply_configure_actuator(configure)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"joint_id": configure.joint_id,
			"status_name": result.get("status_name", &""),
		}
	)


func _configure_wheel(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var metadata: Dictionary = target.get("metadata", {})
	var configure := ConfigureWheelCommand.new()
	configure.wheel_element_id = int(
		parameters.get(
			"wheel_element_id",
			metadata.get("wheel_element_id", metadata.get("element_id", 0))
		)
	)
	if parameters.has("steerable"):
		configure.steerable_set = true
		configure.steerable = bool(parameters["steerable"])
	if parameters.has("drive_torque_scale"):
		configure.drive_torque_scale = float(
			parameters["drive_torque_scale"]
		)
	if parameters.has("brake_torque_n_m"):
		configure.brake_torque_n_m = float(parameters["brake_torque_n_m"])
	var result := _session.apply_configure_wheel(configure)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"wheel_element_id": configure.wheel_element_id,
		}
	)


func _configure_suspension(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var metadata: Dictionary = target.get("metadata", {})
	var configure := ConfigureSuspensionCommand.new()
	configure.suspension_element_id = int(
		parameters.get(
			"suspension_element_id",
			metadata.get(
				"suspension_element_id",
				metadata.get("element_id", 0)
			)
		)
	)
	if parameters.has("travel_m"):
		configure.travel_m = float(parameters["travel_m"])
	if parameters.has("spring_stiffness_n_per_m"):
		configure.spring_stiffness_n_per_m = float(
			parameters["spring_stiffness_n_per_m"]
		)
	if parameters.has("spring_damping_n_s_per_m"):
		configure.spring_damping_n_s_per_m = float(
			parameters["spring_damping_n_s_per_m"]
		)
	var result := _session.apply_configure_suspension(configure)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"suspension_element_id": configure.suspension_element_id,
		}
	)


func _collect_world_loot(command: Dictionary) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var pile_id := int(parameters.get("pile_id", 0))
	var to_store_id := str(
		parameters.get(
			"to_store_id",
			IndustryStoreService.PLAYER_STORE_ID
		)
	)
	var result := _session.world.collect_world_loot_pile(
		pile_id,
		to_store_id
	)
	return _result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"pile_id": pile_id,
			"to_store_id": to_store_id,
			"resource_id": str(result.get("resource_id", "")),
			"amount": float(result.get("amount", 0.0)),
		}
	)


func _dismantle_element(
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		_session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return _result(&"invalid_target")
	var metadata: Dictionary = target.get("metadata", {})
	var element := _session.world.get_element(
		int(metadata.get("element_id", 0))
	)
	if element == null:
		return _result(&"invalid_target")
	var assembly := _session.world.get_assembly(element.assembly_id)
	if assembly == null:
		return _result(&"invalid_target")
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = element.element_id
	dismantle.expected_assembly_revision = assembly.topology_revision
	dismantle.store_id = "player"
	return _structural_result(
		_session.world.apply_structural_command_now(dismantle)
	)


func _structural_result(
	result: StructuralCommandResult
) -> Dictionary:
	if result == null:
		return _result(&"not_ready")
	return _result(
		&"ok" if result.is_ok() else _map_structural_reason(result.reason),
		result.data
	)


func _map_structural_reason(reason: StringName) -> StringName:
	match reason:
		StructuralCommandResult.REASON_OVERLAP:
			return &"blocked"
		StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
			return &"blocked"
		StructuralCommandResult.REASON_MISALIGNED_CONNECTION:
			return &"blocked"
		StructuralCommandResult.REASON_STALE_REVISION:
			return &"not_ready"
		StructuralCommandResult.REASON_INVALID_REFERENCE:
			return &"invalid_target"
		StructuralCommandResult.REASON_INVALID_TRANSFORM:
			return &"invalid_target"
		_:
			return reason


func _result(
	reason: StringName,
	data: Dictionary = {}
) -> Dictionary:
	return {
		"status": &"ok" if reason == &"ok" else &"failed",
		"reason": reason,
		"data": data,
	}
