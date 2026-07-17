class_name MoonCraterStamp
extends RefCounted

## Heightfield crater profile for offline moon cinematics (matches huge-basin look).


static func sample_delta_m(t: float, depth_m: float, rim_frac: float = 0.22) -> float:
	var carve := 0.0
	var rim := 0.0
	if t < 1.0:
		var floor_depth := -depth_m * 0.86
		if t < 0.38:
			if t < 0.26:
				var peak := exp(-pow(t / 0.19, 2.0))
				carve = floor_depth + depth_m * 0.12 * peak
			else:
				carve = floor_depth
		else:
			var wall_t := (t - 0.38) / 0.62
			var bowl := 0.5 + 0.5 * cos(PI * wall_t)
			bowl = bowl * bowl
			carve = lerpf(floor_depth, 0.0, 1.0 - bowl)
	if t > 0.88:
		var falloff := smoothstep(1.85, 0.92, t) * exp(-maxf(0.0, t - 1.0) * 1.6)
		rim = depth_m * rim_frac * 0.38 * falloff
	else:
		var rim_bump := exp(-pow((t - 1.0) / 0.17, 2.0))
		rim = depth_m * rim_frac * 0.3 * rim_bump
	return carve + rim


static func apply_to_heights(
	heights: PackedFloat32Array,
	width: int,
	height: int,
	impact_dir: Vector3,
	radius_m: float,
	depth_m: float
) -> void:
	var center := impact_dir.normalized()
	var rim_frac := 0.22
	for y in height:
		var v := (float(y) + 0.5) / float(height)
		for x in width:
			var u := (float(x) + 0.5) / float(width)
			var n := _sphere_point(u * TAU, v * PI)
			var angle := acos(clampf(n.dot(center), -1.0, 1.0))
			var edge_angle := asin(clampf(radius_m / MoonGeometry.SURFACE_RADIUS_M, 0.02, 0.45))
			var t := angle / edge_angle
			if t > 1.85:
				continue
			var delta := sample_delta_m(t, depth_m, rim_frac)
			var idx := y * width + x
			heights[idx] = clampf(heights[idx] + delta, -MoonTerrainParams.HEIGHT_CLAMP_M, MoonTerrainParams.HEIGHT_CLAMP_M)


static func apply_pierce_channel(
	heights: PackedFloat32Array,
	width: int,
	height: int,
	entry_dir: Vector3,
	exit_dir: Vector3,
	radius_m: float,
	depth_m: float,
	steps: int = 9
) -> void:
	var a := entry_dir.normalized()
	var b := exit_dir.normalized()
	for i in steps:
		var w := float(i) / float(steps - 1)
		var dir := a.slerp(b, w).normalized()
		var falloff := 1.0 - absf(w - 0.5) * 0.35
		apply_to_heights(
			heights,
			width,
			height,
			dir,
			radius_m * lerpf(0.72, 1.0, falloff),
			depth_m * lerpf(0.85, 1.0, falloff)
		)


static func _sphere_point(theta: float, phi: float) -> Vector3:
	return Vector3(
		sin(phi) * cos(theta),
		cos(phi),
		sin(phi) * sin(theta)
	).normalized()
