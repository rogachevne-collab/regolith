extends Node3D
## Step-0 feel demo: the GAME cable solver (XpbdCableRopeSolver, not the plugin
## node) lifting a real 300 kg rover RigidBody. Winch the rope in and it pulls
## the rover up; pay out and it lowers. This is the same solver the game runs,
## with the rover end mass-coupled.
##
## Controls: [ pay out / ] reel in | R reset | RMB + WASD/QE fly (Shift fast)

const Solver := preload("res://scripts/simulation/projection/xpbd_cable_rope_solver.gd")
const CableCurve := preload("res://scripts/simulation/projection/cable_curve_util.gd")
const FlyCamera := preload("res://addons/ropes/demos/fly_camera.gd")

const ANCHOR := Vector3(0, 9, 0)
const ROVER_START := Vector3(0, 0.4, 0)
const ROVER_MASS := 300.0
const REST_START := 8.0
const REST_MIN := 2.5
const REST_MAX := 12.0
const WINCH_SPEED := 1.3

var _rover: RigidBody3D
var _state: Dictionary
var _rest := REST_START
var _tube: MeshInstance3D
var _hud: Label
var _cam: Camera3D
var _y0 := 0.0


func _ready() -> void:
	_make_environment()
	_make_anchor_post()
	_make_rover()
	_make_tube()
	_make_camera()
	_make_hud()
	call_deferred("_wire")


func _wire() -> void:
	_state = Solver.create_state(
		ANCHOR, _hook(), _rest, Vector3.UP, get_world_3d().direct_space_state
	)
	_y0 = _rover.global_position.y


func _physics_process(dt: float) -> void:
	if _state.is_empty():
		return
	var dir := 0.0
	if Input.is_key_pressed(KEY_BRACKETRIGHT):
		dir -= 1.0
	if Input.is_key_pressed(KEY_BRACKETLEFT):
		dir += 1.0
	if dir != 0.0:
		_rest = clampf(_rest + dir * WINCH_SPEED * dt, REST_MIN, REST_MAX)
	var result: Dictionary = Solver.step(
		_state, ANCHOR, _hook(), _rest, Vector3(0, -9.8, 0), dt,
		get_world_3d().direct_space_state, true,
		null, _rover, {}, {}, 0.0, true,
		0.0, ROVER_MASS)          # couple_mass_b = rover → the rover end lifts
	_last_tension = float(result.get("tension_n", 0.0))


var _last_tension := 0.0


func _process(_dt: float) -> void:
	if _state.is_empty():
		return
	var path: PackedVector3Array = Solver.path(_state)
	if path.size() >= 2:
		_tube.mesh = CableCurve.build_tube_mesh(path, 0.07)
	_hud.text = "\n".join([
		"[ pay out   ] reel in   R reset   RMB+WASD fly",
		"rope %5.2f m   rover lifted %6.2f m   tension %7.0f N  (weight %.0f N)" % [
			_rest, _rover.global_position.y - _y0, _last_tension, ROVER_MASS * 9.8],
	])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_R:
			_reset()


func _reset() -> void:
	_rover.global_position = ROVER_START
	_rover.rotation = Vector3.ZERO
	_rover.linear_velocity = Vector3.ZERO
	_rover.angular_velocity = Vector3.ZERO
	_rest = REST_START
	_state = Solver.create_state(
		ANCHOR, _hook(), _rest, Vector3.UP, get_world_3d().direct_space_state
	)


func _hook() -> Vector3:
	return _rover.global_position + Vector3(0, 0.35, 0)


# --- scene ------------------------------------------------------------------


func _make_rover() -> void:
	_rover = RigidBody3D.new()
	_rover.mass = ROVER_MASS
	_rover.position = ROVER_START
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.6, 0.7, 2.4)
	cs.shape = shape
	_rover.add_child(cs)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = shape.size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.2, 0.18)
	mesh.material = mat
	visual.mesh = mesh
	_rover.add_child(visual)
	add_child(_rover)


func _make_anchor_post() -> void:
	# A visible fixed point the rope hangs from.
	var post := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.3, 0.3, 0.3)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.7, 0.2)
	mesh.material = mat
	post.mesh = mesh
	post.position = ANCHOR
	add_child(post)


func _make_tube() -> void:
	_tube = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.85, 0.25)   # bright so the rope reads
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.5, 0.1)
	mat.emission_energy_multiplier = 0.4
	_tube.material_override = mat
	add_child(_tube)


func _make_camera() -> void:
	_cam = FlyCamera.new()
	add_child(_cam)
	# Frame the whole column from the floor to the anchor so the rope is a
	# clear line the rover climbs.
	_cam.look_at_from_position(Vector3(11, 5.5, 13), Vector3(0, 4.5, 0), Vector3.UP)


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
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(40, 1, 40)
	cs.shape = shape
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	var floor_visual := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.33, 0.31)
	plane.material = mat
	floor_visual.mesh = plane
	floor_body.add_child(floor_visual)
	add_child(floor_body)
