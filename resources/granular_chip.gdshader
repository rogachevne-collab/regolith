shader_type spatial;
render_mode diffuse_burley, cull_back;

// Chips of broken rock, drawn by `GranularGrainShell` as a MultiMesh.
//
// Deliberately not the planet terrain shader, which is what the first pass used
// and why the chips came out as scattered coal. That one is world-space
// triplanar with a three-metre texture period: a ten-centimetre chip lands in a
// nearly constant patch of the photo and takes whatever value happens to be
// there, so a field of them is randomly black and grey. Its normals come from a
// helper built for transvoxel geometry, which a chip is not.
//
// The rule that still holds is the one that made the heap stop reading as mud:
// spoil is the same substance as the ground, so these colours belong near the
// ground's own value. Fresh breaks are darker than gardened surface — by a few
// per cent, not by half.

uniform vec3 u_rock_color : source_color = vec3(0.44, 0.43, 0.41);
// What a chip lying deep in the fines wears. Nearer the ground's value, because
// that is what it is: a stone with dust on it.
uniform vec3 u_dust_color : source_color = vec3(0.58, 0.57, 0.55);
// The ground's own rock photo, laid over the flat colours above. Sampled
// triplanar in world space: the chips share one mesh, so their surfaces can
// only differ by where they stand, and world space is exactly that. The period
// has to be small — this is the same family of texture whose three-metre
// period on the planet shader made chips read as scattered coal, and the cure
// is not a different photo, it is a period a ten-centimetre chip can actually
// traverse.
uniform sampler2D u_albedo : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Texture repeats per metre. Around three, a chip crosses a third of a tile —
// visible grain without the tile itself ever reading.
uniform float u_tex_scale : hint_range(0.5, 8.0) = 3.0;
// The photo's own average, measured: linear-space mean luminance 0.149. The
// sample is divided by it, so the photo contributes *variation around one*
// and the chip keeps exactly the brightness its flat colours intended — a
// guessed gain here is how the whole heap once came out three times too dark.
uniform float u_tex_mean : hint_range(0.01, 1.0) = 0.149;
// How much of the photo's contrast the chip wears. Full is the source's own
// blotches, hotspots and all; zero is flat paint again.
uniform float u_tex_amount : hint_range(0.0, 1.0) = 0.7;
// The matching normal map, projected the same three ways. The facets shade a
// chip as cut planes; this puts mineral grain inside each plane. Only the RG
// channels are read — the VRAM normal-map import keeps nothing else — and the
// swizzle blend needs nothing else.
uniform sampler2D u_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float u_normal_strength : hint_range(0.0, 2.0) = 0.8;
// Fresh regolith glints — tiny specular sparks on clean cut faces, gone the
// moment a chip is dusted over. Sourced from the albedo photo sampled far off
// its own scale, thresholded to its top few per cent, so the sparks are rare
// points that shift as the camera moves. Specular is otherwise all but off:
// the base of this material is bone-dry rock.
uniform float u_sparkle : hint_range(0.0, 1.0) = 0.35;
uniform float u_roughness : hint_range(0.0, 1.0) = 1.0;
// Local up. Radial on a planetoid, so the view sets it per region.
uniform vec3 u_up = vec3(0.0, 1.0, 0.0);
// How dark a chip's underside goes, and over what height.
//
// This is the whole answer to making a dense cluster read as one mass instead
// of a pile of separate objects, and it costs nothing: what shows between the
// stones is their own shadowed bases, which is exactly what shows between real
// stones. Nothing here needs the chips to be bigger.
uniform float u_base_shade : hint_range(0.0, 1.0) = 0.5;
uniform float u_shade_span_m : hint_range(0.01, 0.5) = 0.09;
// How dark the cell plugs are worn against the dust. A plug is the mass a gap
// between stones opens onto, and it has to be darker than any stone so the gap
// reads as depth — but not black, or every gap is a hole punched in the heap.
// At 0.55 the plugs came out the same value as the chips and read as one more
// layer of stones, which put their regularity on display; held down here they
// recede to what they are, the dark behind the stones.
uniform float u_plug_shade : hint_range(0.0, 1.0) = 0.4;

