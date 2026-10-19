extends Node
## The three export formats on the demo document: SVG (rendered back to pixels to check orientation and content), glTF (re-imported
## and its meshes counted) and the document file (reloaded and compared).

func _ready() -> void:
	var t := TestCase.new("export")
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_export"
	var doc := DemoDoc.build()
	doc.name = "Export test"
	var canvas_id := ""
	for f in doc.frames.values():
		if (f as FrameData).kind == FrameData.CANVAS:
			canvas_id = (f as FrameData).id

	# SVG
	var svg_res := Exporter.svg(doc, {"background": "white"})
	t.check(svg_res.ok, "svg export reports success: %s" % svg_res.message)
	t.eq((svg_res.paths as PackedStringArray).size(), 1, "one svg file for the one canvas")
	var svg_text := SvgExport.canvas(doc, canvas_id, {"background": "white", "margin": 0.05})
	t.check(svg_text.contains("<path") and svg_text.contains("<text") and svg_text.contains("<polygon"), "svg has paths, text and arrow heads")
	t.check(svg_text.contains(">Load data<") and svg_text.contains(">Hello, mixed reality!<"), "svg carries the text as text")
	var img := Image.new()
	t.eq(img.load_svg_from_string(svg_text, 0.4), OK, "the svg renders")
	if img.get_width() > 0:
		# the title text is drawn at the top of the canvas, the brush samples lower down: ink must exist in both halves, none in a corner margin
		var dark_top := _ink_pixels(img, Rect2i(0, 0, img.get_width(), img.get_height() / 2))
		var dark_bottom := _ink_pixels(img, Rect2i(0, img.get_height() / 2, img.get_width(), img.get_height() / 2))
		t.check(dark_top > 200 and dark_bottom > 200, "both halves of the drawing have ink (top %d, bottom %d)" % [dark_top, dark_bottom])
		var corner := _ink_pixels(img, Rect2i(0, 0, 8, 8))
		t.eq(corner, 0, "the margin around the drawing is empty")
		# orientation: the flow diagram's top row (y up in the app) must be above the brush samples
		var top_rows := _first_ink_row(img)
		t.check(top_rows < img.get_height() / 3, "the top of the drawing is at the top of the image (row %d of %d)" % [top_rows, img.get_height()])

	# glTF
	var glb_res := Exporter.glb(doc)
	t.check(glb_res.ok, "glb export reports success: %s" % glb_res.message)
	if glb_res.ok:
		var path: String = glb_res.paths[0]
		t.check(FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path).size() > 2000, "the glb file exists and is not empty")
		var state := GLTFState.new()
		var gd := GLTFDocument.new()
		t.eq(gd.append_from_file(path, state), OK, "the glb loads back")
		var scene := gd.generate_scene(state)
		var meshes := scene.find_children("*", "MeshInstance3D", true, false)
		t.check(meshes.size() >= 20, "the glb holds the ink as meshes (%d)" % meshes.size())
		scene.free()

	# document file
	var mrw := Exporter.document(doc)
	t.check(mrw.ok, "document export reports success")
	var back := Document.load_file(mrw.paths[0])
	t.check(back != null and back.items.size() == doc.items.size() and back.frames.size() == doc.frames.size(), "the exported .mrw loads back with every item and frame")

	for p in (svg_res.paths as PackedStringArray):
		DirAccess.remove_absolute(p)
	get_tree().quit(t.done())


func _ink_pixels(img: Image, r: Rect2i) -> int:
	var n := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and (c.r < 0.85 or c.g < 0.85 or c.b < 0.85):
				n += 1
	return n


func _first_ink_row(img: Image) -> int:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and (c.r < 0.85 or c.g < 0.85 or c.b < 0.85):
				return y
	return img.get_height()
