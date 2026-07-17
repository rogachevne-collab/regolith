class_name PistonVisual
extends RefCounted

const BASE_SCENE := preload(
	"res://scenes/presentation/piston_base_visual.tscn"
)
const HEAD_SCENE := preload(
	"res://scenes/presentation/piston_head_visual.tscn"
)

const MIN_SHAFT_HEIGHT_M := 0.04
const SHAFT_RADIUS_M := 0.07
const TRAVEL_GHOST_RADIUS_M := 0.045
static func is_piston_element(archetype_id: String) -> bool:
	return archetype_id == "piston_base" or archetype_id == "piston_head"


static func element_body_transform(
	element: SimulationElement
) -> Transform3D:
	return GridPoseUtil.element_local_transform(
		element.origin_cell,
		element.orientation_index
	)


static func attach_runtime(
	base_body: PhysicsBody3D,
	head_body: PhysicsBody3D,
	base_element: SimulationElement,
	head_element: SimulationElement,
	definition: PistonDefinition,
	assembly_id: int,
	joint_id: int
) -> Dictionary:
	var axis_local := PistonProjectionUtil.piston_axis_assembly_local(
		base_element,
		definition
	)
	var drive_local := PistonProjectionUtil.port_anchor_assembly_local(
		base_element,
		SimulationMotorState.PISTON_DRIVE_PORT
	)
	var carriage_local := PistonProjectionUtil.port_anchor_assembly_local(
		head_element,
		SimulationMotorState.PISTON_CARRIAGE_PORT
	)
	var base_root: Node3D = BASE_SCENE.instantiate() as Node3D
	var head_root: Node3D = HEAD_SCENE.instantiate() as Node3D
	base_root.name = "PistonBaseVisual_%d" % joint_id
	head_root.name = "PistonHeadVisual_%d" % joint_id
	base_root.transform = Transform3D(
		PistonProjectionUtil.basis_from_axis(axis_local),
		drive_local
	)
	head_root.transform = Transform3D(
		PistonProjectionUtil.basis_from_axis(axis_local),
		carriage_local
	)
	_tag_runtime_node(base_root, assembly_id, joint_id, base_element.element_id)
	_tag_runtime_node(head_root, assembly_id, joint_id, head_element.element_id)
	base_body.add_child(base_root)
	head_body.add_child(head_root)
	var shaft_mesh := base_root.get_node("Shaft") as MeshInstance3D
	return {
		"joint_id": joint_id,
		"assembly_id": assembly_id,
		"base_root": base_root,
		"head_root": head_root,
		"shaft_mesh": shaft_mesh,
		"axis_local": axis_local,
	}


static func update_runtime(
	record: Dictionary,
	extension_m: float,
	powered: bool,
	status: StringName
) -> void:
	var shaft_mesh: MeshInstance3D = record.get("shaft_mesh")
	if shaft_mesh == null:
		return
	var height := maxf(extension_m, MIN_SHAFT_HEIGHT_M)
	var cylinder := shaft_mesh.mesh as CylinderMesh
	if cylinder == null:
		cylinder = CylinderMesh.new()
		cylinder.top_radius = SHAFT_RADIUS_M
		cylinder.bottom_radius = SHAFT_RADIUS_M
		cylinder.radial_segments = 12
		shaft_mesh.mesh = cylinder
	cylinder.height = height
	shaft_mesh.position = Vector3(0.0, height * 0.5, 0.0)
	_apply_runtime_shaft_material(shaft_mesh, powered, status)


static func build_placement_preview_nodes(
	base_archetype: ElementArchetype,
	head_archetype: ElementArchetype,
	base_origin_cell: Vector3i,
	orientation_index: int,
	valid: bool
) -> Array[Node]:
	var nodes: Array[Node] = []
	if (
		base_archetype == null
		or head_archetype == null
		or base_archetype.piston_definition == null
	):
		return nodes
	var definition := base_archetype.piston_definition
	var head_origin := PistonPlacementUtil.head_origin_cell(
		base_origin_cell,
		orientation_index,
		definition
	)
	var base_element := SimulationElement.frame(
		-1,
		-1,
		base_archetype,
		base_origin_cell,
		orientation_index,
		{}
	)
	var head_element := SimulationElement.frame(
		-2,
		-1,
		head_archetype,
		head_origin,
		orientation_index,
		{}
	)
	var axis_local := PistonProjectionUtil.piston_axis_assembly_local(
		base_element,
		definition
	)
	var base_material := _preview_material(
		Color(0.12, 0.2, 0.34, 0.42) if valid else Color(0.45, 0.08, 0.06, 0.38)
	)
	var head_material := _preview_material(
		Color(0.18, 0.62, 0.78, 0.48) if valid else Color(0.55, 0.12, 0.08, 0.4)
	)
	var travel_material := _preview_material(
		Color(0.95, 0.82, 0.2, 0.16) if valid else Color(0.7, 0.2, 0.12, 0.14)
	)
	var base_root := _instantiate_preview_part(
		BASE_SCENE,
		base_element,
		axis_local,
		SimulationMotorState.PISTON_DRIVE_PORT,
		base_material,
		"PreviewPistonBase"
	)
	var head_root := _instantiate_preview_part(
		HEAD_SCENE,
		head_element,
		axis_local,
		SimulationMotorState.PISTON_CARRIAGE_PORT,
		head_material,
		"PreviewPistonHead"
	)
	if base_root != null:
		nodes.append(base_root)
	if head_root != null:
		nodes.append(head_root)
	var carriage_local := PistonProjectionUtil.port_anchor_assembly_local(
		head_element,
		SimulationMotorState.PISTON_CARRIAGE_PORT
	)
	nodes.append(
		_build_travel_ghost(
			carriage_local,
			axis_local,
			definition.upper_limit_m,
			travel_material
		)
	)
	nodes.append(
		_build_axis_arrow(
			carriage_local,
			axis_local,
			definition.upper_limit_m,
			valid
		)
	)
	return nodes


