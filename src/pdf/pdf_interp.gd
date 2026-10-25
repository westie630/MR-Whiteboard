class_name PdfInterp
extends RefCounted
## Runs a page's content stream and records what it draws as a PdfDisplay: the graphics state (matrix, colours, line style, clip, text
## state), path construction and painting, text, images, form XObjects, shadings. Nothing here touches the engine's rendering: the result
## is plain data (see PdfBuilder for the step to meshes), so a page can be prepared on a worker thread.

const MAX_DEPTH := 12
const MAX_ARGS := 64

var doc: PdfDoc
var disp: PdfDisplay
var fonts: Dictionary = {}                 # shared with the reader: one PdfFont per font object
var tol := 0.05                            # curves are cut so that the straight pieces stay this close (page units)
var min_line := 0.3                        # the thinnest line drawn (page units): a hairline would vanish in the headset
var max_ops := 600000
var max_triangles := 3000000
var show_annotations := true
var budget: PdfBudget = PdfBudget.new()    # what a soft mask's little drawing is made with (it is a page of its own)
var templates: Dictionary = {}             # triangulated glyphs, shared with the builder that makes the page

var _gs: GS
var _stack: Array = []
var _path := PdfPath.new()
var _clip_mode := 0                        # a W / W* is waiting for the painting operator: 1 non-zero, 2 even-odd
var _res: Dictionary = {}
var _base := Transform2D.IDENTITY          # matrix of the content stream being run (patterns are placed relative to it)
var _depth := 0
var _ops_run := 0
var _hidden := 0                           # inside optional content that is switched off
var _mc: Array = []                        # marked-content stack: whether each level hid something
var _oc_off: Dictionary = {}
var _tm := Transform2D.IDENTITY
var _tlm := Transform2D.IDENTITY
var _t3_uncolored := 0
var _stopped := false
var _text_contours: Array = []             # outlines of the glyphs shown in a clipping text mode since the text object began
var _ga := 1.0                             # the alpha of the transparency groups being drawn (their objects are drawn at it)


class GS:
	extends RefCounted
	var ctm := Transform2D.IDENTITY
	var clip := 0
	var fill_cs: PdfColor = PdfColor.GRAY
	var stroke_cs: PdfColor = PdfColor.GRAY
	var fill_color := Color.BLACK
	var stroke_color := Color.BLACK
	var fill_pattern: Dictionary = {}
	var stroke_pattern: Dictionary = {}
	var fill_alpha := 1.0
	var stroke_alpha := 1.0
	var blend := ""
	var line_width := 1.0
	var cap := 0
	var join := 0
	var miter := 10.0
	var dash := PackedFloat64Array()
	var dash_phase := 0.0
	var font: PdfFont = null
	var font_size := 0.0
	var char_space := 0.0
	var word_space := 0.0
	var hscale := 1.0
	var leading := 0.0
	var rise := 0.0
	var render_mode := 0
	var smask: Dictionary = {}                 # the soft mask in force: {d: its dictionary, ctm: the matrix it was set under}
	var mask_id := 0                           # its baked picture's number (-1: not baked yet; 0: none)
	var clip_mask := 0                         # the picture of a clip that is a shape too fine for the clip table (text as a clip): drawings go through it

	func copy() -> GS:
		var g := GS.new()
		g.ctm = ctm
		g.clip = clip
		g.fill_cs = fill_cs
		g.stroke_cs = stroke_cs
		g.fill_color = fill_color
		g.stroke_color = stroke_color
		g.fill_pattern = fill_pattern
		g.stroke_pattern = stroke_pattern
		g.fill_alpha = fill_alpha
		g.stroke_alpha = stroke_alpha
		g.blend = blend
		g.line_width = line_width
		g.cap = cap
		g.join = join
		g.miter = miter
		g.dash = dash
		g.dash_phase = dash_phase
		g.font = font
		g.font_size = font_size
		g.char_space = char_space
		g.word_space = word_space
		g.hscale = hscale
		g.leading = leading
		g.rise = rise
		g.render_mode = render_mode
		g.smask = smask
		g.mask_id = mask_id
		g.clip_mask = clip_mask
		return g


# ------------------------------------------------------------------------------------------------ the page

## Runs page `page` (a dictionary from PdfDoc.page) and returns what it draws.
func run_page(page: Dictionary) -> PdfDisplay:
	disp = PdfDisplay.new()
	disp.fonts = fonts
	var media := _rect_of(doc.d_nums(page.get("MediaBox")), Rect2(0, 0, 612, 792))
	var box := media
	var crop := doc.d_nums(page.get("CropBox"))
	if crop.size() >= 4:
		var cb := _rect_of(crop, media)
		var inter := media.intersection(cb)
		if inter.size.x > 1.0 and inter.size.y > 1.0:
			box = inter
	var rot := ((doc.d_int(page.get("Rotate"), 0) % 360) + 360) % 360
	var w := box.size.x
	var h := box.size.y
	var base := Transform2D(Vector2(1, 0), Vector2(0, 1), -box.position)
	match rot:
		90:
			base = Transform2D(Vector2(0, -1), Vector2(1, 0), Vector2(0, w)) * base
			disp.size = Vector2(h, w)
		180:
			base = Transform2D(Vector2(-1, 0), Vector2(0, -1), Vector2(w, h)) * base
			disp.size = Vector2(w, h)
		270:
			base = Transform2D(Vector2(0, 1), Vector2(-1, 0), Vector2(h, 0)) * base
			disp.size = Vector2(h, w)
		_:
			disp.size = Vector2(w, h)
	disp.clips[0].rect = Rect2(Vector2.ZERO, disp.size)
	_compute_optional_content()
	_gs = GS.new()
	_gs.ctm = base
	_gs.clip = disp.clip_with_rect(0, Rect2(Vector2.ZERO, disp.size))      # nothing is drawn outside the page
	_base = base
	_res = doc.d_dict(page.get("Resources"))
	var bytes := _contents(page.get("Contents"))
	_run(bytes)
	if show_annotations:
		_annotations(page, base)
	return disp


func _rect_of(a: PackedFloat64Array, fallback: Rect2) -> Rect2:
	if a.size() < 4:
		return fallback
	var x0 := minf(a[0], a[2])
	var y0 := minf(a[1], a[3])
	var x1 := maxf(a[0], a[2])
	var y1 := maxf(a[1], a[3])
	if x1 - x0 < 1.0 or y1 - y0 < 1.0:
		return fallback
	return Rect2(x0, y0, x1 - x0, y1 - y0)


