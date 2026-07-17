class_name GravityField
extends Node

## Location Field gravity (PHYSICAL-LANGUAGE). Flat −Y by default; moon uses RADIAL.
## RigidBody dynamics use Area3D point gravity in the moon scene; CharacterBody
## and gameplay code read this node for local up / accel.

enum Mode {
	FLAT,
	RADIAL,
}

const GROUP_NAME := &"gravity_field"

@export var mode: Mode = Mode.FLAT
@export var center := Vector3.ZERO
@export var gravity_strength := 1.62


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func up_at(world_position: Vector3) -> Vector3:
	if mode == Mode.RADIAL:
		var away := world_position - center
		if away.length_squared() <= 0.000001:
			return Vector3.UP
		return away.normalized()
	return Vector3.UP


func gravity_accel_at(world_position: Vector3) -> Vector3:
	return -up_at(world_position) * gravity_strength


func probe_direction_toward_ground(world_position: Vector3) -> Vector3:
	return -up_at(world_position)


func tangent_basis_at(world_position: Vector3, hint_forward: Vector3 = Vector3.FORWARD) -> Basis:
	var up := up_at(world_position)
	var forward := hint_forward.slide(up)
	if forward.length_squared() <= 0.000001:
		forward = Vector3.FORWARD.slide(up)
	if forward.length_squared() <= 0.000001:
		forward = Vector3.RIGHT.slide(up)
	if forward.length_squared() <= 0.000001:
		return Basis.IDENTITY
	return Basis.looking_at(forward.normalized(), up)


static func find_in_tree(from: Node) -> GravityField:
	if from == null or not from.is_inside_tree():
		return null
	var node := from.get_tree().get_first_node_in_group(GROUP_NAME)
	return node as GravityField


static func resolve_up(from: Node, world_position: Vector3) -> Vector3:
	var field := find_in_tree(from)
	if field == null:
		return Vector3.UP
	return field.up_at(world_position)


static func resolve_gravity_accel(from: Node, world_position: Vector3) -> Vector3:
	var field := find_in_tree(from)
	if field == null:
		var strength := float(
			ProjectSettings.get_setting("physics/3d/default_gravity", 1.62)
		)
		return Vector3.DOWN * strength
	return field.gravity_accel_at(world_position)


static func project_on_tangent(vector: Vector3, up: Vector3) -> Vector3:
	return vector.slide(up)
