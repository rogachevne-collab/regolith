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
		&"assembly_spawned", &"assembly_changed":
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


func _rebuild_assembly(assembly_id: int) -> void:
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
	if records.is_empty():
		return
	_records_by_assembly[assembly_id] = records
	_sync_assembly(assembly_id)


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
		PistonVisualScript.update_runtime(
			record,
			float(measured.get("extension_m", 0.0)),
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
