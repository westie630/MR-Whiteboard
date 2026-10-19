shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add, shadows_disabled, fog_disabled;
#include "ink_common.gdshaderinc"

// Glowing ink (neon): added to what is behind it, so it lights up the passthrough image.
uniform int style = 5;
varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	float aa = fwidth(UV.y);
	float cov = ink_coverage(style, abs(UV.y), UV.x, aa, v_local.xy);
	ALBEDO = ink_color(style, srgb_to_linear(COLOR.rgb), abs(UV.y)) * COLOR.a * cov;
	ALPHA = 1.0;
}
