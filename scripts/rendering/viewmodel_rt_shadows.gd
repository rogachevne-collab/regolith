extends Node
class_name ViewmodelRtShadows

const SHADER_PATH := "res://shaders/rt/viewmodel_shadow.glsl"
const AMBIENT_FLOOR := 0.22

@export var enabled := true
@export var camera_path: NodePath = ^"../Camera"
@export var drill_visual_path: NodePath = ^"../Camera/DrillVisual"
@export var drill_model_path: NodePath = ^"../Camera/DrillVisual/ShakePivot/Mount/Model"
@export var drill_bit_path: NodePath = ^"../Camera/DrillVisual/ShakePivot/Mount/Model/Sketchfab_model/Drill_Low_fbx/RootNode/Body_Low/Cone"
@export var mining_light_path: NodePath = ^"../Camera/MiningLight"
@export var sun_path: NodePath = NodePath("/root/Main/DirectionalLight3D")

var debug_view := false

var rt_available := false
var rt_active := false

var _camera: Camera3D
var _drill_visual: Node3D
var _drill_model: Node3D
var _drill_bit: Node3D
var _mining_light: SpotLight3D
var _sun: DirectionalLight3D
var _rd: RenderingDevice
var _drill_meshes: Array[MeshInstance3D] = []

var _body_blas: RID
var _bit_blas: RID
var _blas_rids: Array[RID] = []

var _frame_mutex := Mutex.new()
var _frame: Dictionary = {}
var _cast_shadow_backup: Dictionary = {}
var _params_bytes := PackedByteArray()


func _ready() -> void:
	_camera = get_node_or_null(camera_path) as Camera3D
	_drill_visual = get_node_or_null(drill_visual_path) as Node3D
	_drill_model = get_node_or_null(drill_model_path) as Node3D
	_drill_bit = get_node_or_null(drill_bit_path) as Node3D
	_mining_light = get_node_or_null(mining_light_path) as SpotLight3D
	_sun = get_node_or_null(sun_path) as DirectionalLight3D
	if _sun == null:
		_sun = get_tree().root.get_node_or_null("Main/DirectionalLight3D") as DirectionalLight3D
	_rd = RenderingServer.get_rendering_device()
	rt_available = _rd != null and _rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	if not rt_available:
		print("ViewmodelRtShadows: RT unavailable — soft-disabled (Vulkan RT or GPU required)")
		return
	if not _init_blas():
		push_warning("ViewmodelRtShadows: BLAS build failed — soft-disabled")
		rt_available = false
		return
	ViewmodelRtRegistry.controller = self
	_register_console()
	_set_rt_active(enabled and _drill_visual.visible)
	print("ViewmodelRtShadows: RT ready (probe ok)")


