vec3 decode_normal_map(vec3 encoded_normal) {
	return encoded_normal * 2.0 - 1.0;
}


vec3 triplanar_normal_whiteout(
	sampler2D normal_texture,
	vec3 world_position,
	vec3 world_normal,
	vec3 blending
) {
	vec3 normal_x = decode_normal_map(
		texture(normal_texture, world_position.yz).xyz
	);
	vec3 normal_y = decode_normal_map(
		texture(normal_texture, world_position.xz).xyz
	);
	vec3 normal_z = decode_normal_map(
		texture(normal_texture, world_position.xy).xyz
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
