class_name RoverModuleVisual
extends RefCounted

const SUSPENSION_SCENE := preload(
	"res://scenes/presentation/wheel_suspension_visual.tscn"
)
const WHEEL_SCENE := preload(
	"res://scenes/presentation/drive_wheel_visual.tscn"
)
const COCKPIT_SCENE := preload(
	"res://scenes/presentation/cockpit_visual.tscn"
)

const DEFAULT_SUSPENSION_TRAVEL_M := 0.6
const DEFAULT_WHEEL_RADIUS_M := 0.4
const DEFAULT_MAX_STEERING_RAD := 0.4887
const TRAVEL_GHOST_RADIUS_M := 0.045
const SOCKET_HALO_RADIUS_M := 0.11


static func is_rover_module(archetype_id: String) -> bool:
	return (
		archetype_id == "wheel_suspension"
		or archetype_id == "drive_wheel"
		or archetype_id == "cockpit"
	)


static func scene_for(archetype_id: String) -> PackedScene:
	match archetype_id:
		"wheel_suspension":
			return SUSPENSION_SCENE
		"drive_wheel":
			return WHEEL_SCENE
		"cockpit":
			return COCKPIT_SCENE
	return null


static func instantiate_for_element(
	origin_cell: Vector3i,
	orientation_index: int,
	archetype: ElementArchetype
) -> Node3D:
	var scene := scene_for(archetype.archetype_id if archetype != null else "")
	if scene == null:
		return null
	var visual: Node3D = scene.instantiate() as Node3D
	var basis := OrientationUtil.orientation_basis(orientation_index)
	visual.transform = Transform3D(
		basis,
		GridPoseUtil.oriented_footprint_pivot(
			archetype,
			origin_cell,
			orientation_index
		)
	)
	return visual


static func attach_runtime(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement
) -> Dictionary:
	var archetype := element.get_archetype()
	if archetype == null or not is_rover_module(element.archetype_id):
		return {}
	var visual := instantiate_for_element(
		element.origin_cell,
		element.orientation_index,
		archetype
	)
	if visual == null:
		return {}
	visual.name = "RoverModuleVisual_%d" % element.element_id
	visual.set_meta("element_visual", true)
	visual.set_meta("assembly_id", assembly_id)
	visual.set_meta("element_id", element.element_id)
	visual.set_meta("rover_module_visual", true)
	body.add_child(visual)
	var record := {
		"element_id": element.element_id,
		"assembly_id": assembly_id,
		"root": visual,
		"archetype_id": element.archetype_id,
	}
	if element.archetype_id == "drive_wheel":
		record["steer_root"] = visual.get_node_or_null("SteerRoot") as Node3D
		record["spin_root"] = (
			visual.get_node_or_null("SteerRoot/SpinRoot") as Node3D
		)
		record["hub_root"] = (
			visual.get_node_or_null("SteerRoot/Hub") as Node3D
		)
		record["root_base_transform"] = visual.transform
	return record


static func apply_preview_material(
	visual: Node3D,
	material: Material
) -> void:
	if visual == null or material == null:
		return
	_apply_material_recursive(visual, material)


static func build_placement_preview_nodes(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int,
	valid: bool
) -> Array[Node]:
	var nodes: Array[Node] = []
	if archetype == null or not is_rover_module(archetype.archetype_id):
		return nodes
	var body_material := _preview_material(
		_preview_body_color(archetype.archetype_id, valid)
	)
	var visual := instantiate_for_element(
		origin_cell,
		orientation_index,
		archetype
	)
	if visual != null:
		visual.name = "Preview%s" % archetype.archetype_id.capitalize()
		apply_preview_material(visual, body_material)
		nodes.append(visual)
	match archetype.archetype_id:
		"wheel_suspension":
			nodes.append_array(
				_build_suspension_gizmos(
					origin_cell,
					orientation_index,
					archetype,
					valid
				)
			)
		"drive_wheel":
			nodes.append_array(
				_build_wheel_gizmos(
					origin_cell,
					orientation_index,
					archetype,
					valid
				)
			)
	return nodes


static func build_orientation_hint(archetype_id: String) -> String:
	match archetype_id:
		"wheel_suspension":
			return "↑ рама  ↓ гнездо"
		"drive_wheel":
			return "↑ подвеска  ↔ протектор = ход"
		"cockpit":
			return "↔ стекло = перед"
	return ""


