extends Node3D
## SHIELD-SPIKE-1, playable rough build: a person drives a tunnel shield.
##
## Replaces steps 1 and 2 of `docs/plans/SHIELD-SPIKE-1.md` with one thing you
## can sit down at. The question it exists to answer is not "is this right" and
## not "is this pretty" — it is **is forty seconds of driving interesting**.
## Everything here that does not change how the driving *feels* is a stand-in.
##
## What is real:
##
##   * the granular field, at the 0.5 m cell step 0 settled on, with the sweep
##     budget off (`budget = 0`) — a budgeted sweep draws a tunnel that is not
##     there;
##   * cutting the face and returning part of it as spoil behind the machine,
##     the model measured in `scripts/bench_shield_face.gd`;
##   * the shield as a **physical tube**: it stamps its own cylindrical shell
##     solid, so the bore stays open while the machine is in it, and the shell
##     left behind is the lining. Step 0 measured sand closing a bare tunnel
##     100 % within five metres, so a shield that is only a cutting cursor
##     shows the driver nothing but sand.
##
## What is a stand-in, deliberately: the lining is solid cells and not blocks
## (that is step 3), the machine is a cage of rings with a lamp on it, and the
## rock is a second field that is never simulated — it exists only so the
## native mesher has something to draw a rock face from.
##
## Two fields, and the reason is worth knowing before changing anything here.
## `GranularVoxelField` draws rock (`set_solid`) only where it touches loose
## material, because in the game the rock is drawn by the world's own voxel
## terrain. A bore driven through solid rock touches no loose material at all,
## so its walls would be invisible — a black screen exactly where the plan
## wants the driver to feel the ground change. So rock is carried twice: as
## `set_solid` in the simulated field (it holds sand up, it does not flow) and
## as plain mass in a second field that is meshed but never stepped. Cutting
## rock clears both. Do not step `_rock` — it has no solid in it and the whole
## hill would fall.
##
## Debug stand: raw physical keys, no project input actions.
##
## Headless self-check:
##   godot --headless res://scenes/shield_drive.tscn -- --ticks=400

## The project's one grid. Not a knob: step 0 decided it, and construction,
## granular material and this all share it.
const CELL := 0.5
## The trace. 120 x 24 x 48 m, which is the plan's length, enough cover over
## the bore for a collapse to read, and enough width that an 18 m turning
## circle fits without hitting the side of the world.
const BOX := Vector3i(240, 48, 96)

## Mesh chunk edge, in cells — the same unit the view in the game uses, so what
## is timed here is what the game pays.
const FLUSH_CHUNK := 16
const MESH_CHUNKS_PER_FLUSH := 10
const MESH_FLUSH_HZ := 30.0
## Reconstruction settings, mirrored from `GranularVoxelRegionView` so this
## draws the surface the game draws.
const SMOOTH_PASSES := 1
const SMOOTH_CENTRE := 4.0
const RENDER_MIN_FILL := 0.15
const SURFACE_ISO := 0.35
const SDF_GAIN := 2.0
const AIR_SDF := 1.0

## Sweeps per second of game time, and the ceiling on how many one tick may
## run. Straight from `GranularVoxelWorld`, so material falls at the speed it
## falls at in the game.
## How much of a sweep's worth of movement one sweep makes, and how many sweeps
## a second that is paid for with. Copied from `GranularVoxelRegion` rather than
## read off it: this file is meant to survive whatever else is in flight in the
## tree, and at the time of writing that script does not compile (it calls
## native methods the built extension does not have yet). One constant is a
## cheaper price than a scene that will not load.
const STEP_FINENESS := 0.5
const SETTLE_HZ := 30.0 / STEP_FINENESS
const MAX_SWEEPS_PER_TICK := 8

## How far apart the machine's path is recorded. The camera rides this and so
## does the lining, because a tunnel that turned is not a straight line behind
## the shield — a chase camera placed on the heading would be inside the wall.
const TRAIL_STEP_M := 0.25
## How far ahead of the cutting face cells are taken. One plane of samples is
## enough by itself (the face sweeps every cell centre through it as the
## machine advances), so this is only the head start the cutterhead has on the
## shield skin.
const CUT_LEAD_M := 0.2

# --- the knobs ---------------------------------------------------------------

@export_group("Machine")
## Bore diameter. Everything else about the machine is derived from it: the
## face disc, the shell it stamps, the cage that is drawn.
@export var bore_diameter_m := 6.0
## Length of the tube. Also how far behind the face the lining is left, and so
## how far behind the face a collapse can reach if the lining is gapped.
@export var shield_length_m := 9.0
## Full-throttle advance in sand. The face is mostly sand for most of the
## trace, so this is the tempo of the whole run.
@export var speed_sand_m_s := 1.6
## Full-throttle advance in rock. The difference between the two is the only
## thing telling the driver what the ground is, HUD aside.
@export var speed_rock_m_s := 0.45
## The heart of it. Course may change no faster than `speed / radius`, so a
## turn has to be decided long before it is needed — and the faster the
## machine runs, the wider it swings.
@export var min_turn_radius_m := 18.0
## Share of the cut volume that comes back as spoil behind the shield. The
## plan's starting number. At 1.0 the tunnel fills with its own muck.
@export var spoil_share := 0.4
## How far behind the face the spoil is set down. Behind the chase camera, and
## that is not cosmetic: measured, a 0.4 share of a 1.8x overcut leaves the
## bore about 70 % full of its own muck, and a camera dropped into that sees
## nothing at all. Shorten this and the driver rides inside the spoil heap.
@export var spoil_lag_m := 16.0
## How fast the thrust lever moves under W/S, in full-scale per second.
@export var throttle_rate := 1.2
## How fast the steering follows A/D, in full-lock per second. Low on purpose:
## the driver is turning a machine, not a mouse.
@export var steer_rate := 1.6
## How fast steering and pitch return to centre when nothing is held.
@export var steer_centre_rate := 1.0
## Ceiling on climb and dive, radians.
@export var max_pitch_rad := 0.45

