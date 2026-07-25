extends CompositorEffect
class_name ViewmodelRtCompositeEffect

const RAY_SHADER_PATH := "res://shaders/rt/viewmodel_shadow.glsl"

const COMPUTE_TEMPLATE := """#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std140) uniform CompositeParams {
	vec2 raster_size;
	float ambient_floor;
	float pad;
} params;

layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D mask_texture;

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}
	vec2 uv_norm = (vec2(uv) + vec2(0.5)) / params.raster_size;
	vec4 mask = texture(mask_texture, uv_norm);
	if (mask.a < 0.5) {
		return;
	}
	vec4 color = imageLoad(color_image, uv);
	if (params.ambient_floor < 0.0) {
		// Debug: visualize sun visibility (white = lit, black = RT shadow).
		color.rgb = vec3(mask.r);
		imageStore(color_image, uv, color);
		return;
	}
	float sun_mul = mix(params.ambient_floor, 1.0, mask.r);
	float lamp_mul = mix(params.ambient_floor, 1.0, mask.g);
	color.rgb *= sun_mul * lamp_mul;
	imageStore(color_image, uv, color);
}
"""

var rd: RenderingDevice
var _ray_shader: RID
var _ray_pipeline: RID
var _ray_sbt: RID
var _ray_sbt_range: int
var _ray_uniform_set: RID
var _params_buffer: RID
var _tlas: RID
var _mask_texture: RID
var _mask_size := Vector2i.ZERO

var _compute_shader: RID
var _compute_pipeline: RID
var _composite_params_buffer: RID
var _nearest_sampler: RID

var _initialized := false
var _rt_ready := false


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()


func _ensure_rt_pipeline() -> bool:
	if _rt_ready:
		return true
	if rd == null or not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		return false
	var shader_file: RDShaderFile = load(RAY_SHADER_PATH) as RDShaderFile
	if shader_file == null:
		return false
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv == null:
		return false
	for stage in [
		RenderingDevice.SHADER_STAGE_RAYGEN,
		RenderingDevice.SHADER_STAGE_MISS,
		RenderingDevice.SHADER_STAGE_CLOSEST_HIT,
	]:
		var err := spirv.get_stage_compile_error(stage)
		if err != "":
			push_error("VIEWMODEL_RT ray shader stage %d: %s" % [stage, err])
	_ray_shader = rd.shader_create_from_spirv(spirv)
	if not _ray_shader.is_valid():
		return false
	var raygen := RDPipelineShader.new()
	raygen.shader = _ray_shader
	var miss := RDPipelineShader.new()
	miss.shader = _ray_shader
	var hit := RDPipelineShader.new()
	hit.shader = _ray_shader
	var hit_group := RDHitGroup.new()
	hit_group.closest_hit_shader = hit
	_ray_pipeline = rd.raytracing_pipeline_create([raygen], [miss], [hit_group], 2)
	if not _ray_pipeline.is_valid():
		return false
	_ray_sbt = rd.hit_sbt_create(_ray_pipeline, 8)
	_ray_sbt_range = rd.hit_sbt_range_alloc(_ray_sbt, 1)
	if _ray_sbt_range == 0:
		return false
	if rd.hit_sbt_range_update(_ray_sbt, _ray_sbt_range, 0, [0]) != OK:
		return false
	_params_buffer = rd.uniform_buffer_create(256)
	_composite_params_buffer = rd.uniform_buffer_create(16)
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = COMPUTE_TEMPLATE
	var c_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)
	if c_spirv.compile_error_compute != "":
		push_error(c_spirv.compile_error_compute)
		return false
	_compute_shader = rd.shader_create_from_spirv(c_spirv)
	if not _compute_shader.is_valid():
		return false
	_compute_pipeline = rd.compute_pipeline_create(_compute_shader)
	if not _nearest_sampler.is_valid():
		var samp := RDSamplerState.new()
		samp.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		samp.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		_nearest_sampler = rd.sampler_create(samp)
	_rt_ready = true
	return true


func _ensure_mask_texture(size: Vector2i) -> void:
	if size == _mask_size and _mask_texture.is_valid():
		return
	if _mask_texture.is_valid():
		rd.free_rid(_mask_texture)
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = size.x
	fmt.height = size.y
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	var view := RDTextureView.new()
	_mask_texture = rd.texture_create(fmt, view)
	_mask_size = size
	if _ray_uniform_set.is_valid():
		rd.free_rid(_ray_uniform_set)
		_ray_uniform_set = RID()


