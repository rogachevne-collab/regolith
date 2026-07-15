class_name SuspensionDefinition
extends Resource

@export var wheel_socket_face: OrientationUtil.Face = OrientationUtil.Face.NEG_Y
@export var suspension_travel_m: float = 0.6
@export var spring_stiffness_n_per_m: float = 1600.0
@export var spring_damping_n_s_per_m: float = 400.0
@export var min_travel_m: float = 0.2
@export var max_travel_m: float = 1.0
@export var max_wheels_per_socket: int = 1


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if suspension_travel_m <= 0.0:
		errors.append("suspension_travel_m must be positive")
	if suspension_travel_m < min_travel_m or suspension_travel_m > max_travel_m:
		errors.append("suspension_travel_m outside min/max travel")
	if (
		spring_stiffness_n_per_m < 0.0
		or spring_damping_n_s_per_m < 0.0
		or max_wheels_per_socket < 1
	):
		errors.append("suspension tuning must be non-negative")
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	var socket_pads := 0
	for pad: StructuralMountPad in archetype.structural_mount_pads:
		if pad != null and pad.socket_tag == "wheel_socket":
			socket_pads += 1
	if socket_pads != 1:
		errors.append("wheel_suspension must expose exactly one wheel_socket pad")
	return errors
