extends RigidBody3D

signal structure_event_applied(kind: String)

const CartLocomotionScript = preload("res://scripts/rover/cart_locomotion.gd")
const CartStructureAdapterScript = preload(
	"res://scripts/rover/cart_structure_adapter.gd"
)

@export var wheel_radius := 0.4
@export var rest_length := 0.6
@export var spring_stiffness := 1600.0
@export var spring_damping := 400.0
@export var drive_torque := 65.0
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
var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _structure: RefCounted
var _locomotion: RefCounted


func _ready() -> void:
	_anchors = [
		$WheelFrontLeft,
		$WheelFrontRight,
		$WheelRearLeft,
		$WheelRearRight,
	]
	_world = SimulationWorld.new()
	_world.name = "SimulationWorld"
	add_child(_world)
	_projection = SimulationPhysicsProjection.new()
	_projection.name = "SimulationPhysicsProjection"
	add_child(_projection)

	_structure = CartStructureAdapterScript.new()
	_structure.structure_changed.connect(_on_structure_changed)
	if not _structure.setup(_world, _projection, self):
		push_error("Cart rover kernel setup failed")
	_projection.bind_world(_world)

	_locomotion = CartLocomotionScript.new()
	_locomotion.wheel_radius = wheel_radius
	_locomotion.rest_length = rest_length
	_locomotion.spring_stiffness = spring_stiffness
	_locomotion.spring_damping = spring_damping
	_locomotion.drive_torque = drive_torque
	_locomotion.brake_torque = brake_torque
	_locomotion.longitudinal_grip = longitudinal_grip
	_locomotion.lateral_grip = lateral_grip
	_locomotion.slip_stiffness = slip_stiffness
	_locomotion.lateral_stiffness = lateral_stiffness
	_locomotion.wheel_inertia = wheel_inertia
	_locomotion.max_steering_angle = max_steering_angle
	_locomotion.steering_response = steering_response
	_locomotion.bind(
		self,
		_anchors,
		Callable(_structure, "is_wheel_active")
	)


func set_drive_command(throttle: float, brake: float) -> void:
	_locomotion.set_drive_command(throttle, brake)


func set_steering_command(steering: float) -> void:
	_locomotion.set_steering_command(steering)


func is_slipping() -> bool:
	return _locomotion.is_slipping()


func is_lateral_slipping() -> bool:
	return _locomotion.is_lateral_slipping()


func request_attach_frame_element(cell: Vector3i) -> bool:
	return _structure.request_attach_frame_element(cell)


func request_detach_frame_element(cell: Vector3i) -> bool:
	return _structure.request_detach_frame_element(cell)


func request_detach_wheel(wheel_index: int) -> bool:
	return _structure.request_detach_wheel(wheel_index)


func structure_element_count() -> int:
	return _structure.structure_element_count()


func structure_total_mass() -> float:
	return _structure.structure_total_mass()


func structure_has_element(cell: Vector3i) -> bool:
	return _structure.structure_has_element(cell)


func structure_event_count() -> int:
	return _structure.structure_event_count()


func spawned_fragments() -> Array[RigidBody3D]:
	return _structure.spawned_fragments()


func active_wheel_count() -> int:
	return _structure.active_wheel_count()


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
	_locomotion.physics_step(delta)


func _on_structure_changed(change: Dictionary) -> void:
	structure_event_applied.emit(String(change["kind"]))
