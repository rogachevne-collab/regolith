class_name PistonVisual
extends RefCounted

const BASE_SCENE := preload(
	"res://scenes/presentation/piston_base_visual.tscn"
)
const HEAD_SCENE := preload(
	"res://scenes/presentation/piston_head_visual.tscn"
)

const LARGE_VISUAL_SCALE := 2.4
const TRAVEL_GHOST_RADIUS_M := 0.045
## Art keys (meters, local +Y from base bottom). Translation + slight Y scale on extend.
const SEGMENT1_REST_Y_M := 0.0
const SEGMENT1_EXTEND_Y_M := 0.84
const SEGMENT1_EXTEND_SCALE_Y := 1.082
const SEGMENT2_REST_Y_M := 0.0
const SEGMENT2_EXTEND_Y_M := 1.865
const SEGMENT2_EXTEND_SCALE_Y := 1.079
const ART_TRAVEL_M := 2.0
## Folded art: head bottom 0.9m, game carriage port 0.5m → +0.4m visual bias.
const ART_HEAD_BOTTOM_OFFSET_FROM_CARRIAGE_M := 0.4
static func is_piston_element(archetype_id: String) -> bool:
	return (
		archetype_id == "piston_base"
		or archetype_id == "piston_head"
		or archetype_id == "piston_base_large"
		or archetype_id == "piston_head_large"
	)


static func is_large_piston_element(archetype_id: String) -> bool:
	return (
		archetype_id == "piston_base_large"
		or archetype_id == "piston_head_large"
	)


static func element_body_transform(
	element: SimulationElement
) -> Transform3D:
	return GridPoseUtil.element_local_transform(
		element.origin_cell,
		element.orientation_index,
		element.pose_offset
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
	var base_bottom_local := _base_bottom_assembly_local(
		base_element,
		axis_local
	)
	var head_anchor_local := _head_visual_anchor_assembly_local(
		head_element,
		axis_local
	)
	var base_root: Node3D = BASE_SCENE.instantiate() as Node3D
	var head_root: Node3D = HEAD_SCENE.instantiate() as Node3D
	base_root.name = "PistonBaseVisual_%d" % joint_id
	head_root.name = "PistonHeadVisual_%d" % joint_id
	var large := is_large_piston_element(base_element.archetype_id)
	var visual_scale := LARGE_VISUAL_SCALE if large else 1.0
	var basis := PistonProjectionUtil.basis_from_axis(axis_local)
	base_root.transform = Transform3D(basis, base_bottom_local)
	head_root.transform = Transform3D(basis, head_anchor_local)
	base_root.scale = Vector3.ONE * visual_scale
	head_root.scale = Vector3.ONE * visual_scale
	_tag_runtime_node(base_root, assembly_id, joint_id, base_element.element_id)
	_tag_runtime_node(head_root, assembly_id, joint_id, head_element.element_id)
	base_body.add_child(base_root)
	head_body.add_child(head_root)
	var segments := _resolve_segment_nodes(base_root)
	return {
		"joint_id": joint_id,
		"assembly_id": assembly_id,
		"base_root": base_root,
		"head_root": head_root,
		"segment1": segments.get("segment1"),
		"segment2": segments.get("segment2"),
		"axis_local": axis_local,
		"visual_scale": visual_scale,
		"travel_m": maxf(definition.upper_limit_m, ART_TRAVEL_M),
	}


## Surviving half after the piston joint is gone (dismantle/damage).
## Base keeps `frozen_extension_m` so an extended cut does not visually collapse.
static func attach_runtime_orphan(
	body: PhysicsBody3D,
	element: SimulationElement,
	assembly_id: int,
	frozen_extension_m: float = 0.0
) -> Dictionary:
	if body == null or element == null:
		return {}
	var is_head := element.archetype_id.begins_with("piston_head")
	var scene: PackedScene = HEAD_SCENE if is_head else BASE_SCENE
	var axis_local := _orphan_axis_assembly_local(element)
	var anchor_local := _visual_anchor_assembly_local(element, axis_local)
	var root: Node3D = scene.instantiate() as Node3D
	if root == null:
		return {}
	root.name = (
		"PistonHeadVisual_orphan_%d" % element.element_id
		if is_head
		else "PistonBaseVisual_orphan_%d" % element.element_id
	)
	var large := is_large_piston_element(element.archetype_id)
	var visual_scale := LARGE_VISUAL_SCALE if large else 1.0
	var basis := PistonProjectionUtil.basis_from_axis(axis_local)
	root.transform = Transform3D(basis, anchor_local)
	root.scale = Vector3.ONE * visual_scale
	_tag_runtime_node(root, assembly_id, 0, element.element_id)
	body.add_child(root)
	var travel_m := ART_TRAVEL_M
	var archetype := element.get_archetype()
	if (
		archetype != null
		and archetype.piston_definition != null
	):
		travel_m = maxf(
			archetype.piston_definition.upper_limit_m,
			ART_TRAVEL_M
		)
	var record := {
		"joint_id": 0,
		"assembly_id": assembly_id,
		"element_id": element.element_id,
		"orphan": true,
		"axis_local": axis_local,
		"visual_scale": visual_scale,
		"travel_m": travel_m,
		"last_extension_m": maxf(frozen_extension_m, 0.0),
	}
	if is_head:
		record["head_root"] = root
	else:
		record["base_root"] = root
		var segments := _resolve_segment_nodes(root)
		record["segment1"] = segments.get("segment1")
		record["segment2"] = segments.get("segment2")
		update_runtime(record, maxf(frozen_extension_m, 0.0), false, &"idle")
	return record


static func _orphan_axis_assembly_local(element: SimulationElement) -> Vector3:
	var archetype := element.get_archetype()
	if archetype != null and archetype.piston_definition != null:
		return PistonProjectionUtil.piston_axis_assembly_local(
			element,
			archetype.piston_definition
		)
	# Head archetypes have no piston_definition; default authored axis is +Y.
	var axis_cell := OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(OrientationUtil.Face.POS_Y),
		element.orientation_index
	)
	return Vector3(axis_cell).normalized()


