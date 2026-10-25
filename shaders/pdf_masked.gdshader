shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
// Coloured triangles of a PDF page that are drawn through a soft mask: what shows is multiplied by the mask, a grey picture of the area
// the mask's own drawing covers (outside that area the mask has the value `outside`, the backdrop of its group).

uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform vec4 mask_rect = vec4(0.0, 0.0, 1.0, 1.0);   // x, y, width, height of the picture, in page points
uniform float outside = 0.0;

varying vec2 page_pos;

void vertex() {
	page_pos = VERTEX.xy;
}

void fragment() {
	vec2 uv = (page_pos - mask_rect.xy) / mask_rect.zw;
	float m = outside;
	if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
		m = texture(mask_tex, vec2(uv.x, 1.0 - uv.y)).r;
	}
	vec3 c = COLOR.rgb;
	ALBEDO = mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), step(c, vec3(0.04045)));
	ALPHA = pow(clamp(COLOR.a * m, 0.0, 1.0), 0.6);
}
