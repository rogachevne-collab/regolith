class_name ConnectorDefinition
extends Resource

## One attach point on a part, in the part's canonical local frame.
##
## Grid connectors (`is_grid`) sit on cell faces and mate by grid adjacency —
## they are the bridge into the integer topology layer (occupancy,
## connectivity, structural ids). Point connectors are free metric points
## that mate point-to-point with anti-parallel directions.
##
## `local_position` is always the anchor: joints and precise seating use it
## directly. For a plain grid connector it is simply the face centre.

## Stable id inside the part. Grid connectors reuse the structural id scheme
## ("structural_<x>_<y>_<z>_<face>") so persisted joint records keep working.
@export var id: String = ""
@export var local_position: Vector3 = Vector3.ZERO
## Outward mating direction (surface normal), part-local.
@export var local_direction: Vector3 = Vector3.UP
## Roll reference for non-symmetric connectors. ZERO = pick automatically.
@export var local_up: Vector3 = Vector3.ZERO
## Compatibility tag; pairs are allowed by ConnectorRuleTable, not code.
## Empty is normalised to "structural".
@export var tag: String = ""
## The part is rotationally symmetric around this connector's axis: roll is
## meaningless (wheels, rotors). Otherwise roll snaps in 90° steps from
## effective_up().
@export var symmetric: bool = false

@export var is_grid: bool = false
@export var grid_cell: Vector3i = Vector3i.ZERO
@export var grid_face: OrientationUtil.Face = OrientationUtil.Face.POS_X


static func grid_connector(
	cell: Vector3i,
	face: OrientationUtil.Face,
	socket_tag: String = ""
) -> ConnectorDefinition:
	var connector := ConnectorDefinition.new()
	connector.is_grid = true
	connector.grid_cell = cell
	connector.grid_face = face
	connector.tag = socket_tag
	connector.id = FootprintUtil.structural_id_for(cell, face)
	connector.local_position = FootprintUtil.face_center_local(cell, face)
	connector.local_direction = Vector3(OrientationUtil.face_to_vector(face))
	connector.symmetric = _tag_is_symmetric_by_default(socket_tag)
	return connector


static func from_pad(pad: StructuralMountPad) -> ConnectorDefinition:
	var connector := grid_connector(pad.local_cell, pad.local_face, pad.socket_tag)
	connector.local_position = pad.point_local()
	return connector


func direction_normalized() -> Vector3:
	if local_direction.is_zero_approx():
		return Vector3.UP
	return local_direction.normalized()


## Roll reference perpendicular to the mating direction.
func effective_up() -> Vector3:
	var direction := direction_normalized()
	if not local_up.is_zero_approx():
		var projected := local_up - direction * local_up.dot(direction)
		if not projected.is_zero_approx():
			return projected.normalized()
	var seed := Vector3.UP
	if absf(direction.dot(seed)) > 0.9:
		seed = Vector3.RIGHT
	return (seed - direction * seed.dot(direction)).normalized()


func normalized_tag() -> String:
	return ConnectorRuleTable.normalize_tag(tag)


static func _tag_is_symmetric_by_default(socket_tag: String) -> bool:
	return socket_tag == "wheel_plug" or socket_tag == "wheel_socket"
