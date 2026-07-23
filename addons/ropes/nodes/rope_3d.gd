@tool
class_name Rope3D
extends Node3D
## A simulated rope hanging between two anchors.
##
## Endpoints follow [member anchor_a] and [member anchor_b]; an empty anchor
## path leaves that end free. Simulation state is read back with
## [method get_particles] and [method get_segment_tension].
##
## Properties come in two kinds. [b]Hot[/b] ones (length, stiffness, damping,
## budget, radius) apply immediately. [b]Cold[/b] ones change the rope's
## topology (resolution, density, end mass, anchors) and re-seed it at the
## start of the next physics tick, discarding its current motion.
##
## STATUS: gate 5. Collision covers the analytic set plus concave meshes and
## voxel terrain; a [RigidBody3D] anchor is coupled by mass, so a rope on a
## winch can lift it; [member length] is a winch. XPBD shipping; AVBD parked.

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")
const RopeRenderer := preload("res://addons/ropes/render/rope_renderer.gd")
const RopeColliders := preload("res://addons/ropes/core/rope_colliders.gd")

## Under-relax pin reactions so a coupled body can settle (Spike B / gate 4).
## Only frozen or non-rigid anchors take this path now; anything the rope can
## actually move is coupled by mass instead (see [method _end_body]).
const PIN_REACTION_RELAXATION := 0.55

## Momentum handed to a mass-coupled body, as a fraction of what the rope
## spent on its proxy. 1.0 is the honest number — the proxy carries the body's
## own mass, so the exchange is already correctly scaled, and under-relaxing it
## would mean a rope that lifts 55% of a rover and drops the rest.
const PROXY_REACTION_RELAXATION := 1.0

## Floor on a coupled body's mass, kg. A zero-mass anchor would make its proxy
## massless and the rope would snap to it as if to a pin — silently, which is
## the worst way for a rope to stop lifting things.
const MIN_ANCHOR_MASS := 0.001

## An anchor further than this from its body's origin is treated as acting at
## the origin: past it the lever arm is almost certainly a stale transform, and
## a stale lever arm spins the body instead of pulling it.
const MAX_LEVER_ARM_M := 120.0

## Which core this node drives, as a constant rather than a setting: exposing
## two solvers as a choice means every feature has to exist twice or the
## setting silently changes which ones work (ADR 0007). XPBD today; AVBD is
## parked. Kept as a compile-time constant so a deliberate revive is an edit,
## never a runtime switch — AVBD carries multipliers across frames, so
## entering it cold reproduces the free-fall-and-bounce transient exactly
## when the rope becomes loaded. [method rebuild] always constructs XPBD while
## this is false; the guard helpers below are the only AVBD-aware path.
const CORE_IS_AVBD := false

## Lateral deviation used when seeding the rope, in meters: no real rope is
## manufactured perfectly straight, and an exactly straight one never leaves
## the unstable equilibrium of axial compression — it telescopes into itself
## instead of toppling into a heap. 0.1 mm is invisible next to any rope
## radius and deterministic. See XPBDRope.lay_line.
const STRAIGHTNESS_JITTER := 0.0001

## Rest length in meters. [b]Hot: this is the winch.[/b] Changing it pays rope
## out or reels it in without re-seeding — shape, motion and anchors survive.
##
## Resolution does not follow: the rope keeps the segment count it was seeded
## with, so a rope winched far past its original length gets coarse. Call
## [method rebuild] when that matters more than the motion does.
@export_range(0.1, 1000.0, 0.1, "or_greater", "suffix:m") var length: float = 5.0:
	set(value):
		length = maxf(value, 0.01)
		if _sim != null and not _needs_rebuild:
			_sim.set_rest_length(length)
			_push_visual_params()
		update_configuration_warnings()

## Simulated particles per meter. Higher = smoother bends, more CPU. Cold.
@export_range(1.0, 16.0, 0.5) var segments_per_meter: float = 4.0:
	set(value):
		segments_per_meter = value
		_cold_changed()

## Linear density, kg per meter. Cold.
@export_range(0.01, 100.0, 0.01, "or_greater", "suffix:kg/m") var mass_per_meter: float = 0.5:
	set(value):
		mass_per_meter = value
		_cold_changed()

## Visual and collision radius in meters. Hot.
@export_range(0.005, 0.5, 0.005, "suffix:m") var radius: float = 0.02:
	set(value):
		radius = value
		_push_visual_params()

