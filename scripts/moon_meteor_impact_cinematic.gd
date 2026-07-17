extends Node3D

## Offline cinematic: huge meteor slams baked moon crust, crater + debris.

const CAMERA_DISTANCE_M := 2300.0
const CAMERA_FOV_DEG := 40.0
const VIEWPORT_SIZE := 768
const HEIGHT_W := 512
const HEIGHT_H := 256
const MESH_SEGMENTS := 320
const MESH_RINGS := 160
const FRAME_COUNT := 72
const IMPACT_FRAME := 28
const FRAMES_DIR := "/tmp/moon_impact_frames"

const CRATER_RADIUS_M := 118.0
const CRATER_DEPTH_M := 40.0
const METEOR_RADIUS_M := 82.0

const _LUNAR_SKY_DECOR := preload("res://scenes/lunar_sky_decor.tscn")
const _SKY_MAT := preload("res://resources/sky/lunar_starfield_sky_material.tres")
const _IMPACT_VFX := preload("res://scenes/vfx/kinetic_impact_burst.tscn")
const _CraterStamp := preload("res://scripts/props/moon_crater_stamp.gd")

var _height_image: Image
var _heights: PackedFloat32Array
var _moon_pivot: Node3D
var _moon_mi: MeshInstance3D
var _meteor: Node3D
var _camera: Camera3D
var _world_root: Node3D
var _impact_done := false
var _impact_normal := Vector3.UP
var _impact_world_point_at_hit := Vector3.ZERO
var _impact_world_normal_at_hit := Vector3.UP
var _debris: Array[Dictionary] = []
var _cam_dir := Vector3.ZERO
var _meteor_start := Vector3.ZERO
var _meteor_end := Vector3.ZERO


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(FRAMES_DIR)
	for i in FRAME_COUNT:
		var stale := "%s/frame_%03d.png" % [FRAMES_DIR, i]
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(stale)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(VIEWPORT_SIZE, VIEWPORT_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.positional_shadow_atlas_size = 2048
	add_child(viewport)

	_world_root = Node3D.new()
	viewport.add_child(_world_root)

	_height_image = MoonHeightmapUtil.ensure_heightmap()
	if _height_image == null or _height_image.get_width() <= 0:
		push_error("MOON_IMPACT: missing crust heightmap")
		get_tree().quit(1)
		return

	_heights = _sample_height_map()

	_moon_pivot = Node3D.new()
	_world_root.add_child(_moon_pivot)
	_moon_mi = MeshInstance3D.new()
	_moon_mi.mesh = _mesh_from_heights()
	_moon_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_moon_mi.material_override = _make_moon_material()
	_moon_pivot.add_child(_moon_mi)

	var env := WorldEnvironment.new()
	env.environment = _make_environment()
	_world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(0.98, 0.99, 1.0)
	sun.light_energy = 1.55
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 5000.0
	sun.rotation_degrees = Vector3(-30.0, 122.0, 0.0)
	_world_root.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.55, 0.62, 0.82)
	fill.light_energy = 0.22
	fill.rotation_degrees = Vector3(30.0, -50.0, 0.0)
	_world_root.add_child(fill)

	var rim := DirectionalLight3D.new()
	rim.light_color = Color(0.72, 0.8, 0.96)
	rim.light_energy = 0.38
	rim.shadow_enabled = false
	rim.rotation_degrees = Vector3(14.0, 122.0 - 180.0, 0.0)
	_world_root.add_child(rim)

	_cam_dir = Vector3(0.68, 0.3, 0.67).normalized()
	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = CAMERA_FOV_DEG
	_camera.far = 9000.0
	_world_root.add_child(_camera)
	_camera.look_at_from_position(_cam_dir * CAMERA_DISTANCE_M, Vector3.ZERO, Vector3.UP)

	var decor: LunarSkyDecor = _LUNAR_SKY_DECOR.instantiate()
	decor.earth_direction = Vector3(0.28, 0.92, 0.28)
	decor.angular_diameter_deg = 5.8
	decor.distance_m = 12000.0
	decor.hide_below_horizon = false
	_world_root.add_child(decor)
	decor.sun_light_path = sun.get_path()
	decor.camera_path = _camera.get_path()

	_meteor = _make_meteor()
	_world_root.add_child(_meteor)
	_setup_meteor_flight()

	for _warm in 10:
		await get_tree().process_frame

	for frame_idx in FRAME_COUNT:
		_update_scene(frame_idx)
		for _i in 3:
			await get_tree().process_frame

		var img: Image = viewport.get_texture().get_image()
		if img == null or img.is_empty():
			push_error("MOON_IMPACT: empty frame %d" % frame_idx)
			get_tree().quit(1)
			return
		img.flip_y()
		var path := "%s/frame_%03d.png" % [FRAMES_DIR, frame_idx]
		img.save_png(path)
		print("MOON_IMPACT: frame %d/%d" % [frame_idx + 1, FRAME_COUNT])

	print("MOON_IMPACT: done → %s" % FRAMES_DIR)
	get_tree().quit(0)