func _render_callback(p_effect_callback_type: EffectCallbackType, p_render_data: RenderData) -> void:
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	var ctrl := ViewmodelRtRegistry.controller
	if ctrl == null or not ctrl.is_runtime_active():
		return
	if not _ensure_rt_pipeline():
		return
	var render_scene_buffers: RenderSceneBuffers = p_render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return
	var size: Vector2i = render_scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	_ensure_mask_texture(size)
	var state := ctrl.get_frame_state()
	var blases: Array = state.get("blases", [])
	var instances: Array = state.get("instances", [])
	if blases.is_empty() or instances.is_empty():
		return
	if not _trace_shadows(size, ctrl, blases, instances):
		return
	_composite(render_scene_buffers, size, state.get("ambient_floor", 0.22))


func _trace_shadows(size: Vector2i, ctrl: ViewmodelRtShadows, blases: Array, instances: Array) -> bool:
	var rt_instances: Array[RDAccelerationStructureInstance] = []
	for i in blases.size():
		var inst := RDAccelerationStructureInstance.new()
		inst.blas = blases[i]
		inst.transform = instances[i]
		inst.hit_sbt_range = _ray_sbt_range
		rt_instances.append(inst)
	if _tlas.is_valid():
		rd.free_rid(_tlas)
	_tlas = rd.tlas_create(rt_instances.size(), RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)
	if not _tlas.is_valid():
		return false
	rd.tlas_build(_tlas, rt_instances)
	var params_bytes := ctrl.set_raster_size_in_params(ctrl.get_params_bytes(), size)
	rd.buffer_update(_params_buffer, 0, params_bytes.size(), params_bytes)
	# The TLAS is rebuilt every frame; freeing it also drops the uniform set that
	# referenced it, so the set is simply recreated here rather than freed again.
	var img_u := RDUniform.new()
	img_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img_u.binding = 0
	img_u.add_id(_mask_texture)
	var as_u := RDUniform.new()
	as_u.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	as_u.binding = 1
	as_u.add_id(_tlas)
	var par_u := RDUniform.new()
	par_u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	par_u.binding = 2
	par_u.add_id(_params_buffer)
	_ray_uniform_set = rd.uniform_set_create([img_u, as_u, par_u], _ray_shader, 0)
	if not _ray_uniform_set.is_valid():
		return false
	var raylist := rd.raytracing_list_begin()
	rd.raytracing_list_bind_raytracing_pipeline(raylist, _ray_pipeline)
	rd.raytracing_list_bind_uniform_set(raylist, _ray_uniform_set, 0)
	rd.raytracing_list_trace_rays(raylist, 0, _ray_sbt, size.x, size.y, 1)
	rd.raytracing_list_end()
	return true


func _composite(render_scene_buffers: RenderSceneBuffers, size: Vector2i, ambient_floor: float) -> void:
	var floor_val := ambient_floor
	if ViewmodelRtRegistry.debug_view:
		floor_val = -1.0
	@warning_ignore("integer_division")
	var x_groups: int = (size.x - 1) / 8 + 1
	@warning_ignore("integer_division")
	var y_groups: int = (size.y - 1) / 8 + 1
	var comp_params := PackedFloat32Array([float(size.x), float(size.y), floor_val, 0.0])
	rd.buffer_update(_composite_params_buffer, 0, comp_params.size() * 4, comp_params.to_byte_array())
	var view_count: int = render_scene_buffers.get_view_count()
	for view in view_count:
		var color_image: RID = render_scene_buffers.get_color_layer(view)
		var par_u := RDUniform.new()
		par_u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		par_u.binding = 0
		par_u.add_id(_composite_params_buffer)
		var color_u := RDUniform.new()
		color_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_u.binding = 1
		color_u.add_id(color_image)
		var mask_u := RDUniform.new()
		mask_u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		mask_u.binding = 2
		mask_u.add_id(_nearest_sampler)
		mask_u.add_id(_mask_texture)
		var uniform_set: RID = UniformSetCacheRD.get_cache(
			_compute_shader, 0, [par_u, color_u, mask_u]
		)
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _compute_pipeline)
		rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
		rd.compute_list_dispatch(cl, x_groups, y_groups, 1)
		rd.compute_list_end()
