class_name DemoDoc
extends RefCounted
## A small demo document (flow diagram, every brush, text, shapes) used by the render check and for trying the app out.


static func build() -> Document:
	var doc := Document.create("Demo")
	var room := doc.add_room("Studio")
	var canvas := FrameData.make(FrameData.CANVAS, room.id, Transform3D(Basis.IDENTITY, Vector3(0, 1.3, -1.2)))
	canvas.size = Vector2(1.8, 1.1)
	doc.add_frame(canvas)

	var col := Color("#ffd166")
	# flow diagram
	var start := _box(doc, canvas, "rrect", Vector2(-0.62, 0.32), Vector2(0.26, 0.11), "Start", Color("#3fe0c8"), Color(0.25, 0.9, 0.8, 0.18))
	var proc := _box(doc, canvas, "rect", Vector2(-0.2, 0.32), Vector2(0.26, 0.13), "Load data", col, Color(1, 0.8, 0.3, 0.16))
	var dec := _box(doc, canvas, "diamond", Vector2(0.28, 0.32), Vector2(0.30, 0.2), "OK?", Color("#ef476f"), Color(0.94, 0.28, 0.44, 0.16))
	var done := _box(doc, canvas, "rrect", Vector2(0.72, 0.32), Vector2(0.24, 0.11), "Done", Color("#3fe0c8"), Color(0.25, 0.9, 0.8, 0.18))
	var fix := _box(doc, canvas, "rect", Vector2(0.28, 0.02), Vector2(0.26, 0.12), "Fix", col, Color(1, 0.8, 0.3, 0.16))
	_conn(doc, canvas, start, 1, proc, 3, "arrow")
	_conn(doc, canvas, proc, 1, dec, 3, "arrow")
	_conn(doc, canvas, dec, 1, done, 3, "arrow")
	_conn(doc, canvas, dec, 2, fix, 0, "arrow")
	_conn(doc, canvas, fix, 3, proc, 2, "elbow")

	# one wavy stroke per brush
	var y := -0.12
	for b in Brushes.LIST:
		var pts := PackedFloat32Array()
		for i in 60:
			var x := -0.75 + float(i) * 0.0045
			pts.append_array(PackedFloat32Array([x, y + sin(float(i) * 0.25) * 0.018, 0.0, 0.25 + 0.75 * sin(float(i) / 59.0 * PI)]))
		doc.add_item(Item.make_stroke(canvas.id, pts, Color.from_hsv(float(Brushes.LIST.find(b)) / 8.0, 0.55, 1.0), 0.004, b.id))
		var label := Item.make_text(canvas.id, b.name, Color(0.9, 0.95, 1.0), 0.026)
		label.center = Vector2(-0.38, y + 0.005) + Vector2(label.size.x * 0.5, 0)
		doc.add_item(label)
		y -= 0.075

	var t := Item.make_text(canvas.id, "Hello, mixed reality!", Color.WHITE, 0.07)
	t.center = Vector2(0.0, 0.52)
	doc.add_item(t)
	for row in 2:
		for i in TextLayout.WEIGHTS.size():
			var w: Array = TextLayout.WEIGHTS[i]
			var sample := Item.make_text(canvas.id, str(w[1]), Color(0.9, 0.95, 1.0), 0.032)
			sample.weight = int(w[0])
			sample.italic = row == 1
			sample.refit_text()
			sample.center = Vector2(-0.6 + float(i) * 0.24, 0.68 - float(row) * 0.05)
			doc.add_item(sample)
	var cyl := Item.make_shape(canvas.id, "cyl", Color("#8ecae6"), 0.004)
	cyl.center = Vector2(0.62, -0.25)
	cyl.fill = Color(0.55, 0.8, 0.9, 0.2)
	cyl.label = "DB"
	doc.add_item(cyl)
	var hx := Item.make_shape(canvas.id, "hex", Color("#c77dff"), 0.004)
	hx.center = Vector2(0.28, -0.3)
	hx.rot = 0.2
	hx.fill = Color(0.78, 0.49, 1.0, 0.2)
	doc.add_item(hx)
	var st := Item.make_shape(canvas.id, "star", Color("#ffd166"), 0.004)
	st.center = Vector2(-0.7, 0.05)
	st.size = Vector2(0.12, 0.12)
	doc.add_item(st)

	return doc


static func _box(doc: Document, f: FrameData, shape: String, c: Vector2, size: Vector2, label: String, col: Color, fill: Color) -> Item:
	var it := Item.make_shape(f.id, shape, col, 0.004)
	it.center = c
	it.size = size
	it.label = label
	it.fill = fill
	doc.add_item(it)
	return it


static func _conn(doc: Document, f: FrameData, a: Item, pa: int, b: Item, pb: int, kind: String) -> Item:
	var c := Item.make_shape(f.id, kind, Color(0.9, 0.95, 1.0), 0.003)
	var A := Shapes.port_world(a, pa)
	var B := Shapes.port_world(b, pb)
	c.a = A.pos
	c.b = B.pos
	c.na = A.n
	c.nb = B.n
	c.glue_a = {"item": a.id, "port": pa}
	c.glue_b = {"item": b.id, "port": pb}
	c.head_b = true
	doc.add_item(c)
	return c
