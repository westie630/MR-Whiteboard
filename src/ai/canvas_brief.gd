class_name CanvasBrief
extends RefCounted
## What a language model is told about a canvas: its items as plain JSON (what each thing is, where, its words and colours) and,
## optionally, a picture of it. Formatting is left out on purpose: the model needs the meaning (boxes, labels, arrows between them,
## text, the shape of freehand ink), not how it is drawn.
##
## Coordinates are centimetres with x to the right and y DOWN, (0, 0) at the top-left of the drawn area: the way people and models
## describe drawings. `to_frame()` turns them back into the canvas's own metres (y up). Items get short ids (s1 shapes, l2 lines,
## t3 text, p4 freehand, g5 polygons) that the model uses to refer to them; `ids` maps them back.

const MARGIN := 0.04                      # metres around the content: the same as SvgExport's, so the picture covers the same area
const MAX_ITEMS := 300
const MAX_POINTS := 24                    # points kept per freehand stroke (its shape, not its detail)
const PICTURE_PX := 1024

var frame_id := ""
var area := Rect2()                       # the described area in frame metres
var ids := {}                             # short id -> item id
var short := {}                           # item id -> short id
var json := ""                            # the canvas as JSON text
var ink := Color.WHITE                    # the colour most of the canvas is drawn in
var dark := true                          # the canvas looks dark in the headset (light ink)
var count := 0


static func make(doc: Document, fid: String, selection: Array = [], dark_look: bool = true) -> CanvasBrief:
	var b := CanvasBrief.new()
	b.frame_id = fid
	b.dark = dark_look
	b._build(doc, selection)
	return b


func _build(doc: Document, selection: Array) -> void:
	var frame: FrameData = doc.frames.get(frame_id)
	var list := doc.items_of(frame_id)
	count = list.size()
	var first := true
	for it in list:
		var r: Rect2 = (it as Item).bounds()
		area = r if first else area.merge(r)
		first = false
	if first:
		var sz: Vector2 = frame.size if frame != null else Vector2(1.2, 0.8)
		area = Rect2((frame.offset if frame != null else Vector2.ZERO) - sz * 0.5, sz)
	area = area.grow(MARGIN)
	var counts := {"s": 0, "l": 0, "t": 0, "p": 0, "g": 0}
	var colours := {}
	var rows: Array = []
	var left_out := 0
	for it in list:
		var item: Item = it
		var prefix := _prefix(item)
		counts[prefix] = int(counts[prefix]) + 1
		var sid := "%s%d" % [prefix, int(counts[prefix])]
		ids[sid] = item.id
		short[item.id] = sid
		var key := U.color_to_str(Color(item.color.r, item.color.g, item.color.b))
		colours[key] = int(colours.get(key, 0)) + 1
	for it in list:
		if rows.size() >= MAX_ITEMS:
			left_out += 1
			continue
		var row := _row(it as Item)
		if selection.has((it as Item).id):
			row["selected"] = true
		rows.append(row)
	var best := 0
	for k in colours.keys():
		if int(colours[k]) > best:
			best = int(colours[k])
			ink = Color(str(k))
	var out := {"canvas": frame.name if frame != null else "", "width_cm": _cm(area.size.x), "height_cm": _cm(area.size.y),
		"looks": "light ink on a dark background" if dark else "dark ink on a white background", "items": rows}
	if left_out > 0:
		out["not_listed"] = "%d more items" % left_out
	json = JSON.stringify(out, "", false)          # keys in the order written: id and type first reads best


static func _prefix(it: Item) -> String:
	match it.kind:
		Item.TEXT:
			return "t"
		Item.IMAGE:
			return "m"
		Item.STROKE:
			return "p"
	if it.is_line():
		return "l"
	return "g" if it.shape == "poly" else "s"


