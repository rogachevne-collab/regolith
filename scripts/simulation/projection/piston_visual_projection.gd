class_name PistonVisualProjection
extends Node

const PistonVisualScript := preload(
	"res://scripts/presentation/piston_visual.gd"
)

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _records_by_assembly: Dictionary = {}


func bind(
	world: SimulationWorld,
	physics_projection: SimulationPhysicsProjection
) -> void:
	if (
		_world != null
		and _world.structural_event.is_connected(_on_structural_event)
	):
		_world.structural_event.disconnect(_on_structural_event)
	_world = world
	_physics_projection = physics_projection
	if _world != null:
		_world.structural_event.connect(_on_structural_event)
	rebuild_all()


func rebuild_all() -> void:
	_clear_all()
	if _world == null or _physics_projection == null:
		return
	for assembly: SimulationAssembly in _world.list_assemblies():
		if not assembly.tombstoned:
			_rebuild_assembly(assembly.assembly_id)


func rebuild_assembly(assembly_id: int) -> void:
	_rebuild_assembly(assembly_id)


func _process(_delta: float) -> void:
	if _world == null or _physics_projection == null:
		return
	for assembly_id: int in _records_by_assembly.keys():
		_sync_assembly(int(assembly_id))


func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored":
			call_deferred("rebuild_all")
		&"assembly_spawned":
			call_deferred("_rebuild_assembly", int(event["assembly_id"]))
		&"assembly_changed":
			# Frame place/dismantle on a rover must not tear down every piston
			# visual — only rebuild when a piston half or joint is involved.
			if _event_touches_piston_visuals(event):
				call_deferred("_rebuild_assembly", int(event["assembly_id"]))
		&"assembly_removed":
			_clear_assembly(int(event["assembly_id"]))
		&"assembly_split":
			call_deferred("_rebuild_assembly", int(event["survivor_assembly_id"]))
			for mapping_variant: Variant in event.get("new_assemblies", []):
				if mapping_variant is Dictionary:
					call_deferred(
						"_rebuild_assembly",
						int(mapping_variant["assembly_id"])
					)
		&"assembly_merged":
			_clear_assembly(int(event["loser_assembly_id"]))
			call_deferred("_rebuild_assembly", int(event["survivor_assembly_id"]))


func _event_touches_piston_visuals(event: Dictionary) -> bool:
	if _world == null:
		return true
	var assembly_id := int(event.get("assembly_id", 0))
	var placed_element_id := int(event.get("placed_element_id", 0))
	var removed_element_id := int(event.get("removed_element_id", 0))
	if placed_element_id > 0:
		var placed := _world.get_element(placed_element_id)
		if (
			placed != null
			and PistonVisualScript.is_piston_element(placed.archetype_id)
		):
			return true
		return false
	if removed_element_id > 0:
		return _records_reference_element(assembly_id, removed_element_id)
	return true


func _records_reference_element(assembly_id: int, element_id: int) -> bool:
	var records_variant: Variant = _records_by_assembly.get(assembly_id, [])
	if not records_variant is Array:
		return false
	for record_variant: Variant in records_variant:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		if int(record.get("element_id", 0)) == element_id:
			return true
		var sim_joint: SimulationJoint = record.get("sim_joint")
		if (
			sim_joint != null
			and (
				sim_joint.element_a_id == element_id
				or sim_joint.element_b_id == element_id
			)
		):
			return true
		var base_root: Node = record.get("base_root") as Node
		if (
			base_root != null
			and is_instance_valid(base_root)
			and int(base_root.get_meta("element_id", 0)) == element_id
		):
			return true
	return false


func _rebuild_assembly(assembly_id: int) -> void:
	# Harvest extension before teardown: deferred rebuild runs after physics
	# freed the old bodies/joint, but record dicts still hold last sync state.
	var frozen_extensions := _harvest_extension_by_element(assembly_id)
	_clear_assembly(assembly_id)
	if _world == null or _physics_projection == null:
		return
	var assembly := _world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return
	var records: Array[Dictionary] = []
	for constraint_variant: Variant in (
		_physics_projection.list_piston_constraint_records(assembly_id)
	):
		if not constraint_variant is Dictionary:
			continue
		var visual_record := _create_visual_record(constraint_variant)
		if not visual_record.is_empty():
			records.append(visual_record)
	# Paired visuals are joint-keyed; after one half is destroyed the joint is
	# gone and list_piston_constraint_records is empty — reattach the survivor.
	_attach_orphan_piston_visuals(assembly, records, frozen_extensions)
	if records.is_empty():
		return
	_records_by_assembly[assembly_id] = records
	_sync_assembly(assembly_id)


func _harvest_extension_by_element(assembly_id: int) -> Dictionary:
	var out: Dictionary = {}
	var records_variant: Variant = _records_by_assembly.get(assembly_id, [])
	if not records_variant is Array:
		return out
	for record_variant: Variant in records_variant:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		var sim_joint: SimulationJoint = record.get("sim_joint")
		var extension_m := float(record.get("last_extension_m", NAN))
		if (
			not is_finite(extension_m)
			and sim_joint != null
			and sim_joint.motor != null
		):
			extension_m = sim_joint.motor.observed_position_m
		if not is_finite(extension_m):
			continue
		extension_m = maxf(extension_m, 0.0)
		var base_root: Node = record.get("base_root") as Node
		if (
			base_root != null
			and is_instance_valid(base_root)
			and base_root.has_meta("element_id")
		):
			out[int(base_root.get_meta("element_id"))] = extension_m
		if sim_joint != null:
			out[sim_joint.element_a_id] = extension_m
		var element_id := int(record.get("element_id", 0))
		if element_id > 0:
			out[element_id] = extension_m
	return out


