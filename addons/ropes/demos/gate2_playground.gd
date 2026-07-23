extends Node3D
# Gate 2 visual playground: ropes with different parameters, hanging weights,
# poke them with the mouse. Rope color shows tension (green -> red).
#
# Controls: LMB poke | RMB hold + WASD/QE fly (Shift fast, wheel speed)
#           +/- poke impulse | G gravity Moon/Earth | R reset

const RopeScript := preload("res://addons/ropes/nodes/rope_3d.gd")
const FlyCamera := preload("res://addons/ropes/demos/fly_camera.gd")

# The collision demos derive their geometry from these, so a rope can never
# again end up hanging politely NEXT to the obstacle it is meant to test.
const CUBE_POS := Vector3(-10, 0.75, -4)
const CUBE_SIDE := 1.5
const FREE_CUBE_OFFSET := Vector3(0, 0, 4.0)

var _ropes: Array[Node3D] = []
var _weights: Array[Dictionary] = []  # {rope, box}
var _poke_impulse := 5.0
var _cam: Camera3D
var _hud: Label
var _earth_gravity := false

var _configs := [
	{name = "taut span 4.05/4", len = 4.05, a = Vector3(-12, 5, 0), b = Vector3(-8, 5, 0)},
	{name = "slack span 6/4", len = 6.0, a = Vector3(-6.5, 5, 0), b = Vector3(-2.5, 5, 0)},
	{name = "weight 20 kg", len = 3.5, a = Vector3(0, 6, 0), end_mass = 20.0},
	{name = "stretchy 0.005 m/N + 10 kg", len = 3.5, a = Vector3(2.5, 6, 0),
			end_mass = 10.0, compliance = 0.005},
	{name = "long 12 m + 5 kg", len = 12.0, a = Vector3(6, 13.5, 0), end_mass = 5.0},
	# Same rope three times, one knob apart: poke all three and watch how
	# they differ. Vacuum rings forever, internal damping kills the wobble
	# but not the swing, drag kills everything (ADR 0003).
	{name = "vacuum (damp 0)", len = 3.5, a = Vector3(9, 6, 0), end_mass = 5.0,
			damping = 0.0},
	{name = "internal damp 2.0", len = 3.5, a = Vector3(11, 6, 0), end_mass = 5.0,
			damping = 2.0},
	{name = "air drag 1.0", len = 3.5, a = Vector3(13, 6, 0), end_mass = 5.0,
			damping = 0.0, drag = 1.0},
	# Collision row (gate 3). Geometry derived from CUBE_POS/CUBE_SIDE in
	# _ready(); see _add_collision_configs().
]


func _ready() -> void:
	_add_collision_configs()
	_make_environment()
	_make_camera()
	_make_hud()
	_build_ropes()


# Ropes that actually touch the cube: a drape resting across its top edges,
# and one dropped straight onto it to pile up. Both anchored to the cube's
# real geometry, not to hand-typed coordinates.
func _add_collision_configs() -> void:
	# Every offset below is relative to the cube's CENTRE, so `half` is the
	# top face. Mixing an absolute height into a relative offset is exactly
	# how the first version of this demo ended up hanging politely next to
	# the cube instead of touching it.
	var half := CUBE_SIDE * 0.5
	_configs.append({
		name = "draped over the cube",
		len = 5.5,
		a = CUBE_POS + Vector3(-half - 1.05, half + 0.9, 0),
		b = CUBE_POS + Vector3(half + 1.05, half + 0.9, 0),
		friction = 0.8,
		resolution = 9.0,
	})
	# The same rope again on its own cube, but FREE: laid flat just above the
	# box and dropped, so it drapes itself. Side by side with the anchored
	# one this is the honest comparison — same length, same resolution, only
	# the anchors differ.
	# Length chosen so the tails hang clear of the floor: once a tail lands,
	# the rope is held by two surfaces at once and stops being a clean read
	# of "does it stay on the cube".
	_configs.append({
		name = "the same, free (no anchors)",
		len = 3.6,
		pos = CUBE_POS + FREE_CUBE_OFFSET + Vector3(-1.8, half + 0.2, 0),
		lay_direction = Vector3.RIGHT,
		friction = 0.8,
		resolution = 9.0,
	})


