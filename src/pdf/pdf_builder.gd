class_name PdfBuilder
extends RefCounted
## PdfDisplay -> PdfPageData: consecutive drawings of the same kind become one layer of coloured triangles (a glyph is placed by one transform
## of its triangulated outline, which is made once per font, glyph and size class), images are read into pictures.

const MAX_LAYERS := 120

var doc: PdfDoc
var budget: PdfBudget
var templates: Dictionary = {}             # "font|gid|class" -> {soup, rect}: triangulated glyphs (shared by pages of one document)

var _layers: Array = []
var _verts := PackedVector2Array()
var _cols := PackedColorArray()
var _blend := ""
var _mask := 0
var _masks: Array = []
var _tri_count := 0


func build(disp: PdfDisplay) -> PdfPageData:
	var data := PdfPageData.new()
	data.size = disp.size
	_layers = []
	_verts = PackedVector2Array()
	_cols = PackedColorArray()
	_blend = ""
	_mask = 0
	_masks = disp.masks
	_tri_count = 0
	for op in disp.ops:
		if _tri_count > budget.max_triangles:
			disp.note_unsupported("page too complex: the rest was left out")
			break
		var bm := _blend_of(str(op.get("bm", "")))
		var mk := int(op.get("mask", 0))
		if bm != _blend or mk != _mask:
			_flush()
			_blend = bm
			_mask = mk
		match op.t:
			"fill":
				_add_soup(op.soup, op.color)
			"mesh":
				_verts.append_array(op.soup)
				_cols.append_array(_boost_alphas(op.cols))
				_tri_count += (op.soup as PackedVector2Array).size() / 3
			"glyph":
				_add_glyph(disp, op)
			"tex":
				_flush()
				var tex_layer := {"kind": "image", "verts": op.soup, "uvs": op.uvs, "color": op.color, "alpha": op.alpha, "mask": false, "fill": Color.BLACK,
					"opacity": _boost_alpha(float(op.opacity)), "blend": _blend}
				(op.color as Image).generate_mipmaps()
				(op.alpha as Image).generate_mipmaps()
				if _mask > 0 and _mask <= _masks.size():
					tex_layer["soft"] = _masks[_mask - 1]
				_layers.append(tex_layer)
				_tri_count += (op.soup as PackedVector2Array).size() / 3
			"image":
				_flush()
				_add_image(disp, op)
	_flush()
	data.layers = _layers
	data.stats = disp.stats.duplicate(true)
	data.stats["layers"] = _layers.size()
	data.stats["triangles_built"] = _tri_count
	return data


func _boost_alpha(a: float) -> float:
	return a if a >= 0.999 or a <= 0.0 else pow(a, budget.alpha_power)


func _boost_alphas(cols: PackedColorArray) -> PackedColorArray:
	var out := cols.duplicate()
	for i in out.size():
		var a := out[i].a
		if a < 0.999 and a > 0.0:
			out[i].a = pow(a, budget.alpha_power)
	return out


static func _blend_of(bm: String) -> String:
	match bm:
		"Multiply", "Darken":
			return "Multiply"
		"Screen", "Lighten":
			return "Screen"
	return ""


func _flush() -> void:
	if _verts.is_empty():
		return
	var layer := {"kind": "tris", "verts": _verts, "cols": _cols, "blend": _blend}
	if _mask > 0 and _mask <= _masks.size():
		layer["mask"] = _masks[_mask - 1]
	_layers.append(layer)
	_verts = PackedVector2Array()
	_cols = PackedColorArray()


func _add_soup(soup: PackedVector2Array, color: Color) -> void:
	if soup.is_empty():
		return
	color.a = _boost_alpha(color.a)
	_verts.append_array(soup)
	var c := PackedColorArray()
	c.resize(soup.size())
	c.fill(color)
	_cols.append_array(c)
	_tri_count += soup.size() / 3