static func apply_preview_material(root: Node3D, material: Material) -> void:
	if root == null or material == null:
		return
	_apply_material_recursive(root, material)


static func detach_runtime(record: Dictionary) -> void:
	for key: String in ["base_root", "head_root"]:
		var node_variant: Variant = record.get(key)
		if node_variant is Node:
			var node := node_variant as Node
			if is_instance_valid(node):
				node.queue_free()


static func _instantiate_preview_part(
	scene: PackedScene,
	element: SimulationElement,
	axis_local: Vector3,
	port_id: String,
	material: Material,
	node_name: String
) -> Node3D:
	if scene == null or element == null:
		return null
	var anchor_local := PistonProjectionUtil.port_anchor_assembly_local(
		element,
		port_id
	)
	var root: Node3D = scene.instantiate() as Node3D
	root.name = node_name
	root.transform = Transform3D(
		PistonProjectionUtil.basis_from_axis(axis_local),
		anchor_local
	)
	_apply_material_recursive(root, material)
	var shaft := root.get_node_or_null("Shaft") as MeshInstance3D
	if shaft != null:
		shaft.visible = port_id == SimulationMotorState.PISTON_DRIVE_PORT
		if shaft.visible:
			update_runtime(
				{"shaft_mesh": shaft},
				MIN_SHAFT_HEIGHT_M,
				false,
				&"standby"
			)
	return root


static func _build_travel_ghost(
	origin_local: Vector3,
	axis_local: Vector3,
	travel_m: float,
	material: Material
) -> MeshInstance3D:
	var axis := axis_local.normalized()
	var height := maxf(travel_m, GridMetric.CELL_SIZE_M)
	var ghost := MeshInstance3D.new()
	ghost.name = "PreviewPistonTravel"
	var mesh := CylinderMesh.new()
	mesh.top_radius = TRAVEL_GHOST_RADIUS_M
	mesh.bottom_radius = TRAVEL_GHOST_RADIUS_M
	mesh.height = height
	mesh.radial_segments = 10
	ghost.mesh = mesh
	ghost.material_override = material
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.transform = Transform3D(
		PistonProjectionUtil.basis_from_axis(axis),
		origin_local + axis * (height * 0.5)
	)
	return ghost


static func _build_axis_arrow(
	origin_local: Vector3,
	axis_local: Vector3,
	travel_m: float,
	valid: bool
) -> Node3D:
	var axis := axis_local.normalized()
	var root := Node3D.new()
	root.name = "PreviewPistonAxisArrow"
	var color := Color(1.0, 0.72, 0.12, 0.9) if valid else Color(1.0, 0.25, 0.12, 0.85)
	var material := _preview_material(color)
	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.025
	shaft_mesh.bottom_radius = 0.025
	shaft_mesh.height = maxf(travel_m, GridMetric.HALF_CELL_SIZE_M)
	shaft.mesh = shaft_mesh
	shaft.material_override = material
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shaft.position = axis * (shaft_mesh.height * 0.5)
	root.transform = Transform3D(
		PistonProjectionUtil.basis_from_axis(axis),
		origin_local
	)
	root.add_child(shaft)
	var tip := MeshInstance3D.new()
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.0
	tip_mesh.bottom_radius = 0.09
	tip_mesh.height = 0.14
	tip.mesh = tip_mesh
	tip.material_override = material
	tip.position = axis * (shaft_mesh.height + 0.07)
	tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(tip)
	return root


static func _apply_runtime_shaft_material(
	shaft_mesh: MeshInstance3D,
	powered: bool,
	status: StringName
) -> void:
	var color := Color(0.34, 0.48, 0.62, 1.0)
	var emission := Color(0.0, 0.0, 0.0, 1.0)
	var emission_energy := 0.0
	if status == &"overloaded":
		color = Color(0.82, 0.22, 0.12, 1.0)
		emission = Color(0.9, 0.18, 0.05, 1.0)
		emission_energy = 1.4
	elif status == &"no_power":
		color = Color(0.22, 0.24, 0.28, 1.0)
	elif powered:
		color = Color(0.28, 0.58, 0.78, 1.0)
		emission = Color(0.12, 0.42, 0.62, 1.0)
		emission_energy = 0.8
	var material := shaft_mesh.material_override as StandardMaterial3D
	if material == null:
		material = StandardMaterial3D.new()
		material.metallic = 0.82
		material.roughness = 0.22
		shaft_mesh.material_override = material
	material.albedo_color = color
	material.emission_enabled = emission_energy > 0.0
	material.emission = emission
	material.emission_energy_multiplier = emission_energy


static func _preview_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material


static func _apply_material_recursive(node: Node, material: Material) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.material_override = material
		mesh_instance.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
	for child_node: Node in node.get_children():
		_apply_material_recursive(child_node, material)


static func _tag_runtime_node(
	node: Node3D,
	assembly_id: int,
	joint_id: int,
	element_id: int
) -> void:
	node.set_meta("piston_visual", true)
	node.set_meta("assembly_id", assembly_id)
	node.set_meta("piston_joint_id", joint_id)
	node.set_meta("element_id", element_id)
