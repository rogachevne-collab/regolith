class_name ColliderDefinition
extends Resource

enum ShapeKind {
	BOX,
}

@export var shape_kind: ShapeKind = ShapeKind.BOX
@export var local_cell: Vector3i = Vector3i.ZERO
@export var size: Vector3 = Vector3.ONE * GridMetric.CELL_SIZE_M
@export var offset_in_cell: Vector3 = GridMetric.CELL_CENTER_OFFSET_M
