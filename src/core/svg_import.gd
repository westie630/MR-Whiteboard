class_name SvgImport
extends RefCounted
## Reads an SVG file into canvas items, so a drawing made on a PC can be edited in the headset: shapes stay shapes (rectangles,
## ellipses, lines, polygons), open paths become pen strokes, text stays text, colours, fills, stroke widths, opacity and
## transforms are kept. Curves and arcs are cut into short straight pieces fine enough to look round.
##
## Not carried over (counted in `skipped`, so the page can say so): embedded images, patterns, clip paths and masks, filters, arrow
## markers. Gradients become their first colour; holes in a filled path are filled; dashes become solid.
##
## parse() only reads: it returns the items (their `frame` empty) and the size the canvas should have; the Board adds them.

const MAX_ITEMS := 4000
const MAX_DEPTH := 24
const PX_M := 0.0254 / 96.0               # one CSS pixel in metres
const MIN_EXTENT := 0.9                   # the longer side of the result is brought between these (metres) ...
const TINY_EXTENT := 0.6                  # ... but only drawings smaller than this are enlarged (an A4 page or an icon is too small to edit in a room)
const MAX_EXTENT := 2.4
const PRESSURE := 0.85                    # imported strokes are drawn at this pressure: the pen then gives exactly the SVG's width
const MIN_WIDTH := 0.0008
const MAX_WIDTH := 0.04
const MIN_POINT_GAP := 0.0004             # strokes drop points closer than this to the previous one (metres)
const NONE := Color(0, 0, 0, -1)          # "no paint"
const SKIP_TAGS := ["defs", "symbol", "clipPath", "mask", "marker", "pattern", "linearGradient", "radialGradient", "style", "title", "desc",
	"metadata", "filter", "script", "namedview", "stop", "font", "glyph", "view", "animate", "set"]
const INHERITED := ["fill", "stroke", "stroke-width", "fill-opacity", "stroke-opacity", "font-size", "text-anchor", "color", "visibility", "font-weight", "font-style"]
const CSS_NAMES := {"green": "#008000", "gray": "#808080", "grey": "#808080", "maroon": "#800000", "purple": "#800080", "lime": "#00ff00"}


class El:
	extends RefCounted
	var tag := ""
	var attrs := {}
	var kids: Array = []
	var text := ""


## Reads numbers (and arc flags) out of path data, point lists and transform arguments.
class Scan:
	extends RefCounted
	var s := ""
	var i := 0

	func _init(text: String) -> void:
		s = text

	func skip_sep() -> void:
		while i < s.length() and (s[i] == " " or s[i] == "," or s[i] == "\t" or s[i] == "\n" or s[i] == "\r"):
			i += 1

	func done() -> bool:
		skip_sep()
		return i >= s.length()

	func peek() -> String:
		skip_sep()
		return s[i] if i < s.length() else ""

	func next_is_number() -> bool:
		var c := peek()
		return c != "" and "+-.0123456789".contains(c)

	func number() -> float:
		skip_sep()
		var st := i
		if i < s.length() and (s[i] == "+" or s[i] == "-"):
			i += 1
		var digits := 0
		while i < s.length() and s[i] >= "0" and s[i] <= "9":
			i += 1
			digits += 1
		if i < s.length() and s[i] == ".":
			i += 1
			while i < s.length() and s[i] >= "0" and s[i] <= "9":
				i += 1
				digits += 1
		if digits == 0:
			i = maxi(i, st + 1)
			return NAN
		if i < s.length() and (s[i] == "e" or s[i] == "E"):
			var j := i + 1
			if j < s.length() and (s[j] == "+" or s[j] == "-"):
				j += 1
			if j < s.length() and s[j] >= "0" and s[j] <= "9":
				while j < s.length() and s[j] >= "0" and s[j] <= "9":
					j += 1
				i = j
		return s.substr(st, i - st).to_float()

	func flag() -> int:
		skip_sep()
		if i < s.length() and (s[i] == "0" or s[i] == "1"):
			i += 1
			return int(s[i - 1])
		return -1

	func numbers() -> PackedFloat32Array:
		var out := PackedFloat32Array()
		while not done():
			var v := number()
			if is_nan(v):
				break
			out.append(v)
		return out


var _ids := {}                            # element id -> El
var _rules: Array = []                    # {tag, classes, id, decl}
var _grads := {}                          # gradient id -> first stop colour
var _prims: Array = []
var _skipped := {}
var _page := Rect2()                      # the drawing area in SVG units (zero size = unknown)
var _tol := 0.3                           # flattening tolerance in SVG units
var _bg_removed := false
var _keep_size := false
var _bg_color := Color.WHITE


## {ok, message, items, size (metres), count, skipped, title}
## `keep_size` leaves small drawings at their real size instead of enlarging them.
static func parse(svg: String, keep_size: bool = false) -> Dictionary:
	var p := SvgImport.new()
	p._keep_size = keep_size
	return p._run(svg)


# ------------------------------------------------------------------------------------------------ driver

