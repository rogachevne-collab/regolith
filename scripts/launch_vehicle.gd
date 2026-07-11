extends RigidBody3D

@export var player_path: NodePath
@export var thrust_per_engine := 78.0
@export var fuel_seconds := 28.0
@export var launch_distance := 4.5
@export var control_authority := 0.42
@export var impact_speed := 4.5
@export var impact_impulse := 18.0

@onready var _player: Node3D = get_node(player_path)
@onready var _status: Label3D = $Status

var _blocks: Dictionary = {}
var _thruster_cells: Array[Vector3i] = []
var _occupied := false
var _ever_airborne := false
var _fuel := 0.0
var _launch_height := 0.0
var _impact_cooldown := 0.0
var _peak_fall_speed := 0.0
var _damage_message := ""
var _damage_message_left := 0.0

var _armor_material: StandardMaterial3D
var _cockpit_material: StandardMaterial3D
var _battery_material: StandardMaterial3D
var _thruster_material: StandardMaterial3D
var _debris_material: StandardMaterial3D

const BLOCK_SIZE := 1.0
const COCKPIT_CELL := Vector3i(0, 1, 0)


func _ready() -> void:
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	contact_monitor = true
	max_contacts_reported = 16
	body_entered.connect(_on_body_entered)
	_make_materials()
	_build_grid()
	_recalculate_mass()
	_status.text = "ИСПЫТАТЕЛЬНЫЙ КОРАБЛЬ\nE — сесть в кокпит"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		if _occupied:
			_exit_cockpit()
		elif global_position.distance_to(_player.global_position) <= launch_distance:
			_enter_cockpit()


func _physics_process(delta: float) -> void:
	_impact_cooldown = maxf(_impact_cooldown - delta, 0.0)
	_damage_message_left = maxf(_damage_message_left - delta, 0.0)
	_peak_fall_speed = maxf(_peak_fall_speed, maxf(-linear_velocity.y, 0.0))

	if not _occupied:
		var distance := global_position.distance_to(_player.global_position)
		_status.visible = distance <= 12.0
		return

	var throttle := Input.get_action_strength("jump")
	var pitch := Input.get_axis("move_forward", "move_back")
	var roll := Input.get_axis("move_left", "move_right")
	var firing := throttle > 0.01 and _fuel > 0.0 and not _thruster_cells.is_empty()

	if firing:
		for cell in _thruster_cells:
			if not _blocks.has(cell):
				continue
			var differential := (
				1.0
				+ pitch * float(cell.z) * control_authority
				+ roll * float(cell.x) * control_authority)
			var force := global_transform.basis.y * thrust_per_engine * maxf(differential, 0.1)
			var offset := global_transform.basis * Vector3(cell)
			apply_force(force, offset)
			_set_thruster_visual(cell, true)
		_fuel = maxf(_fuel - delta, 0.0)
		if global_position.y > _launch_height + 2.0:
			_ever_airborne = true
	else:
		_set_all_thrusters(false)

	var altitude := global_position.y - _launch_height
	var flight_status := (
		"КОРАБЛЬ: %d блоков | %.0f кг\n"
		+ "Топливо %.1f с | высота %.1f м | скорость %.1f м/с\n"
		+ "Space — тяга, WASD — баланс, E — выйти"
	) % [_blocks.size(), mass, _fuel, altitude, linear_velocity.length()]
	if _damage_message_left > 0.0:
		flight_status += "\n" + _damage_message
	_status.text = flight_status


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _ever_airborne or _impact_cooldown > 0.0:
		return

	var strongest_impulse := 0.0
	for contact_index in state.get_contact_count():
		strongest_impulse = maxf(
			strongest_impulse,
			state.get_contact_impulse(contact_index).length())

	var hard_contact := (
		state.get_contact_count() > 0
		and (
			_peak_fall_speed >= impact_speed
			or strongest_impulse >= impact_impulse))
	if hard_contact:
		_impact_cooldown = 1.0
		_peak_fall_speed = 0.0
		call_deferred("_apply_impact_damage", strongest_impulse)


