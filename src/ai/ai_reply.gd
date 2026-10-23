class_name AiReply
extends RefCounted
## Turns a model's answer into things the board can show: the words ("say") and the drawing it proposes as ready-made Items. New items
## get real ids at once, so arrows to new boxes are glued to them and stay glued when the suggestion is accepted.
##
## The answer is the JSON object AiPrompts.SYSTEM asks for. Models do not always obey: a fenced ```json block, text around the
## object, or plain prose without any JSON are all understood (prose becomes the words, with nothing drawn).

const MAX_ADD := 300

var say := ""
var items: Array = []                     # new Items
var changed: Array = []                   # changed copies of existing Items (same ids)
var removed: Array = []                   # ids of existing items to delete
var skipped := 0                          # entries that could not be understood

var _brief: CanvasBrief
var _doc: Document
var _new := {}                            # the model's id for a new item -> Item
var _width := 0.004


## The JSON object in a model's answer, or {"say": the text} when there is none.
static func extract(text: String) -> Dictionary:
	var t := text.strip_edges()
	var direct: Variant = LlmApi.parse_json(t)
	if direct is Dictionary:
		return direct
	var best := {}
	for o in WitSpeech.split_json_objects(t):
		if o is Dictionary and ((o as Dictionary).has("say") or (o as Dictionary).has("add") or (o as Dictionary).has("change")):
			if best.is_empty() or JSON.stringify(o).length() > JSON.stringify(best).length():
				best = o
	if not best.is_empty():
		return best
	return {"say": t}


static func build(answer: String, brief: CanvasBrief, doc: Document) -> AiReply:
	var r := AiReply.new()
	r._brief = brief
	r._doc = doc
	r._read(extract(answer))
	return r


func draws() -> bool:
	return not (items.is_empty() and changed.is_empty() and removed.is_empty())


func _read(d: Dictionary) -> void:
	say = _text(d.get("say", d.get("message", d.get("answer", ""))))
	_width = _typical_width()
	var adds: Array = d.get("add", []) if d.get("add") is Array else []
	var later: Array = []
	for e in adds.slice(0, MAX_ADD):
		if not (e is Dictionary):
			skipped += 1
			continue
		if _is_line_type(str(e.get("type", ""))):
			later.append(e)
			continue
		var it := _make(e)
		if it == null:
			skipped += 1
			continue
		items.append(it)
		if str(e.get("id", "")) != "":
			_new[str(e.id)] = it
	for e in later:
		var ln := _make_line(e, null)
		if ln == null:
			skipped += 1
		else:
			items.append(ln)
	for e in (d.get("change", []) if d.get("change") is Array else []):
		var c := _change(e) if e is Dictionary else null
		if c == null:
			skipped += 1
		else:
			changed.append(c)
	for id in (d.get("remove", []) if d.get("remove") is Array else []):
		var real := _existing(str(id))
		if real != null and not removed.has(real.id):
			removed.append(real.id)


static func _text(v: Variant) -> String:
	if v is Array:
		return "\n".join(PackedStringArray((v as Array).map(func(x): return str(x))))
	return str(v).strip_edges() if v != null else ""


static func _is_line_type(t: String) -> bool:
	return Shapes.is_line(t)


func _typical_width() -> float:
	var sum := 0.0
	var n := 0
	for it in _doc.items_of(_brief.frame_id):
		if (it as Item).kind == Item.SHAPE:
			sum += (it as Item).width
			n += 1
	return clampf(sum / n, 0.001, 0.02) if n > 0 else float(App.val("width"))


func _num(e: Dictionary, k: String, fallback: float) -> float:
	var v: Variant = e.get(k)
	return float(v) if (v is float or v is int) else fallback


func _colour(v: Variant, fallback: Color) -> Color:
	var s := str(v) if v != null else ""
	if s != "" and Color.html_is_valid(s):
		return Color.html(s)
	return fallback


func _fill(v: Variant) -> Color:
	var s := str(v) if v != null else ""
	if s == "" or not Color.html_is_valid(s) or s.to_lower() == "none":
		return Color(0, 0, 0, 0)
	var c := Color.html(s)
	if s.trim_prefix("#").length() <= 6:
		c.a = float(App.val("fill_alpha"))         # an opaque fill would hide the canvas: fills are see-through here
	return c


