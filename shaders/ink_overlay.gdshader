shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;
#include "ink_common.gdshaderinc"
#include "bend.gdshaderinc"

// Ink that is drawn after everything on the canvas (the selection, handles and markers of a bent canvas): ink_canvas, drawn late (render
// priority) and not clipped to the shown part of the surface (the markers stand outside it). It is depth tested, so a model or a drawing in
// the air in front of it hides it like it hides the canvas; nothing on a canvas writes depth, so the canvas's own contents never do.
uniform int style = 0;
varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
	VERTEX = desk_bend(VERTEX);
}

void fragment() {
	float aa = fwidth(UV.y);
	float cov = ink_coverage(style, abs(UV.y), UV.x, aa, v_local.xy);
	ALBEDO = ink_color(style, srgb_to_linear(COLOR.rgb), abs(UV.y));
	ALPHA = COLOR.a * cov;
}
