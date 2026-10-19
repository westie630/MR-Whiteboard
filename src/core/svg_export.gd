class_name SvgExport
extends RefCounted
## Export of a canvas as SVG (scalable vector graphics): the editable, universal format for diagrams. Opens in Inkscape,
## Illustrator, Figma, PowerPoint and every browser. Units are millimetres (1 canvas metre = 1000 user units), y flipped to SVG's
## downward axis. Freehand strokes keep their pressure as variable-width outlines; shapes stay real vector paths; text stays text.
##
## Options: background ("none" | "white" | "dark"), grid (bool), margin (metres around the content).

const MM := 1000.0
const FONT := "'Open Sans', 'Segoe UI', Arial, Helvetica, sans-serif"


static func canvas(doc: Document, frame_id: String, opts: Dictionary = {}) -> String:
	var frame: FrameData = doc.frames.get(frame_id)
	var list := doc.items_of(frame_id)
	var margin := float(opts.get("margin", 0.04))
	var bb := Rect2()
	var first := true
	for it in list:
		var r: Rect2 = (it as Item).bounds()
		bb = r if first else bb.merge(r)
		first = false
	if first:
		var sz: Vector2 = frame.size if frame != null else Vector2(1.2, 0.8)
		bb = Rect2(-sz * 0.5, sz)
	bb = bb.grow(margin)
	var w := bb.size.x * MM
	var h := bb.size.y * MM
	var out := PackedStringArray()
	out.append('<?xml version="1.0" encoding="UTF-8"?>')
	out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%smm" height="%smm" viewBox="0 0 %s %s">' % [_n(w), _n(h), _n(w), _n(h)])
	out.append('<title>%s</title>' % _esc("%s - %s" % [doc.name, frame.name if frame != null else frame_id]))
	out.append('<desc>Exported from MR Whiteboard. 1 unit = 1 mm.</desc>')
	out.append('<defs><filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="2.2" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>')
	var bg := str(opts.get("background", "white"))
	if bg == "white":
		out.append('<rect width="100%" height="100%" fill="#ffffff"/>')
	elif bg == "dark":
		out.append('<rect width="100%" height="100%" fill="#14181f"/>')
	if bool(opts.get("grid", false)):
		out.append(_grid(bb, bg == "dark"))
	var tx := func(p: Vector2) -> Vector2: return Vector2((p.x - bb.position.x) * MM, (bb.end.y - p.y) * MM)
	for it in list:
		var item: Item = it
		match item.kind:
			Item.STROKE:
				out.append(_stroke(item, tx))
			Item.SHAPE:
				out.append(_shape(item, tx))
			Item.TEXT:
				out.append(_text(item.text, item.center, item.rot, item.font_size, item.color, tx))
	out.append('</svg>')
	return "\n".join(out)


## Write every canvas of a document as its own .svg file in a folder; returns the written paths.
static func export_document(doc: Document, folder: String, opts: Dictionary = {}) -> PackedStringArray:
	var written := PackedStringArray()
	DirAccess.make_dir_recursive_absolute(folder)
	var used := {}
	for f in doc.frames.values():
		var fr: FrameData = f
		if fr.kind != FrameData.CANVAS:
			continue
		var base := DocStore.safe_name(fr.name)
		var k := 2
		var fname := base
		while used.has(fname):
			fname = "%s %d" % [base, k]
			k += 1
		used[fname] = true
		var p := "%s/%s.svg" % [folder, fname]
		var file := FileAccess.open(p, FileAccess.WRITE)
		if file != null:
			file.store_string(canvas(doc, fr.id, opts))
			file.close()
			written.append(p)
	return written


# ------------------------------------------------------------------------------------------------ elements

static func _stroke(it: Item, tx: Callable) -> String:
	var b := Brushes.get_def(it.brush)
	var col := _hex(it.color)
	var op := float(b.alpha) * it.color.a
	var n := it.point_count()
	if n == 0:
		return ""
	var attrs := ' fill="%s" fill-opacity="%s"' % [col, _n(op, 3)]
	if it.brush == "highlighter":
		attrs += ' style="mix-blend-mode:multiply"'
	elif it.brush == "neon":
		attrs += ' filter="url(#glow)"'
	if it.brush == "dashed" and n > 1:
		var pts := PackedStringArray()
		for i in n:
			var p: Vector2 = tx.call(Vector2(it.pts[i * 4], it.pts[i * 4 + 1]))
			pts.append("%s,%s" % [_n(p.x), _n(p.y)])
		var w := Brushes.width_at(it.brush, it.width, 0.7) * MM
		return '<polyline points="%s" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="%s" stroke-linecap="butt" stroke-linejoin="round" stroke-dasharray="%s %s"/>' % [" ".join(pts), col, _n(op, 3), _n(w), _n(w * 3.0), _n(w * 2.0)]
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var centers := PackedVector2Array()
	var widths := PackedFloat32Array()
	for i in n:
		centers.append(Vector2(it.pts[i * 4], it.pts[i * 4 + 1]))
		widths.append(Brushes.width_at(it.brush, it.width, it.pressure(i)))
	if n == 1:
		var c: Vector2 = tx.call(centers[0])
		return '<circle cx="%s" cy="%s" r="%s"%s/>' % [_n(c.x), _n(c.y), _n(widths[0] * 0.5 * MM), attrs]
	for i in n:
		var d := (centers[mini(i + 1, n - 1)] - centers[maxi(i - 1, 0)]).normalized()
		var nrm := Vector2(-d.y, d.x) * widths[i] * 0.5
		left.append(centers[i] + nrm)
		right.append(centers[i] - nrm)
	var path := PackedStringArray()
	for i in n:
		var p: Vector2 = tx.call(left[i])
		path.append(("M" if i == 0 else "L") + "%s %s" % [_n(p.x), _n(p.y)])
	for i in range(n - 1, -1, -1):
		var p2: Vector2 = tx.call(right[i])
		path.append("L%s %s" % [_n(p2.x), _n(p2.y)])
	var s := '<path d="%sZ"%s/>' % ["".join(path), attrs]
	if b.get("caps", false):
		for i in [0, n - 1]:
			var c2: Vector2 = tx.call(centers[i])
			s += '<circle cx="%s" cy="%s" r="%s"%s/>' % [_n(c2.x), _n(c2.y), _n(widths[i] * 0.5 * MM), attrs]
	return s