func _add_glyph(disp: PdfDisplay, op: Dictionary) -> void:
	var font: PdfFont = op.font
	var m: Transform2D = op.m
	var scale := sqrt(absf(m.determinant()))
	if scale < 1e-12:
		return
	var tol_g := budget.tolerance / scale
	var bucket := int(round(log(tol_g) / log(2.0) * 2.0))
	var key := "%s|%d|%d" % [font.id, op.gid, bucket]
	var tpl: Variant = templates.get(key)
	if tpl == null:
		tpl = _template(font, int(op.gid), tol_g)
		templates[key] = tpl
	var soup: PackedVector2Array = tpl.soup
	if soup.is_empty():
		return
	var placed := m * soup
	var clip_id: int = op.clip
	if clip_id > 0:
		var c: Dictionary = disp.clips[clip_id]
		var rect: Rect2 = c.rect
		var box := PdfGeom.bounds(m * PackedVector2Array(tpl.corners))
		if not (c.pieces as Array).is_empty() or not rect.encloses(box):
			if not rect.intersects(box) and (c.pieces as Array).is_empty():
				return
			placed = disp.clip_soup(placed, clip_id)
	_add_soup(placed, op.color)


func _template(font: PdfFont, gid: int, tol_g: float) -> Dictionary:
	var path := font.program.glyph_path(gid)
	var soup := PackedVector2Array()
	var corners := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	if not path.is_empty():
		var flat := path.flatten(Transform2D.IDENTITY, tol_g)
		var contours: Array = flat[0]
		var boost: float = budget.text_boost * tol_g / maxf(budget.tolerance, 1e-9)       # points -> glyph units (the glyph's scale is tolerance / tol_g)
		if boost > 0.0:
			contours = _grown(contours, boost)
		soup = PdfGeom.fill(contours, false)
		var b := PdfGeom.bounds(soup)
		corners = PackedVector2Array([b.position, Vector2(b.end.x, b.position.y), b.end, Vector2(b.position.x, b.end.y)])
	return {"soup": soup, "corners": corners}


func _add_image(disp: PdfDisplay, op: Dictionary) -> void:
	var st: PdfStream = op.stream
	var im := PdfImage.decode(doc, st, op.cs_res if op.has("cs_res") else {}, budget.max_image_dim, budget.pixel_budget)
	if not im.ok():
		disp.note_unsupported("image: " + im.reason)
		return
	if im.color != null:
		im.color.generate_mipmaps()
	if im.alpha != null:
		im.alpha.generate_mipmaps()
	var m: Transform2D = op.m
	var quad := PackedVector2Array([m * Vector2(0, 0), m * Vector2(1, 0), m * Vector2(1, 1), m * Vector2(0, 0), m * Vector2(1, 1), m * Vector2(0, 1)])
	# texture coordinates travel as colours through the clipper, which interpolates them at the cut corners
	var uvc := PackedColorArray([Color(0, 1, 0, 1), Color(1, 1, 0, 1), Color(1, 0, 0, 1), Color(0, 1, 0, 1), Color(1, 0, 0, 1), Color(0, 0, 0, 1)])
	var clip_id: int = op.clip
	if clip_id > 0:
		var cut := disp.clip_mesh(quad, uvc, clip_id)
		quad = cut[0]
		uvc = cut[1]
	if quad.is_empty():
		return
	var uvs := PackedVector2Array()
	for c in uvc:
		uvs.append(Vector2(c.r, c.g))
	_tri_count += quad.size() / 3
	var layer := {"kind": "image", "verts": quad, "uvs": uvs, "color": im.color, "alpha": im.alpha, "mask": im.is_mask, "fill": op.fill, "opacity": _boost_alpha(float(op.alpha)),
		"blend": _blend_of(str(op.get("bm", "")))}
	var mk := int(op.get("mask", 0))
	if mk > 0 and mk <= _masks.size():
		layer["soft"] = _masks[mk - 1]
	_layers.append(layer)


## Outlines grown by `delta` (the letter gets heavier, its counters smaller). Each contour is offset on its own; one that runs the other way round
## than the biggest contour is a hole and is shrunk instead (a hole that would vanish is kept as it is).
static func _grown(contours: Array, delta: float) -> Array:
	var polys: Array = []
	var main_sign := 1.0
	var biggest := 0.0
	for c in contours:
		var poly := PdfGeom.clean(c)
		if poly.size() < 3:
			continue
		polys.append(poly)
		var a := PdfGeom.area(poly)
		if absf(a) > biggest:
			biggest = absf(a)
			main_sign = signf(a)
	var out: Array = []
	for poly in polys:
		var hole := signf(PdfGeom.area(poly)) != main_sign
		var res := Geometry2D.offset_polygon(poly, -delta if hole else delta, Geometry2D.JOIN_MITER)
		if res.is_empty():
			out.append(poly)
		else:
			for r in res:
				out.append(r)
	return out
