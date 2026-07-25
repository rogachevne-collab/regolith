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
## behind, the arc ahead and the arcs the minimum radius allows. Chase and free
## are still on `C`; nothing in them changed.
##
## Beside it stands **one instrument with three screens** — plan, profile, ground
## column — and it is one instrument on purpose. It used to be three windows in
## three corners, and the plan among them was a second orthographic render of the
## whole world while the other two were drawings; they read as three panels
## borrowed from three different games. Every screen is drawn from the record
## now, off one clock, at one scale, in one case, and the plan's second render is
## gone with the 0.40 ms a frame it cost.
##
## What was *not* done, and should not be done later: the readings were not
## repainted. Sand warm, rock cool, worked ground rust, open bore black — that is
## the driver's only read of what he is driving in, and flooding the screens with
## one phosphor green would have bought a radar look with the whole of it. What
## makes them one instrument is the case, the bezel, the grid at one price per
## division, the type, the machine symbol, the accent, the shared metre and the
## shared refresh. `V` and `B` put one screen out, `H` puts the instrument out.
##
## The cut is **not a plane**, and that is the one thing about this view that had
## to change. A driver who dives loses everything behind: the tunnel he dug is
## under a horizontal plane that followed the machine up, and the harder he
## steers the less of his own work he can see. So the cut is a *surface* that
## rides the tunnel — a metre-resolution height map built from the recorded path
## and flared out sideways to the base level where nothing was dug. `F` puts the
## old flat plane back, because a plane is still the better read of *how deep*
## something is; it is only useless as the only mode.
##
## Ground the machine has been through is marked and drawn as its own thing, on
## the lid and in the volume. Without it the driver cannot tell the two halves of
## his own tunnel apart: at a 0.4 spoil share the bore is about three-quarters
## full of its own muck a few metres back, and muck drawn as sand is a tunnel
## that looks like it was never dug. Three states, three readings: untouched /
## dug and open / dug and buried. `T` turns the marking off.
##
## Debug stand: raw physical keys, no project input actions.
##
## Headless self-check:
##   godot --headless res://scenes/shield_drive.tscn -- --ticks=400
##
## Also: `--view=chase|free` starts in the old views (and measures what the
## section costs), `--ring-solid=N` walks the un-pinning path, `--dive` makes
## the autopilot climb and dive so the cut has to follow, `--flat-cut` runs the
## old plane instead of the surface, `--no-mark` runs it without the marking on
## worked ground, `--no-plan` / `--no-profile` / `--no-instrument` walk what `V`,
## `B` and `H` do to the case, and `--shot=<abs path>.png` saves the last frame —
## the only way
## to check a view without sitting at it.

## The project's one grid. Not a knob: step 0 decided it, and construction,
## granular material and this all share it.
const CELL := 0.5
## The trace. 120 x 24 x 48 m, which is the plan's length, enough cover over
## the bore for a collapse to read, and enough width that an 18 m turning
## circle fits without hitting the side of the world.
const BOX := Vector3i(240, 48, 96)

## Mesh chunk edge, in cells — the same unit the view in the game uses, so what
## is timed here is what the game pays. A power of two so a cell can be put in
## its chunk with a shift, which the lid does per column.
const CHUNK_SHIFT := 4
const FLUSH_CHUNK := 1 << CHUNK_SHIFT
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

## How many cap chunks are rebuilt per mesh flush. The cap is the lid drawn at
## the cut; it is rebuilt in the same chunks and on the same clock as the
## surface, so what the lid says and what the mesh shows can never be a frame
## apart in different places. Five and not ten: a lid chunk is a small terrain
## now that the cut is a surface, and ten of them in one tick is a hitch you can
## see. There are ninety in the whole trace, so the worst case is still under a
## second to redraw all of it.
const CAP_CHUNKS_PER_FLUSH := 5
## How far the cut may sit from where it wants to be before it is moved, in
## cells. Moving it rebuilds the whole lid, and a plane that chases the machine
## cell by cell would rebuild it several times a second for no gain. Flat mode
## only: the following surface moves a metre of map at a time by construction.
const CUT_HYSTERESIS_CELLS := 2

## The cut map: one texel per two cells, so a metre. Not per cell, and the
## reason is the cost of laying the flare down — the disc written on every step
## is quadratic in the resolution, and a metre is already finer than the half
## metre the cut quantises to along a dive.
const CUT_MAP_SHIFT := 1
const CUT_MAP_STEP := 1 << CUT_MAP_SHIFT
const CUT_MAP_CELL := CELL * float(CUT_MAP_STEP)
const CUT_MAP := Vector2i(BOX.x, BOX.z) / CUT_MAP_STEP
## Map texels to one lid chunk, so a changed texel marks exactly one chunk.
const CAP_MAP_SHIFT := 3
## How far the machine goes between writes of the flare. Half a metre rather
## than every trail point: the corridor is metres wide, so nothing is missed,
## and the write is the one part of this that is not free.
const CUT_MAP_STEP_M := 0.5

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
## Ground the machine has been through and its own muck has filled again, shaded
## by how full the cell is. A hue of its own — neither the tans of the untouched
## sand nor the blue-greys of the rock — because this is the one thing on the lid
## that is not geology but the driver's own doing, and it has to be told apart
## from ground nobody has touched at a glance and not by shade.
const CAP_SPOIL_THIN := Color(0.30, 0.15, 0.10)
const CAP_SPOIL_FULL := Color(0.78, 0.36, 0.16)
## The same, in the volume: everything inside the envelope the machine dug is
## tinted towards this, so the muck heap and the bore walls in the trench read as
## worked ground and not as the dune they are drawn out of.
const DUG_TINT := Color(0.86, 0.42, 0.18)
const DUG_TINT_MIX := 0.42

## Overlay colours: where you have been, where you are going, and the two arcs
## you could not go outside of even at full lock. The shadows are dark rather
## than pale because they are drawn on a lid the colour of dry sand.
const TRAIL_COLOUR := Color(0.98, 0.72, 0.28)
const TRAIL_SHADOW := Color(0.42, 0.26, 0.03, 0.70)
const COURSE_COLOUR := Color(0.45, 0.92, 1.0)
const COURSE_SHADOW := Color(0.07, 0.30, 0.42, 0.70)
const ENVELOPE_COLOUR := Color(0.35, 0.62, 0.78, 0.55)
const PLUMB_COLOUR := Color(1.0, 1.0, 1.0, 0.55)

## The instrument's own palette — the case, not the readings.
##
## The two screens used to be two windows out of two different games: one was a
## second render of the world, warm and lit, and the other was a drawing on a
## dark ground. The obvious fix is to flood both with one colour and call it a
## radar. That is the wrong fix and it was not taken: sand is warm, rock is cool,
## worked ground is rust and open bore is black *because those mean something*,
## and the driver reads the ground by hue before he reads anything else.
##
## So nothing below is ever mixed into a reading. What makes the two screens one
## instrument is everything around the readings — one case, one bezel, one grid
## at one price per division, one typeface at three sizes, one machine symbol,
## one accent for "you are here" and for where the course goes, and one refresh
## clock that both screens are visibly swept by.
const HUD_CASE := Color(0.055, 0.062, 0.078, 0.94)
const HUD_CASE_EDGE := Color(0.38, 0.48, 0.55, 0.80)
const HUD_SCREEN := Color(0.035, 0.042, 0.055, 0.96)
const HUD_SCREEN_EDGE := Color(0.32, 0.42, 0.50, 0.65)
## The grid has to be legible over a screen of dry sand and over a screen of dark
## rock without being two different grids, so it is a pale cool line rather than
## either a light one or a dark one: it lifts off the rock and it cools the sand,
## and the same two alphas do both.
const HUD_GRID := Color(0.58, 0.74, 0.84, 0.20)
const HUD_GRID_MAJOR := Color(0.62, 0.78, 0.88, 0.34)
const HUD_TEXT := Color(0.80, 0.88, 0.92)
const HUD_TEXT_DIM := Color(0.60, 0.70, 0.76)
## Every word on a screen is set over this, one pixel down and across. The
## screens are drawn *on* the readings and the readings run from near-black to
## near-white, so a label without a shadow is a label that disappears somewhere.
const HUD_TEXT_SHADOW := Color(0.02, 0.03, 0.04, 0.85)
## The sweep. Barely there on purpose: it is a sign that the picture is live, and
## anything strong enough to notice while reading is a fault and not a feature.
const HUD_SCAN := Color(0.45, 0.92, 1.0, 0.13)
const HUD_SCAN_LINE := Color(0.45, 0.92, 1.0, 0.030)
## Three sizes and no more. A fourth size is how a panel stops looking built.
const HUD_TITLE_PT := 13
const HUD_LABEL_PT := 11
const HUD_TICK_PT := 10

enum View { ISO, CHASE, FREE }

