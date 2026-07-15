class_name ElementVisualProjection
extends Node

const VISUAL_PREFIX := "ElementVisual_"
const DRILL_SPIN_SPEED := 7.0
const STATIONARY_DRILL_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/stationary_drill_visual.gd"
)
const ROVER_MODULE_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/rover_module_visual.gd"
)

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _materials: Dictionary = {}
var _known_bodies: Dictionary = {}
var _drill_rotors: Dictionary = {}


func bind(
	world: SimulationWorld,
	physics_projection: SimulationPhysicsProjection
) -> void:
	if _world != null and _world.structural_event.is_connected(
		_on_structural_event
	):
		_world.structural_event.disconnect(_on_structural_event)
	_world = world
	_physics_projection = physics_projection
	_create_materials()
	if _world != null:
		_world.structural_event.connect(_on_structural_event)
	rebuild_all()


func rebuild_all() -> void:
	if _world == null or _physics_projection == null:
		return
	for assembly_id: Variant in _known_bodies.keys():
		_clear_known_body(int(assembly_id))
	for assembly: SimulationAssembly in _world.list_assemblies():
		if assembly.tombstoned:
			continue
		_rebuild_assembly(assembly.assembly_id)


func rebuild_assembly(assembly_id: int) -> void:
	_rebuild_assembly(assembly_id)


func _process(delta: float) -> void:
	if _world == null:
		return
	for element_id_variant: Variant in _drill_rotors.keys():
		var element_id := int(element_id_variant)
		var rotor_variant: Variant = _drill_rotors[element_id]
		if not is_instance_valid(rotor_variant):
			_drill_rotors.erase(element_id)
			continue
		var rotor := rotor_variant as Node3D
		var element := _world.get_element(element_id)
		if element == null:
			_drill_rotors.erase(element_id)
			continue
		var running := _stationary_drill_spinning(element)
		var operation_vfx := rotor.get_node_or_null("OperationVfx") as Node3D
		if operation_vfx != null:
			operation_vfx.visible = running
		if running:
			rotor.rotate_x(DRILL_SPIN_SPEED * delta)


func _stationary_drill_spinning(element: SimulationElement) -> bool:
	if element == null or not element.is_operational():
		return false
	var runtime := _world.ensure_industry_element_runtime(element.element_id)
	if not runtime.machine_enabled:
		return false
	if (
		IndustryArchetypeProfile.drill_requires_power()
		and not runtime.powered
	):
		return false
	return true


func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored":
			rebuild_all()
		&"assembly_spawned", &"assembly_changed":
			_rebuild_assembly(int(event["assembly_id"]))
		&"assembly_removed":
			_clear_known_body(int(event["assembly_id"]))
		&"assembly_split":
			_rebuild_assembly(int(event["survivor_assembly_id"]))
			for mapping_variant: Variant in event.get("new_assemblies", []):
				if mapping_variant is Dictionary:
					_rebuild_assembly(int(mapping_variant["assembly_id"]))
		&"assembly_merged":
			_clear_known_body(int(event["loser_assembly_id"]))
			_rebuild_assembly(int(event["survivor_assembly_id"]))
		&"element_state_changed":
			var change_kind := StringName(event.get("change_kind", &""))
			if change_kind in [&"damage", &"repair", &"weld"]:
				_update_element_visual(int(event.get("element_id", 0)))
			else:
				_rebuild_assembly(int(event["assembly_id"]))


func _update_element_visual(element_id: int) -> void:
	if _world == null or _physics_projection == null or element_id <= 0:
		return
	var element := _world.get_element(element_id)
	if element == null:
		return
	var body := _body_for_element(element_id)
	if body == null:
		return
	var prefix := "%s%d_" % [VISUAL_PREFIX, element_id]
	var material := _material_for(element)
	for child: Node in body.get_children():
		if child is MeshInstance3D and child.name.begins_with(prefix):
			(child as MeshInstance3D).material_override = material


