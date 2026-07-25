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
## The view is a section, and that is not decoration either. Driving a shield is
## driving something you cannot see out of: the chase camera in the tube shows a
## wall of sand and nothing else — not the trajectory, not the depth, not where
## the ground changes. The default view is an orthographic section cut through
## the machine's own axis, with a drawn lid on the plane of the cut, the track
## behind, the arc ahead and the arcs the minimum radius allows, a plan inset of
## the whole trace, and a ground column beside it. Chase and free are still on
## `C`; nothing in them changed.
##
## Debug stand: raw physical keys, no project input actions.
##
## Headless self-check:
##   godot --headless res://scenes/shield_drive.tscn -- --ticks=400
##
## Also: `--view=chase|free` starts in the old views (and measures what the
## section costs), `--ring-solid=N` walks the un-pinning path, `--dive` makes
## the autopilot climb and dive so the cut plane has to follow, and
## `--shot=<abs path>.png` saves the last frame — the only way to check a view
## without sitting at it.

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

## How many cap chunks are rebuilt per mesh flush. The cap is the lid drawn on
## the plane of the cut; it is rebuilt in the same chunks and on the same clock
## as the surface, so what the lid says and what the mesh shows can never be a
## frame apart in different places.
const CAP_CHUNKS_PER_FLUSH := 10
## How far the cut may sit from where it wants to be before it is moved, in
## cells. Moving it rebuilds the whole lid, and a plane that chases the machine
## cell by cell would rebuild it several times a second for no gain.
const CUT_HYSTERESIS_CELLS := 2

## The lid's palette. Warm for sand, cool for rock, so the one boundary the
## drive is about is a change of hue and not only of brightness — a shading
## gradient can be mistaken for light, a hue step cannot.
const CAP_LINING := Color(0.92, 0.88, 0.80)
## Rock standing in the plane, shaded by how much more of it is stacked above:
## the buried hill drawn as a contour map, so its shape is legible before the
## face reaches it.
const CAP_ROCK_THIN := Color(0.46, 0.53, 0.64)
const CAP_ROCK_DEEP := Color(0.17, 0.21, 0.29)
## Sand in the plane, shaded by how far under it the rock starts. Same rule in
## both ramps — darker is more rock — so the two read as one map.
const CAP_SAND_NEAR := Color(0.40, 0.35, 0.27)
const CAP_SAND_FAR := Color(0.86, 0.78, 0.60)

## Overlay colours: where you have been, where you are going, and the two arcs
## you could not go outside of even at full lock. The shadows are dark rather
## than pale because they are drawn on a lid the colour of dry sand.
const TRAIL_COLOUR := Color(0.98, 0.72, 0.28)
const TRAIL_SHADOW := Color(0.42, 0.26, 0.03, 0.70)
const COURSE_COLOUR := Color(0.45, 0.92, 1.0)
const COURSE_SHADOW := Color(0.07, 0.30, 0.42, 0.70)
const ENVELOPE_COLOUR := Color(0.35, 0.62, 0.78, 0.55)
const PLUMB_COLOUR := Color(1.0, 1.0, 1.0, 0.55)

enum View { ISO, CHASE, FREE }

## The surface shader, and the whole of the depth cut.
##
## World height without `MODEL_MATRIX` and without anything derived from the
## camera: the chunk instances carry a pure scale by the cell size and no
## translation at all (see `_mesh_chunk`), so a vertex's own Y — the mesher
## emits vertices in cell units — is the world height over the cell size. This
## build's camera-relative world transforms make `CAMERA_POSITION_WORLD` and
## everything like it unreliable; none of that is touched here.
const SECTION_SHADER_CODE := """
shader_type spatial;
render_mode cull_back;

uniform float cell_size = 0.5;
uniform float cut_y = 1.0e9;
uniform vec4 albedo : source_color = vec4(0.6, 0.5, 0.4, 1.0);
uniform float rough : hint_range(0.0, 1.0) = 1.0;

varying float world_y;

void vertex() {
	world_y = VERTEX.y * cell_size;
}

void fragment() {
	if (world_y > cut_y) {
		discard;
	}
	ALBEDO = albedo.rgb;
	ROUGHNESS = rough;
	METALLIC = 0.0;
}
"""

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

@export_group("Section")
## Where the cut plane sits relative to the machine's own axis. Low enough to
## slice the bore open is the whole reason the tunnel reads as a trench from
## above rather than as a buried pipe. Raise it and the tunnel roofs over; drop
## it and the trench narrows. The mouse wheel drives this at run time.
@export var cut_above_axis_m := 0.5
## What one notch of the wheel is worth.
@export var cut_step_m := 0.5
## Depth over which buried rock still tints the lid. Ten metres because the
## bore is six across: rock that close is rock the driver has to decide about.
@export var cap_probe_m := 10.0
## Number of tint steps between "rock right under the plane" and "no rock in
## reach". Steps rather than a gradient on purpose — hard edges read as contour
## lines on a map, a smooth ramp reads as lighting.
@export var cap_bands := 5

@export_group("Camera")
## Which view comes up first. The isometric section is the one the drive is
## meant to be read from; the other two are kept for debugging.
@export var start_view: View = View.ISO
## The isometric view: where it stands, how far it can see across, and how fast
## it closes on the machine.
@export var iso_pitch_deg := -35.0
@export var iso_yaw_deg := 45.0
@export var iso_size_m := 38.0
@export var iso_zoom_min_m := 16.0
@export var iso_zoom_max_m := 140.0
@export var iso_distance_m := 260.0
@export var iso_follow_rate := 6.0
## How far ahead the projected course is drawn. Sixty metres is a little over
## three times the minimum turning radius, which is the span over which a
## steering decision actually shows.
@export var course_preview_m := 60.0
## Widths of the drawn ribbons, metres.
@export var trail_width_m := 0.9
@export var course_width_m := 0.5
## The plan inset: on by default, and its size in pixels. The aspect is the
## trace's own, so the whole box fits with nothing cropped.
@export var plan_inset := true
@export var plan_inset_px := Vector2i(400, 160)
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