func _run(svg: String) -> Dictionary:
	var root := _dom(svg)
	if root == null or root.tag != "svg":
		return {"ok": false, "message": "That file is not an SVG image."}
	_index(root)
	var vb := _viewbox(String(root.attrs.get("viewBox", "")))
	var w_px := _to_px(String(root.attrs.get("width", "")), -1.0, 0.0)
	var h_px := _to_px(String(root.attrs.get("height", "")), -1.0, 0.0)
	var k := PX_M
	if vb.size.x > 0.0 and vb.size.y > 0.0:
		_page = vb
		if w_px > 0.0:
			k = PX_M * w_px / vb.size.x
		elif h_px > 0.0:
			k = PX_M * h_px / vb.size.y
	elif w_px > 0.0 and h_px > 0.0:
		_page = Rect2(0, 0, w_px, h_px)
	var ref := maxf(_page.size.x, _page.size.y)
	_tol = maxf(ref * 0.0005, 0.001) if ref > 0.0 else 0.2
	_walk(root, Transform2D.IDENTITY, _base_style(), 0)
	if _prims.is_empty():
		return {"ok": false, "message": "Nothing drawable was found in that SVG.", "skipped": _skipped}
	if _page.size.x <= 0.0 or _page.size.y <= 0.0:
		_page = _bounds().grow(maxf(_bounds().size.x, _bounds().size.y) * 0.04 + 1.0)
	var extent := maxf(_page.size.x, _page.size.y) * k
	if extent > MAX_EXTENT:
		k *= MAX_EXTENT / extent
	elif extent < TINY_EXTENT and extent > 0.0 and not _keep_size:
		k *= MIN_EXTENT / extent
	var items := _build(k)
	if items.is_empty():
		return {"ok": false, "message": "Nothing drawable was found in that SVG.", "skipped": _skipped}
	var title := ""
	for kid in root.kids:
		if (kid as El).tag == "title":
			for t in (kid as El).kids:
				title += (t as El).text
	return {"ok": true, "message": "", "items": items, "size": Vector2(maxf(_page.size.x * k, 0.1), maxf(_page.size.y * k, 0.1)),
		"count": items.size(), "skipped": _skipped, "title": title.strip_edges(), "background_removed": _bg_removed, "backing": _backing()}


## The canvas backing that suits the ink: dark ink goes on white, light ink on the default glass, a dark page background on dark.
func _backing() -> String:
	if _bg_removed:
		return "dark" if _bg_color.get_luminance() < 0.4 else "white"
	var sum := 0.0
	var n := 0
	for p in _prims:
		for key in ["stroke", "fill", "color"]:
			if p.has(key) and (p[key] as Color).a >= 0.0:
				sum += (p[key] as Color).get_luminance()
				n += 1
				break
	return "white" if n > 0 and sum / n < 0.4 else ""


