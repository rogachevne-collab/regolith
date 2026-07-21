shader_type spatial;
render_mode diffuse_burley, cull_back;

#include "res://addons/zylann.voxel/shaders/transvoxel.gdshaderinc"

// Loose material drawn as a crust of packed stones rather than as a skin.
//
// The mesh under this shader is unchanged: the same transvoxel isosurface over
// the same low-passed occupancy field. What changed is that the isosurface is
// no longer asked to *be* the picture. It carries mass and silhouette; the
// stones live in the fragment stage, where a pebble can be seven centimetres
// across without the mesher ever resolving one.
//
// It answers two complaints, and they are separate mechanisms:
//
//   "slitted mass, like dough"  -> a cellular pebble field perturbs the normal
//       and tones each stone separately, so the surface stops being one
//       continuous substance lit by one continuous normal.
//
//   "ragged ugly edges"  -> at the silhouette, and only there, the same field
//       drives an alpha scissor. The outline stops being a quarter-metre
//       polygon boundary and becomes a scatter of stone tops. The tearing is
//       not smoothed away — it is denied a continuous line to be seen along.
//
// Deliberately not the planet terrain shader, which is what spoil wore before.
// That one is built for a crust: its finest band is a photo at a ~0.55 m period
// here, which across a heap is a few soft blotches and no grain at all at the
// scale the eye reads granularity. The rule it was obeying still holds and is
// obeyed here — spoil is the same substance as the ground, so the colours below
// sit near the crust's own value and wear the crust's own photo.

// --- substance -------------------------------------------------------------
// The ground's own rock photo. Not the base colour: it is divided by its own
// mean and applied as variation around one, so the heap keeps exactly the
// brightness the flat colours intend. Same arrangement as `granular_chip`,
// where guessing a gain here is what once made everything three times too dark.
uniform sampler2D u_albedo : source_color, hint_default_white,
	filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_normal : hint_normal,
	filter_linear_mipmap_anisotropic, repeat_enable;
// Texture cycles per metre. High on purpose — this is the period a stone can
// actually traverse, which is the whole difference between grain and blotches.
uniform float u_tex_scale : hint_range(0.5, 12.0) = 3.4;
// The Ground103 albedo's linear-space mean luminance, as measured for the chip
// shader. If the texture is swapped this must be re-measured, not guessed.
uniform float u_tex_mean : hint_range(0.01, 1.0) = 0.149;
uniform float u_tex_amount : hint_range(0.0, 1.0) = 0.55;
uniform float u_photo_normal : hint_range(0.0, 2.0) = 0.7;
// Broken rock, and the dust it settles into. Fresh breaks are darker than
// gardened surface by a few per cent, not by half.
uniform vec3 u_rock_color : source_color = vec3(0.46, 0.45, 0.43);
uniform vec3 u_dust_color : source_color = vec3(0.58, 0.57, 0.55);

// --- pebbles ---------------------------------------------------------------
// Edge of a stone in the fine band. Around the size of the chips the instanced
// path lays, so the two renderers describe the same material.
uniform float u_grain_size_m : hint_range(0.02, 0.4) = 0.075;
// How many fine stones fit across a coarse one. The coarse band is what sells
// the size hierarchy of a heap — one band alone reads as a texture, which is
// the failure the chip shader records under BOULDER_CHANCE.
uniform float u_coarse_ratio : hint_range(1.5, 8.0) = 3.2;
uniform float u_grain_relief : hint_range(0.0, 3.0) = 1.25;
uniform float u_coarse_relief : hint_range(0.0, 3.0) = 0.85;
// Turns depth-inside-the-stone into height. A Voronoi cell seeded at random in
// a unit grid runs to roughly a third of a cell at its middle, so around three
// takes a stone to full height at its centre and leaves the outer part of it
// as the bevel falling into the crack. Raise it for flatter tops and sharper
// cracks, lower it and the facets soften back toward domes.
uniform float u_facet_gain : hint_range(0.5, 8.0) = 3.0;
// Spread of per-stone value. Stones from one seam are near one grey, never at
// it; a heap all at exactly one value is paint.
uniform float u_grain_tone : hint_range(0.0, 0.6) = 0.20;
// How dark the gaps between stones go. This is what makes a crust of separate
// pieces cohere as one mass instead of reading as a bumpy skin: what shows
// between stones is the shadowed fines they are bedded in.
uniform float u_crevice_shade : hint_range(0.0, 1.0) = 0.55;
// Distance the fine band is worth paying for. Past it a 7 cm stone is well
// under a pixel and the field is only aliasing — the coarse band carries on
// alone, and past twice this the surface is plain triplanar again.
uniform float u_grain_end_m : hint_range(2.0, 120.0) = 26.0;

