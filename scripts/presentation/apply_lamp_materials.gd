extends Node3D
## Housing → polystyrene; mesh named "Lamp" → emissive; optional beam light.
## Construction ghosts strip this script / set meta before enter_tree.

@export var housing_material: Material
@export var lamp_material: Material
@export var lamp_node_name: String = "Lamp"
@export var add_spot_light: bool = true


func _ready() -> void:
	if has_meta("construction_preview"):
		return

	for node: Node in _mesh_instances(self):
		var mi := node as MeshInstance3D
		# Preview tint already applied — do not clobber (antenna contract).
		if mi.material_override != null:
			continue
		if _is_lamp_mesh(mi):
			if lamp_material != null:
				mi.material_override = lamp_material
		elif housing_material != null:
			mi.material_override = housing_material

	if add_spot_light and get_node_or_null("Beam") == null:
		var spot := SpotLight3D.new()
		spot.name = "Beam"
		# FBX lens aims local −Z (SpotLight default).
		spot.position = Vector3(0.0, 0.25, -0.05)
		spot.light_color = Color(1.0, 0.95, 0.82)
		spot.light_energy = 2.2
		spot.spot_range = 28.0
		spot.spot_angle = 32.0
		spot.shadow_enabled = false
		add_child(spot)


func _is_lamp_mesh(mi: MeshInstance3D) -> bool:
	var key := lamp_node_name.strip_edges().to_lower()
	return not key.is_empty() and mi.name.strip_edges().to_lower() == key


func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		out.append_array(_mesh_instances(child))
	return out
