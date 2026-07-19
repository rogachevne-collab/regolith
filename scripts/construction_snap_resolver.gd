class_name ConstructionSnapResolver
extends RefCounted
## Resolves where the build ghost goes. One pipeline for every aim case:
##
## 1. Direct hit on a compatible element face → that face wins, no scan.
## 2. Everything else (ground, miss, invalid direct) → stateless magnet scan:
##    march the aim ray through each attach-allowed assembly's occupancy grid
##    (already indexed per topology revision by the kernel) and derive exposed
##    faces near the ray. No world-space face cache, no invalidation, no
##    structural-event plumbing — occupancy + current transforms are always
##    fresh, so parked rovers magnetize and moving ones drop out for free.
## 3. Voxel fallback scores below magnetic faces; if nothing is placeable the
##    invalid direct plan is surfaced so the preview can render the red ghost.

const MAX_CANDIDATES := 8
## Cap on authoritative plan validations per resolve (the expensive part).
const TOP_K_VALIDATE := 12
const DIRECT_ELEMENT_SCORE := 1000.0
const VOXEL_FALLBACK_SCORE := 3.0
const HYSTERESIS_SCORE_BONUS := 0.12
const HYSTERESIS_BREAK_GAP := 0.18
const MAX_RAY_DISTANCE := 4.0
const MAX_RAY_LATERAL := 1.2
const MIN_FORWARD_DOT := 0.15
const MAX_SCREEN_PENALTY_RADIUS := 0.65
const _RAY_STEP_M := GridMetric.HALF_CELL_SIZE_M

var last_stats: Dictionary = _empty_stats()

var _sticky_candidate_key: String = ""
## assembly_id -> {revision, aabb}: local-space grid bounds for quick ray
## rejection. Revision-keyed like the kernel occupancy index it derives from.
var _bounds_cache: Dictionary = {}

## Magnet probe offsets around each ray cell (Manhattan distance <= 2): which
## occupied cells near the aim line may contribute an exposed face.
static var _magnet_offsets: Array[Vector3i] = _build_magnet_offsets()