var _section_shader: Shader
var _clipped: Array[ShaderMaterial] = []
var _cap_view: Node3D
var _cap_chunks: Dictionary = {}
var _cap_pending: Dictionary = {}
var _cap_material: StandardMaterial3D
## Highest cell holding rock in each column, or -1. Seeded from the geology and
## kept honest by the cutter, so the lid's tint is the rock that is there now
## and not the rock the trace was built with.
var _rock_top := PackedInt32Array()
var _cut_cell := -9999
var _cut_y := 1.0e9

var _machine: Node3D
var _chase: Camera3D
var _fly: Camera3D
var _iso: Camera3D
var _iso_target := Vector3.ZERO
var _iso_yaw := 45.0
var _sun: DirectionalLight3D
var _overlay: MeshInstance3D
var _overlay_mesh: ImmediateMesh
var _overlay_material: StandardMaterial3D
var _plan_viewport: SubViewport
var _plan_camera: Camera3D
var _plan_frame: Control
var _ruler: Control
var _environment: Environment
var _view := View.ISO
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
var _autopilot_ticks := 0
var _autopilot_dives := false
var _shot_path := ""
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
		elif arg == "--view=chase":
			# The old view, for measuring what the section costs and for proving
			# it still works.
			start_view = View.CHASE
		elif arg == "--view=free":
			start_view = View.FREE
		elif arg == "--dive":
			# The cut plane rides the machine, and a machine that never leaves
			# its own axis never moves it. This is the only way the headless
			# check walks that path.
			_autopilot_dives = true
		elif arg.begins_with("--shot="):
			# The whole point of this scene is what it looks like, and the
			# autopilot's verdict cannot see. One frame to a PNG at the end of
			# the run, so a change to the section can be checked without a
			# person having to sit down at it.
			_shot_path = arg.substr(7)
	var started := Time.get_ticks_usec()
	_build_shapes()
	_build_fields()
	_build_views()
	_build_machine()
	_build_overlay()
	_build_hud()
	_pos = Vector3(start_x_m, bore_axis_y_m, float(BOX.z) * CELL * 0.5)
	_push_trail()
	# A launch chamber: the shield does not start buried, or the chase camera
	# opens on the inside of a sand dune.
	var launch := maxf(shield_length_m, camera_back_m) + 6.0
	_bore_out(launch)
	_stamp_shell(-SHELL_LEAD_M, launch)
	_remesh_all()
	_iso_target = _pos
	_iso_yaw = iso_yaw_deg
	var world := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world != null:
		_environment = world.environment
	_set_view(start_view)
	_update_camera(1.0)
	_update_overlay()
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
	_rock_top.resize(BOX.x * BOX.z)

	var cell_volume := _field.cell_volume_m3()
	var sand_top_cell := int(floor(sand_top_m / CELL))
	for x in BOX.x:
		var x_m := (float(x) + 0.5) * CELL
		for z in BOX.z:
			var z_m := (float(z) + 0.5) * CELL
			var rock_cells := int(round(_rock_top_m(x_m, z_m) / CELL))
			rock_cells = clampi(rock_cells, 0, BOX.y)
			_rock_top[z * BOX.x + x] = rock_cells - 1
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
	_section_shader = Shader.new()
	_section_shader.code = SECTION_SHADER_CODE
	_sand_material = _make_section_material(Color(0.60, 0.52, 0.39), 1.0)
	_rock_material = _make_section_material(Color(0.30, 0.31, 0.34), 0.85)
	_sand_view = Node3D.new()
	_sand_view.name = "SandSurface"
	add_child(_sand_view)
	_rock_view = Node3D.new()
	_rock_view.name = "RockSurface"
	add_child(_rock_view)
	# The lid. Unshaded on purpose: the cut face is a diagram, not a surface,
	# and a diagram that changes colour when a lamp swings past it stops being
	# readable. Everything below the cut is lit and shaded, so the flat lid also
	# separates "ground I am looking through" from "ground I am looking at".
	_cap_material = StandardMaterial3D.new()
	_cap_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cap_material.vertex_color_use_as_albedo = true
	_cap_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cap_view = Node3D.new()
	_cap_view.name = "SectionCap"
	add_child(_cap_view)


func _make_section_material(albedo: Color, roughness: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _section_shader
	material.set_shader_parameter("cell_size", CELL)
	material.set_shader_parameter("cut_y", 1.0e9)
	material.set_shader_parameter("albedo", albedo)
	material.set_shader_parameter("rough", roughness)
	_clipped.append(material)
	return material


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
	_fly = Camera3D.new()
	_fly.far = 600.0
	_fly.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_fly.set_script(load("res://addons/ropes/demos/fly_camera.gd"))
	add_child(_fly)
	# Orthographic, so a metre is a metre wherever it is on the screen and the
	# same turn drawn twice is the same shape twice. Standing well back with a
	# generous far plane: an ortho frustum is a box, and a box that starts at
	# the machine clips away everything between the machine and the eye.
	_iso = Camera3D.new()
	_iso.projection = Camera3D.PROJECTION_ORTHOGONAL
	_iso.size = iso_size_m
	_iso.near = 0.5
	_iso.far = iso_distance_m * 2.5
	_iso.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_iso)
	# The trench is a hole in the ground and the machine's own lamps only reach
	# the few metres around it. Off in the chase view, which is lit exactly as
	# it was before this camera existed.
	_sun = DirectionalLight3D.new()
	_sun.name = "SectionLight"
	_sun.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(28.0), 0.0)
	_sun.light_energy = 0.85
	_sun.light_color = Color(1.0, 0.97, 0.92)
	_sun.shadow_enabled = false
	add_child(_sun)
	# A fill from behind, because a trench lit from one side is a black slot:
	# the wall the camera can see is the wall the key light cannot reach.
	var fill := DirectionalLight3D.new()
	fill.name = "SectionFill"
	fill.light_energy = 0.55
	fill.light_color = Color(0.86, 0.90, 1.0)
	fill.shadow_enabled = false
	# Parented to the key so one `visible` puts both out; aimed in world terms,
	# because a rotation inherited from the key is not the direction it reads as.
	_sun.add_child(fill)
	fill.global_rotation = Vector3(deg_to_rad(-34.0), deg_to_rad(-146.0), 0.0)
	_build_plan_view()


