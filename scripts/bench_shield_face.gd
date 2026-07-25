extends Node
## SHIELD-SPIKE-1 step 0: does continuous tunnel-face excavation fit a frame?
##
## Not a feature. The gate the whole shield plan hangs on: a machine of Ø6 m
## driving forward at 1 m/s cuts a slice of the face every tick and drops part
## of the spoil behind itself. If that does not fit in 16.6 ms at any cell size,
## the plan stops at step 0 and the architecture is rethought instead.
##
## Measured on the *native* `GranularVoxelField` — the GDScript file of the same
## path is the specification, not what runs.
##
## Deliberately synchronous: no `await` anywhere in the run loop, so wall clock
## equals the work measured rather than the headless main loop's own pace.
##
## Usage:
##   godot --headless res://scenes/bench_shield_face.tscn -- --config=a
##     --config=a|b     which of the two candidate cell sizes (default: both)
##     --ticks=N        game ticks to run (default 2400 = 40 s at 60 Hz)
##     --budget=N       cells one sweep may visit; 0 = unlimited
##                      (default: `GranularVoxelWorld.CELL_BUDGET_PER_SWEEP`)
##     --headroom=N     leave N cells of air at the top of the box instead of
##                      filling it solid. Zero — the plan's own setup — means
##                      the box has no free volume at all, so the spoil the
##                      machine owes has nowhere to land until the cut has
##                      destroyed enough material to make room. That is a real
##                      result and it is the default; the flag exists so the
##                      deposit path can also be measured doing actual work.

const LABEL := "SHIELD-FACE"

## The two candidates from the plan. Both boxes are the same 120 x 24 x 24 m of
## world, so the only thing that changes between them is the cell.
const CONFIG_A := {
	"name": "A  cell 0.50 m  240x48x48",
	"cell": 0.5,
	"size": Vector3i(240, 48, 48),
}
const CONFIG_B := {
	"name": "B  cell 0.25 m  480x96x96",
	"cell": 0.25,
	"size": Vector3i(480, 96, 96),
}

## The machine.
const BORE_RADIUS_M := 3.0
const ADVANCE_M_PER_S := 1.0
const TICK_HZ := 60.0
## Share of the cut volume that comes back as spoil behind the shield.
const SPOIL_SHARE := 0.4
## How far behind the face the spoil is set down.
const SPOIL_LAG_M := 2.5
## Radius of the spoil footprint, in metres, at the bore floor.
const SPOIL_RADIUS_M := 1.0
## Where the machine starts along the long axis.
const START_X_M := 10.0
## Height of the bore axis above the rock — one radius, so the bore sits on the
## rock and the whole cut is in sand. That is the worst case for the field and
## the case the spike is about.
const BORE_ABOVE_ROCK_M := 3.0

const DEFAULT_TICKS := 2400

## The view's own settings, mirrored so the mesh measured here is the mesh the
## game would draw. Kept as literals rather than reaching into
## `GranularVoxelRegionView`, which is a Node3D and drags a material and shaders
## in with it.
const FLUSH_CHUNK := 16
const SMOOTH_PASSES := 1
const SMOOTH_CENTRE := 4.0
const RENDER_MIN_FILL := 0.15
const SURFACE_ISO := 0.35
const SDF_GAIN := 2.0
const AIR_SDF := 1.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("GranularVoxelField"):
		print("%s: FAIL - GranularVoxelField (native) is not registered" % LABEL)
		get_tree().quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var ticks := DEFAULT_TICKS
	var budget: int = GranularVoxelWorld.CELL_BUDGET_PER_SWEEP
	var which := "ab"
	var headroom := 0
	for arg in args:
		if arg.begins_with("--ticks="):
			ticks = int(arg.substr(8))
		elif arg.begins_with("--budget="):
			budget = int(arg.substr(9))
		elif arg.begins_with("--config="):
			which = arg.substr(9).to_lower()
		elif arg.begins_with("--headroom="):
			headroom = int(arg.substr(11))
	print(
		"%s: %d ticks (%.1f s of game time at %d Hz), sweep budget %s, headroom %d cells"
		% [
			LABEL,
			ticks,
			float(ticks) / TICK_HZ,
			int(TICK_HZ),
			("unlimited" if budget <= 0 else str(budget)),
			headroom,
		]
	)
	if which.contains("a"):
		_drive(CONFIG_A, ticks, budget, headroom)
	if which.contains("b"):
		_drive(CONFIG_B, ticks, budget, headroom)
	get_tree().quit(0)


