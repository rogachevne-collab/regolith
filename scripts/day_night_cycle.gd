extends Node
class_name DayNightCycle

## Presentation-only sun orbit + ambient / earthshine modulation.
## Sun disc is drawn in lunar_starfield.gdshader from LIGHT0_DIRECTION
## (same +Z vector as scene lighting). See docs/specs/DAY-NIGHT-V0.md.
##
## Soft fill is sky ambient + a dim Earthshine directional from
## LunarSkyDecor.earth_direction — not an anti-sun second key light
## (that inverted crater relief in shadow).

@export var enabled := true
@export var cycle_duration_sec := 600.0
## Fallback before spawn alignment; bootstrap calls align_noon_above().
@export_range(0.0, 1.0, 0.001) var start_phase := 0.8
## Offset from local noon applied by align_noon_above(), in orbit fractions.
## 0.0 lands the sun near the local zenith — the flattest light there is, no
## relief and no cast shadows. +0.13 drops it to ~33 deg: the working area
## stays lit while slopes and objects get readable shadows. Past ~0.16 the
## ground the player stands on falls into shade. Negative offsets mirror the
## azimuth and read as front light (flat again).
@export_range(-0.5, 0.5, 0.001) var noon_phase_offset := 0.0
## Orbit axis in world space (sun sweeps the plane perpendicular to this).
@export var orbit_axis := Vector3(0.35, 0.0, 0.94)
## Noon direction at phase ~0 (will be orthogonalized against orbit_axis).
@export var noon_direction := Vector3(-0.43, 0.75, -0.5)

@export var day_sun_energy := 1.55
## Dim blue-ish bounce from Earth (no shadows). Kept low so sky ambient
## carries the soft lift and earthshine only adds a sided cue.
@export var day_earthshine_energy := 0.12
@export var night_earthshine_energy := 0.18
@export var day_ambient_energy := 0.42
@export var flat_day_ambient_energy := 0.28
@export var flat_night_ambient_energy := 0.12
## Fallback if LunarSkyDecor is missing (matches decor default).
@export var earth_direction := Vector3(0.28, 0.92, 0.28)

@export_node_path("DirectionalLight3D") var sun_light_path: NodePath = ^"../DirectionalLight3D"
@export_node_path("DirectionalLight3D") var earthshine_light_path: NodePath = ^"../Earthshine"
@export_node_path("Node3D") var lunar_sky_decor_path: NodePath = ^"../LunarSkyDecor"
@export_node_path("WorldEnvironment") var world_environment_path: NodePath = ^"../WorldEnvironment"

## World-space direction from the scene toward the sun (matches light +Z / LIGHT0).
var sun_direction := Vector3.UP
var phase: float = 0.0

var _sun: DirectionalLight3D
var _earthshine: DirectionalLight3D
var _sky_decor: Node
var _world_env: WorldEnvironment
var _radial := false
var _elapsed := 0.0
var _sun_pos := Vector3.ZERO
var _earthshine_pos := Vector3.ZERO


class OrbitFrame:
	var axis: Vector3
	var noon: Vector3
	var dawn: Vector3

	func _init(p_axis: Vector3, p_noon: Vector3, p_dawn: Vector3) -> void:
		axis = p_axis
		noon = p_noon
		dawn = p_dawn


func _ready() -> void:
	_sun = get_node_or_null(sun_light_path) as DirectionalLight3D
	_earthshine = get_node_or_null(earthshine_light_path) as DirectionalLight3D
	_sky_decor = get_node_or_null(lunar_sky_decor_path)
	_world_env = get_node_or_null(world_environment_path) as WorldEnvironment
	var field := GravityField.find_in_tree(self)
	_radial = field != null and field.mode == GravityField.Mode.RADIAL
	if _sun != null:
		_sun_pos = _sun.global_position
	if _earthshine != null:
		_earthshine_pos = _earthshine.global_position
		## Soft bounce only — no hard specular glints from Earthshine.
		_earthshine.light_specular = 0.0
		_earthshine.shadow_enabled = false
	phase = start_phase
	_apply()
	set_process(enabled)


func _process(delta: float) -> void:
	if not enabled:
		return
	var dur := maxf(cycle_duration_sec, 0.001)
	_elapsed += delta
	phase = fposmod(start_phase + _elapsed / dur, 1.0)
	_apply()


