extends Node
## SVG import: what comes in from a PC drawing (shapes, paths with curves and arcs, text, transforms, style sheets, <use>), what is
## counted as skipped, scaling to the canvas, bad input, and a round trip of the app's own export.

const SAMPLE := """<?xml version="1.0"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200mm" height="100mm" viewBox="0 0 200 100">
<title>Sample drawing</title>
<style>.red{fill:#ff0000;stroke:none}.thick{stroke:#0000ff;stroke-width:4;fill:none}</style>
<defs><g id="dot"><circle cx="0" cy="0" r="3" fill="green"/></g><linearGradient id="g1"><stop offset="0" stop-color="#00ff00"/><stop offset="1" stop-color="#000"/></linearGradient></defs>
<rect width="100%" height="100%" fill="#ffffff"/>
<rect x="10" y="10" width="40" height="20" class="red"/>
<circle cx="100" cy="50" r="20" fill="rgb(0,128,255)" stroke="black" stroke-width="2"/>
<path class="thick" d="M10 80 C 30 60, 50 100, 70 80 S 110 60 130 80 Q 150 100 170 80"/>
<path d="M150 20 a15 15 0 1 1 -30 0 a15 15 0 1 1 30 0 z" fill="#ffaa00"/>
<polygon points="170,10 190,10 180,30" fill="purple"/>
<line x1="10" y1="95" x2="190" y2="95" stroke="#333" stroke-width="1"/>
<g transform="translate(100 5) rotate(10)"><text x="0" y="0" font-size="8" text-anchor="middle" fill="#112233">Hello <tspan x="0" y="10">second line</tspan></text></g>
<use href="#dot" x="20" y="50"/>
<rect x="60" y="40" width="30" height="20" fill="url(#g1)"/>
<image href="data:image/png;base64,AAAA" width="10" height="10"/>
<rect x="0" y="0" width="5" height="5" fill="#00ffff" clip-path="url(#c)"/>
</svg>"""