static func _build_magnet_offsets() -> Array[Vector3i]:
	var offsets: Array[Vector3i] = []
	for x: int in range(-2, 3):
		for y: int in range(-2, 3):
			for z: int in range(-2, 3):
				var manhattan: int = absi(x) + absi(y) + absi(z)
				if manhattan == 0 or manhattan > 2:
					continue
				offsets.append(Vector3i(x, y, z))
	return offsets


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
	var direct_kind := StringName(direct_hit.get("target_kind", &""))
	var direct_valid := bool(direct_hit.get("valid", false))
	# Direct element hit is planned once and reused everywhere below. The
	# voxel ground plan is planned lazily after the face scan: when a magnetic
	# face wins anyway, the ground plan (seat raycasts, large footprints) is
	# wasted work on every aim change.
	var direct_plan: Dictionary = {}
	if direct_valid and direct_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		last_stats["plans_validated"] = 1
		direct_plan = ConstructionPlacement.plan(
			world,
			direct_hit,
			archetype,
			orientation_index,
			store_id,
			held_ground_pivot,
			held_attach_pivot
		)

	# Direct compatible element hit always wins (magnetic snap policy §1); no
	# scan needed — cheapest and by far the most common aim case.
	if (
		manual_index < 0
		and direct_kind == InteractionHit.KIND_SIMULATION_ELEMENT
		and bool(direct_plan.get("valid", false))
	):
		var direct_command: PlaceElementCommand = direct_plan.get("command")
		if direct_command != null and direct_command.assembly_id != 0:
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

	var candidates: Array[Dictionary] = _collect_face_candidates(
		world,
		archetype,
		orientation_index,
		store_id,
		ray_origin,
		ray_direction,
		camera,
		held_ground_pivot,
		held_attach_pivot
	)

	if (
		direct_kind == InteractionHit.KIND_SIMULATION_ELEMENT
		and bool(direct_plan.get("valid", false))
	):
		var command: PlaceElementCommand = direct_plan.get("command")
		if command != null and command.assembly_id != 0:
			candidates.append(
				_make_candidate(
					direct_hit,
					direct_plan,
					DIRECT_ELEMENT_SCORE,
					&"direct_element"
				)
			)
	elif direct_valid and direct_kind == InteractionHit.KIND_VOXEL:
		# Voxel fallback scores below magnetic faces (policy §3): aiming at
		# the ground next to a structure still snaps to the structure — so
		# only pay for the ground plan when it can matter (no valid face, or
		# manual cycling wants the full pool).
		if candidates.is_empty() or manual_index >= 0:
			last_stats["plans_validated"] = (
				int(last_stats["plans_validated"]) + 1
			)
			direct_plan = ConstructionPlacement.plan(
				world,
				direct_hit,
				archetype,
				orientation_index,
				store_id,
				held_ground_pivot,
				held_attach_pivot
			)
			if bool(direct_plan.get("valid", false)):
				candidates.append(
					_make_candidate(
						direct_hit,
						direct_plan,
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

	# No placeable candidate anywhere: surface the invalid direct-hit plan so
	# the preview can render the red "cannot place here" ghost.
	if selected.is_empty() and not direct_plan.is_empty():
		_sticky_candidate_key = ""
		return {
			"candidates": [],
			"selected_index": -1,
			"selected_target": direct_hit,
			"selected_plan": direct_plan,
			"sticky_key": "",
			"stats": last_stats.duplicate(true),
		}

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
		"assemblies_scanned": 0,
		"faces_scanned": 0,
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
		key = _target_key(target)
	return {
		"key": key,
		"target": target,
		"plan": plan,
		"score": score,
		"source": source,
	}


static func _target_key(target: Dictionary) -> String:
	var metadata: Dictionary = target.get("metadata", {})
	return "%s|%s|%s|%s" % [
		target.get("target_kind", &""),
		metadata.get("element_id", -1),
		metadata.get("snap_cell", Vector3i.ZERO),
		metadata.get("snap_dir", Vector3i.ZERO),
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
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		var faces := _scan_assembly_faces(
			world,
			assembly,
			ray_origin,
			ray_direction,
			camera
		)
		if faces.is_empty():
			continue
		# Attach permission is checked only for assemblies the aim actually
		# reaches — it is the (joint-scan) expensive check, not the scan.
		if not world.construction_attach_allowed(assembly.assembly_id):
			continue
		ranked.append_array(faces)

	ranked.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return float(left["score"]) > float(right["score"])
	)

	# Only the selected candidate needs an authoritative plan this frame:
	# validate best-first and stop at the first valid face, plus the sticky
	# face (hysteresis must be able to keep it selected).
	var validated: Array[Dictionary] = []
	var attempts := 0
	var have_first_valid := false
	var use_prefilter := not held_attach_pivot.is_finite()
	for entry: Dictionary in ranked:
		if attempts >= TOP_K_VALIDATE:
			break
		var is_sticky := (
			not _sticky_candidate_key.is_empty()
			and str(entry.get("key", "")) == _sticky_candidate_key
		)
		if have_first_valid and not is_sticky:
			continue
		# Footprint-overlap prefilter: a dictionary sweep instead of a full
		# authoritative plan (~µs vs ~ms for a 125-cell archetype). The plan
		# below still validates whatever passes.
		if use_prefilter and not _prefilter_attach_fits(
			world,
			archetype,
			orientation_index,
			entry["target"]
		):
			continue
		attempts += 1
		last_stats["plans_validated"] = int(last_stats["plans_validated"]) + 1
		var target: Dictionary = entry["target"]
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
		validated.append(
			_make_candidate(
				target,
				plan,
				float(entry["score"]),
				&"face_scan",
				str(entry["key"])
			)
		)
		have_first_valid = true
	validated.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return float(left["score"]) > float(right["score"])
	)
	return validated


func _prefilter_attach_fits(
	world: SimulationWorld,
	archetype: ElementArchetype,
	orientation_index: int,
	target: Dictionary
) -> bool:
	var metadata: Dictionary = target.get("metadata", {})
	if not metadata.has("snap_cell"):
		return true
	var assembly := world.get_assembly_raw(int(metadata.get("assembly_id", 0)))
	if assembly == null:
		return true
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
		world,
		assembly
	)
	var origin: Vector3i = GridPoseUtil.snap_origin_for_target_cell(
		archetype,
		metadata.get("snap_cell", Vector3i.ZERO),
		metadata.get("snap_dir", Vector3i.UP),
		orientation_index
	)
	for cell: Vector3i in archetype.footprint_cells:
		if occupancy.has(
			origin + OrientationUtil.rotate_cell(cell, orientation_index)
		):
			return false
	return true


