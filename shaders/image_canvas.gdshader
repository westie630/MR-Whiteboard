shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;
#include "bend.gdshaderinc"

// A picture on a canvas (Item.IMAGE): its texture with mipmaps and anisotropic filtering, so it stays smooth from near and far, drawn in
// item order (render_priority) with the ink. On a curved desk it bends with the surface like everything else (the quad is cut into strips).
uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float opacity = 1.0;
varying vec2 v_surf;

void vertex() {
	v_surf = desk_surf(VERTEX);
	VERTEX = desk_bend(VERTEX);
}

void fragment() {
	if (desk_clipped(v_surf)) {
		discard;
	}
	vec4 c = texture(tex, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a * opacity;
}