## One line saying what was left out, "" when nothing was.
static func skipped_text(skipped: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in skipped.keys():
		parts.append("%d %s" % [int(skipped[k]), k])
	return ", ".join(parts)


func _skip(what: String, n: int = 1) -> void:
	_skipped[what] = int(_skipped.get(what, 0)) + n


# ------------------------------------------------------------------------------------------------ document tree

func _dom(svg: String) -> El:
	var p := XMLParser.new()
	if p.open_buffer(svg.to_utf8_buffer()) != OK:
		return null
	var root: El = null
	var stack: Array = []
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var e := El.new()
				e.tag = _local(p.get_node_name())
				for i in p.get_attribute_count():
					e.attrs[_local(p.get_attribute_name(i))] = p.get_attribute_value(i)
				if root == null:
					root = e
				elif not stack.is_empty():
					(stack.back() as El).kids.append(e)
				else:
					continue
				if not p.is_empty():
					stack.append(e)
			XMLParser.NODE_ELEMENT_END:
				if not stack.is_empty():
					stack.pop_back()
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if not stack.is_empty():
					var parent := stack.back() as El
					var data := p.get_node_data()
					if ["text", "tspan", "textPath", "style", "title"].has(parent.tag) and (data.strip_edges() != "" or parent.tag == "text" or parent.tag == "tspan"):
						var t := El.new()
						t.tag = "#text"
						t.text = data
						parent.kids.append(t)
	return root


static func _local(name: String) -> String:
	var at := name.rfind(":")
	return name.substr(at + 1) if at >= 0 else name


## Collects ids, style sheet rules and gradients before anything is drawn (they may come after their first use).
func _index(el: El) -> void:
	if el.attrs.has("id"):
		_ids[String(el.attrs.id)] = el
	match el.tag:
		"style":
			var css := ""
			for t in el.kids:
				css += (t as El).text
			_parse_css(css)
		"linearGradient", "radialGradient":
			_index_gradient(el)
	for k in el.kids:
		if (k as El).tag != "#text":
			_index(k)


func _index_gradient(el: El) -> void:
	if not el.attrs.has("id"):
		return
	var stops: Array = []
	for k in el.kids:
		if (k as El).tag == "stop":
			stops.append(k)
	if stops.is_empty() and el.attrs.has("href"):
		var ref: El = _ids.get(String(el.attrs.href).trim_prefix("#"))
		if ref != null:
			for k in ref.kids:
				if (k as El).tag == "stop":
					stops.append(k)
	if stops.is_empty():
		return
	var first := stops[0] as El
	var d := _decls(first)
	var c := _color(String(d.get("stop-color", "black")), Color.BLACK)
	c.a *= _num(String(d.get("stop-opacity", "1")), 1.0)
	_grads[String(el.attrs.id)] = c


func _parse_css(css: String) -> void:
	var cleaned := RegEx.create_from_string(r"/\*.*?\*/").sub(css, "", true)
	for block in cleaned.split("}"):
		var b := String(block)
		var brace := b.find("{")
		if brace < 0:
			continue
		var decl := _parse_decls(b.substr(brace + 1))
		for sel in b.substr(0, brace).split(","):
			var s := String(sel).strip_edges()
			var m := RegEx.create_from_string(r"^([A-Za-z0-9_-]*|\*)((?:\.[A-Za-z0-9_-]+)*)(?:#([A-Za-z0-9_-]+))?$").search(s)
			if m == null or s == "":
				continue
			var classes := PackedStringArray()
			for c in m.get_string(2).split(".", false):
				classes.append(c)
			_rules.append({"tag": m.get_string(1), "classes": classes, "id": m.get_string(3), "decl": decl})


static func _parse_decls(text: String) -> Dictionary:
	var out := {}
	for part in text.split(";"):
		var kv := String(part).split(":", true, 1)
		if kv.size() == 2:
			out[kv[0].strip_edges()] = kv[1].strip_edges().trim_suffix("!important").strip_edges()
	return out


# ------------------------------------------------------------------------------------------------ style

func _base_style() -> Dictionary:
	return {"fill": "black", "stroke": "none", "stroke-width": "1", "fill-opacity": "1", "stroke-opacity": "1", "font-size": "16", "font-weight": "normal", "font-style": "normal",
		"text-anchor": "start", "color": "black", "visibility": "visible", "_op": 1.0}


## The properties an element sets itself: presentation attributes, then style sheet rules, then its style attribute.
func _decls(el: El) -> Dictionary:
	var d := {}
	for key in ["fill", "stroke", "stroke-width", "fill-opacity", "stroke-opacity", "opacity", "font-size", "font-weight", "font-style", "text-anchor", "color", "display", "visibility", "stop-color", "stop-opacity"]:
		if el.attrs.has(key):
			d[key] = String(el.attrs[key]).strip_edges()
	var classes := String(el.attrs.get("class", "")).split(" ", false)
	for r in _rules:
		var rule: Dictionary = r
		if str(rule.tag) not in ["", "*", el.tag]:
			continue
		if str(rule.id) != "" and str(rule.id) != String(el.attrs.get("id", "")):
			continue
		var ok := true
		for c in (rule.classes as PackedStringArray):
			if not classes.has(c):
				ok = false
		if ok:
			d.merge(rule.decl, true)
	if el.attrs.has("style"):
		d.merge(_parse_decls(String(el.attrs.style)), true)
	return d


func _style(el: El, parent: Dictionary) -> Dictionary:
	var own := _decls(el)
	var st := parent.duplicate()
	for key in INHERITED:
		if own.has(key) and own[key] != "inherit":
			st[key] = own[key]
	st["_op"] = float(parent._op) * clampf(_num(String(own.get("opacity", "1")), 1.0), 0.0, 1.0)
	st["display"] = own.get("display", "")
	return st


## Colour of a paint value; NONE for "no paint". `st` supplies currentColor.
func _paint(value: String, st: Dictionary, opacity_key: String) -> Color:
	var v := value.strip_edges()
	if v == "" or v == "none" or v == "transparent":
		return NONE
	var c := Color.BLACK
	if v == "currentColor":
		c = _color(String(st.get("color", "black")), Color.BLACK)
	elif v.begins_with("url("):
		var id := v.substr(4).get_slice(")", 0).strip_edges().trim_prefix("'").trim_suffix("'").trim_prefix("\"").trim_suffix("\"").trim_prefix("#")
		if _grads.has(id):
			c = _grads[id]
			_skip("gradients (one colour used)")
		else:
			_skip("patterns")
			return NONE
	else:
		c = _color(v, Color(-1, 0, 0))
		if c.r < 0.0:
			return NONE
	c.a *= clampf(_num(String(st.get(opacity_key, "1")), 1.0), 0.0, 1.0) * float(st._op)
	return c if c.a > 0.004 else NONE


static func _color(s: String, fallback: Color) -> Color:
	var v := s.strip_edges().to_lower()
	if v.begins_with("rgb"):
		var nums := RegEx.create_from_string(r"[-+]?\d*\.?\d+%?").search_all(v.substr(v.find("(")))
		if nums.size() < 3:
			return fallback
		var ch: Array = []
		for i in 3:
			var t := nums[i].get_string()
			ch.append(clampf(t.trim_suffix("%").to_float() / (100.0 if t.ends_with("%") else 255.0), 0.0, 1.0))
		var a := 1.0
		if nums.size() > 3:
			var t4 := nums[3].get_string()
			a = clampf(t4.trim_suffix("%").to_float() / (100.0 if t4.ends_with("%") else 1.0), 0.0, 1.0)
		return Color(ch[0], ch[1], ch[2], a)
	if CSS_NAMES.has(v):
		v = CSS_NAMES[v]
	return Color.from_string(v, fallback)


static func _num(s: String, fallback: float) -> float:
	var t := s.strip_edges()
	if t == "":
		return fallback
	if t.ends_with("%"):
		return t.trim_suffix("%").to_float() / 100.0
	return t.to_float() if t.is_valid_float() else fallback


## A length with its unit in SVG user units (CSS pixels). `ref` is what a percentage refers to. fallback when empty / invalid.
static func _to_px(s: String, fallback: float, ref: float) -> float:
	var t := s.strip_edges()
	if t == "":
		return fallback
	var m := RegEx.create_from_string(r"^([-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)\s*([a-z%]*)$").search(t)
	if m == null:
		return fallback
	var v := m.get_string(1).to_float()
	match m.get_string(2):
		"", "px": return v
		"mm": return v * 96.0 / 25.4
		"cm": return v * 96.0 / 2.54
		"in": return v * 96.0
		"pt": return v * 96.0 / 72.0
		"pc": return v * 16.0
		"em": return v * 16.0
		"ex": return v * 8.0
		"%": return ref * v / 100.0 if ref > 0.0 else fallback
	return fallback


static func _viewbox(s: String) -> Rect2:
	var n := Scan.new(s).numbers()
	return Rect2(n[0], n[1], n[2], n[3]) if n.size() == 4 else Rect2()


static func _transform(s: String) -> Transform2D:
	var out := Transform2D.IDENTITY
	if s.strip_edges() == "":
		return out
	for m in RegEx.create_from_string(r"([a-zA-Z]+)\s*\(([^)]*)\)").search_all(s):
		var a := Scan.new(m.get_string(2)).numbers()
		var t := Transform2D.IDENTITY
		match m.get_string(1):
			"matrix":
				if a.size() >= 6:
					t = Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))
			"translate":
				if a.size() >= 1:
					t = Transform2D(0.0, Vector2(a[0], a[1] if a.size() > 1 else 0.0))
			"scale":
				if a.size() >= 1:
					t = Transform2D(Vector2(a[0], 0), Vector2(0, a[1] if a.size() > 1 else a[0]), Vector2.ZERO)
			"rotate":
				if a.size() >= 1:
					t = Transform2D(deg_to_rad(a[0]), Vector2.ZERO)
					if a.size() >= 3:
						var c := Vector2(a[1], a[2])
						t = Transform2D(0.0, c) * t * Transform2D(0.0, -c)
			"skewX":
				if a.size() >= 1:
					t = Transform2D(Vector2(1, 0), Vector2(tan(deg_to_rad(a[0])), 1), Vector2.ZERO)
			"skewY":
				if a.size() >= 1:
					t = Transform2D(Vector2(1, tan(deg_to_rad(a[0]))), Vector2(0, 1), Vector2.ZERO)
		out = out * t
	return out