func _build_ropes() -> void:
	for entry in _weights:
		entry.box.queue_free()
	for rope in _ropes:
		rope.queue_free()
	for child in get_children():
		if child is Marker3D or child is Label3D:
			child.queue_free()
	_ropes.clear()
	_weights.clear()

	for cfg: Dictionary in _configs:
		var marker_a: Marker3D = null
		if cfg.has("a"):
			marker_a = Marker3D.new()
			marker_a.position = cfg.a
			add_child(marker_a)
		var marker_b: Marker3D = null
		if cfg.has("b"):
			marker_b = Marker3D.new()
			marker_b.position = cfg.b
			add_child(marker_b)

		var rope: Node3D = RopeScript.new()
		rope.length = cfg.len
		# Collision demos run finer: contact is enforced at particles, so
		# spacing has to stay within a few radii or the rendered tube visibly
		# cuts a sharp corner (ADR 0006). Not FREE though — measured, a
		# 77-segment rope against two colliders costs 5.8 ms per step in the
		# GDScript reference, a third of a 60 Hz frame for one rope. 9/m is
		# the compromise until the native core lands.
		rope.segments_per_meter = cfg.get("resolution", 5.0)
		rope.radius = 0.035
		rope.mass_per_meter = 0.5
		rope.damping = cfg.get("damping", 0.5)
		rope.drag = cfg.get("drag", 0.0)
		rope.stretch_compliance = cfg.get("compliance", 0.0)
		rope.end_mass = cfg.get("end_mass", 0.0)
		rope.friction = cfg.get("friction", 0.6)
		rope.lay_direction = cfg.get("lay_direction", Vector3.DOWN)
		if marker_a != null:
			rope.anchor_a = marker_a.get_path()
		else:
			rope.position = cfg.pos
		if marker_b != null:
			rope.anchor_b = marker_b.get_path()
		add_child(rope)
		_ropes.append(rope)

		if cfg.get("end_mass", 0.0) > 0.0:
			var box := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			var side: float = 0.18 * pow(cfg.end_mass, 1.0 / 3.0)
			mesh.size = Vector3.ONE * side
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.75, 0.55, 0.25)
			mesh.material = mat
			box.mesh = mesh
			add_child(box)
			_weights.append({rope = rope, box = box})

		var label := Label3D.new()
		label.text = cfg.name
		label.position = cfg.get("a", cfg.get("pos", Vector3.ZERO)) + Vector3(0, 0.5, 0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 40
		label.pixel_size = 0.004
		add_child(label)


func _process(_dt: float) -> void:
	for entry in _weights:
		var pts: PackedVector3Array = entry.rope.get_render_particles()
		if not pts.is_empty():
			entry.box.global_position = pts[pts.size() - 1]
	var g_name := "Earth 9.81 + air" if _earth_gravity else "Moon 1.62, vacuum"
	_hud.text = ("poke impulse: %.1f N*s    gravity: %s    "
			+ "[LMB poke  RMB+WASD/QE fly (Shift fast)  +/- force  G gravity  R reset]") \
			% [_poke_impulse, g_name]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_poke(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_EQUAL, KEY_KP_ADD:
				_poke_impulse = minf(_poke_impulse * 1.5, 100.0)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_poke_impulse = maxf(_poke_impulse / 1.5, 0.5)
			KEY_G:
				_toggle_gravity()
			KEY_R:
				_build_ropes.call_deferred()


# Applied live, without re-seeding: the ropes keep their shape and motion
# and simply start falling under a different pull, which is the point.
#
# This switches the ENVIRONMENT, not just the number. Earth gravity comes
# with air, and that matters: internal fibre friction barely touches the
# long-wavelength swing of a weighted rope (ADR 0003), so in vacuum the
# envelope decays with a half-life around eleven seconds — measured. On the
# Moon the amplitude is small enough not to notice; at 9.81 it reads as
# "never settles". Air is what actually stops a swinging rope on Earth.
func _toggle_gravity() -> void:
	_earth_gravity = not _earth_gravity
	var g := Vector3(0, -9.81, 0) if _earth_gravity else Vector3(0, -1.62, 0)
	for rope in _ropes:
		rope.use_project_gravity = false
		rope.gravity = g
		rope.drag = 0.6 if _earth_gravity else 0.0


func _poke(mouse_pos: Vector2) -> void:
	var origin := _cam.project_ray_origin(mouse_pos)
	var dir := _cam.project_ray_normal(mouse_pos)
	var best_dist := 0.45
	var best_rope: Node3D = null
	var best_index := -1
	for rope in _ropes:
		var pts: PackedVector3Array = rope.get_particles()
		for i in pts.size():
			var to := pts[i] - origin
			var t := to.dot(dir)
			if t <= 0.0:
				continue
			var d := (to - dir * t).length()
			if d < best_dist:
				best_dist = d
				best_rope = rope
				best_index = i
	if best_rope != null:
		best_rope.apply_impulse(best_index, dir * _poke_impulse)


func _make_camera() -> void:
	_cam = FlyCamera.new()
	add_child(_cam)
	# Start on the collision demos — that is the live gate. Fly out with
	# RMB+WASD for the rest of the row.
	# Both cubes framed with the full length of both ropes: the drape profile
	# is what needs judging, and the hanging tails are most of the evidence.
	_cam.look_at_from_position(CUBE_POS + Vector3(5.0, 4.5, 12.0),
			CUBE_POS + Vector3(0, 0.4, 2.0), Vector3.UP)


func _make_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 8)
	layer.add_child(_hud)


func _make_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(50, 50)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.35, 0.38)
	plane.material = mat
	floor_mesh.mesh = plane
	add_child(floor_mesh)
	var floor_body := StaticBody3D.new()
	var floor_cs := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(50, 1, 50)
	floor_cs.shape = floor_shape
	floor_body.add_child(floor_cs)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)
	_make_cube(CUBE_POS, CUBE_SIDE)
	_make_cube(CUBE_POS + FREE_CUBE_OFFSET, CUBE_SIDE)


func _make_cube(at: Vector3, side: float) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * side
	cs.shape = shape
	body.add_child(cs)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * side
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.42, 0.32)
	mesh.material = mat
	visual.mesh = mesh
	body.add_child(visual)
	body.position = at
	add_child(body)