static func _shape(it: Item, tx: Callable) -> String:
	var out := PackedStringArray()
	var stroke_col := _hex(it.color)
	var sw := it.width * MM
	var dash := ' stroke-dasharray="%s %s"' % [_n(sw * 3.0), _n(sw * 2.0)] if it.brush == "dashed" else ""
	var fill := 'fill="none"'
	if it.fill.a > 0.01 and not it.is_line():
		fill = 'fill="%s" fill-opacity="%s"' % [_hex(it.fill), _n(it.fill.a, 3)]
	if it.shape == "poly":
		out.append(_path(it.poly, true, tx, stroke_col, sw, fill, dash))
	else:
		for o in Shapes.world_outlines(it):
			out.append(_path(o.pts, o.closed, tx, stroke_col, sw, fill if o.closed else 'fill="none"', dash))
		if it.is_line():
			var pts := Shapes.line_points(it)
			if pts.size() >= 2:
				var n := pts.size()
				if it.shape == "arrow" or it.head_b or it.shape == "darrow" or it.shape == "elbow":
					out.append(_head(pts[n - 1], (pts[n - 1] - pts[n - 2]).normalized(), it, tx))
				if it.shape == "darrow" or it.head_a:
					out.append(_head(pts[0], (pts[0] - pts[1]).normalized(), it, tx))
	if it.label != "" and it.kind == Item.SHAPE and not it.is_line():
		var box := Shapes.label_box(it.shape, it.size)
		var em := minf(box.y * 0.5, TextLayout.fit_ink(it.label, Rect2(-box * 0.5, box)).em)
		em = minf(em, 0.05)
		out.append(_text(it.label, it.center, it.rot, em, it.color, tx))
	return "".join(out)


static func _path(pts: PackedVector2Array, closed: bool, tx: Callable, col: String, sw: float, fill: String, dash: String) -> String:
	if pts.size() < 2:
		return ""
	var d := PackedStringArray()
	for i in pts.size():
		var p: Vector2 = tx.call(pts[i])
		d.append(("M" if i == 0 else "L") + "%s %s" % [_n(p.x), _n(p.y)])
	return '<path d="%s%s" %s stroke="%s" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"%s/>' % ["".join(d), "Z" if closed else "", fill, col, _n(sw), dash]


static func _head(tip: Vector2, dir: Vector2, it: Item, tx: Callable) -> String:
	var tri := Shapes.arrow_head(tip, dir, it.width)
	var pts := PackedStringArray()
	for p in tri:
		var q: Vector2 = tx.call(p)
		pts.append("%s,%s" % [_n(q.x), _n(q.y)])
	return '<polygon points="%s" fill="%s" stroke="%s" stroke-width="%s" stroke-linejoin="round"/>' % [" ".join(pts), _hex(it.color), _hex(it.color), _n(it.width * MM * 0.5)]


static func _text(txt: String, center: Vector2, rot: float, em: float, col: Color, tx: Callable) -> String:
	var lines := txt.split("\n")
	var c: Vector2 = tx.call(center)
	var size := em * MM
	var total_h := size * 1.2 * lines.size()
	var y0 := c.y - total_h * 0.5 + size * 0.95
	var s := PackedStringArray()
	for i in lines.size():
		s.append('<tspan x="%s" y="%s">%s</tspan>' % [_n(c.x), _n(y0 + float(i) * size * 1.2), _esc(lines[i])])
	var tr := ' transform="rotate(%s %s %s)"' % [_n(-rad_to_deg(rot)), _n(c.x), _n(c.y)] if absf(rot) > 1e-4 else ""
	return '<text font-family="%s" font-size="%s" fill="%s" text-anchor="middle"%s>%s</text>' % [FONT, _n(size), _hex(col), tr, "".join(s)]


static func _grid(bb: Rect2, dark: bool) -> String:
	var step := 0.05
	var col := "#ffffff" if dark else "#000000"
	var s := PackedStringArray()
	s.append('<g stroke="%s" stroke-opacity="0.12" stroke-width="0.6">' % col)
	var x := ceilf(bb.position.x / step) * step
	while x <= bb.end.x:
		var px := (x - bb.position.x) * MM
		s.append('<line x1="%s" y1="0" x2="%s" y2="%s"/>' % [_n(px), _n(px), _n(bb.size.y * MM)])
		x += step
	var y := ceilf(bb.position.y / step) * step
	while y <= bb.end.y:
		var py := (bb.end.y - y) * MM
		s.append('<line x1="0" y1="%s" x2="%s" y2="%s"/>' % [_n(py), _n(bb.size.x * MM), _n(py)])
		y += step
	s.append('</g>')
	return "".join(s)


# ------------------------------------------------------------------------------------------------ formatting

static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


static func _n(v: float, digits: int = 2) -> String:
	var s := String.num(v, digits)
	return s


static func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