@export_group("Anchors")
## Node3D the first particle is pinned to. A [PhysicsBody3D] also receives
## reaction impulses at the pin. Empty = free end. Cold.
@export var anchor_a: NodePath:
	set(value):
		anchor_a = value
		_cold_changed()
## Node3D the last particle is pinned to. Same rules as [member anchor_a].
@export var anchor_b: NodePath:
	set(value):
		anchor_b = value
		_cold_changed()

## Direction the rope is laid out in when it has no anchor B — a free rope
## starts as a straight line from its own position along this. Cold.
@export var lay_direction := Vector3.DOWN:
	set(value):
		lay_direction = value
		_cold_changed()

@export_group("Gravity")
## Follow the project's gravity setting. Turn off for a local gravity zone,
## another planet, or a zero-g pocket. Hot.
@export var use_project_gravity := true:
	set(value):
		use_project_gravity = value
		if _sim:
			_sim.gravity = _effective_gravity()
## Gravity used when [member use_project_gravity] is off, m/s^2. Hot.
@export var gravity := Vector3(0, -9.8, 0):
	set(value):
		gravity = value
		if _sim:
			_sim.gravity = _effective_gravity()

@export_group("Stiffness")
## Stretch compliance in m/N. 0 = as stiff as the simulation budget allows;
## see the mass-ratio envelope in the README. Hot.
@export_range(0.0, 0.1, 0.0001, "or_greater") var stretch_compliance: float = 0.0:
	set(value):
		stretch_compliance = value
		if _sim:
			_sim.stretch_compliance = value

## Extra lumped mass in kg on the B end (a hook, a weight). Has no effect
## while anchor B is set (a pinned end is kinematic). Cold.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:kg") var end_mass: float = 0.0:
	set(value):
		end_mass = value
		_cold_changed()

@export_group("Budget")
## Per-rope for now; the leaning is a solver-global budget (see README). Hot.
@export_range(1, 32) var substeps: int = 8:
	set(value):
		substeps = value
		if _sim:
			_sim.substeps = value
@export_range(1, 8) var iterations: int = 1:
	set(value):
		iterations = value
		if _sim:
			_sim.iterations = value

## Internal damping, 1/s: the rope's own fiber friction. Decays stretching,
## bending and vibration; cannot slow a rope that falls as a whole. Hot.
@export_range(0.0, 20.0, 0.01) var damping: float = 0.5:
	set(value):
		damping = value
		if _sim:
			_sim.damping = value

## Aerodynamic drag, 1/s. Decays absolute velocity, imposing a terminal
## speed of gravity / drag — set it for air, leave 0 for vacuum. Hot.
@export_range(0.0, 10.0, 0.01) var drag: float = 0.0:
	set(value):
		drag = value
		if _sim:
			_sim.drag = value

@export_group("Collision")
## Whether the rope collides with the world. Hot.
@export var collision_enabled: bool = true:
	set(value):
		collision_enabled = value
		if _sim and not value:
			_sim.colliders = []
## Physics layers the rope collides with. Hot.
@export_flags_3d_physics var collision_mask: int = 1
## Coulomb friction against everything the rope touches. Static friction is
## what makes a wrap hold and a laid cable stay put. Hot.
@export_range(0.0, 2.0, 0.01) var friction: float = 0.6:
	set(value):
		friction = value
		if _sim:
			_sim.friction = value

## Also collide with geometry that has no analytic form — concave meshes,
## heightmaps, voxel terrain. Costs one physics query per particle per tick,
## against the same [member collision_mask]; turn it off for a rope that only
## ever meets boxes and spheres. Hot.
@export var concave_collision := true

## How far ahead of the rope the concave probe looks, in meters. It is also
## the rope's speed limit against that geometry: whatever the rope crosses in
## one tick beyond this margin was never sampled and is not there. Hot.
@export_range(0.05, 2.0, 0.01, "suffix:m") var probe_margin: float = 0.25

var _sim: XPBDRope
var _renderer: RopeRenderer
var _anchor_a_node: Node3D
var _anchor_b_node: Node3D
var _anchor_a_prev := Vector3.ZERO
var _anchor_b_prev := Vector3.ZERO
var _prev_points := PackedVector3Array()
var _curr_points := PackedVector3Array()
var _needs_rebuild := false
var _collider_prev := {}


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		set_process(false)
		return
	rebuild()


