shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add, shadows_disabled, fog_disabled;
#include "ink_common.gdshaderinc"
#include "bend.gdshaderinc"

// Glowing ink (neon): added to what is behind it, so it lights up the passthrough image.
uniform int style = 5;
varying vec3 v_local;
varying vec2 v_surf;

void vertex() {
	v_local = VERTEX;
	v_surf = desk_surf(VERTEX);
	VERTEX = desk_bend(VERTEX);
}

void fragment() {
	if (desk_clipped(v_surf)) {
		discard;
	}
	float aa = fwidth(UV.y);
	float cov = ink_coverage(style, abs(UV.y), UV.x, aa, v_local.xy);
	ALBEDO = ink_color(style, srgb_to_linear(COLOR.rgb), abs(UV.y)) * COLOR.a * cov;
	ALPHA = 1.0;
}
