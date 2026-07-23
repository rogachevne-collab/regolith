extends Node3D
# XPBD vs AVBD, side by side, same scenario, same frame.
#
# Every scenario is built twice: the shipping XPBD core in the back row and the
# AVBD spike in the front row, at their own recommended budgets rather than at
# equal iteration counts (XPBD spends substeps, AVBD spends iterations), with
# the per-step cost on screen so the comparison stays honest about what each
# one is paying.
#
# The HUD number that matters is stretch: a rope that reports 8% longer than
# its rest length is lying to whatever it is holding by 8%, and that lie is
# what reaches the vehicle as force.
#
# Controls: LMB poke | RMB hold + WASD/QE fly (Shift fast, wheel speed)
#           R reset | 1 toggle XPBD row | 2 toggle AVBD row

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")
const RopeRenderer := preload("res://addons/ropes/render/rope_renderer.gd")
const FlyCamera := preload("res://addons/ropes/demos/fly_camera.gd")

const G := 9.8
const MASS_PER_M := 0.5
## Matches bench/mass_ratio_bench.gd so the numbers here stay comparable to the
## README table. 10/m looked nicer and put the whole playground over the 16.6 ms
## physics budget, which makes every reading suspect.
const SEGMENTS_PER_M := 5.0
const RADIUS := 0.035
## Per-tick particle motion below which a rope counts as having stopped,
## in meters — the same threshold bench/rope_bench.gd uses.
const SETTLED_M := 0.002
## One row per solver configuration, spread along z so one camera sees them
## all. XPBD appears twice on purpose: substeps are its quality dial, and
## docs/research/mass-ratio-state-of-the-art.md puts the useful setting at
## 32-64 for heavy payloads, so judging it at the shipping default of 8 would
## be judging it outside its own envelope.
const ROWS := [
	{tag = "XPBD/8", solver = "XPBD", sub = 8, z = -2.6, tint = Color(0.55, 0.75, 1.0)},
	{tag = "XPBD/32", solver = "XPBD", sub = 32, z = 0.0, tint = Color(0.5, 1.0, 0.7)},
	{tag = "AVBD", solver = "AVBD", sub = 1, z = 2.6, tint = Color(1.0, 0.85, 0.5)},
]
## Averaging window for the per-step cost readout, in frames.
const COST_WINDOW := 30

# Scenario list. `end_mass` hangs a payload on the free end; `b` pins the far
# end instead. Ratios in the names are payload : rope mass.
var _scenarios := [
	{name = "20 kg  (16:1)", len = 3.5, x = -9.0, top = 6.0, end_mass = 20.0},
	{name = "250 kg  (100:1)", len = 5.0, x = -4.0, top = 7.0, end_mass = 250.0},
	{name = "1250 kg  (500:1)", len = 5.0, x = 1.0, top = 7.0, end_mass = 1250.0},
	{name = "slack span 6/4", len = 6.0, x = 6.0, top = 6.0, span = 4.0},
	{name = "taut span 4.05/4", len = 4.05, x = 12.0, top = 6.0, span = 4.0},
]

var _ropes: Array[Dictionary] = []
var _cam: Camera3D
var _hud: Label
var _poke_impulse := 5.0
var _rows_visible := {}
var _headless := false
var _frames := 0


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	for row: Dictionary in ROWS:
		_rows_visible[row.tag] = true
	_make_environment()
	_make_camera()
	_make_hud()
	_build()


func _build() -> void:
	for r in _ropes:
		r.renderer.queue_free()
		if r.box != null:
			r.box.queue_free()
		if r.label != null:
			r.label.queue_free()
	_ropes.clear()

	for cfg: Dictionary in _scenarios:
		for row: Dictionary in ROWS:
			_make_rope(cfg, row)
		var title := Label3D.new()
		title.text = cfg.name
		title.position = Vector3(cfg.x, cfg.top + 0.7, 0)
		title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		title.font_size = 44
		title.pixel_size = 0.005
		add_child(title)