static func spin_root(record: Dictionary) -> Node3D:
	return record.get("spin_root") as Node3D


static func update_runtime(
	record: Dictionary,
	runtime: Dictionary,
	delta: float
) -> void:
	if delta <= 0.0:
		return
	var root_variant: Variant = record.get("root")
	if root_variant == null or not is_instance_valid(root_variant):
		return
	var root: Node3D = root_variant as Node3D
	if root == null:
		return
	var steer := record.get("steer_root") as Node3D
	if (
		steer != null
		and is_instance_valid(steer)
		and runtime.has("wheel_center_body_local")
	):
		var root_base: Transform3D = record.get(
			"root_base_transform",
			root.transform
		)
		var wheel_center_body_local: Vector3 = runtime.get(
			"wheel_center_body_local",
			root_base.origin
		)
		steer.position = root_base.affine_inverse() * wheel_center_body_local
		steer.rotation = Vector3(
			0.0,
			float(runtime.get("steering_angle_rad", 0.0)),
			0.0
		)
	var spin := spin_root(record)
	if spin != null and is_instance_valid(spin):
		spin.rotate_object_local(
			Vector3.RIGHT,
			float(runtime.get("wheel_speed", 0.0)) * delta
		)


static func _build_suspension_gizmos(
	origin_cell: Vector3i,
	orientation_index: int,
	archetype: ElementArchetype,
	valid: bool
) -> Array[Node]:
	var nodes: Array[Node] = []
	var pivot := GridPoseUtil.oriented_footprint_pivot(
		archetype,
		origin_cell,
		orientation_index
	)
	var basis := OrientationUtil.orientation_basis(orientation_index)
	var axis_local := -basis.y
	var travel_m := _suspension_travel_m(archetype)
	var socket_local := pivot + axis_local * GridMetric.HALF_CELL_SIZE_M
	var travel_material := _preview_material(
		Color(0.95, 0.82, 0.2, 0.16) if valid else Color(0.7, 0.2, 0.12, 0.14)
	)
	nodes.append(
		_build_travel_ghost(socket_local, axis_local, travel_m, travel_material)
	)
	nodes.append(
		_build_axis_arrow(socket_local, axis_local, travel_m, valid)
	)
	nodes.append(
		_build_socket_halo(
			socket_local,
			axis_local,
			valid,
			Color(0.95, 0.82, 0.2, 0.55) if valid else Color(1.0, 0.25, 0.12, 0.45)
		)
	)
	return nodes


static func _build_wheel_gizmos(
	origin_cell: Vector3i,
	orientation_index: int,
	archetype: ElementArchetype,
	valid: bool
) -> Array[Node]:
	var nodes: Array[Node] = []
	var pivot := GridPoseUtil.oriented_footprint_pivot(
		archetype,
		origin_cell,
		orientation_index
	)
	var basis := OrientationUtil.orientation_basis(orientation_index)
	var plug_local := pivot + basis.y * (GridMetric.HALF_CELL_SIZE_M - 0.02)
	var halo_color := (
		Color(1.0, 0.55, 0.1, 0.62) if valid else Color(1.0, 0.25, 0.12, 0.45)
	)
	nodes.append(_build_socket_halo(plug_local, basis.y, valid, halo_color))
	if _wheel_steerable_default(archetype):
		var definition: WheelDefinition = archetype.wheel_definition
		var neutral_forward := basis * Vector3(
			OrientationUtil.face_to_vector(definition.forward_axis_face)
		)
		nodes.append(
			_build_steering_arc(
				pivot,
				neutral_forward.normalized(),
				basis.y.normalized(),
				DEFAULT_MAX_STEERING_RAD,
				valid
			)
		)
	return nodes


static func _suspension_travel_m(archetype: ElementArchetype) -> float:
	if archetype != null and archetype.suspension_definition != null:
		return archetype.suspension_definition.suspension_travel_m
	return DEFAULT_SUSPENSION_TRAVEL_M


static func _wheel_steerable_default(archetype: ElementArchetype) -> bool:
	if archetype != null and archetype.wheel_definition != null:
		return archetype.wheel_definition.steerable_default
	return false


