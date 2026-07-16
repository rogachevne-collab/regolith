extends Node3D

## One-shot: render the moon from outside and save a PNG, then quit.

const CAMERA_DISTANCE_M := 1800.0
const SETTLE_FRAMES := 300
const OUTPUT_USER := "user://moon_from_space.png"
const OUTPUT_ARTIFACT := "/opt/cursor/artifacts/assets/moon_from_space.png"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
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
	add_child(terrain)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	var sky_tex: Texture2D = load("res://resources/starfield_panorama.png")
	if sky_tex != null:
		var sky_mat := PanoramaSkyMaterial.new()
		sky_mat.panorama = sky_tex
		sky_mat.energy_multiplier = 1.2
		var sky := Sky.new()
		sky.sky_material = sky_mat
		environment.background_mode = Environment.BG_SKY
		environment.sky = sky
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		environment.ambient_light_sky_contribution = 0.25
		environment.ambient_light_energy = 0.3
	else:
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color(0.01, 0.01, 0.02)
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = Color(0.15, 0.16, 0.2)
		environment.ambient_light_energy = 0.35
	env.environment = environment
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.2
	sun.shadow_enabled = false
	sun.rotation_degrees = Vector3(-25.0, 55.0, 0.0)
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.35
	fill.light_color = Color(0.55, 0.62, 0.85)
	fill.rotation_degrees = Vector3(15.0, -130.0, 0.0)
	add_child(fill)

	var camera := Camera3D.new()
	camera.current = true
	camera.fov = 42.0
	camera.far = 8000.0
	add_child(camera)
	var cam_pos := Vector3(0.75, 0.25, 1.0).normalized() * CAMERA_DISTANCE_M
	camera.look_at_from_position(cam_pos, Vector3.ZERO, Vector3.UP)

	var viewer := VoxelViewer.new()
	viewer.view_distance = terrain.view_distance
	viewer.requires_visuals = true
	viewer.requires_collisions = false
	camera.add_child(viewer)

	print(
		"SPACE_SHOT: waiting mesh view_distance=%d cam=%s"
		% [terrain.view_distance, str(cam_pos)]
	)
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
		if i % 60 == 0:
			print("SPACE_SHOT: frame=", i)

	await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
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
	print("SPACE_SHOT: save_user err=", err)
	var abs_user := ProjectSettings.globalize_path(OUTPUT_USER)
	DirAccess.make_dir_recursive_absolute("/opt/cursor/artifacts/assets")
	# Immutable artifacts: write a new filename, don't overwrite if policy cares.
	var artifact := "/opt/cursor/artifacts/assets/moon_from_space_v2.png"
	var copy_err := DirAccess.copy_absolute(abs_user, artifact)
	# Also refresh the canonical name for the walkthrough.
	DirAccess.copy_absolute(abs_user, OUTPUT_ARTIFACT)
	print(
		"SPACE_SHOT: copy_err=",
		copy_err,
		" artifact=",
		artifact,
		" size=",
		FileAccess.get_file_as_bytes(artifact).size()
	)
	get_tree().quit()
