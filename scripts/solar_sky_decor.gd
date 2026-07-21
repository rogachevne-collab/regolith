extends Node3D
class_name SolarSkyDecor

## Presentation-only sun disc. Camera-locked on a long celestial ray — no parallax.

@export var enabled := true
@export var angular_diameter_deg := 2.0
@export var distance_m := 12000.0
@export var hide_below_horizon := true
@export var horizon_margin_deg := -1.5
@export_node_path("DirectionalLight3D") var sun_light_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath

@onready var _disc: MeshInstance3D = $Disc

var _sun_light: DirectionalLight3D
var _camera: Camera3D
var _disc_mesh: SphereMesh


func _ready() -> void:
	if sun_light_path != NodePath():
		_sun_light = get_node_or_null(sun_light_path) as DirectionalLight3D
	if camera_path != NodePath():
		_camera = get_node_or_null(camera_path) as Camera3D
	_disc_mesh = _disc.mesh as SphereMesh
	if _disc_mesh != null:
		_disc_mesh = _disc_mesh.duplicate() as SphereMesh
		_disc.mesh = _disc_mesh
	_apply_scale()
	visible = enabled
	set_process(enabled)


func _process(_delta: float) -> void:
	if not enabled:
		return
	_place()


func _place() -> void:
	var cam := _resolve_camera()
	var anchor := Vector3.ZERO
	if cam != null:
		anchor = cam.global_position
	else:
		anchor = _fallback_anchor()

	var up := GravityField.resolve_up(self, anchor)
	var sun_dir := _sun_direction()
	var sun_pos := anchor + sun_dir * distance_m

	var look_up := up
	if absf(sun_dir.dot(up)) > 0.999:
		var tangent := Vector3.FORWARD.slide(up)
		if tangent.length_squared() < 0.0001:
			tangent = Vector3.RIGHT.slide(up)
		look_up = tangent.normalized()
	global_transform = Transform3D(Basis.looking_at(-sun_dir, look_up), sun_pos)
	_apply_scale()

	if hide_below_horizon:
		var elev := rad_to_deg(asin(clampf(sun_dir.dot(up), -1.0, 1.0)))
		visible = elev >= horizon_margin_deg
	else:
		visible = true


func _sun_direction() -> Vector3:
	# DirectionalLight emits along -Z; the source (sun) sits on +Z.
	if _sun_light != null and is_instance_valid(_sun_light):
		return _sun_light.global_transform.basis.z.normalized()
	return Vector3(0.5, 0.75, 0.35).normalized()


func _fallback_anchor() -> Vector3:
	var field := GravityField.find_in_tree(self)
	if field != null and field.mode == GravityField.Mode.RADIAL:
		return field.center + Vector3.UP * MoonGeometry.SURFACE_RADIUS_M
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
	if _disc_mesh != null:
		_disc_mesh.radius = radius
		_disc_mesh.height = radius * 2.0