func _drive(config: Dictionary, ticks: int, budget: int, headroom: int) -> void:
	var cell: float = config["cell"]
	var size: Vector3i = config["size"]
	print("")
	print("%s: === %s ===" % [LABEL, config["name"]])
	var cells_total := size.x * size.y * size.z
	print(
		"%s: %d cells, box %.1f x %.1f x %.1f m, ~%.1f MB of field state"
		% [
			LABEL,
			cells_total,
			float(size.x) * cell,
			float(size.y) * cell,
			float(size.z) * cell,
			float(cells_total) * 9.0 / 1048576.0,
		]
	)

	var t_create := Time.get_ticks_usec()
	var field := GranularVoxelField.create(size, cell)
	if field == null or field.size != size:
		print("%s: FAIL - could not create a field of %s" % [LABEL, str(size)])
		return
	# Exactly what `GranularVoxelRegion.create` does to a fresh field, so the
	# material moves at the speed the game's material moves at.
	field.fall_rate *= GranularVoxelRegion.STEP_FINENESS
	field.spread_rate *= GranularVoxelRegion.STEP_FINENESS
	field.lateral_rate *= GranularVoxelRegion.STEP_FINENESS
	print(
		"%s: created in %.1f ms" % [LABEL, float(Time.get_ticks_usec() - t_create) / 1000.0]
	)

	# --- ground: rock in the bottom half, sand filling the top half ----------
	@warning_ignore("integer_division")
	var rock_top := size.y / 2
	var t_fill := Time.get_ticks_usec()
	for z in size.z:
		for x in size.x:
			for y in rock_top:
				field.set_solid(x, y, z, true)
	var cell_volume := field.cell_volume_m3()
	var poured := 0.0
	for y in range(rock_top, size.y - headroom):
		for z in size.z:
			for x in size.x:
				poured += field.deposit(x, y, z, cell_volume)
	print(
		"%s: filled %.1f m3 of sand over rock in %.1f ms"
		% [LABEL, poured, float(Time.get_ticks_usec() - t_fill) / 1000.0]
	)

	# --- settle (preparation, not measured as part of the drive) -------------
	var t_settle := Time.get_ticks_usec()
	var settle_sweeps := 0
	while not field.is_settled() and settle_sweeps < 400:
		field.step(0)
		settle_sweeps += 1
	print(
		"%s: settled in %d sweeps, %.1f ms (settled=%s, %.1f m3 standing)"
		% [
			LABEL,
			settle_sweeps,
			float(Time.get_ticks_usec() - t_settle) / 1000.0,
			str(field.is_settled()),
			field.total_volume_m3(),
		]
	)

	# One full mesh of the box, once, so the incremental numbers below have the
	# cold cost to be read against.
	var t_full := Time.get_ticks_usec()
	var full_chunks := 0
	var full_tris := 0
	for cy in range(0, size.y, FLUSH_CHUNK):
		for cz in range(0, size.z, FLUSH_CHUNK):
			for cx in range(0, size.x, FLUSH_CHUNK):
				var lo := Vector3i(cx, cy, cz)
				var extent := (size - lo).min(Vector3i.ONE * FLUSH_CHUNK)
				var arrays: Array = field.build_mesh_box(
					lo, extent, SMOOTH_PASSES, SMOOTH_CENTRE, RENDER_MIN_FILL,
					SURFACE_ISO, SDF_GAIN, AIR_SDF
				)
				full_chunks += 1
				if not arrays.is_empty():
					full_tris += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	print(
		"%s: cold full mesh — %d chunks, %d triangles, %.1f ms"
		% [LABEL, full_chunks, full_tris, float(Time.get_ticks_usec() - t_full) / 1000.0]
	)
	# The setup marked every cell dirty; the drive is only interested in what
	# the machine itself changes.
	field.take_dirty_prep(FLUSH_CHUNK, 0)

	# --- the drive -----------------------------------------------------------
	var disc := _disc_offsets(cell)
	var spoil_columns := _spoil_columns(cell)
	var bore_y_m := float(rock_top) * cell + BORE_ABOVE_ROCK_M
	var bore_y := int(floor(bore_y_m / cell))
	@warning_ignore("integer_division")
	var bore_z := size.z / 2
	var bore_floor_y := int(floor((float(rock_top) * cell) / cell))
	var advance := ADVANCE_M_PER_S / TICK_HZ
	# Sweeps per tick, exactly as `GranularVoxelWorld._process` derives them.
	var sweep_debt := 0.0
	var flush_debt := 0.0

	var face_col := int(floor(START_X_M / cell))
	var cut_depth := 0.0

	var take_ms := PackedFloat32Array()
	var sim_ms := PackedFloat32Array()
	var mesh_ms := PackedFloat32Array()
	var commit_ms := PackedFloat32Array()
	## One `ArrayMesh` per chunk, kept and rewritten, exactly as the view keeps a
	## `MeshInstance3D` per chunk. Held here only so the commit — packing the
	## arrays into a surface — is measured apart from the marching. What this
	## cannot measure is the GPU upload: headless runs the dummy renderer.
	var chunk_meshes := {}
	var active := PackedInt32Array()
	var pending := PackedInt32Array()
	var chunks_meshed := 0
	var mesh_flushes := 0
	var cut_total := 0.0
	var spoil_total := 0.0
	var spoil_placed := 0.0
	var sweeps_total := 0
	var worst_tick_ms := 0.0
	var t_drive := Time.get_ticks_usec()

	for tick in ticks:
		var t0 := Time.get_ticks_usec()
		# --- cut ---------------------------------------------------------
		# The face moves 1/60 m a tick, which is a fraction of a cell either
		# way, so the frontier column is taken in proportion to how far into it
		# the machine has reached. When the column is spent it is cleared whole
		# and the machine steps to the next one.
		var taken := 0.0
		var fraction := advance / maxf(cell - cut_depth, 0.0001)
		fraction = clampf(fraction, 0.0, 1.0)
		for off: Vector2i in disc:
			taken += field.take_fraction(
				face_col, bore_y + off.x, bore_z + off.y, fraction
			)
		cut_depth += advance
		if cut_depth >= cell:
			for off: Vector2i in disc:
				taken += field.take(face_col, bore_y + off.x, bore_z + off.y)
			cut_depth -= cell
			face_col += 1
			if face_col >= size.x:
				print("%s: ran out of box at tick %d" % [LABEL, tick])
				break
		cut_total += taken
		# --- spoil -------------------------------------------------------
		var owed := taken * SPOIL_SHARE
		spoil_total += owed
		spoil_placed += _place_spoil(
			field,
			face_col - int(round(SPOIL_LAG_M / cell)),
			bore_floor_y,
			bore_z,
			spoil_columns,
			owed,
			size
		)
		var t1 := Time.get_ticks_usec()
		# --- simulation --------------------------------------------------
		sweep_debt += GranularVoxelWorld.SETTLE_HZ / TICK_HZ
		var sweeps: int = mini(int(sweep_debt), GranularVoxelWorld.MAX_SWEEPS_PER_FRAME)
		sweep_debt -= float(sweeps)
		for _s in sweeps:
			field.step(budget)
		sweeps_total += sweeps
		var t2 := Time.get_ticks_usec()
		# --- mesh --------------------------------------------------------
		var this_mesh_ms := 0.0
		var this_commit_us := 0
		flush_debt += GranularVoxelWorld.MESH_FLUSH_HZ / TICK_HZ
		if flush_debt >= 1.0:
			flush_debt -= 1.0
			mesh_flushes += 1
			# `shell_radius` 0: the chip shell is presentation the spike has
			# none of, and this measures the surface only.
			var prep: Dictionary = field.take_dirty_prep(FLUSH_CHUNK, 0)
			var chunk_ints: PackedInt32Array = prep["chunks"]
			var k := 0
			while k < chunk_ints.size():
				var lo := Vector3i(
					chunk_ints[k] * FLUSH_CHUNK,
					chunk_ints[k + 1] * FLUSH_CHUNK,
					chunk_ints[k + 2] * FLUSH_CHUNK
				)
				k += 9
				var extent := (size - lo).min(Vector3i.ONE * FLUSH_CHUNK)
				if extent.x <= 0 or extent.y <= 0 or extent.z <= 0:
					continue
				var arrays: Array = field.build_mesh_box(
					lo, extent, SMOOTH_PASSES, SMOOTH_CENTRE, RENDER_MIN_FILL,
					SURFACE_ISO, SDF_GAIN, AIR_SDF
				)
				chunks_meshed += 1
				var t_commit := Time.get_ticks_usec()
				if arrays.is_empty():
					chunk_meshes.erase(lo)
				else:
					var mesh: ArrayMesh = chunk_meshes.get(lo)
					if mesh == null:
						mesh = ArrayMesh.new()
						chunk_meshes[lo] = mesh
					mesh.clear_surfaces()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				this_commit_us += Time.get_ticks_usec() - t_commit
			this_mesh_ms = float(Time.get_ticks_usec() - t2 - this_commit_us) / 1000.0
		var t3 := Time.get_ticks_usec()
		take_ms.append(float(t1 - t0) / 1000.0)
		sim_ms.append(float(t2 - t1) / 1000.0)
		mesh_ms.append(this_mesh_ms)
		commit_ms.append(float(this_commit_us) / 1000.0)
		active.append(field.active_count())
		pending.append(field.pending_count())
		worst_tick_ms = maxf(worst_tick_ms, float(t3 - t0) / 1000.0)
	var drive_ms := float(Time.get_ticks_usec() - t_drive) / 1000.0

	var ran := take_ms.size()
	print(
		"%s: drove %d ticks (%.1f s of game time) in %.1f s of wall clock"
		% [LABEL, ran, float(ran) / TICK_HZ, drive_ms / 1000.0]
	)
	print(
		"%s: cut %.1f m3, owed %.1f m3 of spoil, placed %.1f m3, %d sweeps"
		% [LABEL, cut_total, spoil_total, spoil_placed, sweeps_total]
	)
	_report_f("take   ", take_ms)
	_report_f("sim    ", sim_ms)
	_report_f("mesh   ", mesh_ms)
	_report_f("commit ", commit_ms)
	print(
		"%s:   mesh flushed %d times, %d chunks total (%.1f chunks per flush)"
		% [
			LABEL,
			mesh_flushes,
			chunks_meshed,
			float(chunks_meshed) / maxf(float(mesh_flushes), 1.0),
		]
	)
	_report_i("active ", active)
	_report_i("pending", pending)
	# Is there a tunnel back there at all, or did the sand close it behind the
	# machine? Mean fill of the bore cross-section at a few distances back.
	var behind := PackedStringArray()
	for metres: float in [1.0, 5.0, 15.0, 30.0]:
		var col := face_col - int(round(metres / cell))
		if col < 0:
			continue
		var sum := 0.0
		for off: Vector2i in disc:
			sum += field.mass_at(col, bore_y + off.x, bore_z + off.y)
		behind.append("%.0f m: %.0f%%" % [metres, 100.0 * sum / float(disc.size())])
	print("%s:   bore fill behind the shield — %s" % [LABEL, " | ".join(behind)])
	var frame_mean := (
		_mean_f(take_ms) + _mean_f(sim_ms) + _mean_f(mesh_ms) + _mean_f(commit_ms)
	)
	print(
		"%s: TOTAL per tick — mean %.3f ms (%.1f%% of a 16.6 ms frame), worst tick %.3f ms"
		% [LABEL, frame_mean, 100.0 * frame_mean / 16.6, worst_tick_ms]
	)


