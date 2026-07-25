class_name GatewayTerrainDigService
extends RefCounted

static func _probe_assembly_terrain_contact(gateway, 
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	var space_state: PhysicsDirectSpaceState3D = gateway._physics_space_state()
	return TerrainAnchorProbe.touching_element_ids(
		gateway._voxel_tool,
		gateway._session.world,
		assembly,
		elements,
		space_state,
		gateway._terrain
	)
## Share of loose material the spinning bit throws clear of its cylinder each
## bite. High on purpose: the drill mines rock only, so anything loose in the
## throat is parted aside, never left to re-flood the cut. `plow_spoil` rings it
## onto the rim and collects nothing — no spoil is credited as yield. First knob
## to drop if the ejected ring visibly pumps back in and out.
const HAND_DRILL_PLOW_SHARE := 1.0

static func _remove_voxel(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var target_kind := StringName(target["target_kind"])
	# Loose material neither blocks the bit nor is mined by it. Whether the aim
	# landed on rock or on the dust standing in front of it, one path: part the
	# loose aside (below) and cut the rock behind. `_remove_granular` is retired —
	# kept for reference, no longer reached — because the drill does not scoop.
	if (
		target_kind != InteractionHit.KIND_VOXEL
		and target_kind != InteractionHit.KIND_GRANULAR
	):
		return gateway._result(&"invalid_target")
	var parameters: Dictionary = command.get("parameters", {})
	var radius := clampf(
		float(
			parameters.get(
				"radius",
				IndustryArchetypeProfile.hand_drill_carve_radius_m()
			)
		),
		0.05,
		4.0
	)
	var direction := InteractionHit.aim_direction_from(target).normalized()
	var contact_point := Vector3(target["point"])
	var bite_center := contact_point - direction * (
		radius - IndustryArchetypeProfile.hand_drill_bite_depth_m()
	)
	var sdf_scale := IndustryArchetypeProfile.hand_drill_sdf_scale()
	# Clear the throat first: shove any loose out of the bit's cylinder so a dust
	# cover cannot stall the cut. Collects nothing — the parted spoil stays in the
	# world, ringed on the rim, and the carve below reaches the rock underneath.
	_plow_hand_drill_loose(gateway, contact_point, radius)
	var total_removed_m3 := 0.0
	var now_msec := Time.get_ticks_msec()
	# Coop replay must not path-sweep from local wall-clock / last-bite state:
	# join catch-up and live ops arrive back-to-back, which would over-carve
	# vs the host. Host already stamped the final sphere(s) it chose.
	var use_path_sweep := false
	if not gateway._replaying_remote_dig and gateway._hand_drill_last_bite_center is Vector3:
		var span_m: float = bite_center.distance_to(
			gateway._hand_drill_last_bite_center as Vector3
		)
		var gap_ms: int = now_msec - gateway._hand_drill_last_bite_msec
		use_path_sweep = (
			span_m > 0.0001
			and span_m <= IndustryArchetypeProfile.hand_drill_path_max_span_m()
			and gap_ms <= IndustryArchetypeProfile.hand_drill_path_max_gap_ms()
		)
	if use_path_sweep:
		# do_path trips a VoxelDataGrid assert in the pinned godot_voxel
		# build (is_valid_block_position), so sweep the gap with
		# overlapping sphere bites instead.
		var last_center: Vector3 = gateway._hand_drill_last_bite_center as Vector3
		var span := bite_center - last_center
		var step := maxf(radius * 0.5, 0.01)
		var count := clampi(ceili(span.length() / step), 1, 8)
		for index: int in range(count):
			var sweep: Dictionary = gateway._excavation.excavate(
				gateway._voxel_tool,
				{
					"stamp_kind": &"sphere",
					"terrain": gateway._terrain,
					"center": last_center + span * (
						float(index + 1) / float(count)
					),
					"radius": radius,
					"sdf_scale": sdf_scale,
				}
			)
			total_removed_m3 += float(sweep["removed_volume_m3"])
	var excavation: Dictionary = gateway._excavation.excavate(
		gateway._voxel_tool,
		{
			"stamp_kind": &"sphere",
			"terrain": gateway._terrain,
			"center": bite_center,
			"radius": radius,
			"sdf_scale": sdf_scale,
		}
	)
	total_removed_m3 += float(excavation["removed_volume_m3"])
	if total_removed_m3 > 0.000001:
		gateway._hand_drill_last_bite_center = bite_center
		gateway._hand_drill_last_bite_msec = now_msec
		_notify_terrain_modified(gateway, total_removed_m3, bite_center, radius, direction)
		if not gateway._replaying_remote_dig:
			_maybe_separate_floating_chunks(gateway, bite_center, total_removed_m3, radius)
	else:
		gateway._hand_drill_last_bite_center = null
	var removed_m3 := total_removed_m3
	# Excavation mode discards the yield: rock is cleared but nothing is mined.
	var discard_yield := bool(parameters.get("discard_yield", false))
	if removed_m3 > 0.000001 and not discard_yield:
		var material_id: String = gateway._material_field.material_id_at_world(
			contact_point,
			gateway._hand_drill_spawn_world
		)
		_route_hand_drill_yield(gateway, 
			contact_point,
			gateway._material_source.yield_for_excavation(
				removed_m3,
				{material_id: 1.0}
			)
		)
	# Path-sweep can remove volume even if the last bite hits a block that has
	# not streamed to LOD0 yet (`terrain_unavailable`). Report success whenever
	# anything was carved so the HUD does not flash a false failure.
	var status := StringName(excavation["status"])
	if removed_m3 > 0.000001:
		status = &"ok"
	return gateway._result(
		status,
		{
			"point": target["point"],
			"removed_volume_m3": removed_m3,
		}
	)
## Shove loose material out of the bit's cylinder without collecting any. The
## drill parts what it meets and mines rock only, so the parted spoil stays in
## the world (ringed on the rim by `plow_spoil`) rather than counting as yield.
## No-op when the scene has no volumetric granular world.
static func _plow_hand_drill_loose(gateway, world_point: Vector3, radius_m: float) -> void:
	if radius_m <= 0.0:
		return
	var granular: Node = _granular_world(gateway)
	if granular == null or not granular.has_method(&"plow_spoil"):
		return
	granular.call(&"plow_spoil", world_point, radius_m, HAND_DRILL_PLOW_SHARE)
## Retired: the drill no longer scoops loose material (see `_remove_voxel`, which
## now parts spoil aside and cuts the rock behind it). Kept, not deleted, so the
## dig-a-heap-of-spoil path is one wiring change away if a future tool wants it.
## Drill a heap of loose material. Digging spoil moves thickness on a
## `GranularPatch` instead of carving the SDF — the rock underneath is
## untouched — but it yields the same regolith, so clearing your own spoil is
## a way to recover it rather than a dead end.
static func _remove_granular(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	# Found by group and called by name rather than by type: the height-field
	# implementation and the volumetric one both answer `dig_spoil`, and which
	# is live is a scene decision, not this node's business.
	var granular: Node = gateway.get_tree().get_first_node_in_group(&"granular_world")
	if granular == null or not granular.has_method(&"dig_spoil"):
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var radius := clampf(
		float(
			parameters.get(
				"radius",
				IndustryArchetypeProfile.hand_drill_carve_radius_m()
			)
		),
		0.05,
		4.0
	)
	var contact_point := Vector3(target["point"])
	var removed_m3 := float(granular.call(&"dig_spoil", contact_point, radius))
	if removed_m3 <= 0.000001:
		return gateway._result(&"no_target", {"point": contact_point})
	# Excavation mode discards the yield: spoil is cleared but nothing is mined.
	if not bool(parameters.get("discard_yield", false)):
		var material_id: String = gateway._material_field.material_id_at_world(
			contact_point,
			gateway._hand_drill_spawn_world
		)
		_route_hand_drill_yield(gateway, 
			contact_point,
			gateway._material_source.yield_for_excavation(removed_m3, {material_id: 1.0})
		)
	return gateway._result(
		&"ok",
		{"point": contact_point, "removed_volume_m3": removed_m3}
	)
## Fill a carried scoop from a heap. Reports the volume taken so the tool can
## add it to its load; the world has no record of it after this, so a caller
## that drops the number drops the material.
##
## No yield is credited: a scoop moves material around the world rather than
## into a store. Loading it into cargo is a separate mechanism and a separate
## decision.
static func _scoop_spoil(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var granular: Node = gateway.get_tree().get_first_node_in_group(&"granular_world")
	if granular == null or not granular.has_method(&"scoop_spoil"):
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var radius := clampf(float(parameters.get("radius", 0.5)), 0.05, 2.0)
	var capacity := maxf(float(parameters.get("max_volume_m3", 0.0)), 0.0)
	if capacity <= 0.000001:
		return gateway._result(&"no_capacity", {"scooped_volume_m3": 0.0})
	var contact_point := Vector3(target["point"])
	var taken := float(
		granular.call(&"scoop_spoil", contact_point, radius, capacity)
	)
	if taken <= 0.000001:
		return gateway._result(&"no_target", {"point": contact_point})
	return gateway._result(
		&"ok",
		{"point": contact_point, "scooped_volume_m3": taken}
	)
## Tip a carried load back out. Reports what the world accepted — the caller
## keeps the remainder in the tool rather than treating the dump as complete,
## or the shortfall is volume destroyed.
static func _dump_scoop(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var granular: Node = gateway.get_tree().get_first_node_in_group(&"granular_world")
	if granular == null or not granular.has_method(&"dump_load"):
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var volume := maxf(float(parameters.get("volume_m3", 0.0)), 0.0)
	if volume <= 0.000001:
		return gateway._result(&"no_target", {"dumped_volume_m3": 0.0})
	var contact_point := Vector3(target["point"])
	var accepted := float(granular.call(&"dump_load", contact_point, volume))
	return gateway._result(
		&"ok",
		{"point": contact_point, "dumped_volume_m3": accepted}
	)
## Debug: conjure loose material at the aim point, out of nothing.
##
## Loose material otherwise only exists where something dug or dumped, so a fresh
## world has nothing for a blade or a scoop to work — and getting a heap the
## honest way means standing there with the drill first. This is a test fixture,
## not a mechanic: it credits no yield and costs nothing, and no gameplay path
## reaches it.
static func _debug_spawn_spoil(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var granular: Node = gateway.get_tree().get_first_node_in_group(&"granular_world")
	if granular == null or not granular.has_method(&"dump_load"):
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var volume := maxf(float(parameters.get("volume_m3", 0.0)), 0.0)
	if volume <= 0.000001:
		return gateway._result(&"no_target", {"spawned_volume_m3": 0.0})
	var contact_point := Vector3(target["point"])
	var accepted := float(granular.call(&"dump_load", contact_point, volume))
	return gateway._result(
		&"ok",
		{"point": contact_point, "spawned_volume_m3": accepted}
	)

static func _dig_terrain_debris(gateway, 
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if StringName(target.get("target_kind", &"")) != InteractionHit.KIND_TERRAIN_DEBRIS:
		return gateway._result(&"invalid_target")
	var body := target.get("collider") as RigidBody3D
	if body == null or not is_instance_valid(body):
		return gateway._result(&"no_target")
	if not body.is_in_group(&"terrain_floating_debris"):
		return gateway._result(&"invalid_target")
	var dig_hp := float(body.get_meta(&"dig_hp", body.mass))
	var dig_hp_max := float(body.get_meta(&"dig_hp_max", maxf(body.mass, 1.0)))
	var dig_mass_kg := float(body.get_meta(&"dig_mass_kg", body.mass))
	if dig_hp_max <= 0.0001:
		dig_hp_max = 1.0
	# One turbo bite ≈ 25–40% of a typical chunk; small rocks die in 1–2 ticks.
	var damage := maxf(dig_hp_max * 0.35, dig_hp_max * 0.08)
	var removed_frac := minf(damage, dig_hp) / dig_hp_max
	dig_hp = maxf(dig_hp - damage, 0.0)
	body.set_meta(&"dig_hp", dig_hp)
	var contact := Vector3(target.get("point", body.global_position))
	var removed_mass := dig_mass_kg * removed_frac
	if removed_mass > 0.000001:
		# Map mass→volume with regolith density proxy so yield path stays shared.
		var removed_m3 := removed_mass / 1600.0
		var material_id: String = gateway._material_field.material_id_at_world(
			contact,
			gateway._hand_drill_spawn_world
		)
		_route_hand_drill_yield(gateway, 
			contact,
			gateway._material_source.yield_for_excavation(
				removed_m3,
				{material_id: 1.0}
			)
		)
	if dig_hp > 0.0001:
		var scale_t := clampf(dig_hp / dig_hp_max, 0.35, 1.0)
		body.scale = Vector3.ONE * scale_t
		body.mass = maxf(dig_mass_kg * scale_t, 4.0)
		body.sleeping = false
		body.apply_central_impulse(
			-Vector3(target.get("normal", Vector3.UP)).normalized() * (8.0 + damage)
		)
		return gateway._result(&"ok", {"point": contact, "dig_hp": dig_hp})
	body.queue_free()
	return gateway._result(&"ok", {"point": contact, "destroyed": true})
## Drop what the drill freed on the ground. Nothing goes straight into the
## pack: what you dug by hand you pick up by hand, so carrying capacity is a
## decision you make at the working face rather than a silent cap that turns
## into litter the moment it is reached.
##
## A bite is ~0.1 m³ every 0.15 s, so one pile per bite left a trail of small
## ones down the tunnel. Mass waits in `_hand_drill_yield_buffer` until it is
## worth a discrete object instead.
static func _route_hand_drill_yield(gateway, 
	center: Vector3,
	yields: Array[Dictionary]
) -> void:
	if gateway._session == null or gateway._session.world == null:
		return
	for yield_entry: Dictionary in yields:
		var resource_id := String(yield_entry.get("resource_id", ""))
		var mass_kg := float(yield_entry.get("mass_kg", 0.0))
		if resource_id.is_empty() or mass_kg <= 0.000001:
			continue
		var pending := mass_kg + float(
			gateway._hand_drill_yield_buffer.get(resource_id, 0.0)
		)
		var quantum_kg: float = _hand_drill_emit_quantum_kg(gateway, resource_id)
		if quantum_kg <= 0.000001:
			# Nothing to quantise by — a resource with no mass or volume per
			# unit. Drop it rather than accumulate it forever.
			gateway._session.world.add_world_loot_pile(center, resource_id, pending)
			pending = 0.0
		else:
			while pending >= quantum_kg:
				gateway._session.world.add_world_loot_pile(
					center,
					resource_id,
					quantum_kg
				)
				pending -= quantum_kg
		gateway._hand_drill_yield_buffer[resource_id] = pending
## Mass of `resource_id` that has to accumulate before a chunk drops. The
## balance value is a volume, so chunks are a consistent size on the ground;
## this converts it with the resource's own density.
static func _hand_drill_emit_quantum_kg(gateway, resource_id: String) -> float:
	var unit_volume_l := ResourceCatalog.volume_per_unit_l(resource_id)
	var unit_mass_kg := ResourceCatalog.mass_per_unit_kg(resource_id)
	if unit_volume_l <= 0.000001 or unit_mass_kg <= 0.000001:
		return 0.0
	return (
		IndustryArchetypeProfile.hand_drill_loot_emit_volume_l()
		* unit_mass_kg
		/ unit_volume_l
	)

static func apply_terrain_carve(gateway, 
	op: Dictionary,
	volume_budget_m3: float = INF
) -> float:
	if gateway._voxel_tool == null or gateway._excavation == null or gateway._terrain == null:
		push_warning("WorldCommandGateway.apply_terrain_carve: not ready")
		return 0.0
	var request := op.duplicate(true)
	request["terrain"] = gateway._terrain
	request["volume_budget_m3"] = volume_budget_m3
	if not request.has("sdf_scale"):
		request["sdf_scale"] = TerrainExcavationService.DEFAULT_SDF_SCALE
	var removed := float(
		gateway._excavation.excavate(gateway._voxel_tool, request).get("removed_volume_m3", 0.0)
	)
	if removed > 0.000001:
		var dig_center: Vector3 = _dig_center_from_request(gateway, request)
		var dig_radius: float = _dig_radius_from_request(gateway, request)
		_notify_terrain_modified(gateway, removed, dig_center, dig_radius)
		_maybe_separate_floating_chunks(gateway, dig_center, removed, dig_radius)
	return removed

static func _dig_center_from_request(gateway, request: Dictionary) -> Vector3:
	match StringName(request.get("stamp_kind", &"sphere")):
		&"path":
			var points: PackedVector3Array = request.get("points", PackedVector3Array())
			if points.is_empty():
				return Vector3.ZERO
			return points[points.size() - 1]
		_:
			return request.get("center", Vector3.ZERO)

static func _dig_radius_from_request(gateway, request: Dictionary) -> float:
	match StringName(request.get("stamp_kind", &"sphere")):
		&"path":
			var radii: PackedFloat32Array = request.get("radii", PackedFloat32Array())
			if radii.is_empty():
				return 0.0
			return float(radii[radii.size() - 1])
		_:
			return float(request.get("radius", 0.0))
## Announce that loose material was sintered into the rock SDF, so the dig
## stream is marked dirty and the new solid persists. Does *not* touch
## `terrain_modified` — see that signal's note. The granular world writes the
## SDF itself (it owns the tool); this is only the persistence hand-off.
static func mark_terrain_deposited(gateway, 
	deposit_center: Vector3 = Vector3.ZERO,
	deposit_radius_m: float = 0.0
) -> void:
	gateway.terrain_deposited.emit(deposit_center, deposit_radius_m)

static func _notify_terrain_modified(gateway, 
	removed_volume_m3: float,
	dig_center: Vector3 = Vector3.ZERO,
	dig_radius_m: float = 0.0,
	dig_direction: Vector3 = Vector3.ZERO
) -> void:
	gateway.terrain_modified.emit(
		removed_volume_m3, dig_center, dig_radius_m, dig_direction
	)
	# A frozen parked rover must re-settle if the ground under it is dug away.
	if gateway._session != null and gateway._session.projection != null and dig_radius_m > 0.0:
		gateway._session.projection.wake_frozen_near(dig_center, dig_radius_m)

static func stationary_drill_has_terrain_contact(gateway, element_id: int) -> bool:
	return not _stationary_drill_contact(gateway, element_id).is_empty()
## World-space point the drill's last carve worked, for material sampling. The
## drill service calls this straight after `carve_stationary_drill`, so the
## cached centre is the one it just cut. Falls back to a fresh contact resolve
## when nothing is cached yet (first tick / cache miss).
static func stationary_drill_carve_point(gateway, element_id: int) -> Vector3:
	if gateway._stationary_drill_carve_points.has(element_id):
		return gateway._stationary_drill_carve_points[element_id]
	var contact: Dictionary = _stationary_drill_contact(gateway, element_id)
	if contact.is_empty():
		return Vector3.ZERO
	var radius := IndustryArchetypeProfile.drill_carve_radius_m()
	var direction: Vector3 = contact["direction"]
	return (
		contact["point"]
		+ direction
		* radius
		* IndustryArchetypeProfile.drill_carve_center_offset_factor()
	)

static func carve_stationary_drill(gateway, element_id: int) -> float:
	var contact: Dictionary = _stationary_drill_contact(gateway, element_id)
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
	# Remember where this bit is cutting so `stationary_drill_carve_point` can
	# report it back for material sampling — without it the drill service reads
	# the material at the world origin and only ever yields mare regolith.
	gateway._stationary_drill_carve_points[element_id] = center
	var removed := float(
		gateway._excavation.excavate(
			gateway._voxel_tool,
			{
				"stamp_kind": &"sphere",
				"terrain": gateway._terrain,
				"center": center,
				"radius": radius,
				"sdf_scale": IndustryArchetypeProfile.hand_drill_sdf_scale(),
			}
		).get("removed_volume_m3", 0.0)
	)
	if removed > 0.000001:
		_notify_terrain_modified(gateway, removed, center, radius, direction)
		_maybe_separate_floating_chunks(gateway, center, removed, radius)
	return removed

static func _maybe_separate_floating_chunks(gateway, 
	world_center: Vector3,
	removed_m3: float,
	dig_radius_m: float
) -> void:
	var spawned: int = gateway._floating_debris.try_separate_after_dig(
		gateway._terrain,
		gateway._voxel_tool,
		world_center,
		removed_m3,
		_ensure_floating_debris_parent(gateway)
	)
	if spawned <= 0:
		return
	# Separation edits SDF again — mark dig stream dirty for persistence.
	_notify_terrain_modified(gateway, 0.0, world_center, dig_radius_m)

static func _ensure_floating_debris_parent(gateway) -> Node3D:
	if gateway._floating_debris_parent != null and is_instance_valid(gateway._floating_debris_parent):
		return gateway._floating_debris_parent
	gateway._floating_debris_parent = Node3D.new()
	gateway._floating_debris_parent.name = "TerrainFloatingDebris"
	var host: Node = gateway.get_parent()
	if host == null:
		host = gateway
	host.add_child(gateway._floating_debris_parent)
	return gateway._floating_debris_parent

static func _stationary_drill_contact(gateway, element_id: int) -> Dictionary:
	if gateway._session == null or gateway._session.world == null or gateway._voxel_tool == null:
		return {}
	var element: SimulationElement = gateway._session.world.get_element(element_id)
	if element == null or element.archetype_id != "stationary_drill":
		return {}
	var working_frame: Transform3D = _stationary_drill_working_frame(gateway, element)
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
	var sdf_hit: Dictionary = _stationary_drill_sdf_contact_along_axis(gateway, tip, direction)
	if not sdf_hit.is_empty():
		return sdf_hit
	var probe_start := tip - direction * 0.08
	var reach := IndustryArchetypeProfile.drill_contact_reach_m() + 0.08
	var physics_hit := TerrainAnchorProbe.raycast_terrain(
		gateway._physics_space_state(),
		gateway._terrain,
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
		gateway._physics_space_state(),
		gateway._terrain,
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
		gateway._voxel_tool,
		gateway._terrain,
		probe_start,
		direction,
		reach
	)
	if hit == null:
		return {}
	return {
		"point": VoxelSpaceUtil.raycast_hit_world_point(
			gateway._terrain,
			probe_start,
			direction,
			hit
		),
		"direction": direction,
	}

static func _stationary_drill_working_frame(gateway, element: SimulationElement) -> Transform3D:
	var body: PhysicsBody3D = _stationary_drill_physics_body(gateway, element)
	if body != null:
		return body.global_transform
	if gateway._session == null or gateway._session.world == null or element == null:
		return Transform3D.IDENTITY
	return gateway._session.world.element_group_transform(element.element_id)

static func _stationary_drill_physics_body(gateway, 
	element: SimulationElement
) -> PhysicsBody3D:
	if gateway._session == null or gateway._session.projection == null:
		return null
	var record: Dictionary = gateway._session.projection.get_element_projection(
		element.element_id
	)
	return record.get("body") as PhysicsBody3D

static func _stationary_drill_sdf_contact_along_axis(gateway, 
	tip: Vector3,
	direction: Vector3
) -> Dictionary:
	var axis := direction.normalized()
	for along_m: float in [0.0, -0.12, -0.25, 0.12, 0.25]:
		var sample := tip + axis * along_m
		var sample_cell: Vector3i = VoxelSpaceUtil.world_cell_from_point(
			gateway._terrain,
			sample
		)
		if (
			TerrainExcavationService.sdf_occupancy(
				gateway._voxel_tool.get_voxel_f(sample_cell)
			)
			> 0.0
		):
			return {"point": sample, "direction": direction}
	return {}
# --- Dozer blade (mounted) terrain hooks -------------------------------------
#
# A dozer blade works loose (granular) material only — it never touches the SDF
# rock. `DozerBladeService` runs in the simulation (no scene tree) and reaches
# the granular world through these gateway callables, the same shape as the
# stationary drill's carve hooks. Contact is probed against loose material in
# front of the blade's working edge (local +X, like the drill).

# --- Dozer blade (mounted) terrain hooks -------------------------------------
#
# A dozer blade works loose (granular) material only — it never touches the SDF
# rock. `DozerBladeService` runs in the simulation (no scene tree) and reaches
# the granular world through these gateway callables, the same shape as the
# stationary drill's carve hooks. Contact is probed against loose material in
# front of the blade's working edge (local +X, like the drill).

static func _granular_world(gateway) -> Node:
	return gateway.get_tree().get_first_node_in_group(&"granular_world")

static func dozer_blade_has_terrain_contact(gateway, element_id: int) -> bool:
	return not _dozer_blade_contact(gateway, element_id).is_empty()
## World point the blade last worked, for material sampling. Falls back to a
## fresh contact resolve when nothing is cached (first tick / cache miss).
static func dozer_blade_contact_point(gateway, element_id: int) -> Vector3:
	if gateway._dozer_blade_contact_points.has(element_id):
		return gateway._dozer_blade_contact_points[element_id]
	var contact: Dictionary = _dozer_blade_contact(gateway, element_id)
	if contact.is_empty():
		return Vector3.ZERO
	return contact["point"]
## Load up to `budget_m3` of loose material under the blade into the tool,
## returning the volume actually taken. The world loses that volume here; the
## service credits it as yield.
static func dozer_blade_load(gateway, element_id: int, budget_m3: float) -> float:
	var granular: Node = _granular_world(gateway)
	if granular == null or not granular.has_method(&"scoop_spoil"):
		return 0.0
	var contact: Dictionary = _dozer_blade_contact(gateway, element_id)
	if contact.is_empty():
		return 0.0
	var point: Vector3 = contact["point"]
	gateway._dozer_blade_contact_points[element_id] = point
	var radius := IndustryArchetypeProfile.dozer_blade_push_radius_m()
	return float(
		granular.call(&"scoop_spoil", point, radius, maxf(budget_m3, 0.0))
	)
## Shove loose material aside without collecting any (buffer full). Returns the
## volume moved; it stays in the world.
static func dozer_blade_plow(gateway, element_id: int) -> float:
	var granular: Node = _granular_world(gateway)
	if granular == null or not granular.has_method(&"plow_spoil"):
		return 0.0
	var contact: Dictionary = _dozer_blade_contact(gateway, element_id)
	if contact.is_empty():
		return 0.0
	var point: Vector3 = contact["point"]
	gateway._dozer_blade_contact_points[element_id] = point
	var radius := IndustryArchetypeProfile.dozer_blade_push_radius_m()
	var share := IndustryArchetypeProfile.dozer_blade_push_share()
	return float(granular.call(&"plow_spoil", point, radius, share))

static func _dozer_blade_contact(gateway, element_id: int) -> Dictionary:
	if gateway._session == null or gateway._session.world == null:
		return {}
	var element: SimulationElement = gateway._session.world.get_element(element_id)
	if element == null or element.archetype_id != "dozer_blade":
		return {}
	var granular: Node = _granular_world(gateway)
	if granular == null or not granular.has_method(&"raycast_dust"):
		return {}
	var working_frame: Transform3D = _stationary_drill_working_frame(gateway, element)
	if working_frame == Transform3D.IDENTITY:
		return {}
	# Authored working face is local +X — presentation and the drill share it.
	var local_direction := OrientationUtil.rotate_direction(
		Vector3i.RIGHT,
		element.orientation_index
	)
	# A blade works the material under its cutting edge, not the air in front of
	# its middle. Drop the probe to the edge and tilt it down, or it only ever
	# registers a heap standing taller than half the blade — and drops it again
	# the moment the rover climbs its own spoil.
	var local_down := OrientationUtil.rotate_direction(
		Vector3i.DOWN,
		element.orientation_index
	)
	var forward := (
		working_frame.basis * Vector3(local_direction)
	).normalized()
	var down := (working_frame.basis * Vector3(local_down)).normalized()
	var pitch := deg_to_rad(
		IndustryArchetypeProfile.dozer_blade_probe_pitch_deg()
	)
	var direction := (forward * cos(pitch) + down * sin(pitch)).normalized()
	var local_tip := (
		GridPoseUtil.oriented_footprint_pivot(
			element.get_archetype(),
			element.origin_cell,
			element.orientation_index
		)
		+ Vector3(local_direction)
		* IndustryArchetypeProfile.dozer_blade_head_offset_m()
		+ Vector3(local_down)
		* IndustryArchetypeProfile.dozer_blade_edge_drop_m()
	)
	var tip := working_frame * local_tip
	var reach := IndustryArchetypeProfile.dozer_blade_contact_reach_m()
	var hit: Dictionary = granular.call(
		&"raycast_dust",
		tip - direction * 0.1,
		direction,
		reach + 0.1
	)
	if hit.is_empty():
		return {}
	return {"point": hit["point"], "direction": direction}