// --- silhouette ------------------------------------------------------------
// How much of the outline is allowed to dissolve into stones. Zero is the old
// hard polygon edge.
uniform float u_dissolve : hint_range(0.0, 1.0) = 0.60;
// How edge-on a fragment has to be before any of it dissolves. A ragged
// outline is only ever seen at the silhouette, so the clipping is confined
// there — the bulk of the heap facing the camera is never punctured, which is
// what keeps this from turning the mass see-through.
uniform float u_dissolve_start : hint_range(0.0, 1.0) = 0.55;
uniform float u_dissolve_end : hint_range(0.0, 1.0) = 0.96;

// The grazing test above closes the *outline*. It does nothing for the thin
// plates that stand along the fringe of a scatter, and one attempt at those is
// recorded here so it is not made twice: comparing the triangle's own plane
// against the mesher's normal and clipping where they disagree. It is inert,
// and the reason is worth keeping. A fringe plate is not a degenerate triangle
// carrying a borrowed normal — it *is* the local isosurface, so the field's
// gradient at its vertices is perpendicular to the plate exactly as it is
// anywhere else on the heap. The two normals agree, and no threshold on their
// disagreement can find something that does not disagree.

// --- frame -----------------------------------------------------------------
// World to the region's own frame. Set per region by
// `GranularVoxelRegionView`, and the reason the pebble field is trustworthy at
// all: shader varyings are float32 whatever the engine build does on the CPU,
// and a world position on a 9.5 km radius arrives quantised to about a
// millimetre with no mantissa left for `fract` at a 7 cm period. A region box
// is a couple of dozen metres across, so in its own frame there is precision to
// spare — and it stays that way however `REGION_CELLS` grows.
uniform mat4 u_local_from_world;
// Local up at the region — radial on a planetoid, so it cannot be a constant.
uniform vec3 u_up = vec3(0.0, 1.0, 0.0);
// Unused here, and kept because `GranularVoxelWorld._make_spoil_material`
// copies them off the live terrain material by name. Dropping them would make
// that copy silently miss.
uniform float u_radial_up : hint_range(0.0, 1.0, 1.0) = 0.0;
uniform float u_planet_radius : hint_range(0.0, 20000.0, 1.0) = 0.0;

// --- grade -----------------------------------------------------------------
// Same shape and same defaults as the crust's `grade_lunar`, so a heap and the
// ground it sits on are graded once and identically.
uniform float u_exposure : hint_range(0.3, 1.5, 0.01) = 0.52;
uniform float u_contrast : hint_range(0.5, 2.0, 0.01) = 1.0;
uniform float u_chroma : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float u_specular : hint_range(0.0, 0.5, 0.01) = 0.06;
uniform float u_roughness : hint_range(0.0, 1.0, 0.01) = 0.93;

varying vec3 v_local;
varying vec3 v_model;

// Integer-stable hash. A sin-hash is unusable here for the same reason it is
// unusable on the crust: it turns to mush well below the coordinates this game
// works in.
vec3 hash33(vec3 c) {
	uvec3 u = uvec3(ivec3(floor(c)));
	uint n = u.x * 1597334677u ^ u.y * 3812015801u ^ u.z * 2798796415u;
	n ^= n >> 13u;
	n *= 1274126177u;
	n ^= n >> 16u;
	uint a = n * 1103515245u + 12345u;
	uint b = a * 1103515245u + 12345u;
	return vec3(float(n), float(a), float(b)) * (1.0 / 4294967296.0);
}