@export_group("Trace")
## Rock surface where there is no hill: well below the bore, so the machine
## starts and ends in clean sand.
@export var rock_base_m := 5.0
## How far the rock rises at the crest. Two things ride on it, and they pull in
## opposite directions: base plus this has to clear the top of the bore or the
## machine never gets a rock face at all, and it has to stay low enough that a
## driver who starts climbing early enough can go over the hill instead of
## through it. At 5 + 10 against a bore axis at 11 and a ceiling at 17.5, both
## hold — which is the one real decision in the run.
@export var rock_hill_m := 10.0
## Along-trace extent of the rock hill, in metres. The near flank decides how
## long the driver has to make up their mind.
@export var hill_from_m := 26.0
@export var hill_to_m := 80.0
## Cross-trace tilt of the rock surface, metres of rise per metre across. Makes
## the ground boundary arrive at the face on a slant instead of level, which is
## what tells the driver to climb or dive rather than just to slow down.
@export var rock_cross_slope := 0.09
## Top of the sand. Left short of the ceiling so spoil and heave have somewhere
## to go.
@export var sand_top_m := 22.0
## Where the machine starts, and the height of its axis. Far enough in that the
## launch chamber behind it — and the camera riding in it — is inside the box
## from the first frame.
@export var start_x_m := 18.0
@export var bore_axis_y_m := 11.0

@export_group("Lining")
## Lining period and how much of each period stays solid behind the tail.
## Equal — the default — is a continuous lining: the shell the shield stamped
## simply stays, which is the whole of "rings are erected in the tail".
## Shorten `ring_solid_m` and the gaps between rings are unpinned as the tail
## clears them, and the sand comes in. That is the tension knob, and it is off
## by default because a buried camera answers no question about driving.
@export var ring_period_m := 2.0
@export var ring_solid_m := 2.0

@export_group("Camera")
## How far back along the tunnel the chase camera rides, and how far off the
## axis. Back far enough to see the machine, close enough to stay in the lit
## part of the bore.
@export var camera_back_m := 10.0
@export var camera_up_m := 1.6
## Point ahead of the face the camera aims at.
@export var camera_look_ahead_m := 4.0
## Metres per second the camera closes on where it should be. High enough to
## keep up in a turn, low enough to smooth the 0.25 m trail steps.
@export var camera_follow_rate := 12.0

# --- state -------------------------------------------------------------------

var _field: GranularVoxelField
var _rock: GranularVoxelField
var _sand_view: Node3D
var _rock_view: Node3D
var _sand_chunks: Dictionary = {}
var _rock_chunks: Dictionary = {}
var _sand_pending: Dictionary = {}
var _rock_pending: Dictionary = {}
var _sand_material: Material
var _rock_material: Material

var _machine: Node3D
var _chase: Camera3D
var _fly: Camera3D
var _legend: Label
var _status: Label

var _pos := Vector3.ZERO
var _yaw := 0.0
var _pitch := 0.0
var _throttle := 0.0
var _steer := 0.0
var _elevator := 0.0
var _speed := 0.0
var _travelled := 0.0
var _rock_share := 0.0
var _air_share := 0.0
var _cut_m3 := 0.0
var _spoil_m3 := 0.0
var _blocked := false

var _trail_pos := PackedVector3Array()
var _trail_fwd := PackedVector3Array()
var _trail_dist := PackedFloat32Array()
var _shell_done_m := 0.0
var _lining_cursor := 0

## Face disc offsets in the machine's own plane, metres, at half a cell — fine
## enough that a sample lands inside every cell the disc crosses.
var _disc: Array[Vector2] = []
## A coarse ring of the same disc, for asking what the ground ahead is.
var _probe: Array[Vector2] = []
## Columns spoil is spread over, as (dx, dz) cell offsets.
var _spoil_cols: Array[Vector2i] = []

## Cell-visited marks, so a sample pattern that hits the same cell a dozen
## times still only crosses into native code once. A generation counter rather
## than a clear: clearing a million-entry array every tick is the cost this
## avoids.
var _stamp := PackedInt32Array()
var _stamp_gen := 0

var _sweep_debt := 0.0
var _flush_debt := 0.0
var _fly_mode := false
var _autopilot_ticks := 0
var _tick := 0
var _prof_cut_ms := 0.0
var _prof_sim_ms := 0.0
var _prof_mesh_ms := 0.0
var _prof_worst_ms := 0.0
## Where the ground last changed under the machine, for the headless check:
## a run that never leaves the sand proves nothing about the trace.
var _seen_grounds := {}


