class_name ColliderDefinition
extends Resource

enum ShapeKind {
	BOX,
}

@export var shape_kind: ShapeKind = ShapeKind.BOX
@export var local_cell: Vector3i = Vector3i.ZERO
@export var size: Vector3 = Vector3.ONE
@export var offset_in_cell: Vector3 = Vector3(0.5, 0.5, 0.5)
