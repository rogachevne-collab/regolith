extends Node3D

## Orbital spin preview: baked crust + moon_experiment sky/Earth decor → PNG frames.

const CAMERA_DISTANCE_M := 2300.0
const CAMERA_FOV_DEG := 40.0
const VIEWPORT_SIZE := 768
const HEIGHT_W := 512
const HEIGHT_H := 256
const MESH_SEGMENTS := 320
const MESH_RINGS := 160
const FRAME_COUNT := 48
const FRAMES_DIR := "/tmp/moon_spin_frames"
const OUTPUT_GIF := "/tmp/moon_spin.gif"

const _LUNAR_SKY_DECOR := preload("res://scenes/lunar_sky_decor.tscn")
const _SKY_MAT := preload("res://resources/sky/lunar_starfield_sky_material.tres")

var _height_image: Image
var _heights: PackedFloat32Array
var _moon_pivot: Node3D


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

	var world_root := Node3D.new()
	viewport.add_child(world_root)

	_height_image = MoonHeightmapUtil.ensure_heightmap()
	if _height_image == null or _height_image.get_width() <= 0:
		push_error("MOON_SPIN: missing crust heightmap")
		get_tree().quit(1)
		return

	print("MOON_SPIN: baking mesh %dx%d, %d frames" % [MESH_SEGMENTS, MESH_RINGS, FRAME_COUNT])
	_heights = _sample_height_map()
	var mesh := _mesh_from_heights()

	_moon_pivot = Node3D.new()
	world_root.add_child(_moon_pivot)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.material_override = _make_moon_material()
	_moon_pivot.add_child(mi)

	var env := WorldEnvironment.new()
	env.environment = _make_moon_experiment_environment()
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(0.98, 0.99, 1.0)
	sun.light_energy = 1.55
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 5000.0
	sun.rotation_degrees = Vector3(-30.0, 122.0, 0.0)
	world_root.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.55, 0.62, 0.82)
	fill.light_energy = 0.22
	fill.rotation_degrees = Vector3(30.0, -50.0, 0.0)
	world_root.add_child(fill)

	var rim := DirectionalLight3D.new()
	rim.light_color = Color(0.72, 0.8, 0.96)
	rim.light_energy = 0.38
	rim.shadow_enabled = false
	rim.rotation_degrees = Vector3(14.0, 122.0 - 180.0, 0.0)
	world_root.add_child(rim)

	var cam_dir := Vector3(0.68, 0.3, 0.67).normalized()
	var camera := Camera3D.new()
	camera.current = true
	camera.fov = CAMERA_FOV_DEG
	camera.far = 9000.0
	world_root.add_child(camera)
	camera.look_at_from_position(cam_dir * CAMERA_DISTANCE_M, Vector3.ZERO, Vector3.UP)

	var decor: LunarSkyDecor = _LUNAR_SKY_DECOR.instantiate()
	decor.earth_direction = Vector3(0.28, 0.92, 0.28)
	decor.angular_diameter_deg = 5.8
	decor.distance_m = 12000.0
	decor.hide_below_horizon = false
	world_root.add_child(decor)
	decor.sun_light_path = sun.get_path()
	decor.camera_path = camera.get_path()

	for _warm in 8:
		await get_tree().process_frame

	for frame_idx in FRAME_COUNT:
		_moon_pivot.rotation.y = TAU * float(frame_idx) / float(FRAME_COUNT)
		for _i in 2:
			await get_tree().process_frame

		var img: Image = viewport.get_texture().get_image()
		if img == null or img.is_empty():
			push_error("MOON_SPIN: empty frame %d" % frame_idx)
			get_tree().quit(1)
			return
		img.flip_y()
		var path := "%s/frame_%03d.png" % [FRAMES_DIR, frame_idx]
		img.save_png(path)
		print("MOON_SPIN: frame %d/%d → %s" % [frame_idx + 1, FRAME_COUNT, path])

	print("MOON_SPIN: frames done, assembling gif → %s" % OUTPUT_GIF)
	get_tree().quit(0)


func _make_moon_experiment_environment() -> Environment:
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
	environment.fog_enabled = false
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
