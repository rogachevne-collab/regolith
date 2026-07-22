extends Node3D
# Spike B (throwaway): frame ordering and impulse coupling with Jolt.
# Answers:
#  T1 - do impulses applied in _physics_process integrate on the same tick
#  T2 - does an XPBD chain coupled via impulses hold a hanging body stably
#  T3 - does a rope-coupled body ever sleep
#  T4 - cost of 1000 ray / 1000 sphere queries from _physics_process
#  T5 - interleaving of _physics_process vs _integrate_forces

const SEGMENTS := 3
const SEG_REST := 0.5
const ITERS := 20
const ANCHOR := Vector3(0, 4, 0)
const ATTACH_LOCAL := Vector3(0, 0.2, 0)
const BODY_MASS := 10.0
const PARTICLE_MASS := 0.05
const ROPE_START_TICK := 60
const QUERY_TICK := 400
const END_TICK := 900
const IMPULSE_EPS := 1e-4

var body: RigidBody3D
var gravity: float = 9.8
var p: Array[Vector3] = []
var p_prev: Array[Vector3] = []
var inv_m: Array[float] = []
var tick := 0
var events: Array[String] = []
var rope_active := false
var v_at_impulse := Vector3.ZERO
var pos_at_impulse := Vector3.ZERO
var last_imp_len := 0.0
var sleep_ticks := 0
var impulses_applied := 0


func _ready() -> void:
	gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	_make_floor()
	_make_body()
	print("SPIKE_B|setup engine=", ProjectSettings.get_setting("physics/3d/physics_engine"),
			" gravity=", gravity, " tick_hz=", Engine.physics_ticks_per_second)


func _make_floor() -> void:
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)


func _make_body() -> void:
	body = RigidBody3D.new()
	body.set_script(preload("res://addons/ropes/spikes/spike_b_body.gd"))
	body.mass = BODY_MASS
	body.gravity_scale = 0.0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 0.4, 0.4)
	cs.shape = box
	body.add_child(cs)
	body.position = Vector3(0, 2.6, 0)
	add_child(body)


func note_event(tag: String) -> void:
	if events.size() < 16:
		events.append("%d:%s" % [Engine.get_physics_frames(), tag])


func _physics_process(dt: float) -> void:
	tick += 1
	note_event("physics_process")

	if tick == 6:
		print("SPIKE_B|T5 interleave: ", " | ".join(events))
	elif tick == 30:
		v_at_impulse = body.linear_velocity
		pos_at_impulse = body.global_position
		body.apply_central_impulse(Vector3(5, 0, 0))
		print("SPIKE_B|T1 tick30 pre: v.x=%.4f pos.x=%.4f" % [v_at_impulse.x, pos_at_impulse.x])
	elif tick == 31:
		var dv := body.linear_velocity.x - v_at_impulse.x
		var dx := body.global_position.x - pos_at_impulse.x
		print("SPIKE_B|T1 tick31: dv=%.4f (expect 0.5 if same-tick) dx=%.5f (expect ~%.5f)"
				% [dv, dx, 0.5 * dt])
	elif tick == ROPE_START_TICK:
		_start_rope()

	if rope_active:
		_rope_step(dt)
		if body.sleeping:
			sleep_ticks += 1
		if tick % 60 == 0:
			_log_status()

	if tick == QUERY_TICK:
		_measure_queries()

	if tick >= END_TICK:
		_summary()
		get_tree().quit()


func _start_rope() -> void:
	rope_active = true
	body.linear_velocity = Vector3.ZERO
	body.global_position = Vector3(0, 2.6, 0)
	body.gravity_scale = 1.0
	var attach := body.to_global(ATTACH_LOCAL)
	p.clear()
	p_prev.clear()
	for i in SEGMENTS + 1:
		p.append(ANCHOR.lerp(attach, float(i) / SEGMENTS))
	p_prev = p.duplicate()
	inv_m = [0.0, 1.0 / PARTICLE_MASS, 1.0 / PARTICLE_MASS, 1.0 / BODY_MASS]
	print("SPIKE_B|rope started, slack: dist=%.3f rest=%.3f" % [ANCHOR.distance_to(attach), SEGMENTS * SEG_REST])


func _rope_step(dt: float) -> void:
	var attach_world := body.to_global(ATTACH_LOCAL)
	p[3] = attach_world
	p_prev[3] = attach_world
	for i in [1, 2]:
		var vel := (p[i] - p_prev[i]) / dt
		vel *= 0.995
		vel.y -= gravity * dt
		p_prev[i] = p[i]
		p[i] += vel * dt

	for _it in ITERS:
		for s in SEGMENTS:
			var d := p[s + 1] - p[s]
			var seg_len := d.length()
			if seg_len < 1e-9:
				continue
			var c := seg_len - SEG_REST
			if c <= 0.0:
				continue
			var w := inv_m[s] + inv_m[s + 1]
			if w == 0.0:
				continue
			var corr := d / seg_len * (c / w)
			p[s] += corr * inv_m[s]
			p[s + 1] -= corr * inv_m[s + 1]

	var imp := (p[3] - attach_world) * BODY_MASS / dt
	last_imp_len = imp.length()
	if last_imp_len > IMPULSE_EPS:
		body.apply_central_impulse(imp)
		impulses_applied += 1


func _log_status() -> void:
	var chain := 0.0
	for s in SEGMENTS:
		chain += p[s].distance_to(p[s + 1])
	print("SPIKE_B|T2/T3 tick=%d body_y=%.3f chain=%.3f (rest %.1f) v=%.4f sleeping=%s imp=%.3f"
			% [tick, body.global_position.y, chain, SEGMENTS * SEG_REST,
			body.linear_velocity.length(), body.sleeping, last_imp_len])


func _measure_queries() -> void:
	var space := get_world_3d().direct_space_state
	var t0 := Time.get_ticks_usec()
	var hits := 0
	for i in 1000:
		var x := float(i % 40) * 0.1 - 2.0
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 10, 0.5), Vector3(x, -10, 0.5))
		if space.intersect_ray(q):
			hits += 1
	var t1 := Time.get_ticks_usec()
	var shape := SphereShape3D.new()
	shape.radius = 0.05
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = shape
	var t2 := Time.get_ticks_usec()
	var shits := 0
	for i in 1000:
		sq.transform = Transform3D(Basis.IDENTITY, Vector3(float(i % 40) * 0.1 - 2.0, 0.3, 0.5))
		if not space.intersect_shape(sq, 4).is_empty():
			shits += 1
	var t3 := Time.get_ticks_usec()
	print("SPIKE_B|T4 rays=1000 hits=%d usec=%d | spheres=1000 hits=%d usec=%d"
			% [hits, t1 - t0, shits, t3 - t2])


func _summary() -> void:
	print("SPIKE_B|SUMMARY final_y=%.3f expected_y~%.3f sleep_ticks=%d/%d impulses=%d"
			% [body.global_position.y, ANCHOR.y - SEGMENTS * SEG_REST - ATTACH_LOCAL.y,
			sleep_ticks, tick - ROPE_START_TICK, impulses_applied])
