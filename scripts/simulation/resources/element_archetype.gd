class_name ElementArchetype
extends Resource

enum StructuralSurfacePolicy {
	INFER,
	FULL_SURFACE,
	MOUNT_PADS,
	NONE,
}

@export var archetype_id: String = ""
@export var display_name: String = ""
@export var roles: PackedStringArray = PackedStringArray()
@export var mass_kg: float = 1.0
@export var footprint_cells: Array[Vector3i] = [Vector3i.ZERO]
@export var colliders: Array[ColliderDefinition] = []
@export var max_integrity: float = 100.0
@export var ports: Array[PortDefinition] = []
@export var structural_surface_policy: StructuralSurfacePolicy = (
	StructuralSurfacePolicy.INFER
)
@export var structural_mount_pads: Array[StructuralMountPad] = []
@export var build_requirements: Array[BuildRequirement] = []
@export var piston_definition: PistonDefinition
@export var rotor_definition: RotorDefinition
@export var hinge_definition: HingeDefinition
@export var suspension_definition: SuspensionDefinition
@export var wheel_definition: WheelDefinition
@export var thruster_definition: ThrusterDefinition
@export var gyro_definition: GyroDefinition
@export var internal_archetype: bool = false


func is_piston_base() -> bool:
	return piston_definition != null


func is_rotor_base() -> bool:
	return rotor_definition != null


func is_hinge_base() -> bool:
	return hinge_definition != null


func is_wheel() -> bool:
	return wheel_definition != null


func is_suspension() -> bool:
	return suspension_definition != null


func is_thruster() -> bool:
	return thruster_definition != null


func is_gyro() -> bool:
	return gyro_definition != null


func resolved_structural_surface_policy() -> StructuralSurfacePolicy:
	match structural_surface_policy:
		StructuralSurfacePolicy.INFER:
			if roles.has("Frame"):
				return StructuralSurfacePolicy.FULL_SURFACE
			return StructuralSurfacePolicy.MOUNT_PADS
		_:
			return structural_surface_policy


func effective_mount_pads() -> Array[StructuralMountPad]:
	if not structural_mount_pads.is_empty():
		return structural_mount_pads
	var pads: Array[StructuralMountPad] = []
	for port: PortDefinition in ports:
		if not _is_authored_structural_port(port):
			continue
		var pad := StructuralMountPad.new()
		pad.local_cell = port.local_cell
		pad.local_face = port.local_face
		pads.append(pad)
	return pads


func _is_authored_structural_port(port: PortDefinition) -> bool:
	return (
		port != null
		and port.kind == PortDefinition.Kind.MECHANICAL
		and port.compatibility_tags.has("structural")
	)


func get_occupied_cells(
	origin_cell: Vector3i,
	orientation_index: int
) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for local_cell: Vector3i in footprint_cells:
		var rotated: Vector3i = OrientationUtil.rotate_cell(
			local_cell,
			orientation_index
		)
		result.append(origin_cell + rotated)
	return result
