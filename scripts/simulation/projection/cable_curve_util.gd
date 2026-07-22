class_name CableCurveUtil
extends RefCounted
## Shape of a hanging rope span. One source of truth for the placed cable mesh
## and for the live rope that trails the cursor while routing, so what the
## player drags is exactly what gets built.

## Parabolic approximation of a catenary: for rest length L over span d,
## L ≈ d·(1 + 8/3·(s/d)²) → s = d·√(3·(L/d − 1)/8). Good to a few percent for
## the slack range the wheel offers, and it costs one sqrt.
static func sag_depth_m(span_m: float, rest_length_m: float) -> float:
	if span_m <= 0.000001:
		return 0.0
	var ratio := rest_length_m / span_m
	if ratio <= 1.000001:
		return 0.0
	return span_m * sqrt(3.0 * (ratio - 1.0) / 8.0)


## Samples the span from `from` to `to`, dipping along −`up`. A near-vertical
## span keeps its dip proportional to the horizontal share, otherwise a rope
## hanging straight down would bulge sideways for no reason.
static func sample_span(
	from: Vector3,
	to: Vector3,
	rest_length_m: float,
	up: Vector3,
	segments: int = 12
) -> PackedVector3Array:
	var points := PackedVector3Array()
	var span := to - from
	var length := span.length()
	if length <= 0.000001 or segments < 1:
		points.append(from)
		points.append(to)
		return points
	var sag := sag_depth_m(length, rest_length_m)
	if sag > 0.0:
		var vertical := absf(span.dot(up))
		var horizontal := sqrt(maxf(length * length - vertical * vertical, 0.0))
		sag *= horizontal / length
	if sag <= 0.002:
		points.append(from)
		points.append(to)
		return points
	for step: int in range(segments + 1):
		var t := float(step) / float(segments)
		points.append(
			from
			+ span * t
			- up * (sag * 4.0 * t * (1.0 - t))
		)
	return points


## Render resolution, decoupled from simulation resolution: a Catmull-Rom pass
## through the solved particles, subdivided by how sharply the rope turns at
## each one. Straight runs stay at one segment per particle, an elbow gets up to
## MAX_SUBDIVISIONS. This is where "adaptive" belongs — the physics stays
## uniform (stable, cheap, corrections propagate evenly) and only the mesh gets
## dense where the eye can tell.
const MIN_SUBDIVISIONS := 1
const MAX_SUBDIVISIONS := 6
## Turn angle at which a joint is considered a full elbow, in radians.
const FULL_BEND_RAD := 1.0


static func smooth_adaptive(points: PackedVector3Array) -> PackedVector3Array:
	if points.size() < 3:
		return points
	var result := PackedVector3Array()
	result.append(points[0])
	for index: int in range(points.size() - 1):
		var previous := points[maxi(index - 1, 0)]
		var start := points[index]
		var end := points[index + 1]
		var next := points[mini(index + 2, points.size() - 1)]
		var subdivisions := _subdivisions_for(previous, start, end, next)
		for step: int in range(1, subdivisions + 1):
			result.append(
				_catmull_rom(
					previous,
					start,
					end,
					next,
					float(step) / float(subdivisions)
				)
			)
	return result


## Sharper of the two joints bounding this span decides how finely it is cut.
static func _subdivisions_for(
	previous: Vector3,
	start: Vector3,
	end: Vector3,
	next: Vector3
) -> int:
	var bend := maxf(
		_turn_angle(previous, start, end),
		_turn_angle(start, end, next)
	)
	return int(round(lerpf(
		float(MIN_SUBDIVISIONS),
		float(MAX_SUBDIVISIONS),
		clampf(bend / FULL_BEND_RAD, 0.0, 1.0)
	)))


static func _turn_angle(a: Vector3, b: Vector3, c: Vector3) -> float:
	var incoming := b - a
	var outgoing := c - b
	if (
		incoming.length_squared() <= 0.000001
		or outgoing.length_squared() <= 0.000001
	):
		return 0.0
	return incoming.normalized().angle_to(outgoing.normalized())