func _ink() -> Color:
	return Color(_brief.ink.r, _brief.ink.g, _brief.ink.b, 1.0)


## A new shape, text or freehand stroke from one "add" entry, or null.
func _make(e: Dictionary) -> Item:
	var fid := _brief.frame_id
	match str(e.get("type", "shape")):
		"shape", "box":
			var sid := str(e.get("shape", "rect"))
			if Shapes.is_line(sid) or Shapes.name_of(sid) == sid:
				sid = "rect"
			var it := Item.make_shape(fid, sid, _colour(e.get("color"), _ink()), _width)
			_place_box(it, e, Vector2.ZERO, Vector2.ZERO)
			it.label = TextController.wrap_text(str(e.get("label", "")), TextController.WRAP_CHARS)
			it.fill = _fill(e.get("fill"))
			return it
		"text":
			var words := TextController.wrap_text(str(e.get("text", "")).strip_edges(), 40)
			if words == "":
				return null
			var st := TextLayout.style(str(e.get("size", "body")))
			var t := Item.make_text(fid, words, _colour(e.get("color"), _ink()), float(st[2]), int(st[3]))
			var tl := _brief.to_frame(_num(e, "x", 0.0), _num(e, "y", 0.0))
			t.center = tl + Vector2(t.size.x * 0.5, -t.size.y * 0.5)
			return t
		"stroke", "path", "freehand", "polygon":
			var raw: Array = e.get("points", []) if e.get("points") is Array else []
			var pts := PackedFloat32Array()
			var first := Vector2.INF
			for p in raw:
				if p is Array and (p as Array).size() >= 2:
					var q := _brief.to_frame(float(p[0]), float(p[1]))
					if first == Vector2.INF:
						first = q
					pts.append_array(PackedFloat32Array([q.x, q.y, 0.0, 1.0]))
			if pts.size() < 8:
				return null
			if bool(e.get("closed", str(e.get("type", "")) == "polygon")):
				pts.append_array(PackedFloat32Array([first.x, first.y, 0.0, 1.0]))
			var w := clampf(_num(e, "width_mm", _width * 1000.0) / 1000.0, 0.0005, 0.04)
			return Item.make_stroke(fid, pts, _colour(e.get("color"), _ink()), w, "pen")
	return null


## Centre and size of a box from x, y, w, h (brief centimetres, top-left); missing fields keep `center` / `size`.
func _place_box(it: Item, e: Dictionary, center: Vector2, size: Vector2) -> void:
	var cur_w := size.x * 100.0 if size != Vector2.ZERO else it.size.x * 100.0
	var cur_h := size.y * 100.0 if size != Vector2.ZERO else it.size.y * 100.0
	var cur_x := (center.x - _brief.area.position.x) * 100.0 - cur_w * 0.5 if size != Vector2.ZERO else 0.0
	var cur_y := (_brief.area.end.y - center.y) * 100.0 - cur_h * 0.5 if size != Vector2.ZERO else 0.0
	var w := clampf(_num(e, "w", cur_w), 1.0, 500.0)
	var h := clampf(_num(e, "h", cur_h), 1.0, 500.0)
	var x := _num(e, "x", cur_x)
	var y := _num(e, "y", cur_y)
	it.size = Vector2(w, h) / 100.0
	it.center = _brief.to_frame(x + w * 0.5, y + h * 0.5)


## The existing item a short id (or a real id) means, or null.
func _existing(id: String) -> Item:
	var real := str(_brief.ids.get(id, id))
	var it: Item = _doc.items.get(real)
	return it if it != null and it.frame == _brief.frame_id else null


## A shape an arrow end can be glued to: a new one first, then an existing one.
func _target(id: String) -> Item:
	if id == "":
		return null
	var it: Item = _new.get(id)
	if it == null:
		it = _existing(id)
	if it == null or it.kind != Item.SHAPE or it.is_line() or it.shape == "poly":
		return null
	return it


