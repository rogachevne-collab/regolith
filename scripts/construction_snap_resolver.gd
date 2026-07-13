class_name ConstructionSnapResolver
extends RefCounted

const MAX_CANDIDATES := 8
const TOP_K_VALIDATE := 12
const DIRECT_ELEMENT_SCORE := 1000.0
const VOXEL_FALLBACK_SCORE := 3.0
const HYSTERESIS_SCORE_BONUS := 0.12
const HYSTERESIS_BREAK_GAP := 0.18
const MAX_RAY_DISTANCE := 4.0
const MAX_RAY_LATERAL := 1.2
const MIN_FORWARD_DOT := 0.15
const MAX_SCREEN_PENALTY_RADIUS := 0.65

var last_stats: Dictionary = _empty_stats()

var _sticky_candidate_key: String = ""
var _face_cache: ConstructionSnapFaceCache


func bind_cache(cache: ConstructionSnapFaceCache) -> void:
	_face_cache = cache


func reset_sticky() -> void:
	_sticky_candidate_key = ""


func cycle_candidate(candidates: Array, current_index: int, direction: int = 1) -> int:
	if candidates.is_empty():
		return -1
	return posmod(current_index + direction, candidates.size())


func resolve(params: Dictionary) -> Dictionary:
	last_stats = _empty_stats()
	last_stats["resolve_calls"] = 1

	var world: SimulationWorld = params.get("world")
	var archetype: ElementArchetype = params.get("archetype")
	if world == null or archetype == null:
		return _empty_result()
	var orientation_index := int(params.get("orientation_index", 0))
	var store_id := str(params.get("store_id", "player"))
	var ray_origin: Vector3 = params.get("ray_origin", Vector3.ZERO)
	var ray_direction: Vector3 = Vector3(
		params.get("ray_direction", Vector3.FORWARD)
	).normalized()
	var camera: Camera3D = params.get("camera")
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
	if (
		manual_index < 0
		and bool(direct_hit.get("valid", false))
		and StringName(direct_hit.get("target_kind", &""))
		== InteractionHit.KIND_SIMULATION_ELEMENT
	):
		last_stats["plans_validated"] = 1
		var direct_plan := ConstructionPlacement.plan(
			world,
			direct_hit,
			archetype,
			orientation_index,
			store_id,
			held_ground_pivot,
			held_attach_pivot
		)
		var direct_command: PlaceElementCommand = direct_plan.get("command")
		if (
			bool(direct_plan.get("valid", false))
			and direct_command != null
			and direct_command.assembly_id != 0
		):
			var direct_candidate := _make_candidate(
				direct_hit,
				direct_plan,
				DIRECT_ELEMENT_SCORE,
				&"direct_element"
			)
			_sticky_candidate_key = str(direct_candidate["key"])
			return {
				"candidates": [direct_candidate],
				"selected_index": 0,
				"selected_target": direct_hit,
				"selected_plan": direct_plan,
				"sticky_key": _sticky_candidate_key,
				"stats": last_stats.duplicate(true),
			}

	if _face_cache != null:
		_face_cache.bind_world(world)
		last_stats["cache_rebuilt"] = _face_cache.ensure_current()
		last_stats["cache_rebuilds"] = _face_cache.cache_rebuilds
		last_stats["faces_in_cache"] = _face_cache.last_faces_in_cache
	else:
		last_stats["cache_rebuilt"] = true

	var candidates: Array[Dictionary] = []
	for candidate: Dictionary in _collect_face_candidates(
		world,
		archetype,
		orientation_index,
		store_id,
		ray_origin,
		ray_direction,
		camera,
		held_ground_pivot,
		held_attach_pivot
	):
		candidates.append(candidate)
		if candidates.size() >= MAX_CANDIDATES:
			break

	if bool(direct_hit.get("valid", false)):
		var direct_kind := StringName(direct_hit.get("target_kind", &""))
		if direct_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
			last_stats["plans_validated"] = (
				int(last_stats["plans_validated"]) + 1
			)
			var direct_plan := ConstructionPlacement.plan(
				world,
				direct_hit,
				archetype,
				orientation_index,
				store_id,
				held_ground_pivot,
				held_attach_pivot
			)
			var command: PlaceElementCommand = direct_plan.get("command")
			if (
				bool(direct_plan.get("valid", false))
				and command != null
				and command.assembly_id != 0
			):
				candidates.append(
					_make_candidate(
						direct_hit,
						direct_plan,
						DIRECT_ELEMENT_SCORE,
						&"direct_element"
					)
				)
		elif direct_kind == InteractionHit.KIND_VOXEL:
			last_stats["plans_validated"] = (
				int(last_stats["plans_validated"]) + 1
			)
			var voxel_plan := ConstructionPlacement.plan(
				world,
				direct_hit,
				archetype,
				orientation_index,
				store_id,
				held_ground_pivot,
				held_attach_pivot
			)
			if bool(voxel_plan.get("valid", false)):
				candidates.append(
					_make_candidate(
						direct_hit,
						voxel_plan,
						VOXEL_FALLBACK_SCORE,
						&"voxel_fallback"
					)
				)

	candidates.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return float(left["score"]) > float(right["score"])
	)
	if candidates.size() > MAX_CANDIDATES:
		candidates = candidates.slice(0, MAX_CANDIDATES)

	var selected_index := -1
	if manual_index >= 0 and manual_index < candidates.size():
		selected_index = manual_index
	elif not candidates.is_empty():
		selected_index = _apply_hysteresis(candidates)

	var selected: Dictionary = {}
	if selected_index >= 0 and selected_index < candidates.size():
		selected = candidates[selected_index]
		_sticky_candidate_key = str(selected.get("key", ""))

	return {
		"candidates": candidates,
		"selected_index": selected_index,
		"selected_target": selected.get("target", {}),
		"selected_plan": selected.get("plan", {}),
		"sticky_key": _sticky_candidate_key,
		"stats": last_stats.duplicate(true),
	}


