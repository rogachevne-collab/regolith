class_name PortDefinition
extends Resource

enum Kind {
	MECHANICAL,
	ELECTRIC,
	FLUID,
	GAS,
	DATA,
	THERMAL,
	MECHANICAL_POWER,
	CARGO,
}

@export var port_id: String = ""
@export var kind: Kind = Kind.MECHANICAL
@export var local_cell: Vector3i = Vector3i.ZERO
@export var local_face: OrientationUtil.Face = OrientationUtil.Face.POS_X
@export var face_slot: int = 0
@export var compatibility_tags: PackedStringArray = PackedStringArray()