## A second ortho camera looking straight down on the whole trace, rendered into
## a corner inset. The isometric view answers "what is around me"; nothing in it
## answers "where am I on the run", which is the question a drive with an
## eighteen-metre turning radius is actually made of.
func _build_plan_view() -> void:
	_plan_viewport = SubViewport.new()
	_plan_viewport.size = plan_inset_px
	_plan_viewport.transparent_bg = false
	# No `own_world_3d`: the inset draws this same world, so the lid, the trail
	# and the projected course cannot disagree between the two views.
	_plan_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_plan_viewport)
	_plan_camera = Camera3D.new()
	_plan_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# Height first: the inset's aspect is the trace's, so fixing the cross-trace
	# extent fits the length as well.
	_plan_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_plan_camera.size = float(BOX.z) * CELL * 1.04
	_plan_camera.near = 1.0
	_plan_camera.far = 400.0
	_plan_camera.position = Vector3(
		float(BOX.x) * CELL * 0.5, 200.0, float(BOX.z) * CELL * 0.5
	)
	_plan_camera.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	_plan_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_plan_viewport.add_child(_plan_camera)


## Where the machine has been and where it is going, as flat ribbons laid in the
## world. Drawn with the depth test off: the whole point of them is to be read
## through ground the camera cannot see into, and a course line that disappears
## the moment it enters the sand is a course line for nothing.
func _build_overlay() -> void:
	_overlay_material = StandardMaterial3D.new()
	_overlay_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay_material.vertex_color_use_as_albedo = true
	_overlay_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_overlay_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_overlay_material.no_depth_test = true
	_overlay_material.render_priority = 2
	_overlay_mesh = ImmediateMesh.new()
	_overlay = MeshInstance3D.new()
	_overlay.name = "Overlay"
	_overlay.mesh = _overlay_mesh
	# Ribbons are rebuilt around the machine every frame, so the engine's own
	# culling box goes stale a frame at a time; ortho or not, a stale box is a
	# vanishing overlay.
	_overlay.custom_aabb = AABB(Vector3.ZERO, Vector3(BOX) * CELL)
	_overlay.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_overlay)


## White text on a lid the colour of dry sand is white text on white. An outline
## costs nothing and the readout stops depending on where the machine happens to
## be standing.
static func _outline(label: Label) -> void:
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("outline_size", 5)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_legend = Label.new()
	_outline(_legend)
	_legend.position = Vector2(16.0, 12.0)
	_legend.text = "\n".join([
		"W / S — thrust      A / D — course      Q / E — pitch",
		"wheel — cut depth      [ / ] — zoom      Z / X — turn the view      V — plan inset",
		"C — view: section / chase / free (free: hold RMB + WASD)      R — restart",
	])
	layer.add_child(_legend)
	_status = Label.new()
	_outline(_status)
	_status.position = Vector2(16.0, 86.0)
	layer.add_child(_status)

	_plan_frame = Control.new()
	_plan_frame.position = Vector2(16.0, 236.0)
	_plan_frame.size = Vector2(plan_inset_px) + Vector2(4.0, 4.0)
	_plan_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_plan_frame)
	var backing := ColorRect.new()
	backing.color = Color(0.06, 0.06, 0.08, 0.9)
	backing.size = _plan_frame.size
	backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plan_frame.add_child(backing)
	var plan_image := TextureRect.new()
	plan_image.texture = _plan_viewport.get_texture()
	plan_image.position = Vector2(2.0, 2.0)
	plan_image.size = Vector2(plan_inset_px)
	plan_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plan_frame.add_child(plan_image)
	var plan_label := Label.new()
	_outline(plan_label)
	plan_label.text = "plan — the whole trace"
	plan_label.position = Vector2(4.0, -20.0)
	_plan_frame.add_child(plan_label)

	# The ruler is a section of its own: the column of ground the machine is
	# standing in, and the same column twenty metres ahead. Two columns rather
	# than one because the question underground is never "what am I in" but
	# "what am I about to be in".
	_ruler = Control.new()
	_ruler.anchor_left = 1.0
	_ruler.anchor_right = 1.0
	_ruler.offset_left = -176.0
	_ruler.offset_right = -16.0
	_ruler.offset_top = 16.0
	_ruler.offset_bottom = 372.0
	_ruler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ruler.draw.connect(_draw_ruler)
	layer.add_child(_ruler)


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
	_update_cut(false)
	_flush_debt += MESH_FLUSH_HZ * delta
	if _flush_debt >= 1.0:
		_flush_debt -= 1.0
		_flush(_field, _sand_view, _sand_chunks, _sand_pending, _sand_material)
		_flush(_rock, _rock_view, _rock_chunks, _rock_pending, _rock_material)
		_flush_cap()
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
		_elevator = sin(float(_tick) / 140.0) if _autopilot_dives else 0.0
		return
	if _view == View.FREE:
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
				_lower_rock_top(c)
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
				_lower_rock_top(c)
			else:
				_field.take(c.x, c.y, c.z)
		depth += CELL * 0.5


