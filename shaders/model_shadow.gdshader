shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

// The soft shadow under a 3D model, lying on the real surface below it (ModelNode). Darkest in the middle of the model's footprint, gone at
// the quad's edge; `strength` fades it as the model rises off the surface. Unshaded: it darkens the passthrough picture the same everywhere.

uniform float strength = 0.45;
uniform float core = 0.55;          // how much of the footprint is fully dark (0..1 of the ellipse)

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float a = 1.0 - smoothstep(core * 0.5, 1.0, r);
	ALBEDO = vec3(0.0);
	ALPHA = strength * a * a;
}
