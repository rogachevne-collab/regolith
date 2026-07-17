extends Node3D
class_name LunarSkyDecor

## Presentation-only Earth + atmosphere limb.
## Locked to the camera on a long celestial ray — no walking parallax.

@export var enabled := true
@export var angular_diameter_deg := 5.5
## Camera-relative distance. Large ⇒ reads as infinitely far.
@export var distance_m := 14000.0
## World / selenocentric direction toward Earth.
@export var earth_direction := Vector3(0.28, 0.92, 0.28)
@export var spin_deg_per_sec := 0.04
@export var hide_below_horizon := true
@export var horizon_margin_deg := -1.5
@export_node_path("DirectionalLight3D") var sun_light_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath

@onready var _earth: MeshInstance3D = $Earth
@onready var _atmosphere: MeshInstance3D = $Atmosphere

var _sun_light: DirectionalLight3D
var _camera: Camera3D
var _spin := 0.0
var _earth_mesh: SphereMesh
var _atmo_mesh: SphereMesh


func _ready() -> void:
	if sun_light_path != NodePath():
		_sun_light = get_node_or_null(sun_light_path) as DirectionalLight3D
	if camera_path != NodePath():
		_camera = get_node_or_null(camera_path) as Camera3D
	_earth_mesh = _earth.mesh as SphereMesh
	_atmo_mesh = _atmosphere.mesh as SphereMesh
	# Unique meshes so instances don't fight shared SphereMesh resources.
	if _earth_mesh != null:
		_earth_mesh = _earth_mesh.duplicate() as SphereMesh
		_earth.mesh = _earth_mesh
	if _atmo_mesh != null:
		_atmo_mesh = _atmo_mesh.duplicate() as SphereMesh
		_atmosphere.mesh = _atmo_mesh
	_apply_scale()
	_update_materials_sun()
	visible = enabled
	set_process(enabled)


func _process(delta: float) -> void:
	if not enabled:
		return
	_spin += spin_deg_per_sec * delta
	_place()
	_update_materials_sun()


func _place() -> void:
	var cam := _resolve_camera()
	var anchor := Vector3.ZERO
	if cam != null:
		anchor = cam.global_position
	else:
		anchor = _fallback_anchor()

	var up := GravityField.resolve_up(self, anchor)
	var sky_dir := _celestial_direction(anchor, up)
	var earth_pos := anchor + sky_dir * distance_m

	var look_up := up
	if absf(sky_dir.dot(up)) > 0.999:
		var tangent := Vector3.FORWARD.slide(up)
		if tangent.length_squared() < 0.0001:
			tangent = Vector3.RIGHT.slide(up)
		look_up = tangent.normalized()
	var look := Basis.looking_at(-sky_dir, look_up)
	look = look.rotated(look.y.normalized(), deg_to_rad(_spin))
	global_transform = Transform3D(look, earth_pos)
	_apply_scale()

	if hide_below_horizon:
		var elev := rad_to_deg(asin(clampf(sky_dir.dot(up), -1.0, 1.0)))
		visible = elev >= horizon_margin_deg
	else:
		visible = true


func _celestial_direction(anchor: Vector3, up: Vector3) -> Vector3:
	var dir := earth_direction
	if dir.length_squared() <= 0.000001:
		dir = Vector3.UP
	else:
		dir = dir.normalized()

	var field := GravityField.find_in_tree(self)
	if field != null and field.mode == GravityField.Mode.RADIAL:
		# Parallel rays from surface toward a far selenocentric target.
		var far := field.center + dir * (MoonGeometry.SURFACE_RADIUS_M + 1_000_000.0)
		var to_far := far - anchor
		if to_far.length_squared() <= 0.000001:
			return dir
		return to_far.normalized()

	var bearing := dir.slide(up)
	if bearing.length_squared() <= 0.000001:
		bearing = Vector3.FORWARD.slide(up)
	bearing = bearing.normalized()
	var elev := clampf(dir.dot(up), 0.2, 0.92)
	return (bearing * sqrt(max(0.0, 1.0 - elev * elev)) + up * elev).normalized()


func _fallback_anchor() -> Vector3:
	var field := GravityField.find_in_tree(self)
	if field != null and field.mode == GravityField.Mode.RADIAL:
		return field.center + earth_direction.normalized() * MoonGeometry.SURFACE_RADIUS_M
	return Vector3.ZERO


func _resolve_camera() -> Camera3D:
	if _camera != null and is_instance_valid(_camera):
		return _camera
	var viewport := get_viewport()
	if viewport != null:
		return viewport.get_camera_3d()
	return null


func _apply_scale() -> void:
	var radius := distance_m * tan(deg_to_rad(angular_diameter_deg * 0.5))
	if _earth_mesh != null:
		_earth_mesh.radius = radius
		_earth_mesh.height = radius * 2.0
	if _atmo_mesh != null:
		var atmo_r := radius * 1.06
		_atmo_mesh.radius = atmo_r
		_atmo_mesh.height = atmo_r * 2.0


func _update_materials_sun() -> void:
	var sun_dir := Vector3(0.5, 0.75, 0.35).normalized()
	if _sun_light != null and is_instance_valid(_sun_light):
		sun_dir = (-_sun_light.global_transform.basis.z).normalized()
	var mat := _atmosphere.material_override as ShaderMaterial
	if mat == null:
		mat = _atmosphere.get_active_material(0) as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("sun_direction", sun_dir)