static func _empty_stats() -> Dictionary:
	return {
		"resolve_calls": 0,
		"cache_rebuilds": 0,
		"cache_rebuilt": false,
		"faces_in_cache": 0,
		"faces_scanned": 0,
		"faces_corridor_pass": 0,
		"plans_validated": 0,
	}


static func _empty_result() -> Dictionary:
	return {
		"candidates": [],
		"selected_index": -1,
		"selected_target": {},
		"selected_plan": {},
		"sticky_key": "",
		"stats": _empty_stats(),
	}


static func _make_candidate(
	target: Dictionary,
	plan: Dictionary,
	score: float,
	source: StringName,
	key: String = ""
) -> Dictionary:
	if key.is_empty():
		key = _target_key(target, plan)
	return {
		"key": key,
		"target": target,
		"plan": plan,
		"score": score,
		"source": source,
	}


static func _target_key(target: Dictionary, plan: Dictionary) -> String:
	var metadata: Dictionary = target.get("metadata", {})
	var command: PlaceElementCommand = plan.get("command")
	var origin := Vector3i.ZERO
	if command != null:
		origin = command.origin_cell
	return "%s|%s|%s|%s|%s" % [
		target.get("target_kind", &""),
		metadata.get("element_id", -1),
		metadata.get("collider_local_cell", Vector3i.ZERO),
		origin,
		target.get("point", Vector3.ZERO),
	]


func _apply_hysteresis(candidates: Array[Dictionary]) -> int:
	if _sticky_candidate_key.is_empty() or candidates.is_empty():
		return 0
	var best_score := float(candidates[0]["score"])
	var sticky_index := -1
	for index: int in range(candidates.size()):
		if str(candidates[index].get("key", "")) == _sticky_candidate_key:
			sticky_index = index
			break
	if sticky_index < 0:
		return 0
	var sticky_score := float(candidates[sticky_index]["score"])
	if sticky_score + HYSTERESIS_SCORE_BONUS >= best_score - HYSTERESIS_BREAK_GAP:
		return sticky_index
	return 0