func _enter_cockpit() -> void:
	_occupied = true
	_fuel = fuel_seconds
	_launch_height = global_position.y
	freeze = false
	sleeping = false
	_player.enter_vehicle(self, Vector3(0.0, 1.7, 0.15))
	_status.visible = true


func _exit_cockpit() -> void:
	_occupied = false
	_set_all_thrusters(false)
	var exit_position := global_position + global_transform.basis.x * 2.2 + Vector3.UP
	_player.exit_vehicle(exit_position)


func _make_materials() -> void:
	_armor_material = _material(Color(0.32, 0.36, 0.43), 0.78, 0.34)
	_cockpit_material = _material(Color(0.08, 0.38, 0.72), 0.52, 0.2)
	_battery_material = _material(Color(0.92, 0.58, 0.06), 0.58, 0.3)
	_thruster_material = _material(Color(0.19, 0.21, 0.25), 0.88, 0.28)
	_debris_material = _material(Color(0.22, 0.23, 0.25), 0.65, 0.5)


func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	return material


func _build_grid() -> void:
	_add_block(Vector3i(0, 0, 0), "battery", 5.0)
	_add_block(COCKPIT_CELL, "cockpit", 4.0)

	for cell in [
		Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
		Vector3i(0, 0, -1), Vector3i(0, 0, 1),
	]:
		_add_block(cell, "armor", 2.5)

	for cell in [
		Vector3i(-2, 0, 0), Vector3i(2, 0, 0),
		Vector3i(0, 0, -2), Vector3i(0, 0, 2),
	]:
		_add_block(cell, "thruster", 3.5)
		_thruster_cells.append(cell)


func _add_block(cell: Vector3i, kind: String, block_mass: float) -> void:
	var root := Node3D.new()
	root.name = "%s_%d_%d_%d" % [kind, cell.x, cell.y, cell.z]
	root.position = Vector3(cell) * BLOCK_SIZE
	add_child(root)

	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 0.94
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _material_for_kind(kind)
	root.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	collision.name = "Collision_%d_%d_%d" % [cell.x, cell.y, cell.z]
	collision.position = Vector3(cell) * BLOCK_SIZE
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * 0.94
	collision.shape = shape
	add_child(collision)

	if kind == "thruster":
		_add_thruster_visuals(root)

	_blocks[cell] = {
		"kind": kind,
		"mass": block_mass,
		"root": root,
		"collision": collision,
	}


func _material_for_kind(kind: String) -> StandardMaterial3D:
	match kind:
		"cockpit":
			return _cockpit_material
		"battery":
			return _battery_material
		"thruster":
			return _thruster_material
		_:
			return _armor_material


func _add_thruster_visuals(root: Node3D) -> void:
	var nozzle := MeshInstance3D.new()
	nozzle.name = "Nozzle"
	var nozzle_mesh := CylinderMesh.new()
	nozzle_mesh.top_radius = 0.18
	nozzle_mesh.bottom_radius = 0.34
	nozzle_mesh.height = 0.5
	nozzle.mesh = nozzle_mesh
	nozzle.position = Vector3(0, -0.7, 0)
	nozzle.material_override = _thruster_material
	root.add_child(nozzle)

	var flame := MeshInstance3D.new()
	flame.name = "Flame"
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.18
	flame_mesh.bottom_radius = 0.02
	flame_mesh.height = 1.2
	flame.mesh = flame_mesh
	flame.position = Vector3(0, -1.45, 0)
	var flame_material := StandardMaterial3D.new()
	flame_material.albedo_color = Color(1.0, 0.25, 0.015)
	flame_material.emission_enabled = true
	flame_material.emission = Color(1.0, 0.08, 0.005)
	flame_material.emission_energy_multiplier = 5.0
	flame.material_override = flame_material
	flame.visible = false
	root.add_child(flame)


