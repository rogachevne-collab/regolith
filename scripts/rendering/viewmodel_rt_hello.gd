extends Node
class_name ViewmodelRtHello

## Minimal RT hello-triangle (MIT demo pattern). Sets last_ok after one trace.

var last_ok := false

var _rd: RenderingDevice
var _ray_texture: RID
var _shader: RID
var _sbt: RID
var _sbt_range: int
var _pipeline: RID
var _vertex_buffer: RID
var _vertex_array: RID
var _index_buffer: RID
var _index_array: RID
var _blas: RID
var _tlas: RID
var _uniform_set: RID
var _cleaned := false


func _ready() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or not _rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		return
	last_ok = _run_once()
	cleanup()


func cleanup() -> void:
	if _cleaned:
		return
	_cleaned = true
	_cleanup()


func _run_once() -> bool:
	if not _init_pipeline():
		return false
	if not _init_geometry():
		return false
	_render()
	var data := _rd.texture_get_data(_ray_texture, 0)
	if data.is_empty():
		push_warning("ViewmodelRtHello: empty texture readback")
		return false
	for i in mini(data.size(), 256):
		if data[i] != 0:
			return true
	return false


func _init_pipeline() -> bool:
	var shader_file: RDShaderFile = load("res://shaders/rt/hello_triangle.glsl") as RDShaderFile
	if shader_file == null:
		push_warning("ViewmodelRtHello: missing ray shader")
		return false
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return false
	var raygen := RDPipelineShader.new()
	raygen.shader = _shader
	var miss := RDPipelineShader.new()
	miss.shader = _shader
	var hit := RDPipelineShader.new()
	hit.shader = _shader
	var hit_group := RDHitGroup.new()
	hit_group.closest_hit_shader = hit
	_pipeline = _rd.raytracing_pipeline_create([raygen], [miss], [hit_group], 1)
	if not _pipeline.is_valid():
		return false
	_sbt = _rd.hit_sbt_create(_pipeline, 4)
	_sbt_range = _rd.hit_sbt_range_alloc(_sbt, 1)
	if _sbt_range == 0:
		return false
	if _rd.hit_sbt_range_update(_sbt, _sbt_range, 0, [0]) != OK:
		return false
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = 8
	fmt.height = 8
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	)
	var view := RDTextureView.new()
	_ray_texture = _rd.texture_create(fmt, view)
	return _ray_texture.is_valid()


func _init_geometry() -> bool:
	var points := PackedFloat32Array([
		0.0, -0.7, 1.0,
		0.5, -0.7, 1.0,
		0.0, 0.5, 1.0,
	])
	var point_bytes := points.to_byte_array()
	var buf_flags := (
		RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT
		| RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT
	)
	_vertex_buffer = _rd.vertex_buffer_create(point_bytes.size(), point_bytes, buf_flags)
	var vdesc := RDVertexAttribute.new()
	vdesc.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vdesc.location = 0
	vdesc.stride = 12
	var vfmt := _rd.vertex_format_create([vdesc])
	_vertex_array = _rd.vertex_array_create(3, vfmt, [_vertex_buffer])
	var indices := PackedInt32Array([0, 2, 1])
	var index_bytes := indices.to_byte_array()
	_index_buffer = _rd.index_buffer_create(
		indices.size(),
		RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,
		index_bytes,
		false,
		buf_flags
	)
	_index_array = _rd.index_array_create(_index_buffer, 0, indices.size())
	var geometry := RDAccelerationStructureGeometry.new()
	geometry.index_buffer = _index_buffer
	geometry.index_count = indices.size()
	geometry.vertex_buffer = _vertex_buffer
	geometry.vertex_count = 3
	geometry.vertex_format = vdesc.format
	geometry.vertex_stride = vdesc.stride
	_blas = _rd.blas_create([geometry], RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT)
	if not _blas.is_valid():
		return false
	_rd.blas_build(_blas)
	_tlas = _rd.tlas_create(1, RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)
	if not _tlas.is_valid():
		return false
	var instance := RDAccelerationStructureInstance.new()
	instance.blas = _blas
	instance.hit_sbt_range = _sbt_range
	_rd.tlas_build(_tlas, [instance])
	var image_u := RDUniform.new()
	image_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_u.binding = 0
	image_u.add_id(_ray_texture)
	var as_u := RDUniform.new()
	as_u.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	as_u.binding = 1
	as_u.add_id(_tlas)
	_uniform_set = _rd.uniform_set_create([image_u, as_u], _shader, 0)
	return _uniform_set.is_valid()


func _render() -> void:
	var raylist := _rd.raytracing_list_begin()
	_rd.raytracing_list_bind_raytracing_pipeline(raylist, _pipeline)
	_rd.raytracing_list_bind_uniform_set(raylist, _uniform_set, 0)
	_rd.raytracing_list_trace_rays(raylist, 0, _sbt, 8, 8, 1)
	_rd.raytracing_list_end()


func _cleanup() -> void:
	if _rd == null:
		return
	if _sbt.is_valid() and _sbt_range != 0:
		_rd.hit_sbt_range_free(_sbt, _sbt_range)
		_sbt_range = 0
	if _sbt.is_valid():
		_rd.free_rid(_sbt)
		_sbt = RID()
	for rid in [
		_uniform_set, _tlas, _blas, _index_array, _index_buffer, _vertex_array,
		_vertex_buffer, _pipeline, _shader, _ray_texture,
	]:
		if rid.is_valid():
			_rd.free_rid(rid)
