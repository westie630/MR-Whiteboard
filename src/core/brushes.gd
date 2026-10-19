class_name Brushes
extends RefCounted
## Brush styles. A brush decides the look of a stroke (shader style, transparency, how pressure changes the width) and
## builds the materials. 2D canvas ink is blended and drawn in item order; 3D strokes are opaque tubes.

const LIST := [
	{"id": "pen", "name": "Pen", "style": 0, "width_mul": 1.0, "alpha": 1.0, "pressure": 0.55, "caps": true},
	{"id": "marker", "name": "Marker", "style": 1, "width_mul": 2.6, "alpha": 0.92, "pressure": 0.15, "caps": false},
	{"id": "highlighter", "name": "Highlighter", "style": 2, "width_mul": 7.0, "alpha": 0.32, "pressure": 0.0, "caps": false, "under": true},
	{"id": "pencil", "name": "Pencil", "style": 3, "width_mul": 0.8, "alpha": 0.9, "pressure": 0.7, "caps": true},
	{"id": "calligraphy", "name": "Calligraphy", "style": 4, "width_mul": 2.4, "alpha": 1.0, "pressure": 0.2, "caps": false, "nib": 0.7853982},
	{"id": "neon", "name": "Neon", "style": 5, "width_mul": 2.2, "alpha": 1.0, "pressure": 0.3, "caps": true, "add": true},
	{"id": "spray", "name": "Spray", "style": 6, "width_mul": 5.0, "alpha": 0.8, "pressure": 0.4, "caps": true},
	{"id": "dashed", "name": "Dashed", "style": 7, "width_mul": 1.0, "alpha": 1.0, "pressure": 0.2, "caps": false},
]

static var _canvas_shader: Shader
static var _canvas_add_shader: Shader
static var _tube_shader: Shader
static var _cache := {}


static func get_def(id: String) -> Dictionary:
	for b in LIST:
		if b.id == id:
			return b
	return LIST[0]


static func name_of(id: String) -> String:
	return str(get_def(id).name)


## Width of a stroke point: the nominal width scaled by the brush and by how hard the pen is pressed.
static func width_at(brush_id: String, base_width: float, pressure: float) -> float:
	var b := get_def(brush_id)
	var k: float = b.pressure
	return base_width * float(b.width_mul) * (1.0 - k + k * clampf(pressure, 0.05, 1.0) * 1.2)


## Drawing priority band: highlighter ink goes under everything, shape fills under outlines.
static func priority(brush_id: String, z: int, part: String = "ink") -> int:
	var under: bool = get_def(brush_id).get("under", false)
	if part == "fill":
		return -100 + (z % 24)
	if under:
		return -127 + (z % 26)
	return -70 + (z % 150)


## Material for 2D canvas ink of a brush at a drawing priority.
static func canvas_material(brush_id: String, prio: int) -> ShaderMaterial:
	var key := "c|%s|%d" % [brush_id, prio]
	if _cache.has(key):
		return _cache[key]
	var b := get_def(brush_id)
	var m := ShaderMaterial.new()
	if b.get("add", false):
		if _canvas_add_shader == null:
			_canvas_add_shader = load("res://shaders/ink_canvas_add.gdshader")
		m.shader = _canvas_add_shader
	else:
		if _canvas_shader == null:
			_canvas_shader = load("res://shaders/ink_canvas.gdshader")
		m.shader = _canvas_shader
	m.set_shader_parameter("style", int(b.style))
	m.render_priority = prio
	_cache[key] = m
	return m


## Material for solid fills (vertex colour, blended).
static func fill_material(prio: int) -> StandardMaterial3D:
	var key := "f|%d" % prio
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.render_priority = prio
	_cache[key] = m
	return m


## Material for 3D (air-drawn) tubes.
static func tube_material(brush_id: String) -> ShaderMaterial:
	var key := "t|" + brush_id
	if _cache.has(key):
		return _cache[key]
	if _tube_shader == null:
		_tube_shader = load("res://shaders/ink_tube.gdshader")
	var b := get_def(brush_id)
	var m := ShaderMaterial.new()
	m.shader = _tube_shader
	m.set_shader_parameter("style", int(b.style))
	m.set_shader_parameter("glow", bool(b.get("add", false)))
	_cache[key] = m
	return m


static func color_for(brush_id: String, c: Color) -> Color:
	var b := get_def(brush_id)
	return Color(c.r, c.g, c.b, c.a * float(b.alpha))