static func _preview_body_color(archetype_id: String, valid: bool) -> Color:
	match archetype_id:
		"wheel_suspension":
			return (
				Color(0.18, 0.34, 0.58, 0.44)
				if valid
				else Color(0.45, 0.08, 0.06, 0.38)
			)
		"drive_wheel":
			return (
				Color(0.2, 0.22, 0.26, 0.46)
				if valid
				else Color(0.5, 0.1, 0.08, 0.4)
			)
		"cockpit":
			return (
				Color(0.16, 0.42, 0.58, 0.42)
				if valid
				else Color(0.45, 0.08, 0.06, 0.38)
			)
	return Color(0.3, 0.3, 0.3, 0.4)


static func _build_travel_ghost(
	origin_local: Vector3,
	axis_local: Vector3,
	travel_m: float,
	material: Material
) -> MeshInstance3D:
	var axis := axis_local.normalized()
	var height := maxf(travel_m, GridMetric.CELL_SIZE_M)
	var ghost := MeshInstance3D.new()
	ghost.name = "PreviewSuspensionTravel"
	var mesh := CylinderMesh.new()
	mesh.top_radius = TRAVEL_GHOST_RADIUS_M
	mesh.bottom_radius = TRAVEL_GHOST_RADIUS_M
	mesh.height = height
	mesh.radial_segments = 10
	ghost.mesh = mesh
	ghost.material_override = material
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.transform = Transform3D(
		_basis_from_axis(axis),
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
	root.name = "PreviewSuspensionAxisArrow"
	var color := (
		Color(1.0, 0.72, 0.12, 0.9) if valid else Color(1.0, 0.25, 0.12, 0.85)
	)
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
	root.transform = Transform3D(_basis_from_axis(axis), origin_local)
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


static func _build_socket_halo(
	center_local: Vector3,
	axis_local: Vector3,
	valid: bool,
	color: Color
) -> MeshInstance3D:
	var axis := axis_local.normalized()
	var halo := MeshInstance3D.new()
	halo.name = "PreviewSocketHalo"
	var mesh := TorusMesh.new()
	mesh.inner_radius = SOCKET_HALO_RADIUS_M - 0.02
	mesh.outer_radius = SOCKET_HALO_RADIUS_M
	mesh.rings = 12
	mesh.ring_segments = 8
	halo.mesh = mesh
	halo.material_override = _preview_material(color)
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var basis := _basis_from_axis(axis)
	halo.transform = Transform3D(basis, center_local)
	return halo


static func _build_steering_arc(
	pivot_local: Vector3,
	neutral_forward: Vector3,
	steering_axis: Vector3,
	max_angle_rad: float,
	valid: bool
) -> Node3D:
	var root := Node3D.new()
	root.name = "PreviewSteeringArc"
	var color := (
		Color(0.95, 0.82, 0.2, 0.35) if valid else Color(0.7, 0.2, 0.12, 0.3)
	)
	var material := _preview_material(color)
	var radius := DEFAULT_WHEEL_RADIUS_M * 0.85
	for sign: int in [-1, 1]:
		var angle := float(sign) * max_angle_rad
		var forward := neutral_forward.rotated(steering_axis, angle)
		var arc := MeshInstance3D.new()
		var arc_mesh := CylinderMesh.new()
		arc_mesh.top_radius = 0.015
		arc_mesh.bottom_radius = 0.015
		arc_mesh.height = radius
		arc.mesh = arc_mesh
		arc.material_override = material
		arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arc.transform = Transform3D(
			_basis_from_axis(forward),
			pivot_local + forward * (radius * 0.5)
		)
		root.add_child(arc)
	return root


static func _basis_from_axis(axis_local: Vector3) -> Basis:
	var axis := axis_local.normalized()
	if axis.is_equal_approx(Vector3.UP):
		return Basis.IDENTITY
	if axis.is_equal_approx(Vector3.DOWN):
		return Basis(Vector3.RIGHT, PI)
	var reference := Vector3.FORWARD
	if absf(axis.dot(reference)) > 0.95:
		reference = Vector3.RIGHT
	var side := axis.cross(reference).normalized()
	var forward := side.cross(axis).normalized()
	return Basis(side, axis, forward)


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
	for child: Node in node.get_children():
		_apply_material_recursive(child, material)
