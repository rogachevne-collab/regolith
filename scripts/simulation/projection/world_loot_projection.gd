class_name WorldLootProjection
extends Node3D
## Gameplay presentation for authoritative WorldLootPile records.
## RigidBody3D owns kinematics; positions write back into simulation so
## merge-by-sphere-contact and snapshot stay consistent with Jolt.

const LOOT_COLOR := Color(0.44, 0.38, 0.31, 1.0)
const LOOT_COLLISION_LAYER := 8
const LOOT_COLLISION_MASK := 9
const MERGE_TELEPORT_DISTANCE_SQ := 0.25
const _CODEC := preload("res://scripts/simulation/snapshot_codec.gd")

var _world: SimulationWorld
var _signature := ""
var _material: StandardMaterial3D
var _physics_material: PhysicsMaterial
var _bodies: Dictionary = {}


func bind(world: SimulationWorld) -> void:
	_world = world
	_material = _make_material()
	_physics_material = _make_physics_material()
	_ensure_terrain_accepts_loot()
	rebuild_all()


func _physics_process(_delta: float) -> void:
	if _world == null:
		return
	# Piles created after bind() — every hand-drill overflow drop — only become
	# visible if we re-sync when the set changes. bind() alone renders whatever
	# existed at startup and nothing after, so a fresh drop never got a body.
	# The signature ignores position (physics owns that via write-back) and only
	# moves on add / remove / amount change, so this rebuilds just when needed.
	var rows := _world.list_world_loot_piles()
	if _rows_signature(rows) != _signature:
		_sync_piles(rows)
	_write_back_positions()


func rebuild_all() -> void:
	if _world == null:
		return
	_sync_piles(_world.list_world_loot_piles())


func _ensure_terrain_accepts_loot() -> void:
	var terrain := get_node_or_null("../../VoxelTerrain") as Node3D
	if terrain != null and not TerrainCompat.is_terrain(terrain):
		terrain = null
	if terrain == null:
		return
	terrain.collision_mask = terrain.collision_mask | LOOT_COLLISION_LAYER


func _write_back_positions() -> void:
	for pile_id_variant: Variant in _bodies.keys():
		var pile_id := int(pile_id_variant)
		var body := _bodies[pile_id] as RigidBody3D
		if body == null or not is_instance_valid(body):
			continue
		_world.sync_world_loot_position(pile_id, body.global_position)


func _sync_piles(rows: Array[Dictionary]) -> void:
	var next_ids := {}
	for row: Dictionary in rows:
		var pile_id := int(row.get("pile_id", 0))
		if pile_id <= 0:
			continue
		next_ids[pile_id] = true
		if _bodies.has(pile_id):
			_update_body(_bodies[pile_id] as RigidBody3D, row)
		else:
			var body := _make_pile(row)
			if body != null:
				add_child(body)
				_bodies[pile_id] = body
	for pile_id_variant: Variant in _bodies.keys():
		var pile_id := int(pile_id_variant)
		if next_ids.has(pile_id):
			continue
		var stale: RigidBody3D = _bodies[pile_id]
		if is_instance_valid(stale):
			stale.queue_free()
		_bodies.erase(pile_id)
	_signature = _rows_signature(rows)


func _update_body(body: RigidBody3D, row: Dictionary) -> void:
	var pile_id := int(row.get("pile_id", 0))
	var resource_id := str(row.get("resource_id", ""))
	var amount_kg := float(row.get("amount_kg", 0.0))
	_apply_mass_and_visual(body, amount_kg)
	var source_position := _CODEC.vector3_from_variant(
		row.get("position", Vector3.ZERO)
	)
	if source_position.distance_squared_to(body.global_position) > MERGE_TELEPORT_DISTANCE_SQ:
		body.global_position = source_position
	body.set_meta("interaction_metadata", {
		"loot_pile_id": pile_id,
		"resource_id": resource_id,
		"amount_kg": amount_kg,
	})


func _make_pile(row: Dictionary) -> RigidBody3D:
	var pile_id := int(row.get("pile_id", 0))
	var resource_id := str(row.get("resource_id", ""))
	var amount_kg := float(row.get("amount_kg", 0.0))
	if pile_id <= 0 or resource_id.is_empty() or amount_kg <= 0.000001:
		return null

	var body := RigidBody3D.new()
	body.name = "WorldLootPile_%d" % pile_id
	var source_position := _CODEC.vector3_from_variant(
		row.get("position", Vector3.ZERO)
	)
	body.global_position = source_position
	body.collision_layer = LOOT_COLLISION_LAYER
	body.collision_mask = LOOT_COLLISION_MASK
	body.continuous_cd = true
	body.can_sleep = true
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.linear_damp = 0.1
	body.angular_damp = 0.2
	body.physics_material_override = _physics_material
	body.mass = maxf(amount_kg, 0.05)
	body.set_meta("interaction_metadata", {
		"loot_pile_id": pile_id,
		"resource_id": resource_id,
		"amount_kg": amount_kg,
	})
	body.body_entered.connect(_on_loot_body_entered.bind(pile_id))

	var shape_node := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	var radius := _collision_radius(amount_kg)
	shape.radius = radius
	shape_node.shape = shape
	shape_node.position.y = radius * 0.5
	body.add_child(shape_node)

	var visual := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	visual.mesh = mesh
	visual.material_override = _material
	visual.scale = Vector3(1.35, 0.55, 1.1)
	visual.position.y = radius * 0.5
	body.add_child(visual)
	return body


func _on_loot_body_entered(other_body: Node, pile_id: int) -> void:
	if _world == null or not other_body is RigidBody3D:
		return
	var metadata: Variant = other_body.get_meta("interaction_metadata", {})
	if not metadata is Dictionary:
		return
	var other_pile_id := int(metadata.get("loot_pile_id", 0))
	if other_pile_id <= 0 or other_pile_id == pile_id:
		return
	if _world.try_merge_world_loot_piles(pile_id, other_pile_id):
		_sync_piles(_world.list_world_loot_piles())


func _apply_mass_and_visual(body: RigidBody3D, amount_kg: float) -> void:
	var radius := _collision_radius(amount_kg)
	body.mass = maxf(amount_kg, 0.05)
	for child_node: Node in body.get_children():
		if child_node is CollisionShape3D:
			var shape_node := child_node as CollisionShape3D
			var shape := shape_node.shape as SphereShape3D
			if shape == null:
				continue
			shape.radius = radius
			shape_node.position.y = radius * 0.5
		elif child_node is MeshInstance3D:
			var visual := child_node as MeshInstance3D
			var mesh := visual.mesh as SphereMesh
			if mesh == null:
				continue
			mesh.radius = radius
			mesh.height = radius * 2.0
			visual.position.y = radius * 0.5


static func _collision_radius(amount_kg: float) -> float:
	return IndustryArchetypeProfile.hand_drill_loot_collision_radius_m(
		amount_kg
	)


func _rows_signature(rows: Array[Dictionary]) -> String:
	var parts := PackedStringArray()
	for row: Dictionary in rows:
		parts.append("%d:%s:%.4f" % [
			int(row.get("pile_id", 0)),
			str(row.get("resource_id", "")),
			float(row.get("amount_kg", 0.0)),
		])
	return "|".join(parts)


func _make_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = LOOT_COLOR
	mat.roughness = 0.92
	mat.metallic = 0.08
	return mat


func _make_physics_material() -> PhysicsMaterial:
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = 0.55
	phys_mat.bounce = 0.05
	phys_mat.rough = true
	return phys_mat