func _contents(c: Variant) -> PackedByteArray:
	c = doc.res(c)
	var out := PackedByteArray()
	if c is PdfStream:
		return (c as PdfStream).decode()
	if c is Array:
		for x in c:
			var s := doc.d_stream(x)
			if s != null:
				out.append_array(s.decode())
				out.append(10)
	return out


func _annotations(page: Dictionary, base: Transform2D) -> void:
	for a in doc.d_array(page.get("Annots")):
		var ad := doc.d_dict(a)
		var sub := doc.d_name(ad.get("Subtype"))
		var flags := doc.d_int(ad.get("F"), 0)
		if sub in ["Link", "Popup", "Movie", "Sound", "Screen"] or (flags & 2) != 0 or (flags & 32) != 0:   # hidden or no-view
			continue
		var ap := doc.d_dict(ad.get("AP"))
		var n: Variant = doc.res(ap.get("N"))
		if n is Dictionary:
			var st := doc.d_name(ad.get("AS"))
			n = doc.res((n as Dictionary).get(st)) if st != "" else null
		if not (n is PdfStream):
			continue
		if ad.has("OC") and _oc_is_hidden(ad.get("OC")):
			continue
		var rect := doc.d_nums(ad.get("Rect"))
		if rect.size() < 4:
			continue
		var form: PdfStream = n
		var bb := doc.d_nums(form.dict.get("BBox"))
		if bb.size() < 4:
			continue
		var fm := _matrix_of(doc.d_nums(form.dict.get("Matrix")))
		# the form's box, as the matrix puts it, is fitted to the annotation's rectangle
		var corners := PackedVector2Array([fm * Vector2(bb[0], bb[1]), fm * Vector2(bb[2], bb[1]), fm * Vector2(bb[2], bb[3]), fm * Vector2(bb[0], bb[3])])
		var tb := PdfGeom.bounds(corners)
		var rx0 := minf(rect[0], rect[2])
		var ry0 := minf(rect[1], rect[3])
		var rw := absf(rect[2] - rect[0])
		var rh := absf(rect[3] - rect[1])
		var sx := rw / tb.size.x if tb.size.x > 1e-6 else 1.0
		var sy := rh / tb.size.y if tb.size.y > 1e-6 else 1.0
		var place := Transform2D(Vector2(sx, 0), Vector2(0, sy), Vector2(rx0 - tb.position.x * sx, ry0 - tb.position.y * sy))
		_gs = GS.new()
		_gs.ctm = base * place
		_base = _gs.ctm
		_stack.clear()
		_depth = 0
		_draw_form(form, true)


# ------------------------------------------------------------------------------------------------ optional content

func _compute_optional_content() -> void:
	_oc_off.clear()
	var root := doc.d_dict(doc.trailer.get("Root"))
	var props := doc.d_dict(root.get("OCProperties"))
	if props.is_empty():
		return
	var d := doc.d_dict(props.get("D"))
	var base_off := doc.d_name(d.get("BaseState"), "ON") == "OFF"
	if base_off:
		for g in doc.d_array(props.get("OCGs")):
			if typeof(g) == TYPE_VECTOR2I:
				_oc_off[(g as Vector2i).x] = true
		for g in doc.d_array(d.get("ON")):
			if typeof(g) == TYPE_VECTOR2I:
				_oc_off.erase((g as Vector2i).x)
	for g in doc.d_array(d.get("OFF")):
		if typeof(g) == TYPE_VECTOR2I:
			_oc_off[(g as Vector2i).x] = true


func _oc_is_hidden(v: Variant) -> bool:
	if _oc_off.is_empty():
		return false
	var d := doc.d_dict(v)
	var type := doc.d_name(d.get("Type"))
	if type == "OCMD":
		var members: Array = []
		var raw: Variant = d.get("OCGs")
		var rv: Variant = doc.res(raw)
		if rv is Array:
			members = rv
		elif raw != null:
			members = [raw]
		if members.is_empty():
			return false
		var on := 0
		for m in members:
			if typeof(m) == TYPE_VECTOR2I and _oc_off.has((m as Vector2i).x):
				continue
			on += 1
		match doc.d_name(d.get("P"), "AnyOn"):
			"AllOn":
				return on != members.size()
			"AnyOff":
				return on == members.size()
			"AllOff":
				return on != 0
		return on == 0
	return typeof(v) == TYPE_VECTOR2I and _oc_off.has((v as Vector2i).x)


# ------------------------------------------------------------------------------------------------ the stream

func _run(bytes: PackedByteArray) -> void:
	var lex := PdfLex.new(bytes)
	var args: Array = []
	while not _stopped:
		var t: Variant = lex.next()
		var ty := typeof(t)
		if ty == TYPE_STRING_NAME:
			if t == PdfLex.END:
				break
			args.append(t)
		elif ty == TYPE_STRING:
			_ops_run += 1
			if _ops_run > max_ops or int(disp.stats.triangles) > max_triangles:
				_stopped = true
				disp.note_unsupported("page too complex: the rest was left out")
				break
			if t == "BI":
				_inline_image(lex)
			else:
				_exec(t, args)
			args.clear()
		else:
			args.append(t)
			if args.size() > MAX_ARGS:
				args.pop_front()


func _n(args: Array, i: int, fallback: float = 0.0) -> float:
	if i < args.size():
		var v: Variant = args[i]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			return float(v)
	return fallback