## Cells of one face slice: a disc of `BORE_RADIUS_M` in the plane across the
## drive, as (dy, dz) offsets.
func _disc_offsets(cell: float) -> Array[Vector2i]:
	var reach := int(ceil(BORE_RADIUS_M / cell))
	var out: Array[Vector2i] = []
	for dy in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			var y_m := (float(dy) + 0.5) * cell
			var z_m := (float(dz) + 0.5) * cell
			if y_m * y_m + z_m * z_m <= BORE_RADIUS_M * BORE_RADIUS_M:
				out.append(Vector2i(dy, dz))
	return out


## Columns the spoil is dropped into, as (dx, dz) offsets from the point behind
## the machine.
func _spoil_columns(cell: float) -> Array[Vector2i]:
	var reach := maxi(1, int(round(SPOIL_RADIUS_M / cell)))
	var out: Array[Vector2i] = []
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			if float(dx * dx + dz * dz) * cell * cell <= SPOIL_RADIUS_M * SPOIL_RADIUS_M:
				out.append(Vector2i(dx, dz))
	return out


## Put the spoil down at the bore floor behind the shield, spread over a few
## columns and stacked upward when a column is full. Returns what was placed;
## anything short is volume with nowhere to go, which is itself a result.
func _place_spoil(
	field: GranularVoxelField,
	x: int,
	floor_y: int,
	z: int,
	columns: Array[Vector2i],
	volume_m3: float,
	size: Vector3i
) -> float:
	if volume_m3 <= 0.0 or x < 0 or x >= size.x:
		return 0.0
	var placed := 0.0
	var remaining := volume_m3
	var share := volume_m3 / float(columns.size())
	for pass_index in 2:
		for column: Vector2i in columns:
			if remaining <= 0.0:
				return placed
			var owed: float = minf(share if pass_index == 0 else remaining, remaining)
			for dy in range(0, size.y - floor_y):
				if owed <= 0.0:
					break
				var accepted := field.deposit(
					x + column.x, floor_y + dy, z + column.y, owed
				)
				placed += accepted
				remaining -= accepted
				owed -= accepted
	return placed


func _mean_f(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for v in values:
		sum += v
	return sum / float(values.size())


func _report_f(name: String, values: PackedFloat32Array) -> void:
	if values.is_empty():
		return
	var sorted := values.duplicate()
	sorted.sort()
	var peak := sorted[sorted.size() - 1]
	var p99 := sorted[mini(sorted.size() - 1, int(float(sorted.size()) * 0.99))]
	print(
		"%s:   %s mean %.3f ms   p99 %.3f ms   peak %.3f ms"
		% [LABEL, name, _mean_f(values), p99, peak]
	)


func _report_i(name: String, values: PackedInt32Array) -> void:
	if values.is_empty():
		return
	var sum := 0
	var peak := 0
	for v in values:
		sum += v
		peak = maxi(peak, v)
	print(
		"%s:   %s mean %d   peak %d"
		% [LABEL, name, sum / values.size(), peak]
	)
