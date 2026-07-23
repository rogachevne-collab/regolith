class_name SuspensionDefinition
extends Resource

@export var wheel_socket_face: OrientationUtil.Face = OrientationUtil.Face.NEG_Y
@export var suspension_travel_m: float = 0.6
@export var spring_stiffness_n_per_m: float = 1600.0
@export var spring_damping_n_s_per_m: float = 400.0
@export var max_suspension_force_n: float = 5000.0
@export var min_travel_m: float = 0.2
@export var max_travel_m: float = 1.0
@export var max_wheels_per_socket: int = 1


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	for value: float in [
		suspension_travel_m,
		spring_stiffness_n_per_m,
		spring_damping_n_s_per_m,
		max_suspension_force_n,
		min_travel_m,
		max_travel_m,
	]:
		if not is_finite(value):
			errors.append("suspension tuning must be finite")
			break
	if suspension_travel_m <= 0.0:
		errors.append("suspension_travel_m must be positive")
	if suspension_travel_m < min_travel_m or suspension_travel_m > max_travel_m:
		errors.append("suspension_travel_m outside min/max travel")
	if (
		spring_stiffness_n_per_m < 0.0
		or spring_damping_n_s_per_m < 0.0
		or max_suspension_force_n <= 0.0
		or max_wheels_per_socket < 1
	):
		errors.append("suspension tuning must be non-negative")
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	var socket_pads := 0
	var socket_face := OrientationUtil.Face.NEG_Y
	for pad: StructuralMountPad in archetype.structural_mount_pads:
		if pad != null and pad.socket_tag == "wheel_socket":
			socket_pads += 1
			socket_face = pad.local_face
	if socket_pads != 1:
		errors.append("a suspension must expose exactly one wheel_socket pad")
	elif socket_face != wheel_socket_face:
		errors.append("wheel socket face differs from suspension definition")
	return errors
