extends Node
## Document model: items, save/load round trip, undo/redo, shapes and connectors, SVG export, document store.

func _ready() -> void:
	var t := TestCase.new("document")
	App.settings_path = "user://test_settings.cfg"
	App.reload()
	var doc := Document.create("Test doc")
	var room := doc.add_room("Office", "anchor-room-1", Transform3D(Basis.IDENTITY, Vector3(1, 0, 2)))
	var canvas := FrameData.make(FrameData.CANVAS, room.id, Transform3D(Basis.IDENTITY, Vector3(0, 1.2, -1)))
	doc.add_frame(canvas)
	canvas.anchor = "anchor-frame-1"
	var vol := FrameData.make(FrameData.VOLUME, room.id, Transform3D.IDENTITY)
	doc.add_frame(vol)
	t.eq(canvas.name, "Canvas 1", "first canvas is named")
	t.eq(vol.name, "3D sketch 1", "first volume is named")

	var pts := PackedFloat32Array()
	for i in 40:
		pts.append_array(PackedFloat32Array([float(i) * 0.005, sin(float(i) * 0.3) * 0.02, 0.0, 0.2 + float(i) / 80.0]))
	var stroke := Item.make_stroke(canvas.id, pts, Color("#ff5577"), 0.004, "pen")
	doc.add_item(stroke)
	var box := Item.make_shape(canvas.id, "rect", Color.WHITE, 0.003)
	box.center = Vector2(0.3, 0.1)
	box.size = Vector2(0.24, 0.14)
	box.fill = Color(0.2, 0.6, 1.0, 0.3)
	box.label = "Start"
	doc.add_item(box)
	var box2 := Item.make_shape(canvas.id, "diamond", Color.WHITE, 0.003)
	box2.center = Vector2(0.8, 0.1)
	doc.add_item(box2)
	var arrow := Item.make_shape(canvas.id, "arrow", Color.WHITE, 0.003)
	arrow.a = Vector2(0.42, 0.1)
	arrow.b = Vector2(0.68, 0.1)
	arrow.head_b = true
	arrow.glue_a = {"item": box.id, "port": 1}
	arrow.glue_b = {"item": box2.id, "port": 3}
	doc.add_item(arrow)
	var txt := Item.make_text(canvas.id, "Hello\nworld", Color.YELLOW, 0.05)
	txt.center = Vector2(0.2, 0.4)
	doc.add_item(txt)
	var air := Item.make_stroke(vol.id, PackedFloat32Array([0, 0, 0, 1, 0.1, 0.1, 0.05, 1, 0.2, 0.0, 0.1, 1]), Color.CYAN, 0.006, "neon")
	doc.add_item(air)
	t.check(txt.size.x > 0.05 and txt.size.y > 0.05, "text item is measured")
	t.eq(doc.items_of(canvas.id).size(), 5, "five items on the canvas")
	t.eq(doc.items_of(vol.id).size(), 1, "one stroke in the volume")

	# save / load round trip
	var path := "user://test_doc.mrw"
	t.eq(doc.save(path), OK, "document saves")
	var back := Document.load_file(path)
	t.check(back != null, "document loads")
	if back != null:
		t.eq(back.name, "Test doc", "name survives")
		t.eq(back.items.size(), doc.items.size(), "all items survive")
		t.eq(back.frames.size(), 2, "frames survive")
		t.eq(back.rooms.size(), 1, "room survives")
		t.eq(str(back.rooms[0].anchor), "anchor-room-1", "room anchor uuid survives")
		var bf: FrameData = back.frames[canvas.id]
		t.eq(bf.anchor, "anchor-frame-1", "frame anchor uuid survives")
		t.near(bf.xf.origin.y, 1.2, 1e-4, "frame pose survives")
		var bs: Item = back.items[stroke.id]
		t.eq(bs.point_count(), 40, "stroke point count survives")
		t.near(bs.pt(10).x, 0.05, 1e-5, "stroke geometry survives")
		t.near(bs.pressure(39), stroke.pressure(39), 1e-5, "pressure survives")
		t.eq((back.items[arrow.id] as Item).glue_b.get("port"), 3, "glue survives")
		t.eq((back.items[box.id] as Item).label, "Start", "label survives")
		t.eq((back.items[txt.id] as Item).text, "Hello\nworld", "text survives")
		t.near((back.items[box.id] as Item).fill.a, 0.3, 0.01, "fill alpha survives")

	# history
	var hist := History.new(doc)
	var extra := Item.make_shape(canvas.id, "ellipse", Color.GREEN, 0.003)
	hist.do(History.op_add([extra]))
	t.check(doc.items.has(extra.id), "add applies")
	t.check(hist.undo(), "undo works")
	t.check(not doc.items.has(extra.id), "undo removes the item")
	t.check(hist.redo(), "redo works")
	t.check(doc.items.has(extra.id), "redo restores the item")
	var before := extra.duplicate_item(false)
	extra.color = Color.RED
	var after := extra.duplicate_item(false)
	hist.do(History.op_modify([before], [after]))
	t.eq((doc.items[extra.id] as Item).color, Color.RED, "modify applies")
	hist.undo()
	t.eq((doc.items[extra.id] as Item).color, Color.GREEN, "undo restores the colour")
	var c0: Vector2 = (doc.items[box.id] as Item).center
	var mv := Transform2D(0.0, Vector2(0.1, -0.05))
	hist.do(History.op_xform2([box.id], mv))
	t.near(((doc.items[box.id] as Item).center - c0 - Vector2(0.1, -0.05)).length(), 0.0, 1e-6, "xform moves the shape")
	hist.undo()
	t.near(((doc.items[box.id] as Item).center - c0).length(), 0.0, 1e-6, "undo moves it back")
	hist.begin_group()
	hist.do(History.op_remove([extra]))
	hist.do(History.op_add([Item.make_shape(canvas.id, "hex", Color.WHITE, 0.003)]))
	hist.end_group()
	var n_before := doc.items.size()
	hist.undo()
	t.eq(doc.items.size(), n_before, "a group undoes as one step (one removed, one added)")
	t.check(doc.items.has(extra.id), "group undo restores the removed item")

	# shapes / connectors
	var ports := Shapes.ports("rect", Vector2(0.2, 0.1))
	t.near((ports[1].pos as Vector2).x, 0.1, 1e-4, "right port of a rect")
	t.near((ports[0].pos as Vector2).y, 0.05, 1e-4, "top port of a rect")
	var tri_ports := Shapes.ports("triangle", Vector2(0.2, 0.2))
	t.near((tri_ports[0].pos as Vector2).y, 0.1, 1e-4, "triangle apex is its top port")
	var elbow := Shapes.route_elbow(Vector2(0, 0), Vector2(0.3, 0.2), Vector2(1, 0), Vector2(0, -1))
	t.check(elbow.size() >= 3, "elbow route has bends")
	for i in range(elbow.size() - 1):
		var d := elbow[i + 1] - elbow[i]
		t.check(absf(d.x) < 1e-6 or absf(d.y) < 1e-6, "elbow segment %d is axis aligned" % i)
	for s in Shapes.STENCILS:
		if not Shapes.is_line(s.id):
			var poly := Shapes.fill_poly(s.id, Shapes.default_size(s.id))
			t.check(poly.size() >= 3, "%s has an outline" % s.id)
			t.check(Geom2D.polygon_area(poly) > 0.001, "%s has an area" % s.id)

	# containing shape (label target)
	var inside := doc.shape_containing(canvas.id, Vector2(0.3, 0.1))
	t.check(inside != null and inside.id == box.id, "shape_containing finds the box")

	# SVG export is well formed XML
	var svg := SvgExport.canvas(doc, canvas.id, {"background": "white", "grid": true})
	t.check(svg.begins_with("<?xml"), "svg has an XML header")
	var xml := XMLParser.new()
	t.eq(xml.open_buffer(svg.to_utf8_buffer()), OK, "svg opens in the XML parser")
	var tags := {}
	var guard := 0
	while xml.read() == OK and guard < 100000:
		guard += 1
		if xml.get_node_type() == XMLParser.NODE_ELEMENT:
			tags[xml.get_node_name()] = tags.get(xml.get_node_name(), 0) + 1
	t.check(tags.has("svg") and tags.has("path") and tags.has("text") and tags.has("polygon"), "svg holds paths, text and arrowheads: %s" % str(tags))
	var written := SvgExport.export_document(doc, "user://test_export")
	t.eq(written.size(), 1, "one svg per canvas is written")

	# document store
	var made := DocStore.create_new("Store test")
	var listed := DocStore.list()
	var found := false
	for s in listed:
		if s.id == made.id:
			found = true
	t.check(found, "new document is listed")
	var dup := DocStore.clone(made.id)
	t.check(dup != null and dup.id != made.id, "clone has a new id")
	DocStore.rename(made.id, "Renamed")
	t.eq(DocStore.open(made.id).name, "Renamed", "rename persists")
	DocStore.delete(made.id)
	if dup != null:
		DocStore.delete(dup.id)
	t.check(DocStore.open(made.id) == null, "delete removes the file")
	t.eq(DocStore.safe_name("a/b:c?"), "a_b_c_", "file names are made safe")

	# text fitting: the text takes the size of the ink
	var fit := TextLayout.fit_ink("Hello", Rect2(Vector2(0, 0), Vector2(0.4, 0.08)))
	t.check(fit.em > 0.04 and fit.em < 0.2, "text size is plausible: %f" % fit.em)
	var measured := TextLayout.measure("Hello", fit.em)
	t.check(absf(measured.x - 0.4) < 0.1, "fitted text is about as wide as the ink: %f" % measured.x)

	# Open Sans weights and italics
	t.check(TextLayout.font(700) != TextLayout.font(400) and TextLayout.font(400, true) != TextLayout.font(400), "each weight and style is its own font")
	t.check(TextLayout.font(700) == TextLayout.font(690), "weights snap to steps of 50 and share one font")
	t.check(TextLayout.font(100) == TextLayout.font(300) and TextLayout.font(1000) == TextLayout.font(800), "weights are limited to 300..800")
	t.check(TextLayout.measure("Weight", 0.1, 800).x > TextLayout.measure("Weight", 0.1, 300).x, "heavier text is wider")
	t.eq(TextLayout.style_id(0.09, 700), "h1", "a text of Heading 1 size and weight is Heading 1")
	t.eq(TextLayout.style_id(0.0905, 700), "", "a text scaled by hand is no longer in a style")
	var sizes_ok := true
	for i in TextLayout.STYLES.size() - 1:
		sizes_ok = sizes_ok and float(TextLayout.STYLES[i][2]) > float(TextLayout.STYLES[i + 1][2])
	t.check(sizes_ok, "the styles get smaller from Heading 1 to Small")
	var styled := Item.make_text("", "Styled", Color.WHITE, 0.05)
	var plain_w := styled.size.x
	styled.weight = 700
	styled.italic = true
	styled.refit_text()
	t.check(styled.size.x > plain_w, "bold text gets a wider box")
	var reloaded := Item.from_dict(styled.to_dict())
	t.check(reloaded.weight == 700 and reloaded.italic and absf(reloaded.size.x - styled.size.x) < 1e-4, "weight and italic survive save and load (%d %s %f vs %f)" % [reloaded.weight, reloaded.italic, reloaded.size.x, styled.size.x])
	var normal := Item.make_text("", "Plain", Color.WHITE, 0.05).to_dict()
	t.check(not normal.has("weight") and not normal.has("italic"), "regular upright text saves no style")
	var styled_svg := SvgExport._text("Styled", Vector2.ZERO, 0.0, 0.05, Color.WHITE, func(p): return p, 700, true)
	t.check(styled_svg.contains('font-weight="700"') and styled_svg.contains('font-style="italic"'), "the SVG export names weight and italic")
	var round := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><text x="5" y="20" font-size="8" font-weight="bold" font-style="italic">B</text><text x="5" y="40" font-size="8" font-weight="300">L</text><text x="5" y="48" font-size="8">N</text></svg>', true)
	var rt: Array = round.get("items", [])
	t.check(rt.size() == 3 and (rt[0] as Item).weight == 700 and (rt[0] as Item).italic, "bold italic SVG text imports as weight 700 italic")
	t.check(rt.size() == 3 and (rt[1] as Item).weight == 300 and not (rt[1] as Item).italic and (rt[2] as Item).weight == 400, "numeric and default SVG weights import")

	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_doc.mrw"))
	get_tree().quit(t.done())