func _ready() -> void:
	if not ClassDB.class_exists("GranularVoxelField"):
		push_error("SHIELD: GranularVoxelField (native) is not registered")
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ticks="):
			_autopilot_ticks = int(arg.substr(8))
		elif arg.begins_with("--ring-solid="):
			# So the headless check can walk the un-pinning path, which is off
			# at its default setting.
			ring_solid_m = float(arg.substr(13))
	var started := Time.get_ticks_usec()
	_build_shapes()
	_build_fields()
	_build_views()
	_build_machine()
	_build_hud()
	_pos = Vector3(start_x_m, bore_axis_y_m, float(BOX.z) * CELL * 0.5)
	_push_trail()
	# A launch chamber: the shield does not start buried, or the chase camera
	# opens on the inside of a sand dune.
	var launch := maxf(shield_length_m, camera_back_m) + 6.0
	_bore_out(launch)
	_stamp_shell(-SHELL_LEAD_M, launch)
	_remesh_all()
	_update_camera(1.0)
	print(
		"SHIELD: trace %.0f x %.0f x %.0f m, %d cells x2, ready in %.0f ms"
		% [
			float(BOX.x) * CELL, float(BOX.y) * CELL, float(BOX.z) * CELL,
			BOX.x * BOX.y * BOX.z,
			float(Time.get_ticks_usec() - started) / 1000.0,
		]
	)


# --- setup -------------------------------------------------------------------


func _build_shapes() -> void:
	var radius := bore_diameter_m * 0.5
	var step := CELL * 0.5
	var reach := int(ceil(radius / step))
	_disc.clear()
	for iu in range(-reach, reach + 1):
		for iv in range(-reach, reach + 1):
			var u := float(iu) * step
			var v := float(iv) * step
			if u * u + v * v <= radius * radius:
				_disc.append(Vector2(u, v))
	_probe.clear()
	_probe.append(Vector2.ZERO)
	for ring: float in [0.5, 0.85]:
		for k in 6:
			var angle := TAU * float(k) / 6.0 + (0.5 if ring > 0.6 else 0.0)
			_probe.append(Vector2(cos(angle), sin(angle)) * radius * ring)
	_spoil_cols.clear()
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			if dx * dx + dz * dz <= 4:
				_spoil_cols.append(Vector2i(dx, dz))


func _build_fields() -> void:
	_field = GranularVoxelField.create(BOX, CELL)
	_rock = GranularVoxelField.create(BOX, CELL)
	# The same rate scaling a region applies, so material moves at the speed
	# the game's material moves at.
	_field.fall_rate *= STEP_FINENESS
	_field.spread_rate *= STEP_FINENESS
	_field.lateral_rate *= STEP_FINENESS
	_stamp.resize(BOX.x * BOX.y * BOX.z)
	_stamp.fill(-1)

	var cell_volume := _field.cell_volume_m3()
	var sand_top_cell := int(floor(sand_top_m / CELL))
	for x in BOX.x:
		var x_m := (float(x) + 0.5) * CELL
		for z in BOX.z:
			var z_m := (float(z) + 0.5) * CELL
			var rock_cells := int(round(_rock_top_m(x_m, z_m) / CELL))
			rock_cells = clampi(rock_cells, 0, BOX.y)
			for y in rock_cells:
				# Solid in the simulated field: it holds sand up and never
				# flows. Mass in the drawn field: it is the only reason a bore
				# through rock has visible walls.
				_field.set_solid(x, y, z, true)
				_rock.deposit(x, y, z, cell_volume)
			for y in range(rock_cells, sand_top_cell):
				_field.deposit(x, y, z, cell_volume)
	# One sweep to let the slope of the boundary settle. The fill is flat-topped
	# and rests on rock, so there is almost nothing to do — but the sand lying
	# on the flank of the hill is not at its angle of repose until it has been
	# asked.
	var guard := 0
	while not _field.is_settled() and guard < 60:
		_field.step(0)
		guard += 1


## Top of the rock at a point on the trace: flat, then a hill the drive has to
## go through, then flat again — so a straight run crosses sand, rock and sand
## without the driver choosing anything. The cross slope tilts the boundary so
## it arrives at the face on a slant.
func _rock_top_m(x_m: float, z_m: float) -> float:
	var top := rock_base_m
	if x_m > hill_from_m and x_m < hill_to_m:
		var t := (x_m - hill_from_m) / maxf(hill_to_m - hill_from_m, 0.001)
		# A rounded crest with flanks steep enough to cross in a few seconds,
		# and a plateau long enough to be unmistakably *in* the rock.
		top += rock_hill_m * smoothstep(0.12, 0.42, sin(PI * t))
	return top + (z_m - float(BOX.z) * CELL * 0.5) * rock_cross_slope


func _build_views() -> void:
	_sand_material = _make_material(Color(0.60, 0.52, 0.39), 1.0)
	_rock_material = _make_material(Color(0.30, 0.31, 0.34), 0.85)
	_sand_view = Node3D.new()
	_sand_view.name = "SandSurface"
	add_child(_sand_view)
	_rock_view = Node3D.new()
	_rock_view.name = "RockSurface"
	add_child(_rock_view)