# ------------------------------------------------------------------------------------------------ walking the tree

func _walk(el: El, xf: Transform2D, parent: Dictionary, depth: int) -> void:
	if depth > MAX_DEPTH or el.tag == "#text" or SKIP_TAGS.has(el.tag):
		return
	var st := _style(el, parent)
	if st.display == "none" or st.visibility == "hidden" or st.visibility == "collapse":
		return
	var lxf := xf * _transform(String(el.attrs.get("transform", "")))
	if el.attrs.has("clip-path") or el.attrs.has("mask"):
		_skip("clip paths / masks")
	if el.attrs.has("filter"):
		_skip("filters")
	var ref_w := maxf(_page.size.x, 1.0)
	var ref_h := maxf(_page.size.y, 1.0)
	match el.tag:
		"svg", "g", "a":
			if el.tag == "svg" and depth > 0:
				lxf = lxf * Transform2D(0.0, Vector2(_to_px(String(el.attrs.get("x", "")), 0.0, ref_w), _to_px(String(el.attrs.get("y", "")), 0.0, ref_h)))
			for k in el.kids:
				_walk(k, lxf, st, depth + 1)
		"switch":
			for k in el.kids:
				if (k as El).tag != "#text":
					_walk(k, lxf, st, depth + 1)
					break
		"use":
			var target: El = _ids.get(String(el.attrs.get("href", "")).trim_prefix("#"))
			if target == null:
				_skip("external references")
				return
			var off := Vector2(_to_px(String(el.attrs.get("x", "")), 0.0, ref_w), _to_px(String(el.attrs.get("y", "")), 0.0, ref_h))
			var uxf := lxf * Transform2D(0.0, off)
			if target.tag == "symbol":
				for k in target.kids:
					_walk(k, uxf, st, depth + 1)
			else:
				_walk(target, uxf, st, depth + 1)
		"path":
			var d := String(el.attrs.get("d", ""))
			for sub in _path(d, lxf):
				_emit_poly(sub.pts, bool(sub.closed), st, lxf, el)
		"rect":
			_rect(el, lxf, st)
		"circle", "ellipse":
			_ellipse(el, lxf, st)
		"line":
			var a := lxf * Vector2(_to_px(String(el.attrs.get("x1", "")), 0.0, ref_w), _to_px(String(el.attrs.get("y1", "")), 0.0, ref_h))
			var b := lxf * Vector2(_to_px(String(el.attrs.get("x2", "")), 0.0, ref_w), _to_px(String(el.attrs.get("y2", "")), 0.0, ref_h))
			var sc := _paint(String(st.stroke), st, "stroke-opacity")
			if sc.a >= 0.0:
				_prims.append({"k": "line", "a": a, "b": b, "stroke": sc, "sw": _stroke_w(st, lxf)})
			_check_markers(el)
		"polyline", "polygon":
			var n := Scan.new(String(el.attrs.get("points", ""))).numbers()
			var pts := PackedVector2Array()
			for i in range(0, n.size() - 1, 2):
				pts.append(lxf * Vector2(n[i], n[i + 1]))
			_emit_poly(pts, el.tag == "polygon", st, lxf, el)
		"text":
			_text(el, lxf, st)
		"image":
			_skip("images")
		"foreignObject":
			_skip("embedded web content")


func _check_markers(el: El) -> void:
	if el.attrs.has("marker-end") or el.attrs.has("marker-start") or el.attrs.has("marker-mid"):
		_skip("arrow markers")


static func _scale_of(xf: Transform2D) -> float:
	return sqrt(absf(xf.determinant()))


func _stroke_w(st: Dictionary, xf: Transform2D) -> float:
	return maxf(_to_px(String(st["stroke-width"]), 1.0, maxf(_page.size.x, 1.0)), 0.0) * _scale_of(xf)