func _update_scene(frame_idx: int) -> void:
	_moon_pivot.rotation.y = TAU * float(frame_idx) / float(FRAME_COUNT)

	if frame_idx == IMPACT_FRAME:
		_do_impact()

	if frame_idx <= IMPACT_FRAME:
		var approach_t := clampf(float(frame_idx) / float(IMPACT_FRAME), 0.0, 1.0)
		_meteor.visible = true
		_place_meteor_approach(approach_t)
	else:
		_meteor.visible = false
		_advance_debris(float(frame_idx - IMPACT_FRAME))


func _do_impact() -> void:
	if _impact_done:
		return
	_impact_done = true
	## Stamp where the camera-facing patch is at this rotation.
	_impact_normal = (
		_moon_pivot.global_transform.affine_inverse().basis * _cam_dir
	).normalized()
	_impact_world_point_at_hit = _cam_dir * MoonGeometry.SURFACE_RADIUS_M
	_impact_world_normal_at_hit = _cam_dir
	_CraterStamp.apply_to_heights(
		_heights, HEIGHT_W, HEIGHT_H, _impact_normal, CRATER_RADIUS_M, CRATER_DEPTH_M
	)
	_moon_mi.mesh = _mesh_from_heights()
	_spawn_impact_vfx()
	_spawn_debris_chunks()


func _setup_meteor_flight() -> void:
	## Straight world-space path into the camera-facing hemisphere — meteor does not spin.
	var target := _cam_dir * MoonGeometry.SURFACE_RADIUS_M
	var tangent := Vector3.UP.cross(_cam_dir)
	if tangent.length_squared() < 0.0001:
		tangent = Vector3.RIGHT
	tangent = tangent.normalized()
	_meteor_start = target + _cam_dir * 680.0 + tangent * -240.0 + Vector3.UP * 90.0
	_meteor_end = target + _cam_dir * METEOR_RADIUS_M * 0.32
	var flight_dir := (_meteor_end - _meteor_start).normalized()
	if flight_dir.length_squared() > 0.0001:
		_meteor.look_at(_meteor_start + flight_dir, Vector3.UP)


func _place_meteor_approach(t: float) -> void:
	var eased := t * t * (3.0 - 2.0 * t)
	_meteor.global_position = _meteor_start.lerp(_meteor_end, eased)


func _spawn_impact_vfx() -> void:
	var burst: Node3D = _IMPACT_VFX.instantiate()
	_world_root.add_child(burst)
	burst.global_position = _impact_world_point_at_hit
	burst.look_at(_impact_world_point_at_hit + _impact_world_normal_at_hit, Vector3.UP)
	_prime_vfx(burst)


func _spawn_debris_chunks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5046367
	for i in 12:
		var chunk := MeshInstance3D.new()
		chunk.mesh = _make_rock_chunk_mesh(rng)
		chunk.material_override = _make_moon_material()
		chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_world_root.add_child(chunk)
		var tangent := Vector3.UP.cross(_impact_world_normal_at_hit)
		if tangent.length_squared() < 0.001:
			tangent = Vector3.RIGHT
		tangent = tangent.normalized()
		var bitangent := _impact_world_normal_at_hit.cross(tangent).normalized()
		var disk := tangent * rng.randf_range(-1.0, 1.0) + bitangent * rng.randf_range(-1.0, 1.0)
		if disk.length_squared() < 0.01:
			disk = tangent
		disk = disk.normalized()
		var spawn := (
			_impact_world_point_at_hit
			+ _impact_world_normal_at_hit * 8.0
			+ disk * rng.randf_range(0.0, 32.0)
		)
		chunk.global_position = spawn
		chunk.scale = Vector3.ONE * rng.randf_range(0.35, 1.1) * 14.0
		var outward := (spawn - _impact_world_point_at_hit * 0.92).normalized()
		var speed := rng.randf_range(55.0, 145.0)
		_debris.append({
			"node": chunk,
			"velocity": (
				outward * speed
				+ _impact_world_normal_at_hit * rng.randf_range(18.0, 55.0)
			),
			"spin": Vector3(
				rng.randf_range(-2.5, 2.5),
				rng.randf_range(-2.5, 2.5),
				rng.randf_range(-2.5, 2.5)
			),
		})