static func _make_material(albedo: Color, roughness: float) -> Material:
	# The native mesher emits vertices and normals and no UVs at all, so a
	# textured material would come out as flat colour. Plain shading, and the
	# lamp on the machine does the rest.
	var material := StandardMaterial3D.new()
	material.albedo_color = albedo
	material.roughness = roughness
	material.metallic = 0.0
	return material


func _build_machine() -> void:
	_machine = Node3D.new()
	_machine.name = "Shield"
	# Machine and cameras are placed in `_process`, on the frame's own clock,
	# so the engine must not also interpolate them from physics transforms.
	_machine.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_machine)
	var radius := bore_diameter_m * 0.5
	var metal := _make_material(Color(0.34, 0.36, 0.40), 0.45)
	var lit := StandardMaterial3D.new()
	lit.albedo_color = Color(0.9, 0.75, 0.45)
	lit.emission_enabled = true
	lit.emission = Color(0.9, 0.7, 0.35)
	lit.emission_energy_multiplier = 1.5
	# A cage rather than a skin: the driver has to see the face through the
	# machine, and a translucent tube seen from inside is a sorting problem
	# nobody needs in a spike.
	for k in 4:
		var ring := TorusMesh.new()
		ring.inner_radius = radius - 0.32
		ring.outer_radius = radius - 0.10
		ring.rings = 6
		ring.ring_segments = 24
		var node := MeshInstance3D.new()
		node.mesh = ring
		node.material_override = (lit if k == 0 else metal)
		# The torus stands in the XZ plane; turn its axis along the drive.
		node.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		node.position = Vector3(
			0.0, 0.0, -shield_length_m * float(k) / 3.0
		)
		_machine.add_child(node)
	for k in 6:
		var angle := TAU * float(k) / 6.0
		var strut := BoxMesh.new()
		strut.size = Vector3(0.16, 0.16, shield_length_m)
		var node := MeshInstance3D.new()
		node.mesh = strut
		node.material_override = metal
		node.position = Vector3(
			cos(angle) * (radius - 0.22),
			sin(angle) * (radius - 0.22),
			-shield_length_m * 0.5
		)
		_machine.add_child(node)
	# Underground and unlit: without a lamp on the machine this is a black
	# screen and there is nothing to judge.
	var head_lamp := SpotLight3D.new()
	head_lamp.position = Vector3(0.0, 0.0, -0.6)
	head_lamp.spot_range = 42.0
	head_lamp.spot_angle = 62.0
	head_lamp.light_energy = 3.2
	head_lamp.light_color = Color(1.0, 0.94, 0.84)
	_machine.add_child(head_lamp)
	var tail_lamp := OmniLight3D.new()
	tail_lamp.position = Vector3(0.0, 0.0, -shield_length_m * 0.6)
	tail_lamp.omni_range = 16.0
	tail_lamp.light_energy = 1.4
	tail_lamp.light_color = Color(0.85, 0.9, 1.0)
	_machine.add_child(tail_lamp)

	_chase = Camera3D.new()
	_chase.far = 400.0
	_chase.fov = 78.0
	_chase.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_chase)
	_chase.current = true
	_fly = Camera3D.new()
	_fly.far = 600.0
	_fly.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_fly.set_script(load("res://addons/ropes/demos/fly_camera.gd"))
	add_child(_fly)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_legend = Label.new()
	_legend.position = Vector2(16.0, 12.0)
	_legend.text = "\n".join([
		"W / S — thrust      A / D — course      Q / E — pitch",
		"C — chase / free camera (free: hold RMB + WASD)      R — restart",
	])
	layer.add_child(_legend)
	_status = Label.new()
	_status.position = Vector2(16.0, 66.0)
	layer.add_child(_status)


# --- driving -----------------------------------------------------------------


func _physics_process(delta: float) -> void:
	if _field == null:
		return
	_tick += 1
	_read_controls(delta)
	var t0 := Time.get_ticks_usec()
	var advance := _advance(delta)
	var cut := 0.0
	if advance > 0.0:
		cut = _cut(advance)
		_cut_m3 += cut
		_spoil_m3 += _spoil(cut * spoil_share)
	while _travelled - _shell_done_m > TRAIL_STEP_M:
		_shell_done_m += TRAIL_STEP_M
		# Only the band the previous stamp cannot already have covered: the
		# machine moves `TRAIL_STEP_M` between stamps, so the two overlap.
		_stamp_shell(-SHELL_LEAD_M, CELL * 0.5)
	_retire_lining()
	var t1 := Time.get_ticks_usec()
	_sweep_debt += SETTLE_HZ * delta
	var sweeps := mini(int(_sweep_debt), MAX_SWEEPS_PER_TICK)
	_sweep_debt -= float(sweeps)
	for _s in sweeps:
		# Budget off. Step 0: a budgeted sweep does not save time and leaves a
		# tunnel standing in sand that has simply not been swept yet.
		_field.step(0)
	var t2 := Time.get_ticks_usec()
	_flush_debt += MESH_FLUSH_HZ * delta
	if _flush_debt >= 1.0:
		_flush_debt -= 1.0
		_flush(_field, _sand_view, _sand_chunks, _sand_pending, _sand_material)
		_flush(_rock, _rock_view, _rock_chunks, _rock_pending, _rock_material)
	var t3 := Time.get_ticks_usec()
	# Smoothed, because the shell is stamped and the mesh is flushed on their
	# own clocks: an instantaneous number is a different measurement every
	# frame and tells the eye nothing.
	_prof_cut_ms = lerpf(_prof_cut_ms, float(t1 - t0) / 1000.0, 0.1)
	_prof_sim_ms = lerpf(_prof_sim_ms, float(t2 - t1) / 1000.0, 0.1)
	_prof_mesh_ms = lerpf(_prof_mesh_ms, float(t3 - t2) / 1000.0, 0.1)
	_prof_worst_ms = maxf(_prof_worst_ms, float(t3 - t0) / 1000.0)
	if _autopilot_ticks > 0 and _tick >= _autopilot_ticks:
		_finish_autopilot()