func _exec(op: String, args: Array) -> void:
	match op:
		"Tj":
			if not args.is_empty() and typeof(args[0]) == TYPE_PACKED_BYTE_ARRAY:
				_show(args[0])
		"TJ":
			if not args.is_empty() and args[0] is Array:
				for item in (args[0] as Array):
					if typeof(item) == TYPE_PACKED_BYTE_ARRAY:
						_show(item)
					elif typeof(item) == TYPE_INT or typeof(item) == TYPE_FLOAT:
						var adj := -float(item) / 1000.0 * _gs.font_size * _gs.hscale
						_tm = _tm * Transform2D(0.0, Vector2(adj, 0.0))
		"Td":
			_tlm = _tlm * Transform2D(0.0, Vector2(_n(args, 0), _n(args, 1)))
			_tm = _tlm
		"Tm":
			_tlm = Transform2D(Vector2(_n(args, 0), _n(args, 1)), Vector2(_n(args, 2), _n(args, 3)), Vector2(_n(args, 4), _n(args, 5)))
			_tm = _tlm
		"re":
			_path.rect(_n(args, 0), _n(args, 1), _n(args, 2), _n(args, 3))
		"m":
			_path.move_to(Vector2(_n(args, 0), _n(args, 1)))
		"l":
			_path.line_to(Vector2(_n(args, 0), _n(args, 1)))
		"c":
			_path.cubic_to(Vector2(_n(args, 0), _n(args, 1)), Vector2(_n(args, 2), _n(args, 3)), Vector2(_n(args, 4), _n(args, 5)))
		"v":
			_path.cubic_to(_path.cur, Vector2(_n(args, 0), _n(args, 1)), Vector2(_n(args, 2), _n(args, 3)))
		"y":
			var end := Vector2(_n(args, 2), _n(args, 3))
			_path.cubic_to(Vector2(_n(args, 0), _n(args, 1)), end, end)
		"h":
			_path.close()
		"f", "F":
			_paint(true, false, false, false)
		"f*":
			_paint(true, false, true, false)
		"S":
			_paint(false, true, false, false)
		"s":
			_paint(false, true, false, true)
		"B":
			_paint(true, true, false, false)
		"B*":
			_paint(true, true, true, false)
		"b":
			_paint(true, true, false, true)
		"b*":
			_paint(true, true, true, true)
		"n":
			_paint(false, false, false, false)
		"W":
			_clip_mode = 1
		"W*":
			_clip_mode = 2
		"q":
			if _stack.size() < 64:
				_stack.append(_gs.copy())
		"Q":
			if not _stack.is_empty():
				_gs = _stack.pop_back()
		"cm":
			_gs.ctm = _gs.ctm * Transform2D(Vector2(_n(args, 0), _n(args, 1)), Vector2(_n(args, 2), _n(args, 3)), Vector2(_n(args, 4), _n(args, 5)))
		"g":
			_set_device(false, PdfColor.GRAY, args)
		"G":
			_set_device(true, PdfColor.GRAY, args)
		"rg":
			_set_device(false, PdfColor.RGB, args)
		"RG":
			_set_device(true, PdfColor.RGB, args)
		"k":
			_set_device(false, PdfColor.CMYK, args)
		"K":
			_set_device(true, PdfColor.CMYK, args)
		"cs":
			_set_space(false, args)
		"CS":
			_set_space(true, args)
		"sc", "scn":
			_set_color(false, args)
		"SC", "SCN":
			_set_color(true, args)
		"BT":
			_tm = Transform2D.IDENTITY
			_tlm = Transform2D.IDENTITY
			_text_contours = []
		"ET":
			_apply_text_clip()
		"Tf":
			if not args.is_empty() and typeof(args[0]) == TYPE_STRING_NAME:
				_set_font(String(args[0]), _n(args, 1))
		"Tc":
			_gs.char_space = _n(args, 0)
		"Tw":
			_gs.word_space = _n(args, 0)
		"Tz":
			_gs.hscale = _n(args, 0, 100.0) / 100.0
		"TL":
			_gs.leading = _n(args, 0)
		"Tr":
			_gs.render_mode = int(_n(args, 0))
		"Ts":
			_gs.rise = _n(args, 0)
		"TD":
			_gs.leading = -_n(args, 1)
			_tlm = _tlm * Transform2D(0.0, Vector2(_n(args, 0), _n(args, 1)))
			_tm = _tlm
		"T*":
			_tlm = _tlm * Transform2D(0.0, Vector2(0.0, -_gs.leading))
			_tm = _tlm
		"'":
			_tlm = _tlm * Transform2D(0.0, Vector2(0.0, -_gs.leading))
			_tm = _tlm
			if not args.is_empty() and typeof(args[0]) == TYPE_PACKED_BYTE_ARRAY:
				_show(args[0])
		"\"":
			_gs.word_space = _n(args, 0)
			_gs.char_space = _n(args, 1)
			_tlm = _tlm * Transform2D(0.0, Vector2(0.0, -_gs.leading))
			_tm = _tlm
			if args.size() >= 3 and typeof(args[2]) == TYPE_PACKED_BYTE_ARRAY:
				_show(args[2])
		"w":
			_gs.line_width = _n(args, 0, 1.0)
		"J":
			_gs.cap = clampi(int(_n(args, 0)), 0, 2)
		"j":
			_gs.join = clampi(int(_n(args, 0)), 0, 2)
		"M":
			_gs.miter = maxf(_n(args, 0, 10.0), 1.0)
		"d":
			if not args.is_empty() and args[0] is Array:
				var dd := PackedFloat64Array()
				for x in (args[0] as Array):
					dd.append(float(x) if typeof(x) == TYPE_INT or typeof(x) == TYPE_FLOAT else 0.0)
				_gs.dash = dd
				_gs.dash_phase = _n(args, 1)
		"gs":
			if not args.is_empty() and typeof(args[0]) == TYPE_STRING_NAME:
				_ext_gstate(String(args[0]))
		"Do":
			if not args.is_empty() and typeof(args[0]) == TYPE_STRING_NAME:
				_do(String(args[0]))
		"sh":
			if not args.is_empty() and typeof(args[0]) == TYPE_STRING_NAME:
				_shade(String(args[0]))
		"BMC":
			_mc.append(false)
		"BDC":
			var hide := false
			if args.size() >= 2 and typeof(args[0]) == TYPE_STRING_NAME and args[0] == &"OC":
				var prop: Variant = args[1]
				if typeof(prop) == TYPE_STRING_NAME:
					prop = doc.d_dict(_res.get("Properties")).get(String(prop))
				hide = _oc_is_hidden(prop)
			_mc.append(hide)
			if hide:
				_hidden += 1
		"EMC":
			if not _mc.is_empty():
				if _mc.pop_back():
					_hidden -= 1
		"d0":
			pass
		"d1":
			_t3_uncolored += 1
		"ri", "i", "MP", "DP", "BX", "EX":
			pass
		_:
			pass


# ------------------------------------------------------------------------------------------------ transparency

func _fa() -> float:
	return _gs.fill_alpha * _ga


func _sa() -> float:
	return _gs.stroke_alpha * _ga


## The number of the soft mask in force (baked the first time something is drawn under it), 0 for none.
func _mask() -> int:
	if _gs.clip_mask > 0:
		return _gs.clip_mask
	if _gs.smask.is_empty():
		return 0
	if _gs.mask_id < 0:
		_gs.mask_id = _bake_mask(_gs.smask)
	return _gs.mask_id


