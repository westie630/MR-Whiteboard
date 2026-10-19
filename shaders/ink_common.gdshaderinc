// Shared pieces of the ink shaders. UV.x = distance along the stroke (metres), UV.y = -1..1 across it (ribbon) or around it (tube).

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 0 = solid pen, 1 marker, 2 highlighter, 3 pencil, 4 calligraphy, 5 neon, 6 spray, 7 dashed
// `across` is |UV.y|, `aa` the width of one pixel in UV.y units. Returns the coverage 0..1.
float ink_coverage(int style, float across, float along, float aa, vec2 grain_pos) {
	float edge = clamp((1.0 - across) / max(aa, 1e-4), 0.0, 1.0);
	if (style == 3) {
		float n = value_noise(grain_pos * 900.0) * 0.6 + value_noise(grain_pos * 2300.0) * 0.4;
		return edge * (0.45 + 0.55 * smoothstep(0.15, 0.85, n));
	}
	if (style == 5) {
		return pow(clamp(1.0 - across, 0.0, 1.0), 0.8);
	}
	if (style == 6) {
		float n = hash21(floor(grain_pos * 1500.0));
		return pow(clamp(1.0 - across, 0.0, 1.0), 1.4) * (0.55 + 0.45 * n);
	}
	if (style == 7) {
		float period = 0.02;
		return edge * step(fract(along / period), 0.6);
	}
	return edge;
}

vec3 ink_color(int style, vec3 base, float across) {
	if (style == 5) {
		float core = pow(clamp(1.0 - across * 1.6, 0.0, 1.0), 2.0);
		return mix(base, vec3(1.0), core * 0.75) * 1.25;
	}
	if (style == 1) {
		return base * (1.0 - 0.14 * smoothstep(0.55, 1.0, across));
	}
	return base;
}