varying float v_rise;
varying float v_buried;
varying float v_plug;
varying float v_tone;
varying vec3 v_world;

void vertex() {
	// How far into the material this chip is sitting, handed over per instance.
	v_buried = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	// Whether this instance is a cell plug rather than a chip.
	v_plug = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
	// Each piece's own light or dark cast. Stones from one seam are near one
	// value, never at it — a heap all at exactly the same grey is paint.
	v_tone = mix(0.85, 1.15, clamp(INSTANCE_CUSTOM.z, 0.0, 1.0));
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world = world;
	vec3 centre = MODEL_MATRIX[3].xyz;
	v_rise = dot(world - centre, normalize(u_up));
}

void fragment() {
	// Facet the chip from its own geometry, whatever normals the mesh carries.
	// A low-polygon ball shaded with interpolated normals is a smooth blob —
	// the first attempt proved that, it read as foam — but the same ball shaded
	// flat is a chip with cut edges, which is the chamfer without a chamfered
	// mesh. Signed against the interpolated normal so it cannot come out
	// inside-out on either winding convention.
	vec3 faceted = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = faceted * sign(dot(faceted, NORMAL));
	// The photo, projected from whichever world axis each facet faces best.
	// Blended off the faceted normal, so every cut face takes the texture
	// square-on rather than smeared along a curve the chip does not have.
	vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 blend = pow(abs(world_n), vec3(4.0));
	blend /= blend.x + blend.y + blend.z;
	vec2 uv_x = v_world.zy * u_tex_scale;
	vec2 uv_y = v_world.xz * u_tex_scale;
	vec2 uv_z = v_world.xy * u_tex_scale;
	vec3 grain = (
		texture(u_albedo, uv_x).rgb * blend.x
		+ texture(u_albedo, uv_y).rgb * blend.y
		+ texture(u_albedo, uv_z).rgb * blend.z
	) / u_tex_mean;
	grain = mix(vec3(1.0), grain, u_tex_amount);
	// The normal map's tangent axes swizzled onto each projection's world
	// axes, added to the faceted normal as a perturbation. The cheap blend:
	// mirror-faced projections take the bumps with the wrong handedness,
	// which on broken rubble no eye can call wrong.
	vec2 bump_x = texture(u_normal, uv_x).rg * 2.0 - 1.0;
	vec2 bump_y = texture(u_normal, uv_y).rg * 2.0 - 1.0;
	vec2 bump_z = texture(u_normal, uv_z).rg * 2.0 - 1.0;
	vec3 bump = (
		vec3(0.0, bump_x.y, bump_x.x) * blend.x
		+ vec3(bump_y.x, 0.0, bump_y.y) * blend.y
		+ vec3(bump_z.x, bump_z.y, 0.0) * blend.z
	);
	world_n = normalize(world_n + bump * u_normal_strength);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
	// A buried chip wears the dust it is lying in; a proud one stays clean. So
	// a pile reads as a dusty mass with stones standing out of it, and a lone
	// chip on bare ground still reads as a stone.
	vec3 base = mix(u_rock_color, u_dust_color, v_buried);
	// A plug is not a stone, it is what shows between the stones: the shadowed
	// mass of the heap itself. Dust-coloured and held down, so a gap in the
	// chips lands on something that reads as inside rather than as sky or as
	// one more rock.
	base = mix(base, u_dust_color * u_plug_shade, v_plug);
	float rise = clamp(v_rise / u_shade_span_m + 0.5, 0.0, 1.0);
	ALBEDO = base * grain * v_tone * mix(1.0 - u_base_shade, 1.0, rise);
	float glint_src = texture(
		u_albedo, uv_y * 11.3 + uv_x * 5.7 + uv_z * 2.9
	).r / u_tex_mean;
	float glint = smoothstep(1.45, 1.9, glint_src)
		* (1.0 - v_buried) * (1.0 - v_plug) * u_sparkle;
	SPECULAR = 0.03 + glint * 0.5;
	ROUGHNESS = mix(u_roughness, 0.25, glint);
}
