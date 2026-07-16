extends Node3D

## One-shot: render the moon from outside into a square SubViewport PNG.
## Uses strong night-limb rim so the full disk reads circular (lit-only
## hemispheres look egg-shaped against black space).

const CAMERA_DISTANCE_M := 2000.0
const CAMERA_FOV_DEG := 38.0
const VIEWPORT_SIZE := 1024
const SETTLE_FRAMES := 360
const OUTPUT_USER := "user://moon_from_space.png"
const OUTPUT_ARTIFACT := "/opt/cursor/artifacts/assets/moon_from_space_perspective.png"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.name = "CaptureViewport"
	viewport.size = Vector2i(VIEWPORT_SIZE, VIEWPORT_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	add_child(viewport)

	var world_root := Node3D.new()
	world_root.name = "World"
	viewport.add_child(world_root)

	var terrain := VoxelLodTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.scale = Vector3.ONE * MoonGeometry.VOXEL_SCALE
	terrain.generator = MoonSphereGeneratorFactory.create()
	terrain.mesher = VoxelMesherTransvoxel.new()
	terrain.material = load("res://resources/terrain_material_smooth.tres")
	terrain.generate_collisions = false
	terrain.voxel_bounds = MoonGeometry.voxel_bounds_aabb()
	terrain.view_distance = int(ceili(MoonGeometry.radius_voxels() * 2.2))
	terrain.full_load_mode_enabled = true
	terrain.lod_distance = 220.0
	world_root.add_child(terrain)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	var sky_tex: Texture2D = load("res://resources/starfield_panorama.png")
	if sky_tex != null:
		var sky_mat := PanoramaSkyMaterial.new()
		sky_mat.panorama = sky_tex
		sky_mat.energy_multiplier = 1.15
		var sky := Sky.new()
		sky.sky_material = sky_mat
		environment.background_mode = Environment.BG_SKY
		environment.sky = sky
	else:
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color(0.01, 0.01, 0.02)
	# Color ambient (not sky-only) so the night limb stays above black.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.22, 0.24, 0.3)
	environment.ambient_light_energy = 0.85
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.05
	env.environment = environment
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.7
	sun.shadow_enabled = false
	sun.rotation_degrees = Vector3(-20.0, 50.0, 0.0)
	world_root.add_child(sun)

	# Primary rim: opposite the key light — defines the night limb.
	var rim := DirectionalLight3D.new()
	rim.name = "Rim"
	rim.light_energy = 2.4
	rim.light_color = Color(0.75, 0.82, 1.0)
	rim.shadow_enabled = false
	rim.rotation_degrees = Vector3(25.0, 50.0 - 180.0, 0.0)
	world_root.add_child(rim)

	# Secondary wrap so the terminator does not punch a black bite out of the disk.
	var wrap := DirectionalLight3D.new()
	wrap.name = "Wrap"
	wrap.light_energy = 0.75
	wrap.light_color = Color(0.55, 0.6, 0.75)
	wrap.shadow_enabled = false
	wrap.rotation_degrees = Vector3(5.0, 50.0 - 110.0, 0.0)
	world_root.add_child(wrap)

	var camera := Camera3D.new()
	camera.current = true
	# Perspective keeps PanoramaSky looking like stars (ortho collapses it
	# into radial white streaks through the planet).
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = CAMERA_FOV_DEG
	camera.far = 8000.0
	camera.near = 1.0
	world_root.add_child(camera)
	var cam_pos := Vector3(0.75, 0.25, 1.0).normalized() * CAMERA_DISTANCE_M
	camera.look_at_from_position(cam_pos, Vector3.ZERO, Vector3.UP)

	# Drive meshing from the planet center so the full sphere (including the
	# night limb) exists — a camera-only viewer tends to omit the far side,
	# and a lit half-disk reads as an egg against black space.
	var viewer := VoxelViewer.new()
	viewer.view_distance = terrain.view_distance
	viewer.requires_visuals = true
	viewer.requires_collisions = false
	world_root.add_child(viewer)
	viewer.global_position = Vector3.ZERO

	print(
		"SPACE_SHOT: perspective fov=%s cam=%s"
		% [CAMERA_FOV_DEG, str(cam_pos)]
	)
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
		if i % 60 == 0:
			print("SPACE_SHOT: frame=", i)

	await RenderingServer.frame_post_draw
	var tex: ViewportTexture = viewport.get_texture()
	if tex == null:
		push_error("SPACE_SHOT: no viewport texture")
		get_tree().quit()
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("SPACE_SHOT: get_image failed")
		get_tree().quit()
		return
	img.flip_y()
	var err := img.save_png(OUTPUT_USER)
	print("SPACE_SHOT: save_user err=", err, " img=", img.get_width(), "x", img.get_height())
	var abs_user := ProjectSettings.globalize_path(OUTPUT_USER)
	DirAccess.make_dir_recursive_absolute("/opt/cursor/artifacts/assets")
	var copy_err := DirAccess.copy_absolute(abs_user, OUTPUT_ARTIFACT)
	DirAccess.copy_absolute(abs_user, "/opt/cursor/artifacts/assets/moon_from_space.png")
	print(
		"SPACE_SHOT: copy_err=",
		copy_err,
		" artifact=",
		OUTPUT_ARTIFACT,
		" bytes=",
		FileAccess.get_file_as_bytes(OUTPUT_ARTIFACT).size()
	)
	get_tree().quit()