static func _catmull_rom(
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	t: float
) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		2.0 * p1
		+ (p2 - p0) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3
	)


## One continuous tube extruded along the sampled path with parallel-transport
## frames, so the section never twists through bends. Shared by the placed
## cables and by the rope trailing the cursor — same mesh code, same look.
static func build_tube_mesh(
	path: PackedVector3Array,
	radius: float,
	ring_segments: int = 8
) -> ArrayMesh:
	if path.size() < 2:
		return ArrayMesh.new()
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array[PackedVector3Array] = []
	var ring_normals: Array[PackedVector3Array] = []
	var normal := Vector3.UP
	var first_tangent := (path[1] - path[0]).normalized()
	if absf(first_tangent.dot(normal)) > 0.95:
		normal = Vector3.RIGHT
	for index: int in range(path.size()):
		var previous := path[maxi(index - 1, 0)]
		var next := path[mini(index + 1, path.size() - 1)]
		var tangent := next - previous
		if tangent.length_squared() < 0.0000001:
			tangent = first_tangent
		tangent = tangent.normalized()
		normal = (normal - tangent * normal.dot(tangent))
		if normal.length_squared() < 0.0001:
			normal = tangent.cross(Vector3.UP)
			if normal.length_squared() < 0.0001:
				normal = tangent.cross(Vector3.RIGHT)
		normal = normal.normalized()
		var binormal := tangent.cross(normal).normalized()
		var ring := PackedVector3Array()
		var normals := PackedVector3Array()
		for segment: int in range(ring_segments):
			var angle := TAU * float(segment) / float(ring_segments)
			var offset := normal * cos(angle) + binormal * sin(angle)
			ring.append(path[index] + offset * radius)
			normals.append(offset)
		rings.append(ring)
		ring_normals.append(normals)
	for ring_index: int in range(rings.size() - 1):
		for segment: int in range(ring_segments):
			var next_segment := (segment + 1) % ring_segments
			var a := rings[ring_index][segment]
			var b := rings[ring_index][next_segment]
			var c := rings[ring_index + 1][next_segment]
			var d := rings[ring_index + 1][segment]
			var na := ring_normals[ring_index][segment]
			var nb := ring_normals[ring_index][next_segment]
			var nc := ring_normals[ring_index + 1][next_segment]
			var nd := ring_normals[ring_index + 1][segment]
			surface.set_normal(na)
			surface.add_vertex(a)
			surface.set_normal(nb)
			surface.add_vertex(b)
			surface.set_normal(nc)
			surface.add_vertex(c)
			surface.set_normal(na)
			surface.add_vertex(a)
			surface.set_normal(nc)
			surface.add_vertex(c)
			surface.set_normal(nd)
			surface.add_vertex(d)
	return surface.commit()


## Polyline through every routed point, each span sagging on its own. Legacy
## скобы keep working: they simply cut the rope into shorter spans.
static func sample_route(
	points: PackedVector3Array,
	rest_length_m: float,
	up: Vector3,
	segments_per_span: int = 12
) -> PackedVector3Array:
	if points.size() < 2:
		return points
	var straight := 0.0
	for index: int in range(points.size() - 1):
		straight += points[index].distance_to(points[index + 1])
	var slack_ratio := 1.0
	if straight > 0.000001 and rest_length_m > 0.0:
		slack_ratio = maxf(rest_length_m / straight, 1.0)
	var result := PackedVector3Array()
	for index: int in range(points.size() - 1):
		var span_length := points[index].distance_to(points[index + 1])
		var span := sample_span(
			points[index],
			points[index + 1],
			span_length * slack_ratio,
			up,
			segments_per_span
		)
		for point_index: int in range(span.size()):
			if index > 0 and point_index == 0:
				continue
			result.append(span[point_index])
	return result
