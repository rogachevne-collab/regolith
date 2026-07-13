class_name StationaryDrillVisual
extends RefCounted

const SCENE := preload(
	"res://scenes/presentation/stationary_drill_visual.tscn"
)


static func instantiate_for_element(
	origin_cell: Vector3i,
	orientation_index: int
) -> Node3D:
	var visual := SCENE.instantiate() as Node3D
	var basis := OrientationUtil.orientation_basis(orientation_index)
	visual.transform = Transform3D(
		basis,
		Vector3(origin_cell) + basis * Vector3(0.5, 0.5, 0.5)
	)
	return visual


static func apply_preview_material(
	visual: Node3D,
	material: Material
) -> void:
	if visual == null or material == null:
		return
	var mechanical := visual.get_node_or_null("Mechanical")
	if mechanical != null:
		_apply_material_recursive(mechanical, material)
	var operation_vfx := operation_vfx(visual)
	if operation_vfx != null:
		operation_vfx.visible = false


static func operational_rotor(visual: Node3D) -> Node3D:
	if visual == null:
		return null
	return visual.get_node_or_null(
		"Mechanical/OperationalRotor"
	) as Node3D


static func operation_vfx(visual: Node3D) -> Node3D:
	var rotor := operational_rotor(visual)
	if rotor == null:
		return null
	return rotor.get_node_or_null("OperationVfx") as Node3D


static func _apply_material_recursive(
	node: Node,
	material: Material
) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.material_override = material
		mesh_instance.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
	for child: Node in node.get_children():
		_apply_material_recursive(child, material)