## Keep the rock-top map true after the cutter has been through a column. Only a
## cell that *was* the top can move the top, so this costs nothing on the
## thousands of cells a bore through rock takes out from underneath it.
func _lower_rock_top(c: Vector3i) -> void:
	var column := c.z * BOX.x + c.x
	if _rock_top[column] != c.y:
		return
	var top := c.y - 1
	while top >= 0 and _rock.mass_at(c.x, top, c.z) <= 0.5:
		top -= 1
	_rock_top[column] = top


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
	@warning_ignore("integer_division")
	var cut_chunk_y := _cut_cell / FLUSH_CHUNK
	var k := 0
	while k < chunks.size():
		var chunk := Vector3i(chunks[k], chunks[k + 1], chunks[k + 2])
		pending[chunk] = true
		# The lid is derived from the same cells the mesher just heard about, so
		# it is marked from the same report. A lid drawn from a stale read is a
		# picture of a tunnel that is not there.
		#
		# Against the record's own box of moved cells, not against the chunk: a
		# chunk is eight metres tall and the plane is one cell thick, and
		# rebuilding the lid for every collapse anywhere in that band cost more
		# than the whole of the rest of the section.
		if (
			chunk.y == cut_chunk_y
			and chunks[k + 4] <= _cut_cell and chunks[k + 7] >= _cut_cell
		):
			_cap_pending[Vector2i(chunk.x, chunk.z)] = true
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
		# Vertices come out in cell units, so the scale is the whole transform —
		# no rotation and no translation. The section shader depends on that: it
		# reads world height straight off the vertex.
		instance.scale = Vector3.ONE * CELL
		instance.visible = _chunk_below_cut(chunk)
		view.add_child(instance)
		meshes[chunk] = instance
	var mesh := instance.mesh as ArrayMesh
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


# --- the depth cut -----------------------------------------------------------
#
# Three things have to agree or the section lies, and a lying section is worse
# than no section at all:
#
#   * the surface, which stops at the plane because the shader throws away every
#     fragment above it — nothing is drawn above the cut by any route;
#   * the lid, which is built from the cells *in* the plane and so is a reading
#     of the field rather than a decoration on it;
#   * the machine, which is never above the plane, because the plane is placed
#     off the machine's own axis and follows it.
#
# The simulation above the cut is untouched and keeps running. That is not a
# discrepancy: the material up there is really there, it is simply not drawn,
# and the moment any of it falls into the bore it is below the plane and drawn.


func _chunk_below_cut(chunk: Vector3i) -> bool:
	if _view != View.ISO:
		return true
	return float(chunk.y * FLUSH_CHUNK) * CELL < _cut_y


## Where the plane wants to be: off the machine's axis, snapped to a cell so the
## lid is a layer of cells and not a slab sawn through the middle of one.
func _wanted_cut_cell() -> int:
	return clampi(int(floor((_pos.y + cut_above_axis_m) / CELL)), 0, BOX.y - 1)


func _update_cut(force: bool) -> void:
	var wanted := _wanted_cut_cell()
	if not force and absi(wanted - _cut_cell) < CUT_HYSTERESIS_CELLS:
		return
	_cut_cell = wanted
	# The lid sits on the top face of the layer it draws, a centimetre clear of
	# it so the two never fight for the same depth.
	_cut_y = float(_cut_cell + 1) * CELL
	_cap_view.position = Vector3(0.0, _cut_y + 0.01, 0.0)
	var plane := _cut_y if _view == View.ISO else 1.0e9
	for material in _clipped:
		material.set_shader_parameter("cut_y", plane)
	_apply_chunk_visibility()
	_cap_pending.clear()
	for cx in range(0, BOX.x, FLUSH_CHUNK):
		for cz in range(0, BOX.z, FLUSH_CHUNK):
			@warning_ignore("integer_division")
			_cap_pending[Vector2i(cx / FLUSH_CHUNK, cz / FLUSH_CHUNK)] = true
	if force:
		_flush_cap(_cap_pending.size())


func _apply_chunk_visibility() -> void:
	for chunk: Vector3i in _sand_chunks:
		(_sand_chunks[chunk] as MeshInstance3D).visible = _chunk_below_cut(chunk)
	for chunk: Vector3i in _rock_chunks:
		(_rock_chunks[chunk] as MeshInstance3D).visible = _chunk_below_cut(chunk)
	_cap_view.visible = _view == View.ISO


func _flush_cap(budget := CAP_CHUNKS_PER_FLUSH) -> void:
	# Nothing is rebuilt while the lid is not being looked at. Every route back
	# into the section view goes through `_set_view`, which marks all of it
	# dirty again, so it can never come back stale.
	if _view != View.ISO or _cap_pending.is_empty():
		return
	var done := 0
	var drawn: Array[Vector2i] = []
	for chunk: Vector2i in _cap_pending:
		if done >= budget:
			break
		_build_cap_chunk(chunk)
		drawn.append(chunk)
		done += 1
	for chunk in drawn:
		_cap_pending.erase(chunk)


