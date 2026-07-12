// HUD reticle (minimalist): a clean gapped crosshair with a tiny center dot.
// Target brackets and glow default to near-off. `color` carries target state
// (cyan = valid). Text-only per R3.
shader_type canvas_item;
render_mode blend_add;

uniform vec2 rect_size = vec2(64.0, 64.0);
uniform vec4 color : source_color = vec4(0.20, 0.882, 1.0, 1.0);

uniform float gap : hint_range(0.0, 30.0) = 6.0;    // inner clear radius (px)
uniform float len : hint_range(2.0, 40.0) = 9.0;    // arm length (px)
uniform float thick : hint_range(0.5, 4.0) = 1.0;   // arm half-thickness (px)
uniform float dot_size : hint_range(0.0, 4.0) = 1.0;
uniform float bracket_r : hint_range(0.0, 40.0) = 18.0;   // corner-bracket radius
uniform float bracket_len : hint_range(0.0, 16.0) = 4.0;  // corner-bracket arm len
uniform float bracket_strength : hint_range(0.0, 1.0) = 0.0; // off by default
uniform float glow_strength : hint_range(0.0, 2.0) = 0.15;

float arm(float along, float across) {
	float a = (1.0 - smoothstep(thick, thick + 1.0, across));
	float lo = smoothstep(gap - 0.5, gap + 0.5, along);
	float hi = 1.0 - smoothstep(gap + len, gap + len + 1.0, along);
	return a * lo * hi;
}

// One edge of the optional square target bracket (segment near coord == bracket_r).
float bracket_edge(float on, float along) {
	float line = 1.0 - smoothstep(thick, thick + 1.0, abs(on - bracket_r));
	float span = smoothstep(bracket_r - bracket_len, bracket_r - bracket_len + 0.5, along)
		* (1.0 - smoothstep(bracket_r, bracket_r + 0.5, along));
	return line * span;
}

void fragment() {
	vec2 px = UV * rect_size - rect_size * 0.5;   // centered coordinates
	vec2 ap = abs(px);

	float cross = clamp(arm(ap.x, ap.y) + arm(ap.y, ap.x), 0.0, 1.0);

	float r = length(px);
	float dot = 1.0 - smoothstep(dot_size, dot_size + 1.0, r);

	// Optional (near-off) corner brackets.
	float brackets = clamp(
		bracket_edge(ap.y, ap.x) + bracket_edge(ap.x, ap.y), 0.0, 1.0) * bracket_strength;

	// Very faint glow hugging the arms.
	float near = min(ap.x, ap.y);
	float glow = exp(-near / 2.0) * step(gap - 2.0, max(ap.x, ap.y)) * glow_strength * 0.25;

	float mask = clamp(cross + dot + brackets, 0.0, 1.0);
	vec3 col = color.rgb * (mask + glow);
	COLOR = vec4(col, clamp(mask + glow * 0.5, 0.0, 1.0));
}