func _ready() -> void:
	var t := TestCase.new("svg_import")
	var res := SvgImport.parse(SAMPLE, true)
	t.check(res.ok, "the sample imports: %s" % res.get("message", ""))
	var items: Array = res.get("items", [])
	var by_shape := {}
	var strokes := 0
	var texts: Array = []
	for it in items:
		var item: Item = it
		match item.kind:
			Item.STROKE:
				strokes += 1
			Item.TEXT:
				texts.append(item)
			Item.SHAPE:
				by_shape[item.shape] = int(by_shape.get(item.shape, 0)) + 1
	t.eq(res.title, "Sample drawing", "the title is read")
	t.check(res.background_removed, "the full-page white rectangle is taken as the background")
	t.eq(res.backing, "white", "a white page gives a white canvas backing")
	t.eq(by_shape.get("rect", 0), 3, "three parametric rectangles (red, gradient, clipped)")
	t.eq(by_shape.get("ellipse", 0), 2, "the circle and the used dot are parametric ellipses")
	t.check(by_shape.get("line", 0) == 1, "the line is a line")
	t.eq(by_shape.get("poly", 0), 2, "the arc ring and the polygon are polygons")
	t.eq(strokes, 1, "the open curve path is a stroke")
	t.eq(texts.size(), 1, "one text")
	t.eq(res.size, Vector2(0.2, 0.1), "kept at its real size, 200 x 100 mm is 20 x 10 cm")
	var scaled := SvgImport.parse(SAMPLE)
	t.near(scaled.size.x, 0.9, 0.001, "by default a small drawing (A4 is 30 cm) is enlarged to 90 cm to be editable in a room")
	t.near(scaled.size.x / scaled.size.y, 2.0, 0.001, "... keeping its proportions")
	var sk: Dictionary = res.skipped
	t.check(sk.has("images") and sk.has("clip paths / masks") and sk.has("gradients (one colour used)"), "what was left out is counted: %s" % SvgImport.skipped_text(sk))

	# details
	for it in items:
		var item: Item = it
		if item.kind == Item.SHAPE and item.shape == "rect" and item.fill.is_equal_approx(Color("#ff0000")):
			t.near(item.size.x, 0.04, 0.0005, "the red rectangle is 40 mm wide")
			t.near(item.size.y, 0.02, 0.0005, "... and 20 mm high")
			t.near(item.center.x, (30.0 - 100.0) * 0.001, 0.0005, "its centre is 70 mm left of the middle (x)")
			t.near(item.center.y, (50.0 - 20.0) * 0.001, 0.0005, "... and 30 mm above it (y is up)")
		if item.kind == Item.SHAPE and item.shape == "ellipse" and item.fill.is_equal_approx(Color(0.0, 128.0 / 255.0, 1.0)):
			t.near(item.size.x, 0.04, 0.0005, "the circle has a 40 mm diameter")
			t.check(item.color.is_equal_approx(Color.BLACK) and absf(item.width - 0.002) < 0.0003, "its outline is black and 2 mm")
		if item.kind == Item.STROKE:
			t.check(item.point_count() > 40, "the curved stroke is cut into many points (%d)" % item.point_count())
			t.check(item.color.is_equal_approx(Color("#0000ff")) and absf(item.width - 0.004) < 0.0004, "its colour and width come from the style sheet")
			var bb := Geom2D.bbox(item.pts_2d())
			t.near(bb.size.x, 0.160, 0.003, "the stroke spans 160 mm")
	var text: Item = texts[0]
	t.eq(text.text, "Hello\nsecond line", "the tspan starts a second line")
	t.near(text.font_size, 0.008, 0.0004, "font size 8 units = 8 mm")
	t.near(text.rot, -deg_to_rad(10.0), 0.01, "rotate(10) turns the text clockwise (frame y is up)")
	# the arc ring: two 15-radius half circles make a circle of 30 units
	var ring: Item = null
	for it in items:
		var item: Item = it
		if item.kind == Item.SHAPE and item.shape == "poly" and item.fill.is_equal_approx(Color("#ffaa00")):
			ring = item
	t.check(ring != null, "the arc path became a filled polygon")
	if ring != null:
		var rb := Geom2D.bbox(ring.poly)
		t.near(rb.size.x, 0.030, 0.0008, "the two arcs make a 30 mm circle (x)")
		t.near(rb.size.y, 0.030, 0.0008, "... (y)")
		t.check(ring.poly.size() > 24, "and it is round, not a hexagon (%d points)" % ring.poly.size())

	# scaling and sizes
	var tiny := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="20" fill="blue"/></svg>')
	t.check(tiny.ok and maxf(tiny.size.x, tiny.size.y) >= 0.899, "a tiny icon is enlarged to 90 cm (%s)" % str(tiny.get("size")))
	var huge := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" width="8000" height="4000"><rect x="100" y="100" width="500" height="500" fill="blue"/></svg>')
	t.check(huge.ok and maxf(huge.size.x, huge.size.y) <= 2.401, "a huge page is reduced to 2.4 m (%s)" % str(huge.get("size")))
	var nosize := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0 L100 50 L0 100" stroke="red" fill="none"/></svg>')
	t.check(nosize.ok and nosize.count == 1, "an SVG without size or viewBox still imports")
	var dark := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#101820"/><path d="M1 1L9 9" stroke="#ffffff"/></svg>')
	t.check(dark.ok and dark.backing == "dark" and dark.count == 1, "a dark page background gives a dark backing and is not drawn")
	var lightink := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="M1 1L9 9" stroke="#ffd166"/></svg>')
	t.eq(lightink.backing, "", "light ink keeps the default backing")

	# path syntax corner cases
	var p1 := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="m10,10h20v20h-20z m50 50l10-10 10 10" stroke="red" fill="none"/></svg>')
	t.check(p1.ok and p1.count == 2, "relative commands and two sub-paths give two items (%s)" % str(p1.get("count")))
	var p2 := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="M10 10a5 5 0 1010 0" stroke="red" fill="none"/></svg>')
	t.check(p2.ok and (p2.items[0] as Item).point_count() > 8, "arc flags written without separators are read")
	var p3 := SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="M1.5.5L10-5e1" stroke="red"/></svg>')
	t.check(p3.ok and (p3.items[0] as Item).point_count() == 2, "numbers like 1.5.5 and 10-5e1 are split correctly")

	# bad input
	t.check(not SvgImport.parse("this is not xml").ok, "text that is not XML is refused")
	t.check(not SvgImport.parse("<html><body/></html>").ok, "XML that is not SVG is refused")
	t.check(not SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>').ok, "an empty SVG is refused")
	t.check(not SvgImport.parse('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="M 5 5 L garbage"/></svg>').ok, "broken path data does not crash")
	var many := "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 1000'>"
	for i in 4300:
		many += "<rect x='%d' y='%d' width='3' height='3' fill='red'/>" % [i % 300 * 3, i / 300 * 3]
	many += "</svg>"
	var capped := SvgImport.parse(many)
	t.check(capped.ok and capped.count == SvgImport.MAX_ITEMS and capped.skipped.size() == 1, "more than %d shapes are cut off and reported" % SvgImport.MAX_ITEMS)

	# a round trip of the app's own export
	var doc := DemoDoc.build()
	var canvas_id := ""
	for f in doc.frames.values():
		if (f as FrameData).kind == FrameData.CANVAS:
			canvas_id = (f as FrameData).id
	var original := doc.items_of(canvas_id)
	var svg := SvgExport.canvas(doc, canvas_id, {"background": "white", "margin": 0.04})
	var back := SvgImport.parse(svg, true)
	t.check(back.ok, "the app's own SVG imports: %s" % back.get("message", ""))
	if back.ok:
		t.check(back.count >= original.size() * 0.8, "most of the %d original items come back (%d)" % [original.size(), back.count])
		var bb := Rect2()
		var first := true
		for it in back.items:
			var r: Rect2 = (it as Item).bounds()
			bb = r if first else bb.merge(r)
			first = false
		var ob := Rect2()
		first = true
		for it in original:
			var r2: Rect2 = (it as Item).bounds()
			ob = r2 if first else ob.merge(r2)
			first = false
		t.near(bb.size.x, ob.size.x, 0.08 * ob.size.x, "the drawing keeps its width (%.3f vs %.3f m)" % [bb.size.x, ob.size.x])
		t.near(bb.size.y, ob.size.y, 0.08 * ob.size.y, "... and its height (%.3f vs %.3f m)" % [bb.size.y, ob.size.y])
		var has_text := false
		for it in back.items:
			if (it as Item).kind == Item.TEXT and (it as Item).text == "Load data":
				has_text = true
		t.check(has_text, "text comes back as text")
		# put it on a canvas and check that the model accepts it (save, load)
		var d2 := Document.create("import check")
		var f2 := FrameData.make(FrameData.CANVAS, "", Transform3D.IDENTITY, "Imported")
		d2.add_frame(f2)
		for it in back.items:
			(it as Item).frame = f2.id
			d2.add_item(it)
		var loaded := Document.from_dict(d2.to_dict())
		t.eq(loaded.items.size(), back.count, "imported items survive save and load")
	get_tree().quit(t.done())