## The soft mask's group, drawn once into a small grey picture (PdfRaster): luminosity of the group over its backdrop, or its coverage.
func _bake_mask(sm: Dictionary) -> int:
	var d: Dictionary = sm.d
	var group := doc.d_stream(d.get("G"))
	if group == null or _depth >= 3:
		return 0
	var bb := doc.d_nums(group.dict.get("BBox"))
	if bb.size() < 4:
		return 0
	var luminosity := doc.d_name(d.get("S"), "Luminosity") != "Alpha"
	var m: Transform2D = (sm.ctm as Transform2D) * _matrix_of(doc.d_nums(group.dict.get("Matrix")))
	var corners := PackedVector2Array([m * Vector2(bb[0], bb[1]), m * Vector2(bb[2], bb[1]), m * Vector2(bb[2], bb[3]), m * Vector2(bb[0], bb[3])])
	var area := PdfGeom.bounds(corners).intersection(Rect2(Vector2.ZERO, disp.size))
	var backdrop := 0.0
	var bc := doc.d_nums(d.get("BC"))
	if luminosity and not bc.is_empty():
		var space := PdfColor.GRAY if bc.size() == 1 else (PdfColor.RGB if bc.size() == 3 else PdfColor.CMYK)
		var col := space.to_rgb(Array(bc))
		backdrop = 0.3 * col.r + 0.59 * col.g + 0.11 * col.b
	var tr := _transfer_of(d.get("TR"))
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		var flat := _through_transfer(Image.create_from_data(1, 1, false, Image.FORMAT_L8, PackedByteArray([int(backdrop * 255.0)])), backdrop, tr)
		return disp.add_mask(flat[0], Rect2(0, 0, 1, 1), flat[1])
	var longest := 512 if budget.tier != "low" else 256
	var k := float(longest) / maxf(area.size.x, area.size.y)
	var w := clampi(ceili(area.size.x * k), 2, longest)
	var h := clampi(ceili(area.size.y * k), 2, longest)
	var sub := PdfInterp.new()
	sub.doc = doc
	sub.fonts = fonts
	sub.tol = tol
	sub.min_line = min_line
	sub.budget = budget
	sub.templates = templates
	sub.show_annotations = false
	sub.disp = PdfDisplay.new()
	sub.disp.size = disp.size
	sub.disp.clips[0].rect = Rect2(Vector2.ZERO, disp.size)
	sub._gs = GS.new()
	sub._gs.ctm = sm.ctm
	sub._base = sm.ctm
	sub._res = _res
	sub._depth = _depth + 1
	sub._oc_off = _oc_off
	sub._draw_form(group, false)
	var builder := PdfBuilder.new()
	builder.doc = doc
	builder.budget = budget
	builder.templates = templates
	var page := builder.build(sub.disp)
	var ras := PdfRaster.new(w, h, area, backdrop)
	for layer in page.layers:
		if layer.kind == "tris":
			ras.tris(layer.verts, layer.cols)
		else:
			ras.image_tris(layer.verts, layer.uvs, layer.color, layer.alpha, float(layer.opacity), (layer.fill as Color) if bool(layer.mask) else Color.WHITE)
	var baked := _through_transfer(ras.to_image(not luminosity), backdrop if luminosity else 0.0, tr)
	return disp.add_mask(baked[0], area, baked[1])


## A soft mask's transfer function (/TR), or null for none (or /Identity).
func _transfer_of(v: Variant) -> PdfFunction:
	if v == null or typeof(doc.res(v)) == TYPE_STRING_NAME:
		return null
	var fn := PdfFunction.make(doc, v)
	return fn if fn != null and fn.n_in == 1 else null


## The mask picture and its value beyond the picture, both put through the transfer function.
func _through_transfer(img: Image, outside: float, tr: PdfFunction) -> Array:
	if tr == null:
		return [img, outside]
	var lut := PackedByteArray()
	lut.resize(256)
	for v in 256:
		lut[v] = clampi(int(float(tr.evaluate([v / 255.0])[0]) * 255.0 + 0.5), 0, 255)
	var bytes := img.get_data()
	for i in bytes.size():
		bytes[i] = lut[bytes[i]]
	return [Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_L8, bytes), clampf(float(tr.evaluate([outside])[0]), 0.0, 1.0)]


# ------------------------------------------------------------------------------------------------ colour

func _set_device(stroking: bool, space: PdfColor, args: Array) -> void:
	if _t3_uncolored > 0:
		return
	var comps: Array = []
	for i in space.n:
		comps.append(_n(args, i))
	var c := space.to_rgb(comps)
	if stroking:
		_gs.stroke_cs = space
		_gs.stroke_color = c
		_gs.stroke_pattern = {}
	else:
		_gs.fill_cs = space
		_gs.fill_color = c
		_gs.fill_pattern = {}


func _set_space(stroking: bool, args: Array) -> void:
	if _t3_uncolored > 0 or args.is_empty():
		return
	var space := PdfColor.make(doc, args[0], doc.d_dict(_res.get("ColorSpace")))
	var c := space.to_rgb(space.initial()) if space.kind != "Pattern" else Color.BLACK
	if stroking:
		_gs.stroke_cs = space
		_gs.stroke_color = c
		_gs.stroke_pattern = {}
	else:
		_gs.fill_cs = space
		_gs.fill_color = c
		_gs.fill_pattern = {}


func _set_color(stroking: bool, args: Array) -> void:
	if _t3_uncolored > 0:
		return
	var space: PdfColor = _gs.stroke_cs if stroking else _gs.fill_cs
	var pattern := {}
	var comps: Array = []
	for a in args:
		if typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT:
			comps.append(float(a))
	var color := Color.BLACK
	if space.kind == "Pattern":
		if not args.is_empty() and typeof(args[args.size() - 1]) == TYPE_STRING_NAME:
			pattern = _pattern(String(args[args.size() - 1]))
		if space.base != null and not comps.is_empty():
			color = space.base.to_rgb(comps)
			pattern["color"] = color
	else:
		if space.kind == "Separation" and space.none_ink:
			color = Color(0, 0, 0, 0)
		else:
			while comps.size() < space.n:
				comps.append(0.0)
			color = space.to_rgb(comps)
	if stroking:
		_gs.stroke_color = color
		_gs.stroke_pattern = pattern
	else:
		_gs.fill_color = color
		_gs.fill_pattern = pattern


func _pattern(name: String) -> Dictionary:
	var pv: Variant = doc.res(doc.d_dict(_res.get("Pattern")).get(name))
	var d := doc.d_dict(pv)
	if d.is_empty():
		return {}
	var m := _matrix_of(doc.d_nums(d.get("Matrix")))
	return {"type": doc.d_int(d.get("PatternType"), 0), "dict": d, "stream": pv if pv is PdfStream else null, "matrix": _base * m}


