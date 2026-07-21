extends Node
class_name DayNightCycle

## Presentation-only sun orbit + light/ambient modulation.
## See docs/specs/DAY-NIGHT-V0.md.

@export var enabled := true
@export var cycle_duration_sec := 600.0
@export_range(0.0, 1.0, 0.001) var start_phase := 0.18
## Orbit axis in world space (sun sweeps the plane perpendicular to this).
@export var orbit_axis := Vector3(0.35, 0.0, 0.94)
## Noon direction at phase 0.25 (will be orthogonalized against orbit_axis).
@export var noon_direction := Vector3(-0.43, 0.75, -0.5)

@export var day_sun_energy := 1.55
@export var day_fill_energy := 0.28
@export var night_fill_energy := 0.22
@export var day_ambient_energy := 0.32
@export var night_ambient_energy := 0.08
@export var flat_day_ambient_energy := 0.2
@export var flat_night_ambient_energy := 0.06

@export_node_path("DirectionalLight3D") var sun_light_path: NodePath = ^"../DirectionalLight3D"
@export_node_path("DirectionalLight3D") var fill_light_path: NodePath = ^"../FillLight"
@export_node_path("WorldEnvironment") var world_environment_path: NodePath = ^"../WorldEnvironment"

var phase: float = 0.0

var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _world_env: WorldEnvironment
var _radial := false
var _elapsed := 0.0
var _sun_pos := Vector3.ZERO
var _fill_pos := Vector3.ZERO


func _ready() -> void:
	_sun = get_node_or_null(sun_light_path) as DirectionalLight3D
	_fill = get_node_or_null(fill_light_path) as DirectionalLight3D
	_world_env = get_node_or_null(world_environment_path) as WorldEnvironment
	var field := GravityField.find_in_tree(self)
	_radial = field != null and field.mode == GravityField.Mode.RADIAL
	if _sun != null:
		_sun_pos = _sun.global_position
	if _fill != null:
		_fill_pos = _fill.global_position
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


func _apply() -> void:
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

	var angle := phase * TAU
	var sun_dir := (noon * cos(angle) + dawn * sin(angle)).normalized()
	var up_hint := axis
	if absf(sun_dir.dot(up_hint)) > 0.95:
		up_hint = noon

	if _sun != null and is_instance_valid(_sun):
		_sun.global_transform = _orient_light(_sun_pos, sun_dir, up_hint)
		if _radial:
			_sun.light_energy = day_sun_energy
		else:
			var elev := sun_dir.y
			_sun.light_energy = day_sun_energy * smoothstep(-0.08, 0.12, elev)

	if _fill != null and is_instance_valid(_fill):
		var fill_dir := (-sun_dir).normalized()
		_fill.global_transform = _orient_light(_fill_pos, fill_dir, up_hint)
		if _radial:
			_fill.light_energy = day_fill_energy
		else:
			var night_w := 1.0 - smoothstep(-0.05, 0.2, sun_dir.y)
			_fill.light_energy = lerpf(day_fill_energy, night_fill_energy, night_w)

	if _world_env != null and _world_env.environment != null:
		var env := _world_env.environment
		if _radial:
			env.ambient_light_energy = day_ambient_energy
		else:
			var day_w := smoothstep(-0.05, 0.25, sun_dir.y)
			env.ambient_light_energy = lerpf(
				flat_night_ambient_energy, flat_day_ambient_energy, day_w
			)


func _orient_light(origin: Vector3, sky_dir: Vector3, up_hint: Vector3) -> Transform3D:
	# sky_dir = direction from scene toward the light source.
	# DirectionalLight emits along local -Z, so aim -Z into the scene (-sky_dir).
	# Then basis.z == sky_dir (SolarSkyDecor / LunarSkyDecor read +Z as sun).
	var up := up_hint
	if absf(sky_dir.dot(up)) > 0.995:
		up = Vector3.RIGHT if absf(sky_dir.dot(Vector3.UP)) > 0.9 else Vector3.UP
	return Transform3D(Basis.looking_at(-sky_dir, up), origin)