## Put local noon above `world_up` (spawn radial / flat +Y) and restart the cycle.
func align_noon_above(world_up: Vector3) -> void:
	var up := world_up
	if up.length_squared() <= 0.000001:
		up = Vector3.UP
	else:
		up = up.normalized()
	var best_phase := start_phase
	var best_dot := -2.0
	const STEPS := 256
	for i in STEPS:
		var p := float(i) / float(STEPS)
		var d := _sun_direction_at_phase(p).dot(up)
		if d > best_dot:
			best_dot = d
			best_phase = p
	start_phase = fposmod(best_phase + noon_phase_offset, 1.0)
	phase = start_phase
	_elapsed = 0.0
	_apply()


func _apply() -> void:
	sun_direction = _sun_direction_at_phase(phase)
	var orbit: OrbitFrame = _orbit_basis()
	var up_hint: Vector3 = orbit.axis
	if absf(sun_direction.dot(up_hint)) > 0.95:
		up_hint = orbit.noon

	if _sun != null and is_instance_valid(_sun):
		# Godot directional L and sky LIGHT0_DIRECTION are both +basis.z.
		_sun.global_transform = _orient_source(_sun_pos, sun_direction, up_hint)
		if _radial:
			_sun.light_energy = day_sun_energy
		else:
			_sun.light_energy = day_sun_energy * smoothstep(-0.08, 0.12, sun_direction.y)

	if _earthshine != null and is_instance_valid(_earthshine):
		var earth_dir := _resolve_earth_direction()
		_earthshine.global_transform = _orient_source(
			_earthshine_pos, earth_dir, up_hint
		)
		if _radial:
			_earthshine.light_energy = day_earthshine_energy
		else:
			var night_w := 1.0 - smoothstep(-0.05, 0.2, sun_direction.y)
			_earthshine.light_energy = lerpf(
				day_earthshine_energy, night_earthshine_energy, night_w
			)

	if _world_env != null and _world_env.environment != null:
		var env := _world_env.environment
		if _radial:
			env.ambient_light_energy = day_ambient_energy
		else:
			var day_w := smoothstep(-0.05, 0.25, sun_direction.y)
			env.ambient_light_energy = lerpf(
				flat_night_ambient_energy, flat_day_ambient_energy, day_w
			)


func _orbit_basis() -> OrbitFrame:
	var axis := orbit_axis
	if axis.length_squared() < 0.0001:
		axis = Vector3.FORWARD
	else:
		axis = axis.normalized()
	var noon := noon_direction.slide(axis)
	if noon.length_squared() < 0.0001:
		noon = Vector3.UP.slide(axis)
	if noon.length_squared() < 0.0001:
		noon = Vector3.RIGHT.slide(axis)
	noon = noon.normalized()
	var dawn := axis.cross(noon).normalized()
	return OrbitFrame.new(axis, noon, dawn)


func _sun_direction_at_phase(p: float) -> Vector3:
	var orbit: OrbitFrame = _orbit_basis()
	var angle := fposmod(p, 1.0) * TAU
	return (orbit.noon * cos(angle) + orbit.dawn * sin(angle)).normalized()


func _resolve_earth_direction() -> Vector3:
	var dir := earth_direction
	if _sky_decor != null and is_instance_valid(_sky_decor):
		var from_decor: Variant = _sky_decor.get("earth_direction")
		if from_decor is Vector3 and (from_decor as Vector3).length_squared() > 0.000001:
			dir = from_decor as Vector3
	if dir.length_squared() <= 0.000001:
		return Vector3.UP
	return dir.normalized()


func _orient_source(origin: Vector3, source_dir: Vector3, up_hint: Vector3) -> Transform3D:
	# source_dir = direction toward the light source in the sky.
	# looking_at(-source_dir) ⇒ basis.z == source_dir (== Godot L / LIGHT0).
	var up := up_hint
	if absf(source_dir.dot(up)) > 0.995:
		up = Vector3.RIGHT if absf(source_dir.dot(Vector3.UP)) > 0.9 else Vector3.UP
	return Transform3D(Basis.looking_at(-source_dir, up), origin)