## The surface shader, and the whole of the depth cut.
##
## World position without `MODEL_MATRIX` and without anything derived from the
## camera: the chunk instances carry a pure scale by the cell size and no
## translation at all (see `_mesh_chunk`), so a vertex's own coordinates — the
## mesher emits vertices in cell units — are the world position over the cell
## size. This build's camera-relative world transforms make
## `CAMERA_POSITION_WORLD` and everything like it unreliable; none of that is
## touched here, and the cut map is read in world XZ for the same reason.
##
## The bilinear is written out by hand over `texelFetch` rather than left to the
## sampler, and that is not fussiness. Two reasons. The lid is built out of the
## same map on the CPU and the two have to agree to the centimetre — a lid drawn
## a hair off the height fragments are thrown away at is a hairline gap running
## the length of the trench — and writing the filter out is the only way to be
## sure both are computing the same thing. And a 32-bit float texture is not
## guaranteed to be filterable at all: `filter_linear` on it is a driver-dependent
## black screen waiting to happen.
##
## The cut *has* to be interpolated and not stepped. Quantised to the cell it
## already quantises to, the flare came out as a field of loose tiles — the slope
## is shallow, so half the trace straddled a cell boundary and dithered between
## two levels. That reads as breakage, not as a slope.
const SECTION_SHADER_CODE := """
shader_type spatial;
render_mode cull_back;

uniform float cell_size = 0.5;
uniform bool cut_on = false;
uniform bool dug_on = true;
uniform float map_cell = 1.0;
uniform vec2 map_dim = vec2(120.0, 48.0);
uniform sampler2D cut_map : filter_nearest, repeat_disable, hint_default_black;
uniform vec4 albedo : source_color = vec4(0.6, 0.5, 0.4, 1.0);
uniform vec4 dug_tint : source_color = vec4(0.86, 0.42, 0.18, 1.0);
uniform float dug_mix : hint_range(0.0, 1.0) = 0.42;
uniform float rough : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_pos;

// The cut surface, in metres, at a point on the trace. Texel centres sit half a
// map cell in from the corner of the box, which is what the lid assumes too.
float cut_at(vec2 p) {
	vec2 t = p / map_cell - vec2(0.5);
	vec2 f = fract(t);
	ivec2 last = ivec2(map_dim) - ivec2(1);
	ivec2 lo = clamp(ivec2(floor(t)), ivec2(0), last);
	ivec2 hi = clamp(ivec2(floor(t)) + ivec2(1), ivec2(0), last);
	float h00 = texelFetch(cut_map, ivec2(lo.x, lo.y), 0).r;
	float h10 = texelFetch(cut_map, ivec2(hi.x, lo.y), 0).r;
	float h01 = texelFetch(cut_map, ivec2(lo.x, hi.y), 0).r;
	float h11 = texelFetch(cut_map, ivec2(hi.x, hi.y), 0).r;
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

void vertex() {
	world_pos = VERTEX * cell_size;
}

void fragment() {
	vec3 colour = albedo.rgb;
	if (cut_on) {
		if (world_pos.y > cut_at(world_pos.xz)) {
			discard;
		}
		if (dug_on) {
			// g and b are the bottom and the top of the volume the machine has
			// taken out of this column, and an empty span where it never came.
			// Read flat, not interpolated: an envelope is a fact about one
			// column and smearing it into its neighbours would tint ground the
			// machine never touched.
			ivec2 last = ivec2(map_dim) - ivec2(1);
			ivec2 c = clamp(
				ivec2(floor(world_pos.xz / map_cell)), ivec2(0), last
			);
			vec2 span = texelFetch(cut_map, c, 0).gb;
			if (world_pos.y >= span.x && world_pos.y <= span.y) {
				colour = mix(colour, dug_tint.rgb, dug_mix);
			}
		}
	}
	ALBEDO = colour;
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
## Where the cut sits relative to the machine's own axis. Low enough to slice the
## bore open is the whole reason the tunnel reads as a trench from above rather
## than as a buried pipe. Raise it and the tunnel roofs over; drop it and the
## trench narrows. The mouse wheel drives this at run time.
@export var cut_above_axis_m := 0.5
## What one notch of the wheel is worth.
@export var cut_step_m := 0.5
## Whether the cut is a surface that rides the tunnel or the old flat plane. `F`
## at run time. Off, this is exactly the build before it: a horizontal plane at
## `cut_above_axis_m` over the machine, which is the better read of how deep
## something lies and a useless read of anything the driver already dug.
@export var cut_follows_tunnel := true
## How wide the cut stays right down on the tunnel, from the axis. Bore radius
## plus a metre: wide enough that the bore is opened along its whole length, tight
## enough that two passes have to be nearly on top of each other to fight over a
## column.
@export var cut_corridor_m := 4.0
## How far out the cut takes to climb back to where it would be with nothing dug.
## This is a sight line and not a taste: the section camera stands at 35 degrees,
## so a wall rising faster than about 0.7 m per metre hides what it stands beside.
## Fourteen metres against the seven the machine can be under the base level is a
## slope of 0.5 — the trench stays open from every one of the eight view angles.
@export var cut_flare_m := 14.0
## Whether ground the machine has been through is marked and drawn apart from
## ground nobody has touched. `T` at run time.
@export var mark_disturbed := true
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

@export_group("Instrument")
## The whole instrument: one case, three screens. `H` at run time.
##
## It used to be three separate things in three corners — a rendered plan inset,
## a drawn profile inset and a drawn ground column — and they read as three
## windows from three different games. They are one box now, and the plan is
## drawn from the recorded path and the maps like the other two rather than
## rendered by a second camera on the world.
@export var instrument := true
## The plan screen — the trace seen from above. `V` at run time.
@export var plan_screen := true
## The profile screen — the trace unrolled. `B` at run time.
##
## Unrolled and not rendered, and that is not only about cost: a camera at the
## side of a tunnel that turns draws it foreshortened, so the one view in which
## a dive is a line going down has to be a drawing.
@export var profile_screen := true
## The width of a screen, in pixels. This is the one number the whole instrument
## is scaled from: it is the trace's own length across the screen, so a metre is
## the same number of pixels in every screen and a division of the grid is the
## same width in both. Two panels drawn at two scales are two panels.
@export var screen_width_px := 600
## The ground-column screen down the right of the case. Narrow, and at its own
## magnification — which is why it says so on its face.
@export var column_width_px := 168
## Where the case sits, from the bottom left corner of the window.
@export var instrument_margin_px := Vector2i(16, 16)
## What one division of the grid is worth, metres. The same in every screen; it
## is written on the case so it never has to be guessed.
@export var grid_step_m := 10.0
## How far apart the distance ticks along the trace are, metres, and how often
## one of them is numbered. The same numbers appear in the plan, on the trail
## itself, and along the foot of the profile — which is what makes "sixty metres"
## a place both screens agree about.
@export var tick_step_m := 10.0
@export var tick_label_every := 2
## The vertical scale of the profile screen, as a multiple of the true one. One
## is a true section: a metre down is the same number of pixels as a metre along,
## and the same as a metre in the plan. Raise it if the tunnel's dive needs
## exaggerating, and know that the grid stops being square when you do.
@export var profile_v_scale := 1.0
## How often the instrument re-reads the ground. It is a drawing of a hundred
## metres of tunnel and it does not change in a frame — and the refresh is drawn
## rather than hidden, because a picture that is a tenth of a second old should
## say so.
@export var instrument_hz := 10.0
## The sweep: one pass of a faint bar across every screen at once, on the case's
## own clock. Both screens swept by the same bar at the same moment is the
## cheapest possible statement that they are one instrument.
@export var scan_sweep := true
@export var scan_period_s := 2.4
## Scan lines over the screens. Very faint — a reading that is harder to read is
## a worse instrument however good it looks.
@export var scan_lines := true

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
var _cell_volume := 0.125

## The cut map. Four floats a texel because that is the one float format every
## target samples without asking: r is the height of the cut there, g and b are
## the bottom and the top of the volume the machine has taken out of that column,
## a is spare.
var _cut_pixels := PackedFloat32Array()
## The cell layer the lid draws in each map column, derived from r.
var _cut_map_cell := PackedInt32Array()
## Which pass of the machine owns a column and how strongly, so the wheel can
## move the whole surface without the path having to be walked again.
var _cut_owner_y := PackedFloat32Array()
var _cut_owner_w := PackedFloat32Array()
## The flare, precomputed once: offsets and weights of every map column one pass
## of the machine writes.
var _cut_disc_dx := PackedInt32Array()
var _cut_disc_dz := PackedInt32Array()
var _cut_disc_w := PackedFloat32Array()
var _cut_texture: ImageTexture
var _cut_map_dirty := true
var _cut_map_done := -1.0e9
## Every cell the machine has taken, whether or not anything is standing in it
## now. A mark on the *space* and not on the material: material moves and this
## does not have to follow it, and "the bore is here and it is full again" is a
## fact about the space.
var _dug := PackedByteArray()
var _dug_cells := 0
## Per lid chunk: the top of the cut in it (what hides a mesh chunk) and the span
## of cell layers it draws (what makes it dirty).
var _cap_nx := 1
var _cap_nz := 1
var _cap_top := PackedFloat32Array()
var _cap_lo := PackedInt32Array()
var _cap_hi := PackedInt32Array()
var _cap_visible_dirty := false

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
## The instrument. One case, three screens, one clock.
var _case: Control
var _plan: Control
var _profile: Control
var _ruler: Control
## The sheet over the screens: the sweep and the refresh lamp, and nothing that
## is a reading. It is the one part of the instrument redrawn every frame.
var _glass: Control
## Metres to pixels — one number for the whole instrument, derived from the
## screen width and the length of the trace.
var _px_per_m := 5.0
## The plan's ground map, one texel per square metre: what the column is made of
## and whether the machine has been through it. Rebuilt on the instrument's clock
## and only when something in it moved, which most of the time is nothing.
var _plan_words := PackedInt32Array()
var _plan_texture: ImageTexture
var _plan_map_dirty := true
## Where the sweep bar stands, 0..1 across every screen at once.
var _scan_phase := 0.0
## Lit for one refresh period after a sample is taken, so the blip on the case
## blinks at exactly the rate the screens are being redrawn from.
var _scan_blip := 0.0
## The profile's samples, rebuilt on their own slow clock: distance along the
## trace, the axis there, the top of the rock, how full the bore is, and where
## the cut stands. The projected course carries its own two.
var _pf_dist := PackedFloat32Array()
var _pf_axis := PackedFloat32Array()
var _pf_rock := PackedFloat32Array()
var _pf_fill := PackedFloat32Array()
var _pf_cut := PackedFloat32Array()
var _pf_ahead_dist := PackedFloat32Array()
var _pf_ahead_axis := PackedFloat32Array()
var _pf_ahead_rock := PackedFloat32Array()
var _pf_span := 60.0
var _pf_mean_fill := 0.0
var _pf_due := 0.0
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
## Worst rather than smoothed: the flare is written twice a second and a smoothed
## average of a spike that lands on one tick in twenty is a number that hides it.
var _prof_map_ms := 0.0
var _prof_cap_ms := 0.0
## What the instrument costs: one rebuild of the plan's ground map and one
## resample of the profile, both on the instrument's own clock rather than the
## frame's. Worst rather than mean, for the same reason as the flare.
var _prof_plan_ms := 0.0
var _prof_pf_ms := 0.0
## And the mean of the same two, because what they cost per *frame* is what they
## cost per refresh divided by however many frames a refresh covers — and a worst
## case on its own cannot be divided by anything.
var _prof_plan_sum := 0.0
var _prof_plan_n := 0
var _prof_pf_sum := 0.0
var _prof_pf_n := 0
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
			# The cut rides the machine, and a machine that never leaves its own
			# axis never deforms it. This is the only way the headless check
			# walks that path, and it is the path the view is for.
			_autopilot_dives = true
		elif arg == "--flat-cut":
			# The old plane, for measuring what the surface costs and for proving
			# it still works.
			cut_follows_tunnel = false
		elif arg == "--no-plan":
			# The case has to close over a missing screen, and a layout that is
			# computed rather than written down is a layout only a key press
			# reaches. These three walk it.
			plan_screen = false
		elif arg == "--no-profile":
			profile_screen = false
		elif arg == "--no-instrument":
			instrument = false
		elif arg == "--no-mark":
			# The lid and the volume without the marking on worked ground, which
			# is otherwise a path only a key press reaches.
			mark_disturbed = false
		elif arg.begins_with("--shot="):
			# The whole point of this scene is what it looks like, and the
			# autopilot's verdict cannot see. One frame to a PNG at the end of
			# the run, so a change to the section can be checked without a
			# person having to sit down at it.
			_shot_path = arg.substr(7)
	var started := Time.get_ticks_usec()
	_build_shapes()
	_build_fields()
	_build_cut_map()
	_build_plan_map()
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
	# The launch chamber is dug ground like any other, so the cut has to be over
	# it from the first frame. Walked from the far end forward, because a tie in
	# the flare goes to whoever wrote it last and the machine's own column has to
	# be the last word.
	var back := launch
	while back > 0.0:
		_extend_cut_map(_pos - _forward() * back)
		back -= CUT_MAP_STEP_M
	_extend_cut_map(_pos)
	_cut_map_done = _travelled
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
	_cell_volume = cell_volume
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


# --- the cut map -------------------------------------------------------------
#
# The surface the section cuts on, as a height per square metre of the trace.
#
# The plane it replaces failed for a reason that has nothing to do with taste:
# a tunnel is not horizontal and a plane is. Sitting on the machine's own axis
# it followed the machine up on a climb, and every metre driven before the climb
# went under it — the harder the driver steered, the less of his own work he
# could see, which is the exact opposite of what a view exists for.
#
# So the cut is asked for the thing the driver actually wants: *a little above
# whatever is dug here*. Each pass of the machine writes its own height into a
# disc of columns around it, full weight over the bore and fading out over
# `cut_flare_m`; a column nobody has been near keeps the base level. What comes
# out is a trench that dives and climbs with the tunnel and opens out gently
# where nothing was dug.
#
# What it cannot do: two passes stacked within the corridor of each other are one
# column and one height, and the later pass wins. Drive directly over your own
# tunnel and the older one goes under the cut — the alternative is losing sight
# of the machine you are steering, which is worse.


func _build_cut_map() -> void:
	var count := CUT_MAP.x * CUT_MAP.y
	_cut_pixels.resize(count * 4)
	_cut_map_cell.resize(count)
	_cut_owner_y.resize(count)
	_cut_owner_w.resize(count)
	_cut_map_cell.fill(
		clampi(
			int(floor((bore_axis_y_m + cut_above_axis_m) / CELL)), 0, BOX.y - 1
		)
	)
	_cut_owner_y.fill(bore_axis_y_m)
	_cut_owner_w.fill(0.0)
	for col in count:
		_cut_pixels[col * 4] = bore_axis_y_m + cut_above_axis_m
		# An empty span: nothing is inside it, so nothing is tinted until the
		# machine has actually taken something out of the column.
		_cut_pixels[col * 4 + 1] = 1.0e9
		_cut_pixels[col * 4 + 2] = -1.0e9
		_cut_pixels[col * 4 + 3] = 1.0
	_dug.resize(BOX.x * BOX.y * BOX.z)
	_dug.fill(0)
	_cap_nx = int(ceil(float(BOX.x) / float(FLUSH_CHUNK)))
	_cap_nz = int(ceil(float(BOX.z) / float(FLUSH_CHUNK)))
	_cap_top.resize(_cap_nx * _cap_nz)
	_cap_top.fill(float(BOX.y) * CELL)
	_cap_lo.resize(_cap_nx * _cap_nz)
	_cap_lo.fill(0)
	_cap_hi.resize(_cap_nx * _cap_nz)
	_cap_hi.fill(BOX.y - 1)
	var reach := int(ceil(cut_flare_m / CUT_MAP_CELL))
	for iz in range(-reach, reach + 1):
		for ix in range(-reach, reach + 1):
			var dx := float(ix) * CUT_MAP_CELL
			var dz := float(iz) * CUT_MAP_CELL
			var d := sqrt(dx * dx + dz * dz)
			if d >= cut_flare_m:
				continue
			var w := (
				1.0 if d <= cut_corridor_m
				else smoothstep(cut_flare_m, cut_corridor_m, d)
			)
			if w <= 0.002:
				continue
			_cut_disc_dx.append(ix)
			_cut_disc_dz.append(iz)
			_cut_disc_w.append(w)
	_cut_texture = ImageTexture.create_from_image(_cut_map_image())
	_cut_map_dirty = false


func _cut_map_image() -> Image:
	return Image.create_from_data(
		CUT_MAP.x, CUT_MAP.y, false, Image.FORMAT_RGBAF,
		_cut_pixels.to_byte_array()
	)


func _upload_cut_map() -> void:
	if not _cut_map_dirty:
		return
	_cut_map_dirty = false
	_cut_texture.update(_cut_map_image())


## How far a map column may move before the lid over it has to be built again.
## The lid is what this costs: every column that moves marks a chunk, and at the
## section's zoom five centimetres is about a pixel — which is the point of a
## slack rather than a rebuild on every write.
const CUT_MAP_SLACK_M := 0.05


## Where the cut wants to be over one map column, and what that does to the lid.
func _apply_cut_column(col: int) -> void:
	var height := _cut_y
	if cut_follows_tunnel:
		height = (
			lerpf(bore_axis_y_m, _cut_owner_y[col], _cut_owner_w[col])
			+ cut_above_axis_m
		)
	if absf(_cut_pixels[col * 4] - height) < CUT_MAP_SLACK_M:
		return
	_cut_pixels[col * 4] = height
	_cut_map_cell[col] = clampi(int(floor(height / CELL)), 0, BOX.y - 1)
	_cut_map_dirty = true
	@warning_ignore("integer_division")
	var row := col / CUT_MAP.x
	var mx := col - row * CUT_MAP.x
	# The neighbours too: a texel is read by the interpolation for a map cell
	# either side of it, and that reach crosses chunk edges.
	for cz in range(
		maxi(row - 1, 0) >> CAP_MAP_SHIFT,
		(mini(row + 1, CUT_MAP.y - 1) >> CAP_MAP_SHIFT) + 1
	):
		for cx in range(
			maxi(mx - 1, 0) >> CAP_MAP_SHIFT,
			(mini(mx + 1, CUT_MAP.x - 1) >> CAP_MAP_SHIFT) + 1
		):
			_cap_pending[Vector2i(cx, cz)] = true


## The cut surface at a point, exactly as the shader computes it. The lid is
## built out of this, which is the whole of why the two agree.
func _cut_height_at(x_m: float, z_m: float) -> float:
	var tx := x_m / CUT_MAP_CELL - 0.5
	var tz := z_m / CUT_MAP_CELL - 0.5
	var bx := int(floor(tx))
	var bz := int(floor(tz))
	var fx := tx - float(bx)
	var fz := tz - float(bz)
	var x0 := clampi(bx, 0, CUT_MAP.x - 1)
	var x1 := clampi(bx + 1, 0, CUT_MAP.x - 1)
	var z0 := clampi(bz, 0, CUT_MAP.y - 1) * CUT_MAP.x
	var z1 := clampi(bz + 1, 0, CUT_MAP.y - 1) * CUT_MAP.x
	return lerpf(
		lerpf(_cut_pixels[(z0 + x0) * 4], _cut_pixels[(z0 + x1) * 4], fx),
		lerpf(_cut_pixels[(z1 + x0) * 4], _cut_pixels[(z1 + x1) * 4], fx),
		fz
	)


## One pass of the machine, written into the map.
func _extend_cut_map(at: Vector3) -> void:
	var mx := int(floor(at.x / CUT_MAP_CELL))
	var mz := int(floor(at.z / CUT_MAP_CELL))
	for k in _cut_disc_w.size():
		var ix := mx + _cut_disc_dx[k]
		if ix < 0 or ix >= CUT_MAP.x:
			continue
		var iz := mz + _cut_disc_dz[k]
		if iz < 0 or iz >= CUT_MAP.y:
			continue
		var w := _cut_disc_w[k]
		var col := iz * CUT_MAP.x + ix
		if w < _cut_owner_w[col]:
			continue
		_cut_owner_w[col] = w
		_cut_owner_y[col] = at.y
		if cut_follows_tunnel:
			_apply_cut_column(col)


func _rebuild_cut_map() -> void:
	for col in CUT_MAP.x * CUT_MAP.y:
		_apply_cut_column(col)
	_cut_map_dirty = true
	_cap_pending.clear()
	for cx in _cap_nx:
		for cz in _cap_nz:
			_cap_pending[Vector2i(cx, cz)] = true


## Mark a cell as ground the machine has been through. The lid reads the mark
## itself; the volume reads the envelope, which is all a per-column tint can
## carry and enough to tell a bore full of muck from the dune around it.
func _mark_dug(c: Vector3i, index: int) -> void:
	if _dug[index] != 0:
		return
	_dug[index] = 1
	_dug_cells += 1
	var col := (c.z >> CUT_MAP_SHIFT) * CUT_MAP.x + (c.x >> CUT_MAP_SHIFT)
	var low := float(c.y) * CELL
	var high := low + CELL
	# The first cell taken out of a map column is the one that turns it into
	# worked ground on the plan. Every cell after it is already inside a column
	# that is drawn as worked, so the plan's map does not have to hear about it.
	if _cut_pixels[col * 4 + 1] > _cut_pixels[col * 4 + 2]:
		_plan_map_dirty = true
	if low < _cut_pixels[col * 4 + 1]:
		_cut_pixels[col * 4 + 1] = low
		_cut_map_dirty = true
	if high > _cut_pixels[col * 4 + 2]:
		_cut_pixels[col * 4 + 2] = high
		_cut_map_dirty = true
	# A cell that is already empty changes no mass, so the mesher's own report of
	# what moved would never mark the lid over it.
	if _cut_map_cell[col] == c.y:
		_cap_pending[
			Vector2i(c.x >> CHUNK_SHIFT, c.z >> CHUNK_SHIFT)
		] = true


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


# --- the plan's ground map ----------------------------------------------------
#
# The trace seen from above, one texel per square metre, at the same resolution
# and on the same lattice as the cut map — so "has the machine been through this
# column" is a read of the cut map's own envelope and not a second bookkeeping.
#
# What is drawn is the same three things the lid draws and in the same colours:
# rock, banded by how far it stands over the driving depth; sand, banded by how
# far under it the rock starts; and ground the machine has been through, tinted
# with the same rust the volume is tinted with. Same rule as the lid — darker is
# more rock — so the plan, the profile, the column and the section are one map
# read four ways.
#
# It is a texture and not a few thousand rectangles because the panel is redrawn
# every frame for the sweep and the map changes ten times a second at most.


func _build_plan_map() -> void:
	_plan_words.resize(CUT_MAP.x * CUT_MAP.y)
	_refresh_plan_map()
	_plan_texture = ImageTexture.create_from_image(_plan_image())


func _plan_image() -> Image:
	return Image.create_from_data(
		CUT_MAP.x, CUT_MAP.y, false, Image.FORMAT_RGBA8,
		_plan_words.to_byte_array()
	)


## The colour of one map column, as a packed RGBA word. Little-endian, which is
## the byte order `FORMAT_RGBA8` wants.
static func _plan_word(colour: Color) -> int:
	return (
		int(clampf(colour.r, 0.0, 1.0) * 255.0)
		| (int(clampf(colour.g, 0.0, 1.0) * 255.0) << 8)
		| (int(clampf(colour.b, 0.0, 1.0) * 255.0) << 16)
		| (255 << 24)
	)


## Every colour the plan can be, built once per refresh: sand bands, then rock
## bands, then the same twenty again as worked ground. Twenty words rather than a
## colour mixed per texel is what keeps a rebuild of the whole trace under a
## millisecond.
func _plan_palette() -> PackedInt32Array:
	var out := PackedInt32Array()
	var span := maxf(float(cap_bands - 1), 1.0)
	for dug in 2:
		for band in cap_bands:
			var colour := CAP_SAND_NEAR.lerp(CAP_SAND_FAR, float(band) / span)
			if dug == 1:
				colour = colour.lerp(DUG_TINT, DUG_TINT_MIX)
			out.append(_plan_word(colour))
		for band in cap_bands:
			var colour := CAP_ROCK_THIN.lerp(CAP_ROCK_DEEP, float(band) / span)
			if dug == 1:
				colour = colour.lerp(DUG_TINT, DUG_TINT_MIX)
			out.append(_plan_word(colour))
	return out


## Read the rock map into the plan's texels.
##
## The reference height is the bore axis and not the cut, and that is the whole
## difference between this and the lid: the lid answers "what is at the plane I
## am looking through", and looking down at the trace the driver is asking "at
## the depth I drive at, is there rock in front of me". So rock is banded by how
## far it stands *above the axis* — the height he would have to climb over — and
## sand by how far under the axis the rock starts.
func _refresh_plan_map() -> void:
	_plan_map_dirty = false
	var started := Time.get_ticks_usec()
	var palette := _plan_palette()
	var bands := cap_bands
	# Over the same ten metres in both directions, and not over a bore radius the
	# way the lid bands rock. The lid is reading one plane and everything more
	# than a radius over it is the same news; the plan is reading a hill fifteen
	# metres tall, and banded over three of them the whole hill came out as one
	# flat slab of the darkest blue with no shape in it at all.
	var rock_step := maxf(cap_probe_m / float(bands), 0.01)
	var sand_step := maxf(cap_probe_m / float(bands), 0.01)
	var dug_slot := bands * 2 if mark_disturbed else 0
	var half := CUT_MAP_STEP >> 1
	for mz in CUT_MAP.y:
		var z := (mz << CUT_MAP_SHIFT) + half
		var row := mz * CUT_MAP.x
		var z_base := z * BOX.x
		for mx in CUT_MAP.x:
			var col := row + mx
			var over := (
				float(_rock_top[z_base + (mx << CUT_MAP_SHIFT) + half] + 1) * CELL
				- bore_axis_y_m
			)
			var slot := (
				bands + clampi(int(over / rock_step), 0, bands - 1) if over > 0.0
				else clampi(int(-over / sand_step), 0, bands - 1)
			)
			if _cut_pixels[col * 4 + 1] <= _cut_pixels[col * 4 + 2]:
				slot += dug_slot
			_plan_words[col] = palette[slot]
	if _plan_texture != null:
		_plan_texture.update(_plan_image())
	var spent := float(Time.get_ticks_usec() - started) / 1000.0
	_prof_plan_ms = maxf(_prof_plan_ms, spent)
	_prof_plan_sum += spent
	_prof_plan_n += 1


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
	# A centimetre clear of the cut, so the lid and the fragments thrown away at
	# the same height never fight for the same depth. The height itself is on the
	# quads now — the lid is a surface and not a slab.
	_cap_view.position = Vector3(0.0, 0.01, 0.0)
	add_child(_cap_view)


func _make_section_material(albedo: Color, roughness: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _section_shader
	material.set_shader_parameter("cell_size", CELL)
	material.set_shader_parameter("cut_on", false)
	material.set_shader_parameter("dug_on", mark_disturbed)
	material.set_shader_parameter("map_cell", CUT_MAP_CELL)
	material.set_shader_parameter(
		"map_dim", Vector2(float(CUT_MAP.x), float(CUT_MAP.y))
	)
	material.set_shader_parameter("cut_map", _cut_texture)
	material.set_shader_parameter("albedo", albedo)
	material.set_shader_parameter("dug_tint", DUG_TINT)
	material.set_shader_parameter("dug_mix", DUG_TINT_MIX)
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
		"W / S — thrust      A / D — course      Q / E — pitch      wheel — cut depth",
		"F — cut: rides the tunnel / flat      T — mark the ground you have worked",
		"V — plan screen      B — profile screen      H — instrument",
		"[ / ] — zoom      Z / X — turn the view      R — restart",
		"C — view: section / chase / free (free: hold RMB + WASD)",
	])
	# The keys and the readout are not screens and do not get a case, but they do
	# get the instrument's type colours — white text beside a panel that has none
	# on it is the loudest thing on the screen and it is the least important.
	_legend.add_theme_color_override("font_color", HUD_TEXT_DIM)
	layer.add_child(_legend)
	_status = Label.new()
	_outline(_status)
	_status.add_theme_color_override("font_color", HUD_TEXT)
	_status.position = Vector2(16.0, 140.0)
	layer.add_child(_status)

	# The case. Everything that used to be a window in a corner is a screen in
	# this, and the case is what draws every frame, every bezel, every label and
	# the sweep — so no screen can drift into a style of its own.
	_case = Control.new()
	_case.name = "Instrument"
	_case.anchor_top = 1.0
	_case.anchor_bottom = 1.0
	_case.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_case.draw.connect(_draw_case)
	layer.add_child(_case)

	# The plan: the trace seen from above, drawn from the recorded path and the
	# rock map. It used to be a second orthographic camera on the whole world,
	# rendered every frame — measured at 0.40 ms a frame of the 1.90 the scene
	# cost — and while it was a render and the profile was a drawing there was no
	# chance of the two ever looking like one instrument.
	_plan = Control.new()
	_plan.name = "PlanScreen"
	_plan.clip_contents = true
	_plan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A ground map of one texel per square metre, blown up five times. Nearest,
	# because a texel is a square metre of ground and blurring it into its
	# neighbours would invent a boundary that is not on the map.
	_plan.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_plan.draw.connect(_draw_plan)
	_case.add_child(_plan)

	# The trace unrolled: the one thing neither the section nor the plan can show,
	# because both of them are looking down a tunnel that turns.
	_profile = Control.new()
	_profile.name = "ProfileScreen"
	# The course ahead runs off the right edge whenever the run is short.
	_profile.clip_contents = true
	_profile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile.draw.connect(_draw_profile)
	_case.add_child(_profile)

	# The column of ground the machine is standing in, and the same column twenty
	# metres ahead. Two columns rather than one because the question underground
	# is never "what am I in" but "what am I about to be in".
	_ruler = Control.new()
	_ruler.name = "ColumnScreen"
	_ruler.clip_contents = true
	_ruler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ruler.draw.connect(_draw_ruler)
	_case.add_child(_ruler)

	# Added last so it is over every screen. Nothing on it is a reading.
	_glass = Control.new()
	_glass.name = "Glass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glass.draw.connect(_draw_glass)
	_case.add_child(_glass)
	_layout_instrument()


## Where every screen stands and how big the case has to be to hold them.
##
## Computed rather than written down, because `V` and `B` put screens out and a
## case with a hole in it where a screen used to be is not a case. One number
## drives all of it: `screen_width_px` is the length of the trace across a
## screen, and every extent in every screen is that many pixels per metre.
func _layout_instrument() -> void:
	var trace_m := float(BOX.x) * CELL
	_px_per_m = float(screen_width_px) / maxf(trace_m, 0.001)
	var pad := 10.0
	var head := 20.0
	var caption := 15.0
	var status := 18.0
	var gap := 8.0
	var plan_h := float(BOX.z) * CELL * _px_per_m
	var profile_h := (sand_top_m + 2.0) * _px_per_m * maxf(profile_v_scale, 0.05)
	var stack := 0.0
	if plan_screen:
		stack += caption + plan_h
	if profile_screen:
		stack += (gap if stack > 0.0 else 0.0) + caption + profile_h
	# The column screen is always in the case: it is the readout the driver looks
	# at when he has stopped looking at the trace, and it is the same instrument.
	# It takes exactly the height of whatever is stacked beside it — a case with a
	# screen out of it should close up, not leave a hole where the screen was —
	# and only falls back to a height of its own when there is nothing beside it.
	var column_h := stack if stack > 0.0 else 200.0
	var body := maxf(stack, column_h)
	var width := pad * 2.0 + float(column_width_px)
	if stack > 0.0:
		width += float(screen_width_px) + gap
	var height := pad * 2.0 + head + body + gap + status
	_case.offset_left = float(instrument_margin_px.x)
	_case.offset_right = _case.offset_left + width
	_case.offset_bottom = -float(instrument_margin_px.y)
	_case.offset_top = _case.offset_bottom - height

	var y := pad + head
	if plan_screen:
		_plan.position = Vector2(pad, y + caption)
		_plan.size = Vector2(float(screen_width_px), plan_h)
		y += caption + plan_h + gap
	if profile_screen:
		_profile.position = Vector2(pad, y + caption)
		_profile.size = Vector2(float(screen_width_px), profile_h)
	_ruler.position = Vector2(
		width - pad - float(column_width_px), pad + head + caption
	)
	_ruler.size = Vector2(float(column_width_px), column_h - caption)
	_glass.position = Vector2.ZERO
	_glass.size = Vector2(width, height)
	_case.visible = instrument
	_plan.visible = plan_screen
	_profile.visible = profile_screen
	_redraw_screens()


## Everything on the instrument except the glass. On the instrument's own clock,
## which is the whole point: the readings under the sweep are a tenth of a second
## old and the instrument does not pretend otherwise.
func _redraw_screens() -> void:
	_case.queue_redraw()
	_plan.queue_redraw()
	_profile.queue_redraw()
	_ruler.queue_redraw()


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
	# Written whether or not the cut is following it: the map is what the flat
	# plane is toggled *back* from, and a map with a hole in it where the driver
	# was looking at a plane would come back as a tunnel that was never dug.
	if _travelled - _cut_map_done >= CUT_MAP_STEP_M:
		_cut_map_done = _travelled
		var map_started := Time.get_ticks_usec()
		_extend_cut_map(_pos)
		_prof_map_ms = maxf(
			_prof_map_ms, float(Time.get_ticks_usec() - map_started) / 1000.0
		)
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
		# On the mesh's own clock, so what the shader throws away and what the
		# lid draws can never be a frame apart.
		_upload_cut_map()
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
		# The elevator is held against a wanted height rather than driven open
		# loop. Pitch is the *integral* of the stick, so a stick that swings
		# evenly does not: past about fourteen hundred ticks the open-loop
		# version parked itself against the ceiling of the trace and the run
		# failed for having stopped, which says nothing about the view it was
		# opened to test. Nothing about how the machine drives changes — this is
		# the hand on the stick, and only when there is no hand on it.
		if _autopilot_dives:
			var wanted := bore_axis_y_m + sin(float(_tick) / 140.0) * 5.0
			_elevator = clampf((wanted - _pos.y) * 0.6, -1.0, 1.0)
		else:
			_elevator = 0.0
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
			_mark_dug(c, index)
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
			_mark_dug(c, index)
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
	# The plan is a drawing of this map, so a bore through the crest of the hill
	# has to show up on it as the hill being eaten.
	_plan_map_dirty = true


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
				var c := Vector3i(
					base.x + column.x, base.y + dy, base.z + column.y
				)
				var accepted := _field.deposit(c.x, c.y, c.z, owed)
				placed += accepted
				remaining -= accepted
				owed -= accepted
				# Muck that ended up somewhere the cutter never was — over the
				# crown of a bore that has already filled, mostly — is still the
				# driver's own, and the section says so.
				if accepted > 0.0 and _in_box(c):
					_mark_dug(c, (c.y * BOX.z + c.z) * BOX.x + c.x)
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
		var chunk := Vector3i(chunks[k], chunks[k + 1], chunks[k + 2])
		pending[chunk] = true
		# The lid is derived from the same cells the mesher just heard about, so
		# it is marked from the same report. A lid drawn from a stale read is a
		# picture of a tunnel that is not there.
		#
		# Against the record's own box of moved cells, not against the chunk: a
		# chunk is eight metres tall and the cut is one cell thick, and
		# rebuilding the lid for every collapse anywhere in that band cost more
		# than the whole of the rest of the section. The band the cut wanders
		# through over this square of the trace is what the lid last measured.
		var ci := chunk.z * _cap_nx + chunk.x
		if (
			ci >= 0 and ci < _cap_lo.size()
			and chunks[k + 4] <= _cap_hi[ci] and chunks[k + 7] >= _cap_lo[ci]
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
#   * the surface, which stops at the cut because the shader throws away every
#     fragment above it — nothing is drawn above the cut by any route;
#   * the lid, which is built from the cells *at* the cut and so is a reading of
#     the field rather than a decoration on it;
#   * the machine, which is never above the cut, because the cut is placed off
#     the machine's own axis and follows it.
#
# All three now read the same height map (`_cut_pixels`), which is what keeps
# them agreeing once the cut stopped being one number.
#
# The simulation above the cut is untouched and keeps running. That is not a
# discrepancy: the material up there is really there, it is simply not drawn,
# and the moment any of it falls into the bore it is below the cut and drawn.


## Whether any of a mesh chunk is under the cut, asked of the chunk's own square
## of the map rather than of the whole trace: with the cut riding the tunnel there
## is no one height that could answer it for the box.
func _chunk_below_cut(chunk: Vector3i) -> bool:
	if _view != View.ISO:
		return true
	var ci := chunk.z * _cap_nx + chunk.x
	if ci < 0 or ci >= _cap_top.size():
		return true
	return float(chunk.y * FLUSH_CHUNK) * CELL < _cap_top[ci]


## Where a flat cut wants to be: off the machine's axis, snapped to a cell so the
## lid is a layer of cells and not a slab sawn through the middle of one.
func _wanted_cut_cell() -> int:
	return clampi(int(floor((_pos.y + cut_above_axis_m) / CELL)), 0, BOX.y - 1)


func _update_cut(force: bool) -> void:
	if cut_follows_tunnel:
		if force:
			_rebuild_cut_map()
		# The readouts want one number, and the one that means anything is the
		# cut over the machine itself.
		_cut_y = _cut_height_at(_pos.x, _pos.z)
		_cut_cell = clampi(int(floor(_cut_y / CELL)), 0, BOX.y - 1)
	else:
		var wanted := _wanted_cut_cell()
		if not force and absi(wanted - _cut_cell) < CUT_HYSTERESIS_CELLS:
			return
		_cut_cell = wanted
		# The lid sits on the top face of the layer it draws, a centimetre clear
		# of it so the two never fight for the same depth.
		_cut_y = float(_cut_cell + 1) * CELL
		_rebuild_cut_map()
	if not force:
		return
	for material in _clipped:
		material.set_shader_parameter("cut_on", _view == View.ISO)
		material.set_shader_parameter("dug_on", mark_disturbed)
	_flush_cap(_cap_pending.size())
	_apply_chunk_visibility()
	_upload_cut_map()


func _apply_chunk_visibility() -> void:
	_cap_visible_dirty = false
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
	var started := Time.get_ticks_usec()
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
	# A rebuilt lid is the only thing that can tell a mesh chunk it is under the
	# cut now, because the lid is what reads the map over that square.
	if _cap_visible_dirty:
		_apply_chunk_visibility()
	if done > 0:
		_prof_cap_ms = maxf(
			_prof_cap_ms,
			float(Time.get_ticks_usec() - started) / 1000.0 / float(done)
		)


## Bands of one kind of lid cell. The codes are laid out in blocks so a run of
## the same colour is a run of the same integer and the lid stays a few hundred
## quads instead of a quarter of a million.
func _cap_first_spoil() -> int:
	return 1


func _cap_first_sand() -> int:
	return 1 + cap_bands


func _cap_first_rock() -> int:
	return 1 + cap_bands * 2


## What one cell at the cut is, as a code: -1 nothing, 0 lining, then muck in the
## driver's own bore, then sand, then rock.
##
## This is where the section stops being a hole and becomes a drawing. A cut
## through sand produces no geometry at all — an isosurface only exists where the
## fill crosses it, and the inside of a dune crosses nothing — so without the lid
## the driver looks straight through the ground into the backfaces of the bore
## and sees an empty black box. With it, the cut reads as ground: the open tunnel
## is the gap in it, the lining is the rim of the gap, the part of the tunnel that
## has filled back up is its own colour, and rock that reaches the cut is a
## different colour than the sand beside it.
func _cap_code(
	sand: PackedFloat32Array,
	rock: PackedFloat32Array,
	solid: PackedByteArray,
	dug: bool,
	cell: int,
	i: int,
	column: int
) -> int:
	var step := maxf(cap_probe_m / float(cap_bands), 0.01)
	if rock[i] > 0.5:
		# Rock at the cut, banded by how much of it stands above. Saturating at
		# the bore's own radius rather than at the sand probe: rock a bore-radius
		# over the cut is already rock the machine cannot climb over, and
		# everything past that is the same news.
		var over := float(_rock_top[column] - cell) * CELL
		var over_step := maxf(bore_diameter_m * 0.5 / float(cap_bands), 0.01)
		return _cap_first_rock() + clampi(
			int(over / over_step), 0, cap_bands - 1
		)
	if solid[i] != 0:
		return 0
	if sand[i] <= RENDER_MIN_FILL:
		return -1
	if dug:
		# Ground the machine took out and its own muck has come back into,
		# banded by how much of the cell is back. Reported apart from the sand
		# because it is not sand any more in the only sense the driver cares
		# about: it is his tunnel, and it is standing full.
		var full := clampf(sand[i] / maxf(_cell_volume, 0.0001), 0.0, 1.0)
		return _cap_first_spoil() + clampi(
			int(full * float(cap_bands)), 0, cap_bands - 1
		)
	# Sand at the cut, tinted by the rock underneath it. This is the layering: a
	# cut through a layer cake shows one layer, so the other layer has to be
	# reported rather than shown, and the honest way to report it is how far down
	# it starts.
	var depth := float(cell - _rock_top[column]) * CELL
	return _cap_first_sand() + clampi(int(depth / step), 0, cap_bands - 1)


func _cap_colour(code: int) -> Color:
	if code == 0:
		return CAP_LINING
	var span := maxf(float(cap_bands - 1), 1.0)
	if code >= _cap_first_rock():
		return CAP_ROCK_THIN.lerp(
			CAP_ROCK_DEEP, float(code - _cap_first_rock()) / span
		)
	if code >= _cap_first_sand():
		return CAP_SAND_NEAR.lerp(
			CAP_SAND_FAR, float(code - _cap_first_sand()) / span
		)
	return CAP_SPOIL_THIN.lerp(
		CAP_SPOIL_FULL, float(code - _cap_first_spoil()) / span
	)


## One chunk of the lid, built at whatever height the map puts the cut over each
## column. Once the cut stopped being flat this is a small terrain: horizontal
## quads on the cells, and a face at every step between neighbours, or the trench
## would be striped with slots looking into an unlit box.
func _build_cap_chunk(chunk: Vector2i) -> void:
	var x0 := chunk.x * FLUSH_CHUNK
	var z0 := chunk.y * FLUSH_CHUNK
	var w := mini(FLUSH_CHUNK, BOX.x - x0)
	var d := mini(FLUSH_CHUNK, BOX.z - z0)
	var instance: MeshInstance3D = _cap_chunks.get(chunk)
	if w <= 0 or d <= 0:
		return
	# The cut at every corner of every cell of the chunk. Corners and not centres
	# because the lid is a surface: neighbouring quads share their corner heights,
	# which is what makes it continuous instead of a flight of steps.
	var corner := PackedFloat32Array()
	corner.resize((w + 1) * (d + 1))
	var top := -1.0e9
	for iz in d + 1:
		var z_m := float(z0 + iz) * CELL
		for ix in w + 1:
			var height := _cut_height_at(float(x0 + ix) * CELL, z_m)
			corner[iz * (w + 1) + ix] = height
			top = maxf(top, height)
	var cells := PackedInt32Array()
	cells.resize(w * d)
	var lo := BOX.y - 1
	var hi := 0
	for iz in d:
		for ix in w:
			# The mean of the four corners of a bilinear patch is its value at
			# the centre, so this is the cut in the middle of the cell and not an
			# approximation of it.
			var centre := 0.25 * (
				corner[iz * (w + 1) + ix] + corner[iz * (w + 1) + ix + 1]
				+ corner[(iz + 1) * (w + 1) + ix]
				+ corner[(iz + 1) * (w + 1) + ix + 1]
			)
			var cell := clampi(int(floor(centre / CELL)), 0, BOX.y - 1)
			cells[iz * w + ix] = cell
			lo = mini(lo, cell)
			hi = maxi(hi, cell)
	var ci := chunk.y * _cap_nx + chunk.x
	if not is_equal_approx(_cap_top[ci], top):
		_cap_top[ci] = top
		_cap_visible_dirty = true
	_cap_lo[ci] = lo
	_cap_hi[ci] = hi
	# Three reads of the slab the cut wanders through instead of a quarter of a
	# million bound calls: the cost of the lid is the reason it can be rebuilt
	# whenever the tunnel changes shape.
	var origin := Vector3i(x0, lo, z0)
	var extent := Vector3i(w, hi - lo + 1, d)
	var sand := _field.copy_mass_box(origin, extent)
	var rock := _rock.copy_mass_box(origin, extent)
	var solid := _field.copy_solid_box(origin, extent)
	var codes := PackedInt32Array()
	codes.resize(w * d)
	for iz in d:
		for ix in w:
			var at := iz * w + ix
			var cell := cells[at]
			var dug := (
				mark_disturbed
				and _dug[(cell * BOX.z + z0 + iz) * BOX.x + x0 + ix] != 0
			)
			codes[at] = _cap_code(
				sand, rock, solid, dug, cell,
				((cell - lo) * d + iz) * w + ix,
				(z0 + iz) * BOX.x + x0 + ix
			)
	var verts := PackedVector3Array()
	var colours := PackedColorArray()
	for iz in d:
		var near := iz * (w + 1)
		var far := (iz + 1) * (w + 1)
		# Runs of one colour at one height become one quad. Over ground nobody
		# has dug the cut is level for tens of metres, so this is most of the lid
		# most of the time; on the flare every corner is a different height and
		# every cell is its own quad, which is exactly what a slope needs.
		var ix := 0
		while ix < w:
			var code := codes[iz * w + ix]
			var run_from := ix
			var h_near := corner[near + ix]
			var h_far := corner[far + ix]
			ix += 1
			while (
				ix < w
				and codes[iz * w + ix] == code
				and is_equal_approx(corner[near + ix], h_near)
				and is_equal_approx(corner[near + ix + 1], h_near)
				and is_equal_approx(corner[far + ix], h_far)
				and is_equal_approx(corner[far + ix + 1], h_far)
			):
				ix += 1
			if code >= 0:
				_cap_quad(
					verts, colours, x0 + run_from, x0 + ix, z0 + iz,
					h_near, corner[near + ix], h_far, corner[far + ix],
					_cap_colour(code)
				)
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


## One quad of the lid, carrying the cut's own height at each of its four
## corners. Neighbouring quads read the same corners out of the same array, so
## the lid closes: no step to draw a face of, and no seam to look through.
func _cap_quad(
	verts: PackedVector3Array,
	colours: PackedColorArray,
	xa: int,
	xb: int,
	z: int,
	y_near_a: float,
	y_near_b: float,
	y_far_a: float,
	y_far_b: float,
	colour: Color
) -> void:
	var x_lo := float(xa) * CELL
	var x_hi := float(xb) * CELL
	var z_lo := float(z) * CELL
	var z_hi := float(z + 1) * CELL
	var a := Vector3(x_lo, y_near_a, z_lo)
	var b := Vector3(x_hi, y_near_b, z_lo)
	var c := Vector3(x_hi, y_far_b, z_hi)
	var e := Vector3(x_lo, y_far_a, z_hi)
	# Two triangles, wound either way: the lid's material has culling off, so a
	# lid that ends up facing down is still a lid.
	verts.append(a)
	verts.append(b)
	verts.append(c)
	verts.append(a)
	verts.append(c)
	verts.append(e)
	for _k in 6:
		colours.append(colour)


# --- camera and HUD ----------------------------------------------------------


func _process(delta: float) -> void:
	if _field == null:
		return
	_update_camera(delta)
	_update_overlay()
	_update_hud()
	_update_instrument(delta)


## The instrument's own clock, and the one thing on this HUD that is shared by
## every screen rather than owned by one of them.
##
## Both readings are taken on the same tick of it — the profile's samples and the
## plan's ground map — so the two screens can never be a frame apart in what they
## are showing, which is a thing the old pair could not promise: one of them was
## a live render of the world and the other was a tenth of a second old.
func _update_instrument(delta: float) -> void:
	if not instrument:
		return
	var period := 1.0 / maxf(instrument_hz, 1.0)
	_scan_blip = maxf(_scan_blip - delta / maxf(period * 0.4, 0.001), 0.0)
	_scan_phase = fmod(_scan_phase + delta / maxf(scan_period_s, 0.05), 1.0)
	_pf_due -= delta
	if _pf_due <= 0.0:
		_pf_due = period
		_scan_blip = 1.0
		# Sampled whether or not the profile is being looked at: the case's own
		# status line reads how full the bore behind is off these samples, and a
		# status line that says 0 % because a screen was switched off is a lie
		# printed on the instrument.
		_sample_profile()
		if plan_screen and _plan_map_dirty:
			_refresh_plan_map()
		_redraw_screens()
	# Every frame, and it is the only thing that is: a sweep redrawn ten times a
	# second is a stutter, and a sweep is what makes a still panel read as live.
	_glass.queue_redraw()


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
	var datum := _datum_y()
	_plumb(finish, datum, COURSE_COLOUR)
	_cross(Vector3(finish.x, datum, finish.z), 1.4, COURSE_COLOUR)
	# From the machine to the top of the ground, straight through the plane of
	# the cut. Under an orthographic camera the length of that mast is the one
	# thing on the screen that says how much ground is overhead — the rest of
	# the cover was clipped away to make the tunnel visible in the first place.
	_plumb(_pos, sand_top_m, PLUMB_COLOUR)
	_cross(Vector3(_pos.x, sand_top_m, _pos.z), 2.5, PLUMB_COLOUR)


## The one level the shadows are cast on. A cut that rides the tunnel is useless
## as a datum — it is half a metre over the track everywhere, so a track and its
## shadow would be two parallel lines half a metre apart whatever the machine
## did, and the cue would say nothing. The level the cut would have without a
## tunnel under it is a real datum and does not move.
func _datum_y() -> float:
	if cut_follows_tunnel:
		return bore_axis_y_m + cut_above_axis_m
	return _cut_y


## Same track, laid on the datum. Under an orthographic camera a line and its
## shadow are two parallel lines a fixed distance apart, and that distance is the
## depth — the one depth cue ortho does not destroy.
func _flatten(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var datum := _datum_y() + 0.03
	out.resize(points.size())
	for i in points.size():
		out[i] = Vector3(points[i].x, datum, points[i].z)
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


# --- the instrument ----------------------------------------------------------
#
# One case, three screens, one clock.
#
# What follows is split down the middle into chrome and readings, and that split
# is the whole answer to "two windows out of two different games":
#
#   * the chrome — case, bezel, grid, ticks, type, the machine symbol, the accent
#     and the sweep — is drawn by shared code and comes out identical in every
#     screen. There is one `_bezel`, one `_screen_grid`, one `_machine_symbol`,
#     one `_scan`. A screen cannot drift into a style of its own because it has
#     no style of its own to drift into.
#
#   * the readings are untouched. Sand stays warm, rock stays cool, worked ground
#     stays rust, open bore stays black. Flooding the lot with one phosphor
#     colour would have made a radar out of this in an afternoon and thrown away
#     the only thing on the screen that tells the driver what he is driving in.
#
# The unit that ties the screens to each other is the metre. `_px_per_m` is
# derived once, in `_layout_instrument`, from the screen width and the length of
# the trace, and every extent in every screen is that many pixels per metre — so
# a ten metre division is the same width of glass in the plan as in the profile,
# a 6 m bore is the same 30 px in both, and the numbers written along the trail
# in one screen are the numbers written along the foot of the other.


## The one typeface on the instrument. Three sizes and no more.
func _hud_font() -> Font:
	return _case.get_theme_default_font()


## Every word on this instrument goes through here, and it is one line of drop
## shadow. Without it half the labels are white on a dune and the other half are
## grey on black rock, which is exactly how a panel stops looking designed.
func _hud_text(
	on: CanvasItem,
	font: Font,
	at: Vector2,
	text: String,
	colour: Color,
	points := HUD_TICK_PT
) -> void:
	on.draw_string(
		font, at + Vector2.ONE, text, HORIZONTAL_ALIGNMENT_LEFT, -1, points,
		HUD_TEXT_SHADOW
	)
	on.draw_string(
		font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, points, colour
	)


## The frame of everything here: a hairline and four corner brackets. The case
## goes through it and so does every screen, which is most of the reason they
## read as parts of one object rather than as neighbours.
func _bezel(on: CanvasItem, rect: Rect2, edge: Color, corner := 9.0) -> void:
	on.draw_rect(rect, edge, false, 1.0)
	var bright := Color(edge.r, edge.g, edge.b, minf(edge.a * 1.9, 1.0))
	var xs: Array[float] = [rect.position.x, rect.end.x]
	var ys: Array[float] = [rect.position.y, rect.end.y]
	for ix in 2:
		var sx := 1.0 if ix == 0 else -1.0
		for iy in 2:
			var sy := 1.0 if iy == 0 else -1.0
			var at := Vector2(xs[ix], ys[iy])
			on.draw_line(at, at + Vector2(sx * corner, 0.0), bright, 2.0)
			on.draw_line(at, at + Vector2(0.0, sy * corner), bright, 2.0)


## The grid a screen is ruled with. One price per division across the whole
## instrument — the price is written on the case, so it never has to be counted —
## and every fifth line brighter, because ten of anything is easier to find than
## a hundred of it.
func _screen_grid(
	on: CanvasItem,
	size: Vector2,
	step_x: float,
	step_y: float,
	y_from_bottom: bool,
	base := -1.0,
	major := 5
) -> void:
	# Where the horizontal lines are counted from. The screens that draw a height
	# count from the level that is zero metres on them, which is not always the
	# bottom edge of the glass.
	var zero := base if base >= 0.0 else size.y
	if step_x > 3.0:
		var i := 1
		var x := step_x
		while x < size.x - 0.5:
			on.draw_line(
				Vector2(x, 0.0), Vector2(x, size.y),
				HUD_GRID_MAJOR if i % major == 0 else HUD_GRID, 1.0
			)
			x += step_x
			i += 1
	if step_y > 3.0:
		var i := 1
		var offset := step_y
		while offset < size.y - 0.5:
			var y := zero - offset if y_from_bottom else offset
			if y > 0.5 and y < size.y - 0.5:
				on.draw_line(
					Vector2(0.0, y), Vector2(size.x, y),
					HUD_GRID_MAJOR if i % major == 0 else HUD_GRID, 1.0
				)
			offset += step_y
			i += 1


## Scan lines. What makes a screen look like a screen when nothing on it moves.
## Faint to the point of being arguable, and that is the specification: anything
## strong enough to notice while reading a depth off the profile is a fault
## dressed up as a feature. Drawn into the screen itself, because it does not
## move and so costs nothing between refreshes.
func _scan(on: CanvasItem, size: Vector2) -> void:
	if not scan_lines:
		return
	var y := 1.0
	while y < size.y:
		on.draw_line(Vector2(0.0, y), Vector2(size.x, y), HUD_SCAN_LINE, 1.0)
		y += 4.0


## The glass: one sheet over the whole case, and the only thing here redrawn
## every frame.
##
## The sweep is one bar travelling across the *instrument* and not one bar per
## screen. It crosses the plan and the profile at the same instant at the same
## column, then goes on and crosses the ground column — which is a statement no
## amount of matching bezel can make, that these are three faces of one machine.
##
## It is on its own layer for a reason that is not cosmetic. The screens under it
## are a few hundred draw calls each and they are redrawn on the instrument's own
## clock, ten times a second; the sweep and the refresh lamp are eight draw calls
## and they are redrawn every frame. Drawing the screens every frame instead cost
## 0.84 ms a frame — more than the second world render this whole pass removed.
func _draw_glass() -> void:
	var size := _glass.size
	var blip := Color(
		COURSE_COLOUR.r, COURSE_COLOUR.g, COURSE_COLOUR.b,
		0.16 + 0.78 * _scan_blip
	)
	_glass.draw_circle(Vector2(size.x - 27.0, 17.0), 3.0, blip)
	if not scan_sweep:
		return
	var x := _scan_phase * size.x
	var trail := Color(HUD_SCAN.r, HUD_SCAN.g, HUD_SCAN.b, HUD_SCAN.a * 0.5)
	for screen: Control in [_plan, _profile, _ruler]:
		if not screen.visible:
			continue
		var rect := Rect2(screen.position, screen.size)
		var from := maxf(x - 10.0, rect.position.x)
		var to := minf(x, rect.end.x)
		if to <= from:
			continue
		# A band behind the line and not a line on its own: a hairline at a
		# fractional position flickers as it is rounded, and this is meant to be
		# barely seen.
		_glass.draw_rect(
			Rect2(from, rect.position.y, to - from, rect.size.y), trail
		)
		if x <= rect.end.x:
			_glass.draw_line(
				Vector2(x, rect.position.y), Vector2(x, rect.end.y), HUD_SCAN, 1.0
			)


## The machine, in whichever screen has one. The same arrowhead, the same size,
## the same accent, pointed the way it is going — in the plan that is the course,
## in the profile it is the pitch — so the eye never has to learn two of them.
## The ring around it is the "you are here" and nothing else on the instrument is
## allowed to be a ring.
func _machine_symbol(on: CanvasItem, at: Vector2, heading: Vector2, size := 7.0) -> void:
	var f := (
		heading.normalized() if heading.length_squared() > 1e-8 else Vector2.RIGHT
	)
	var r := Vector2(-f.y, f.x)
	var points := PackedVector2Array([
		at + f * size,
		at - f * size * 0.6 + r * size * 0.66,
		at - f * size * 0.18,
		at - f * size * 0.6 - r * size * 0.66,
	])
	var ring := Color(COURSE_COLOUR.r, COURSE_COLOUR.g, COURSE_COLOUR.b, 0.45)
	on.draw_arc(at, size * 2.0, 0.0, TAU, 28, ring, 1.0)
	on.draw_colored_polygon(points, COURSE_COLOUR)
	var outline := points
	outline.append(points[0])
	on.draw_polyline(outline, HUD_SCREEN, 1.0)


## A caption over a screen, and the bezel round it. The left half names the
## screen, the right half says what one division of its grid is worth — which is
## the one thing a grid must never leave to be guessed.
func _screen_caption(
	font: Font, screen: Control, name: String, note: String
) -> void:
	var at := screen.position
	var size := screen.size
	_case.draw_string(
		font, at + Vector2(1.0, -5.0), name, HORIZONTAL_ALIGNMENT_LEFT, -1,
		HUD_LABEL_PT, HUD_TEXT
	)
	var width := font.get_string_size(
		note, HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_TICK_PT
	).x
	_case.draw_string(
		font, at + Vector2(size.x - width - 1.0, -5.0), note,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_TICK_PT, HUD_TEXT_DIM
	)
	_bezel(
		_case, Rect2(at - Vector2.ONE, size + Vector2(2.0, 2.0)),
		HUD_SCREEN_EDGE, 8.0
	)


## How much bigger than true scale the column screen is drawn. It is the one
## screen on the instrument that is not at the shared scale — it is 24 m of
## ground in a panel a fifth of the width of the others — so it says so on its
## own face rather than quietly lying about a length.
func _column_magnification() -> float:
	var world_top := maxf(sand_top_m + 2.0, 0.001)
	var true_px := world_top * _px_per_m * maxf(profile_v_scale, 0.05)
	return maxf(_ruler.size.y - 30.0, 1.0) / maxf(true_px, 0.001)


## The case: everything that is not a reading. Drawn here and not in the screens
## so that there is exactly one description of what this instrument looks like.
func _draw_case() -> void:
	var font := _hud_font()
	var size := _case.size
	_case.draw_rect(Rect2(Vector2.ZERO, size), HUD_CASE)
	_bezel(
		_case, Rect2(Vector2.ONE, size - Vector2(2.0, 2.0)), HUD_CASE_EDGE, 14.0
	)
	# Four fasteners. It takes about that much for a rectangle to read as a thing
	# that was bolted together instead of a rectangle.
	for corner: Vector2 in [
		Vector2(14.0, 14.0), Vector2(size.x - 14.0, 14.0),
		Vector2(14.0, size.y - 14.0), Vector2(size.x - 14.0, size.y - 14.0),
	]:
		_case.draw_circle(corner, 2.0, HUD_CASE_EDGE)
	_case.draw_string(
		font, Vector2(24.0, 22.0), "TRACE SCAN", HORIZONTAL_ALIGNMENT_LEFT, -1,
		HUD_TITLE_PT, HUD_TEXT
	)
	# The refresh, stated and shown. Both screens are redrawn off one sample taken
	# ten times a second; the blip is lit for the first third of each period, so
	# what is blinking in the corner is literally the clock the pictures are on.
	var hz := "REFRESH %.0f Hz" % instrument_hz
	var hz_width := font.get_string_size(
		hz, HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_TICK_PT
	).x
	_case.draw_string(
		font, Vector2(size.x - 24.0 - hz_width - 12.0, 21.0), hz,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_TICK_PT, HUD_TEXT_DIM
	)
	_case.draw_line(
		Vector2(14.0, 28.0), Vector2(size.x - 14.0, 28.0), HUD_SCREEN_EDGE, 1.0
	)

	var division := "grid %.0f m" % grid_step_m
	if plan_screen:
		_screen_caption(font, _plan, "PLAN · looking down", division)
	if profile_screen:
		_screen_caption(font, _profile, "PROFILE · along the tunnel", division)
	_screen_caption(
		font, _ruler, "COLUMN · here / +20 m",
		"x%.1f" % _column_magnification()
	)

	# The status strip: the scale bar first, because a drawing with a bar on it is
	# a drawing anybody can measure, and then the four numbers the two screens are
	# a picture of.
	var base := size.y - 12.0
	var bar := grid_step_m * _px_per_m
	var rule := base - 5.0
	_case.draw_line(Vector2(24.0, rule), Vector2(24.0 + bar, rule), HUD_TEXT, 1.0)
	for end_x: float in [24.0, 24.0 + bar]:
		_case.draw_line(
			Vector2(end_x, rule - 3.0), Vector2(end_x, rule + 3.0), HUD_TEXT, 1.0
		)
	_case.draw_string(
		font, Vector2(24.0 + bar + 7.0, base), "%.0f m" % grid_step_m,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_TICK_PT, HUD_TEXT_DIM
	)
	_case.draw_string(
		font, Vector2(24.0 + bar + 60.0, base),
		"%.1f m driven   %d%% of the bore behind is full   face: %s" % [
			_travelled,
			int(round(_pf_mean_fill * 100.0)),
			_ground_name(),
		],
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_LABEL_PT, HUD_TEXT_DIM
	)


# --- the plan screen ---------------------------------------------------------


## A point of the world on the plan screen. The plan is the trace at the shared
## scale with no offset at all: world x runs across, world z runs down, and the
## whole 120 x 48 m box is exactly the screen.
func _plan_at(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z) * _px_per_m


func _plan_course(points: PackedVector3Array, colour: Color, width: float) -> void:
	if points.size() < 2:
		return
	var out := PackedVector2Array()
	out.resize(points.size())
	for i in points.size():
		out[i] = _plan_at(points[i])
	_plan.draw_polyline(out, colour, width)


## The distance ticks. Every ten metres of driven tunnel gets a tick across the
## trail and every twentieth gets a number, and the same numbers are written
## along the foot of the profile — so "sixty metres" is a place both screens
## agree about even though one of them is a map and the other is a graph.
func _plan_ticks(font: Font) -> void:
	if tick_step_m <= 0.0:
		return
	# From zero, and the zero is drawn: the profile's origin is the left edge of
	# its glass and is obvious, the plan's origin is a point in the middle of a
	# map and is not. Both screens number the same trace from the same place, and
	# the plan has to say where that place is or the numbers are only decoration.
	var mark := 0.0
	var index := 0
	while mark <= _travelled:
		var at := _trail_at(mark)
		var point: Vector3 = at[0]
		var forward: Vector3 = at[1]
		var here := _plan_at(point)
		var along := Vector2(forward.x, forward.z)
		if along.length_squared() < 1e-8:
			along = Vector2.RIGHT
		var side := Vector2(-along.y, along.x).normalized()
		var labelled := index % maxi(tick_label_every, 1) == 0
		var reach := 7.0 if labelled else 4.0
		_plan.draw_line(
			here - side * reach, here + side * reach,
			HUD_TEXT if labelled else HUD_TEXT_DIM, 1.0
		)
		if labelled:
			_hud_text(
				_plan, font, here + side * reach + Vector2(3.0, 4.0),
				"%d" % int(round(mark)), HUD_TEXT_DIM
			)
		mark += tick_step_m
		index += 1


## The trace from above, drawn from the recorded path and the ground map.
##
## This used to be a second orthographic camera on the whole world, rendered into
## the corner every frame. It was replaced for two reasons and the cheaper one is
## the 0.40 ms a frame it cost. The other is that a render and a drawing can never
## be made to look like one instrument: one of them is lit, shaded, perspective-
## free but photographic, and the other is ink. Both screens are ink now.
func _draw_plan() -> void:
	var size := _plan.size
	_plan.draw_rect(Rect2(Vector2.ZERO, size), HUD_SCREEN)
	if _plan_texture != null:
		_plan.draw_texture_rect(_plan_texture, Rect2(Vector2.ZERO, size), false)
	var step := grid_step_m * _px_per_m
	_screen_grid(_plan, size, step, step, false)
	var font := _hud_font()
	# Where the machine has been. One point per metre, as in the section: the
	# trail is recorded four times finer than that because the lining rides it.
	var trail := PackedVector2Array()
	var stride := maxi(1, int(round(1.0 / TRAIL_STEP_M)))
	var i := 0
	while i < _trail_pos.size():
		trail.append(_plan_at(_trail_pos[i]))
		i += stride
	trail.append(_plan_at(_pos))
	if trail.size() > 1:
		# On its own shadow, because the corridor it runs down is tinted with the
		# same rust the trail is drawn in — the track would vanish into exactly
		# the ground it made. The same pairing the section uses.
		_plan.draw_polyline(trail, TRAIL_SHADOW, 5.0)
		_plan.draw_polyline(trail, TRAIL_COLOUR, 2.0)
	# Where it can go and where it is going, in the same two colours the section
	# draws them in — so the arcs on the screen and the arcs in the world are
	# recognisably the same arcs.
	var limit := 1.0 / maxf(min_turn_radius_m, 0.1)
	_plan_course(_course_points(limit, course_preview_m), ENVELOPE_COLOUR, 1.0)
	_plan_course(_course_points(-limit, course_preview_m), ENVELOPE_COLOUR, 1.0)
	_plan_course(
		_course_points(_steer * limit, course_preview_m), COURSE_COLOUR, 2.0
	)
	_plan_ticks(font)
	var here := _plan_at(_pos)
	_machine_symbol(_plan, here, Vector2(cos(_yaw), sin(_yaw)))
	# The same number the profile writes at its own caret, in the same accent, at
	# the same place relative to the same symbol.
	_hud_text(
		_plan, font, here + Vector2(14.0, -11.0), "%.0f m" % _travelled,
		COURSE_COLOUR
	)
	_scan(_plan, size)


# --- the profile screen ------------------------------------------------------


## How many samples the profile is drawn from. Sixty-four across the run and
## whatever the course preview brings: the panel is six hundred pixels wide and
## a sample is a column of it.
const PROFILE_SAMPLES := 64


## Read the trace off the record, on the instrument's own clock. Everything the
## profile draws is here, so the draw itself is arithmetic on packed arrays —
## which is what lets the screen be redrawn every frame for the sweep while the
## reading underneath it is only a tenth of a second's work ten times a second.
func _sample_profile() -> void:
	var started := Time.get_ticks_usec()
	_pf_dist.clear()
	_pf_axis.clear()
	_pf_rock.clear()
	_pf_fill.clear()
	_pf_cut.clear()
	var driven := maxf(_travelled, 0.001)
	for i in PROFILE_SAMPLES + 1:
		var distance := driven * float(i) / float(PROFILE_SAMPLES)
		var at := _trail_at(distance)
		var point: Vector3 = at[0]
		_pf_dist.append(distance)
		_pf_axis.append(point.y)
		_pf_rock.append(_rock_surface_m(point.x, point.z))
		_pf_cut.append(_cut_height_at(point.x, point.z))
		# How much of the bore is standing full there. The same thirteen points
		# the face is read with, which is the coarsest read that still tells a
		# bore with a heap in the invert from a bore that has closed.
		var frame := _frame(at[1])
		var full := 0
		for uv in _probe:
			var c := _cell_of(point + frame[0] * uv.x + frame[1] * uv.y)
			if _in_box(c) and _field.mass_at(c.x, c.y, c.z) > 0.2:
				full += 1
		_pf_fill.append(float(full) / float(_probe.size()))
	_pf_ahead_dist.clear()
	_pf_ahead_axis.clear()
	_pf_ahead_rock.clear()
	var course := _course_points(
		_steer / maxf(min_turn_radius_m, 0.1), course_preview_m
	)
	var run := _travelled
	for i in course.size():
		if i > 0:
			run += course[i].distance_to(course[i - 1])
		_pf_ahead_dist.append(run)
		_pf_ahead_axis.append(course[i].y)
		_pf_ahead_rock.append(_rock_surface_m(course[i].x, course[i].z))
	# The whole trace, always, and never a span that grows with the run.
	#
	# It used to be scaled to what had been driven, because a panel two seconds in
	# was a hundred pixels to the metre and nothing in it held still. A fixed span
	# fixes that harder — nothing in it ever moves but the machine — and it buys
	# the thing this pass is actually for: the profile and the plan are now the
	# same number of pixels to the metre, so one grid division, one bore diameter
	# and one scale bar mean the same width of glass in both.
	_pf_span = float(BOX.x) * CELL
	var sum := 0.0
	for value in _pf_fill:
		sum += value
	_pf_mean_fill = sum / float(maxi(_pf_fill.size(), 1))
	var spent := float(Time.get_ticks_usec() - started) / 1000.0
	_prof_pf_ms = maxf(_prof_pf_ms, spent)
	_prof_pf_sum += spent
	_prof_pf_n += 1


## The trace unrolled: what is over the tunnel, what is under it, how deep it is
## lying and how much of it is standing open, against metres driven. The section
## and the plan are both looking down a tunnel that turns; this is the only view
## in which a dive is a line going down.
##
## At `profile_v_scale = 1` this is a true section — a metre down is a metre
## along is a metre in the plan — so the bore is drawn the same 30 px across here
## as the machine's own ring is drawn in the screen above it.
func _draw_profile() -> void:
	var size := _profile.size
	_profile.draw_rect(Rect2(Vector2.ZERO, size), HUD_SCREEN)
	if _pf_dist.size() < 2:
		return
	var font := _hud_font()
	var world_top := maxf(sand_top_m + 2.0, 0.001)
	var to_x := _px_per_m
	var to_y := size.y / world_top
	var radius := bore_diameter_m * 0.5
	var floor_px := size.y
	var surface_px := size.y - sand_top_m * to_y
	# Sand first, as one block: everything under the surface is sand until the
	# rock is drawn over it.
	_profile.draw_rect(
		Rect2(0.0, surface_px, size.x, floor_px - surface_px), CAP_SAND_FAR
	)
	var last := _pf_dist.size() - 1
	for i in _pf_dist.size():
		var x0 := _pf_dist[i] * to_x
		var x1 := (
			_pf_dist[mini(i + 1, last)] * to_x if i < last
			else x0 + _pf_span * to_x / float(PROFILE_SAMPLES)
		)
		var w := maxf(x1 - x0, 1.0)
		var rock_px := size.y - _pf_rock[i] * to_y
		_profile.draw_rect(
			Rect2(x0, rock_px, w, floor_px - rock_px), CAP_ROCK_DEEP
		)
		# The bore, to scale. Open is a hole; what has filled back up is drawn in
		# the same colour the lid gives it, from the invert up, so the muck line
		# down the tunnel is a shape and not a number.
		var crown_px := size.y - (_pf_axis[i] + radius) * to_y
		var invert_px := size.y - (_pf_axis[i] - radius) * to_y
		_profile.draw_rect(
			Rect2(x0, crown_px, w, invert_px - crown_px), Color(0.07, 0.08, 0.10)
		)
		var fill := (invert_px - crown_px) * clampf(_pf_fill[i], 0.0, 1.0)
		if fill > 0.5:
			_profile.draw_rect(
				Rect2(x0, invert_px - fill, w, fill), CAP_SPOIL_FULL
			)
	# The same grid as the plan, at the same price per division, over the reading
	# rather than under it — the profile's bands are opaque and a grid beneath
	# them would only be a grid over the sky.
	var step := grid_step_m * _px_per_m
	_screen_grid(
		_profile, size, step, grid_step_m * to_y, true
	)
	# Where the cut is standing over the tunnel: the line between what is drawn
	# in the section and what is thrown away.
	var cut_line := PackedVector2Array()
	for i in _pf_dist.size():
		cut_line.append(
			Vector2(_pf_dist[i] * to_x, size.y - _pf_cut[i] * to_y)
		)
	_profile.draw_polyline(cut_line, Color(0.45, 0.92, 1.0, 0.55), 1.0)
	# The ground ahead, and the course through it. Ahead is drawn as a band and
	# not as a line because the question the driver is asking is not where the
	# rock is but whether he is about to be in it, and a band against the bore is
	# that question answered.
	if _pf_ahead_dist.size() > 1:
		var crown := PackedVector2Array()
		var invert := PackedVector2Array()
		var last_ahead := _pf_ahead_dist.size() - 1
		for i in _pf_ahead_dist.size():
			var x := _pf_ahead_dist[i] * to_x
			if i < last_ahead:
				var next_x := _pf_ahead_dist[i + 1] * to_x
				var rock_px := size.y - _pf_ahead_rock[i] * to_y
				# The same rock, paler: ahead is a reading of the map and not of
				# the ground, and it should not be mistaken for ground crossed.
				_profile.draw_rect(
					Rect2(x, rock_px, maxf(next_x - x, 1.0), floor_px - rock_px),
					CAP_ROCK_DEEP.lerp(CAP_ROCK_THIN, 0.75)
				)
			crown.append(
				Vector2(x, size.y - (_pf_ahead_axis[i] + radius) * to_y)
			)
			invert.append(
				Vector2(x, size.y - (_pf_ahead_axis[i] - radius) * to_y)
			)
		_profile.draw_polyline(crown, COURSE_COLOUR, 2.0)
		_profile.draw_polyline(invert, COURSE_COLOUR, 2.0)
	_profile.draw_line(
		Vector2(0.0, surface_px), Vector2(size.x, surface_px),
		Color(0.95, 0.95, 1.0, 0.8), 1.0
	)
	# The same distance ticks the plan writes on the trail, on the axis they
	# belong to. Same step, same numbers, same type.
	if tick_step_m > 0.0:
		var mark := 0.0
		var index := 0
		while mark * to_x < size.x:
			var x := mark * to_x
			var labelled := index % maxi(tick_label_every, 1) == 0
			_profile.draw_line(
				Vector2(x, size.y), Vector2(x, size.y - (7.0 if labelled else 4.0)),
				HUD_TEXT if labelled else HUD_TEXT_DIM, 1.0
			)
			if labelled:
				_hud_text(
					_profile, font, Vector2(x + 3.0, size.y - 4.0),
					"%d" % int(round(mark)), HUD_TEXT_DIM
				)
			mark += tick_step_m
			index += 1
	# Heights up the left edge, so the vertical scale is stated rather than
	# implied by the surface line.
	var level := grid_step_m
	while level < world_top:
		_hud_text(
			_profile, font, Vector2(3.0, size.y - level * to_y - 3.0),
			"%d" % int(round(level)), HUD_TEXT_DIM
		)
		level += grid_step_m
	# The machine: the same symbol as the plan, at the same distance the plan
	# writes beside it, pointed at its own pitch.
	var here_x := _travelled * to_x
	_profile.draw_line(
		Vector2(here_x, 0.0), Vector2(here_x, size.y),
		Color(COURSE_COLOUR.r, COURSE_COLOUR.g, COURSE_COLOUR.b, 0.35), 1.0
	)
	_machine_symbol(
		_profile, Vector2(here_x, size.y - _pos.y * to_y),
		Vector2(cos(_pitch), -sin(_pitch) * maxf(profile_v_scale, 0.05))
	)
	_scan(_profile, size)


# --- the column screen -------------------------------------------------------


## Two ground columns, drawn to scale: where the machine is standing and what it
## will be standing in twenty metres from now. The one number a tunnel driver
## never has — how much ground is over the crown — is on it, and so is the
## boundary the whole trace is about.
##
## The only screen at its own magnification, and it says so in its caption. Its
## colours are the other screens' colours and its type is the other screens'
## type, which is what keeps it a third screen of this instrument rather than a
## fourth window.
func _draw_ruler() -> void:
	var size := _ruler.size
	_ruler.draw_rect(Rect2(Vector2.ZERO, size), HUD_SCREEN)
	var font := _hud_font()
	var top := 16.0
	var height := size.y - top - 14.0
	var world_top := maxf(sand_top_m + 2.0, 0.001)
	var to_y := height / world_top
	var base_px := top + height
	_screen_grid(_ruler, size, size.x * 2.0, grid_step_m * to_y, true, base_px)
	var radius := bore_diameter_m * 0.5
	var ahead := _pos + _forward() * 20.0
	var wide := (size.x - 24.0) * 0.5
	var columns := [
		["here", _pos.x, _pos.z, 8.0, _pos.y],
		["+20 m", ahead.x, ahead.z, 16.0 + wide, ahead.y],
	]
	for entry in columns:
		var label: String = entry[0]
		var rock_m := _rock_surface_m(entry[1], entry[2])
		var left: float = entry[3]
		var sand_px := base_px - sand_top_m * to_y
		var rock_px := base_px - rock_m * to_y
		_ruler.draw_rect(
			Rect2(left, sand_px, wide, base_px - sand_px), CAP_SAND_FAR
		)
		_ruler.draw_rect(
			Rect2(left, rock_px, wide, base_px - rock_px), CAP_ROCK_DEEP
		)
		_hud_text(_ruler, font, Vector2(left, top - 4.0), label, HUD_TEXT_DIM)
		# The bore, to scale, at the machine's own axis: the gap between the top
		# of that box and the rock band is the cover, and it is a length on the
		# screen rather than a number to be trusted.
		var axis_y: float = entry[4]
		var crown_px := base_px - (axis_y + radius) * to_y
		var invert_px := base_px - (axis_y - radius) * to_y
		_ruler.draw_rect(
			Rect2(left + wide * 0.22, crown_px, wide * 0.56, invert_px - crown_px),
			Color(0.07, 0.08, 0.10)
		)
		# Both bores are outlined — the one the machine is in with the accent, the
		# one it is about to be in dimly. Unoutlined, a black box on the dark blue
		# of deep rock is a box nobody can see, which is the one place a driver
		# most needs to see it.
		_ruler.draw_rect(
			Rect2(left + wide * 0.22, crown_px, wide * 0.56, invert_px - crown_px),
			COURSE_COLOUR if label == "here" else HUD_TEXT_DIM, false, 1.0
		)
	var surface_px := base_px - sand_top_m * to_y
	_ruler.draw_line(
		Vector2(0.0, surface_px), Vector2(size.x, surface_px),
		Color(0.95, 0.95, 1.0, 0.8), 1.0
	)
	# Only when there is room for it. The column takes the height of the screens
	# beside it, so with the plan out it can be short enough that this word lands
	# on the two column headings — and a label sitting on another label is the one
	# thing that makes a panel look unbuilt.
	if surface_px - top > 13.0:
		_hud_text(
			_ruler, font, Vector2(2.0, surface_px - 3.0), "surface",
			Color(0.95, 0.95, 1.0, 0.85)
		)
	var cut_px := base_px - _cut_y * to_y
	_ruler.draw_line(
		Vector2(0.0, cut_px), Vector2(size.x, cut_px),
		Color(0.45, 0.92, 1.0, 0.7), 1.0
	)
	_hud_text(_ruler, font, Vector2(2.0, cut_px - 3.0), "cut", COURSE_COLOUR)
	_hud_text(
		_ruler, font, Vector2(2.0, size.y - 3.0),
		"%.1f m deep   cover %.1f m" % [
			sand_top_m - _pos.y,
			maxf(sand_top_m - (_pos.y + radius), 0.0),
		],
		HUD_TEXT
	)
	_scan(_ruler, size)


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
	# The instrument stands in every view. It could not before: the plan was a
	# second camera on the world and was only ever shown beside the section. Now
	# that every screen is a drawing of the record, the chase view keeps the one
	# thing that says where the machine is on the run.
	_layout_instrument()
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
		"cut: %s   worked ground: %s" % [
			"rides the tunnel" if cut_follows_tunnel else "flat plane",
			"marked" if mark_disturbed else "off",
		],
		"%d fps   cut %.2f / sim %.2f / mesh %.2f ms   map %.2f / lid %.2f ms" % [
			Engine.get_frames_per_second(),
			_prof_cut_ms, _prof_sim_ms, _prof_mesh_ms,
			_prof_map_ms, _prof_cap_ms,
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
			plan_screen = not plan_screen
			if plan_screen:
				_refresh_plan_map()
			_layout_instrument()
		KEY_B:
			profile_screen = not profile_screen
			if profile_screen:
				_sample_profile()
			_layout_instrument()
		KEY_H:
			# The whole instrument, case and all. `V` and `B` are still there for
			# one screen at a time, but a driver who wants the picture of the
			# ground and nothing else should not have to press two keys for it.
			instrument = not instrument
			_layout_instrument()
		KEY_F:
			# Both cuts are built out of the same map, so this is one rebuild and
			# not a second code path: flat mode simply writes the machine's own
			# plane into every column.
			cut_follows_tunnel = not cut_follows_tunnel
			_cut_cell = -9999
			_update_cut(true)
		KEY_T:
			mark_disturbed = not mark_disturbed
			# The plan marks worked ground with the same rust and off the same
			# switch, so the two pictures agree about what has been dug.
			_refresh_plan_map()
			_update_cut(true)
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
	# The cut has to be where the knob says it is over the machine itself, within
	# the slack the hysteresis and the map's own metre are allowed, and it may
	# never sink below the invert — a cut under the machine draws the machine
	# standing on top of the ground.
	var wanted_cut := _pos.y + cut_above_axis_m
	if absf(_cut_y - wanted_cut) > CELL * float(CUT_HYSTERESIS_CELLS + 1):
		faults.append(
			"cut %.1f m drifted from the %.1f m it was asked for"
			% [_cut_y, wanted_cut]
		)
	if _cut_y < _pos.y - bore_diameter_m * 0.5:
		faults.append(
			"cut %.1f m is under the machine at %.1f m" % [_cut_y, _pos.y]
		)
	# The whole point of the surface. A run that climbed and dived and came out
	# with one height everywhere is a flat plane wearing a map, and the driver
	# would lose his tunnel behind him exactly as before.
	var cut_low := 1.0e9
	var cut_high := -1.0e9
	var followed := 0
	for col in _cut_map_cell.size():
		var height := _cut_pixels[col * 4]
		cut_low = minf(cut_low, height)
		cut_high = maxf(cut_high, height)
		if _cut_owner_w[col] > 0.0:
			followed += 1
	if cut_follows_tunnel and _autopilot_dives and cut_high - cut_low < 1.0:
		faults.append(
			"the cut never left %.1f m through a run that climbed and dived"
			% cut_low
		)
	if mark_disturbed and _dug_cells <= 0:
		faults.append("nothing was marked as ground the machine had been through")
	# The plan is a drawing now and not a render, so nothing about it fails
	# loudly: a plan built from an empty map is a clean black panel and the run
	# would still pass. What it is made of has to be counted.
	var worked_columns := 0
	for col in CUT_MAP.x * CUT_MAP.y:
		if _cut_pixels[col * 4 + 1] <= _cut_pixels[col * 4 + 2]:
			worked_columns += 1
	if instrument and plan_screen:
		if _plan_texture == null:
			faults.append("the plan screen has no ground map")
		elif worked_columns <= 0 and _dug_cells > 0:
			faults.append(
				"%d cells were dug and the plan has no worked ground on it"
				% _dug_cells
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
	print(
		"SHIELD: cut map — worst write %.2f ms every %.1f m, worst lid chunk %.2f ms, %d chunks still owed"
		% [_prof_map_ms, CUT_MAP_STEP_M, _prof_cap_ms, _cap_pending.size()]
	)
	# What the instrument costs, against the 0.40 ms a frame the plan cost while
	# it was a second render of the world. Both of these are paid at `instrument_hz`
	# and not per frame, so divide by ten before comparing them to anything.
	print(
		"SHIELD: instrument at %.0f Hz — plan map %.2f mean / %.2f worst ms over %d refreshes, profile sample %.2f / %.2f ms over %d, %.1f px/m, %d of %d plan columns worked"
		% [
			instrument_hz,
			_prof_plan_sum / float(maxi(_prof_plan_n, 1)), _prof_plan_ms,
			_prof_plan_n,
			_prof_pf_sum / float(maxi(_prof_pf_n, 1)), _prof_pf_ms, _prof_pf_n,
			_px_per_m, worked_columns, CUT_MAP.x * CUT_MAP.y,
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
		"SHIELD: cut over the machine at %.1f m (%.1f m over the axis), lid %d chunks; in that one layer — %d open, %d lining, %d rock of %d cells"
		% [
			_cut_y, _cut_y - _pos.y, _cap_chunks.size(),
			open, lining, rock_cells, slab.size(),
		]
	)
	# What the section actually shows, which is not the flat layer above: the lid
	# reads a different cell in every column, so the three states the driver is
	# meant to tell apart have to be counted the way he sees them.
	var seen_open := 0
	var seen_buried := 0
	for col in _cut_map_cell.size():
		var cell := _cut_map_cell[col]
		@warning_ignore("integer_division")
		var row := col / CUT_MAP.x
		var x0 := (col - row * CUT_MAP.x) << CUT_MAP_SHIFT
		var z0 := row << CUT_MAP_SHIFT
		for dz in CUT_MAP_STEP:
			for dx in CUT_MAP_STEP:
				var index := (
					(cell * BOX.z + z0 + dz) * BOX.x + x0 + dx
				)
				if _dug[index] == 0:
					continue
				if _field.mass_at(x0 + dx, cell, z0 + dz) <= RENDER_MIN_FILL:
					seen_open += 1
				else:
					seen_buried += 1
	print(
		"SHIELD: cut surface %.1f..%.1f m over %d of %d map columns; %d cells dug, and at the cut the driver sees %d open and %d buried"
		% [
			cut_low, cut_high, followed, _cut_map_cell.size(),
			_dug_cells, seen_open, seen_buried,
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