static func update_runtime(
	record: Dictionary,
	extension_m: float,
	_powered: bool,
	_status: StringName
) -> void:
	var travel_m := maxf(float(record.get("travel_m", ART_TRAVEL_M)), 0.001)
	var t := clampf(extension_m / travel_m, 0.0, 1.0)
	var segment1: Node3D = record.get("segment1") as Node3D
	var segment2: Node3D = record.get("segment2") as Node3D
	if segment1 != null:
		var scale1 := lerpf(1.0, SEGMENT1_EXTEND_SCALE_Y, t)
		segment1.scale = Vector3(1.0, scale1, 1.0)
		segment1.position = Vector3(
			0.0,
			lerpf(SEGMENT1_REST_Y_M, SEGMENT1_EXTEND_Y_M, t),
			0.0
		)
	if segment2 != null:
		var scale2 := lerpf(1.0, SEGMENT2_EXTEND_SCALE_Y, t)
		segment2.scale = Vector3(1.0, scale2, 1.0)
		segment2.position = Vector3(
			0.0,
			lerpf(SEGMENT2_REST_Y_M, SEGMENT2_EXTEND_Y_M, t),
			0.0
		)


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
	var large := is_large_piston_element(base_archetype.archetype_id)
	var visual_scale := LARGE_VISUAL_SCALE if large else 1.0
	var travel_radius := (
		TRAVEL_GHOST_RADIUS_M * LARGE_VISUAL_SCALE if large else TRAVEL_GHOST_RADIUS_M
	)
	var base_root := _instantiate_preview_part(
		BASE_SCENE,
		base_element,
		axis_local,
		base_material,
		"PreviewPistonBase",
		visual_scale
	)
	var head_root := _instantiate_preview_part(
		HEAD_SCENE,
		head_element,
		axis_local,
		head_material,
		"PreviewPistonHead",
		visual_scale
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
			travel_material,
			travel_radius
		)
	)
	nodes.append(
		_build_axis_arrow(
			carriage_local,
			axis_local,
			definition.upper_limit_m,
			valid,
			visual_scale
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
	material: Material,
	node_name: String,
	visual_scale: float = 1.0
) -> Node3D:
	if scene == null or element == null:
		return null
	var anchor_local := _visual_anchor_assembly_local(element, axis_local)
	var root: Node3D = scene.instantiate() as Node3D
	root.name = node_name
	root.transform = Transform3D(
		PistonProjectionUtil.basis_from_axis(axis_local),
		anchor_local
	)
	root.scale = Vector3.ONE * visual_scale
	_apply_material_recursive(root, material)
	if node_name.contains("Base"):
		var segments := _resolve_segment_nodes(root)
		update_runtime(
			{
				"segment1": segments.get("segment1"),
				"segment2": segments.get("segment2"),
				"travel_m": ART_TRAVEL_M,
			},
			0.0,
			false,
			&"standby"
		)
	return root


static func _build_travel_ghost(
	origin_local: Vector3,
	axis_local: Vector3,
	travel_m: float,
	material: Material,
	radius_m: float = TRAVEL_GHOST_RADIUS_M
) -> MeshInstance3D:
	var axis := axis_local.normalized()
	var height := maxf(travel_m, GridMetric.CELL_SIZE_M)
	var ghost := MeshInstance3D.new()
	ghost.name = "PreviewPistonTravel"
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius_m
	mesh.bottom_radius = radius_m
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
	valid: bool,
	visual_scale: float = 1.0
) -> Node3D:
	var axis := axis_local.normalized()
	var root := Node3D.new()
	root.name = "PreviewPistonAxisArrow"
	var color := Color(1.0, 0.72, 0.12, 0.9) if valid else Color(1.0, 0.25, 0.12, 0.85)
	var material := _preview_material(color)
	var scale := maxf(visual_scale, 1.0)
	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.025 * scale
	shaft_mesh.bottom_radius = 0.025 * scale
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
	tip_mesh.bottom_radius = 0.09 * scale
	tip_mesh.height = 0.14 * scale
	tip.mesh = tip_mesh
	tip.material_override = material
	tip.position = axis * (shaft_mesh.height + tip_mesh.height * 0.5)
	tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(tip)
	return root