## What one cell of the plane is, as a code: -1 nothing, 0 lining, and from 2
## upwards sand and then rock, each banded by where the rock is.
##
## This is where the section stops being a hole and becomes a drawing. A plane
## cut through sand produces no geometry at all — an isosurface only exists
## where the fill crosses it, and the inside of a dune crosses nothing — so
## without the lid the driver looks straight through the ground into the
## backfaces of the bore and sees an empty black box. With it, the plane reads
## as ground: the tunnel is the gap in it, the lining is the rim of the gap, and
## rock that reaches the plane is a different colour than the sand beside it.
func _cap_code(
	sand: PackedFloat32Array,
	rock: PackedFloat32Array,
	solid: PackedByteArray,
	i: int,
	column: int
) -> int:
	var step := maxf(cap_probe_m / float(cap_bands), 0.01)
	if rock[i] > 0.5:
		# Rock in the plane, banded by how much of it stands above the plane.
		# Saturating at the bore's own radius rather than at the sand probe:
		# rock a bore-radius over the plane is already rock the machine cannot
		# climb over, and everything past that is the same news.
		var over := float(_rock_top[column] - _cut_cell) * CELL
		var over_step := maxf(bore_diameter_m * 0.5 / float(cap_bands), 0.01)
		return 2 + cap_bands + clampi(int(over / over_step), 0, cap_bands - 1)
	if solid[i] != 0:
		return 0
	if sand[i] <= RENDER_MIN_FILL:
		return -1
	# Sand at the plane, tinted by the rock underneath it. This is the layering:
	# a horizontal cut through a layer cake shows one layer, so the other layer
	# has to be reported rather than shown, and the honest way to report it is
	# how far down it starts.
	var depth := float(_cut_cell - _rock_top[column]) * CELL
	return 2 + clampi(int(depth / step), 0, cap_bands - 1)


func _cap_colour(code: int) -> Color:
	if code == 0:
		return CAP_LINING
	var span := maxf(float(cap_bands - 1), 1.0)
	if code >= 2 + cap_bands:
		return CAP_ROCK_THIN.lerp(
			CAP_ROCK_DEEP, float(code - 2 - cap_bands) / span
		)
	return CAP_SAND_NEAR.lerp(CAP_SAND_FAR, float(code - 2) / span)


func _build_cap_chunk(chunk: Vector2i) -> void:
	var x0 := chunk.x * FLUSH_CHUNK
	var z0 := chunk.y * FLUSH_CHUNK
	var w := mini(FLUSH_CHUNK, BOX.x - x0)
	var d := mini(FLUSH_CHUNK, BOX.z - z0)
	var instance: MeshInstance3D = _cap_chunks.get(chunk)
	if w <= 0 or d <= 0:
		return
	var lo := Vector3i(x0, _cut_cell, z0)
	var extent := Vector3i(w, 1, d)
	# Three reads of a one-cell-thick slab instead of a quarter of a million
	# bound calls: the cost of the lid is the reason it can be rebuilt whenever
	# the tunnel changes shape.
	var sand := _field.copy_mass_box(lo, extent)
	var rock := _rock.copy_mass_box(lo, extent)
	var solid := _field.copy_solid_box(lo, extent)
	var verts := PackedVector3Array()
	var colours := PackedColorArray()
	for iz in d:
		# Runs of one colour become one quad. With the tint in steps rather than
		# a ramp, a row of the lid is a handful of runs and not sixteen quads.
		var run_code := -1
		var run_from := 0
		for ix in range(w + 1):
			var code := -1
			if ix < w:
				code = _cap_code(
					sand, rock, solid, iz * w + ix, (z0 + iz) * BOX.x + x0 + ix
				)
			if code == run_code:
				continue
			if run_code >= 0:
				_cap_quad(
					verts, colours,
					x0 + run_from, x0 + ix, z0 + iz, _cap_colour(run_code)
				)
			run_code = code
			run_from = ix
	if verts.is_empty():
		if instance != null:
			_cap_chunks.erase(chunk)
			instance.queue_free()
		return
	if instance == null:
		instance = MeshInstance3D.new()
		instance.mesh = ArrayMesh.new()
		instance.material_override = _cap_material
		_cap_view.add_child(instance)
		_cap_chunks[chunk] = instance
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colours
	var mesh := instance.mesh as ArrayMesh
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _cap_quad(
	verts: PackedVector3Array,
	colours: PackedColorArray,
	xa: int,
	xb: int,
	z: int,
	colour: Color
) -> void:
	var x_lo := float(xa) * CELL
	var x_hi := float(xb) * CELL
	var z_lo := float(z) * CELL
	var z_hi := float(z + 1) * CELL
	# Two triangles, wound either way: the lid's material has culling off, so a
	# lid that ends up facing down is still a lid.
	verts.append(Vector3(x_lo, 0.0, z_lo))
	verts.append(Vector3(x_hi, 0.0, z_lo))
	verts.append(Vector3(x_hi, 0.0, z_hi))
	verts.append(Vector3(x_lo, 0.0, z_lo))
	verts.append(Vector3(x_hi, 0.0, z_hi))
	verts.append(Vector3(x_lo, 0.0, z_hi))
	for _k in 6:
		colours.append(colour)


# --- camera and HUD ----------------------------------------------------------


func _process(delta: float) -> void:
	if _field == null:
		return
	_update_camera(delta)
	_update_overlay()
	_update_hud()
	_ruler.queue_redraw()


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
	if _view == View.ISO:
		_update_iso_camera(delta)
		return
	if _view == View.FREE:
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


## The section view. World-aligned and turned only in eighth-turn steps by hand:
## a camera that swung with the machine's own course would hide the one thing
## the view exists to show, which is that the course is changing.
func _update_iso_camera(delta: float) -> void:
	var rate := clampf(iso_follow_rate * delta, 0.0, 1.0)
	if delta >= 1.0:
		_iso_target = _pos
	else:
		_iso_target = _iso_target.lerp(_pos, rate)
	_iso_yaw = lerpf(_iso_yaw, iso_yaw_deg, clampf(6.0 * delta, 0.0, 1.0))
	var yaw := deg_to_rad(_iso_yaw)
	var pitch := deg_to_rad(-iso_pitch_deg)
	var offset := Vector3(
		cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)
	) * iso_distance_m
	_iso.size = iso_size_m
	_iso.global_position = _iso_target + offset
	_iso.look_at(_iso_target, Vector3.UP)


# --- what the driver is actually reading -------------------------------------