// How far inside its own cell this point sits, which way the nearest wall of
// that cell faces, and which stone it belongs to.
//
// Distance to the cell *boundary*, not to the point that seeded it, and that is
// the whole difference between broken rock and bubble wrap. Distance to a point
// is a cone, so its contour is a circle and stones come out as round domes —
// and a plane tiled with circles is foam at any density, which is the failure
// `granular_chip` records under MAX_GRAINS_PER_CELL and which the first version
// of this reproduced exactly. The set of points nearer this seed than any other
// is a convex polyhedron, so measuring to its walls gives flat faces meeting in
// straight edges: a chip off something, not a bubble.
//
// Two passes over the same 27 neighbours, because the walls cannot be built
// until the owning seed is known. The gradient stays free, which is what keeps
// this affordable: the derivative of distance-to-a-plane is that plane's own
// normal, exactly as the derivative of distance-to-a-point was the direction to
// the point. So the facet and the normal that shades it still come out of one
// loop, with no finite differences anywhere.
//
// Points are recomputed in the second pass rather than kept from the first. The
// hash is a handful of integer ops; holding twenty-seven vec3 across the two
// passes would spill registers and cost more than recomputing them.
void pebble_field(vec3 p, out float border, out vec3 away, out float id) {
	vec3 base = floor(p);
	// Pass one: whose cell is this.
	float nearest = 1e9;
	vec3 seed = base;
	id = 0.0;
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec3 cell = base + vec3(float(i), float(j), float(k));
				vec3 h = hash33(cell);
				vec3 point = cell + h;
				float len2 = dot(p - point, p - point);
				if (len2 < nearest) {
					nearest = len2;
					seed = point;
					id = h.z;
				}
			}
		}
	}
	// Pass two: the nearest wall. Each other seed contributes the plane halfway
	// between it and ours, facing it; the distance to the closest of those is
	// how deep in the stone this point lies.
	border = 1e9;
	away = vec3(0.0, 1.0, 0.0);
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec3 cell = base + vec3(float(i), float(j), float(k));
				vec3 point = cell + hash33(cell);
				vec3 run = point - seed;
				float len2 = dot(run, run);
				// The owning seed itself, which has no wall against itself.
				if (len2 < 1e-6) {
					continue;
				}
				vec3 face = run * inversesqrt(len2);
				// Positive on our side of the halfway plane, so it falls to
				// zero exactly at the wall.
				float depth = dot((seed + point) * 0.5 - p, face);
				if (depth < border) {
					border = depth;
					// Outward along the wall's own normal, which is the
					// direction the facet falls away in — the same contract the
					// point version handed back.
					away = face;
				}
			}
		}
	}
}

// Triplanar sample of the photo, blended off the shaded normal. No UVs exist:
// the mesher emits none, which is why a plain textured material on this surface
// comes out as flat colour.
vec3 triplanar_rgb(sampler2D tex, vec3 p, vec3 blend) {
	return texture(tex, p.zy).rgb * blend.x
		+ texture(tex, p.xz).rgb * blend.y
		+ texture(tex, p.xy).rgb * blend.z;
}

// The normal map's tangent axes swizzled onto each projection, as a
// perturbation rather than a replacement. Mirror-faced projections take the
// bumps with the wrong handedness, which on broken rubble no eye can call
// wrong — the same cheap blend the chip shader uses.
vec3 triplanar_bump(sampler2D tex, vec3 p, vec3 blend) {
	vec2 bx = texture(tex, p.zy).rg * 2.0 - 1.0;
	vec2 by = texture(tex, p.xz).rg * 2.0 - 1.0;
	vec2 bz = texture(tex, p.xy).rg * 2.0 - 1.0;
	return vec3(0.0, bx.y, bx.x) * blend.x
		+ vec3(by.x, 0.0, by.y) * blend.y
		+ vec3(bz.x, bz.y, 0.0) * blend.z;
}

vec3 grade_lunar(vec3 c) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(l), c, u_chroma);
	c = vec3(0.32) + (c - vec3(0.32)) * u_contrast;
	return clamp(c * u_exposure, vec3(0.02), vec3(0.95));
}

void vertex() {
	VERTEX = get_transvoxel_position(VERTEX, CUSTOM0);
	v_model = VERTEX;
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_local = (u_local_from_world * vec4(world, 1.0)).xyz;
}