## March the aim ray through the assembly's occupancy grid and derive exposed
## faces near the ray. Stateless: occupancy is revision-cached by the kernel,
## transforms are read fresh, so motion and parking need no invalidation.
func _scan_assembly_faces(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	ray_origin: Vector3,
	ray_direction: Vector3,
	camera: Camera3D
) -> Array[Dictionary]:
	var faces: Array[Dictionary] = []
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
		world,
		assembly
	)
	if occupancy.is_empty():
		return faces
	var root_transform := assembly.motion.transform
	var inverse := root_transform.affine_inverse()
	var local_origin := inverse * ray_origin
	var local_direction := (inverse.basis * ray_direction).normalized()
	if not _ray_hits_bounds(assembly, occupancy, local_origin, local_direction):
		return faces
	last_stats["assemblies_scanned"] = int(last_stats["assemblies_scanned"]) + 1
	var single_group := world.assembly_is_single_body_group(assembly.assembly_id)

	var visited: Dictionary = {}
	var seen_faces: Dictionary = {}
	var previous_cell := GridMetric.meters_to_cell_floor(local_origin)
	var travelled := 0.0
	while travelled <= MAX_RAY_DISTANCE:
		var sample := local_origin + local_direction * travelled
		travelled += _RAY_STEP_M
		var cell := GridMetric.meters_to_cell_floor(sample)
		if visited.has(cell):
			continue
		visited[cell] = true
		if occupancy.has(cell):
			# Ray entered the structure: the entry face is a candidate, and
			# nothing behind the wall should magnetize.
			var entry_dir := _entry_face_direction(
				previous_cell,
				cell,
				local_direction,
				occupancy
			)
			if entry_dir != Vector3i.ZERO:
				_append_face(
					faces,
					seen_faces,
					world,
					assembly,
					occupancy,
					cell,
					entry_dir,
					root_transform,
					single_group,
					ray_origin,
					ray_direction,
					camera
				)
			break
		for offset: Vector3i in _magnet_offsets:
			var occupied := cell + offset
			if not occupancy.has(occupied):
				continue
			for face_dir: Vector3i in _face_directions_toward(offset):
				if occupancy.has(occupied + face_dir):
					continue
				_append_face(
					faces,
					seen_faces,
					world,
					assembly,
					occupancy,
					occupied,
					face_dir,
					root_transform,
					single_group,
					ray_origin,
					ray_direction,
					camera
				)
		previous_cell = cell
	return faces


## Axis-aligned face directions of an occupied cell that point back toward the
## empty ray cell it was probed from.
static func _face_directions_toward(offset: Vector3i) -> Array[Vector3i]:
	var directions: Array[Vector3i] = []
	if offset.x != 0:
		directions.append(Vector3i(-signi(offset.x), 0, 0))
	if offset.y != 0:
		directions.append(Vector3i(0, -signi(offset.y), 0))
	if offset.z != 0:
		directions.append(Vector3i(0, 0, -signi(offset.z)))
	return directions


static func _entry_face_direction(
	previous_cell: Vector3i,
	cell: Vector3i,
	local_direction: Vector3,
	occupancy: Dictionary
) -> Vector3i:
	var delta := previous_cell - cell
	for face_dir: Vector3i in _face_directions_toward(-delta):
		if not occupancy.has(cell + face_dir):
			return face_dir
	var dominant := _dominant_grid_direction(-local_direction)
	if not occupancy.has(cell + dominant):
		return dominant
	return Vector3i.ZERO


static func _dominant_grid_direction(direction: Vector3) -> Vector3i:
	var absolute := direction.abs()
	if absolute.x >= absolute.y and absolute.x >= absolute.z:
		return Vector3i.RIGHT if direction.x >= 0.0 else Vector3i.LEFT
	if absolute.y >= absolute.z:
		return Vector3i.UP if direction.y >= 0.0 else Vector3i.DOWN
	return Vector3i.BACK if direction.z >= 0.0 else Vector3i.FORWARD