## One polygon or polyline (points already in root SVG units) with whatever paint the style gives it.
func _emit_poly(pts: PackedVector2Array, closed: bool, st: Dictionary, xf: Transform2D, el: El) -> void:
	_check_markers(el)
	var f := _paint(String(st.fill), st, "fill-opacity")
	var s := _paint(String(st.stroke), st, "stroke-opacity")
	if (f.a < 0.0 and s.a < 0.0) or pts.size() < 2:
		return
	if closed and pts.size() > 2 and pts[0].distance_to(pts[pts.size() - 1]) < 1e-6:
		pts.remove_at(pts.size() - 1)
	var fills := f.a >= 0.0 and pts.size() >= 3
	if not closed and not fills:
		_prims.append({"k": "stroke", "pts": pts, "stroke": s, "sw": _stroke_w(st, xf)})
		return
	if pts.size() < 3:
		return
	_prims.append({"k": "poly", "pts": pts, "fill": f if fills else NONE, "stroke": s, "sw": _stroke_w(st, xf)})


## "sim" (rotation, uniform scale, mirror), "axis" (plain stretch) or "general" (skew): how a rectangle or ellipse can be kept parametric.
static func _xf_kind(xf: Transform2D) -> String:
	var sx := xf.x.length()
	var sy := xf.y.length()
	if sx < 1e-9 or sy < 1e-9:
		return "general"
	if absf(xf.x.normalized().dot(xf.y.normalized())) > 0.01:
		return "general"
	if absf(sx - sy) <= 0.01 * maxf(sx, sy):
		return "sim"
	if absf(xf.x.y) < 1e-6 * sx and absf(xf.y.x) < 1e-6 * sy:
		return "axis"
	return "general"


func _rect(el: El, xf: Transform2D, st: Dictionary) -> void:
	var rw := maxf(_page.size.x, 1.0)
	var rh := maxf(_page.size.y, 1.0)
	var x := _to_px(String(el.attrs.get("x", "")), 0.0, rw)
	var y := _to_px(String(el.attrs.get("y", "")), 0.0, rh)
	var w := _to_px(String(el.attrs.get("width", "")), 0.0, rw)
	var h := _to_px(String(el.attrs.get("height", "")), 0.0, rh)
	if w <= 0.0 or h <= 0.0:
		return
	var f := _paint(String(st.fill), st, "fill-opacity")
	var s := _paint(String(st.stroke), st, "stroke-opacity")
	if f.a < 0.0 and s.a < 0.0:
		return
	var rx := _to_px(String(el.attrs.get("rx", "")), -1.0, rw)
	var ry := _to_px(String(el.attrs.get("ry", "")), -1.0, rh)
	if rx < 0.0:
		rx = maxf(ry, 0.0)
	if ry < 0.0:
		ry = rx
	rx = minf(rx, w * 0.5)
	ry = minf(ry, h * 0.5)
	# a plain filled rectangle laid over the whole drawing first of all is the page background: left out
	if _prims.is_empty() and _page.size.x > 0.0 and f.a >= 0.0 and s.a < 0.0 and _xf_kind(xf) != "general":
		var covered := Rect2(xf * Vector2(x, y), Vector2.ZERO).expand(xf * Vector2(x + w, y + h))
		if covered.size.x >= _page.size.x * 0.98 and covered.size.y >= _page.size.y * 0.98:
			_bg_removed = true
			_bg_color = f
			return
	var kind := _xf_kind(xf)
	var sw := _stroke_w(st, xf)
	if kind != "general" and rx < 0.001:
		var size := Vector2(w, h) * xf.x.length() if kind == "sim" else Vector2(w * xf.x.length(), h * xf.y.length())
		_prims.append({"k": "rect", "shape": "rect", "center": xf * Vector2(x + w * 0.5, y + h * 0.5), "size": size,
			"rot": xf.get_rotation() if kind == "sim" else 0.0, "fill": f, "stroke": s, "sw": sw})
		return
	if kind != "general" and rx >= 0.45 * minf(w, h) and ry >= 0.45 * minf(w, h) * 0.999:
		var size2 := Vector2(w, h) * xf.x.length() if kind == "sim" else Vector2(w * xf.x.length(), h * xf.y.length())
		_prims.append({"k": "rect", "shape": "rrect", "center": xf * Vector2(x + w * 0.5, y + h * 0.5), "size": size2,
			"rot": xf.get_rotation() if kind == "sim" else 0.0, "fill": f, "stroke": s, "sw": sw})
		return
	var pts := PackedVector2Array()
	if rx < 0.001 or ry < 0.001:
		pts = PackedVector2Array([Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h)])
	else:
		var steps := _arc_steps(PI * 0.5, maxf(rx, ry), xf)
		for corner in 4:
			var c := Vector2(x + w - rx, y + ry) if corner == 0 else (Vector2(x + w - rx, y + h - ry) if corner == 1 else (Vector2(x + rx, y + h - ry) if corner == 2 else Vector2(x + rx, y + ry)))
			for i in steps + 1:
				var a := -PI * 0.5 + PI * 0.5 * (corner + float(i) / steps)
				pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	for i in pts.size():
		pts[i] = xf * pts[i]
	_prims.append({"k": "poly", "pts": pts, "fill": f, "stroke": s, "sw": sw})


