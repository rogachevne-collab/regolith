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
## Authored connectors. Empty = synthesized from mount pads / full surface
## (see effective_connectors), which keeps every pre-connector archetype
## working untouched.
@export var connectors: Array[ConnectorDefinition] = []
@export var build_requirements: Array[BuildRequirement] = []
@export var piston_definition: PistonDefinition
@export var rotor_definition: RotorDefinition
@export var hinge_definition: HingeDefinition
@export var suspension_definition: SuspensionDefinition
@export var wheel_definition: WheelDefinition
@export var thruster_definition: ThrusterDefinition
@export var gyro_definition: GyroDefinition
@export var internal_archetype: bool = false
## Ghost orientation seeded when the player first selects this part —
## baked from the authoring-scene pose so the part appears exactly the way
## the author placed it, instead of always identity.
@export_range(0, 23) var default_orientation_index: int = 0
## In-game model baked from the authoring scene. Empty = draw the collider
## preview meshes (how legacy blocks look).
@export var visual_scene_path: String = ""
## Shift that puts the model's minimum corner at the part origin — the same
## pivot compensation the authoring scene uses (hub-tip pivots etc.).
@export var visual_offset: Vector3 = Vector3.ZERO


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


## The part's attach points, in canonical local frame. Authored connectors
## win; otherwise they are synthesized so legacy archetypes keep their exact
## surface (grid connector ids reuse the structural id scheme, so persisted
## joint records stay valid).
func effective_connectors() -> Array[ConnectorDefinition]:
	if not connectors.is_empty():
		return connectors
	if _connector_cache_valid:
		return _synthesized_connectors
	var result: Array[ConnectorDefinition] = []
	match resolved_structural_surface_policy():
		StructuralSurfacePolicy.FULL_SURFACE:
			for face_data: Dictionary in FootprintUtil.external_faces(
				footprint_cells
			):
				result.append(ConnectorDefinition.grid_connector(
					face_data["local_cell"],
					face_data["local_face"]
				))
		StructuralSurfacePolicy.MOUNT_PADS:
			for pad: StructuralMountPad in effective_mount_pads():
				if pad == null:
					continue
				result.append(ConnectorDefinition.from_pad(pad))
		_:
			pass
	_synthesized_connectors = result
	_connector_cache_valid = true
	return result


func invalidate_connector_cache() -> void:
	_connector_cache_valid = false
	_synthesized_connectors = []


var _synthesized_connectors: Array[ConnectorDefinition] = []
var _connector_cache_valid := false


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
