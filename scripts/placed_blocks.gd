extends Node3D

@export var block_size := 1.0

var _blocks: Dictionary = {}
var _block_material: StandardMaterial3D
var _block_mesh: BoxMesh


func _ready() -> void:
	_block_material = StandardMaterial3D.new()
	_block_material.albedo_color = Color(0.58, 0.61, 0.66)
	_block_material.metallic = 0.72
	_block_material.roughness = 0.38

	_block_mesh = BoxMesh.new()
	_block_mesh.size = Vector3.ONE * block_size


func has_block(cell: Vector3i) -> bool:
	return _blocks.has(cell)


func world_to_cell(world_pos: Vector3) -> Vector3i:
	return Vector3i(
		int(floor(world_pos.x / block_size)),
		int(floor(world_pos.y / block_size)),
		int(floor(world_pos.z / block_size))
	)


func cell_to_world(cell: Vector3i) -> Vector3:
	return Vector3(cell) * block_size + Vector3.ONE * block_size * 0.5


func placement_cell_from_hit(hit_point: Vector3, hit_normal: Vector3) -> Vector3i:
	var offset := hit_point + hit_normal.normalized() * block_size * 0.51
	return world_to_cell(offset)


func overlaps_player(cell: Vector3i, player: Node3D) -> bool:
	var block_aabb := AABB(Vector3(cell) * block_size, Vector3.ONE * block_size)
	var player_aabb := AABB(
		player.global_position + Vector3(-0.35, -0.95, -0.35),
		Vector3(0.7, 1.85, 0.7)
	)
	return block_aabb.intersects(player_aabb)


func try_place(cell: Vector3i, player: Node3D) -> bool:
	if has_block(cell):
		return false
	if overlaps_player(cell, player):
		return false

	var body := StaticBody3D.new()
	body.name = "Block_%d_%d_%d" % [cell.x, cell.y, cell.z]
	body.position = cell_to_world(cell)
	body.add_to_group("placed_blocks")
	body.set_meta("interaction_metadata", {"cell": cell})

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _block_mesh
	mesh_instance.material_override = _block_material
	body.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * block_size
	collision.shape = shape
	body.add_child(collision)

	add_child(body)
	_blocks[cell] = body
	return true