void fragment() {
	// The mesh's own normal is the shape of the mass and is kept as the base;
	// everything below perturbs it. Held in world space for the whole function
	// because the pebble field and the photo both live there.
	vec3 geom_view = normalize(NORMAL);
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(geom_view, 0.0)).xyz);
	// In the fragment stage VERTEX is the view-space position, so its length is
	// the camera distance and its direction is the view ray. CAMERA_POSITION_WORLD
	// is not usable in this build — measured on the crust, it disagrees with the
	// fragment's own world position by the better part of a diameter.
	float view_dist = length(VERTEX);
	vec3 view_dir = -VERTEX / max(view_dist, 1e-4);

	vec3 blend = pow(abs(n), vec3(4.0));
	blend /= blend.x + blend.y + blend.z;

	// --- pebbles -----------------------------------------------------------
	// The coarse band is always paid for: it is what the silhouette dissolves
	// along, and an outline that stops breaking up at range would put the torn
	// polygon edge back exactly where it is most visible against black sky.
	float coarse_size = u_grain_size_m * u_coarse_ratio;
	float c_border;
	vec3 c_away;
	float c_id;
	pebble_field(v_local / coarse_size, c_border, c_away, c_id);
	// Full height in the body of a stone, falling to nothing at its walls. The
	// gain decides how much of a stone is flat top and how much is the bevel
	// down to the crack: high and they are paving slabs, low and the facets
	// round off back toward the domes this replaced.
	float c_high = clamp(c_border * u_facet_gain, 0.0, 1.0);

	// The fine band dies with distance. Nothing is lost when it goes: a 7 cm
	// stone past ~26 m is well under a pixel, and a sub-pixel cellular field is
	// not detail, it is the shimmer that detail turns into.
	float fine_w = 1.0 - smoothstep(u_grain_end_m * 0.45, u_grain_end_m, view_dist);
	float f_high = 0.0;
	vec3 f_away = vec3(0.0);
	float f_id = 0.5;
	if (fine_w > 0.01) {
		float f_border;
		pebble_field(v_local / u_grain_size_m, f_border, f_away, f_id);
		f_high = clamp(f_border * u_facet_gain, 0.0, 1.0);
	}

	// Tilt the normal onto the stones. On a dome the surface leans away from
	// the centre, which is the direction the field already handed back, so the
	// perturbation is that vector with its normal component removed.
	vec3 c_tangent = c_away - n * dot(c_away, n);
	vec3 f_tangent = f_away - n * dot(f_away, n);
	// Weighted by height, so a stone's own face is tilted and the flat of the
	// gap between stones is left alone.
	vec3 relief = c_tangent * (u_coarse_relief * c_high)
		+ f_tangent * (u_grain_relief * f_high * fine_w);

	// --- photo -------------------------------------------------------------
	// Sampled in the region's frame rather than the world's, for the precision
	// reason above. Only the phase differs from the crust's own projection, and
	// a phase step at a 0.3 m period across rubble is not something an eye has
	// any way to see.
	vec3 tp = v_local * u_tex_scale;
	vec3 photo = triplanar_rgb(u_albedo, tp, blend) / u_tex_mean;
	photo = mix(vec3(1.0), photo, u_tex_amount);
	vec3 bump = triplanar_bump(u_normal, tp, blend);

	vec3 world_n = normalize(n + relief + bump * u_photo_normal * mix(0.35, 1.0, fine_w));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

	// --- colour ------------------------------------------------------------
	// How deep in the gaps this fragment sits. The gaps are where the fines
	// collect, so they go both dustier and darker: dustier because that is what
	// is in them, darker because a gap has to read as depth or the crust is a
	// bumpy skin again.
	float high = max(c_high, f_high * fine_w);
	float crevice = 1.0 - high;
	// Each stone its own value, coarse and fine rolled independently so a big
	// stone is not merely a big version of the small one beside it.
	float tone = 1.0
		+ (c_id - 0.5) * 2.0 * u_grain_tone * c_high
		+ (f_id - 0.5) * 2.0 * u_grain_tone * 0.6 * f_high * fine_w;
	vec3 base = mix(u_rock_color, u_dust_color, crevice * 0.65);
	base *= mix(1.0, 1.0 - u_crevice_shade, crevice * crevice);

	ALBEDO = grade_lunar(base * photo * tone);
	METALLIC = 0.0;
	ROUGHNESS = u_roughness;
	SPECULAR = u_specular;

	// --- silhouette --------------------------------------------------------
	// How edge-on the geometry is, from the unperturbed normal — the perturbed
	// one leans onto stones and would fire the dissolve in the middle of a face.
	float grazing = 1.0 - abs(dot(geom_view, view_dir));
	float edge = smoothstep(u_dissolve_start, u_dissolve_end, grazing);
	// Clipped against the stone field, so what survives at the outline is stone
	// tops and what goes is the gaps between them. Threshold rather than blend:
	// this stays in the opaque pass, and the shadow pass runs the same test, so
	// the heap's shadow breaks up with it. On the Moon that matters more than
	// the outline itself.
	ALPHA = clamp(c_high * 0.72 + f_high * fine_w * 0.28 + 0.06, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = edge * u_dissolve;
}