func _ellipse(el: El, xf: Transform2D, st: Dictionary) -> void:
	var rw := maxf(_page.size.x, 1.0)
	var rh := maxf(_page.size.y, 1.0)
	var cx := _to_px(String(el.attrs.get("cx", "")), 0.0, rw)
	var cy := _to_px(String(el.attrs.get("cy", "")), 0.0, rh)
	var rx := 0.0
	var ry := 0.0
	if el.tag == "circle":
		rx = _to_px(String(el.attrs.get("r", "")), 0.0, minf(rw, rh))
		ry = rx
	else:
		rx = _to_px(String(el.attrs.get("rx", "")), 0.0, rw)
		ry = _to_px(String(el.attrs.get("ry", "")), rx, rh)
	if rx <= 0.0 or ry <= 0.0:
		return
	var f := _paint(String(st.fill), st, "fill-opacity")
	var s := _paint(String(st.stroke), st, "stroke-opacity")
	if f.a < 0.0 and s.a < 0.0:
		return
	var kind := _xf_kind(xf)
	var sw := _stroke_w(st, xf)
	if kind != "general":
		var size := Vector2(rx, ry) * 2.0 * xf.x.length() if kind == "sim" else Vector2(rx * 2.0 * xf.x.length(), ry * 2.0 * xf.y.length())
		_prims.append({"k": "rect", "shape": "ellipse", "center": xf * Vector2(cx, cy), "size": size,
			"rot": xf.get_rotation() if kind == "sim" else 0.0, "fill": f, "stroke": s, "sw": sw})
		return
	var pts := PackedVector2Array()
	var n := maxi(_arc_steps(TAU, maxf(rx, ry), xf), 12)
	for i in n:
		var a := TAU * float(i) / n
		pts.append(xf * (Vector2(cx, cy) + Vector2(cos(a) * rx, sin(a) * ry)))
	_prims.append({"k": "poly", "pts": pts, "fill": f, "stroke": s, "sw": sw})


## Number of straight pieces for an arc of `angle` radians and `radius` (user units) so it stays within the tolerance.
func _arc_steps(angle: float, radius: float, xf: Transform2D) -> int:
	var r := maxf(radius * _scale_of(xf), 1e-6)
	var step := 2.0 * acos(clampf(1.0 - _tol / r, -1.0, 0.9999))
	return clampi(ceili(absf(angle) / maxf(step, 0.04)), 2, 160)


# ------------------------------------------------------------------------------------------------ paths

## Path data to polylines in root SVG units: [{pts, closed}]. Curves are flattened after the transform (curves stay curves under it).
func _path(d: String, xf: Transform2D) -> Array:
	var sc := Scan.new(d)
	var subs: Array = []
	var cur := PackedVector2Array()
	var pos := Vector2.ZERO
	var start := Vector2.ZERO
	var ctrl := Vector2.ZERO                  # last control point (for S and T)
	var prev := ""                            # the previous command, upper case
	var cmd := ""
	var guard := 0
	while not sc.done() and guard < 400000:
		guard += 1
		var c := sc.peek()
		if "MmLlHhVvCcSsQqTtAaZz".contains(c):
			cmd = c
			sc.i += 1
		elif cmd == "" or cmd == "Z" or cmd == "z" or not sc.next_is_number():
			break
		var rel := cmd == cmd.to_lower()
		var up := cmd.to_upper()
		match up:
			"Z":
				if cur.size() >= 2:
					subs.append({"pts": cur, "closed": true})
				cur = PackedVector2Array()
				pos = start
				prev = "Z"
				continue
			"M":
				var p := _read_pt(sc, pos, rel)
				if not is_finite(p.x):
					break
				if cur.size() >= 2:
					subs.append({"pts": cur, "closed": false})
				pos = p
				start = p
				cur = PackedVector2Array([xf * p])
				cmd = "l" if rel else "L"
				prev = "M"
				continue
		if cur.is_empty():
			cur = PackedVector2Array([xf * pos])
		var from := pos
		match up:
			"L":
				var p2 := _read_pt(sc, pos, rel)
				if not is_finite(p2.x):
					break
				pos = p2
				cur.append(xf * pos)
			"H":
				var x := sc.number()
				if is_nan(x):
					break
				pos.x = pos.x + x if rel else x
				cur.append(xf * pos)
			"V":
				var y := sc.number()
				if is_nan(y):
					break
				pos.y = pos.y + y if rel else y
				cur.append(xf * pos)
			"C", "S":
				var c1 := Vector2.ZERO
				if up == "C":
					c1 = _read_pt(sc, pos, rel)
				else:
					c1 = pos + (pos - ctrl) if (prev == "C" or prev == "S") else pos
				var c2 := _read_pt(sc, pos, rel)
				var p3 := _read_pt(sc, pos, rel)
				if not (is_finite(c1.x) and is_finite(c2.x) and is_finite(p3.x)):
					break
				_cubic(cur, xf * from, xf * c1, xf * c2, xf * p3)
				ctrl = c2
				pos = p3
			"Q", "T":
				var q1 := Vector2.ZERO
				if up == "Q":
					q1 = _read_pt(sc, pos, rel)
				else:
					q1 = pos + (pos - ctrl) if (prev == "Q" or prev == "T") else pos
				var q2 := _read_pt(sc, pos, rel)
				if not (is_finite(q1.x) and is_finite(q2.x)):
					break
				_quad(cur, xf * from, xf * q1, xf * q2)
				ctrl = q1
				pos = q2
			"A":
				var rx := sc.number()
				var ry := sc.number()
				var rot := sc.number()
				var fa := sc.flag()
				var fs := sc.flag()
				var p4 := _read_pt(sc, pos, rel)
				if is_nan(rx) or is_nan(ry) or is_nan(rot) or fa < 0 or fs < 0 or not is_finite(p4.x):
					break
				_arc(cur, from, p4, rx, ry, rot, fa == 1, fs == 1, xf)
				pos = p4
			_:
				break
		prev = up
	if cur.size() >= 2:
		subs.append({"pts": cur, "closed": false})
	return subs