## An arrow / line from an "add" entry, or the changed version of `old` from a "change" entry.
func _make_line(e: Dictionary, old: Item) -> Item:
	var kind := str(e.get("type", old.shape if old != null else "arrow"))
	if not Shapes.is_line(kind):
		kind = old.shape if old != null else "arrow"
	var ln: Item = old.duplicate_item(false) if old != null else Item.make_shape(_brief.frame_id, kind, _colour(e.get("color"), _ink()), _width)
	if old != null and e.has("color"):
		ln.color = _colour(e.get("color"), ln.color)
	var src := _target(str(e.get("from", "")))
	var dst := _target(str(e.get("to", "")))
	var pa := ln.a
	var pb := ln.b
	if e.has("x1") or e.has("y1"):
		pa = _brief.to_frame(_num(e, "x1", 0.0), _num(e, "y1", 0.0))
	if e.has("x2") or e.has("y2"):
		pb = _brief.to_frame(_num(e, "x2", 0.0), _num(e, "y2", 0.0))
	if old == null and src == null and not (e.has("x1") or e.has("y1")):
		return null
	if old == null and dst == null and not (e.has("x2") or e.has("y2")):
		return null
	var aim_a := dst.center if dst != null else pb
	var aim_b := src.center if src != null else pa
	if src != null:
		var port := Shapes.nearest_port(src, aim_a)
		ln.a = port.pos
		ln.na = port.n
		ln.glue_a = {"item": src.id, "port": int(port.idx)}
	elif e.has("x1") or e.has("y1") or old == null:
		ln.a = pa
		ln.na = Vector2.ZERO
		ln.glue_a = {}
	if dst != null:
		var port2 := Shapes.nearest_port(dst, aim_b)
		ln.b = port2.pos
		ln.nb = port2.n
		ln.glue_b = {"item": dst.id, "port": int(port2.idx)}
	elif e.has("x2") or e.has("y2") or old == null:
		ln.b = pb
		ln.nb = Vector2.ZERO
		ln.glue_b = {}
	if ln.a.distance_to(ln.b) < 0.005:
		return null
	return ln


## The changed copy of an existing item, or null when the entry names nothing (or changes nothing).
func _change(e: Dictionary) -> Item:
	var old := _existing(str(e.get("id", "")))
	if old == null:
		return null
	if old.is_line():
		return _make_line(e, old)
	var c := old.duplicate_item(false)
	if e.has("color"):
		c.color = _colour(e.get("color"), c.color)
	match c.kind:
		Item.SHAPE:
			if e.has("label"):
				c.label = TextController.wrap_text(str(e.label), TextController.WRAP_CHARS)
			if e.has("fill"):
				c.fill = _fill(e.get("fill"))
			if c.shape != "poly" and (e.has("x") or e.has("y") or e.has("w") or e.has("h")):
				_place_box(c, e, old.center, old.size)
			elif c.shape == "poly" and (e.has("x") or e.has("y")):
				c.apply_xform(Transform2D(0.0, _shift(old.bounds(), e)))
		Item.TEXT:
			if e.has("text") and str(e.text).strip_edges() != "":
				c.text = TextController.wrap_text(str(e.text).strip_edges(), 40)
			if e.has("size"):
				var st := TextLayout.style(str(e.size))
				c.font_size = float(st[2])
				c.weight = int(st[3])
			c.refit_text()
			var tl := Vector2(old.bounds().position.x, old.bounds().end.y)
			if e.has("x") or e.has("y"):
				tl = _brief.to_frame(_num(e, "x", (tl.x - _brief.area.position.x) * 100.0), _num(e, "y", (_brief.area.end.y - tl.y) * 100.0))
			c.center = tl + Vector2(c.size.x * 0.5, -c.size.y * 0.5)
		Item.STROKE:
			if e.has("x") or e.has("y"):
				c.apply_xform(Transform2D(0.0, _shift(old.bounds(), e)))
	if c.to_dict().hash() == old.to_dict().hash():
		return null
	return c


## How far x / y (the new top-left, brief centimetres) move a thing whose bounds are `b`.
func _shift(b: Rect2, e: Dictionary) -> Vector2:
	var tl := Vector2(b.position.x, b.end.y)
	var want := _brief.to_frame(_num(e, "x", (tl.x - _brief.area.position.x) * 100.0), _num(e, "y", (_brief.area.end.y - tl.y) * 100.0))
	return want - tl