func _append_face(
	faces: Array[Dictionary],
	seen_faces: Dictionary,
	world: SimulationWorld,
	assembly: SimulationAssembly,
	occupancy: Dictionary,
	face_cell: Vector3i,
	face_dir: Vector3i,
	root_transform: Transform3D,
	single_group: bool,
	ray_origin: Vector3,
	ray_direction: Vector3,
	camera: Camera3D
) -> void:
	var face_key := "%s|%s" % [face_cell, face_dir]
	if seen_faces.has(face_key):
		return
	seen_faces[face_key] = true
	var element_id := int(occupancy.get(face_cell, 0))
	var element := world.get_element(element_id)
	if element == null:
		return
	# Occupancy cells live in assembly grid space; world aim uses the live
	# group frame so extended/bent carriages magnet correctly. Skip only while
	# the driven path is still moving (same rule as construction validation).
	var group_transform := world.element_group_transform(element_id)
	if (
		not single_group
		and not group_transform.is_equal_approx(root_transform)
		and not ConstructionCommandService.is_driven_path_at_home(
			world,
			element_id
		)
	):
		return
	var pose_transform := (
		group_transform
		if not group_transform.is_equal_approx(root_transform)
		else root_transform
	)
	var local_normal := Vector3(face_dir)
	var local_point := (
		GridMetric.cell_center_meters(face_cell)
		+ local_normal * GridMetric.HALF_CELL_SIZE_M
	)
	var world_point := pose_transform * local_point
	if not _is_in_corridor(ray_origin, ray_direction, world_point, MAX_RAY_DISTANCE):
		return
	last_stats["faces_scanned"] = int(last_stats["faces_scanned"]) + 1
	var world_normal := (pose_transform.basis * local_normal).normalized()
	var target := InteractionHit.create(
		world_point,
		world_normal,
		ray_origin.distance_to(world_point),
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		StringName(str(element_id)),
		{
			"element_id": element_id,
			"assembly_id": assembly.assembly_id,
			"collider_local_cell": _element_local_cell(element, face_cell),
			"aim_direction": ray_direction,
			"snap_cell": face_cell,
			"snap_dir": face_dir,
		}
	).snapshot()
	faces.append({
		"key": "%d|%s|%s" % [element_id, face_cell, face_dir],
		"target": target,
		"score": _score_geometric(
			ray_origin,
			ray_direction,
			camera,
			world_point,
			ray_origin.distance_to(world_point)
		),
	})


static func _element_local_cell(
	element: SimulationElement,
	assembly_cell: Vector3i
) -> Vector3i:
	var delta := Vector3(assembly_cell - element.origin_cell)
	var local := OrientationUtil.orientation_basis(
		element.orientation_index
	).inverse() * delta
	return Vector3i(roundi(local.x), roundi(local.y), roundi(local.z))


## Local-space grid bounds per assembly, revision-cached, inflated by magnet
## reach — cheap slab test so far-away assemblies cost nothing per resolve.
func _ray_hits_bounds(
	assembly: SimulationAssembly,
	occupancy: Dictionary,
	local_origin: Vector3,
	local_direction: Vector3
) -> bool:
	var cached: Dictionary = _bounds_cache.get(assembly.assembly_id, {})
	var bounds: AABB
	if int(cached.get("revision", -1)) == assembly.topology_revision:
		bounds = cached["aabb"]
	else:
		var minimum := Vector3i(2147483647, 2147483647, 2147483647)
		var maximum := Vector3i(-2147483648, -2147483648, -2147483648)
		for cell_variant: Variant in occupancy.keys():
			var cell: Vector3i = cell_variant
			minimum = Vector3i(
				mini(minimum.x, cell.x),
				mini(minimum.y, cell.y),
				mini(minimum.z, cell.z)
			)
			maximum = Vector3i(
				maxi(maximum.x, cell.x),
				maxi(maximum.y, cell.y),
				maxi(maximum.z, cell.z)
			)
		var lower := GridMetric.cell_to_meters(minimum)
		var upper := GridMetric.cell_to_meters(maximum + Vector3i.ONE)
		bounds = AABB(lower, upper - lower).grow(MAX_RAY_LATERAL)
		_bounds_cache[assembly.assembly_id] = {
			"revision": assembly.topology_revision,
			"aabb": bounds,
		}
	return bounds.intersects_segment(
		local_origin,
		local_origin + local_direction * MAX_RAY_DISTANCE
	) != null


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
