extends Node3D
# Gate 5 bench: the three things a rope has to do before it is a feature.
#
#   1. Lie on ground that has no analytic shape. The floor here is a concave
#      trimesh, the same class of collider a voxel planet's crust is: not a
#      box, not a plane, no closed form. It reaches the solver as one contact
#      plane per particle per tick (XPBDRope.local_planes).
#   2. Pay out and reel in without being rebuilt — Rope3D.length is hot.
#   3. Lift something heavy. The rover is a 300 kg RigidBody3D on the rope's
#      B end, so that end is mass-coupled: the rope's own constraints have to
#      hold the rover up, and what they spend is handed back to it. A
#      kinematic pin cannot do this at all — it makes the rope believe it is
#      tied to a nail.
#
# Controls: UP/DOWN piston | [ ] winch out/in | R reset
#           RMB hold + WASD/QE fly (Shift fast, wheel speed)

const RopeScript := preload("res://addons/ropes/nodes/rope_3d.gd")
const FlyCamera := preload("res://addons/ropes/demos/fly_camera.gd")

const TERRAIN_SIZE := 40.0
const TERRAIN_CELLS := 48

const ROVER_MASS := 300.0
const ROVER_SIZE := Vector3(1.6, 0.7, 2.4)
const ROVER_START := Vector3(0.0, 0.0, 0.0)

const PISTON_MIN_Y := 4.0
const PISTON_MAX_Y := 9.0
const PISTON_SPEED := 1.6      # m/s
const WINCH_SPEED := 1.2       # m/s
const ROPE_MIN_M := 0.6
const ROPE_MAX_M := 12.0
const ROPE_START_M := 7.6

var _piston: AnimatableBody3D
var _rover: RigidBody3D
var _lift_rope: Node3D
var _drape_rope: Node3D
var _cam: Camera3D
var _hud: Label


func _ready() -> void:
	_make_environment()
	_make_terrain()
	_make_gantry()
	_make_rover()
	_make_ropes()
	_make_camera()
	_make_hud()


func _physics_process(dt: float) -> void:
	var piston_dir := 0.0
	if Input.is_key_pressed(KEY_UP):
		piston_dir += 1.0
	if Input.is_key_pressed(KEY_DOWN):
		piston_dir -= 1.0
	if piston_dir != 0.0:
		var y: float = clampf(
			_piston.position.y + piston_dir * PISTON_SPEED * dt,
			PISTON_MIN_Y,
			PISTON_MAX_Y
		)
		_piston.position.y = y

	var winch_dir := 0.0
	if Input.is_key_pressed(KEY_BRACKETRIGHT):
		winch_dir += 1.0
	if Input.is_key_pressed(KEY_BRACKETLEFT):
		winch_dir -= 1.0
	if winch_dir != 0.0:
		# The whole point of gate 5: assigning length is a winch, not a
		# rebuild. Shape, motion and the rover on the end all survive it.
		_lift_rope.length = clampf(
			_lift_rope.length + winch_dir * WINCH_SPEED * dt, ROPE_MIN_M, ROPE_MAX_M
		)


func _process(_dt: float) -> void:
	var tension := 0.0
	for i in _lift_rope.get_particle_count() - 1:
		tension = maxf(tension, _lift_rope.get_segment_tension(i))
	_hud.text = "\n".join([
		"UP/DOWN piston   [ ] winch   R reset   RMB+WASD fly",
		"rope   %5.2f m (rest)   %5.2f m (hanging)" % [
			_lift_rope.length, _rope_span(_lift_rope)
		],
		"rover  %5.2f m up   %5.0f kg   %s" % [
			_rover.global_position.y - ROVER_START.y,
			ROVER_MASS,
			"OFF THE GROUND" if _rover.global_position.y > ROVER_START.y + 0.25 else "down",
		],
		"peak tension %7.1f N   (rover weight %.0f N)" % [
			tension, ROVER_MASS * _gravity_magnitude()
		],
	])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_R:
			_reset()