func _read_controls(delta: float) -> void:
	if _autopilot_ticks > 0:
		# Full thrust and a slow weave, so a headless run exercises turning,
		# the trail, the lining and both grounds without a hand on the keys.
		_throttle = 1.0
		_steer = sin(float(_tick) / 90.0)
		_elevator = 0.0
		return
	if _fly_mode:
		# The free camera owns WASDQE while it is up; driving with it would
		# mean both at once.
		return
	var thrust := 0.0
	if Input.is_physical_key_pressed(KEY_W):
		thrust += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		thrust -= 1.0
	_throttle = clampf(_throttle + thrust * throttle_rate * delta, 0.0, 1.0)
	_steer = _toward_input(
		_steer,
		(1.0 if Input.is_physical_key_pressed(KEY_D) else 0.0)
			- (1.0 if Input.is_physical_key_pressed(KEY_A) else 0.0),
		delta
	)
	_elevator = _toward_input(
		_elevator,
		(1.0 if Input.is_physical_key_pressed(KEY_E) else 0.0)
			- (1.0 if Input.is_physical_key_pressed(KEY_Q) else 0.0),
		delta
	)


func _toward_input(value: float, wanted: float, delta: float) -> float:
	var rate := steer_rate if not is_zero_approx(wanted) else steer_centre_rate
	return clampf(move_toward(value, wanted, rate * delta), -1.0, 1.0)


## Move the machine and report how far it went. Course rate is tied to speed
## through the minimum radius, which is the whole feel of the thing: standing
## still the machine cannot be aimed at all, and at full speed it swings by
## about three degrees a second.
func _advance(delta: float) -> float:
	_sample_face()
	var ground := lerpf(speed_sand_m_s, speed_rock_m_s, _rock_share)
	_speed = _throttle * ground
	var turn := _speed / maxf(min_turn_radius_m, 0.1)
	_yaw += _steer * turn * delta
	_pitch = clampf(
		_pitch + _elevator * turn * delta, -max_pitch_rad, max_pitch_rad
	)
	var step := _speed * delta
	if step <= 0.0:
		return 0.0
	var wanted := _pos + _forward() * step
	var margin := bore_diameter_m * 0.5 + 1.5
	var clamped := Vector3(
		clampf(wanted.x, margin, float(BOX.x) * CELL - margin),
		clampf(wanted.y, margin, sand_top_m - margin),
		clampf(wanted.z, margin, float(BOX.z) * CELL - margin)
	)
	_blocked = not clamped.is_equal_approx(wanted)
	if _blocked:
		# The edge of the world is not a mechanic; stop rather than grind.
		_speed = 0.0
		_throttle = 0.0
		return 0.0
	_pos = clamped
	_travelled += step
	if _travelled - _trail_dist[_trail_dist.size() - 1] >= TRAIL_STEP_M:
		_push_trail()
	return step


func _forward() -> Vector3:
	return Vector3(
		cos(_pitch) * cos(_yaw), sin(_pitch), cos(_pitch) * sin(_yaw)
	)


func _frame(fwd: Vector3) -> Array:
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	return [right, right.cross(fwd).normalized()]


func _push_trail() -> void:
	_trail_pos.append(_pos)
	_trail_fwd.append(_forward())
	_trail_dist.append(_travelled)


# --- the ground --------------------------------------------------------------


## What is standing in the face, as shares. Cheap on purpose — thirteen points,
## every tick — because the only thing it decides is the advance rate.
func _sample_face() -> void:
	var fwd := _forward()
	var basis := _frame(fwd)
	var right: Vector3 = basis[0]
	var up: Vector3 = basis[1]
	var base := _pos + fwd * (CELL + CUT_LEAD_M)
	var rock := 0
	var air := 0
	for uv in _probe:
		var c := _cell_of(base + right * uv.x + up * uv.y)
		if not _in_box(c):
			continue
		if _rock.mass_at(c.x, c.y, c.z) > 0.5:
			rock += 1
		elif _field.mass_at(c.x, c.y, c.z) < 0.2:
			air += 1
	var total := float(_probe.size())
	_rock_share = float(rock) / total
	_air_share = float(air) / total
	_seen_grounds[
		"rock" if _rock_share > 0.8
		else ("sand" if _rock_share < 0.1 else "mixed")
	] = true


func _ground_name() -> String:
	if _air_share > 0.7:
		return "open"
	if _rock_share > 0.8:
		return "rock"
	if _rock_share < 0.1:
		return "sand"
	return "sand / rock %d%%" % int(round(_rock_share * 100.0))


# --- cutting, spoil, shell ---------------------------------------------------