func _exit_tree() -> void:
	if ViewmodelRtRegistry.controller == self:
		ViewmodelRtRegistry.controller = null
	_free_blas()
	_set_shadow_casting_override(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_free_blas()


func _process(_delta: float) -> void:
	if not rt_available:
		return
	if _drill_visual == null or not _drill_visual.visible:
		if rt_active:
			_set_rt_active(false)
		return
	if enabled and not rt_active:
		_set_rt_active(true)
	elif not enabled and rt_active:
		_set_rt_active(false)
	if not rt_active:
		return
	_update_frame_state()


func is_runtime_active() -> bool:
	return rt_available and rt_active


func get_frame_state() -> Dictionary:
	_frame_mutex.lock()
	var copy := _frame.duplicate(true)
	_frame_mutex.unlock()
	return copy


func get_body_blas() -> RID:
	return _body_blas


func get_bit_blas() -> RID:
	return _bit_blas


func get_params_bytes() -> PackedByteArray:
	return _params_bytes


func set_user_enabled(on: bool) -> void:
	enabled = on
	if not on and rt_active:
		_set_rt_active(false)
	elif on and rt_available and _drill_visual != null and _drill_visual.visible:
		_set_rt_active(true)


func _register_console() -> void:
	if LimboConsole.has_command("viewmodel_rt"):
		return
	LimboConsole.register_command(viewmodel_rt, "viewmodel_rt", "Toggle drill RT shadows: viewmodel_rt [0|1|on|off]")


func viewmodel_rt(mode: String = "") -> void:
	if mode.is_empty():
		LimboConsole.info(
			"viewmodel_rt active=%s enabled=%s available=%s debug=%s"
			% [rt_active, enabled, rt_available, debug_view]
		)
		return
	var v := mode.strip_edges().to_lower()
	if v == "debug":
		debug_view = not debug_view
		ViewmodelRtRegistry.debug_view = debug_view
		LimboConsole.info("viewmodel_rt debug=%s (white=lit, dark=RT shadow)" % debug_view)
		return
	if v == "1" or v == "on":
		set_user_enabled(true)
	elif v == "0" or v == "off":
		set_user_enabled(false)
	else:
		LimboConsole.info("Usage: viewmodel_rt [0|1|on|off|debug]")
		return
	LimboConsole.info("viewmodel_rt active=%s" % rt_active)


func _init_blas() -> bool:
	if _drill_model == null or _drill_bit == null:
		return false
	var body_meshes := ViewmodelRtMesh.collect_mesh_instances(_drill_model, _drill_bit)
	var bit_meshes := ViewmodelRtMesh.collect_mesh_instances(_drill_bit)
	if body_meshes.is_empty() and bit_meshes.is_empty():
		return false
	_drill_meshes = body_meshes.duplicate()
	_drill_meshes.append_array(bit_meshes)
	if not body_meshes.is_empty():
		var body := ViewmodelRtMesh.bake_blas(_rd, body_meshes, _drill_model)
		if body.is_empty():
			return false
		_body_blas = body["blas"]
		## Free order matters: derived arrays before their buffers.
		_blas_rids.append_array([_body_blas, body["index_array"], body["vertex_array"], body["index_buffer"], body["vertex_buffer"]])
	if not bit_meshes.is_empty():
		var bit := ViewmodelRtMesh.bake_blas(_rd, bit_meshes, _drill_bit)
		if bit.is_empty():
			return false
		_bit_blas = bit["blas"]
		_blas_rids.append_array([_bit_blas, bit["index_array"], bit["vertex_array"], bit["index_buffer"], bit["vertex_buffer"]])
	return _body_blas.is_valid() or _bit_blas.is_valid()


func _free_blas() -> void:
	if _rd == null:
		return
	for rid in _blas_rids:
		if rid.is_valid():
			_rd.free_rid(rid)
	_blas_rids.clear()
	_body_blas = RID()
	_bit_blas = RID()


func _set_rt_active(on: bool) -> void:
	rt_active = on
	_set_shadow_casting_override(not on)


## Keeps CSM *reception* intact so world geometry (cave walls, rover, terrain)
## still shadows the viewmodel — the RT pass only knows about the drill itself.
## Dropping the drill out of the shadow map is what removes the CSM self-shadow
## mush; RT supplies the self-shadow term instead.
func _set_shadow_casting_override(cast: bool) -> void:
	for mi in _drill_meshes:
		if not is_instance_valid(mi):
			continue
		if not cast:
			if not _cast_shadow_backup.has(mi):
				_cast_shadow_backup[mi] = mi.cast_shadow
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif _cast_shadow_backup.has(mi):
			mi.cast_shadow = _cast_shadow_backup[mi]
			_cast_shadow_backup.erase(mi)


func _update_frame_state() -> void:
	if _camera == null:
		return
	var cam_inv := _camera.global_transform.affine_inverse()
	var instances: Array[Transform3D] = []
	var blases: Array[RID] = []
	if _body_blas.is_valid() and _drill_model != null:
		blases.append(_body_blas)
		instances.append(cam_inv * _drill_model.global_transform)
	if _bit_blas.is_valid() and _drill_bit != null:
		blases.append(_bit_blas)
		instances.append(cam_inv * _drill_bit.global_transform)
	var sun_dir := Vector3(0.0, -1.0, 0.0)
	var sun_energy := 0.0
	if _sun != null and is_instance_valid(_sun):
		# DirectionalLight shines along -Z; shadow rays go toward the sun (+basis.z).
		sun_dir = (_camera.global_transform.basis.inverse() * _sun.global_transform.basis.z).normalized()
		sun_energy = 1.0 if _sun.visible else 0.0
	var lamp_pos := Vector3.ZERO
	var lamp_dir := Vector3(0.0, 0.0, -1.0)
	var lamp_range := 0.0
	var lamp_cos := 0.0
	var lamp_on := 0.0
	if _mining_light != null and _mining_light.visible:
		lamp_on = 1.0
		lamp_pos = cam_inv * _mining_light.global_position
		lamp_dir = (_camera.global_transform.basis.inverse() * (-_mining_light.global_transform.basis.z)).normalized()
		lamp_range = _mining_light.spot_range
		var half_angle := deg_to_rad(_mining_light.spot_angle * 0.5)
		lamp_cos = cos(half_angle)
	var proj := _camera.get_camera_projection()
	var inv_proj := proj.inverse()
	_params_bytes = _pack_params(inv_proj, sun_dir, sun_energy, lamp_pos, lamp_on, lamp_dir, lamp_range, lamp_cos)
	_frame_mutex.lock()
	_frame = {
		"instances": instances,
		"blases": blases,
		"inv_proj": inv_proj,
		"ambient_floor": AMBIENT_FLOOR,
	}
	_frame_mutex.unlock()


func _pack_params(
	inv_proj: Projection,
	sun_dir: Vector3,
	sun_energy: float,
	lamp_pos: Vector3,
	lamp_on: float,
	lamp_dir: Vector3,
	lamp_range: float,
	lamp_cos: float
) -> PackedByteArray:
	var floats := PackedFloat32Array()
	floats.append_array(_mat4_to_floats(inv_proj))
	floats.append(sun_dir.x)
	floats.append(sun_dir.y)
	floats.append(sun_dir.z)
	floats.append(sun_energy)
	floats.append(lamp_pos.x)
	floats.append(lamp_pos.y)
	floats.append(lamp_pos.z)
	floats.append(lamp_on)
	floats.append(lamp_dir.x)
	floats.append(lamp_dir.y)
	floats.append(lamp_dir.z)
	floats.append(lamp_range)
	floats.append(lamp_cos)
	floats.append(tan(deg_to_rad(_camera.fov * 0.5)))
	floats.append(0.0)
	floats.append(0.0)
	return floats.to_byte_array()


func set_raster_size_in_params(bytes: PackedByteArray, size: Vector2i) -> PackedByteArray:
	var floats := bytes.to_float32_array()
	if floats.size() >= 32:
		floats[30] = float(size.x)
		floats[31] = float(size.y)
	return floats.to_byte_array()


static func _mat4_to_floats(p: Projection) -> PackedFloat32Array:
	var m := p
	return PackedFloat32Array([
		m.x.x, m.y.x, m.z.x, m.w.x,
		m.x.y, m.y.y, m.z.y, m.w.y,
		m.x.z, m.y.z, m.z.z, m.w.z,
		m.x.w, m.y.w, m.z.w, m.w.w,
	])
