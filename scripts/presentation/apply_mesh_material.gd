extends Node3D
## Re-applies material_override in _ready().
## Godot export drops overrides on editable children of instanced FBX scenes,
## so packing material_override on Box009 alone becomes white default mesh.

@export var material: Material
@export var mesh_node_name: String = "Box009"


func _ready() -> void:
	if material == null or mesh_node_name.is_empty():
		return
	var mesh_instance := find_child(mesh_node_name, true, false) as MeshInstance3D
	if mesh_instance == null:
		push_warning("ApplyMeshMaterial: mesh '%s' not found under %s" % [mesh_node_name, name])
		return
	# Only restore when export stripped the editable-instance override.
	# Preview ghosts set material_override before entering the tree — leave them.
	if mesh_instance.material_override == null:
		mesh_instance.material_override = material