## Take one face slice and report the volume. Sampled in the machine's own
## plane at half a cell, which guarantees a sample lands inside every cell the
## disc crosses; the machine's own advance sweeps the plane through every cell
## centre, so one plane per tick leaves nothing behind.
func _cut(advance: float) -> float:
	_stamp_gen += 1
	var fwd := _forward()
	var basis := _frame(fwd)
	var right: Vector3 = basis[0]
	var up: Vector3 = basis[1]
	var taken := 0.0
	var depth := 0.0
	var reach := advance + CUT_LEAD_M
	while true:
		var base := _pos + fwd * depth
		for uv in _disc:
			var c := _cell_of(base + right * uv.x + up * uv.y)
			if not _in_box(c):
				continue
			var index := (c.y * BOX.z + c.z) * BOX.x + c.x
			if _stamp[index] == _stamp_gen:
				continue
			_stamp[index] = _stamp_gen
			var rock := _rock.take(c.x, c.y, c.z)
			if rock > 0.0:
				taken += rock
				# The cell stops holding anything up in the simulated field
				# too, or the bore through rock would be a hole nothing can
				# fall into.
				_field.set_solid(c.x, c.y, c.z, false)
			else:
				taken += _field.take(c.x, c.y, c.z)
		if depth >= reach:
			break
		depth = minf(depth + CELL * 0.5, reach)
	return taken


## How far *ahead* of the cutting face the shield's skin already stands. A real
## shield's skin runs to the cutting edge, and this is not decoration: with the
## skin starting at the face, the sand over the crown just ahead of it ravels
## into the cut and is eaten again, tick after tick. Measured — 2.9x the
## nominal bore volume against the 1.4x step 0 saw, i.e. the machine was
## chimneying rather than tunnelling.
const SHELL_LEAD_M := 0.6


## Clear a length of bore straight back from the machine. Used once, for the
## launch chamber; the drive itself cuts a slice at a time.
func _bore_out(back_m: float) -> void:
	_stamp_gen += 1
	var fwd := _forward()
	var basis := _frame(fwd)
	var right: Vector3 = basis[0]
	var up: Vector3 = basis[1]
	var depth := 0.0
	while depth <= back_m:
		var base := _pos - fwd * depth
		for uv in _disc:
			var c := _cell_of(base + right * uv.x + up * uv.y)
			if not _in_box(c):
				continue
			var index := (c.y * BOX.z + c.z) * BOX.x + c.x
			if _stamp[index] == _stamp_gen:
				continue
			_stamp[index] = _stamp_gen
			if _rock.take(c.x, c.y, c.z) > 0.0:
				_field.set_solid(c.x, c.y, c.z, false)
			else:
				_field.take(c.x, c.y, c.z)
		depth += CELL * 0.5


## Set the spoil down on the bore floor behind the shield. Returns what was
## placed; anything short is volume with nowhere to go, which is a fact about
## the tunnel rather than an error.
func _spoil(volume_m3: float) -> float:
	if volume_m3 <= 0.0:
		return 0.0
	var at := _trail_at(_travelled - spoil_lag_m)
	var floor_point: Vector3 = at[0] - Vector3.UP * (bore_diameter_m * 0.5 - 0.4)
	var base := _cell_of(floor_point)
	var placed := 0.0
	var remaining := volume_m3
	var share := volume_m3 / float(_spoil_cols.size())
	for pass_index in 2:
		for column in _spoil_cols:
			if remaining <= 0.0:
				return placed
			var owed: float = minf(
				share if pass_index == 0 else remaining, remaining
			)
			for dy in 12:
				if owed <= 0.0:
					break
				var accepted := _field.deposit(
					base.x + column.x, base.y + dy, base.z + column.y, owed
				)
				placed += accepted
				remaining -= accepted
				owed -= accepted
	return placed


## The cells of the shield's skin over an axial band behind the face, as an
## index-keyed set. Three radii and a quarter-metre pitch, so the shell is
## watertight: a single gap and the sand is in the tunnel.
func _shell_cells(
	pos: Vector3, fwd: Vector3, from_m: float, to_m: float
) -> Dictionary:
	var basis := _frame(fwd)
	var right: Vector3 = basis[0]
	var up: Vector3 = basis[1]
	var radius := bore_diameter_m * 0.5
	var segments := int(ceil(TAU * (radius + 0.7) / (CELL * 0.4)))
	var out := {}
	var depth := from_m
	while depth <= to_m:
		var base := pos - fwd * depth
		for ring: float in [0.15, 0.40, 0.65]:
			var r := radius + ring
			for k in segments:
				var angle := TAU * float(k) / float(segments)
				var c := _cell_of(
					base + (right * cos(angle) + up * sin(angle)) * r
				)
				if not _in_box(c):
					continue
				out[(c.y * BOX.z + c.z) * BOX.x + c.x] = c
		depth += CELL * 0.5
	return out


func _stamp_shell(from_m: float, to_m: float) -> void:
	for c: Vector3i in _shell_cells(_pos, _forward(), from_m, to_m).values():
		_field.set_solid(c.x, c.y, c.z, true)


