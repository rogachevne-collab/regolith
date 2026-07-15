class_name WheelDefinition
extends Resource

@export var radius_m: float = 0.4
@export var drive_torque_n_m: float = 65.0
@export var brake_torque_n_m: float = 180.0
@export var longitudinal_grip: float = 1.2
@export var lateral_grip: float = 0.9
@export var slip_stiffness: float = 800.0
@export var lateral_stiffness: float = 1000.0
@export var wheel_inertia: float = 0.65
@export var max_steering_angle_rad: float = 0.4887
@export var steering_response: float = 2.5
@export var steerable_default: bool = false
@export var forward_axis_face: OrientationUtil.Face = OrientationUtil.Face.POS_Z
@export var power_draw_w: float = 300.0
@export var idle_w: float = 20.0
@export var requires_socket_tag: String = "wheel_socket"


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if radius_m <= 0.0:
		errors.append("radius_m must be positive")
	if (
		drive_torque_n_m < 0.0
		or brake_torque_n_m < 0.0
		or longitudinal_grip < 0.0
		or lateral_grip < 0.0
		or slip_stiffness < 0.0
		or lateral_stiffness < 0.0
		or wheel_inertia < 0.0
		or power_draw_w < 0.0
		or idle_w < 0.0
		or max_steering_angle_rad < 0.0
		or steering_response < 0.0
	):
		errors.append("wheel tuning must be non-negative")
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	var plug_pads := 0
	for pad: StructuralMountPad in archetype.structural_mount_pads:
		if pad != null and pad.socket_tag == "wheel_plug":
			plug_pads += 1
	if plug_pads != 1:
		errors.append("drive_wheel must expose exactly one wheel_plug pad")
	return errors