static func _matrix_of(a: PackedFloat64Array) -> Transform2D:
	if a.size() < 6:
		return Transform2D.IDENTITY
	return Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))


func _ext_gstate(name: String) -> void:
	var d := doc.d_dict(doc.d_dict(_res.get("ExtGState")).get(name))
	for k in d:
		var v: Variant = doc.res(d[k])
		match k:
			"LW":
				_gs.line_width = doc.d_num(v, 1.0)
			"LC":
				_gs.cap = clampi(doc.d_int(v, 0), 0, 2)
			"LJ":
				_gs.join = clampi(doc.d_int(v, 0), 0, 2)
			"ML":
				_gs.miter = maxf(doc.d_num(v, 10.0), 1.0)
			"D":
				if v is Array and (v as Array).size() >= 2:
					_gs.dash = doc.d_nums((v as Array)[0])
					_gs.dash_phase = doc.d_num((v as Array)[1])
			"CA":
				_gs.stroke_alpha = clampf(doc.d_num(v, 1.0), 0.0, 1.0)
			"ca":
				_gs.fill_alpha = clampf(doc.d_num(v, 1.0), 0.0, 1.0)
			"BM":
				var bm := ""
				if typeof(v) == TYPE_STRING_NAME:
					bm = String(v)
				elif v is Array and not (v as Array).is_empty():
					bm = doc.d_name((v as Array)[0])
				_gs.blend = "" if bm in ["Normal", "Compatible"] else bm
			"Font":
				if v is Array and (v as Array).size() >= 2:
					_gs.font = PdfFont.load_font(doc, (v as Array)[0], fonts)
					_gs.font_size = doc.d_num((v as Array)[1])
			"SMask":
				if typeof(v) == TYPE_STRING_NAME:
					_gs.smask = {}
					_gs.mask_id = 0
				elif v is Dictionary:
					_gs.smask = {"d": v, "ctm": _gs.ctm}
					_gs.mask_id = -1


# ------------------------------------------------------------------------------------------------ painting

func _paint(fill: bool, stroke: bool, even_odd: bool, close: bool) -> void:
	if close:
		_path.close()
	var path := _path
	_path = PdfPath.new()
	if not path.is_empty():
		if _hidden == 0:
			if fill:
				_fill_path(path, even_odd)
			if stroke:
				_stroke_path(path)
		if _clip_mode != 0:
			_apply_clip(path, _clip_mode == 2)
	_clip_mode = 0


func _fill_path(path: PdfPath, even_odd: bool) -> void:
	var flat := path.flatten(_gs.ctm, tol)
	var soup := PdfGeom.fill(flat[0], even_odd)
	if soup.is_empty():
		return
	_fill_soup(soup, _gs.fill_color, _gs.fill_pattern, _fa())


## Paints a region with the fill colour, or with its pattern when it has one.
func _fill_soup(soup: PackedVector2Array, color: Color, pattern: Dictionary, alpha: float) -> void:
	if not pattern.is_empty():
		var t := int(pattern.get("type", 0))
		if t == 2:
			var pm: Transform2D = pattern.matrix
			var sh := doc.d_dict(pattern.dict.get("Shading"))
			var mesh := PdfShading.mesh(doc, sh, soup, pm, doc.d_stream(pattern.dict.get("Shading")), _mesh_texels())
			if mesh.size() == 5:
				disp.add_texture(mesh[1], mesh[2], mesh[3], mesh[4], alpha, _gs.clip, _gs.blend, _mask())
				return
			if mesh.is_empty():
				disp.note_unsupported("shading")                     # (not the fill colour: that is only for a pattern that is not there)
				return
			var cols: PackedColorArray = mesh[1]
			if alpha < 1.0:
				for i in cols.size():
					cols[i].a *= alpha
			disp.add_mesh(mesh[0], cols, _gs.clip, _gs.blend, _mask())
			return
		elif t == 1:
			_tile_fill(soup, pattern, color, alpha)
			return
	var c := color
	c.a *= alpha
	disp.add_fill(soup, c, _gs.clip, _gs.blend, _mask())


## A tiling pattern: its cell is drawn on a grid across the region. A region needing too many cells gets the cell's average look instead.
func _tile_fill(soup: PackedVector2Array, pattern: Dictionary, color: Color, alpha: float) -> void:
	var st: PdfStream = pattern.get("stream")
	if st == null or _depth >= MAX_DEPTH:
		return
	var d: Dictionary = pattern.dict
	var bb := doc.d_nums(d.get("BBox"))
	var xs := doc.d_num(d.get("XStep"), 0.0)
	var ys := doc.d_num(d.get("YStep"), 0.0)
	if bb.size() < 4 or absf(xs) < 1e-6 or absf(ys) < 1e-6:
		return
	var pm: Transform2D = pattern.matrix
	var region := PdfGeom.bounds(soup)
	var inv := pm.affine_inverse()
	var local := PackedVector2Array([inv * region.position, inv * Vector2(region.end.x, region.position.y), inv * region.end, inv * Vector2(region.position.x, region.end.y)])
	var lb := PdfGeom.bounds(local)
	var i0 := floori((lb.position.x - maxf(bb[0], bb[2])) / absf(xs))
	var i1 := ceili((lb.end.x - minf(bb[0], bb[2])) / absf(xs))
	var j0 := floori((lb.position.y - maxf(bb[1], bb[3])) / absf(ys))
	var j1 := ceili((lb.end.y - minf(bb[1], bb[3])) / absf(ys))
	var count := (i1 - i0 + 1) * (j1 - j0 + 1)
	if count > 1500 or count <= 0:
		var c := color if int(d.get("PaintType", 1)) == 2 else Color(0.5, 0.5, 0.5, 1.0)
		c.a *= alpha * 0.6
		disp.add_fill(soup, c, _gs.clip, _gs.blend)
		return
	# the region becomes the clip, and the cell is run once per grid position
	var saved_gs := _gs
	var saved_stack := _stack
	var saved_res := _res
	var saved_base := _base
	var saved_path := _path
	var saved_clip_mode := _clip_mode
	var clip_id := disp.clip_with_region(_gs.clip, soup, PackedVector2Array())
	var uncolored := int(d.get("PaintType", 1)) == 2
	var saved_ga := _ga
	_ga = alpha                                                 # the cell is drawn at the alpha of what is being filled (which already has the group's)
	_depth += 1
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			# the cell's content starts from the initial graphics state (line width 1, no dash, black, opaque), not from what the page had set when it
			# painted: only where it is drawn (the clip, the mask, the blend mode) carries over
			_gs = GS.new()
			_gs.blend = saved_gs.blend
			_gs.smask = saved_gs.smask
			_gs.mask_id = saved_gs.mask_id
			_gs.clip_mask = saved_gs.clip_mask
			_gs.clip = clip_id
			_gs.ctm = pm * Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(i * xs, j * ys))
			_gs.fill_pattern = {}
			_gs.stroke_pattern = {}
			if uncolored:
				_gs.fill_color = color
				_gs.stroke_color = color
				_t3_uncolored += 1
			_stack = []
			_base = _gs.ctm
			var cell_res := doc.d_dict(d.get("Resources"))
			_res = cell_res if not cell_res.is_empty() else saved_res
			_path = PdfPath.new()
			_clip_mode = 0
			# a clip to the cell's box
			var bx := Rect2(minf(bb[0], bb[2]), minf(bb[1], bb[3]), absf(bb[2] - bb[0]), absf(bb[3] - bb[1]))
			_gs.clip = disp.clip_with_region(_gs.clip, _rect_soup(_gs.ctm, bx), PdfGeom.clean(_rect_corners(_gs.ctm, bx)))
			_run(st.decode())
			if uncolored:
				_t3_uncolored -= 1
	_depth -= 1
	_ga = saved_ga
	_gs = saved_gs
	_stack = saved_stack
	_res = saved_res
	_base = saved_base
	_path = saved_path
	_clip_mode = saved_clip_mode


