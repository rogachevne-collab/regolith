class_name ColliderDefinition
extends Resource

enum ShapeKind {
	BOX,
	CYLINDER,
}

@export var shape_kind: ShapeKind = ShapeKind.BOX
@export var local_cell: Vector3i = Vector3i.ZERO
@export var size: Vector3 = Vector3.ONE * GridMetric.CELL_SIZE_M
@export var offset_in_cell: Vector3 = GridMetric.CELL_CENTER_OFFSET_M


func aabb_half_extents() -> Vector3:
	match shape_kind:
		ShapeKind.CYLINDER:
			var radius := size.x * 0.5
			return Vector3(radius, size.y * 0.5, radius)
		_:
			return size * 0.5


func volume_m3() -> float:
	match shape_kind:
		ShapeKind.CYLINDER:
			var radius := size.x * 0.5
			return PI * radius * radius * size.y
		_:
			return size.x * size.y * size.z


func make_physics_shape() -> Shape3D:
	match shape_kind:
		ShapeKind.CYLINDER:
			var shape := CylinderShape3D.new()
			shape.radius = size.x * 0.5
			shape.height = size.y
			return shape
		_:
			var shape := BoxShape3D.new()
			shape.size = size
			return shape


func make_preview_mesh(scale: float = 0.96) -> Mesh:
	match shape_kind:
		ShapeKind.CYLINDER:
			var mesh := CylinderMesh.new()
			mesh.top_radius = size.x * 0.5 * scale
			mesh.bottom_radius = size.x * 0.5 * scale
			mesh.height = size.y * scale
			mesh.radial_segments = 24
			return mesh
		_:
			var mesh := BoxMesh.new()
			mesh.size = size * scale
			return mesh
