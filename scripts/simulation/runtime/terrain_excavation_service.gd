class_name TerrainExcavationService
extends RefCounted

const EPSILON := 0.000001
const DEFAULT_SDF_SCALE := 1.0
const HAND_DRILL_SDF_SCALE := 0.8


func excavate(voxel_tool: VoxelTool, request: Dictionary) -> Dictionary:
	if voxel_tool == null:
		return _result(&"not_ready")
	var stamp_kind := StringName(request.get("stamp_kind", &""))
	if (
		stamp_kind != &"sphere"
		and stamp_kind != &"path"
		and stamp_kind != &"mesh"
	):
		return _result(&"invalid_request")
	var terrain: Node3D = request.get("terrain")
	var budget_m3 := float(request.get("volume_budget_m3", INF))
	if budget_m3 <= 0.0:
		return _result(&"budget_exhausted")
	request = _fit_request_to_budget(request, terrain, budget_m3)
	if request.is_empty():
		return _result(&"budget_exhausted")
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


## Upper-bound estimate of the stamp's removable volume (world m³).
func _estimate_stamp_volume_m3(request: Dictionary) -> float:
	var sdf_scale := clampf(
		float(request.get("sdf_scale", DEFAULT_SDF_SCALE)),
		0.05,
		1.0
	)
	match StringName(request.get("stamp_kind", &"")):
		&"sphere":
			return sphere_volume_m3(float(request.get("radius", 0.0))) * sdf_scale
		&"path":
			var radii: PackedFloat32Array = request.get(
				"radii",
				PackedFloat32Array()
			)
			var total := 0.0
			for radius: float in radii:
				total += sphere_volume_m3(radius)
			return total * sdf_scale
		&"mesh":
			var stamp: Transform3D = request.get(
				"transform",
				Transform3D.IDENTITY
			)
			return (
				stamp.basis.x.length()
				* stamp.basis.y.length()
				* stamp.basis.z.length()
				* sdf_scale
			)
	return 0.0


## Shrink the stamp uniformly so its estimated volume fits the budget;
## reject ({}) when the fitted stamp would be too small to touch voxels.
func _fit_request_to_budget(
	request: Dictionary,
	terrain: Node3D,
	budget_m3: float
) -> Dictionary:
	var estimate := _estimate_stamp_volume_m3(request)
	if estimate <= budget_m3 or estimate <= EPSILON:
		return request
	var scale: float = pow(budget_m3 / estimate, 1.0 / 3.0)
	var min_radius := TerrainImpactCarver.minimum_measurable_radius_m(terrain)
	var fitted := request.duplicate(true)
	match StringName(request.get("stamp_kind", &"")):
		&"sphere":
			var radius := float(request.get("radius", 0.0)) * scale
			if radius < min_radius:
				return {}
			fitted["radius"] = radius
		&"path":
			var radii: PackedFloat32Array = request.get(
				"radii",
				PackedFloat32Array()
			)
			var scaled := PackedFloat32Array()
			var max_radius := 0.0
			for radius: float in radii:
				scaled.append(radius * scale)
				max_radius = maxf(max_radius, radius * scale)
			if max_radius < min_radius:
				return {}
			fitted["radii"] = scaled
		&"mesh":
			var stamp: Transform3D = request.get(
				"transform",
				Transform3D.IDENTITY
			)
			stamp.basis = stamp.basis.scaled(Vector3.ONE * scale)
			var smallest := minf(
				stamp.basis.x.length(),
				minf(stamp.basis.y.length(), stamp.basis.z.length())
			)
			if smallest < min_radius * 2.0:
				return {}
			fitted["transform"] = stamp
	return fitted


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
		&"mesh":
			var mesh_sdf: VoxelMeshSDF = request.get("mesh_sdf")
			if mesh_sdf == null or not mesh_sdf.is_baked():
				return {}
			var world_transform: Transform3D = request.get(
				"transform",
				Transform3D.IDENTITY
			)
			# do_mesh expects the stamp transform in terrain-local space
			# (do_mesh_chunked: "transform is local to the terrain").
			var local_transform := world_transform
			if terrain != null:
				local_transform = (
					terrain.global_transform.affine_inverse()
					* world_transform
				)
			return {
				"stamp_kind": stamp_kind,
				"mesh_sdf": mesh_sdf,
				"transform": local_transform,
				"isolevel": float(request.get("isolevel", 0.0)),
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
		&"mesh":
			voxel_tool.do_mesh(
				request["mesh_sdf"],
				request["transform"],
				float(request.get("isolevel", 0.0))
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
		&"mesh":
			var mesh_sdf: VoxelMeshSDF = request.get("mesh_sdf")
			if mesh_sdf == null:
				return {}
			var local_transform: Transform3D = request.get(
				"transform",
				Transform3D.IDENTITY
			)
			var stamp_aabb: AABB = local_transform * mesh_sdf.get_aabb()
			points.append(stamp_aabb.get_center())
			radii.append(stamp_aabb.size.length() * 0.5)
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
		1 << VoxelBuffer.CHANNEL_SDF
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
	match StringName(request["stamp_kind"]):
		&"sphere":
			return Vector3(request["center"])
		&"mesh":
			var stamp_transform: Transform3D = request.get(
				"transform",
				Transform3D.IDENTITY
			)
			return stamp_transform.origin
		_:
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
