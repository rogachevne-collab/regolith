extends RigidBody3D

signal structure_event_applied(kind: String)

const StructureModelScript = preload("res://scripts/structure_model.gd")
const FRAME_ELEMENT_MASS := 340.0 / 11.0
const WHEEL_ELEMENT_MASS := 15.0
const WHEEL_SUPPORT_CELLS: Array[Vector3i] = [
	Vector3i(-1, 0, -1),
	Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1),
	Vector3i(1, 0, 1),
]
const WHEEL_ELEMENT_CELLS: Array[Vector3i] = [
	Vector3i(-2, 0, -1),
	Vector3i(2, 0, -1),
	Vector3i(-2, 0, 1),
	Vector3i(2, 0, 1),
]

@export var wheel_radius := 0.4
@export var rest_length := 0.6
@export var spring_stiffness := 1600.0
@export var spring_damping := 400.0
@export var drive_torque := 120.0
@export var brake_torque := 180.0
@export var longitudinal_grip := 1.2
@export var lateral_grip := 0.9
@export var slip_stiffness := 800.0
@export var lateral_stiffness := 1000.0
@export var wheel_inertia := 0.65
@export var max_steering_angle := 0.488692
@export var steering_response := 2.5
@export var accept_player_input := true

var _anchors: Array[Marker3D] = []
var _wheel_speeds: Array[float] = []
var _drive_command := 0.0
var _brake_command := 0.0
var _steering_command := 0.0
var _steering_angle := 0.0
var _slipping := false
var _lateral_slipping := false
var _structure_model: RefCounted
var _structure_elements: Dictionary = {}
var _frame_nodes: Dictionary = {}
var _frame_mesh: BoxMesh
var _frame_shape: BoxShape3D
var _spawned_fragments: Array[RigidBody3D] = []
var _pending_consumed_fragments: Dictionary = {}
var _structure_event_count := 0


func _ready() -> void:
	_anchors = [
		$WheelFrontLeft,
		$WheelFrontRight,
		$WheelRearLeft,
		$WheelRearRight,
	]
	_wheel_speeds.resize(_anchors.size())
	_prepare_frame_resources()
	_structure_model = StructureModelScript.new()
	_structure_model.connect(
		"structure_changed",
		Callable(self, "_on_structure_changed")
	)
	var initial_elements: Dictionary = {}
	for x: int in range(-1, 2):
		for z: int in range(-1, 2):
			initial_elements[Vector3i(x, 0, z)] = (
				_frame_element_descriptor()
			)
	initial_elements[Vector3i(0, 0, -2)] = (
		_frame_element_descriptor()
	)
	initial_elements[Vector3i(0, 0, 2)] = (
		_frame_element_descriptor()
	)
	for wheel_index: int in WHEEL_ELEMENT_CELLS.size():
		initial_elements[WHEEL_ELEMENT_CELLS[wheel_index]] = {
			"kind": "wheel",
			"mass": WHEEL_ELEMENT_MASS,
			"wheel_index": wheel_index,
		}
	_structure_model.call("initialize", initial_elements)


func set_drive_command(throttle: float, brake: float) -> void:
	_drive_command = clampf(throttle, -1.0, 1.0)
	_brake_command = clampf(brake, 0.0, 1.0)


func set_steering_command(steering: float) -> void:
	_steering_command = clampf(steering, -1.0, 1.0)


func is_slipping() -> bool:
	return _slipping


func is_lateral_slipping() -> bool:
	return _lateral_slipping


func request_attach_frame_element(cell: Vector3i) -> bool:
	var accepted: bool = bool(_structure_model.call(
		"request_attach",
		cell,
		_frame_element_descriptor()
	))
	if accepted:
		var fragment: RigidBody3D = _find_fragment_with_cell(cell)
		if fragment != null:
			_pending_consumed_fragments[cell] = fragment
	return accepted


func request_detach_frame_element(cell: Vector3i) -> bool:
	return bool(_structure_model.call("request_detach", cell))


func request_detach_wheel(wheel_index: int) -> bool:
	if wheel_index < 0 or wheel_index >= WHEEL_ELEMENT_CELLS.size():
		return false
	return bool(_structure_model.call(
		"request_detach",
		WHEEL_ELEMENT_CELLS[wheel_index]
	))


func structure_element_count() -> int:
	return _structure_elements.size()


func structure_total_mass() -> float:
	var result := 0.0
	for cell: Vector3i in _structure_elements:
		var element: Dictionary = _structure_elements[cell]
		result += float(element["mass"])
	return result