func _reset() -> void:
	_piston.position.y = PISTON_MAX_Y - 1.0
	_rover.global_position = _rover_spawn()
	_rover.rotation = Vector3.ZERO
	_rover.linear_velocity = Vector3.ZERO
	_rover.angular_velocity = Vector3.ZERO
	_lift_rope.length = ROPE_START_M
	_lift_rope.rebuild()
	_drape_rope.rebuild()


# --- world -------------------------------------------------------------------


## Ground with no analytic form: a displaced grid committed as a trimesh, the
## nearest stand-in for a marching-cubes crust that a demo can build in code.
## If a rope lies on this, it lies on a voxel planet for the same reason.
func _make_terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in TERRAIN_CELLS:
		for x in TERRAIN_CELLS:
			var p00 := _terrain_point(x, z)
			var p10 := _terrain_point(x + 1, z)
			var p01 := _terrain_point(x, z + 1)
			var p11 := _terrain_point(x + 1, z + 1)
			# Clockwise seen from above: Godot's front faces wind clockwise,
			# and a ConcavePolygonShape3D only collides on its front. Wind
			# this the other way and everything quietly falls through a floor
			# that still renders perfectly.
			st.add_vertex(p00)
			st.add_vertex(p11)
			st.add_vertex(p01)
			st.add_vertex(p00)
			st.add_vertex(p10)
			st.add_vertex(p11)
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.33, 0.31)
	# Two-sided: a demo that silently disappears because a winding order got
	# flipped teaches the wrong lesson about the rope.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	add_child(visual)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	add_child(body)


func _terrain_point(x: int, z: int) -> Vector3:
	var step := TERRAIN_SIZE / float(TERRAIN_CELLS)
	var wx := x * step - TERRAIN_SIZE * 0.5
	var wz := z * step - TERRAIN_SIZE * 0.5
	return Vector3(wx, _terrain_height(wx, wz), wz)


func _terrain_height(wx: float, wz: float) -> float:
	# Flat under the rover so the lift starts from a known height, lumpy
	# everywhere else so the drape has something to disagree with.
	var lumps := 0.9 * sin(wx * 0.42) * cos(wz * 0.31) + 0.35 * sin(wx * 1.1 + wz * 0.7)
	var flatten: float = clampf((Vector2(wx, wz).length() - 3.0) / 4.0, 0.0, 1.0)
	return lumps * flatten


func _make_gantry() -> void:
	var beam_y := PISTON_MAX_Y + 0.6
	for side: float in [-2.2, 2.2]:
		_add_static_box(
			Vector3(side, beam_y * 0.5, 0.0),
			Vector3(0.35, beam_y, 0.35),
			Color(0.32, 0.35, 0.42)
		)
	_add_static_box(
		Vector3(0.0, beam_y, 0.0), Vector3(5.0, 0.35, 0.35), Color(0.32, 0.35, 0.42)
	)
	# The piston head is kinematic — an AnimatableBody3D, not a rigid body —
	# so the rope pins to it. That is the asymmetry the bench is about: a pin
	# on the crane, a mass on the load.
	_piston = AnimatableBody3D.new()
	_piston.position = Vector3(0.0, PISTON_MAX_Y - 1.0, 0.0)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 0.5, 0.6)
	cs.shape = shape
	_piston.add_child(cs)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = shape.size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.55, 0.2)
	mesh.material = mat
	visual.mesh = mesh
	_piston.add_child(visual)
	var hook := Marker3D.new()
	hook.name = "Hook"
	hook.position = Vector3(0.0, -0.3, 0.0)
	_piston.add_child(hook)
	add_child(_piston)