static func _base_bottom_assembly_local(
	element: SimulationElement,
	axis_local: Vector3
) -> Vector3:
	var axis := axis_local.normalized()
	var cell_center := GridPoseUtil.element_cell_center(
		element.origin_cell,
		Vector3i.ZERO,
		element.orientation_index
	)
	return cell_center - axis * GridMetric.HALF_CELL_SIZE_M


static func _head_visual_anchor_assembly_local(
	element: SimulationElement,
	axis_local: Vector3
) -> Vector3:
	var carriage := PistonProjectionUtil.port_anchor_assembly_local(
		element,
		SimulationMotorState.PISTON_CARRIAGE_PORT
	)
	return carriage + axis_local.normalized() * ART_HEAD_BOTTOM_OFFSET_FROM_CARRIAGE_M


static func _visual_anchor_assembly_local(
	element: SimulationElement,
	axis_local: Vector3
) -> Vector3:
	if element.archetype_id.begins_with("piston_head"):
		return _head_visual_anchor_assembly_local(element, axis_local)
	return _base_bottom_assembly_local(element, axis_local)


static func _resolve_segment_nodes(base_root: Node) -> Dictionary:
	var out := {"segment1": null, "segment2": null}
	if base_root == null:
		return out
	out["segment1"] = base_root.find_child("PistonSegment1", true, false)
	out["segment2"] = base_root.find_child("PistonSegment2", true, false)
	return out


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