func _collect_face_candidates(
	world: SimulationWorld,
	archetype: ElementArchetype,
	orientation_index: int,
	store_id: String,
	ray_origin: Vector3,
	ray_direction: Vector3,
	camera: Camera3D,
	held_ground_pivot: Vector3 = Vector3(INF, INF, INF),
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Array[Dictionary]:
	var ranked: Array[Dictionary] = []
	if _face_cache != null:
		var corridor_bounds := _corridor_bounds(
			ray_origin,
			ray_direction,
			MAX_RAY_DISTANCE
		)
		for face: Dictionary in _face_cache.faces_in_aabb(corridor_bounds):
			last_stats["faces_scanned"] = int(last_stats["faces_scanned"]) + 1
			var world_point: Vector3 = face["world_point"]
			if not _is_in_corridor(
				ray_origin,
				ray_direction,
				world_point,
				MAX_RAY_DISTANCE
			):
				continue
			last_stats["faces_corridor_pass"] = (
				int(last_stats["faces_corridor_pass"]) + 1
			)
			var score := _score_geometric(
				ray_origin,
				ray_direction,
				camera,
				world_point,
				ray_origin.distance_to(world_point)
			)
			ranked.append({
				"face": face,
				"score": score,
			})
	else:
		ranked.append_array(
			_legacy_rank_faces(
				world,
				ray_origin,
				ray_direction,
				camera
			)
		)

	ranked.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return float(left["score"]) > float(right["score"])
	)

	var validated: Array[Dictionary] = []
	var validate_limit := mini(TOP_K_VALIDATE, ranked.size())
	for index: int in range(validate_limit):
		var entry: Dictionary = ranked[index]
		var face: Dictionary = entry["face"]
		var element := world.get_element(int(face["element_id"]))
		if element == null:
			continue
		var assembly := world.get_assembly_raw(int(face["assembly_id"]))
		if assembly == null:
			continue
		var target := _target_from_face(
			face,
			ray_direction,
			ray_origin
		)
		last_stats["plans_validated"] = int(last_stats["plans_validated"]) + 1
		var plan := ConstructionPlacement.plan(
			world,
			target,
			archetype,
			orientation_index,
			store_id,
			held_ground_pivot,
			held_attach_pivot
		)
		if not bool(plan.get("valid", false)):
			continue
		var score := float(entry["score"])
		if _has_compatible_connection(world, element, plan):
			score += 5.0
		validated.append(
			_make_candidate(
				target,
				plan,
				score,
				&"face_scan",
				"%d|%s" % [element.element_id, str(face["port_id"])]
			)
		)
	validated.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return float(left["score"]) > float(right["score"])
	)
	return validated


func _legacy_rank_faces(
	world: SimulationWorld,
	ray_origin: Vector3,
	ray_direction: Vector3,
	camera: Camera3D
) -> Array[Dictionary]:
	var ranked: Array[Dictionary] = []
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly.tombstoned:
			continue
		if not _assembly_has_anchor(world, assembly.assembly_id):
			continue
		var assembly_transform := assembly.motion.transform
		for element_id: int in assembly.element_ids:
			var element := world.get_element(element_id)
			if element == null:
				continue
			var element_archetype := element.get_archetype()
			if element_archetype == null:
				continue
			for port: PortDefinition in element_archetype.ports:
				if not _is_structural_port(port):
					continue
				last_stats["faces_scanned"] = (
					int(last_stats["faces_scanned"]) + 1
				)
				var world_point := ConstructionSnapFaceCache._port_world_point(
					element,
					port,
					assembly_transform
				)
				if not _is_in_corridor(
					ray_origin,
					ray_direction,
					world_point,
					MAX_RAY_DISTANCE
				):
					continue
				last_stats["faces_corridor_pass"] = (
					int(last_stats["faces_corridor_pass"]) + 1
				)
				ranked.append({
					"face": {
						"assembly_id": assembly.assembly_id,
						"element_id": element.element_id,
						"port_id": port.port_id,
						"collider_local_cell": port.local_cell,
						"world_point": world_point,
						"world_normal": (
							assembly_transform.basis
							* Vector3(
								ConstructionSnapFaceCache._element_port_direction(
									element,
									port
								)
							).normalized()
						),
					},
					"score": _score_geometric(
						ray_origin,
						ray_direction,
						camera,
						world_point,
						ray_origin.distance_to(world_point)
					),
				})
	return ranked


