shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, blend_mix, shadows_disabled, fog_disabled;
#include "ink_common.gdshaderinc"

// 3D strokes drawn in the air: round tubes with a cheap fake light so the depth reads against the passthrough image.
uniform int style = 0;
uniform bool glow = false;
varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	vec3 n = normalize(NORMAL);
	float lit = 0.62 + 0.38 * clamp(dot(n, vec3(0.0, 0.0, 1.0)), 0.0, 1.0);
	vec3 col = srgb_to_linear(COLOR.rgb);
	float a = COLOR.a;
	if (style == 7) {
		if (fract(UV.x / 0.02) > 0.6) {
			discard;
		}
	}
	if (style == 3) {
		float g = value_noise(v_local.xy * 900.0 + v_local.z * 700.0);
		lit *= 0.8 + 0.2 * g;
	}
	if (glow) {
		float core = clamp(dot(n, vec3(0.0, 0.0, 1.0)), 0.0, 1.0);
		col = mix(col, vec3(1.0), pow(core, 3.0) * 0.7) * 1.2;
		lit = 1.0;
	}
	ALBEDO = col * lit;
	ALPHA = a;
}