## Unpin the shell where no ring stands, once the tail has cleared it.
##
## `set_solid` alone would leave the sand above asleep — nothing told it its
## support went away. `invalidate_solid` is the only wake that does not also
## move material, so the box is read first and put back exactly as it was,
## minus the cells being freed. Reading rather than remembering matters: the
## box also holds rock the machine has already cut through, and re-deriving
## that from the geology would fill the tunnel back in.
func _retire_lining() -> void:
	if ring_solid_m >= ring_period_m or ring_period_m <= 0.0:
		return
	var cleared := _travelled - shield_length_m
	while (
		_lining_cursor < _trail_dist.size()
		and _trail_dist[_lining_cursor] <= cleared
	):
		var at := _lining_cursor
		_lining_cursor += 1
		var dist := _trail_dist[at]
		if fmod(dist, ring_period_m) < ring_solid_m:
			continue
		var cells := _shell_cells(
			_trail_pos[at], _trail_fwd[at], 0.0, TRAIL_STEP_M
		)
		if cells.is_empty():
			continue
		var lo := Vector3i(BOX)
		var hi := Vector3i.ZERO
		for c: Vector3i in cells.values():
			lo = lo.min(c)
			hi = hi.max(c)
		lo = (lo - Vector3i.ONE).clamp(Vector3i.ZERO, BOX - Vector3i.ONE)
		hi = (hi + Vector3i.ONE).clamp(Vector3i.ZERO, BOX - Vector3i.ONE)
		var extent := hi - lo + Vector3i.ONE
		var was := _field.copy_solid_box(lo, extent)
		_field.invalidate_solid(lo, hi)
		var i := 0
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				for x in range(lo.x, hi.x + 1):
					if was[i] != 0 and not cells.has((y * BOX.z + z) * BOX.x + x):
						_field.set_solid(x, y, z, true)
					i += 1


func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i(
		int(floor(point.x / CELL)),
		int(floor(point.y / CELL)),
		int(floor(point.z / CELL))
	)


func _in_box(c: Vector3i) -> bool:
	return (
		c.x >= 0 and c.y >= 0 and c.z >= 0
		and c.x < BOX.x and c.y < BOX.y and c.z < BOX.z
	)


# --- surface -----------------------------------------------------------------


func _remesh_all() -> void:
	for cy in range(0, BOX.y, FLUSH_CHUNK):
		for cz in range(0, BOX.z, FLUSH_CHUNK):
			for cx in range(0, BOX.x, FLUSH_CHUNK):
				var chunk := Vector3i(
					cx / FLUSH_CHUNK, cy / FLUSH_CHUNK, cz / FLUSH_CHUNK
				)
				_mesh_chunk(_field, _sand_view, _sand_chunks, _sand_material, chunk)
				_mesh_chunk(_rock, _rock_view, _rock_chunks, _rock_material, chunk)
	_field.take_dirty_prep(FLUSH_CHUNK, 0)
	_rock.take_dirty_prep(FLUSH_CHUNK, 0)


func _flush(
	field: GranularVoxelField,
	view: Node3D,
	meshes: Dictionary,
	pending: Dictionary,
	material: Material
) -> void:
	var prep: Dictionary = field.take_dirty_prep(FLUSH_CHUNK, 0)
	var chunks: PackedInt32Array = prep["chunks"]
	var k := 0
	while k < chunks.size():
		pending[Vector3i(chunks[k], chunks[k + 1], chunks[k + 2])] = true
		k += 9
	if pending.is_empty():
		return
	var done := 0
	var drawn: Array[Vector3i] = []
	for chunk: Vector3i in pending:
		if done >= MESH_CHUNKS_PER_FLUSH:
			break
		_mesh_chunk(field, view, meshes, material, chunk)
		drawn.append(chunk)
		done += 1
	for chunk in drawn:
		pending.erase(chunk)


func _mesh_chunk(
	field: GranularVoxelField,
	view: Node3D,
	meshes: Dictionary,
	material: Material,
	chunk: Vector3i
) -> void:
	var lo := chunk * FLUSH_CHUNK
	var extent := (BOX - lo).min(Vector3i.ONE * FLUSH_CHUNK)
	if extent.x <= 0 or extent.y <= 0 or extent.z <= 0:
		return
	var arrays: Array = field.build_mesh_box(
		lo, extent, SMOOTH_PASSES, SMOOTH_CENTRE, RENDER_MIN_FILL,
		SURFACE_ISO, SDF_GAIN, AIR_SDF
	)
	var instance: MeshInstance3D = meshes.get(chunk)
	if arrays.is_empty():
		if instance != null:
			meshes.erase(chunk)
			instance.queue_free()
		return
	if instance == null:
		instance = MeshInstance3D.new()
		instance.mesh = ArrayMesh.new()
		instance.material_override = material
		# Vertices come out in cell units, so the scale is the whole transform.
		instance.scale = Vector3.ONE * CELL
		view.add_child(instance)
		meshes[chunk] = instance
	var mesh := instance.mesh as ArrayMesh
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


# --- camera and HUD ----------------------------------------------------------


func _process(delta: float) -> void:
	if _field == null:
		return
	_update_camera(delta)
	_update_hud()