## Re-seeds the simulation from current properties and anchor positions,
## discarding motion. Called automatically after a cold property changes.
func rebuild() -> void:
	_needs_rebuild = false
	_anchor_a_node = _resolve(anchor_a)
	_anchor_b_node = _resolve(anchor_b)
	var segs := segment_count()
	var warning := tension_readout_warning()
	if not warning.is_empty():
		push_warning("%s: %s" % [get_path() if is_inside_tree() else name, warning])
	_sim = XPBDRope.new()
	_sim.setup(segs, length, mass_per_meter)
	_sim.gravity = _effective_gravity()
	_sim.stretch_compliance = stretch_compliance
	_sim.damping = damping
	_sim.drag = drag
	_sim.radius = radius
	_sim.friction = friction
	_sim.substeps = substeps
	_sim.iterations = maxi(iterations, solver_iterations())
	if end_mass > 0.0:
		_sim.add_point_mass(segs, end_mass)
	var a := _anchor_a_node.global_position if _anchor_a_node else global_position
	var lay := lay_direction if lay_direction.length_squared() > 1e-12 else Vector3.DOWN
	var b := _anchor_b_node.global_position if _anchor_b_node else a + lay.normalized() * length
	_sim.lay_line(a, b, STRAIGHTNESS_JITTER)
	_attach_end(0, _anchor_a_node)
	_attach_end(segs, _anchor_b_node)
	_anchor_a_prev = a
	_anchor_b_prev = b
	_curr_points = _sim.positions.duplicate()
	_prev_points = _curr_points.duplicate()
	if _renderer == null:
		_renderer = RopeRenderer.new()
		add_child(_renderer)
	_push_visual_params()
	_renderer.push_state(_prev_points, _curr_points, _sim.tensions)


## Rigidly move the rope by delta, preserving its shape and motion. Call
## this when an anchor JUMPS instead of traveling (teleport, level load):
## treating a jump as travel would manufacture a huge constraint violation
## and fling the rope.
func teleport(delta: Vector3) -> void:
	if _sim == null:
		return
	_sim.teleport(delta)
	_anchor_a_prev += delta
	_anchor_b_prev += delta
	for i in _curr_points.size():
		_curr_points[i] += delta
		_prev_points[i] += delta


func _physics_process(dt: float) -> void:
	if _needs_rebuild:
		rebuild()
	if _sim == null:
		return
	var last := _sim.segment_count()
	var a := _anchor_a_node.global_position if _anchor_a_node else _anchor_a_prev
	var b := _anchor_b_node.global_position if _anchor_b_node else _anchor_b_prev
	if _anchor_a_node:
		_drive_end(0, _anchor_a_node, a, _anchor_a_prev, dt)
		_anchor_a_prev = a
	if _anchor_b_node:
		_drive_end(last, _anchor_b_node, b, _anchor_b_prev, dt)
		_anchor_b_prev = b
	if collision_enabled:
		_gather_colliders()
	else:
		_sim.colliders = []
		_sim.local_planes = PackedVector4Array()
	_sim.step(dt)
	if _anchor_a_node:
		_settle_end(0, _anchor_a_node, a)
	if _anchor_b_node:
		_settle_end(last, _anchor_b_node, b)
	_prev_points = _curr_points
	_curr_points = _sim.positions.duplicate()
	_renderer.push_state(_prev_points, _curr_points, _sim.tensions)


func _process(_dt: float) -> void:
	if _renderer != null:
		_renderer.update_visual(Engine.get_physics_interpolation_fraction())


## Number of simulated particles (segment count + 1).
func get_particle_count() -> int:
	return _curr_points.size()


## Particle positions in global space at physics rate; index 0 at anchor A.
## For attaching visuals, prefer [method get_render_particles].
func get_particles() -> PackedVector3Array:
	if _sim == null:
		return PackedVector3Array()
	return _sim.positions.duplicate()


## Particle positions interpolated for the current rendered frame.
func get_render_particles() -> PackedVector3Array:
	var out := _curr_points.duplicate()
	if _prev_points.size() != _curr_points.size():
		return out
	var f := Engine.get_physics_interpolation_fraction()
	for i in out.size():
		out[i] = _prev_points[i].lerp(_curr_points[i], f)
	return out


