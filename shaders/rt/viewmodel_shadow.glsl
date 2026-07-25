#[raygen]

#version 460

#pragma shader_stage(raygen)
#extension GL_EXT_ray_tracing : enable

layout(location = 0) rayPayloadEXT vec4 payload;

layout(set = 0, binding = 0, rgba16f) uniform image2D mask_image;
layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;

layout(set = 0, binding = 2, std140) uniform RtParams {
	mat4 inv_proj;
	vec4 sun_dir_energy;
	vec4 lamp_pos_enabled;
	vec4 lamp_dir_range;
	vec4 lamp_spot_cos;
} params;

const float PRIMARY_TMIN = 0.001;
const float PRIMARY_TMAX = 4.0;
// Offset back along the view ray; no position fetch, so no surface normal here.
const float SHADOW_ORIGIN_PULLBACK = 0.0015;
const float SHADOW_TMIN = 0.002;
const float SHADOW_TMAX = 8.0;

vec3 primary_ray_dir(vec2 ndc) {
	// The viewmodel is a Camera3D child: Godot camera forward is -Z.
	vec2 raster_size = params.lamp_spot_cos.zw;
	float aspect = raster_size.x / max(raster_size.y, 1.0);
	float tan_half_fov = params.lamp_spot_cos.y;
	return normalize(vec3(
		ndc.x * aspect * tan_half_fov,
		-ndc.y * tan_half_fov,
		-1.0
	));
}

float trace_shadow(vec3 origin, vec3 dir) {
	payload.w = 1.0;
	traceRayEXT(
		tlas,
		gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsOpaqueEXT,
		0xFF,
		0,
		0,
		0,
		origin,
		SHADOW_TMIN,
		dir,
		SHADOW_TMAX,
		0
	);
	return payload.w;
}

void main() {
	ivec2 px = ivec2(gl_LaunchIDEXT.xy);
	vec2 raster_size = params.lamp_spot_cos.zw;
	vec2 uv = (vec2(px) + vec2(0.5)) / raster_size;

	vec2 ndc = uv * 2.0 - 1.0;
	vec3 dir = primary_ray_dir(ndc);
	vec3 origin = vec3(0.0);

	payload = vec4(0.0, 0.0, 0.0, 0.0);
	traceRayEXT(
		tlas,
		gl_RayFlagsOpaqueEXT,
		0xFF,
		0,
		0,
		0,
		origin,
		PRIMARY_TMIN,
		dir,
		PRIMARY_TMAX,
		0
	);

	if (payload.w < 0.5) {
		imageStore(mask_image, px, vec4(1.0, 1.0, 0.0, 0.0));
		return;
	}

	vec3 hit_pos = origin + dir * (payload.x - SHADOW_ORIGIN_PULLBACK);

	float sun_vis = 1.0;
	if (params.sun_dir_energy.w > 0.5) {
		sun_vis = trace_shadow(hit_pos, normalize(params.sun_dir_energy.xyz));
	}

	float lamp_vis = 1.0;
	if (params.lamp_pos_enabled.w > 0.5) {
		vec3 to_lamp = params.lamp_pos_enabled.xyz - hit_pos;
		float dist = length(to_lamp);
		if (dist <= params.lamp_dir_range.w) {
			vec3 lamp_dir = to_lamp / max(dist, 1e-6);
			vec3 spot_dir = normalize(-params.lamp_dir_range.xyz);
			if (dot(lamp_dir, spot_dir) >= params.lamp_spot_cos.x) {
				lamp_vis = trace_shadow(hit_pos, lamp_dir);
			}
		}
	}

	imageStore(mask_image, px, vec4(sun_vis, lamp_vis, 1.0, 1.0));
}

#[miss]

#version 460

#pragma shader_stage(miss)
#extension GL_EXT_ray_tracing : enable

layout(location = 0) rayPayloadInEXT vec4 payload;

void main() {
	// Shadow rays reuse the payload: miss means the light is visible.
	if ((uint(gl_IncomingRayFlagsEXT) & gl_RayFlagsTerminateOnFirstHitEXT) != 0u) {
		payload.w = 1.0;
	} else {
		payload = vec4(0.0, 0.0, 0.0, 0.0);
	}
}

#[closest_hit]

#version 460

#pragma shader_stage(closest_hit)
#extension GL_EXT_ray_tracing : enable

layout(location = 0) rayPayloadInEXT vec4 payload;

void main() {
	if ((uint(gl_IncomingRayFlagsEXT) & gl_RayFlagsTerminateOnFirstHitEXT) != 0u) {
		payload.w = 0.0;
		return;
	}
	payload = vec4(gl_HitTEXT, 0.0, 0.0, 1.0);
}