func _row(it: Item) -> Dictionary:
	var row := {"id": short[it.id]}
	var col := _hex(it.color)
	match it.kind:
		Item.TEXT:
			var b := it.bounds()
			row.merge({"type": "text", "text": it.text, "x": _x(b.position.x), "y": _y(b.end.y), "w": _cm(b.size.x), "h": _cm(b.size.y)})
			var st := TextLayout.style_id(it.font_size, it.weight)
			row["size"] = st if st != "" else "%.1f cm letters" % (it.font_size * 100.0)
			row["color"] = col
		Item.IMAGE:
			var ib := it.bounds()
			row.merge({"type": "picture", "x": _x(ib.position.x), "y": _y(ib.end.y), "w": _cm(ib.size.x), "h": _cm(ib.size.y)})
		Item.STROKE:
			var pts := it.pts_2d()
			var eps := 0.002
			var simple := Geom2D.rdp(pts, eps) if pts.size() > 2 else pts
			while simple.size() > MAX_POINTS:
				eps *= 1.6
				simple = Geom2D.rdp(pts, eps)
			row.merge({"type": "stroke", "brush": it.brush, "color": col, "width_mm": snappedf(it.width * 1000.0, 0.1), "points": _points(simple)})
		Item.SHAPE:
			if it.is_line():
				row["type"] = it.shape
				var path := Shapes.line_points(it)
				row.merge({"x1": _x(it.a.x), "y1": _y(it.a.y), "x2": _x(it.b.x), "y2": _y(it.b.y)})
				if path.size() > 2:
					row["route"] = _points(path)
				if not it.glue_a.is_empty() and short.has(str(it.glue_a.get("item", ""))):
					row["from"] = short[str(it.glue_a.item)]
				if not it.glue_b.is_empty() and short.has(str(it.glue_b.get("item", ""))):
					row["to"] = short[str(it.glue_b.item)]
				if it.head_a and it.shape == "line":
					row["arrow_at_start"] = true
				if it.head_b and it.shape == "line":
					row["arrow_at_end"] = true
				row["color"] = col
			elif it.shape == "poly":
				row.merge({"type": "polygon", "points": _points(it.poly), "color": col})
				if it.fill.a > 0.02:
					row["fill"] = _hex(it.fill)
			else:
				var half := it.size * 0.5
				row.merge({"type": "shape", "shape": it.shape, "kind": Shapes.name_of(it.shape),
					"x": _x(it.center.x - half.x), "y": _y(it.center.y + half.y), "w": _cm(it.size.x), "h": _cm(it.size.y)})
				if absf(it.rot) > 0.01:
					row["rotation_deg"] = snappedf(rad_to_deg(it.rot), 1.0)
				if it.label != "":
					row["label"] = it.label
				row["color"] = col
				if it.fill.a > 0.02:
					row["fill"] = _hex(it.fill)
	return row


func _points(pts: PackedVector2Array) -> Array:
	var out: Array = []
	for p in pts:
		out.append([_x(p.x), _y(p.y)])
	return out


static func _hex(c: Color) -> String:
	return "#" + c.to_html(c.a < 0.99)


static func _cm(m: float) -> float:
	return snappedf(m * 100.0, 0.1)


func _x(m: float) -> float:
	return snappedf((m - area.position.x) * 100.0, 0.1)


func _y(m: float) -> float:
	return snappedf((area.end.y - m) * 100.0, 0.1)


## A point given in the brief's centimetres (y down) in the canvas's metres (y up).
func to_frame(x: float, y: float) -> Vector2:
	return Vector2(area.position.x + x / 100.0, area.end.y - y / 100.0)


## The canvas as a PNG of at most PICTURE_PX pixels a side, covering exactly the described area. Text is not drawn (the SVG renderer
## has no fonts): it is in the JSON.
static func picture(doc: Document, fid: String, dark_look: bool) -> PackedByteArray:
	var svg := SvgExport.canvas(doc, fid, {"background": "dark" if dark_look else "white", "margin": MARGIN})
	var m := RegEx.create_from_string(r'width="([0-9.]+)mm" height="([0-9.]+)mm"').search(svg)
	if m == null:
		return PackedByteArray()
	var w := float(m.get_string(1))
	var h := float(m.get_string(2))
	var k := float(PICTURE_PX) / maxf(maxf(w, h), 1.0)
	svg = svg.replace(m.get_string(0), 'width="%d" height="%d"' % [maxi(int(w * k), 1), maxi(int(h * k), 1)])
	var img := Image.new()
	if img.load_svg_from_string(svg, 1.0) != OK:
		return PackedByteArray()
	return img.save_png_to_buffer()