func _set_thruster_visual(cell: Vector3i, active: bool) -> void:
	if not _blocks.has(cell):
		return
	var root: Node3D = _blocks[cell]["root"]
	var flame := root.get_node_or_null("Flame")
	if flame != null:
		flame.visible = active


func _set_all_thrusters(active: bool) -> void:
	for cell in _thruster_cells:
		_set_thruster_visual(cell, active)


func _recalculate_mass() -> void:
	var total_mass := 0.0
	var weighted_center := Vector3.ZERO
	for cell in _blocks:
		var block_mass: float = _blocks[cell]["mass"]
		total_mass += block_mass
		weighted_center += Vector3(cell) * block_mass
	mass = maxf(total_mass, 1.0)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = weighted_center / mass


func _on_body_entered(_body: Node) -> void:
	if not _ever_airborne or _impact_cooldown > 0.0:
		return
	if _peak_fall_speed < impact_speed:
		return
	_impact_cooldown = 0.8
	_peak_fall_speed = 0.0
	call_deferred("_apply_impact_damage", 0.0)


func _apply_impact_damage(measured_impulse: float) -> void:
	var blocks_before := _blocks.size()
	_break_structural_link()
	var blocks_lost := blocks_before - _blocks.size()
	if blocks_lost > 0:
		_damage_message = (
			"УДАР %.1f Н·с: потеряно блоков — %d"
			% [measured_impulse, blocks_lost])
		_damage_message_left = 4.0


func _break_structural_link() -> void:
	var candidates := [
		Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
		Vector3i(0, 0, -1), Vector3i(0, 0, 1),
	]
	for cell in candidates:
		if _blocks.has(cell):
			_remove_block(cell, true)
			_split_disconnected_blocks()
			_recalculate_mass()
			return


func _remove_block(cell: Vector3i, spawn_debris: bool) -> void:
	if not _blocks.has(cell):
		return
	var block: Dictionary = _blocks[cell]
	var world_position := to_global(Vector3(cell))
	var kind: String = block["kind"]
	var root: Node3D = block["root"]
	var collision: CollisionShape3D = block["collision"]
	_blocks.erase(cell)
	_thruster_cells.erase(cell)
	root.queue_free()
	collision.queue_free()
	if spawn_debris:
		_spawn_debris(world_position, kind)


func _split_disconnected_blocks() -> void:
	if not _blocks.has(COCKPIT_CELL):
		return
	var connected: Dictionary = {COCKPIT_CELL: true}
	var queue: Array[Vector3i] = [COCKPIT_CELL]
	var directions: Array[Vector3i] = [
		Vector3i.LEFT, Vector3i.RIGHT, Vector3i.UP,
		Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK,
	]
	while not queue.is_empty():
		var cell: Vector3i = queue.pop_front()
		for direction: Vector3i in directions:
			var neighbor: Vector3i = cell + direction
			if _blocks.has(neighbor) and not connected.has(neighbor):
				connected[neighbor] = true
				queue.append(neighbor)

	var disconnected: Array[Vector3i] = []
	for cell in _blocks:
		if not connected.has(cell):
			disconnected.append(cell)
	for cell in disconnected:
		_remove_block(cell, true)


func _spawn_debris(world_position: Vector3, kind: String) -> void:
	var debris := RigidBody3D.new()
	debris.position = world_position
	debris.collision_layer = 2
	debris.collision_mask = 3
	debris.mass = 2.0
	debris.linear_velocity = linear_velocity
	debris.angular_velocity = angular_velocity + Vector3(
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0))

	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 0.94
	mesh_instance.mesh = mesh
	mesh_instance.material_override = (
		_material_for_kind(kind) if kind != "armor" else _debris_material)
	debris.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * 0.94
	collision.shape = shape
	debris.add_child(collision)

	get_parent().add_child(debris)