static func _corridor_bounds(
	ray_origin: Vector3,
	ray_direction: Vector3,
	max_distance: float
) -> AABB:
	var ray_end := ray_origin + ray_direction * max_distance
	var padding := Vector3.ONE * MAX_RAY_LATERAL
	var minimum := Vector3(
		minf(ray_origin.x, ray_end.x),
		minf(ray_origin.y, ray_end.y),
		minf(ray_origin.z, ray_end.z)
	) - padding
	var maximum := Vector3(
		maxf(ray_origin.x, ray_end.x),
		maxf(ray_origin.y, ray_end.y),
		maxf(ray_origin.z, ray_end.z)
	) + padding
	return AABB(minimum, maximum - minimum)


static func _is_in_corridor(
	ray_origin: Vector3,
	ray_direction: Vector3,
	world_point: Vector3,
	max_distance: float
) -> bool:
	var to_point := world_point - ray_origin
	var along := to_point.dot(ray_direction)
	if along < 0.05 or along > max_distance:
		return false
	var lateral := to_point.cross(ray_direction).length()
	if lateral > MAX_RAY_LATERAL:
		return false
	if to_point.length_squared() <= 0.000001:
		return true
	var forward_alignment := ray_direction.dot(to_point.normalized())
	return forward_alignment >= MIN_FORWARD_DOT


static func _score_geometric(
	ray_origin: Vector3,
	ray_direction: Vector3,
	camera: Camera3D,
	world_point: Vector3,
	distance: float
) -> float:
	var to_point := world_point - ray_origin
	var ray_distance := to_point.cross(ray_direction).length()
	var angle_penalty := 0.0
	if to_point.length_squared() > 0.000001:
		angle_penalty = 1.0 - clampf(
			ray_direction.dot(to_point.normalized()),
			0.0,
			1.0
		)
	var distance_penalty := clampf(distance / MAX_RAY_DISTANCE, 0.0, 1.0)
	var screen_penalty := 0.0
	if camera != null:
		var viewport := camera.get_viewport()
		if viewport != null:
			var screen := camera.unproject_position(world_point)
			var center := viewport.get_visible_rect().size * 0.5
			if center.length_squared() > 0.000001:
				screen_penalty = clampf(
					screen.distance_to(center) / center.length(),
					0.0,
					MAX_SCREEN_PENALTY_RADIUS
				)
	var score := 10.0
	score -= ray_distance * 2.0
	score -= angle_penalty
	score -= distance_penalty * 0.5
	score -= screen_penalty * 0.3
	return score


static func _has_compatible_connection(
	world: SimulationWorld,
	target_element: SimulationElement,
	plan: Dictionary
) -> bool:
	var command: PlaceElementCommand = plan.get("command")
	if command == null or command.assembly_id == 0:
		return false
	var preview := SimulationElement.frame(
		-1,
		command.assembly_id,
		command.archetype,
		command.origin_cell,
		command.orientation_index,
		{}
	)
	return RuntimeConnectivity.elements_have_rigid_connection(
		target_element,
		preview
	)


static func _target_from_face(
	face: Dictionary,
	aim_direction: Vector3,
	ray_origin: Vector3
) -> Dictionary:
	var world_point: Vector3 = face["world_point"]
	var world_normal: Vector3 = face["world_normal"]
	return InteractionHit.create(
		world_point,
		world_normal,
		ray_origin.distance_to(world_point),
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		StringName(str(face["element_id"])),
		{
			"element_id": int(face["element_id"]),
			"assembly_id": int(face["assembly_id"]),
			"collider_local_cell": face["collider_local_cell"],
			"aim_direction": aim_direction,
			"snap_port_id": str(face["port_id"]),
		}
	).snapshot()


static func _is_structural_port(port: PortDefinition) -> bool:
	return (
		port != null
		and port.kind == PortDefinition.Kind.MECHANICAL
		and port.compatibility_tags.has("structural")
	)


static func _assembly_has_anchor(
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	for joint: SimulationJoint in world.list_joints():
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.ANCHOR
		):
			return true
	return false