## Every metre of the drive that is not the ground itself: the track behind, the
## arc ahead at the current wheel, the two arcs that bound it at full lock, and
## the mast from the machine up to daylight.
func _update_overlay() -> void:
	_overlay_mesh.clear_surfaces()
	if _view == View.CHASE:
		return
	# One point per metre. The trail is recorded four times finer than that
	# because the lining rides it; a ribbon does not need it.
	var trail := PackedVector3Array()
	var stride := maxi(1, int(round(1.0 / TRAIL_STEP_M)))
	var i := 0
	while i < _trail_pos.size():
		trail.append(_trail_pos[i])
		i += stride
	trail.append(_pos)
	_ribbon(trail, trail_width_m, TRAIL_COLOUR)
	_ribbon(_flatten(trail), trail_width_m * 0.5, TRAIL_SHADOW)

	var reach := course_preview_m
	var limit := 1.0 / maxf(min_turn_radius_m, 0.1)
	# The envelope first, so the live course draws over it.
	_ribbon(_course_points(limit, reach), course_width_m * 0.6, ENVELOPE_COLOUR)
	_ribbon(_course_points(-limit, reach), course_width_m * 0.6, ENVELOPE_COLOUR)
	var course := _course_points(_steer * limit, reach)
	_ribbon(course, course_width_m, COURSE_COLOUR)
	_ribbon(_flatten(course), course_width_m, COURSE_SHADOW)
	# Where it ends up, marked on the plane of the cut.
	var finish: Vector3 = course[course.size() - 1]
	_plumb(finish, _cut_y, COURSE_COLOUR)
	_cross(Vector3(finish.x, _cut_y, finish.z), 1.4, COURSE_COLOUR)
	# From the machine to the top of the ground, straight through the plane of
	# the cut. Under an orthographic camera the length of that mast is the one
	# thing on the screen that says how much ground is overhead — the rest of
	# the cover was clipped away to make the tunnel visible in the first place.
	_plumb(_pos, sand_top_m, PLUMB_COLOUR)
	_cross(Vector3(_pos.x, sand_top_m, _pos.z), 2.5, PLUMB_COLOUR)


