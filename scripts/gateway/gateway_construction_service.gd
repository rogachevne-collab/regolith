class_name GatewayConstructionService
extends RefCounted

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

static func _place_block(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var source: Node3D = command.get("source") as Node3D
	if source == null:
		return gateway._result(&"not_ready")
	var cell: Vector3i = gateway._placed_blocks.call(
		"placement_cell_from_hit",
		Vector3(target["point"]),
		Vector3(target["normal"])
	) as Vector3i
	if not gateway._placed_blocks.call("try_place", cell, source):
		return gateway._result(&"blocked", {"cell": cell})
	return gateway._result(&"ok", {"cell": cell})

static func preview_construction(gateway, 
	target: Dictionary,
	archetype_id: String,
	orientation_index: int,
	held_ground_pivot: Vector3 = Vector3(INF, INF, INF),
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Dictionary:
	if gateway._session == null:
		return {
			"valid": false,
			"reason": &"not_ready",
		}
	var archetype: ElementArchetype = gateway._get_archetype(archetype_id)
	return _guard_placement_collision(gateway, 
		_seat_ground_plan(gateway, 
			ConstructionPlacement.plan(
				gateway._session.world,
				target,
				archetype,
				orientation_index,
				PlayerIdentity.store_id(gateway.actor_uid),
				held_ground_pivot,
				held_attach_pivot
			)
		)
	)

static func baseline_ground_pivot(gateway, 
	target: Dictionary,
	archetype_id: String
) -> Vector3:
	if gateway._session == null:
		return Vector3(INF, INF, INF)
	return ConstructionPlacement.baseline_ground_pivot(
		gateway._session.world,
		target,
		gateway._get_archetype(archetype_id),
		PlayerIdentity.store_id(gateway.actor_uid)
	)

static func resolve_construction_placement(gateway, params: Dictionary) -> Dictionary:
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
	if gateway._session == null:
		var plan: Dictionary = preview_construction(gateway, 
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
	# No result cache here: ConstructionPreview already reuses results via its
	# quantized context key, and deep-copying the resolve payload every physics
	# frame cost more than it saved.
	var archetype: ElementArchetype = gateway._get_archetype(archetype_id)
	var t_snap := ConstructionPerf.begin()
	var result: Dictionary = gateway._snap_resolver.resolve({
		"world": gateway._session.world,
		"archetype": archetype,
		"orientation_index": orientation_index,
		"store_id": PlayerIdentity.store_id(gateway.actor_uid),
		"ray_origin": params.get("ray_origin", Vector3.ZERO),
		"ray_direction": params.get("ray_direction", Vector3.FORWARD),
		"camera": params.get("camera"),
		"direct_hit": direct_hit,
		"manual_candidate_index": manual_index,
		"held_ground_pivot": held_ground_pivot,
		"held_attach_pivot": held_attach_pivot,
	})
	var snap_us := ConstructionPerf.end(&"snap_us", t_snap)
	var t_seat := ConstructionPerf.begin()
	var seated: Dictionary = _seat_ground_plan(gateway, result.get("selected_plan", {}))
	var seat_us := ConstructionPerf.end(&"seat_us", t_seat)
	var t_collision := ConstructionPerf.begin()
	result["selected_plan"] = _guard_placement_collision(gateway, seated)
	var collision_us := ConstructionPerf.end(&"collision_us", t_collision)
	var stats: Dictionary = result.get("stats", {})
	stats["snap_us"] = snap_us
	stats["seat_us"] = seat_us
	stats["collision_us"] = collision_us
	result["stats"] = stats
	return result
## Cheap staleness token for preview resolve reuse: any structural mutation
## bumps it. Motion/parking flips are covered by the preview's resolve
## heartbeat, not by this counter.
static func snap_context_revision(gateway) -> int:
	if gateway._session == null or gateway._session.world == null:
		return 0
	return gateway._session.world.topology_generation

static func snap_resolve_stats(gateway) -> Dictionary:
	var stats: Dictionary = gateway._snap_resolver.last_stats.duplicate(true)
	stats.merge(ConstructionPerf.last_stats_timings())
	return stats

static func reset_construction_snap(gateway) -> void:
	gateway._snap_resolver.reset_sticky()

static func _construction_apply(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return _place_block(gateway, command, target)
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
			return _apply_place_plan(gateway, placement_plan)
		return gateway._result(
			gateway._map_structural_reason(
				StringName(placement_plan.get("reason", &"invalid_target"))
			),
			placement_plan.get("data", {})
		)

	if target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		var element: SimulationElement = gateway._session.world.get_element(
			InteractionHit.element_id_from(target)
		)
		if element == null:
			return gateway._result(&"invalid_target")
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
			repair.store_id = PlayerIdentity.store_id(gateway.actor_uid)
			repair.max_material_amount = 1.0
			return gateway._structural_result(
				gateway._session.world.apply_structural_command_now(repair)
			)
		var place_plan: Dictionary = preview_construction(gateway, 
			target,
			archetype_id,
			orientation_index
		)
		if bool(place_plan.get("valid", false)):
			return _apply_place_plan(gateway, place_plan)
		if construction_mode == &"repair":
			return gateway._result(&"not_damaged")
		return gateway._result(
			gateway._map_structural_reason(
				StringName(place_plan.get("reason", &"invalid_target"))
			),
			place_plan.get("data", {})
		)

	var plan: Dictionary = preview_construction(gateway, 
		target,
		archetype_id,
		orientation_index
	)
	if not bool(plan.get("valid", false)):
		return gateway._result(
			gateway._map_structural_reason(
				StringName(plan.get("reason", &"invalid_target"))
			),
			plan.get("data", {})
		)
	return _apply_place_plan(gateway, plan)

static func _weld_element(gateway, 
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		gateway._session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return gateway._result(&"invalid_target")
	var element: SimulationElement = gateway._session.world.get_element(
		InteractionHit.element_id_from(target)
	)
	if element == null:
		return gateway._result(&"invalid_target")
	if element.is_complete():
		return gateway._result(&"already_complete")
	if element.is_broken():
		return gateway._result(&"element_broken")
	var weld := WeldElementCommand.new()
	weld.element_id = element.element_id
	weld.expected_state_revision = element.state_revision
	weld.store_id = PlayerIdentity.store_id(gateway.actor_uid)
	weld.max_material_amount = 1.0
	return gateway._structural_result(
		gateway._session.world.apply_structural_command_now(weld)
	)

static func _apply_place_plan(gateway, plan: Dictionary) -> Dictionary:
	# Authoritative re-check: the plan was validated at preview time, but a
	# dynamic assembly or the player may have moved into the footprint since. The
	# grid kernel cannot see either, so the physics guard runs once more here
	# before the placement is committed.
	var guarded: Dictionary = _guard_placement_collision(gateway, plan)
	if not bool(guarded.get("valid", false)):
		return gateway._result(
			gateway._map_structural_reason(
				StringName(guarded.get("reason", &"invalid_target"))
			),
			guarded.get("data", {})
		)
	var place := guarded.get("command") as PlaceElementCommand
	# The plan was built client-side, so its owner is a suggestion. Re-stamp it:
	# a peer must not be able to spend someone else's materials by sending a
	# plan that names their store.
	place.store_id = PlayerIdentity.store_id(gateway.actor_uid)
	var result: StructuralCommandResult = gateway._session.world.apply_structural_command_now(place)
	return gateway._structural_result(result)
## Reseats a first-on-ground placement so its footprint rests on the lowest
## terrain sample beneath it along Field down. Only shifts the continuous root;
## the discrete grid frame (topology) is untouched. Non-ground plans (attaching
## to an existing assembly) and invalid plans pass through unchanged.
static func _seat_ground_plan(gateway, plan: Dictionary) -> Dictionary:
	if gateway._voxel_tool == null or not bool(plan.get("valid", false)):
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
	# Exact oriented corners, not a world-axis AABB: on a radial field the
	# block basis is tilted against world axes, an axis-aligned AABB inflates
	# downward and the block seats on a phantom corner — floating above the
	# ground by the inflation amount. Corner support is exact for any tilt.
	var corners := PackedVector3Array()
	var center := Vector3.ZERO
	for collider: ColliderDefinition in archetype.colliders:
		var collider_transform := GridPoseUtil.collider_world_transform(
			root, origin_cell, orientation_index, collider
		)
		var half: Vector3 = collider.aabb_half_extents()
		for sx: int in [-1, 1]:
			for sy: int in [-1, 1]:
				for sz: int in [-1, 1]:
					var corner: Vector3 = collider_transform * Vector3(
						half.x * sx,
						half.y * sy,
						half.z * sz
					)
					corners.append(corner)
					center += corner
	if corners.is_empty():
		return plan
	center /= float(corners.size())
	var up: Vector3 = GravityField.resolve_up(gateway, center)
	var down := -up
	var field: GravityField = GravityField.find_in_tree(gateway)
	var frame: Basis = (
		field.tangent_basis_at(center)
		if field != null
		else Basis.looking_at(Vector3.FORWARD, Vector3.UP)
	)
	var bottom_along_up := INF
	var top_along_up := -INF
	var extent_x := 0.0
	var extent_z := 0.0
	for corner: Vector3 in corners:
		bottom_along_up = minf(bottom_along_up, corner.dot(up))
		top_along_up = maxf(top_along_up, corner.dot(up))
		extent_x = maxf(extent_x, absf((corner - center).dot(frame.x)))
		extent_z = maxf(extent_z, absf((corner - center).dot(frame.z)))
	var probe_top := top_along_up + 1.0
	var probe_distance := probe_top - bottom_along_up + 4.0
	var lowest_along_up := INF
	for sample: Vector2 in _GROUND_SEAT_SAMPLES:
		var sample_point := (
			center
			+ frame.x * (sample.x * extent_x)
			+ frame.z * (sample.y * extent_z)
		)
		var probe_from := (
			sample_point
			+ up * (probe_top - sample_point.dot(up))
		)
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			gateway._physics_space_state(),
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
			gateway._voxel_tool,
			gateway._terrain,
			probe_from,
			down,
			probe_distance
		)
		if hit == null:
			continue
		var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
			gateway._terrain,
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
## Rejects a valid placement plan when its final world pose clips another
## construction, the player, or (for physical elements) terrain — the world-space
## checks the grid kernel cannot make. Invalid plans and plans without physics
## context pass through untouched.
static func _guard_placement_collision(gateway, plan: Dictionary) -> Dictionary:
	if not bool(plan.get("valid", false)):
		return plan
	var space_state: PhysicsDirectSpaceState3D = gateway._physics_space_state()
	if space_state == null:
		return plan
	var archetype := plan.get("archetype") as ElementArchetype
	var command := plan.get("command") as PlaceElementCommand
	if archetype == null or command == null:
		return plan
	var root: Transform3D = plan.get(
		"preview_root_transform",
		plan.get("assembly_world_transform", Transform3D.IDENTITY)
	)
	var reason := ConstructionPlacementCollision.evaluate(
		space_state,
		archetype,
		root,
		command.origin_cell,
		command.orientation_index,
		command.assembly_id,
		gateway._terrain
	)
	if reason == &"":
		return plan
	var blocked := plan.duplicate()
	blocked["valid"] = false
	blocked["reason"] = reason
	return blocked

static func _dismantle_element(gateway, 
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		gateway._session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return gateway._result(&"invalid_target")
	var element: SimulationElement = gateway._session.world.get_element(
		InteractionHit.element_id_from(target)
	)
	if element == null:
		return gateway._result(&"invalid_target")
	var assembly: SimulationAssembly = gateway._session.world.get_assembly(element.assembly_id)
	if assembly == null:
		return gateway._result(&"invalid_target")
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = element.element_id
	dismantle.expected_assembly_revision = assembly.topology_revision
	dismantle.store_id = PlayerIdentity.store_id(gateway.actor_uid)
	return gateway._structural_result(
		gateway._session.world.apply_structural_command_now(dismantle)
	)