func _rebuild_assembly(assembly_id: int) -> void:
	var assembly := _world.get_assembly_raw(assembly_id)
	var root_body := _physics_projection.get_physics_body(assembly_id)
	if assembly == null or assembly.tombstoned or root_body == null:
		_clear_known_body(assembly_id)
		return
	_clear_assembly_visuals(assembly_id)
	_known_bodies[assembly_id] = root_body
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element == null:
			continue
		var body := _body_for_element(element_id)
		if body == null:
			continue
		var archetype := element.get_archetype()
		if archetype == null or archetype.colliders.is_empty():
			continue
		if PistonVisual.is_piston_element(element.archetype_id):
			continue
		if ROVER_MODULE_VISUAL_SCRIPT.is_rover_module(element.archetype_id):
			_add_rover_module_visual(body, assembly_id, element)
			continue
		for collider_index: int in range(archetype.colliders.size()):
			var collider: ColliderDefinition = archetype.colliders[collider_index]
			if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
				continue
			var mesh := BoxMesh.new()
			mesh.size = collider.size * 0.96
			var visual := MeshInstance3D.new()
			visual.name = "%s%d_%d" % [
				VISUAL_PREFIX,
				element_id,
				collider_index,
			]
			visual.mesh = mesh
			visual.material_override = _material_for(element)
			visual.transform = GridPoseUtil.collider_local_transform(
				element.origin_cell,
				element.orientation_index,
				collider
			)
			visual.set_meta("element_visual", true)
			visual.set_meta("assembly_id", assembly_id)
			body.add_child(visual)
		if element.archetype_id == "stationary_drill":
			_add_stationary_drill_visual(body, assembly_id, element)


func _add_rover_module_visual(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement
) -> void:
	ROVER_MODULE_VISUAL_SCRIPT.attach_runtime(body, assembly_id, element)


func _add_stationary_drill_visual(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement
) -> void:
	var root: Node3D = STATIONARY_DRILL_VISUAL_SCRIPT.instantiate_for_element(
		element.origin_cell,
		element.orientation_index,
		element.get_archetype()
	)
	root.name = "StationaryDrillWorkingHead_%d" % element.element_id
	root.set_meta("element_visual", true)
	root.set_meta("assembly_id", assembly_id)
	body.add_child(root)
	var rotor: Node3D = STATIONARY_DRILL_VISUAL_SCRIPT.operational_rotor(root)
	if rotor != null:
		_drill_rotors[element.element_id] = rotor


func _clear_visuals(body: PhysicsBody3D, assembly_id: int = 0) -> void:
	for child: Node in body.get_children():
		if (
			child.has_meta("element_visual")
			and (
				assembly_id == 0
				or int(child.get_meta("assembly_id", 0)) == assembly_id
			)
		):
			body.remove_child(child)
			child.queue_free()


func _clear_known_body(assembly_id: int) -> void:
	_clear_assembly_visuals(assembly_id)
	_known_bodies.erase(assembly_id)


func _body_for_element(element_id: int) -> PhysicsBody3D:
	if _physics_projection == null or element_id <= 0:
		return null
	var record := _physics_projection.get_element_projection(element_id)
	if not record.is_empty():
		return record.get("body") as PhysicsBody3D
	if _world == null:
		return null
	var element := _world.get_element(element_id)
	if element == null:
		return null
	return _physics_projection.get_physics_body(element.assembly_id)


func _clear_assembly_visuals(assembly_id: int) -> void:
	if _world == null or _physics_projection == null:
		return
	var assembly := _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	var cleared: Dictionary = {}
	for element_id: int in assembly.element_ids:
		var body := _body_for_element(element_id)
		if body == null:
			continue
		var body_id := body.get_instance_id()
		if cleared.has(body_id):
			continue
		_clear_visuals(body, assembly_id)
		cleared[body_id] = true


func _material_for(element: SimulationElement) -> StandardMaterial3D:
	var archetype := element.get_archetype()
	if (
		archetype != null
		and archetype.resource_path.begins_with(
			"res://resources/archetypes/rover/"
		)
	):
		return _materials["rover"]
	var reason := element.status_reason()
	if reason == &"element_broken":
		return _materials["broken"]
	if reason == &"element_incomplete":
		return _materials["frame"]
	if reason == &"damaged":
		return _materials["damaged"]
	return _materials["operational"]


func _create_materials() -> void:
	if not _materials.is_empty():
		return
	_materials["frame"] = _material(
		Color(0.72, 0.48, 0.22, 1.0),
		0.18,
		false,
		0.82
	)
	_materials["operational"] = _material(
		Color(0.23, 0.38, 0.55, 1.0),
		0.72,
		false
	)
	_materials["damaged"] = _material(
		Color(0.88, 0.55, 0.08, 1.0),
		0.5,
		false
	)
	_materials["broken"] = _material(
		Color(0.55, 0.04, 0.03, 1.0),
		0.25,
		false
	)
	_materials["rover"] = _material(
		Color(0.14, 0.15, 0.17, 1.0),
		0.55,
		false,
		0.78
	)


func _material(
	color: Color,
	metallic: float,
	transparent: bool,
	roughness: float = 0.42
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material