func _advance_debris(dt_frames: float) -> void:
	var dt := dt_frames / 24.0
	for item in _debris:
		var node: Node3D = item["node"]
		if node == null or not is_instance_valid(node):
			continue
		var vel: Vector3 = item["velocity"]
		var spin: Vector3 = item["spin"]
		vel += -node.global_position.normalized() * 12.0 * dt
		vel *= pow(0.985, dt_frames)
		item["velocity"] = vel
		node.global_position += vel * dt
		node.rotation += spin * dt


func _make_meteor() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.38, 0.34)
	mat.roughness = 0.92
	mat.metallic = 0.05
	var rng := RandomNumberGenerator.new()
	rng.seed = 99173
	for i in 5:
		var blob := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = METEOR_RADIUS_M * rng.randf_range(0.35, 0.85)
		sphere.height = sphere.radius * 2.0
		sphere.radial_segments = 16
		sphere.rings = 10
		blob.mesh = sphere
		blob.material_override = mat
		blob.position = Vector3(
			rng.randf_range(-0.55, 0.55),
			rng.randf_range(-0.45, 0.45),
			rng.randf_range(-0.55, 0.55)
		) * METEOR_RADIUS_M * 0.55
		root.add_child(blob)
	root.scale = Vector3.ONE * 1.35
	return root


func _make_rock_chunk_mesh(rng: RandomNumberGenerator) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = rng.randf_range(0.8, 1.4)
	mesh.height = mesh.radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 6
	return mesh


func _prime_vfx(root: Node) -> void:
	if root is GPUParticles3D and root.one_shot:
		root.restart()
		root.emitting = true
	for child_node in root.get_children():
		_prime_vfx(child_node)


func _make_environment() -> Environment:
	var environment := Environment.new()
	var sky := Sky.new()
	sky.sky_material = _SKY_MAT.duplicate()
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.12, 0.14, 0.2)
	environment.ambient_light_energy = 0.22
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.02
	environment.ssao_enabled = false
	return environment


func _make_moon_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.7, 0.67)
	var albedo: Texture2D = load("res://resources/moon_regolith_albedo.jpg")
	var normal: Texture2D = load("res://resources/moon_regolith_normal.jpg")
	if albedo != null:
		mat.albedo_texture = albedo
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = 1.1
	mat.uv1_triplanar = true
	mat.uv1_triplanar_sharpness = 10.0
	mat.uv1_scale = Vector3(0.012, 0.012, 0.012)
	mat.roughness = 0.97
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true
	return mat


func _sample_height_map() -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(HEIGHT_W * HEIGHT_H)
	for y in HEIGHT_H:
		var v := (float(y) + 0.5) / float(HEIGHT_H)
		for x in HEIGHT_W:
			var u := (float(x) + 0.5) / float(HEIGHT_W)
			data[y * HEIGHT_W + x] = _sample_baked_meters(u, v)
	return data


func _sample_baked_meters(u: float, v: float) -> float:
	return _sample_baked_voxels(u, v) * MoonGeometry.VOXEL_SCALE


func _sample_baked_voxels(u: float, v: float) -> float:
	var w := _height_image.get_width()
	var h := _height_image.get_height()
	var sx := fposmod(u, 1.0) * float(w)
	var sy := clampf(v, 0.0, 1.0) * float(h - 1)
	var x0 := int(floor(sx)) % w
	var x1 := (x0 + 1) % w
	var y0 := clampi(int(floor(sy)), 0, h - 1)
	var y1 := clampi(y0 + 1, 0, h - 1)
	var fx := sx - floorf(sx)
	var fy := sy - floorf(sy)
	var h00 := _height_image.get_pixel(x0, y0).r
	var h10 := _height_image.get_pixel(x1, y0).r
	var h01 := _height_image.get_pixel(x0, y1).r
	var h11 := _height_image.get_pixel(x1, y1).r
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


