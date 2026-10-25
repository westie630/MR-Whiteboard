shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
// A picture of a PDF page. The colour and the transparency are two textures (a PDF keeps them apart: a soft mask is a second image); a
// stencil mask has no colour texture, it paints `fill` where its coverage says so.

uniform sampler2D tex_color : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D tex_alpha : hint_default_white, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 fill : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float opacity = 1.0;
uniform bool use_color = true;
uniform bool use_alpha = false;
uniform bool use_mask = false;                      // drawn through a soft mask (see pdf_masked.gdshader)
uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform vec4 mask_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float outside = 0.0;

varying vec2 page_pos;

void vertex() {
	page_pos = VERTEX.xy;
}

void fragment() {
	vec3 rgb = fill.rgb;
	float a = fill.a;
	if (use_color) {
		rgb = texture(tex_color, UV).rgb;
		a = 1.0;
	}
	if (use_alpha) {
		a *= texture(tex_alpha, UV).r;
	}
	if (use_mask) {
		vec2 muv = (page_pos - mask_rect.xy) / mask_rect.zw;
		float m = outside;
		if (muv.x >= 0.0 && muv.x <= 1.0 && muv.y >= 0.0 && muv.y <= 1.0) {
			m = texture(mask_tex, vec2(muv.x, 1.0 - muv.y)).r;
		}
		a *= m;
	}
	ALBEDO = rgb;
	ALPHA = pow(clamp(a * opacity, 0.0, 1.0), 0.6);    // (see PdfBudget.alpha_power: blending here is in linear light)
}
