// HUD framed panel overlay (minimalist): a thin crisp hairline border with a
// faint edge falloff and short, quiet corner accents. Scanlines and sweep are
// optional and default to nearly off. Additive so it sits on the StyleBoxFlat
// fill behind it. Text-only per R3.
shader_type canvas_item;
render_mode blend_add;

// Pixel size of the Control this material is applied to (set from code so the
// border stays aspect-correct on non-square panels).
uniform vec2 rect_size = vec2(360.0, 218.0);

uniform vec4 border_color : source_color = vec4(0.30, 0.62, 0.86, 1.0);
uniform vec4 glow_color : source_color = vec4(0.20, 0.882, 1.0, 1.0);

uniform float border_width : hint_range(0.0, 8.0) = 1.0;
uniform float glow_width : hint_range(1.0, 60.0) = 8.0;
uniform float glow_strength : hint_range(0.0, 3.0) = 0.3;
uniform float corner_len : hint_range(0.0, 120.0) = 16.0;
uniform float corner_strength : hint_range(0.0, 2.0) = 0.5;

uniform float scanline_density : hint_range(0.0, 20.0) = 3.5;
uniform float scanline_strength : hint_range(0.0, 0.5) = 0.02;
uniform float sweep_speed : hint_range(0.0, 1.0) = 0.1;
uniform float sweep_strength : hint_range(0.0, 0.3) = 0.0;

void fragment() {
	vec2 px = UV * rect_size;
	vec2 d = min(px, rect_size - px);       // distance to nearest edge, per axis
	float edge = min(d.x, d.y);

	// Thin crisp border line hugging the frame.
	float border = 1.0 - smoothstep(border_width, border_width + 1.0, edge);

	// Very faint inward edge falloff (reads as a subtle depth cue, not a halo).
	float glow = exp(-edge / glow_width) * glow_strength;

	// Short, quiet L-shaped corner accents.
	float in_corner = step(d.x, corner_len) * step(d.y, corner_len);
	float bracket = in_corner * border * corner_strength;

	// Interior CRT-style scanlines (near off by default).
	float scan = (sin(px.y * scanline_density + TIME * 1.6) * 0.5 + 0.5) * scanline_strength;

	// Slow vertical sweep highlight (off by default).
	float sweep_y = fract(TIME * sweep_speed) * rect_size.y;
	float sweep = exp(-abs(px.y - sweep_y) / 8.0) * sweep_strength;

	vec3 col = glow_color.rgb * (glow + scan + sweep)
		+ border_color.rgb * border
		+ glow_color.rgb * bracket;
	float a = clamp(glow + border + bracket + scan + sweep, 0.0, 1.0);
	COLOR = vec4(col, a);
}
