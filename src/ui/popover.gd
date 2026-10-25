class_name Popover
extends FloatPanel
## The options of one dock button, opened above it: Brush (brush, colour, width, snapping), Shapes (stencils and their style),
## Write (handwriting), Dictate (speech to text, then the placement tool) and Add (text, a new canvas). One is open at a time; drawing on a canvas closes it.

const W := 540.0
const SIZES := [["S", "Small", Vector2(0.6, 0.4)], ["M", "Medium", Vector2(1.2, 0.8)], ["L", "Large", Vector2(2.4, 1.6)]]
const TILE_H := 80.0
const SHORT := {"darrow": "Two-way", "elbow": "Elbow", "rarrow": "Block arrow"}

var mode := ""
var _body: VBoxContainer
var _title: Label
var _picker: HsvPicker
var _preview: StrokePreview


func _init() -> void:
	super()
	id = "popover"
	kind = "popover"
	pivot = Vector2(0.5, 1.0)
	max_size = Vector2(W + 40, 720)
	add_theme_stylebox_override("panel", UITheme.glass(24, 18.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.custom_minimum_size = Vector2(W, 0)
	add_child(v)
	_title = UiKit.label("", false, UITheme.FONT, 600)
	v.add_child(_title)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 12)
	v.add_child(_body)


func open(what: String) -> void:
	mode = what
	_kit = UiKit.new()
	UiKit.clear(_body)
	_picker = null
	_preview = null
	match what:
		"brush":
			_title.text = "Brush"
			_build_brush(_body)
		"shapes":
			_title.text = "Shapes"
			_build_shapes(_body)
		"write":
			_title.text = "Handwriting"
			_build_write(_body)
		"dictate":
			_title.text = "Dictate text"
			_build_dictate(_body)
		"add":
			_title.text = "Add"
			_build_add(_body)
	refresh()
	size = Vector2.ZERO


func refresh() -> void:
	_kit.sync()
	if _preview != null:
		_preview.queue_redraw()


## The little arrow under the card, pointing at the dock button it came from.
func _draw() -> void:
	var x := clampf(source_x, 30.0, size.x - 30.0)
	var y := size.y - 1.0
	var tri := PackedVector2Array([Vector2(x - 12, y), Vector2(x + 12, y), Vector2(x, y + 11)])
	draw_colored_polygon(tri, UITheme.GLASS)
	draw_polyline(PackedVector2Array([tri[0], tri[2], tri[1]]), UITheme.GLASS_EDGE, 1.0, true)


# ------------------------------------------------------------------------------------------------ brush

func _build_brush(p: VBoxContainer) -> void:
	_preview = StrokePreview.new()
	p.add_child(_preview)
	var brushes := UiKit.hrow(p, 4)
	brushes.alignment = BoxContainer.ALIGNMENT_CENTER
	var bbtns: Array = []
	for br in Brushes.LIST:
		var bid: String = br.id
		var b := UiKit.tool(bid, str(br.name), func():
			App.put("brush", bid)
			if str(App.val("tool")) not in ["draw"]:
				App.put("tool", "draw"), 62.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		brushes.add_child(b)
		bbtns.append([bid, b])
	_kit.syncers.append(func():
		for pair in bbtns:
			var on: bool = App.val("brush") == pair[0]
			(pair[1] as Btn).on = on
			(pair[1] as Btn).tint = App.val("color") if on else Color(0, 0, 0, 0))
	# colours: the palette and a custom one
	var sw := GridContainer.new()
	sw.columns = 8
	sw.add_theme_constant_override("h_separation", 6)
	sw.add_theme_constant_override("v_separation", 6)
	p.add_child(sw)
	var sbtns: Array = []
	for hex in UITheme.PALETTE:
		var c := Color(hex)
		var b2 := Btn.new("", "")
		b2.variant = "tool"
		b2.swatch = c
		b2.custom_minimum_size = Vector2(0, 58)
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b2.pressed.connect(func(): shell.set_color(c))
		sw.add_child(b2)
		sbtns.append([c, b2])
	var more := Btn.new("palette", "", true)
	more.variant = "tool"
	more.hint = "Any colour"
	more.custom_minimum_size = Vector2(0, 58)
	more.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sw.add_child(more)
	_picker = HsvPicker.new()
	_picker.visible = false
	_picker.custom_minimum_size = Vector2(0, 190)
	_picker.color_changed.connect(func(c: Color): shell.set_color(c))
	p.add_child(_picker)
	more.toggled.connect(func(v: bool):
		_picker.visible = v
		if v:
			_picker.set_color(App.val("color")))
	_kit.syncers.append(func():
		var cur: Color = App.val("color")
		var any := false
		for pair in sbtns:
			var hit := (pair[0] as Color).is_equal_approx(cur)
			(pair[1] as Btn).on = hit
			any = any or hit
		more.on = _picker.visible
		more.tint = cur if not any else Color(0, 0, 0, 0))
	_kit.slider(p, "Width", 0.001, 0.04, "width", 0.0005, func(v: float): return "%.1f mm" % (v * 1000.0))
	UiKit.header(p, "Snap to clean shapes")
	_kit.segmented(p, [["off", "Off"], ["hold", "Hold still"], ["auto", "Always"]], func(): return App.val("recognize"), func(v): App.put("recognize", v))


# ------------------------------------------------------------------------------------------------ shapes

func _build_shapes(p: VBoxContainer) -> void:
	for g in [["flow", "Flow diagram"], ["basic", "Basic"], ["line", "Lines and connectors"]]:
		UiKit.header(p, g[1])
		var grid := GridContainer.new()
		grid.columns = 6
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		p.add_child(grid)
		var btns: Array = []
		for s in Shapes.STENCILS:
			if s.group != g[0]:
				continue
			var sid: String = s.id
			var b := Btn.new(sid, str(SHORT.get(sid, s.name)))
			b.hint = str(s.name) if SHORT.has(sid) else ""
			b.small = true
			b.custom_minimum_size = Vector2(0, TILE_H)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(func(): shell.pick_stencil(sid))
			grid.add_child(b)
			btns.append([sid, b])
		_kit.syncers.append(func():
			for pair in btns:
				(pair[1] as Btn).on = shell.board.stencil == pair[0] and App.val("tool") == "shape")
	var c := UiKit.card(p, 6.0)
	_kit.switch(c, "Fill with colour", "fill")
	_kit.slider(c, "  Fill strength", 0.05, 0.9, "fill_alpha", 0.05, func(v: float): return "%d %%" % int(v * 100.0))
	_kit.switch(c, "Connectors stick to shapes", "snap_connectors")
	UiKit.note(p, "Pick a shape, then drag on a canvas to size it (tap for the default size).")


# ------------------------------------------------------------------------------------------------ write

func _build_write(p: VBoxContainer) -> void:
	UiKit.note(p, "Write words with the stylus and pause: they become text where you wrote. Lines, boxes and arrows you draw in between stay drawings.")
	UiKit.header(p, "Text style")
	_kit.segmented(p, [["h1", "H1"], ["h2", "H2"], ["h3", "H3"], ["body", "Body"], ["small", "Small"]], func(): return App.val("text_style"), func(v): App.put("text_style", v))
	var c := UiKit.card(p, 6.0)
	_kit.switch(c, "Convert after a pause", "ink_auto")
	_kit.slider(c, "  Pause", 1.0, 5.0, "ink_pause", 0.25, func(v: float): return "%.1f s" % v)
	var lang := UiKit.button("text", "", func():
		var i := 0
		for k in InkRecognizer.LANGUAGES.size():
			if InkRecognizer.LANGUAGES[k][0] == App.val("ink_language"):
				i = k
		App.put("ink_language", InkRecognizer.LANGUAGES[(i + 1) % InkRecognizer.LANGUAGES.size()][0]), 48.0, "ghost")
	c.add_child(lang)
	_kit.syncers.append(func():
		for l in InkRecognizer.LANGUAGES:
			if l[0] == App.val("ink_language"):
				lang.text = "Language: %s" % l[1])
	UiKit.header(p, "Writing with the pen tool")
	_kit.segmented(p, [["suggest", "Offer to convert"], ["auto", "Convert"], ["off", "Off"]], func(): return App.val("smart_ink"), func(v): App.put("smart_ink", v))
	UiKit.note(p, "The pen notices words and offers to turn them into text; drawings are left alone.")


# ------------------------------------------------------------------------------------------------ dictate

## One Dictate button: speak, pause, and the words wait as a ghost on the canvas you point at (Board.begin_place_text). The card stays
## open until the dock's Dictate is tapped again or something else is picked; while words are waiting it holds their preview and the
## ways to put them down or throw them away.
func _build_dictate(p: VBoxContainer) -> void:
	UiKit.note(p, "Tap Dictate, speak and pause. The words follow your stylus or hand over the canvases: tap with the stylus tip or pinch to put them down.")
	var mic := UiKit.button("mic", "Dictate", func(): shell.board.speech.toggle(func(t: String): shell.board.begin_place_text(t, TextController.WRAP_CHARS)), 88.0)
	p.add_child(mic)
	UiKit.header(p, "Text style")
	_kit.segmented(p, [["h1", "H1"], ["h2", "H2"], ["h3", "H3"], ["body", "Body"], ["small", "Small"]], func(): return App.val("text_style"), func(v): App.put("text_style", v))
	var wait := UiKit.vcol(p, 8)
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", UITheme.box(UITheme.WELL, 16))
	wait.add_child(well)
	var preview := UiKit.label("", false, UITheme.FONT_SMALL)
	preview.custom_minimum_size = Vector2(W - 60.0, 0)
	well.add_child(preview)
	var where := UiKit.label("", true, UITheme.FONT_TINY)
	wait.add_child(where)
	var row := UiKit.hrow(wait, 8)
	var here := UiKit.chip("Where I look", func(): shell.board.place_text_here(), "eye", 52.0)
	here.accent = UITheme.AI
	here.on = true
	here.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(here)
	var no := UiKit.chip("Cancel", func(): shell.board.cancel_place_text(), "close", 52.0)
	no.variant = "ghost"
	no.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(no)
	_kit.syncers.append(func():
		var b: Board = shell.board
		mic.on = b.speech.listening()
		mic.text = "Listening... tap to finish" if b.speech.listening() else ("Reading..." if b.speech.busy() else "Dictate")
		wait.visible = not b.placing_text.is_empty()
		if wait.visible:
			var text := str(b.placing_text.text)
			preview.text = text if text.length() <= 160 else text.left(160).strip_edges() + "..."
			var fd: FrameData = b.doc.frames.get(str(b.placing_text.frame)) if b.doc != null else null
			where.text = "Pointing at nothing yet" if fd == null else "Pointing at %s" % fd.name)


# ------------------------------------------------------------------------------------------------ add

func _build_add(p: VBoxContainer) -> void:
	var row := UiKit.hrow(p, 8)
	var t := UiKit.button("keyboard", "Type text", func():
		shell.close_popover()
		shell.open_text_entry(), 88.0)
	row.add_child(t)
	var rp := UiKit.hrow(p, 8)
	rp.add_child(UiKit.button("pdf", "PDF", func():
		shell.close_popover()
		shell.show_pdfs(), 64.0))
	UiKit.header(p, "New canvas")
	var r2 := UiKit.hrow(p, 8)
	r2.add_child(UiKit.button("canvas", "On a wall", func(): _place("wall"), 64.0))
	r2.add_child(UiKit.button("canvas", "On a table", func(): _place("table"), 64.0))
	var rd := UiKit.hrow(p, 8)
	var desk := UiKit.button("desk", "On my desk", func(): _find_desk(), 64.0)
	desk.accent = UITheme.DESK
	desk.tint = UITheme.DESK
	rd.add_child(desk)
	UiKit.note(p, "Press the stylus tip on your desk in a few places: the canvas then lies on it and can only slide, turn and scale along it.")
	var r3 := UiKit.hrow(p, 8)
	r3.add_child(UiKit.button("pin", "Bring the canvas to me", func():
		shell.close_popover()
		shell.board.bring_canvas_here(), 52.0, "ghost"))
	UiKit.note(p, "Size of a new canvas (it grows as you draw past its edge):")
	_kit.segmented(p, SIZES.map(func(s): return [SIZES.find(s), "%d × %d cm" % [int(s[2].x * 100), int(s[2].y * 100)]]),
		func(): return shell.canvas_size_idx, func(v): shell.canvas_size_idx = int(v), 40.0)


func _find_desk() -> void:
	shell.close_popover()
	shell.board.surface.begin("", SIZES[shell.canvas_size_idx][2])


func _place(where: String) -> void:
	shell.close_popover()
	shell.board.begin_place(where, SIZES[shell.canvas_size_idx][2])


## A sample stroke in the current brush, colour and width.
class StrokePreview extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(0, 74)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_style_box(UITheme.box(UITheme.WELL, 16), Rect2(Vector2.ZERO, size))
		var col: Color = App.val("color")
		var brush := str(App.val("brush"))
		var w := clampf(float(App.val("width")) * 1000.0 * 1.6, 1.5, 44.0)
		var pts := PackedVector2Array()
		var n := 64
		for i in n + 1:
			var t := float(i) / n
			pts.append(Vector2(lerpf(28.0, size.x - 28.0, t), size.y * 0.5 + sin(t * TAU * 1.5) * size.y * 0.2))
		match brush:
			"highlighter":
				draw_polyline(pts, Color(col.r, col.g, col.b, 0.4), w * 1.6, true)
			"marker":
				draw_polyline(pts, col, w * 1.3, true)
			"pencil":
				for k in 3:
					var off := Vector2(0, (k - 1) * w * 0.25)
					var p2 := PackedVector2Array()
					for q in pts:
						p2.append(q + off)
					draw_polyline(p2, Color(col.r, col.g, col.b, 0.5), maxf(w * 0.35, 1.0), true)
			"neon":
				draw_polyline(pts, Color(col.r, col.g, col.b, 0.18), w * 3.2, true)
				draw_polyline(pts, Color(col.r, col.g, col.b, 0.45), w * 1.8, true)
				draw_polyline(pts, Color(1, 1, 1, 0.95), maxf(w * 0.5, 1.2), true)
			"dashed":
				for i in range(0, n, 4):
					draw_line(pts[i], pts[mini(i + 2, n)], col, w, true)
			"spray":
				var rng := RandomNumberGenerator.new()
				rng.seed = 7
				for i in 420:
					var q := pts[rng.randi() % pts.size()]
					var a := rng.randf() * TAU
					var d := pow(rng.randf(), 0.6) * w * 1.1
					draw_circle(q + Vector2(cos(a), sin(a)) * d, 1.2, Color(col.r, col.g, col.b, 0.8))
			"calligraphy":
				for i in n:
					var dir := (pts[i + 1] - pts[i]).normalized()
					var k2 := absf(dir.cross(Vector2(0.7, -0.7)))
					draw_line(pts[i], pts[i + 1], col, maxf(w * (0.25 + k2 * 1.2), 1.0), true)
			_:
				draw_polyline(pts, col, w, true)