func _make_rope(cfg: Dictionary, row: Dictionary) -> void:
	var length: float = cfg.len
	var z: float = row.z
	var segments := maxi(2, int(round(length * SEGMENTS_PER_M)))
	var end_mass: float = cfg.get("end_mass", 0.0)

	var sim: RefCounted
	if row.solver == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = row.sub
		sim.iterations = 1
	else:
		sim = AVBDRope.new()
		sim.substeps = 1      # warm starting decays per step; do not substep
		sim.iterations = 16
		sim.dual_every = 4
	sim.setup(segments, length, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0

	var a := Vector3(cfg.x, cfg.top, z)
	if cfg.has("span"):
		var b := a + Vector3(cfg.span, 0, 0)
		sim.lay_line(a, b)
		sim.pin(0)
		sim.pin(segments)
	else:
		# A perfectly straight rope sits in the unstable equilibrium of axial
		# compression and telescopes into itself instead of toppling; the same
		# 0.1 mm bend Rope3D seeds is enough to break it.
		sim.lay_line(a, a + Vector3(0.0001, -length, 0))
		sim.pin(0)
		if end_mass > 0.0:
			sim.add_point_mass(segments, end_mass)

	var renderer: MeshInstance3D = RopeRenderer.new()
	add_child(renderer)
	var rope_mass := MASS_PER_M * length
	renderer.configure(RADIUS, maxf((end_mass + rope_mass) * G, 1.0))
	renderer.visible = _rows_visible[row.tag]

	var box: MeshInstance3D = null
	if end_mass > 0.0:
		box = MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * (0.12 * pow(end_mass, 1.0 / 3.0))
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.75, 0.55, 0.25)
		mesh.material = mat
		box.mesh = mesh
		add_child(box)

	var tag := Label3D.new()
	tag.text = row.tag
	tag.position = a + Vector3(0, 0.25, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 32
	tag.pixel_size = 0.004
	tag.modulate = row.tint
	add_child(tag)

	_ropes.append({
		sim = sim, tag = row.tag, name = cfg.name, renderer = renderer,
		box = box, label = tag, rest = length, end_mass = end_mass,
		prev = sim.positions.duplicate(), curr = sim.positions.duplicate(),
		usec = 0.0, motion = 0.0, blown = false,
	})


func _physics_process(dt: float) -> void:
	for r in _ropes:
		# A hidden row is not simulated. Comparing two rows should cost two
		# rows: at 15 ropes in GDScript the whole playground does not fit in a
		# 16.6 ms physics tick, and a physics loop that cannot keep up makes
		# every reading on screen a reading of the wrong thing.
		if r.blown or not r.renderer.visible:
			continue
		var t0 := Time.get_ticks_usec()
		r.sim.step(dt)
		var used := float(Time.get_ticks_usec() - t0)
		r.usec += (used - r.usec) / float(COST_WINDOW)
		# A diverged spike must stop drawing rather than throw NaN geometry at
		# the renderer for the rest of the session.
		var len_now: float = r.sim.total_polyline_length()
		if not is_finite(len_now) or len_now > r.rest * 20.0:
			r.blown = true
			r.label.text = "%s DIVERGED" % r.tag
			r.label.modulate = Color(1, 0.3, 0.3)
			r.renderer.visible = false
			continue
		r.prev = r.curr
		r.curr = r.sim.positions.duplicate()
		r.renderer.push_state(r.prev, r.curr, r.sim.tensions)
		# Quiescence, the axis the stretch table is blind to. A rope that has
		# visually stopped but still moves every tick is converting constraint
		# error into momentum forever — which is what keeps an attached body
		# from ever sleeping (spike B, finding 4). Mean per-particle motion per
		# tick, smoothed, in metres.
		var motion := 0.0
		var n: int = r.curr.size()
		for i in n:
			motion += (r.curr[i] - r.prev[i]).length()
		motion /= float(maxi(n, 1))
		r.motion += (motion - r.motion) / float(COST_WINDOW)


func _process(_dt: float) -> void:
	var fraction := Engine.get_physics_interpolation_fraction()
	for r in _ropes:
		if r.blown:
			continue
		r.renderer.update_visual(fraction)
		if r.box != null and not r.curr.is_empty():
			r.box.global_position = r.curr[r.curr.size() - 1]
	_hud.text = _report()
	# Headless, the same table is the run's output: this scene doubles as a
	# comparison bench that can be diffed between runs.
	#   godot --headless --path . res://addons/ropes/demos/avbd_shootout.tscn --quit-after 600
	if _headless:
		_frames += 1
		if _frames % 180 == 0:
			print("\n--- t = %.1f s\n%s" % [_frames / 60.0, _hud.text])


## One row per scenario, both solvers on it, so the eye and the number agree.
func _report() -> String:
	var by_name := {}
	for r in _ropes:
		if not by_name.has(r.name):
			by_name[r.name] = {}
		by_name[r.name][r.tag] = r
	var out := "%-18s" % "scenario"
	for row: Dictionary in ROWS:
		out += "%26s" % row.tag
	out += "\n%-18s" % ""
	for _row in ROWS:
		out += "%26s" % "stretch  tension  jitter"
	out += "\n"
	for name: String in by_name:
		out += "%-18s" % name
		for row: Dictionary in ROWS:
			var r: Dictionary = by_name[name].get(row.tag, {})
			if r.is_empty() or r.blown:
				out += "%26s" % "-- DIVERGED --"
				continue
			if not r.renderer.visible:
				out += "%26s" % "-- hidden --"
				continue
			var stretch: float = r.sim.total_polyline_length() / r.rest - 1.0
			# A rope still swinging is not jittering; only flag the buzz of one
			# that has otherwise stopped.
			var quiet := "  " if r.motion >= SETTLED_M else ("ok" if r.motion < SETTLED_M * 0.05 else "BUZZ")
			out += " %7.2f%% %7.0fN %5.2fmm%s" % [
					stretch * 100.0, r.sim.tensions[0], r.motion * 1000.0, quiet]
		out += "\n"
	out += "\nexact static tension: "
	for name: String in by_name:
		var any: Dictionary = by_name[name].values()[0]
		out += "%s %.0fN   " % [name.split(" ")[0], (any.end_mass + MASS_PER_M * any.rest) * G]
	out += "\ncost per step, us: "
	var grand := 0.0
	for row: Dictionary in ROWS:
		var total := 0.0
		for r in _ropes:
			if r.tag == row.tag and not r.blown and r.renderer.visible:
				total += r.usec
		grand += total
		out += "%s %.0f   " % [row.tag, total]
	out += "| total %.0f of the 16667 us tick%s" % [grand,
			"  <-- OVER BUDGET, readings are unreliable" if grand > 16667.0 else ""]
	out += "\njitter = mean particle motion per tick; BUZZ = looks stopped but never is\n"
	out += "poke %.1f N*s  [LMB poke  RMB+WASD/QE fly (Shift fast)  +/- force  1/2/3 hide a row  R reset]" % _poke_impulse
	return out


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_poke(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_EQUAL, KEY_KP_ADD:
				_poke_impulse = minf(_poke_impulse * 1.5, 500.0)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_poke_impulse = maxf(_poke_impulse / 1.5, 0.5)
			KEY_1, KEY_2, KEY_3:
				var idx: int = event.keycode - KEY_1
				if idx < ROWS.size():
					_toggle_row(ROWS[idx].tag)
			KEY_R:
				_build.call_deferred()


func _toggle_row(tag: String) -> void:
	_rows_visible[tag] = not _rows_visible[tag]
	for r in _ropes:
		if r.tag == tag and not r.blown:
			r.renderer.visible = _rows_visible[tag]


func _poke(mouse_pos: Vector2) -> void:
	var origin := _cam.project_ray_origin(mouse_pos)
	var dir := _cam.project_ray_normal(mouse_pos)
	var best_dist := 0.45
	var best: Dictionary = {}
	var best_index := -1
	for r in _ropes:
		if r.blown or not r.renderer.visible:
			continue
		var pts: PackedVector3Array = r.sim.positions
		for i in pts.size():
			var to := pts[i] - origin
			var t := to.dot(dir)
			if t <= 0.0:
				continue
			var d := (to - dir * t).length()
			if d < best_dist:
				best_dist = d
				best = r
				best_index = i
	if not best.is_empty():
		best.sim.apply_impulse(best_index, dir * _poke_impulse)


func _make_camera() -> void:
	_cam = FlyCamera.new()
	add_child(_cam)
	_cam.look_at_from_position(Vector3(-2.0, 5.0, 14.0), Vector3(-2.0, 3.5, 0.0), Vector3.UP)


func _make_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 8)
	_hud.add_theme_font_override("font", ThemeDB.fallback_font)
	_hud.add_theme_font_size_override("font_size", 15)
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
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.35, 0.38)
	plane.material = mat
	floor_mesh.mesh = plane
	add_child(floor_mesh)