func structure_has_element(cell: Vector3i) -> bool:
	return _structure_elements.has(cell)


func structure_event_count() -> int:
	return _structure_event_count


func spawned_fragments() -> Array[RigidBody3D]:
	return _spawned_fragments.duplicate()


func active_wheel_count() -> int:
	var result := 0
	for wheel_index: int in WHEEL_ELEMENT_CELLS.size():
		if (
			_structure_elements.has(WHEEL_ELEMENT_CELLS[wheel_index])
			and _structure_elements.has(WHEEL_SUPPORT_CELLS[wheel_index])
		):
			result += 1
	return result


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_K:
		var forward: Vector3 = -global_transform.basis.z.normalized()
		apply_central_impulse(forward * mass * 2.0)
	elif event.physical_keycode == KEY_B:
		request_detach_frame_element(Vector3i.ZERO)
	elif event.physical_keycode == KEY_N:
		request_attach_frame_element(Vector3i.ZERO)
	elif event.physical_keycode == KEY_V:
		request_detach_frame_element(Vector3i(0, 0, 1))
	elif event.physical_keycode == KEY_M:
		request_detach_wheel(0)


func _physics_process(delta: float) -> void:
	if accept_player_input:
		set_drive_command(
			1.0 if Input.is_key_pressed(KEY_UP) else 0.0,
			1.0 if Input.is_key_pressed(KEY_DOWN) else 0.0
		)
		set_steering_command(
			float(Input.is_key_pressed(KEY_LEFT))
			- float(Input.is_key_pressed(KEY_RIGHT))
		)

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var down: Vector3 = -global_transform.basis.y.normalized()
	var ray_length: float = rest_length + wheel_radius
	var center_of_mass_world: Vector3 = to_global(center_of_mass)
	var body_forward: Vector3 = -global_transform.basis.z.normalized()
	_slipping = false
	_lateral_slipping = false
	_steering_angle = move_toward(
		_steering_angle,
		_steering_command * max_steering_angle,
		steering_response * delta
	)
	_anchors[0].rotation.y = _steering_angle
	_anchors[1].rotation.y = _steering_angle

	for wheel_index: int in _anchors.size():
		var anchor: Marker3D = _anchors[wheel_index]
		var wheel: MeshInstance3D = anchor.get_node("Wheel")
		if (
			not _structure_elements.has(WHEEL_ELEMENT_CELLS[wheel_index])
			or not _structure_elements.has(
				WHEEL_SUPPORT_CELLS[wheel_index]
			)
		):
			wheel.visible = false
			_integrate_free_wheel(wheel_index, delta)
			continue
		wheel.visible = true
		var origin: Vector3 = anchor.global_position
		var query: PhysicsRayQueryParameters3D = (
			PhysicsRayQueryParameters3D.create(
				origin,
				origin + down * ray_length
			)
		)
		query.exclude = [get_rid()]
		query.collision_mask = 3
		query.collide_with_areas = false
		query.collide_with_bodies = true

		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			wheel.position.y = -rest_length
			_integrate_free_wheel(wheel_index, delta)
			wheel.rotate_object_local(
				Vector3.UP,
				_wheel_speeds[wheel_index] * delta
			)
			continue

		var hit_point: Vector3 = hit["position"]
		var hit_normal: Vector3 = Vector3(hit["normal"]).normalized()
		var distance: float = origin.distance_to(hit_point)
		var compression: float = ray_length - distance
		var point_velocity: Vector3 = (
			linear_velocity
			+ angular_velocity.cross(origin - center_of_mass_world)
		)
		var velocity_along_down: float = point_velocity.dot(down)
		var force_magnitude: float = maxf(
			spring_stiffness * compression
			+ spring_damping * velocity_along_down,
			0.0
		)
		var force: Vector3 = -down * force_magnitude
		apply_force(force, origin - global_position)

		var wheel_steering: float = (
			_steering_angle if wheel_index < 2 else 0.0
		)
		var steered_forward: Vector3 = body_forward.rotated(
			hit_normal,
			wheel_steering
		)
		var wheel_forward: Vector3 = (
			steered_forward
			- hit_normal * steered_forward.dot(hit_normal)
		)
		if wheel_forward.length_squared() > 0.0001:
			wheel_forward = wheel_forward.normalized()
			var wheel_right: Vector3 = (
				wheel_forward.cross(hit_normal).normalized()
			)
			var ground_speed: float = point_velocity.dot(wheel_forward)
			var lateral_speed: float = point_velocity.dot(wheel_right)
			var slip_speed: float = (
				_wheel_speeds[wheel_index] * wheel_radius
				- ground_speed
			)
			var desired_traction: float = slip_speed * slip_stiffness
			var desired_lateral: float = -lateral_speed * lateral_stiffness
			var longitudinal_limit: float = (
				force_magnitude * longitudinal_grip
			)
			var lateral_limit: float = force_magnitude * lateral_grip
			var traction_force: float = desired_traction
			var lateral_force: float = desired_lateral
			if longitudinal_limit > 0.0 and lateral_limit > 0.0:
				var friction_usage: float = sqrt(
					pow(desired_traction / longitudinal_limit, 2.0)
					+ pow(desired_lateral / lateral_limit, 2.0)
				)
				if friction_usage > 1.0:
					traction_force /= friction_usage
					lateral_force /= friction_usage
					_slipping = true
					if absf(desired_lateral) > 0.01:
						_lateral_slipping = true
			else:
				traction_force = 0.0
				lateral_force = 0.0

			apply_force(
				wheel_forward * traction_force
				+ wheel_right * lateral_force,
				hit_point - global_position
			)
			var wheel_torque: float = (
				_drive_command * drive_torque
				- traction_force * wheel_radius
			)
			_wheel_speeds[wheel_index] += (
				wheel_torque / wheel_inertia * delta
			)
			_apply_wheel_brake(wheel_index, delta)

		wheel.position.y = -(distance - wheel_radius)
		wheel.rotate_object_local(
			Vector3.UP,
			_wheel_speeds[wheel_index] * delta
		)


