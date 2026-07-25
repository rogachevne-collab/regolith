extends Node
## After M0 rebuild: probe SUPPORTS_RAY_QUERY + compile a fragment shader with
## GL_EXT_ray_query. Does not dispatch a full light-loop yet — just capability.

const LABEL := "RAY_QUERY_PROBE"

const FRAG_GLSL := """
#version 460
#extension GL_EXT_ray_query : require
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 1, r32f) uniform image2D out_image;
void main() {
	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, tlas, gl_RayFlagsOpaqueEXT, 0xFF, vec3(0.0), 0.001, vec3(0.0, -1.0, 0.0), 10.0);
	rayQueryProceedEXT(rq);
	float hit = rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionTriangleEXT ? 1.0 : 0.0;
	imageStore(out_image, ivec2(0, 0), vec4(hit));
}
"""


func _ready() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		print("%s: FAIL RenderingDevice=null" % LABEL)
		get_tree().quit(1)
		return

	var pipeline_ok := rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	var query_ok := rd.has_feature(RenderingDevice.SUPPORTS_RAY_QUERY)
	print("%s: SUPPORTS_RAYTRACING_PIPELINE=%s" % [LABEL, pipeline_ok])
	print("%s: SUPPORTS_RAY_QUERY=%s" % [LABEL, query_ok])
	print("%s: engine=%s" % [LABEL, Engine.get_version_info()])

	if not query_ok:
		print("%s: FAIL ray query feature false — rebuild with M0 patch?" % LABEL)
		get_tree().quit(2)
		return

	var shader_spirv := RDShaderFile.new()
	# Godot expects compute via RDShaderSource for this probe.
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = FRAG_GLSL
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)
	var err := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if err != "":
		print("%s: FAIL shader compile:\n%s" % [LABEL, err])
		get_tree().quit(3)
		return

	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		print("%s: FAIL shader_create_from_spirv" % LABEL)
		get_tree().quit(4)
		return

	rd.free_rid(shader)
	print("%s: OK rayQueryEXT compiles in compute shader" % LABEL)
	get_tree().quit(0)
