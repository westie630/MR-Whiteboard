shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;
#include "ink_common.gdshaderinc"

// Ink on a canvas: blended ribbons, drawn in item order (render_priority) so overlapping ink never flickers.
uniform int style = 0;
varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	float aa = fwidth(UV.y);
	float cov = ink_coverage(style, abs(UV.y), UV.x, aa, v_local.xy);
	ALBEDO = ink_color(style, srgb_to_linear(COLOR.rgb), abs(UV.y));
	ALPHA = COLOR.a * cov;
}