func _integrate_free_wheel(wheel_index: int, delta: float) -> void:
	_wheel_speeds[wheel_index] += (
		_drive_command * drive_torque / wheel_inertia * delta
	)
	_apply_wheel_brake(wheel_index, delta)


func _apply_wheel_brake(wheel_index: int, delta: float) -> void:
	var brake_step: float = (
		_brake_command * brake_torque / wheel_inertia * delta
	)
	_wheel_speeds[wheel_index] = move_toward(
		_wheel_speeds[wheel_index],
		0.0,
		brake_step
	)


func _on_structure_changed(change: Dictionary) -> void:
	var kind: String = change["kind"]
	var had_structure: bool = not _structure_elements.is_empty()
	var old_transform: Transform3D = global_transform
	var old_com_world: Vector3 = to_global(center_of_mass)
	var old_linear_velocity: Vector3 = linear_velocity
	var old_angular_velocity: Vector3 = angular_velocity
	_structure_elements = Dictionary(change["elements"]).duplicate(true)

	_sync_frame_nodes()
	_rebuild_frame_body(old_com_world, had_structure)
	var fragment_values: Array = change["fragments"]
	for fragment_value: Variant in fragment_values:
		var fragment_spec: Dictionary = fragment_value
		_spawn_structure_fragment(
			fragment_spec,
			old_transform,
			old_com_world,
			old_linear_velocity,
			old_angular_velocity
		)
	if kind == "attach":
		var attached_cell: Vector3i = change["cell"]
		_consume_pending_fragment(attached_cell)

	_structure_event_count += 1
	structure_event_applied.emit(kind)


func _sync_frame_nodes() -> void:
	var stale_cells: Array[Vector3i] = []
	for cell: Vector3i in _frame_nodes:
		if (
			not _structure_elements.has(cell)
			or String(
				Dictionary(_structure_elements[cell]).get("kind", "")
			) != "frame"
		):
			stale_cells.append(cell)
	for cell: Vector3i in stale_cells:
		var nodes: Dictionary = _frame_nodes[cell]
		var visual: MeshInstance3D = nodes["visual"]
		var collision: CollisionShape3D = nodes["collision"]
		_frame_nodes.erase(cell)
		remove_child(visual)
		remove_child(collision)
		visual.queue_free()
		collision.queue_free()

	for cell: Vector3i in _structure_elements:
		var element: Dictionary = _structure_elements[cell]
		if String(element.get("kind", "")) != "frame":
			continue
		if _frame_nodes.has(cell):
			continue
		var visual := MeshInstance3D.new()
		visual.name = "FrameVisual_%d_%d_%d" % [
			cell.x,
			cell.y,
			cell.z,
		]
		visual.position = Vector3(cell)
		visual.mesh = _frame_mesh
		add_child(visual)

		var collision := CollisionShape3D.new()
		collision.name = "FrameCollision_%d_%d_%d" % [
			cell.x,
			cell.y,
			cell.z,
		]
		collision.position = Vector3(cell)
		collision.shape = _frame_shape
		add_child(collision)
		_frame_nodes[cell] = {
			"visual": visual,
			"collision": collision,
		}