func _make_rover() -> void:
	_rover = RigidBody3D.new()
	_rover.mass = ROVER_MASS
	# Local, not global: the node is not in the tree yet, and asking an
	# orphan for its global transform is how you get a silent identity.
	_rover.position = _rover_spawn()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = ROVER_SIZE
	cs.shape = shape
	_rover.add_child(cs)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = ROVER_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.2, 0.18)
	mesh.material = mat
	visual.mesh = mesh
	_rover.add_child(visual)
	# The rope grabs a hook bolted to the chassis, not the chassis origin —
	# an off-centre pull is what makes a lifted body swing and tilt, and it is
	# the case worth watching.
	#
	# The lug stands proud of the hull, the way a real lifting eye does, and
	# for the same reason: an attachment flush with a face means the rope
	# leaves the body tangent to it, so the first segment grazes the surface
	# on every swing and the tube reads as sunk into the block. Contact cannot
	# fix that — the geometry is asking for it.
	var lug_h := 0.22
	var hook := Marker3D.new()
	hook.name = "Hook"
	hook.position = Vector3(0.0, ROVER_SIZE.y * 0.5 + lug_h, -0.5)
	_rover.add_child(hook)
	var lug := MeshInstance3D.new()
	var lug_mesh := BoxMesh.new()
	lug_mesh.size = Vector3(0.12, lug_h, 0.12)
	var lug_mat := StandardMaterial3D.new()
	lug_mat.albedo_color = Color(0.75, 0.55, 0.2)
	lug_mesh.material = lug_mat
	lug.mesh = lug_mesh
	lug.position = hook.position - Vector3(0.0, lug_h * 0.5, 0.0)
	_rover.add_child(lug)
	add_child(_rover)


func _rover_spawn() -> Vector3:
	return ROVER_START + Vector3(0.0, ROVER_SIZE.y * 0.5 + 0.05, 0.0)


func _make_ropes() -> void:
	_lift_rope = RopeScript.new()
	# Seeded slack: the hook is ~7 m above the rover, so a shorter rope would
	# start the scene already violating its own constraint by metres and the
	# first tick would fire the rover into the gantry. Slack at rest, taut by
	# winching — that is the order the bench is meant to show.
	_lift_rope.length = ROPE_START_M
	_lift_rope.segments_per_meter = 5.0
	_lift_rope.mass_per_meter = 0.6
	_lift_rope.radius = 0.035
	# A 300 kg load on 0.6 kg/m of rope is a 500:1 mass ratio, and force has
	# to travel the whole chain within a substep for the rope to feel rigid.
	# Budget is how that is bought; if the rope looks like elastic, this is
	# the knob, not the compliance.
	_lift_rope.substeps = 16
	_lift_rope.iterations = 4
	add_child(_lift_rope)
	_lift_rope.anchor_a = _lift_rope.get_path_to(_piston.get_node("Hook"))
	_lift_rope.anchor_b = _lift_rope.get_path_to(_rover.get_node("Hook"))

	# Free rope, no anchors, dropped across the lumps: the concave contact on
	# its own, with nothing holding it up.
	_drape_rope = RopeScript.new()
	_drape_rope.position = Vector3(-7.0, 3.0, 4.0)
	_drape_rope.length = 6.0
	_drape_rope.segments_per_meter = 6.0
	_drape_rope.radius = 0.04
	_drape_rope.friction = 0.8
	_drape_rope.lay_direction = Vector3.RIGHT
	add_child(_drape_rope)


# --- presentation ------------------------------------------------------------


func _rope_span(rope: Node3D) -> float:
	var points: PackedVector3Array = rope.get_particles()
	var out := 0.0
	for i in points.size() - 1:
		out += points[i].distance_to(points[i + 1])
	return out


func _gravity_magnitude() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))


func _make_camera() -> void:
	_cam = FlyCamera.new()
	add_child(_cam)
	_cam.look_at_from_position(Vector3(7.5, 4.0, 9.5), Vector3(0, 3.0, 0), Vector3.UP)


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
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _add_static_box(at: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material = mat
	visual.mesh = mesh
	body.add_child(visual)
	body.position = at
	add_child(body)