func _rect_corners(m: Transform2D, r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([m * r.position, m * Vector2(r.end.x, r.position.y), m * r.end, m * Vector2(r.position.x, r.end.y)])


func _rect_soup(m: Transform2D, r: Rect2) -> PackedVector2Array:
	var c := _rect_corners(m, r)
	return PackedVector2Array([c[0], c[1], c[2], c[0], c[2], c[3]])


func _stroke_path(path: PdfPath) -> void:
	var m := _gs.ctm
	var scale := sqrt(absf(m.determinant()))
	if scale < 1e-9:
		return
	var width := maxf(_gs.line_width, min_line / scale)
	var flat := path.flatten(Transform2D.IDENTITY, tol / scale)
	var contours: Array = flat[0]
	if contours.is_empty():
		return
	var soup: PackedVector2Array
	var color := _gs.stroke_color
	var pattern := _gs.stroke_pattern
	if _sa() < 0.99 or (not pattern.is_empty() and int(pattern.get("type", 0)) == 2):
		var outlines := PdfStroker.outline(contours, flat[1], width, _gs.cap, _gs.join, _gs.miter, _gs.dash, _gs.dash_phase)
		for i in outlines.size():
			outlines[i] = m * (outlines[i] as PackedVector2Array)
		soup = PdfGeom.fill(outlines, false)
	else:
		soup = m * PdfStroker.stroke(contours, flat[1], width, _gs.cap, _gs.join, _gs.miter, _gs.dash, _gs.dash_phase, tol / scale)
	if soup.is_empty():
		return
	_fill_soup(soup, color, pattern, _sa())


func _apply_clip(path: PdfPath, even_odd: bool) -> void:
	var flat := path.flatten(_gs.ctm, tol)
	var contours: Array = flat[0]
	if contours.is_empty():
		_gs.clip = disp.clip_with_rect(_gs.clip, Rect2())
		return
	if contours.size() == 1:
		var poly := PdfGeom.clean(contours[0])
		if poly.size() == 4 or (poly.size() == 5 and poly[0].is_equal_approx(poly[4])):
			var r := _axis_rect(poly)
			if r.size != Vector2.ZERO or r.position != Vector2.ZERO:
				_gs.clip = disp.clip_with_rect(_gs.clip, r)
				return
	var soup := PdfGeom.fill(contours, even_odd)
	var outline := PackedVector2Array()
	if contours.size() == 1:
		outline = PdfGeom.clean(contours[0])
	if soup.is_empty():
		_gs.clip = disp.clip_with_rect(_gs.clip, Rect2())
		return
	_gs.clip = disp.clip_with_region(_gs.clip, soup, outline)


## The rectangle a 4-point polygon is, when it is axis-aligned.
static func _axis_rect(p: PackedVector2Array) -> Rect2:
	var a := p[0]
	var b := p[1]
	var c := p[2]
	var d := p[3]
	var h := is_equal_approx(a.y, b.y) and is_equal_approx(b.x, c.x) and is_equal_approx(c.y, d.y) and is_equal_approx(d.x, a.x)
	var v := is_equal_approx(a.x, b.x) and is_equal_approx(b.y, c.y) and is_equal_approx(c.x, d.x) and is_equal_approx(d.y, a.y)
	if not (h or v):
		return Rect2()
	var lo := a.min(c)
	return Rect2(lo, a.max(c) - lo)


# ------------------------------------------------------------------------------------------------ text

func _set_font(name: String, size: float) -> void:
	var fd := doc.d_dict(_res.get("Font"))
	if not fd.has(name):
		_gs.font = null
		return
	_gs.font = PdfFont.load_font(doc, fd[name], fonts)
	_gs.font_size = size


func _show(s: PackedByteArray) -> void:
	var f := _gs.font
	if f == null:
		return
	var fs := _gs.font_size
	var th := _gs.hscale
	var glyphs := f.decode(s)
	var mode := _gs.render_mode
	var visible := _hidden == 0 and mode != 3 and mode != 7
	var clipping := _hidden == 0 and mode >= 4                  # the glyphs are also added to the clip (at the end of the text object)
	var color := _gs.fill_color
	color.a *= _fa()
	var ts := Transform2D(Vector2(fs * th, 0.0), Vector2(0.0, fs), Vector2(0.0, _gs.rise))
	for g in glyphs:
		var w: float = g.w
		var adv := (w * fs + _gs.char_space + (_gs.word_space if g.space else 0.0)) * th
		if visible or clipping:
			var trm := _gs.ctm * _tm * ts
			if f.kind == "type3":
				if visible:
					_type3_glyph(f, int(g.code), trm)
			elif int(g.gid) >= 0:
				var gm := trm * f.program.matrix
				var xsc := f.xscale(int(g.gid), w)
				if xsc != 1.0:
					gm = gm * Transform2D(Vector2(xsc, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
				if f.vertical:
					var vm := f.vertical_metrics(w)
					gm = trm * Transform2D(Vector2.RIGHT, Vector2.DOWN * -1.0, vm.origin) * f.program.matrix
					adv = 0.0
					_tm = _tm * Transform2D(0.0, Vector2(0.0, (float(vm.advance) * fs + _gs.char_space + (_gs.word_space if g.space else 0.0))))
				if clipping:
					_collect_text_clip(f, int(g.gid), gm)
				if mode == 0 or mode == 2 or mode == 4 or mode == 6:
					if _gs.fill_pattern.is_empty() or int(_gs.fill_pattern.get("type", 0)) != 2:
						disp.add_glyph(f, int(g.gid), gm, color, _gs.clip, _gs.blend, _mask())
					else:
						_glyph_with_pattern(f, int(g.gid), gm)
				if mode == 1 or mode == 2 or mode == 5 or mode == 6:
					_stroke_glyph(f, int(g.gid), gm)
		if not f.vertical:
			_tm = _tm * Transform2D(0.0, Vector2(adv, 0.0))
		elif not (visible or clipping):
			var vm2 := f.vertical_metrics(w)
			_tm = _tm * Transform2D(0.0, Vector2(0.0, float(vm2.advance) * fs))


## The outline of a glyph shown in a clipping text mode: kept until the end of the text object, when they all become the clip.
func _collect_text_clip(f: PdfFont, gid: int, gm: Transform2D) -> void:
	var path := f.program.glyph_path(gid)
	if path.is_empty():
		return
	var flat := path.flatten(gm, tol)
	_text_contours.append_array(flat[0])


## The clip that the text of a text object made (modes 4 to 7). It is a shape of any size and fineness, which the clip table (a rectangle or a few convex
## pieces) cannot hold, so it becomes a picture of what it covers that what is drawn afterwards goes through, like a soft mask.
func _apply_text_clip() -> void:
	if _text_contours.is_empty():
		return
	var contours := _text_contours
	_text_contours = []
	var soup := PdfGeom.fill(contours, false)
	var area := disp.clip_rect_of(_gs.clip).intersection(Rect2(Vector2.ZERO, disp.size))
	if not soup.is_empty():
		area = area.intersection(PdfGeom.bounds(soup))
	if soup.is_empty() or area.size.x <= 1e-6 or area.size.y <= 1e-6:
		_gs.clip = disp.clip_with_rect(_gs.clip, Rect2())
		return
	_gs.clip = disp.clip_with_rect(_gs.clip, area)
	var texels := 600000 if budget.tier != "low" else 250000
	var longest := 2048 if budget.tier != "low" else 1024
	var k := minf(minf(3.0, sqrt(float(texels) / (area.size.x * area.size.y))), float(longest) / maxf(area.size.x, area.size.y))
	var w := clampi(ceili(area.size.x * k), 2, longest)
	var h := clampi(ceili(area.size.y * k), 2, longest)
	_gs.clip_mask = disp.add_mask(PdfRaster.coverage(soup, w, h, area), area, 0.0)


func _glyph_with_pattern(f: PdfFont, gid: int, gm: Transform2D) -> void:
	var path := f.program.glyph_path(gid)
	if path.is_empty():
		return
	var flat := path.flatten(gm, tol)
	var soup := PdfGeom.fill(flat[0], false)
	if not soup.is_empty():
		_fill_soup(soup, _gs.fill_color, _gs.fill_pattern, _fa())


func _stroke_glyph(f: PdfFont, gid: int, gm: Transform2D) -> void:
	var path := f.program.glyph_path(gid)
	if path.is_empty():
		return
	var scale := sqrt(absf(_gs.ctm.determinant()))
	if scale < 1e-9:
		return
	var user := path.transformed(_gs.ctm.affine_inverse() * gm)
	_stroke_path(user)


func _type3_glyph(f: PdfFont, code: int, trm: Transform2D) -> void:
	var proc := f.type3_proc(code)
	if proc == null or _depth >= MAX_DEPTH:
		return
	var saved := _gs
	var saved_stack := _stack
	var saved_res := _res
	var saved_path := _path
	var saved_tm := _tm
	var saved_tlm := _tlm
	var saved_clip_mode := _clip_mode
	var saved_base := _base
	_gs = saved.copy()
	_gs.ctm = trm * f.t3_matrix
	_gs.line_width = 1.0
	_stack = []
	_path = PdfPath.new()
	_clip_mode = 0
	if not f.t3_resources.is_empty():
		_res = f.t3_resources
	_depth += 1
	var was_uncolored := _t3_uncolored
	_run(proc.decode())
	_t3_uncolored = was_uncolored
	_depth -= 1
	_gs = saved
	_stack = saved_stack
	_res = saved_res
	_path = saved_path
	_tm = saved_tm
	_tlm = saved_tlm
	_clip_mode = saved_clip_mode
	_base = saved_base


# ------------------------------------------------------------------------------------------------ xobjects, images, shadings

func _do(name: String) -> void:
	var xo: Variant = doc.res(doc.d_dict(_res.get("XObject")).get(name))
	if not (xo is PdfStream):
		return
	var st: PdfStream = xo
	if st.dict.has("OC") and _oc_is_hidden(st.dict.get("OC")):
		return
	if _hidden > 0:
		return
	match doc.d_name(st.dict.get("Subtype")):
		"Image":
			_draw_image(st)
		"Form":
			_draw_form(st, false)


func _draw_image(st: PdfStream) -> void:
	var is_mask := doc.d_bool(st.dict.get("ImageMask"), false) or doc.d_bool(st.dict.get("IM"), false)
	var c := _gs.fill_color
	c.a *= _fa()
	if is_mask and not _gs.fill_pattern.is_empty():
		c = Color(0.5, 0.5, 0.5, c.a)
	disp.add_image(st, _gs.ctm, _fa(), _gs.clip, c, doc.d_dict(_res.get("ColorSpace")), _gs.blend, _mask())


func _draw_form(st: PdfStream, is_annotation: bool) -> void:
	if _depth >= MAX_DEPTH:
		return
	var saved := _gs
	var saved_stack := _stack
	var saved_res := _res
	var saved_path := _path
	var saved_clip_mode := _clip_mode
	var saved_base := _base
	var saved_tm := _tm
	var saved_tlm := _tlm
	var saved_mc := _mc
	var saved_hidden := _hidden
	_gs = saved.copy()
	_stack = []
	_mc = []
	_path = PdfPath.new()
	_clip_mode = 0
	var fm := _matrix_of(doc.d_nums(st.dict.get("Matrix")))
	_gs.ctm = _gs.ctm * fm
	_base = _gs.ctm
	var bb := doc.d_nums(st.dict.get("BBox"))
	if bb.size() >= 4:
		var r := Rect2(minf(bb[0], bb[2]), minf(bb[1], bb[3]), absf(bb[2] - bb[0]), absf(bb[3] - bb[1]))
		var corners := _rect_corners(_gs.ctm, r)
		var ar := _axis_rect(corners)
		if ar.size != Vector2.ZERO:
			_gs.clip = disp.clip_with_rect(_gs.clip, ar)
		else:
			_gs.clip = disp.clip_with_region(_gs.clip, PackedVector2Array([corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]]), corners)
	var fres := doc.d_dict(st.dict.get("Resources"))
	if not fres.is_empty():
		_res = fres
	var saved_ga := _ga
	if doc.d_name(doc.d_dict(st.dict.get("Group")).get("S")) == "Transparency" and not is_annotation:
		# a group is composited as a whole with the alpha it is drawn at; inside, alpha starts again at 1. Here the alpha is carried to the
		# objects inside (the same unless they overlap one another)
		_ga *= saved.fill_alpha
		_gs.fill_alpha = 1.0
		_gs.stroke_alpha = 1.0
	_depth += 1
	_run(st.decode())
	_depth -= 1
	_ga = saved_ga
	_gs = saved
	_stack = saved_stack
	_res = saved_res
	_path = saved_path
	_clip_mode = saved_clip_mode
	_base = saved_base
	_tm = saved_tm
	_tlm = saved_tlm
	_mc = saved_mc
	_hidden = saved_hidden


## About how many texels the picture of a mesh shading may have (a Quest 2 less).
func _mesh_texels() -> int:
	return 160000 if budget.tier != "low" else 70000


func _shade(name: String) -> void:
	if _hidden > 0:
		return
	var sh := doc.d_dict(doc.d_dict(_res.get("Shading")).get(name))
	if sh.is_empty():
		return
	# the shading fills the whole clip: its region is the clip's rectangle (cut to its pieces by the mesh clipper)
	var r := disp.clip_rect_of(_gs.clip).intersection(Rect2(Vector2.ZERO, disp.size))
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var soup := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, r.position, r.end, Vector2(r.position.x, r.end.y)])
	var mesh := PdfShading.mesh(doc, sh, soup, _gs.ctm, doc.d_stream(doc.d_dict(_res.get("Shading")).get(name)), _mesh_texels())
	if mesh.size() == 5:
		disp.add_texture(mesh[1], mesh[2], mesh[3], mesh[4], _fa(), _gs.clip, _gs.blend, _mask())
		return
	if mesh.is_empty():
		disp.note_unsupported("shading")
		return
	var cols: PackedColorArray = mesh[1]
	if _fa() < 1.0:
		for i in cols.size():
			cols[i].a *= _fa()
	disp.add_mesh(mesh[0], cols, _gs.clip, _gs.blend, _mask())


