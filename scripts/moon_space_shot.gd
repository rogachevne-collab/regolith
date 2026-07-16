extends Node3D

## From-space render: UV sphere displaced by MoonTerrainGenerator H(n).

const CAMERA_DISTANCE_M := 1600.0
const CAMERA_FOV_DEG := 38.0
const VIEWPORT_SIZE := 1280
const SPHERE_SEGMENTS := 160
const SPHERE_RINGS := 80
const OUTPUT_USER := "user://moon_from_space.png"
const OUTPUT_ARTIFACT := "/opt/cursor/artifacts/assets/moon_from_space_relief.png"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(VIEWPORT_SIZE, VIEWPORT_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var world_root := Node3D.new()
	viewport.add_child(world_root)

	var gen := MoonSphereGeneratorFactory.create() as MoonTerrainGenerator
	var mesh := _build_displaced_sphere(gen)
	print(
		"SPACE_SHOT: mesh aabb=",
		mesh.get_aabb(),
		" surfaces=",
		mesh.get_surface_count()
	)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.54, 0.52)
	var albedo: Texture2D = load("res://resources/moon_regolith_albedo.jpg")
	if albedo != null:
		mat.albedo_texture = albedo
		mat.uv1_triplanar = true
		mat.uv1_triplanar_sharpness = 4.0
		mat.uv1_scale = Vector3(0.02, 0.02, 0.02)
	mat.roughness = 0.92
	mat.metallic = 0.0
	mesh_instance.material_override = mat
	world_root.add_child(mesh_instance)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	var sky_tex: Texture2D = load("res://resources/starfield_panorama.png")
	if sky_tex != null:
		var sky_mat := PanoramaSkyMaterial.new()
		sky_mat.panorama = sky_tex
		sky_mat.energy_multiplier = 1.35
		var sky := Sky.new()
		sky.sky_material = sky_mat
		environment.background_mode = Environment.BG_SKY
		environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.18, 0.19, 0.22)
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.2
	env.environment = environment
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.8
	sun.rotation_degrees = Vector3(-20.0, 115.0, 0.0)
	world_root.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.4
	fill.light_color = Color(0.55, 0.62, 0.85)
	fill.rotation_degrees = Vector3(25.0, -50.0, 0.0)
	world_root.add_child(fill)

	var rim := DirectionalLight3D.new()
	rim.light_energy = 1.4
	rim.light_color = Color(0.75, 0.82, 1.0)
	rim.rotation_degrees = Vector3(15.0, 115.0 - 180.0, 0.0)
	world_root.add_child(rim)

	var cam_dir := Vector3(0.7, 0.35, 0.62).normalized()
	var camera := Camera3D.new()
	camera.current = true
	camera.fov = CAMERA_FOV_DEG
	camera.far = 8000.0
	world_root.add_child(camera)
	camera.look_at_from_position(cam_dir * CAMERA_DISTANCE_M, Vector3.ZERO, Vector3.UP)

	print("SPACE_SHOT: displaced sphere ready")
	for i in 20:
		await get_tree().process_frame

	await RenderingServer.frame_post_draw
	var img: Image = viewport.get_texture().get_image()
	img.flip_y()
	img.save_png(OUTPUT_USER)
	var abs_user := ProjectSettings.globalize_path(OUTPUT_USER)
	DirAccess.make_dir_recursive_absolute("/opt/cursor/artifacts/assets")
	DirAccess.copy_absolute(abs_user, OUTPUT_ARTIFACT)
	DirAccess.copy_absolute(abs_user, "/opt/cursor/artifacts/assets/moon_from_space.png")
	DirAccess.copy_absolute(
		abs_user,
		"/opt/cursor/artifacts/assets/moon_from_space_perspective.png"
	)
	print(
		"SPACE_SHOT: artifact=",
		OUTPUT_ARTIFACT,
		" bytes=",
		FileAccess.get_file_as_bytes(OUTPUT_ARTIFACT).size()
	)
	get_tree().quit()


func _build_displaced_sphere(gen: MoonTerrainGenerator) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := MoonGeometry.SURFACE_RADIUS_M
	for ring in SPHERE_RINGS:
		var phi0 := float(ring) / float(SPHERE_RINGS) * PI
		var phi1 := float(ring + 1) / float(SPHERE_RINGS) * PI
		for seg in SPHERE_SEGMENTS:
			var th0 := float(seg) / float(SPHERE_SEGMENTS) * TAU
			var th1 := float(seg + 1) / float(SPHERE_SEGMENTS) * TAU
			var n00 := _sphere_point(th0, phi0)
			var n10 := _sphere_point(th1, phi0)
			var n01 := _sphere_point(th0, phi1)
			var n11 := _sphere_point(th1, phi1)
			var d00 := _displaced(gen, n00, r0)
			var d10 := _displaced(gen, n10, r0)
			var d01 := _displaced(gen, n01, r0)
			var d11 := _displaced(gen, n11, r0)
			## CCW when viewed from outside.
			_add_tri(st, d00, d01, d11)
			_add_tri(st, d00, d11, d10)
	st.generate_normals()
	return st.commit()


func _sphere_point(theta: float, phi: float) -> Vector3:
	return Vector3(
		sin(phi) * cos(theta),
		cos(phi),
		sin(phi) * sin(theta)
	).normalized()


func _displaced(gen: MoonTerrainGenerator, n: Vector3, r0: float) -> Vector3:
	var h_m := gen._height_voxels(n) * MoonGeometry.VOXEL_SCALE
	return n * (r0 + h_m)


func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
