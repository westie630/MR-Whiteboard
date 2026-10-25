shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

#include "bend.gdshaderinc"

// The canvas grid: drawn on one quad in the frame's plane. It is only visible near the pen / hand (focus), it fades out as the
// viewer walks away (view_alpha) and it fades at the canvas edges. All lengths are the frame's own metres.
uniform vec4 bounds = vec4(-0.6, -0.4, 0.6, 0.4);   // xmin, ymin, xmax, ymax
uniform float edge_soft = 0.22;
uniform vec3 focus = vec3(0.0);
uniform float focus_r = 0.55;
uniform float focus_floor = 0.16;                   // grid brightness far from the focus (0 = invisible, 1 = uniform)
uniform float view_alpha = 1.0;
uniform float minor = 0.05;
uniform int major_every = 5;
uniform int style = 0;                              // 0 lines, 1 dots, 2 none
uniform vec4 line_color : source_color = vec4(0.55, 0.9, 1.0, 1.0);
uniform vec4 backing : source_color = vec4(1.0, 1.0, 1.0, 0.0);
uniform float hover = 0.0;                          // 0..1: the border lights up when a pen or hand is near
uniform vec2 canvas_shift = vec2(0.0);              // curved desk: the mesh is laid out in surface coordinates, the grid pattern belongs to the canvas

varying vec2 lp;
varying vec2 v_surf;

void vertex() {
	lp = VERTEX.xy + canvas_shift;
	v_surf = desk_surf(VERTEX);
	VERTEX = desk_bend(VERTEX);
}

float line_mask(vec2 p, float cell, float thickness_px) {
	vec2 g = p / cell;
	vec2 w = max(fwidth(g), vec2(1e-5));
	vec2 f = abs(fract(g - 0.5) - 0.5) / w;
	return 1.0 - clamp(min(f.x, f.y) - (thickness_px - 1.0) * 0.5, 0.0, 1.0);
}

void fragment() {
	if (desk_clipped(v_surf)) {
		discard;
	}
	float dx = min(lp.x - bounds.x, bounds.z - lp.x);
	float dy = min(lp.y - bounds.y, bounds.w - lp.y);
	float d = min(dx, dy);
	float a_edge = smoothstep(0.0, edge_soft, d);
	float a_hard = smoothstep(0.0, edge_soft * 0.35, d);
	float fd = length(lp - focus.xy);
	float a_focus = mix(focus_floor, 1.0, 1.0 - smoothstep(focus_r * 0.3, focus_r, fd));
	float grid = 0.0;
	if (style == 0) {
		float minor_l = line_mask(lp, minor, 1.0);
		float major_l = line_mask(lp, minor * float(major_every), 1.6);
		grid = max(minor_l * 0.5, major_l * 0.9);
	} else if (style == 1) {
		vec2 g = lp / minor;
		vec2 q = (fract(g + 0.5) - 0.5) * minor;
		float aa = max(fwidth(lp.x), fwidth(lp.y));
		vec2 gm = lp / (minor * float(major_every));
		vec2 qm = (fract(gm + 0.5) - 0.5) * minor * float(major_every);
		float dots = 1.0 - smoothstep(0.0016 - aa, 0.0016 + aa, length(q));
		float dots_m = 1.0 - smoothstep(0.0028 - aa, 0.0028 + aa, length(qm));
		grid = max(dots * 0.6, dots_m);
	}
	float ga = grid * a_edge * a_focus * view_alpha * line_color.a;
	float border = (1.0 - smoothstep(0.0008, 0.0026, d)) * hover;
	float ba = border * 0.55;
	float back_a = backing.a * a_hard * clamp(view_alpha * 1.4, 0.0, 1.0);
	// composite grid over backing, border over both
	float a1 = ga + back_a * (1.0 - ga);
	vec3 c1 = (line_color.rgb * ga + backing.rgb * back_a * (1.0 - ga)) / max(a1, 1e-4);
	float a2 = ba + a1 * (1.0 - ba);
	vec3 c2 = (vec3(0.9, 1.0, 1.0) * ba + c1 * a1 * (1.0 - ba)) / max(a2, 1e-4);
	ALBEDO = c2;
	ALPHA = a2;
}
