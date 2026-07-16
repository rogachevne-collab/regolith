extends Node3D

## HQ orbital preview with analytic heightfield normals (no faceted crater teeth).

const CAMERA_DISTANCE_M := 2300.0
const CAMERA_FOV_DEG := 40.0
const VIEWPORT_SIZE := 1536
const HEIGHT_W := 1152
const HEIGHT_H := 576
const MESH_SEGMENTS := 576
const MESH_RINGS := 288
const OUTPUT_ARTIFACT := "/opt/cursor/artifacts/assets/moon_from_space_hq.png"

var _gen: MoonTerrainGenerator
var _heights: PackedFloat32Array


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(VIEWPORT_SIZE, VIEWPORT_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.positional_shadow_atlas_size = 8192
	add_child(viewport)

	var world_root := Node3D.new()
	viewport.add_child(world_root)

	_gen = MoonSphereGeneratorFactory.create() as MoonTerrainGenerator
	print("SPACE_HQ: sampling height map ", HEIGHT_W, "x", HEIGHT_H)
	_heights = await _sample_height_map()
	print("SPACE_HQ: building mesh with analytic normals…")
	var mesh := _mesh_from_heights()
	print("SPACE_HQ: aabb=", mesh.get_aabb())

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.material_override = _make_moon_material()
	world_root.add_child(mi)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	var sky_tex: Texture2D = load("res://resources/starfield_panorama.png")
	if sky_tex != null:
		var sky_mat := PanoramaSkyMaterial.new()
		sky_mat.panorama = sky_tex
		sky_mat.energy_multiplier = 1.45
		var sky := Sky.new()
		sky.sky_material = sky_mat
		environment.background_mode = Environment.BG_SKY
		environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.04, 0.04, 0.045)
	environment.ambient_light_energy = 0.1
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.05
	environment.ssao_enabled = true
	environment.ssao_radius = 2.2
	environment.ssao_intensity = 1.6
	env.environment = environment
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 3.8
	sun.light_color = Color(1.0, 0.98, 0.95)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_blur = 0.35
	sun.directional_shadow_max_distance = 5000.0
	sun.rotation_degrees = Vector3(-10.0, 122.0, 0.0)
	world_root.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.12
	fill.light_color = Color(0.6, 0.6, 0.62)
	fill.rotation_degrees = Vector3(30.0, -50.0, 0.0)
	world_root.add_child(fill)

	var rim := DirectionalLight3D.new()
	rim.light_energy = 0.9
	rim.light_color = Color(0.7, 0.78, 0.95)
	rim.rotation_degrees = Vector3(16.0, 122.0 - 180.0, 0.0)
	world_root.add_child(rim)

	var cam_dir := Vector3(0.68, 0.3, 0.67).normalized()
	var camera := Camera3D.new()
	camera.current = true
	camera.fov = CAMERA_FOV_DEG
	camera.far = 9000.0
	world_root.add_child(camera)
	camera.look_at_from_position(cam_dir * CAMERA_DISTANCE_M, Vector3.ZERO, Vector3.UP)

	for i in 55:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img: Image = viewport.get_texture().get_image()
	img.flip_y()
	var tmp := "user://moon_from_space.png"
	img.save_png(tmp)
	var abs_user := ProjectSettings.globalize_path(tmp)
	DirAccess.make_dir_recursive_absolute("/opt/cursor/artifacts/assets")
	DirAccess.copy_absolute(abs_user, OUTPUT_ARTIFACT)
	DirAccess.copy_absolute(abs_user, "/opt/cursor/artifacts/assets/moon_from_space_relief.png")
	DirAccess.copy_absolute(abs_user, "/opt/cursor/artifacts/assets/moon_from_space.png")
	print(
		"SPACE_HQ: artifact=",
		OUTPUT_ARTIFACT,
		" bytes=",
		FileAccess.get_file_as_bytes(OUTPUT_ARTIFACT).size()
	)
	get_tree().quit()


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
		var phi := (float(y) + 0.5) / float(HEIGHT_H) * PI
		for x in HEIGHT_W:
			var theta := (float(x) + 0.5) / float(HEIGHT_W) * TAU
			data[y * HEIGHT_W + x] = _gen._height_meters(_sphere_point(theta, phi))
		if y % 64 == 0:
			print("SPACE_HQ: height row ", y, "/", HEIGHT_H)
			await get_tree().process_frame
	return data


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
	## n × finite-difference of height on the sphere → smooth shading.
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
