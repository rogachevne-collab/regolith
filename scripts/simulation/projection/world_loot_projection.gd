class_name WorldLootProjection
extends Node3D
## Gameplay presentation for authoritative WorldLootPile records.
## Polling is intentional: loot mutations are non-structural and currently expose
## a read model rather than presentation events.

const LOOT_RADIUS := 0.16
const LOOT_MASS_REFERENCE_KG := 12.0
const LOOT_SCALE_MIN := 0.75
const LOOT_SCALE_MAX := 1.35
const LOOT_COLOR := Color(0.44, 0.38, 0.31, 1.0)
const _CODEC := preload("res://scripts/simulation/snapshot_codec.gd")

var _world: SimulationWorld
var _signature := ""
var _material: StandardMaterial3D


func bind(world: SimulationWorld) -> void:
	_world = world
	_material = _make_material()
	rebuild_all()


func _process(_delta: float) -> void:
	if _world == null:
		return
	var rows := _world.list_world_loot_piles()
	var signature := _rows_signature(rows)
	if signature == _signature:
		return
	_rebuild(rows)


func rebuild_all() -> void:
	if _world == null:
		return
	_rebuild(_world.list_world_loot_piles())


func _rebuild(rows: Array[Dictionary]) -> void:
	for child: Node in get_children():
		child.queue_free()
	for row: Dictionary in rows:
		var pile := _make_pile(row)
		if pile != null:
			add_child(pile)
	_signature = _rows_signature(rows)


func _make_pile(row: Dictionary) -> StaticBody3D:
	var pile_id := int(row.get("pile_id", 0))
	var resource_id := str(row.get("resource_id", ""))
	var amount_kg := float(row.get("amount_kg", 0.0))
	if pile_id <= 0 or resource_id.is_empty() or amount_kg <= 0.000001:
		return null

	var body := StaticBody3D.new()
	body.name = "WorldLootPile_%d" % pile_id
	body.position = _CODEC.vector3_from_variant(
		row.get("position", Vector3.ZERO)
	)
	body.collision_layer = 2
	body.collision_mask = 0
	body.set_meta("interaction_metadata", {
		"loot_pile_id": pile_id,
		"resource_id": resource_id,
		"amount_kg": amount_kg,
	})

	var shape_node := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	var scale := _loot_scale_for_mass(amount_kg)
	shape.radius = LOOT_RADIUS * scale
	shape_node.shape = shape
	shape_node.position.y = shape.radius * 0.5
	body.add_child(shape_node)

	var visual := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = LOOT_RADIUS * scale
	mesh.height = LOOT_RADIUS * scale * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	visual.mesh = mesh
	visual.material_override = _material
	visual.scale = Vector3(1.35, 0.55, 1.1)
	visual.position.y = shape.radius * 0.5
	body.add_child(visual)
	return body


static func _loot_scale_for_mass(amount_kg: float) -> float:
	var ratio := maxf(amount_kg / LOOT_MASS_REFERENCE_KG, 0.2)
	return clampf(pow(ratio, 1.0 / 3.0), LOOT_SCALE_MIN, LOOT_SCALE_MAX)


func _rows_signature(rows: Array[Dictionary]) -> String:
	var parts := PackedStringArray()
	for row: Dictionary in rows:
		parts.append("%d:%s:%.4f:%s" % [
			int(row.get("pile_id", 0)),
			str(row.get("resource_id", "")),
			float(row.get("amount_kg", 0.0)),
			str(row.get("position", Vector3.ZERO)),
		])
	return "|".join(parts)


func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = LOOT_COLOR
	material.roughness = 0.92
	material.metallic = 0.08
	return material