## Tension in Newtons of the segment between particles i and i + 1, from the
## solver's Lagrange multipliers.
func get_segment_tension(i: int) -> float:
	if _sim == null or i < 0 or i >= _sim.tensions.size():
		return 0.0
	return _sim.tensions[i]


# --- Tension readout guard ---------------------------------------------------
#
# The segment count is decided here, as length x segments_per_meter, so this is
# where a core's size envelope has to be enforced (ADR 0007). AVBD's tension
# readout collapses past a measured size — 400 segments free hanging reads
# +947%, and +1549406% with a rover on the end — while its stretch stays at
# 0.4% and the rope looks perfect. That is the one failure mode a user cannot
# see, so the budget is raised to meet the measured rule and, when the rule
# outruns the ceiling, the rope says so out loud.
#
# Dormant while [constant CORE_IS_AVBD] is false: XPBD's tension holds to a few
# percent at every length measured (spikes/spike_f_catenary_and_length.gd) and
# asks nothing of this. It lives here anyway, because the segment count is
# authored here, and because a guard written after the solver switch is a guard
# written after the first wrong number has already been believed.

## Segments the current properties produce. This is the number the guard is
## about, and it is not [member segments_per_meter] — a 100 m rope at the
## default 4 per metre is 400 segments.
func segment_count() -> int:
	return maxi(1, ceili(length * segments_per_meter))


## Iterations the core in use needs at this rope's size for its tension readout
## to be trustworthy; 0 when the core has no size-dependent requirement.
## Capped nowhere — compare against the core's own ceiling to find out whether
## the requirement can actually be met.
func solver_iterations() -> int:
	if not CORE_IS_AVBD:
		return 0
	return AVBDRope.required_iterations(segment_count(), length, _is_loaded())


## Why this rope's tension cannot be believed, or "" when it can. Non-empty
## only when the requirement runs past what the core will spend on its own.
func tension_readout_warning() -> String:
	if not CORE_IS_AVBD:
		return ""
	return AVBDRope.guard_warning(segment_count(), length, _is_loaded(),
			maxi(iterations, mini(solver_iterations(), AVBDRope.ITERATIONS_MAX)))


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	var w := tension_readout_warning()
	if not w.is_empty():
		out.append(w)
	return out


## A pinned B end is kinematic, so its mass never loads the rope — the guard
## has to agree with [member end_mass]'s own documented behaviour or it picks
## the wrong law for exactly the ropes that matter.
func _is_loaded() -> bool:
	if _resolve(anchor_b) != null:
		return false
	return end_mass > mass_per_meter * length * AVBDRope.GUARD_LOADED_FRACTION


## Instantaneous impulse (N*s) on one particle — poking, grabbing, wind gusts.
func apply_impulse(particle: int, impulse: Vector3) -> void:
	if _sim != null and particle >= 0 and particle < _sim.positions.size():
		_sim.apply_impulse(particle, impulse)


func _cold_changed() -> void:
	if _sim != null:
		_needs_rebuild = true
	# Every cold property feeds the segment count, so every cold property can
	# move the rope in or out of the envelope the guard is about.
	update_configuration_warnings()


func _effective_gravity() -> Vector3:
	return _world_gravity() if use_project_gravity else gravity


func _push_visual_params() -> void:
	if _renderer == null:
		return
	var g := _effective_gravity().length()
	_renderer.configure(radius, maxf((mass_per_meter * length + end_mass) * g, 0.5))


# One broadphase query per tick; the core does exact analytic distances to
# these shapes every substep with interpolated transforms (ADR 0006).
func _gather_colliders() -> void:
	var world := get_world_3d()
	if world == null:
		return
	var space := world.direct_space_state
	# Anchor bodies are NOT excluded. They used to be, and the price was a rope
	# cutting through the corners of the very block it was tied to whenever the
	# block swung. The narrow exemption belongs on the attachment points — pins
	# and proxies skip contacts in the core — not on the whole body, which the
	# rest of the rope is entitled to lie against.
	var exclude: Array[RID] = []
	var gathered := RopeColliders.gather_from_space(
		_curr_points,
		space,
		collision_mask,
		maxf(length * 0.25, 1.0),
		_collider_prev,
		exclude
	)
	_collider_prev = gathered.cache
	_sim.colliders = gathered.colliders
	if not concave_collision:
		_sim.local_planes = PackedVector4Array()
		return
	# Whatever the analytic pass already solves is excluded from the plane
	# pass: the same wall solved twice is the same wall with twice the
	# friction, and it is the kind of double-count nobody sees until a rope
	# refuses to slide.
	var probe_exclude: Array[RID] = exclude.duplicate()
	for rid: RID in RopeColliders.body_rids(_sim.colliders):
		probe_exclude.append(rid)
	_sim.local_planes = RopeColliders.sample_local_planes(
		_sim.positions,
		space,
		collision_mask,
		radius,
		probe_margin,
		probe_exclude
	)


