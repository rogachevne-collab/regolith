class_name ConstructionPreviewSnapshot
extends RefCounted
## Builds a POD snapshot of attach-relevant assemblies for native magnet scan.
## C++ never holds a SimulationWorld pointer.
##
## Topology-stable fields (packed occupancy, origins, orientations, single_group,
## local grid AABB) are revision-cached. Live fields refresh every build, but
## only for assemblies whose AABB the aim ray can hit — far assemblies never
## pay element-dict / compile_body_groups cost.

const BodyGroupMotionUtilScript := preload(
	"res://scripts/simulation/runtime/body_group_motion_util.gd"
)

static var _topology_cache: Dictionary = {}


static func clear_cache(assembly_id: int = 0) -> void:
	if assembly_id <= 0:
		_topology_cache.clear()
		return
	_topology_cache.erase(assembly_id)


static func build(
	world: SimulationWorld,
	ray_origin: Vector3 = Vector3(INF, INF, INF),
	ray_direction: Vector3 = Vector3.ZERO,
	max_ray_distance: float = 4.0,
	max_lateral: float = 1.2
) -> Dictionary:
	var assemblies: Array = []
	if world == null:
		return {"assemblies": assemblies}
	var cull_ray := (
		ray_origin.is_finite()
		and ray_direction.length_squared() > 0.000001
	)
	var ray_dir := (
		ray_direction.normalized() if cull_ray else Vector3.ZERO
	)
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		var topology := _topology_pod(world, assembly)
		if topology.is_empty():
			continue
		var root_transform := (
			assembly.motion.transform
			if assembly.motion != null
			else Transform3D.IDENTITY
		)
		if cull_ray and not _ray_hits_assembly(
			topology,
			root_transform,
			ray_origin,
			ray_dir,
			max_ray_distance,
			max_lateral
		):
			continue
		var elements: Dictionary
		if bool(topology.get("single_group", true)):
			# Root pose is enough; skip compile_body_groups + joint idle walk.
			elements = _minimal_elements(topology, root_transform)
		else:
			var compiled: Dictionary = world.compile_body_groups(assembly.assembly_id)
			elements = _live_elements(world, assembly, topology, compiled)
		assemblies.append({
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"attach_allowed": true,
			"single_group": bool(topology.get("single_group", true)),
			"root_transform": root_transform,
			"occupancy": topology["occupancy"],
			"elements": elements,
		})
	return {"assemblies": assemblies}


static func _ray_hits_assembly(
	topology: Dictionary,
	root_transform: Transform3D,
	ray_origin: Vector3,
	ray_direction: Vector3,
	max_ray_distance: float,
	max_lateral: float
) -> bool:
	var grid_aabb: AABB = topology.get("grid_aabb", AABB())
	if grid_aabb.size == Vector3.ZERO and grid_aabb.position == Vector3.ZERO:
		return true
	var bounds := grid_aabb.grow(max_lateral)
	var inverse := root_transform.affine_inverse()
	var local_origin := inverse * ray_origin
	var local_direction := (inverse.basis * ray_direction).normalized()
	return (
		bounds.intersects_segment(
			local_origin,
			local_origin + local_direction * max_ray_distance
		)
		!= null
	)


static func _topology_pod(world: SimulationWorld, assembly: SimulationAssembly) -> Dictionary:
	var cached: Variant = _topology_cache.get(assembly.assembly_id)
	if cached is Dictionary:
		var entry: Dictionary = cached
		if int(entry.get("revision", -1)) == assembly.topology_revision:
			return entry
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
		world,
		assembly
	)
	if occupancy.is_empty():
		return {}
	var element_topology: Dictionary = {}
	var minimum := Vector3i(2147483647, 2147483647, 2147483647)
	var maximum := Vector3i(-2147483648, -2147483648, -2147483648)
	for element_id_variant: Variant in assembly.element_ids:
		var element_id := int(element_id_variant)
		var element := world.get_element(element_id)
		if element == null:
			continue
		element_topology[element_id] = {
			"origin_cell": element.origin_cell,
			"orientation_index": element.orientation_index,
		}
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
	var compiled: Dictionary = world.compile_body_groups(assembly.assembly_id)
	var single_group := false
	if bool(compiled.get("valid", false)):
		single_group = (compiled.get("groups", {}) as Dictionary).size() <= 1
	var packed := {
		"revision": assembly.topology_revision,
		"occupancy": ConstructionPreviewKernelAccess.cached_packed_occupancy(
			world,
			assembly
		),
		"element_topology": element_topology,
		"single_group": single_group,
		"grid_aabb": AABB(lower, upper - lower),
	}
	_topology_cache[assembly.assembly_id] = packed
	return packed


