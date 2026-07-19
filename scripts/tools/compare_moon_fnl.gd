extends SceneTree

## Headless: local FNL (MoonHeightmapBake.sample_fnl) vs ZN_FastNoiseLite.
## Usage: ./run.sh --headless -s res://scripts/tools/compare_moon_fnl.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("MoonHeightmapBake"):
		push_error("MoonHeightmapBake missing — run ./run.sh --headless --import")
		quit(1)
		return
	if not ClassDB.class_exists(&"ZN_FastNoiseLite"):
		push_error("ZN_FastNoiseLite missing")
		quit(1)
		return

	var vs := MoonGeometry.VOXEL_SCALE
	var params := [
		{"name": "mare", "seed": 0x4D004E + 11, "period": 480.0 / vs, "oct": 2, "gain": 0.32, "lac": 2.0},
		{"name": "highland", "seed": 0x4D004E + 41, "period": 55.0 / vs, "oct": 3, "gain": 0.42, "lac": 2.0},
		{"name": "surface", "seed": 0x4D004E + 73, "period": 20.0 / vs, "oct": 2, "gain": 0.45, "lac": 2.0},
		{"name": "regolith", "seed": 0x4D004E + 67, "period": 4.5 / vs, "oct": 2, "gain": 0.5, "lac": 2.0},
	]
	var baker: Object = ClassDB.instantiate("MoonHeightmapBake")
	var n := 4000
	var worst_name := ""
	var worst_abs := 0.0
	var sum_abs := 0.0
	var count := 0

	for cfg in params:
		var zn: Object = ClassDB.instantiate(&"ZN_FastNoiseLite")
		zn.set("seed", cfg["seed"])
		zn.set("period", cfg["period"])
		zn.set("noise_type", 0)
		zn.set("fractal_type", 1)
		zn.set("fractal_octaves", cfg["oct"])
		zn.set("fractal_gain", cfg["gain"])
		zn.set("fractal_lacunarity", cfg["lac"])

		var local_sum := 0.0
		var local_max := 0.0
		for i in n:
			var p := Vector3(
				sin(float(i) * 0.173) * 400.0,
				cos(float(i) * 0.091) * 400.0,
				sin(float(i) * 0.057 + 1.3) * 400.0
			)
			var a: float = zn.call("get_noise_3dv", p)
			var b: float = baker.call(
				"sample_fnl",
				cfg["seed"],
				cfg["period"],
				cfg["oct"],
				cfg["gain"],
				cfg["lac"],
				p
			)
			var d: float = absf(a - b)
			local_sum += d
			local_max = maxf(local_max, d)
			sum_abs += d
			count += 1
			if d > worst_abs:
				worst_abs = d
				worst_name = "%s @%d" % [cfg["name"], i]

		print(
			"FNL parity %s: mean|d|=%s max|d|=%s (n=%d)"
			% [cfg["name"], str(local_sum / float(n)), str(local_max), n]
		)

	print(
		"FNL parity TOTAL: mean|d|=%s max|d|=%s worst=%s"
		% [str(sum_abs / float(count)), str(worst_abs), worst_name]
	)
	quit(0 if worst_abs < 1e-4 else 2)
