// Abstract, non-branded mission emblem: a thin orbital ring with an ascending
// tick and a small "satellite" dot on the orbit. Single-color line glyph, drawn
// as a crisp canvas_item shader (no logo, no trademark). Text-only per R3.
shader_type canvas_item;

uniform vec4 color : source_color = vec4(0.20, 0.882, 1.0, 1.0);
uniform float radius : hint_range(0.2, 0.9) = 0.6;
uniform float line_w : hint_range(0.01, 0.2) = 0.055;

float seg(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;   // centered [-1,1]
	float aa = fwidth(p.x) * 1.5 + 0.02;

	float r = length(p);
	float ring = 1.0 - smoothstep(line_w, line_w + aa, abs(r - radius));

	// Short ascending stroke sitting OUTSIDE the ring (an orbit-motion tick),
	// tipped with a small satellite dot. Never crosses the centre.
	vec2 dir = normalize(vec2(1.0, -1.0));   // up-right (canvas Y is downward)
	vec2 base = dir * radius;
	vec2 tip = dir * (radius + 0.42);
	float tick = 1.0 - smoothstep(line_w, line_w + aa, seg(p, base, tip));
	float dot = 1.0 - smoothstep(line_w * 1.7, line_w * 1.7 + aa, length(p - tip));

	float mask = clamp(max(ring, max(tick, dot)), 0.0, 1.0);
	COLOR = vec4(color.rgb, mask * color.a);
}
