class_name ElementVisualProjection
extends Node

const VISUAL_PREFIX := "ElementVisual_"

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _materials: Dictionary = {}
var _known_bodies: Dictionary = {}


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
			_rebuild_assembly(int(event["assembly_id"]))


func _rebuild_assembly(assembly_id: int) -> void:
	var body := _physics_projection.get_physics_body(assembly_id)
	var assembly := _world.get_assembly_raw(assembly_id)
	if body == null or assembly == null or assembly.tombstoned:
		_clear_known_body(assembly_id)
		return
	var previous := _known_bodies.get(assembly_id) as PhysicsBody3D
	if previous != null and previous != body:
		_clear_visuals(previous)
	_clear_visuals(body)
	_known_bodies[assembly_id] = body
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element == null:
			continue
		var archetype := element.get_archetype()
		if (
			archetype == null
			or not archetype.resource_path.begins_with(
				"res://resources/archetypes/slice01/"
			)
		):
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
			body.add_child(visual)


func _clear_visuals(body: PhysicsBody3D) -> void:
	for child: Node in body.get_children():
		if child.has_meta("element_visual"):
			body.remove_child(child)
			child.queue_free()


func _clear_known_body(assembly_id: int) -> void:
	var body := _known_bodies.get(assembly_id) as PhysicsBody3D
	if body != null and is_instance_valid(body):
		_clear_visuals(body)
	_known_bodies.erase(assembly_id)


func _material_for(element: SimulationElement) -> StandardMaterial3D:
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
		Color(1.0, 0.42, 0.08, 0.62),
		0.55,
		true
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


func _material(
	color: Color,
	metallic: float,
	transparent: bool
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = 0.42
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material