static func _minimal_elements(
	topology: Dictionary,
	root_transform: Transform3D
) -> Dictionary:
	var elements: Dictionary = {}
	var element_topology: Dictionary = topology.get("element_topology", {})
	for element_id_variant: Variant in element_topology.keys():
		var topo: Dictionary = element_topology[element_id_variant]
		elements[str(int(element_id_variant))] = {
			"group_transform": root_transform,
			"driven_path_at_home": true,
			"origin_cell": topo.get("origin_cell", Vector3i.ZERO),
			"orientation_index": int(topo.get("orientation_index", 0)),
		}
	return elements


static func _live_elements(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	topology: Dictionary,
	compiled: Dictionary
) -> Dictionary:
	var elements: Dictionary = {}
	var element_topology: Dictionary = topology.get("element_topology", {})
	var element_to_group: Dictionary = {}
	var root_group_id := 0
	var head_to_joint: Dictionary = {}
	var joint_to_base: Dictionary = {}
	var joint_idle: Dictionary = {}
	if bool(compiled.get("valid", false)):
		element_to_group = compiled.get("element_to_group", {})
		root_group_id = int(compiled.get("root_group_id", 0))
		for spec_variant: Variant in compiled.get("driven_specs", []):
			if not spec_variant is Dictionary:
				continue
			var spec: Dictionary = spec_variant
			var joint_id := int(spec.get("joint_id", 0))
			var head_id := int(spec.get("head_group_id", 0))
			var base_id := int(spec.get("base_group_id", 0))
			if head_id > 0 and joint_id > 0:
				head_to_joint[head_id] = joint_id
			if joint_id > 0:
				joint_to_base[joint_id] = base_id
				if not joint_idle.has(joint_id):
					joint_idle[joint_id] = _joint_is_idle(world, joint_id)
	var root_transform := (
		assembly.motion.transform
		if assembly.motion != null
		else Transform3D.IDENTITY
	)
	for element_id_variant: Variant in element_topology.keys():
		var element_id := int(element_id_variant)
		var topo: Dictionary = element_topology[element_id_variant]
		var group_id := int(element_to_group.get(element_id, 0))
		elements[str(element_id)] = {
			"group_transform": _group_transform(
				world,
				assembly,
				root_transform,
				root_group_id,
				group_id
			),
			"driven_path_at_home": _driven_path_at_home(
				group_id,
				head_to_joint,
				joint_to_base,
				joint_idle
			),
			"origin_cell": topo.get("origin_cell", Vector3i.ZERO),
			"orientation_index": int(topo.get("orientation_index", 0)),
		}
	return elements


static func _group_transform(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	root_transform: Transform3D,
	root_group_id: int,
	group_id: int
) -> Transform3D:
	if group_id <= 0 or group_id == root_group_id:
		return root_transform
	var stored: Variant = assembly.body_group_motions.get(group_id)
	if stored is AssemblyMotionState:
		return (stored as AssemblyMotionState).transform
	return BodyGroupMotionUtilScript.reconstruct_group_motion(
		world,
		assembly.assembly_id,
		group_id
	).transform


static func _driven_path_at_home(
	group_id: int,
	head_to_joint: Dictionary,
	joint_to_base: Dictionary,
	joint_idle: Dictionary
) -> bool:
	var current := group_id
	var guard := 0
	while current > 0 and guard < 16:
		guard += 1
		if not head_to_joint.has(current):
			break
		var joint_id := int(head_to_joint[current])
		if not bool(joint_idle.get(joint_id, true)):
			return false
		var base_group := int(joint_to_base.get(joint_id, 0))
		if base_group <= 0 or base_group == current:
			break
		current = base_group
	return true


static func _joint_is_idle(world: SimulationWorld, joint_id: int) -> bool:
	var joint: SimulationJoint = world.get_joint(joint_id)
	if joint == null or joint.motor == null:
		return true
	return (
		absf(joint.motor.observed_velocity_mps)
		<= SimulationMotorState.CONSTRUCTION_IDLE_VELOCITY
	)