func _inline_image(lex: PdfLex) -> void:
	var d := {}
	while true:
		var k: Variant = lex.next()
		if typeof(k) == TYPE_STRING and k == "ID":
			break
		if typeof(k) == TYPE_STRING_NAME and k == PdfLex.END:
			return
		if typeof(k) != TYPE_STRING_NAME:
			continue
		var v: Variant = lex.object()
		d[_inline_key(String(k))] = v
	# one white space, then the data up to "EI"
	if lex.p < lex.end and (lex.b[lex.p] == 32 or lex.b[lex.p] == 10 or lex.b[lex.p] == 13 or lex.b[lex.p] == 9):
		if lex.b[lex.p] == 13 and lex.p + 1 < lex.end and lex.b[lex.p + 1] == 10:
			lex.p += 1
		lex.p += 1
	var start := lex.p
	var w := int(d.get("Width", 0))
	var h := int(d.get("Height", 0))
	var filt: Variant = d.get("Filter")
	var data_end := -1
	if filt == null and w > 0 and h > 0:
		var cs := PdfColor.make(doc, d.get("ColorSpace", &"DeviceGray"), doc.d_dict(_res.get("ColorSpace")))
		var bpc := int(d.get("BitsPerComponent", 8))
		if d.get("ImageMask", false) == true:
			bpc = 1
			cs = PdfColor.GRAY
		var row := (w * cs.n * bpc + 7) / 8
		data_end = start + row * h
	var ei := _find_ei(lex, maxi(data_end, start) if data_end >= 0 else start)
	if ei < 0:
		lex.p = lex.end
		return
	var data := lex.b.slice(start, ei)
	lex.p = ei + 2
	if _hidden > 0:
		return
	var st := PdfStream.new()
	st.dict = d
	st.raw = data
	st.off = 0
	st.length = data.size()
	if d.has("Filter"):
		d["Filter"] = _inline_filters(d["Filter"])
	if d.has("DecodeParms"):
		pass
	_draw_image(st)