func _mesh_from_heights() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := MoonGeometry.SURFACE_RADIUS_M
	for ring in MESH_RINGS:
		var v0 := float(ring) / float(MESH_RINGS)
		var v1 := float(ring + 1) / float(MESH_RINGS)
		for seg in MESH_SEGMENTS:
			var u0 := float(seg) / float(MESH_SEGMENTS)
			var u1 := float(seg + 1) / float(MESH_SEGMENTS)
			var n00 := _sphere_point(u0 * TAU, v0 * PI)
			var n10 := _sphere_point(u1 * TAU, v0 * PI)
			var n01 := _sphere_point(u0 * TAU, v1 * PI)
			var n11 := _sphere_point(u1 * TAU, v1 * PI)
			var h00 := _sample_h(u0, v0)
			var h10 := _sample_h(u1, v0)
			var h01 := _sample_h(u0, v1)
			var h11 := _sample_h(u1, v1)
			var p00 := n00 * (r0 + h00)
			var p10 := n10 * (r0 + h10)
			var p01 := n01 * (r0 + h01)
			var p11 := n11 * (r0 + h11)
			var N00 := _analytic_normal(n00, h00, u0, v0)
			var N10 := _analytic_normal(n10, h10, u1, v0)
			var N01 := _analytic_normal(n01, h01, u0, v1)
			var N11 := _analytic_normal(n11, h11, u1, v1)
			_add_tri(st, p00, p01, p11, N00, N01, N11, h00, h01, h11)
			_add_tri(st, p00, p11, p10, N00, N11, N10, h00, h11, h10)
	st.generate_tangents()
	return st.commit()


func _analytic_normal(n: Vector3, h: float, u: float, v: float) -> Vector3:
	var eps_u := 1.0 / float(HEIGHT_W)
	var eps_v := 1.0 / float(HEIGHT_H)
	var r0 := MoonGeometry.SURFACE_RADIUS_M
	var n_u := _sphere_point((u + eps_u) * TAU, v * PI)
	var n_v := _sphere_point(u * TAU, clampf(v + eps_v, 0.0, 1.0) * PI)
	var h_u := _sample_h(u + eps_u, v)
	var h_v := _sample_h(u, clampf(v + eps_v, 0.0, 1.0))
	var p := n * (r0 + h)
	var p_u := n_u * (r0 + h_u)
	var p_v := n_v * (r0 + h_v)
	var normal := (p_u - p).cross(p_v - p)
	if normal.length_squared() < 0.000001:
		return n
	return normal.normalized()


func _sample_h(u: float, v: float) -> float:
	var x := fposmod(u, 1.0) * float(HEIGHT_W)
	var y := clampf(v, 0.0, 1.0) * float(HEIGHT_H - 1)
	var x0 := int(floor(x)) % HEIGHT_W
	var x1 := (x0 + 1) % HEIGHT_W
	var y0 := clampi(int(floor(y)), 0, HEIGHT_H - 1)
	var y1 := clampi(y0 + 1, 0, HEIGHT_H - 1)
	var fx := x - floorf(x)
	var fy := y - floorf(y)
	var h00 := _heights[y0 * HEIGHT_W + x0]
	var h10 := _heights[y0 * HEIGHT_W + x1]
	var h01 := _heights[y1 * HEIGHT_W + x0]
	var h11 := _heights[y1 * HEIGHT_W + x1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


func _sphere_point(theta: float, phi: float) -> Vector3:
	return Vector3(
		sin(phi) * cos(theta),
		cos(phi),
		sin(phi) * sin(theta)
	).normalized()


func _add_tri(
	st: SurfaceTool,
	a: Vector3, b: Vector3, c: Vector3,
	na: Vector3, nb: Vector3, nc: Vector3,
	ha: float, hb: float, hc: float
) -> void:
	_add_vert(st, a, na, ha)
	_add_vert(st, b, nb, hb)
	_add_vert(st, c, nc, hc)


func _add_vert(st: SurfaceTool, p: Vector3, n: Vector3, h: float) -> void:
	var ao := clampf(1.0 + h / 32.0, 0.4, 1.0)
	st.set_normal(n)
	st.set_color(Color(ao, ao, ao))
	var pn := p.normalized()
	st.set_uv(Vector2(pn.x * 0.5 + 0.5, pn.z * 0.5 + 0.5))
	st.add_vertex(p)
