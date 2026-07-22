// HUD vital/energy bar (minimalist): dark segmented track with a calm colored
// fill, a flat glossy gradient and a very subtle leading edge. No bright pulse.
// Text-only canvas_item shader per R3. Drive `fill` (0..1) from code.
shader_type canvas_item;

uniform vec2 rect_size = vec2(232.0, 10.0);
uniform float fill : hint_range(0.0, 1.0) = 0.72;

uniform vec4 fill_color : source_color = vec4(0.20, 0.882, 1.0, 1.0);
uniform vec4 track_color : source_color = vec4(0.05, 0.078, 0.106, 1.0);

uniform float segments : hint_range(0.0, 60.0) = 24.0;
uniform float gap_ratio : hint_range(0.0, 0.5) = 0.16;
uniform float glow_strength : hint_range(0.0, 2.0) = 0.22;
uniform float lead_strength : hint_range(0.0, 2.0) = 0.35;

void fragment() {
	float filled = step(UV.x, fill);

	// Segment gaps: thin dark separators across the bar. Measured in local
	// pixels, not UV fractions — a UV-space step lands the separators on
	// fractional pixels, so on a short bar some gaps vanish and their
	// neighbours double, which reads as a ragged, uneven track. Clamped to at
	// least one pixel and smoothed over one pixel so the spacing stays even at
	// any width.
	float pitch_px = rect_size.x / max(segments, 1.0);
	float gap_px = min(max(pitch_px * gap_ratio, 1.0), pitch_px * 0.5);
	float phase_px = mod(UV.x * rect_size.x, pitch_px);
	float gap = smoothstep(
		pitch_px - gap_px - 0.5,
		pitch_px - gap_px + 0.5,
		phase_px
	);

	// Gentle glossy vertical gradient.
	float grad = 1.0 - abs(UV.y - 0.5) * 0.9;

	vec3 col = track_color.rgb;
	float a = track_color.a;

	if (filled > 0.5) {
		col = fill_color.rgb * (0.62 + grad * 0.4);
		a = 1.0;
	}

	// Punch the segment gaps into whatever is underneath.
	col *= (1.0 - gap * 0.7);

	// Subtle static leading edge (no pulsing).
	float edge_d = abs(UV.x - fill) * rect_size.x;
	float lead = exp(-edge_d / 5.0) * lead_strength;
	col += fill_color.rgb * lead;
	a = max(a, lead);

	// Faint additive glow inside the filled region.
	col += fill_color.rgb * filled * glow_strength * 0.18;

	COLOR = vec4(col, clamp(a, 0.0, 1.0));
}