func _attach_orphan_piston_visuals(
	assembly: SimulationAssembly,
	records: Array[Dictionary],
	frozen_extensions: Dictionary = {}
) -> void:
	if assembly == null:
		return
	var covered: Dictionary = {}
	for record_variant: Variant in records:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		var sim_joint: SimulationJoint = record.get("sim_joint")
		if sim_joint != null:
			covered[sim_joint.element_a_id] = true
			covered[sim_joint.element_b_id] = true
		var element_id := int(record.get("element_id", 0))
		if element_id > 0:
			covered[element_id] = true
	for element_id: int in assembly.element_ids:
		if covered.has(element_id):
			continue
		var element := _world.get_element(element_id)
		if (
			element == null
			or not PistonVisualScript.is_piston_element(element.archetype_id)
		):
			continue
		var projection := _physics_projection.get_element_projection(element_id)
		var body: PhysicsBody3D = projection.get("body") as PhysicsBody3D
		if body == null or not is_instance_valid(body):
			continue
		var frozen_extension_m := float(
			frozen_extensions.get(element_id, 0.0)
		)
		var orphan := PistonVisualScript.attach_runtime_orphan(
			body,
			element,
			assembly.assembly_id,
			frozen_extension_m
		)
		if not orphan.is_empty():
			records.append(orphan)


func _create_visual_record(constraint_record: Variant) -> Dictionary:
	if not constraint_record is Dictionary:
		return {}
	var constraint: Dictionary = constraint_record
	var sim_joint: SimulationJoint = constraint.get("sim_joint")
	if sim_joint == null or sim_joint.motor == null:
		return {}
	var base_body: PhysicsBody3D = constraint.get("base_body")
	var head_body: PhysicsBody3D = constraint.get("head_body")
	if base_body == null or head_body == null:
		return {}
	var base_element := _world.get_element(sim_joint.element_a_id)
	var head_element := _world.get_element(sim_joint.element_b_id)
	if base_element == null or head_element == null:
		return {}
	var archetype := base_element.get_archetype()
	if archetype == null or archetype.piston_definition == null:
		return {}
	var visual_record := PistonVisualScript.attach_runtime(
		base_body,
		head_body,
		base_element,
		head_element,
		archetype.piston_definition,
		sim_joint.assembly_id,
		sim_joint.joint_id
	)
	visual_record["base_anchor_local"] = constraint.get(
		"base_anchor_local",
		Vector3.ZERO
	)
	visual_record["head_anchor_local"] = constraint.get(
		"head_anchor_local",
		Vector3.ZERO
	)
	visual_record["sim_joint"] = sim_joint
	return visual_record


func _sync_assembly(assembly_id: int) -> void:
	var records_variant: Variant = _records_by_assembly.get(assembly_id, [])
	if not records_variant is Array:
		return
	var root_body: PhysicsBody3D = (
		_physics_projection.get_physics_body(assembly_id) as PhysicsBody3D
	)
	if root_body == null:
		return
	var assembly_transform: Transform3D = root_body.global_transform
	for record_variant: Variant in records_variant:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		var sim_joint: SimulationJoint = _world.get_joint(
			int(record.get("joint_id", 0))
		)
		if sim_joint == null or sim_joint.motor == null:
			continue
		var base_body: PhysicsBody3D = _find_body_for_record(record, "base_root")
		var head_body: PhysicsBody3D = _find_body_for_record(record, "head_root")
		if base_body == null or head_body == null:
			continue
		if not is_instance_valid(base_body) or not is_instance_valid(head_body):
			continue
		var axis_world: Vector3 = (
			assembly_transform.basis * record.get("axis_local", Vector3.UP)
		)
		var measured: Dictionary = PistonProjectionUtil.measure_axial_state(
			base_body,
			head_body,
			record.get("base_anchor_local", Vector3.ZERO),
			record.get("head_anchor_local", Vector3.ZERO),
			axis_world
		)
		var powered := PistonProjectionUtil.is_piston_powered(
			_world,
			sim_joint.element_a_id
		)
		var status := ActuatorSimulationService.status_name_for_motor(
			sim_joint.motor
		)
		var extension_m := float(measured.get("extension_m", 0.0))
		record["last_extension_m"] = extension_m
		PistonVisualScript.update_runtime(
			record,
			extension_m,
			powered,
			status
		)


func _find_body_for_record(
	record: Dictionary,
	root_key: String
) -> PhysicsBody3D:
	var root_variant: Variant = record.get(root_key)
	if not root_variant is Node3D:
		return null
	var root := root_variant as Node3D
	if not is_instance_valid(root):
		return null
	var parent_node := root.get_parent()
	return parent_node as PhysicsBody3D


func _clear_assembly(assembly_id: int) -> void:
	var records_variant: Variant = _records_by_assembly.get(assembly_id, [])
	if records_variant is Array:
		for record_variant: Variant in records_variant:
			if record_variant is Dictionary:
				PistonVisualScript.detach_runtime(record_variant)
	_records_by_assembly.erase(assembly_id)


func _clear_all() -> void:
	for assembly_id: Variant in _records_by_assembly.keys():
		_clear_assembly(int(assembly_id))