# --- anchors -----------------------------------------------------------------
#
# An anchor the rope cannot move (a crane arm, a bolted eyelet, a frozen body)
# is a kinematic pin: the host says where it is, the rope obeys. An anchor the
# rope IS supposed to move — a rover on the end of a winch — is coupled by
# mass instead, because a kinematic end makes the rope's constraints blind to
# the thing hanging on it. See the proxy note in the core: the difference is
# between a rope that reports the weight of its own fibres and one that
# reports the rover.


## The [RigidBody3D] an anchor node belongs to — itself, or the nearest one
## above it, so a [Marker3D] hook bolted under a chassis couples the chassis.
## Null when there is none, or when it is frozen: a frozen body is scenery
## that happens to be a rigid body, and the rope must pin to it, not push it.
func _end_body(node: Node3D) -> RigidBody3D:
	var current: Node = node
	while current != null:
		var body := current as RigidBody3D
		if body != null:
			return null if body.freeze else body
		current = current.get_parent()
	return null


## Decide once, at seed time, whether an end is a pin or a mass-coupled proxy.
func _attach_end(index: int, node: Node3D) -> void:
	if node == null:
		return
	var body := _end_body(node)
	if body != null:
		_sim.attach_proxy(index, maxf(body.mass, MIN_ANCHOR_MASS))
	else:
		_sim.pin(index)


## Put an end where its anchor is, before the step. Bodies that froze or
## unfroze since the last tick switch mode here rather than waiting for a
## rebuild — freezing a body is how a game says "this is scenery now".
func _drive_end(index: int, node: Node3D, at: Vector3, was_at: Vector3, dt: float) -> void:
	var body := _end_body(node)
	if body != null:
		if not _sim.is_proxy(index):
			_sim.attach_proxy(index, maxf(body.mass, MIN_ANCHOR_MASS))
		_sim.seat_proxy(index, at, _point_velocity(body, at))
	else:
		if _sim.is_proxy(index):
			_sim.pin(index)
		_sim.move_pin(index, at, (at - was_at) / dt)


## Hand the anchor's body what the rope just spent on it, after the step.
func _settle_end(index: int, node: Node3D, at: Vector3) -> void:
	var body := _end_body(node)
	if body == null:
		if node is RigidBody3D:
			_apply_pin_reaction(node as RigidBody3D, at, index)
		return
	var impulse := _sim.proxy_momentum(index) * PROXY_REACTION_RELAXATION
	# Back on the hook for rendering, whatever the solver did to the stand-in.
	_sim.reseat_proxy(index, at)
	if impulse.length_squared() <= 1e-12:
		return
	body.sleeping = false
	var offset := at - body.global_position
	if offset.length() > MAX_LEVER_ARM_M:
		offset = Vector3.ZERO
	body.apply_impulse(impulse, offset)


## Velocity of a body's surface AT the anchor point: the tip of a swinging
## boom is not moving at the boom's linear velocity.
func _point_velocity(body: RigidBody3D, at: Vector3) -> Vector3:
	return body.linear_velocity + body.angular_velocity.cross(at - body.global_position)


func _apply_pin_reaction(body: RigidBody3D, anchor: Vector3, pin_index: int) -> void:
	if body.freeze:
		return
	var impulse := _sim.pin_reaction_impulse(pin_index) * PIN_REACTION_RELAXATION
	if impulse.length_squared() <= 1e-12:
		return
	body.sleeping = false
	var offset := anchor - body.global_position
	if offset.length() > MAX_LEVER_ARM_M:
		offset = Vector3.ZERO
	body.apply_impulse(impulse, offset)


func _resolve(path: NodePath) -> Node3D:
	if path.is_empty():
		return null
	return get_node_or_null(path) as Node3D


func _world_gravity() -> Vector3:
	var mag: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var dir: Vector3 = ProjectSettings.get_setting(
			"physics/3d/default_gravity_vector", Vector3.DOWN)
	return dir * mag