## Same track, laid on the plane of the cut. Under an orthographic camera a line
## and its shadow are two parallel lines a fixed distance apart, and that
## distance is the depth — the one depth cue ortho does not destroy.
func _flatten(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(points.size())
	for i in points.size():
		out[i] = Vector3(points[i].x, _cut_y + 0.03, points[i].z)
	return out


## The path the machine takes from here if the wheel is not touched. Curvature,
## not turn rate: how sharply the course bends per metre travelled depends only
## on the wheel, which is why the drawing is the same whether the driver is at
## full thrust or stopped.
func _course_points(curvature: float, length: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var point := _pos
	var yaw := _yaw
	var steps := 40
	# Sixty metres at full lock is a hundred and ninety degrees of arc, and an
	# arc that comes back past the machine says nothing about where the machine
	# is going — it just fills the screen. Cut every arc at a hundred degrees;
	# past that the shape of the decision is already on the screen.
	if absf(curvature) > 0.0001:
		length = minf(length, 1.75 / absf(curvature))
	var span := length / float(steps)
	out.append(point)
	for _k in steps:
		yaw += curvature * span
		point += Vector3(
			cos(_pitch) * cos(yaw), sin(_pitch), cos(_pitch) * sin(yaw)
		) * span
		out.append(point)
	return out


func _ribbon(points: PackedVector3Array, width: float, colour: Color) -> void:
	if points.size() < 2:
		return
	_overlay_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _overlay_material)
	_overlay_mesh.surface_set_color(colour)
	var half := width * 0.5
	for i in points.size():
		var direction: Vector3
		if i == 0:
			direction = points[1] - points[0]
		elif i == points.size() - 1:
			direction = points[i] - points[i - 1]
		else:
			direction = points[i + 1] - points[i - 1]
		direction.y = 0.0
		if direction.length_squared() < 1e-8:
			direction = Vector3.RIGHT
		var side := direction.normalized().cross(Vector3.UP) * half
		_overlay_mesh.surface_add_vertex(points[i] - side)
		_overlay_mesh.surface_add_vertex(points[i] + side)
	_overlay_mesh.surface_end()


## A vertical mast from a point up to a height, as two crossed blades so it is
## there from any of the eight view angles.
func _plumb(at: Vector3, top_y: float, colour: Color) -> void:
	var top := maxf(top_y, at.y + 0.5)
	for axis: Vector3 in [Vector3.RIGHT * 0.12, Vector3.FORWARD * 0.12]:
		_overlay_mesh.surface_begin(
			Mesh.PRIMITIVE_TRIANGLE_STRIP, _overlay_material
		)
		_overlay_mesh.surface_set_color(colour)
		_overlay_mesh.surface_add_vertex(at - axis)
		_overlay_mesh.surface_add_vertex(at + axis)
		_overlay_mesh.surface_add_vertex(Vector3(at.x, top, at.z) - axis)
		_overlay_mesh.surface_add_vertex(Vector3(at.x, top, at.z) + axis)
		_overlay_mesh.surface_end()


## A flat cross at a point, so the top of a mast is a place and not a line that
## happens to stop.
func _cross(at: Vector3, size: float, colour: Color) -> void:
	for across: bool in [true, false]:
		var long := (Vector3.RIGHT if across else Vector3.FORWARD) * size * 0.5
		var wide := (Vector3.FORWARD if across else Vector3.RIGHT) * 0.09
		_overlay_mesh.surface_begin(
			Mesh.PRIMITIVE_TRIANGLE_STRIP, _overlay_material
		)
		_overlay_mesh.surface_set_color(colour)
		_overlay_mesh.surface_add_vertex(at - long - wide)
		_overlay_mesh.surface_add_vertex(at - long + wide)
		_overlay_mesh.surface_add_vertex(at + long - wide)
		_overlay_mesh.surface_add_vertex(at + long + wide)
		_overlay_mesh.surface_end()


## Top of the rock in a column, in metres, read from the map the cutter keeps.
func _rock_surface_m(x_m: float, z_m: float) -> float:
	var x := clampi(int(floor(x_m / CELL)), 0, BOX.x - 1)
	var z := clampi(int(floor(z_m / CELL)), 0, BOX.z - 1)
	return float(_rock_top[z * BOX.x + x] + 1) * CELL


## Two ground columns, drawn to scale: where the machine is standing and what it
## will be standing in twenty metres from now. The one number a tunnel driver
## never has — how much ground is over the crown — is on it, and so is the
## boundary the whole trace is about.
func _draw_ruler() -> void:
	_ruler.draw_rect(Rect2(Vector2.ZERO, _ruler.size), Color(0.05, 0.05, 0.07, 0.82))
	var font := _ruler.get_theme_default_font()
	var font_size := 12
	var box := _ruler.size
	var top := 22.0
	var height := box.y - top - 18.0
	var world_top := sand_top_m + 2.0
	var radius := bore_diameter_m * 0.5
	var ahead := _pos + _forward() * 20.0
	var columns := [
		["here", _pos.x, _pos.z, 8.0],
		["+20 m", ahead.x, ahead.z, 84.0],
	]
	for entry in columns:
		var label: String = entry[0]
		var rock_m := _rock_surface_m(entry[1], entry[2])
		var left: float = entry[3]
		var width := 60.0
		var sand_px := top + height * (1.0 - clampf(sand_top_m / world_top, 0.0, 1.0))
		var rock_px := top + height * (1.0 - clampf(rock_m / world_top, 0.0, 1.0))
		var base_px := top + height
		_ruler.draw_rect(
			Rect2(left, sand_px, width, base_px - sand_px), CAP_SAND_FAR
		)
		_ruler.draw_rect(
			Rect2(left, rock_px, width, base_px - rock_px), CAP_ROCK_DEEP
		)
		_ruler.draw_string(
			font, Vector2(left, top - 8.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.85, 0.85, 0.9)
		)
		# The bore, to scale, at the machine's own axis: the gap between the top
		# of that box and the rock band is the cover, and it is a length on the
		# screen rather than a number to be trusted.
		var axis_y := _pos.y if label == "here" else ahead.y
		var crown_px := top + height * (
			1.0 - clampf((axis_y + radius) / world_top, 0.0, 1.0)
		)
		var invert_px := top + height * (
			1.0 - clampf((axis_y - radius) / world_top, 0.0, 1.0)
		)
		_ruler.draw_rect(
			Rect2(left + 14.0, crown_px, 32.0, invert_px - crown_px),
			Color(0.08, 0.09, 0.11)
		)
		if label == "here":
			_ruler.draw_rect(
				Rect2(left + 14.0, crown_px, 32.0, invert_px - crown_px),
				Color(0.95, 0.78, 0.35), false, 2.0
			)
	var surface_px := top + height * (1.0 - clampf(sand_top_m / world_top, 0.0, 1.0))
	_ruler.draw_line(
		Vector2(0.0, surface_px), Vector2(box.x, surface_px),
		Color(0.95, 0.95, 1.0, 0.8), 1.0
	)
	_ruler.draw_string(
		font, Vector2(0.0, surface_px - 4.0), "surface",
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.95, 0.95, 1.0, 0.8)
	)
	var cut_px := top + height * (1.0 - clampf(_cut_y / world_top, 0.0, 1.0))
	_ruler.draw_line(
		Vector2(0.0, cut_px), Vector2(box.x, cut_px),
		Color(0.45, 0.92, 1.0, 0.7), 1.0
	)
	_ruler.draw_string(
		font, Vector2(0.0, cut_px - 4.0), "cut",
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.45, 0.92, 1.0, 0.8)
	)
	_ruler.draw_string(
		font, Vector2(0.0, box.y - 4.0),
		"%.1f m deep   cover %.1f m" % [
			sand_top_m - _pos.y,
			maxf(sand_top_m - (_pos.y + radius), 0.0),
		],
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.85, 0.85, 0.9)
	)


# --- views -------------------------------------------------------------------


func _set_view(view: View) -> void:
	if view == View.FREE:
		# Picked up where the last view was standing, or the free camera opens
		# on whatever it happened to be pointing at last time.
		_fly.global_transform = (
			_iso.global_transform if _view == View.ISO else _chase.global_transform
		)
	_view = view
	_iso.current = view == View.ISO
	_chase.current = view == View.CHASE
	_fly.current = view == View.FREE
	# The fly camera answers the wheel and the right button whether or not it is
	# the one being looked through; while it is not, it must not.
	_fly.set_process_unhandled_input(view == View.FREE)
	if view != View.FREE and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_sun.visible = view != View.CHASE
	if _environment != null:
		# The chase view is left exactly as dark as it was: it is a view from
		# inside a tube lit by the machine's own lamps, and that is the point of
		# it. The section is a drawing and has to be legible.
		_environment.ambient_light_energy = 0.12 if view == View.CHASE else 0.62
	_overlay.visible = view != View.CHASE
	_plan_frame.visible = view == View.ISO and plan_inset
	_plan_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if _plan_frame.visible
		else SubViewport.UPDATE_DISABLED
	)
	_update_cut(true)


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
		"%.1f m below surface   %.1f m of ground over the crown   rock %s" % [
			sand_top_m - _pos.y,
			maxf(sand_top_m - (_pos.y + bore_diameter_m * 0.5), 0.0),
			_rock_note(),
		],
		"%d fps   cut %.2f / sim %.2f / mesh %.2f ms" % [
			Engine.get_frames_per_second(),
			_prof_cut_ms, _prof_sim_ms, _prof_mesh_ms,
		],
	])