func _find_ei(lex: PdfLex, from: int) -> int:
	var i := from
	while true:
		i = lex.find_word("EI", i)
		if i < 0:
			return -1
		var before_ok := i == 0 or (PdfLex._cls[lex.b[i - 1]] & PdfLex.WS) != 0
		var after_ok := i + 2 >= lex.end or (PdfLex._cls[lex.b[i + 2]] & (PdfLex.WS | PdfLex.DELIM)) != 0
		if before_ok and after_ok:
			return i
		i += 2
	return -1


static func _inline_key(k: String) -> String:
	match k:
		"BPC":
			return "BitsPerComponent"
		"CS":
			return "ColorSpace"
		"D":
			return "Decode"
		"DP":
			return "DecodeParms"
		"F":
			return "Filter"
		"H":
			return "Height"
		"IM":
			return "ImageMask"
		"I":
			return "Interpolate"
		"W":
			return "Width"
	return k


static func _inline_filters(v: Variant) -> Variant:
	var map := {"AHx": &"ASCIIHexDecode", "A85": &"ASCII85Decode", "LZW": &"LZWDecode", "Fl": &"FlateDecode", "RL": &"RunLengthDecode", "CCF": &"CCITTFaxDecode", "DCT": &"DCTDecode"}
	if typeof(v) == TYPE_STRING_NAME:
		return map.get(String(v), v)
	if v is Array:
		var out: Array = []
		for x in v:
			out.append(map.get(String(x), x) if typeof(x) == TYPE_STRING_NAME else x)
		return out
	return v
