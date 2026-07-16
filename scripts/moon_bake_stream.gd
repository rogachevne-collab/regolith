extends Node3D

## Bake streamed moon SDF into RegionFiles with save_generator_output.
## Places viewers around the sphere, waits for generation, then
## save_modified_blocks + flush so generated chunks are frozen.
## Usage: DISPLAY=:1 ./run.sh res://scenes/moon_bake_stream.tscn

const SETTLE_FRAMES := 240
const VIEWERS_AROUND := 12
const OUTPUT_NOTE := "/opt/cursor/artifacts/assets/moon_bake_note.txt"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var dir := MoonGeometry.dig_stream_directory()
	var abs_dir := ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)

	var terrain := VoxelLodTerrain.new()
	terrain.scale = Vector3.ONE * MoonGeometry.VOXEL_SCALE
	terrain.generator = MoonSphereGeneratorFactory.create()
	terrain.mesher = VoxelMesherTransvoxel.new()
	terrain.material = load("res://resources/terrain_material_smooth.tres")
	terrain.generate_collisions = false
	terrain.voxel_bounds = MoonGeometry.voxel_bounds_aabb()
	terrain.view_distance = 384
	terrain.full_load_mode_enabled = false
	terrain.lod_distance = 120.0
	add_child(terrain)

	var stream := VoxelStreamRegionFiles.new()
	stream.directory = dir
	stream.save_generator_output = true
	terrain.stream = stream

	print("BAKE: regions=", abs_dir)

	var viewers: Array[VoxelViewer] = []
	for i in VIEWERS_AROUND:
		var v := VoxelViewer.new()
		v.view_distance = 384
		v.requires_visuals = true
		v.requires_collisions = false
		add_child(v)
		viewers.append(v)

	var poles := [
		Vector3.UP,
		Vector3.DOWN,
		Vector3.RIGHT,
		Vector3.LEFT,
		Vector3.FORWARD,
		Vector3.BACK,
	]
	for i in VIEWERS_AROUND:
		var dir_n: Vector3
		if i < poles.size():
			dir_n = poles[i]
		else:
			var a := float(i) * TAU / float(VIEWERS_AROUND)
			dir_n = Vector3(cos(a), 0.35, sin(a)).normalized()
		viewers[i].global_position = dir_n * MoonGeometry.SURFACE_RADIUS_M
		var tool: VoxelTool = terrain.get_voxel_tool()
		tool.channel = VoxelBuffer.CHANNEL_SDF
		var world_p: Vector3 = viewers[i].global_position
		var local_p := VoxelSpaceUtil.world_to_local(terrain, world_p)
		var cell := Vector3i(floori(local_p.x), floori(local_p.y), floori(local_p.z))
		var editable := false
		var sdf := 100.0
		for _f in SETTLE_FRAMES * 2:
			await get_tree().process_frame
			sdf = tool.get_voxel_f(cell)
			var area := AABB(local_p - Vector3.ONE * 2.0, Vector3.ONE * 4.0)
			if tool.is_area_editable(area):
				editable = true
				break
		if editable:
			tool.mode = VoxelTool.MODE_REMOVE
			tool.do_sphere(local_p, 0.05)
		print(
			"BAKE: viewer ", i,
			" at ", viewers[i].global_position,
			" sdf=", sdf,
			" editable=", editable
		)
		var tracker: VoxelSaveCompletionTracker = terrain.save_modified_blocks()
		var wait := 0
		while tracker != null and not tracker.is_complete() and wait < 240:
			await get_tree().process_frame
			wait += 1
		stream.flush()


	var file_count := 0
	var stack: Array = [abs_dir]
	while not stack.is_empty():
		var path: String = stack.pop_back()
		for fname in DirAccess.get_files_at(path):
			file_count += 1
		for dname in DirAccess.get_directories_at(path):
			stack.append(path.path_join(dname))
	var note := "baked gen_v%d files=%d dir=%s\n" % [
		MoonTerrainParams.GENERATOR_VERSION, file_count, abs_dir
	]
	print("BAKE: ", note.strip_edges())
	var f := FileAccess.open(OUTPUT_NOTE, FileAccess.WRITE)
	if f:
		f.store_string(note)
		f.close()
	var vf := FileAccess.open("%s/generator_version.txt" % abs_dir, FileAccess.WRITE)
	if vf:
		vf.store_string(str(MoonTerrainParams.GENERATOR_VERSION))
		vf.close()
	get_tree().quit()
