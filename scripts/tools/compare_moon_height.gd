extends SceneTree

## Native MoonHeightmapBake heights vs MoonTerrainGenerator (ZN).
## Usage: ./run.sh --headless -s res://scripts/tools/compare_moon_height.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("MoonHeightmapBake"):
		push_error("MoonHeightmapBake missing")
		quit(1)
		return

	var HQ = load("res://scripts/simulation/runtime/moon_terrain_generator.gd")
	var gen = HQ.new()
	gen._radius_voxels = MoonGeometry.radius_voxels()
	gen._setup_noise()

	var baker: Object = ClassDB.instantiate("MoonHeightmapBake")
	var w := 128
	var h := 64
	var t0 := Time.get_ticks_msec()
	var pixels: PackedFloat32Array = baker.call(
		"bake_panorama", w, h, MoonGeometry.radius_voxels()
	)
	var bake_ms := Time.get_ticks_msec() - t0

	var sum := 0.0
	var mx := 0.0
	var n := 0
	for y in h:
		var v := (float(y) + 0.5) / float(h)
		for x in w:
			var u := (float(x) + 0.5) / float(w)
			var dir := MoonHeightmapUtil.direction_from_node_uv(u, v)
			var a: float = gen._height_voxels(dir)
			var b: float = pixels[y * w + x]
			var d: float = absf(a - b)
			sum += d
			mx = maxf(mx, d)
			n += 1

	print(
		"Height parity %dx%d: mean|d|=%s max|d|=%s bake_ms=%d"
		% [w, h, str(sum / float(n)), str(mx), bake_ms]
	)

	t0 = Time.get_ticks_msec()
	var full: PackedFloat32Array = baker.call(
		"bake_panorama", 2048, 1024, MoonGeometry.radius_voxels()
	)
	var full_ms := Time.get_ticks_msec() - t0
	print("Full bake 2048x1024: %d ms (pixels=%d)" % [full_ms, full.size()])
	quit(0 if mx < 1e-3 else 2)
