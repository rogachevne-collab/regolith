vec3 decode_normal_map(vec3 encoded_normal) {
	return encoded_normal * 2.0 - 1.0;
}

// Keep normals sharp under world-space triplanar (default mips go soapy ~10 m).
const float TRIPLANAR_NORMAL_MIP_BIAS = -0.45;

int planar_mode(vec3 blend, float thresh) {
	if (blend.y >= thresh) {
		return 1;
	}
	if (blend.x >= thresh) {
		return 2;
	}
	if (blend.z >= thresh) {
		return 3;
	}
	return 0;
}

vec3 sample_planar_rgb(sampler2D tex, vec3 pos, vec3 blend, int mode) {
	if (mode == 1) {
		return texture(tex, pos.xz, TRIPLANAR_NORMAL_MIP_BIAS).rgb;
	}
	if (mode == 2) {
		return texture(tex, pos.yz, TRIPLANAR_NORMAL_MIP_BIAS).rgb;
	}
	if (mode == 3) {
		return texture(tex, pos.xy, TRIPLANAR_NORMAL_MIP_BIAS).rgb;
	}
	return texture(tex, pos.yz, TRIPLANAR_NORMAL_MIP_BIAS).rgb * blend.x
		+ texture(tex, pos.xz, TRIPLANAR_NORMAL_MIP_BIAS).rgb * blend.y
		+ texture(tex, pos.xy, TRIPLANAR_NORMAL_MIP_BIAS).rgb * blend.z;
}

float sample_planar_r(sampler2D tex, vec3 pos, vec3 blend, int mode) {
	if (mode == 1) {
		return texture(tex, pos.xz, TRIPLANAR_NORMAL_MIP_BIAS).r;
	}
	if (mode == 2) {
		return texture(tex, pos.yz, TRIPLANAR_NORMAL_MIP_BIAS).r;
	}
	if (mode == 3) {
		return texture(tex, pos.xy, TRIPLANAR_NORMAL_MIP_BIAS).r;
	}
	return texture(tex, pos.yz, TRIPLANAR_NORMAL_MIP_BIAS).r * blend.x
		+ texture(tex, pos.xz, TRIPLANAR_NORMAL_MIP_BIAS).r * blend.y
		+ texture(tex, pos.xy, TRIPLANAR_NORMAL_MIP_BIAS).r * blend.z;
}

vec3 triplanar_normal_whiteout(
	sampler2D normal_texture,
	vec3 world_position,
	vec3 world_normal,
	vec3 blending
) {
	vec3 normal_x = decode_normal_map(
		texture(normal_texture, world_position.yz, TRIPLANAR_NORMAL_MIP_BIAS).xyz
	);
	vec3 normal_y = decode_normal_map(
		texture(normal_texture, world_position.xz, TRIPLANAR_NORMAL_MIP_BIAS).xyz
	);
	vec3 normal_z = decode_normal_map(
		texture(normal_texture, world_position.xy, TRIPLANAR_NORMAL_MIP_BIAS).xyz
	);

	normal_x = vec3(
		normal_x.xy + world_normal.zy,
		abs(normal_x.z) * world_normal.x
	);
	normal_y = vec3(
		normal_y.xy + world_normal.xz,
		abs(normal_y.z) * world_normal.y
	);
	normal_z = vec3(
		normal_z.xy + world_normal.xy,
		abs(normal_z.z) * world_normal.z
	);

	return normalize(
		normal_x.zyx * blending.x
		+ normal_y.xzy * blending.y
		+ normal_z.xyz * blending.z
	);
}

vec3 sample_planar_normal(
	sampler2D normal_texture,
	vec3 world_position,
	vec3 world_normal,
	vec3 blending,
	int mode
) {
	if (mode == 1) {
		vec3 tn = decode_normal_map(
			texture(normal_texture, world_position.xz, TRIPLANAR_NORMAL_MIP_BIAS).xyz
		);
		tn = vec3(tn.xy + world_normal.xz, abs(tn.z) * world_normal.y);
		return normalize(tn.xzy);
	}
	if (mode == 2) {
		vec3 tn = decode_normal_map(
			texture(normal_texture, world_position.yz, TRIPLANAR_NORMAL_MIP_BIAS).xyz
		);
		tn = vec3(tn.xy + world_normal.zy, abs(tn.z) * world_normal.x);
		return normalize(tn.zyx);
	}
	if (mode == 3) {
		vec3 tn = decode_normal_map(
			texture(normal_texture, world_position.xy, TRIPLANAR_NORMAL_MIP_BIAS).xyz
		);
		tn = vec3(tn.xy + world_normal.xy, abs(tn.z) * world_normal.z);
		return normalize(tn.xyz);
	}
	return triplanar_normal_whiteout(normal_texture, world_position, world_normal, blending);
}