## Where the machine was `back_m` ago, as `[position, forward]`. Along the
## tunnel, not along the heading — the chase camera has to stay inside the bore
## through a turn, and so does the spoil.
func _trail_at(distance: float) -> Array:
	var count := _trail_dist.size()
	if distance <= _trail_dist[0]:
		return [
			_trail_pos[0] + _trail_fwd[0] * (distance - _trail_dist[0]),
			_trail_fwd[0],
		]
	var lo := 0
	var hi := count - 1
	while lo + 1 < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if _trail_dist[mid] <= distance:
			lo = mid
		else:
			hi = mid
	var span := _trail_dist[hi] - _trail_dist[lo]
	var t := 0.0 if span <= 0.0 else (distance - _trail_dist[lo]) / span
	return [
		_trail_pos[lo].lerp(_trail_pos[hi], t),
		_trail_fwd[lo].lerp(_trail_fwd[hi], t).normalized(),
	]


func _update_camera(delta: float) -> void:
	var fwd := _forward()
	var basis := Basis()
	var right_up := _frame(fwd)
	basis.x = right_up[0]
	basis.y = right_up[1]
	basis.z = -fwd
	_machine.transform = Transform3D(basis, _pos)
	if _fly_mode:
		return
	var at := _trail_at(_travelled - camera_back_m)
	var wanted: Vector3 = at[0] + Vector3.UP * camera_up_m
	var here := _chase.global_position
	if here.distance_to(wanted) > 40.0 or delta >= 1.0:
		here = wanted
	else:
		here = here.lerp(wanted, clampf(camera_follow_rate * delta, 0.0, 1.0))
	_chase.global_position = here
	var target := _pos + fwd * camera_look_ahead_m
	if here.distance_to(target) > 0.2:
		_chase.look_at(target, Vector3.UP)


func _update_hud() -> void:
	_status.text = "\n".join([
		"%.1f m driven%s" % [
			_travelled, "   [edge of the trace]" if _blocked else ""
		],
		"%.2f m/s   thrust %d%%   course %+.0f deg   pitch %+.0f deg" % [
			_speed,
			int(round(_throttle * 100.0)),
			rad_to_deg(_yaw),
			rad_to_deg(_pitch),
		],
		"face: %s   cut %.0f m3   spoil %.0f m3" % [
			_ground_name(), _cut_m3, _spoil_m3
		],
		"%d fps   cut %.2f / sim %.2f / mesh %.2f ms" % [
			Engine.get_frames_per_second(),
			_prof_cut_ms, _prof_sim_ms, _prof_mesh_ms,
		],
	])


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_C:
			_fly_mode = not _fly_mode
			if _fly_mode:
				_fly.global_transform = _chase.global_transform
			_fly.current = _fly_mode
			_chase.current = not _fly_mode
		KEY_R:
			get_tree().reload_current_scene()


# --- headless self-check -----------------------------------------------------


func _finish_autopilot() -> void:
	_autopilot_ticks = 0
	var nominal := PI * pow(bore_diameter_m * 0.5, 2.0) * _travelled
	var expected := speed_sand_m_s * float(_tick) / 60.0 * 0.5
	var faults := PackedStringArray()
	if _travelled < expected:
		faults.append(
			"machine barely moved: %.2f m in %d ticks" % [_travelled, _tick]
		)
	if _cut_m3 <= 0.0:
		faults.append("nothing was cut")
	if _spoil_m3 <= 0.0 and _travelled > spoil_lag_m:
		faults.append("no spoil was placed")
	if _sand_chunks.is_empty() or _rock_chunks.is_empty():
		faults.append(
			"surfaces missing (sand %d, rock %d chunks)"
			% [_sand_chunks.size(), _rock_chunks.size()]
		)
	print(
		"SHIELD: %d ticks, %.1f m, %.2f m/s, face %s, grounds seen %s"
		% [
			_tick, _travelled, _speed, _ground_name(),
			str(_seen_grounds.keys()),
		]
	)
	print(
		"SHIELD: cut %.0f m3 (%.2fx the bore), spoil %.0f m3, %d trail points"
		% [
			_cut_m3, _cut_m3 / maxf(nominal, 0.001), _spoil_m3,
			_trail_dist.size(),
		]
	)
	# The whole reason the shield stamps a shell: step 0 measured a bare tunnel
	# in sand at 100 % closed within five metres. If these numbers climb, the
	# tube is leaking and the build is showing a lie.
	var behind := PackedStringArray()
	for back: float in [5.0, 15.0, 25.0]:
		if back > _travelled + camera_back_m:
			continue
		var at := _trail_at(_travelled - back)
		var frame := _frame(at[1])
		var sum := 0.0
		for uv in _disc:
			var c := _cell_of(at[0] + frame[0] * uv.x + frame[1] * uv.y)
			if _in_box(c):
				sum += _field.mass_at(c.x, c.y, c.z)
		behind.append("%.0f m: %.0f%%" % [back, 100.0 * sum / float(_disc.size())])
	print("SHIELD: bore fill behind the shield — %s" % " | ".join(behind))
	print(
		"SHIELD: per tick cut %.2f / sim %.2f / mesh %.2f ms, worst %.2f ms; %d + %d chunks"
		% [
			_prof_cut_ms, _prof_sim_ms, _prof_mesh_ms, _prof_worst_ms,
			_sand_chunks.size(), _rock_chunks.size(),
		]
	)
	if faults.is_empty():
		print("SHIELD: OK")
		get_tree().quit(0)
	else:
		print("SHIELD: FAIL - %s" % ", ".join(faults))
		get_tree().quit(1)
