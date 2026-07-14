class_name TerrainExcavationService
extends RefCounted

const EPSILON := 0.000001
const DEFAULT_SDF_SCALE := 1.0
const HAND_DRILL_SDF_SCALE := 0.8


func excavate(voxel_tool: VoxelTool, request: Dictionary) -> Dictionary:
	if voxel_tool == null:
		return _result(&"not_ready")
	var stamp_kind := StringName(request.get("stamp_kind", &""))
	if stamp_kind != &"sphere" and stamp_kind != &"path":
		return _result(&"invalid_request")
	var terrain: Node3D = request.get("terrain")
	var local_request := _to_local_request(terrain, request)
	if local_request.is_empty():
		return _result(&"invalid_request")
	var bounds := _sample_bounds(local_request)
	if bounds.is_empty():
		return _result(&"invalid_request")
	var sample_area := _sample_area(bounds)
	if not voxel_tool.is_area_editable(sample_area):
		return _result(&"terrain_unavailable")
	var before := _copy_sdf(voxel_tool, bounds)
	_apply_stamp(voxel_tool, local_request)
	var after := _copy_sdf(voxel_tool, bounds)
	var cell_volume_m3: float = VoxelSpaceUtil.cell_volume_m3(terrain)
	var removed_volume_m3: float = (
		_removed_volume_m3(before, after) * cell_volume_m3
	)
	return _result(
		&"ok",
		{
			"removed_volume_m3": removed_volume_m3,
			"contact_point": _contact_point(request),
		}
	)


func _to_local_request(
	terrain: Node3D,
	request: Dictionary
) -> Dictionary:
	var stamp_kind := StringName(request.get("stamp_kind", &""))
	match stamp_kind:
		&"sphere":
			var radius := float(request.get("radius", 0.0))
			if radius <= EPSILON:
				return {}
			var center := Vector3(request.get("center", Vector3.ZERO))
			return {
				"stamp_kind": stamp_kind,
				"center": VoxelSpaceUtil.world_to_local(terrain, center),
				"radius": VoxelSpaceUtil.world_distance_to_local(
					terrain,
					radius
				),
				"sdf_scale": request.get(
					"sdf_scale",
					DEFAULT_SDF_SCALE
				),
			}
		&"path":
			var points: PackedVector3Array = request.get(
				"points",
				PackedVector3Array()
			)
			var radii: PackedFloat32Array = request.get(
				"radii",
				PackedFloat32Array()
			)
			if points.is_empty() or points.size() != radii.size():
				return {}
			var local_points := PackedVector3Array()
			var local_radii := PackedFloat32Array()
			for index: int in range(points.size()):
				var radius := float(radii[index])
				if radius <= EPSILON:
					return {}
				local_points.append(
					VoxelSpaceUtil.world_to_local(terrain, points[index])
				)
				local_radii.append(
					VoxelSpaceUtil.world_distance_to_local(terrain, radius)
				)
			return {
				"stamp_kind": stamp_kind,
				"points": local_points,
				"radii": local_radii,
				"sdf_scale": request.get(
					"sdf_scale",
					DEFAULT_SDF_SCALE
				),
			}
		_:
			return {}


func _apply_stamp(voxel_tool: VoxelTool, request: Dictionary) -> void:
	voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	voxel_tool.mode = VoxelTool.MODE_REMOVE
	voxel_tool.sdf_strength = clampf(
		float(request.get("sdf_scale", DEFAULT_SDF_SCALE)),
		0.05,
		1.0
	)
	match StringName(request["stamp_kind"]):
		&"sphere":
			voxel_tool.do_sphere(
				Vector3(request["center"]),
				float(request["radius"])
			)
		&"path":
			voxel_tool.do_path(
				request["points"],
				request["radii"]
			)


func _sample_bounds(request: Dictionary) -> Dictionary:
	var points := PackedVector3Array()
	var radii := PackedFloat32Array()
	match StringName(request.get("stamp_kind", &"")):
		&"sphere":
			var radius := float(request.get("radius", 0.0))
			if radius <= EPSILON:
				return {}
			points.append(Vector3(request.get("center", Vector3.ZERO)))
			radii.append(radius)
		&"path":
			points = request.get("points", PackedVector3Array())
			radii = request.get("radii", PackedFloat32Array())
			if points.is_empty() or points.size() != radii.size():
				return {}
			for radius: float in radii:
				if radius <= EPSILON:
					return {}
		_:
			return {}
	var min_point := points[0]
	var max_point := points[0]
	var max_radius := 0.0
	for index: int in range(points.size()):
		var point := points[index]
		min_point = Vector3(
			minf(min_point.x, point.x),
			minf(min_point.y, point.y),
			minf(min_point.z, point.z)
		)
		max_point = Vector3(
			maxf(max_point.x, point.x),
			maxf(max_point.y, point.y),
			maxf(max_point.z, point.z)
		)
		max_radius = maxf(max_radius, radii[index])
	var margin := max_radius + 1.0
	return {
		"min": Vector3i(
			floori(min_point.x - margin),
			floori(min_point.y - margin),
			floori(min_point.z - margin)
		),
		"max": Vector3i(
			ceili(max_point.x + margin),
			ceili(max_point.y + margin),
			ceili(max_point.z + margin)
		),
	}


func _sample_area(bounds: Dictionary) -> AABB:
	var min_cell: Vector3i = bounds["min"]
	var max_cell: Vector3i = bounds["max"]
	return AABB(
		Vector3(min_cell),
		Vector3(max_cell - min_cell + Vector3i.ONE)
	)


func _copy_sdf(
	voxel_tool: VoxelTool,
	bounds: Dictionary
) -> VoxelBuffer:
	var min_cell: Vector3i = bounds["min"]
	var max_cell: Vector3i = bounds["max"]
	var size := max_cell - min_cell + Vector3i.ONE
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	voxel_tool.copy(
		min_cell,
		buffer,
		1 << VoxelBuffer.CHANNEL_SDF,
		false
	)
	return buffer


func _removed_volume_m3(
	before: VoxelBuffer,
	after: VoxelBuffer
) -> float:
	var removed_cells := 0.0
	var size := before.get_size()
	for x: int in range(size.x):
		for y: int in range(size.y):
			for z: int in range(size.z):
				var before_occupancy := sdf_occupancy(
					before.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				)
				var after_occupancy := sdf_occupancy(
					after.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				)
				removed_cells += maxf(
					before_occupancy - after_occupancy,
					0.0
				)
	return removed_cells


func _contact_point(request: Dictionary) -> Vector3:
	if StringName(request["stamp_kind"]) == &"sphere":
		return Vector3(request["center"])
	var points: PackedVector3Array = request["points"]
	return points[points.size() - 1]


func _result(status: StringName, extra: Dictionary = {}) -> Dictionary:
	var result := {
		"status": status,
		"removed_volume_m3": 0.0,
		"contact_point": Vector3.ZERO,
	}
	result.merge(extra, true)
	return result


static func sdf_occupancy(sdf: float) -> float:
	return clampf(0.5 - sdf, 0.0, 1.0)


static func sphere_volume_m3(radius: float) -> float:
	return (4.0 / 3.0) * PI * radius * radius * radius
