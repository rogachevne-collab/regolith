extends RigidBody3D

signal fragment_spawned(fragment: RigidBody3D)

const BLOCK_SIZE := 1.0
const DEFAULT_ELEMENT_MASS := 50.0
const DIRECTIONS: Array[Vector3i] = [
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK,
]

@export var accept_debug_input := false

var _elements: Dictionary = {}
var _element_mesh: BoxMesh
var _element_shape: BoxShape3D
var _element_material: StandardMaterial3D


func _ready() -> void:
	add_to_group("assemblies")
	_ensure_resources()
	_ensure_granular_body()


## Every assembly stands in loose material the same way — rover, dozer, fragment
## broken off one. Attached here rather than per archetype because the coupling
## is a property of being a body in a medium, not of what the body is for: it
## reads the collision shapes and nothing else.
##
## Idle where there is no material, and self-configuring: the component waits
## for `build_from` to give this body its shapes before it measures anything.
func _ensure_granular_body() -> void:
	for child in get_children():
		if child is GranularBody:
			return
	var coupling := GranularBody.new()
	coupling.name = "GranularBody"
	add_child(coupling)


func build_from(cells: Array[Vector3i]) -> void:
	var masses: Array[float] = []
	for _cell: Vector3i in cells:
		masses.append(DEFAULT_ELEMENT_MASS)
	build_from_with_masses(cells, masses)


func build_from_with_masses(
	cells: Array[Vector3i],
	masses: Array[float]
) -> void:
	_ensure_resources()
	_clear_elements()
	for index: int in cells.size():
		var element_mass: float = (
			masses[index] if index < masses.size()
			else DEFAULT_ELEMENT_MASS
		)
		_add_element_data(cells[index], element_mass)
	_rebuild_body(Vector3.ZERO, false)


func attach_element(
	cell: Vector3i,
	element_mass: float = DEFAULT_ELEMENT_MASS
) -> bool:
	if _elements.has(cell) or element_mass <= 0.0:
		return false
	if not _elements.is_empty() and not _has_neighbor(cell):
		return false
	if Engine.is_in_physics_frame():
		call_deferred("_attach_element_now", cell, element_mass)
	else:
		_attach_element_now(cell, element_mass)
	return true


func detach_element(cell: Vector3i) -> bool:
	if not _elements.has(cell) or _elements.size() <= 1:
		return false
	if Engine.is_in_physics_frame():
		call_deferred("_detach_element_now", cell)
	else:
		_detach_element_now(cell)
	return true


func element_count() -> int:
	return _elements.size()


func total_mass() -> float:
	var result := 0.0
	for cell: Vector3i in _elements:
		result += float(_elements[cell]["mass"])
	return result


func has_element(cell: Vector3i) -> bool:
	return _elements.has(cell)


func element_cells() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for cell: Vector3i in _elements:
		cells.append(cell)
	return cells


func _unhandled_input(event: InputEvent) -> void:
	if (
		not accept_debug_input
		or not event is InputEventKey
		or not event.pressed
		or event.echo
	):
		return
	if event.physical_keycode == KEY_J:
		_detach_random_edge()
	elif event.physical_keycode == KEY_H:
		_attach_random_neighbor()


func _attach_element_now(cell: Vector3i, element_mass: float) -> void:
	if _elements.has(cell):
		return
	var old_com_world: Vector3 = _world_center_of_mass()
	var had_elements: bool = not _elements.is_empty()
	_add_element_data(cell, element_mass)
	_rebuild_body(old_com_world, had_elements)


func _detach_element_now(cell: Vector3i) -> void:
	if not _elements.has(cell) or _elements.size() <= 1:
		return

	var old_transform: Transform3D = global_transform
	var old_linear_velocity: Vector3 = linear_velocity
	var old_angular_velocity: Vector3 = angular_velocity
	var old_com_world: Vector3 = _world_center_of_mass()
	var detached_mass: float = float(_elements[cell]["mass"])
	_remove_element_data(cell)

	var fragment_specs: Array[Dictionary] = [{
		"cells": _typed_cells([cell]),
		"masses": _typed_masses([detached_mass]),
	}]
	var components: Array = _connected_components()
	var root_cell: Vector3i = (
		Vector3i.ZERO if _elements.has(Vector3i.ZERO)
		else _first_element_cell()
	)
	for component_value: Variant in components:
		var component: Array[Vector3i] = component_value
		if component.has(root_cell):
			continue
		var component_masses: Array[float] = []
		for component_cell: Vector3i in component:
			component_masses.append(
				float(_elements[component_cell]["mass"])
			)
		fragment_specs.append({
			"cells": component.duplicate(),
			"masses": component_masses,
		})
		for component_cell: Vector3i in component:
			_remove_element_data(component_cell)

	_rebuild_body(old_com_world, true)
	for spec: Dictionary in fragment_specs:
		_spawn_fragment(
			spec["cells"],
			spec["masses"],
			old_transform,
			old_com_world,
			old_linear_velocity,
			old_angular_velocity
		)