func _rebuild_frame_body(
	old_com_world: Vector3,
	compensate_velocity: bool
) -> void:
	var new_mass := 0.0
	var weighted_center := Vector3.ZERO
	for cell: Vector3i in _structure_elements:
		var element: Dictionary = _structure_elements[cell]
		var element_mass: float = float(element["mass"])
		new_mass += element_mass
		weighted_center += Vector3(cell) * element_mass

	mass = maxf(new_mass, 0.001)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = (
		weighted_center / new_mass
		if new_mass > 0.0 else Vector3.ZERO
	)
	inertia = Vector3.ZERO
	if compensate_velocity:
		var new_com_world: Vector3 = to_global(center_of_mass)
		linear_velocity += angular_velocity.cross(
			new_com_world - old_com_world
		)
	sleeping = false


func _spawn_structure_fragment(
	fragment_spec: Dictionary,
	source_transform: Transform3D,
	source_com_world: Vector3,
	source_linear_velocity: Vector3,
	source_angular_velocity: Vector3
) -> void:
	var fragment_elements: Dictionary = fragment_spec["elements"]
	var cells: Array[Vector3i] = []
	var masses: Array[float] = []
	for cell: Vector3i in fragment_elements:
		var element: Dictionary = fragment_elements[cell]
		if String(element.get("kind", "")) == "wheel":
			_spawn_detached_wheel(
				element,
				source_com_world,
				source_linear_velocity,
				source_angular_velocity
			)
		else:
			cells.append(cell)
			masses.append(float(element["mass"]))

	if cells.is_empty():
		return

	var assembly_scene: PackedScene = load(
		"res://scenes/assembly.tscn"
	)
	var fragment: RigidBody3D = assembly_scene.instantiate()
	fragment.freeze = true
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
	_spawned_fragments.append(fragment)


func _spawn_detached_wheel(
	element: Dictionary,
	source_com_world: Vector3,
	source_linear_velocity: Vector3,
	source_angular_velocity: Vector3
) -> void:
	var wheel_index: int = int(element["wheel_index"])
	var anchor: Marker3D = _anchors[wheel_index]
	var source_wheel: MeshInstance3D = anchor.get_node("Wheel")
	var detached_wheel := RigidBody3D.new()
	detached_wheel.name = "DetachedWheel_%d" % wheel_index
	detached_wheel.collision_layer = 2
	detached_wheel.collision_mask = 3
	detached_wheel.mass = float(element["mass"])
	get_parent().add_child(detached_wheel)
	detached_wheel.global_transform = source_wheel.global_transform

	var visual := MeshInstance3D.new()
	visual.mesh = source_wheel.mesh
	detached_wheel.add_child(visual)

	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = wheel_radius
	shape.height = 0.3
	collision.shape = shape
	detached_wheel.add_child(collision)

	var axle: Vector3 = anchor.global_transform.basis.x.normalized()
	detached_wheel.linear_velocity = (
		source_linear_velocity
		+ source_angular_velocity.cross(
			detached_wheel.global_position - source_com_world
		)
	)
	detached_wheel.angular_velocity = (
		source_angular_velocity
		+ axle * _wheel_speeds[wheel_index]
	)
	detached_wheel.add_to_group("detached_wheels")
	_spawned_fragments.append(detached_wheel)


func _prepare_frame_resources() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.24, 0.31, 0.4)
	material.metallic = 0.82
	material.roughness = 0.34

	_frame_mesh = BoxMesh.new()
	_frame_mesh.size = Vector3(0.92, 0.6, 0.92)
	_frame_mesh.material = material

	_frame_shape = BoxShape3D.new()
	_frame_shape.size = Vector3(0.92, 0.6, 0.92)


func _find_fragment_with_cell(cell: Vector3i) -> RigidBody3D:
	for fragment: RigidBody3D in _spawned_fragments:
		if (
			is_instance_valid(fragment)
			and fragment.has_method("has_element")
			and bool(fragment.call("has_element", cell))
		):
			return fragment
	return null


func _consume_pending_fragment(cell: Vector3i) -> void:
	if not _pending_consumed_fragments.has(cell):
		return
	var fragment: RigidBody3D = _pending_consumed_fragments[cell]
	_pending_consumed_fragments.erase(cell)
	_spawned_fragments.erase(fragment)
	if is_instance_valid(fragment):
		fragment.queue_free()


func _frame_element_descriptor() -> Dictionary:
	return {
		"kind": "frame",
		"mass": FRAME_ELEMENT_MASS,
	}