static func _read_pt(sc: Scan, pos: Vector2, rel: bool) -> Vector2:
	var x := sc.number()
	var y := sc.number()
	if is_nan(x) or is_nan(y):
		return Vector2(INF, INF)
	return Vector2(pos.x + x, pos.y + y) if rel else Vector2(x, y)


func _cubic(out: PackedVector2Array, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2) -> void:
	var dd := maxf((p0 - 2.0 * p1 + p2).length(), (p1 - 2.0 * p2 + p3).length())
	var n := clampi(ceili(sqrt(0.75 * dd / _tol)), 1, 100)
	for i in range(1, n + 1):
		var t := float(i) / n
		var u := 1.0 - t
		out.append(u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3)


func _quad(out: PackedVector2Array, p0: Vector2, p1: Vector2, p2: Vector2) -> void:
	var dd := (p0 - 2.0 * p1 + p2).length()
	var n := clampi(ceili(sqrt(dd / (4.0 * _tol))), 1, 100)
	for i in range(1, n + 1):
		var t := float(i) / n
		var u := 1.0 - t
		out.append(u * u * p0 + 2.0 * u * t * p1 + t * t * p2)


## SVG's endpoint arc (implementation notes F.6.5): turned into a centre and sweep, then sampled.
func _arc(out: PackedVector2Array, p1: Vector2, p2: Vector2, rx_in: float, ry_in: float, rot_deg: float, large: bool, sweep: bool, xf: Transform2D) -> void:
	var rx := absf(rx_in)
	var ry := absf(ry_in)
	if p1 == p2:
		return
	if rx < 1e-9 or ry < 1e-9:
		out.append(xf * p2)
		return
	var phi := deg_to_rad(fmod(rot_deg, 360.0))
	var cp := cos(phi)
	var sp := sin(phi)
	var d := (p1 - p2) * 0.5
	var x1p := cp * d.x + sp * d.y
	var y1p := -sp * d.x + cp * d.y
	var lam := x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
	if lam > 1.0:
		var sl := sqrt(lam)
		rx *= sl
		ry *= sl
	var num := rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
	var den := rx * rx * y1p * y1p + ry * ry * x1p * x1p
	var co := sqrt(maxf(0.0, num / den)) * (-1.0 if large == sweep else 1.0) if den > 0.0 else 0.0
	var cxp := co * rx * y1p / ry
	var cyp := -co * ry * x1p / rx
	var mid := (p1 + p2) * 0.5
	var center := Vector2(cp * cxp - sp * cyp + mid.x, sp * cxp + cp * cyp + mid.y)
	var u := Vector2((x1p - cxp) / rx, (y1p - cyp) / ry)
	var v := Vector2((-x1p - cxp) / rx, (-y1p - cyp) / ry)
	var th1 := atan2(u.y, u.x)
	var dth := atan2(u.x * v.y - u.y * v.x, u.dot(v))
	if not sweep and dth > 0.0:
		dth -= TAU
	elif sweep and dth < 0.0:
		dth += TAU
	var n := _arc_steps(dth, maxf(rx, ry), xf)
	for i in range(1, n + 1):
		var a := th1 + dth * float(i) / n
		var q := Vector2(center.x + rx * cos(a) * cp - ry * sin(a) * sp, center.y + rx * cos(a) * sp + ry * sin(a) * cp)
		out.append(xf * (p2 if i == n else q))


# ------------------------------------------------------------------------------------------------ text

func _text(el: El, xf: Transform2D, st: Dictionary) -> void:
	var color := _paint(String(st.fill), st, "fill-opacity")
	if color.a < 0.0:
		return
	var lines: Array = []
	var state := {"cur": "", "x": NAN, "y": NAN}
	var first := Scan.new(String(el.attrs.get("x", ""))).numbers()
	var firsty := Scan.new(String(el.attrs.get("y", ""))).numbers()
	if first.size() > 0:
		state.x = first[0]
	if firsty.size() > 0:
		state.y = firsty[0]
	_collect_text(el, lines, state, true)
	if String(state.cur).strip_edges() != "":
		lines.append(state.cur)
	var cleaned: Array = []
	for l in lines:
		var t := String(l).strip_edges()
		t = RegEx.create_from_string(r" {2,}").sub(t, " ", true)
		if t != "":
			cleaned.append(t)
	if cleaned.is_empty():
		return
	var x := 0.0 if is_nan(state.x) else float(state.x)
	var y := 0.0 if is_nan(state.y) else float(state.y)
	var em := _to_px(String(st["font-size"]), 16.0, 16.0) * _scale_of(xf)
	_prims.append({"k": "text", "lines": cleaned, "pos": xf * Vector2(x, y), "em": em, "anchor": String(st["text-anchor"]),
		"rot": xf.get_rotation(), "color": color, "weight": _font_weight(String(st["font-weight"])), "italic": ["italic", "oblique"].has(String(st["font-style"]))})


## CSS font-weight (keyword or number) as an Open Sans weight.
static func _font_weight(v: String) -> int:
	match v.strip_edges():
		"bold", "bolder":
			return 700
		"normal", "lighter", "":
			return TextLayout.REGULAR
	return clampi(roundi(float(v) / 50.0) * 50, TextLayout.MIN_WEIGHT, TextLayout.MAX_WEIGHT) if v.is_valid_float() else TextLayout.REGULAR


