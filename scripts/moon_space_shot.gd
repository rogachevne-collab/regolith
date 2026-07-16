extends Node3D

## HQ orbital preview: precomputed H lat/lon map → dense mesh + shadow graze.

const CAMERA_DISTANCE_M := 2600.0
const CAMERA_FOV_DEG := 42.0
const VIEWPORT_SIZE := 1536
const HEIGHT_W := 768
const HEIGHT_H := 384
const MESH_SEGMENTS := 384
const MESH_RINGS := 192
const OUTPUT_ARTIFACT := "/opt/cursor/artifacts/assets/moon_from_space_hq.png"


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

	var gen := MoonSphereGeneratorFactory.create() as MoonTerrainGenerator
	print("SPACE_HQ: sampling height map ", HEIGHT_W, "x", HEIGHT_H)
	var heights: PackedFloat32Array = await _sample_height_map(gen)
	print("SPACE_HQ: building mesh…")
	var mesh := _mesh_from_heights(heights)
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
		sky_mat.energy_multiplier = 1.55
		var sky := Sky.new()
		sky.sky_material = sky_mat
		environment.background_mode = Environment.BG_SKY
		environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.05, 0.05, 0.055)
	environment.ambient_light_energy = 0.12
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.0
	environment.ssao_enabled = true
	environment.ssao_radius = 3.0
	environment.ssao_intensity = 2.2
	env.environment = environment
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 4.5
	sun.light_color = Color(1.0, 0.97, 0.93)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_blur = 0.25
	sun.directional_shadow_max_distance = 5000.0
	sun.rotation_degrees = Vector3(-6.0, 128.0, 0.0)
	world_root.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.08
	fill.light_color = Color(0.55, 0.55, 0.58)
	fill.rotation_degrees = Vector3(40.0, -35.0, 0.0)
	world_root.add_child(fill)

	var rim := DirectionalLight3D.new()
	rim.light_energy = 1.25
	rim.light_color = Color(0.65, 0.75, 1.0)
	rim.rotation_degrees = Vector3(14.0, 128.0 - 180.0, 0.0)
	world_root.add_child(rim)

	var cam_dir := Vector3(0.7, 0.26, 0.66).normalized()
	var camera := Camera3D.new()
	camera.current = true
	camera.fov = CAMERA_FOV_DEG
	camera.far = 9000.0
	world_root.add_child(camera)
	camera.look_at_from_position(cam_dir * CAMERA_DISTANCE_M, Vector3.ZERO, Vector3.UP)

	for i in 50:
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
	mat.albedo_color = Color(0.7, 0.68, 0.65)
	var albedo: Texture2D = load("res://resources/moon_regolith_albedo.jpg")
	var normal: Texture2D = load("res://resources/moon_regolith_normal.jpg")
	if albedo != null:
		mat.albedo_texture = albedo
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = 1.6
	mat.uv1_triplanar = true
	mat.uv1_triplanar_sharpness = 8.0
	mat.uv1_scale = Vector3(0.015, 0.015, 0.015)
	mat.roughness = 0.96
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true
	return mat


func _sample_height_map(gen: MoonTerrainGenerator) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(HEIGHT_W * HEIGHT_H)
	for y in HEIGHT_H:
		var phi := (float(y) + 0.5) / float(HEIGHT_H) * PI
		for x in HEIGHT_W:
			var theta := (float(x) + 0.5) / float(HEIGHT_W) * TAU
			var n := _sphere_point(theta, phi)
			data[y * HEIGHT_W + x] = gen._height_meters(n)
		if y % 64 == 0:
			print("SPACE_HQ: height row ", y, "/", HEIGHT_H)
			await get_tree().process_frame
	return data


func _mesh_from_heights(heights: PackedFloat32Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := MoonGeometry.SURFACE_RADIUS_M
	for ring in MESH_RINGS:
		var v0 := float(ring) / float(MESH_RINGS)
		var v1 := float(ring + 1) / float(MESH_RINGS)
		var phi0 := v0 * PI
		var phi1 := v1 * PI
		for seg in MESH_SEGMENTS:
			var u0 := float(seg) / float(MESH_SEGMENTS)
			var u1 := float(seg + 1) / float(MESH_SEGMENTS)
			var th0 := u0 * TAU
			var th1 := u1 * TAU
			var n00 := _sphere_point(th0, phi0)
			var n10 := _sphere_point(th1, phi0)
			var n01 := _sphere_point(th0, phi1)
			var n11 := _sphere_point(th1, phi1)
			var h00 := _sample_h(heights, u0, v0)
			var h10 := _sample_h(heights, u1, v0)
			var h01 := _sample_h(heights, u0, v1)
			var h11 := _sample_h(heights, u1, v1)
			var p00 := n00 * (r0 + h00)
			var p10 := n10 * (r0 + h10)
			var p01 := n01 * (r0 + h01)
			var p11 := n11 * (r0 + h11)
			_add_tri(st, p00, p01, p11, h00, h01, h11)
			_add_tri(st, p00, p11, p10, h00, h11, h10)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


func _sample_h(heights: PackedFloat32Array, u: float, v: float) -> float:
	var x := fposmod(u, 1.0) * float(HEIGHT_W)
	var y := clampf(v, 0.0, 1.0) * float(HEIGHT_H - 1)
	var x0 := int(floor(x)) % HEIGHT_W
	var x1 := (x0 + 1) % HEIGHT_W
	var y0 := clampi(int(floor(y)), 0, HEIGHT_H - 1)
	var y1 := clampi(y0 + 1, 0, HEIGHT_H - 1)
	var fx := x - floorf(x)
	var fy := y - floorf(y)
	var h00 := heights[y0 * HEIGHT_W + x0]
	var h10 := heights[y0 * HEIGHT_W + x1]
	var h01 := heights[y1 * HEIGHT_W + x0]
	var h11 := heights[y1 * HEIGHT_W + x1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


func _sphere_point(theta: float, phi: float) -> Vector3:
	return Vector3(
		sin(phi) * cos(theta),
		cos(phi),
		sin(phi) * sin(theta)
	).normalized()


func _add_tri(
	st: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	ha: float,
	hb: float,
	hc: float
) -> void:
	_add_vert(st, a, ha)
	_add_vert(st, b, hb)
	_add_vert(st, c, hc)


func _add_vert(st: SurfaceTool, p: Vector3, h: float) -> void:
	var ao := clampf(1.0 + h / 35.0, 0.28, 1.0)
	st.set_color(Color(ao, ao, ao))
	var n := p.normalized()
	st.set_uv(Vector2(n.x * 0.5 + 0.5, n.z * 0.5 + 0.5))
	st.add_vertex(p)