## Where the rock is relative to the machine, in the one direction that matters:
## a boundary above the axis is a boundary the machine has to dive under or bore
## through, and one below it is a floor.
func _rock_note() -> String:
	var here := _rock_surface_m(_pos.x, _pos.z) - _pos.y
	var ahead := _pos + _forward() * 20.0
	var there := _rock_surface_m(ahead.x, ahead.z) - _pos.y
	return "%+.1f m here, %+.1f m in 20 m" % [here, there]


func _unhandled_input(event: InputEvent) -> void:
	if _autopilot_ticks > 0:
		# A self-check drives itself. A stray scroll over the window while one
		# is running would move the cut and the run would report on a view
		# nobody asked for.
		return
	if event is InputEventMouseButton and _view == View.ISO:
		var button := event as InputEventMouseButton
		if not button.pressed:
			return
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_nudge_cut(cut_step_m)
			MOUSE_BUTTON_WHEEL_DOWN:
				_nudge_cut(-cut_step_m)
			_:
				return
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_C:
			if _view == View.ISO:
				_set_view(View.CHASE)
			elif _view == View.CHASE:
				_set_view(View.FREE)
			else:
				_set_view(View.ISO)
		KEY_V:
			plan_inset = not plan_inset
			_plan_frame.visible = _view == View.ISO and plan_inset
			_plan_viewport.render_target_update_mode = (
				SubViewport.UPDATE_ALWAYS if _plan_frame.visible
				else SubViewport.UPDATE_DISABLED
			)
		KEY_Z:
			iso_yaw_deg -= 45.0
		KEY_X:
			iso_yaw_deg += 45.0
		KEY_BRACKETLEFT:
			iso_size_m = clampf(iso_size_m * 1.25, iso_zoom_min_m, iso_zoom_max_m)
		KEY_BRACKETRIGHT:
			iso_size_m = clampf(iso_size_m / 1.25, iso_zoom_min_m, iso_zoom_max_m)
		KEY_R:
			get_tree().reload_current_scene()


## The wheel moves the plane relative to the machine, never in the world. Tied
## to the machine it cannot be left behind on a dive, and it cannot be driven
## down past the invert and leave the driver looking at a lid with their own
## shield sitting on top of it.
func _nudge_cut(by: float) -> void:
	cut_above_axis_m = clampf(cut_above_axis_m + by, -2.0, 12.0)
	_update_cut(true)


# --- headless self-check -----------------------------------------------------


func _finish_autopilot() -> void:
	_autopilot_ticks = 0
	var nominal := PI * pow(bore_diameter_m * 0.5, 2.0) * _travelled
	# Against the ground the run actually crossed. Measured against the sand
	# rate, any run long enough to spend its second half in rock — which is the
	# whole point of the trace — fails for driving correctly: at 1800 ticks the
	# machine is asked for 24 m and rock only allows about 14.
	var floor_speed := (
		speed_rock_m_s if _seen_grounds.has("rock") else speed_sand_m_s
	)
	var expected := floor_speed * float(_tick) / 60.0 * 0.5
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
	# The lid is the section. Without it the depth cut is a hole in the picture
	# and the driver is worse off than with no cut at all, so an empty lid is a
	# failure and not a cosmetic remark.
	if _view == View.ISO and _cap_chunks.is_empty():
		faults.append("section lid missing")
	# The plane has to be where the knob says it is, within the slack the
	# hysteresis is allowed, and it may never sink below the invert — a plane
	# under the machine draws the machine standing on top of the ground.
	var wanted_cut := _pos.y + cut_above_axis_m
	if absf(_cut_y - wanted_cut) > CELL * float(CUT_HYSTERESIS_CELLS + 1):
		faults.append(
			"cut plane %.1f m drifted from the %.1f m it was asked for"
			% [_cut_y, wanted_cut]
		)
	if _cut_y < _pos.y - bore_diameter_m * 0.5:
		faults.append(
			"cut plane %.1f m is under the machine at %.1f m" % [_cut_y, _pos.y]
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
	# What the section is made of: how much of the plane is the open bore, how
	# much is lining, how much is rock, and where the plane ended up.
	var slab := _field.copy_mass_box(
		Vector3i(0, _cut_cell, 0), Vector3i(BOX.x, 1, BOX.z)
	)
	var rock_slab := _rock.copy_mass_box(
		Vector3i(0, _cut_cell, 0), Vector3i(BOX.x, 1, BOX.z)
	)
	var solid_slab := _field.copy_solid_box(
		Vector3i(0, _cut_cell, 0), Vector3i(BOX.x, 1, BOX.z)
	)
	var open := 0
	var rock_cells := 0
	var lining := 0
	for i in slab.size():
		if rock_slab[i] > 0.5:
			rock_cells += 1
		elif solid_slab[i] != 0:
			lining += 1
		elif slab[i] <= RENDER_MIN_FILL:
			open += 1
	print(
		"SHIELD: cut plane at %.1f m (%.1f m over the axis), lid %d chunks; in the plane — %d open, %d lining, %d rock of %d cells"
		% [
			_cut_y, _cut_y - _pos.y, _cap_chunks.size(),
			open, lining, rock_cells, slab.size(),
		]
	)
	if faults.is_empty():
		print("SHIELD: OK")
		_quit_after_shot(0)
	else:
		print("SHIELD: FAIL - %s" % ", ".join(faults))
		_quit_after_shot(1)


func _quit_after_shot(code: int) -> void:
	if _shot_path != "":
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		if image != null:
			image.save_png(_shot_path)
			print("SHIELD: view saved to %s" % _shot_path)
	get_tree().quit(code)