func _collect_text(el: El, lines: Array, state: Dictionary, is_root: bool) -> void:
	for k in el.kids:
		var kid := k as El
		if kid.tag == "#text":
			state.cur = String(state.cur) + kid.text.replace("\n", " ").replace("\t", " ").replace("\r", "")
		elif kid.tag == "tspan" or kid.tag == "textPath":
			var has_y := kid.attrs.has("y") or (kid.attrs.has("dy") and absf(_to_px(String(kid.attrs.dy), 0.0, 16.0)) > 0.01)
			if has_y and String(state.cur).strip_edges() != "":
				lines.append(state.cur)
				state.cur = ""
			if is_nan(state.x) and kid.attrs.has("x"):
				var nx := Scan.new(String(kid.attrs.x)).numbers()
				if nx.size() > 0:
					state.x = nx[0]
			if is_nan(state.y) and kid.attrs.has("y"):
				var ny := Scan.new(String(kid.attrs.y)).numbers()
				if ny.size() > 0:
					state.y = ny[0]
			_collect_text(kid, lines, state, false)


# ------------------------------------------------------------------------------------------------ building the items

func _bounds() -> Rect2:
	var bb := Rect2()
	var first := true
	for p in _prims:
		var pts := PackedVector2Array()
		match str(p.k):
			"poly", "stroke":
				pts = p.pts
			"line":
				pts = PackedVector2Array([p.a, p.b])
			"rect":
				var h: Vector2 = (p.size as Vector2) * 0.5
				pts = PackedVector2Array([p.center - h, p.center + h])
			"text":
				pts = PackedVector2Array([p.pos, p.pos + Vector2(float(p.em) * 4.0, -float(p.em))])
		for q in pts:
			if first:
				bb = Rect2(q, Vector2.ZERO)
				first = false
			else:
				bb = bb.expand(q)
	return bb


func _build(k: float) -> Array:
	var c := _page.get_center()
	var items: Array = []
	var over := 0
	for p in _prims:
		if items.size() >= MAX_ITEMS:
			over += 1
			continue
		var it := _item(p, k, c)
		if it != null:
			items.append(it)
	if over > 0:
		_skip("shapes over the limit of %d" % MAX_ITEMS, over)
	return items


func _item(p: Dictionary, k: float, c: Vector2) -> Item:
	var conv := func(q: Vector2) -> Vector2: return Vector2((q.x - c.x) * k, (c.y - q.y) * k)
	var width := clampf(float(p.get("sw", 0.0)) * k, MIN_WIDTH, MAX_WIDTH)
	match str(p.k):
		"stroke":
			var pts := PackedFloat32Array()
			var last := Vector2(INF, INF)
			var src: PackedVector2Array = p.pts
			for i in src.size():
				var q: Vector2 = conv.call(src[i])
				if last.is_finite() and q.distance_to(last) < MIN_POINT_GAP and i < src.size() - 1:
					continue
				pts.append_array(PackedFloat32Array([q.x, q.y, 0.0, PRESSURE]))
				last = q
			if pts.size() < 8:
				return null
			return Item.make_stroke("", pts, p.stroke, width, "pen")
		"poly":
			var poly := PackedVector2Array()
			var last2 := Vector2(INF, INF)
			var src2: PackedVector2Array = p.pts
			for i in src2.size():
				var q2: Vector2 = conv.call(src2[i])
				if last2.is_finite() and q2.distance_to(last2) < MIN_POINT_GAP * 0.5:
					continue
				poly.append(q2)
				last2 = q2
			if poly.size() < 3:
				return null
			var it := Item.make_shape("", "poly", _outline_color(p), width if (p.stroke as Color).a >= 0.0 else MIN_WIDTH)
			it.poly = poly
			it.fill = p.fill if (p.fill as Color).a >= 0.0 else Color(0, 0, 0, 0)
			return it
		"rect":
			var it2 := Item.make_shape("", str(p.shape), _outline_color(p), width if (p.stroke as Color).a >= 0.0 else MIN_WIDTH)
			it2.center = conv.call(p.center)
			it2.size = Vector2(maxf((p.size as Vector2).x * k, 0.002), maxf((p.size as Vector2).y * k, 0.002))
			it2.rot = -float(p.rot)
			it2.fill = p.fill if (p.fill as Color).a >= 0.0 else Color(0, 0, 0, 0)
			return it2
		"line":
			var it3 := Item.make_shape("", "line", p.stroke, width)
			it3.a = conv.call(p.a)
			it3.b = conv.call(p.b)
			return it3
		"text":
			var em := clampf(float(p.em) * k, 0.004, 0.6)
			var text := "\n".join(PackedStringArray(p.lines))
			var it4 := Item.make_text("", text, p.color, em)
			it4.weight = int(p.weight)
			it4.italic = bool(p.italic)
			it4.refit_text()
			var base: Vector2 = conv.call(p.pos)
			var rot := -float(p.rot)
			var off_x := 0.0
			match str(p.anchor):
				"middle": off_x = 0.0
				"end": off_x = -it4.size.x * 0.5
				_: off_x = it4.size.x * 0.5
			var off := Vector2(off_x, em * 0.95 - it4.size.y * 0.5)
			it4.center = base + Geom2D.rot(off, rot)
			it4.rot = rot
			return it4
	return null


## Outlines take the stroke colour, shapes without a stroke take their fill colour (so the thin outline does not stand out).
func _outline_color(p: Dictionary) -> Color:
	var s: Color = p.stroke
	if s.a >= 0.0:
		return s
	var f: Color = p.fill
	return f if f.a >= 0.0 else Color.WHITE