func _spawn_fragment(
	cells: Array[Vector3i],
	masses: Array[float],
	source_transform: Transform3D,
	source_com_world: Vector3,
	source_linear_velocity: Vector3,
	source_angular_velocity: Vector3
) -> void:
	var assembly_scene: PackedScene = load(
		"res://scenes/assembly.tscn"
	)
	var fragment: RigidBody3D = assembly_scene.instantiate()
	fragment.freeze = true
	fragment.set("accept_debug_input", false)
	get_parent().add_child(fragment)
	fragment.global_transform = source_transform
	fragment.call("build_from_with_masses", cells, masses)
	var fragment_com_world: Vector3 = fragment.to_global(
		fragment.center_of_mass
	)
	fragment.freeze = false
	fragment.angular_velocity = source_angular_velocity
	fragment.linear_velocity = (
		source_linear_velocity
		+ source_angular_velocity.cross(
			fragment_com_world - source_com_world
		)
	)
	fragment.sleeping = false
	fragment_spawned.emit(fragment)


func _rebuild_body(
	old_com_world: Vector3,
	compensate_velocity: bool
) -> void:
	var new_mass := 0.0
	var weighted_center := Vector3.ZERO
	for cell: Vector3i in _elements:
		var element_mass: float = float(_elements[cell]["mass"])
		new_mass += element_mass
		weighted_center += Vector3(cell) * BLOCK_SIZE * element_mass

	mass = maxf(new_mass, 0.001)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = (
		weighted_center / new_mass
		if new_mass > 0.0 else Vector3.ZERO
	)
	inertia = Vector3.ZERO
	if compensate_velocity:
		var new_com_world: Vector3 = _world_center_of_mass()
		linear_velocity += angular_velocity.cross(
			new_com_world - old_com_world
		)
	sleeping = false


func _add_element_data(cell: Vector3i, element_mass: float) -> void:
	var visual := MeshInstance3D.new()
	visual.name = "ElementVisual_%d_%d_%d" % [
		cell.x,
		cell.y,
		cell.z,
	]
	visual.position = Vector3(cell) * BLOCK_SIZE
	visual.mesh = _element_mesh
	add_child(visual)

	var collision := CollisionShape3D.new()
	collision.name = "ElementCollision_%d_%d_%d" % [
		cell.x,
		cell.y,
		cell.z,
	]
	collision.position = Vector3(cell) * BLOCK_SIZE
	collision.shape = _element_shape
	add_child(collision)

	_elements[cell] = {
		"mass": element_mass,
		"visual": visual,
		"collision": collision,
	}


func _remove_element_data(cell: Vector3i) -> void:
	if not _elements.has(cell):
		return
	var element: Dictionary = _elements[cell]
	var visual: MeshInstance3D = element["visual"]
	var collision: CollisionShape3D = element["collision"]
	_elements.erase(cell)
	remove_child(visual)
	remove_child(collision)
	visual.queue_free()
	collision.queue_free()


func _clear_elements() -> void:
	var cells: Array[Vector3i] = element_cells()
	for cell: Vector3i in cells:
		_remove_element_data(cell)


func _connected_components() -> Array:
	var components: Array = []
	var visited: Dictionary = {}
	for start: Vector3i in _elements:
		if visited.has(start):
			continue
		var component: Array[Vector3i] = []
		var queue: Array[Vector3i] = [start]
		visited[start] = true
		while not queue.is_empty():
			var cell: Vector3i = queue.pop_front()
			component.append(cell)
			for direction: Vector3i in DIRECTIONS:
				var neighbor: Vector3i = cell + direction
				if _elements.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		components.append(component)
	return components


func _has_neighbor(cell: Vector3i) -> bool:
	for direction: Vector3i in DIRECTIONS:
		if _elements.has(cell + direction):
			return true
	return false


func _neighbor_count(cell: Vector3i) -> int:
	var count := 0
	for direction: Vector3i in DIRECTIONS:
		if _elements.has(cell + direction):
			count += 1
	return count


func _first_element_cell() -> Vector3i:
	for cell: Vector3i in _elements:
		return cell
	return Vector3i.ZERO


func _detach_random_edge() -> void:
	var candidates: Array[Vector3i] = []
	for cell: Vector3i in _elements:
		if _neighbor_count(cell) < DIRECTIONS.size():
			candidates.append(cell)
	if candidates.is_empty():
		return
	var index: int = randi_range(0, candidates.size() - 1)
	detach_element(candidates[index])


func _attach_random_neighbor() -> void:
	var candidates: Dictionary = {}
	for cell: Vector3i in _elements:
		for direction: Vector3i in DIRECTIONS:
			var candidate: Vector3i = cell + direction
			if not _elements.has(candidate):
				candidates[candidate] = true
	if candidates.is_empty():
		return
	var cells: Array[Vector3i] = []
	for candidate: Vector3i in candidates:
		cells.append(candidate)
	var index: int = randi_range(0, cells.size() - 1)
	attach_element(cells[index])


func _world_center_of_mass() -> Vector3:
	return to_global(center_of_mass)


func _typed_cells(values: Array) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for value: Vector3i in values:
		result.append(value)
	return result


func _typed_masses(values: Array) -> Array[float]:
	var result: Array[float] = []
	for value: float in values:
		result.append(value)
	return result


func _ensure_resources() -> void:
	if _element_mesh != null:
		return
	_element_material = StandardMaterial3D.new()
	_element_material.albedo_color = Color(0.38, 0.44, 0.52)
	_element_material.metallic = 0.78
	_element_material.roughness = 0.34

	_element_mesh = BoxMesh.new()
	_element_mesh.size = Vector3.ONE * 0.94
	_element_mesh.material = _element_material

	_element_shape = BoxShape3D.new()
	_element_shape.size = Vector3.ONE * BLOCK_SIZE
