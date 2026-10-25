class_name StylusRay
extends MeshInstance3D
## The line out of the stylus's nib along its body, like the Quest's own controller ray: bright at the nib and fading along its length.
## On something it can act on (the menu, a canvas, a drawing) it runs to the ring HandCursor draws there and keeps a faint tail up to it;
## on nothing it is a short beam that fades out (RAY_IDLE_LEN). A faint dark edge keeps it readable on a white canvas or a white wall.
## One quad, turned to face the eye about its own length in the vertex shader and never thinner than RAY_MIN_PX on the screen (fainter
## instead), so a far beam does not crawl.

const START := 0.004                       # m: the beam starts just out of the nib
const FADE_IN := 0.02                      # m: ...and comes up to full strength over this
const NEAR_A := 0.8                        # its strength at the nib...
const HIT_TAIL := 0.4                      # ...the part of it left at a ring

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled, skip_vertex_transform;

uniform vec3 from_pt;                      // world: the nib end
uniform vec3 to_pt;                        // world: the far end
uniform float width = 0.004;               // m, with the dark edge
uniform float min_px = 1.5;
uniform float fade_in = 0.02;              // m from the nib to full strength
uniform float fade_len = 0.5;              // m from the nib to `tail`
uniform float tail = 0.0;
uniform vec4 near_col : source_color = vec4(1.0);
uniform vec4 far_col : source_color = vec4(1.0);
varying float v_along;                     // m from the nib
varying float v_cov;                       // < 1 where the beam is drawn wider than it is

void vertex() {
	vec3 a = (VIEW_MATRIX * vec4(from_pt, 1.0)).xyz;
	vec3 b = (VIEW_MATRIX * vec4(to_pt, 1.0)).xyz;
	vec3 p = mix(a, b, UV.x);
	vec3 side = cross(b - a, p);
	side = length(side) > 1e-12 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	float px = 2.0 * max(-p.z, 1e-3) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);   // one pixel at this depth
	float w = max(width, min_px * px);
	v_cov = width / w;
	v_along = UV.x * distance(from_pt, to_pt);
	VERTEX = p + side * UV.y * w * 0.5;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float across = abs(UV.y);
	float edge = clamp((1.0 - across) / max(fwidth(UV.y), 1e-4), 0.0, 1.0);
	float core = 1.0 - smoothstep(0.35, 0.6, across);
	float rim = 0.6 * (1.0 - smoothstep(0.6, 1.0, across));
	float k = smoothstep(0.0, fade_len, v_along);
	vec4 c = mix(near_col, far_col, k);
	ALBEDO = c.rgb * core;
	ALPHA = c.a * max(core, rim) * edge * v_cov * smoothstep(0.0, fade_in, v_along) * (1.0 - (1.0 - tail) * k);
}
"""

static var _shader: Shader

var mat: ShaderMaterial


func _init() -> void:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	mat = ShaderMaterial.new()
	mat.shader = _shader
	mat.render_priority = 104              # under HandCursor's ring (105), over the panels (100)
	mat.set_shader_parameter("width", InputTuning.RAY_W)
	mat.set_shader_parameter("min_px", InputTuning.RAY_MIN_PX)
	mat.set_shader_parameter("fade_in", FADE_IN)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, -1), Vector2(0, 1), Vector2(1, -1), Vector2(1, 1)])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)
	mesh = m
	material_override = mat
	custom_aabb = AABB(Vector3.ONE * -1000.0, Vector3.ONE * 2000.0)   # the shader places it: never culled
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## Show the beam from the nib along `dir`. `end`: the point it is on (the beam stops `gap` short of it, at the ring's edge), or null for a
## short beam into nothing. `col`: the ring's colour there; `pressed` tints the whole beam with it.
func aim(tip: Vector3, dir: Vector3, end: Variant, col: Color, pressed: bool, gap: float = 0.0) -> void:
	var d := dir.normalized()
	var from := tip + d * START
	var length := InputTuning.RAY_IDLE_LEN
	var tail := 0.0
	if end != null:
		var along := ((end as Vector3) - from).dot(d) - gap
		if along < FADE_IN:
			visible = false                # the target is at the nib: the ring says it all
			return
		length = minf(along, InputTuning.RAY_MAX_LEN)
		tail = HIT_TAIL
	var near := Color.WHITE.lerp(col, 0.6 if pressed else 0.0)
	mat.set_shader_parameter("from_pt", from)
	mat.set_shader_parameter("to_pt", from + d * length)
	mat.set_shader_parameter("fade_len", length)
	mat.set_shader_parameter("tail", tail)
	mat.set_shader_parameter("near_col", Color(near.r, near.g, near.b, NEAR_A))
	mat.set_shader_parameter("far_col", Color(col.r, col.g, col.b, NEAR_A))
	visible = true


## Where the beam runs, for tests and the log: [from, to] in world space.
func span() -> Array:
	return [mat.get_shader_parameter("from_pt"), mat.get_shader_parameter("to_pt")]
