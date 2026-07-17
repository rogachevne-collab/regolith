extends Node

## Headless visual proof for ConnectedBlockVisual face panels.
## Usage: ./run.sh --headless res://scenes/tools/connected_block_visual_proof.tscn

const OUT_DIR := "/opt/cursor/artifacts/assets"
const VIEWPORT_SIZE := 960


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _capture_case(
		"connected_block_isolated",
		_build_isolated_root(),
		Vector3(1.2, 1.1, 1.4)
	)
	await _capture_case(
		"connected_block_isolated_pos_z",
		_build_isolated_root(),
		Vector3(0.65, 0.7, 1.5)
	)
	await _capture_case(
		"connected_block_isolated_neg_z",
		_build_isolated_root(),
		Vector3(-0.65, 0.7, -1.5)
	)
	await _capture_case(
		"connected_block_merged_x",
		_build_merged_pair_root(),
		Vector3(1.5, 1.4, 2.1)
	)
	await _capture_case(
		"connected_block_large_isolated",
		_build_large_isolated_root(),
		Vector3(4.2, 3.8, 5.0)
	)
	print("CONNECTED-BLOCK-VISUAL-PROOF: PASS")
	get_tree().quit(0)


func _capture_case(name: String, subject: Node3D, camera_pos: Vector3) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(VIEWPORT_SIZE, VIEWPORT_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	add_child(viewport)

	var world := Node3D.new()
	viewport.add_child(world)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.08, 0.09, 0.11)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.22, 0.24, 0.28)
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.environment = environment
	world.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.8
	sun.light_color = Color(1.0, 0.97, 0.92)
	sun.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	world.add_child(sun)

	var fill_light := DirectionalLight3D.new()
	fill_light.light_energy = 0.7
	fill_light.light_color = Color(0.65, 0.72, 0.9)
	fill_light.rotation_degrees = Vector3(30.0, -135.0, 0.0)
	world.add_child(fill_light)

	var back_light := DirectionalLight3D.new()
	back_light.light_energy = 0.45
	back_light.light_color = Color(0.5, 0.55, 0.65)
	back_light.rotation_degrees = Vector3(10.0, 180.0, 0.0)
	world.add_child(back_light)

	world.add_child(subject)

	var camera := Camera3D.new()
	camera.current = true
	camera.fov = 35.0
	world.add_child(camera)
	camera.look_at_from_position(camera_pos, Vector3.ZERO, Vector3.UP)

	for _i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img: Image = viewport.get_texture().get_image()
	img.flip_y()
	var path := "%s/%s.png" % [OUT_DIR, name]
	img.save_png(path)
	print("PROOF: wrote ", path, " bytes=", FileAccess.get_file_as_bytes(path).size())
	viewport.queue_free()


func _build_isolated_root() -> Node3D:
	var root := Node3D.new()
	var size := Vector3.ONE * GridMetric.CELL_SIZE_M
	_attach_block(root, size, 0, Vector3.ZERO)
	return root


func _build_merged_pair_root() -> Node3D:
	var root := Node3D.new()
	var size := Vector3.ONE * GridMetric.CELL_SIZE_M
	var left_mask := 1 << int(OrientationUtil.Face.POS_X)
	var right_mask := 1 << int(OrientationUtil.Face.NEG_X)
	_attach_block(root, size, left_mask, Vector3(-size.x * 0.5, 0.0, 0.0))
	_attach_block(root, size, right_mask, Vector3(size.x * 0.5, 0.0, 0.0))
	return root


func _build_large_isolated_root() -> Node3D:
	var root := Node3D.new()
	_attach_block(root, Vector3.ONE * 2.5, 0, Vector3.ZERO)
	return root


func _attach_block(
	parent: Node3D,
	size: Vector3,
	face_mask: int,
	origin: Vector3
) -> void:
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.72, 0.48, 0.22, 1.0)
	fill_mat.metallic = 0.18
	fill_mat.roughness = 0.82
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.28, 0.16, 0.06, 1.0)
	rim_mat.metallic = 0.4
	rim_mat.roughness = 0.62
	rim_mat.emission_enabled = true
	rim_mat.emission = Color(0.35, 0.2, 0.08)
	rim_mat.emission_energy_multiplier = 0.35

	var holder := Node3D.new()
	holder.position = origin
	parent.add_child(holder)

	var fill := MeshInstance3D.new()
	fill.mesh = ConnectedBlockVisual.make_fill_mesh(size, face_mask)
	fill.material_override = fill_mat
	holder.add_child(fill)

	var rim := MeshInstance3D.new()
	rim.mesh = ConnectedBlockVisual.make_rim_mesh(size, face_mask)
	rim.material_override = rim_mat
	holder.add_child(rim)
