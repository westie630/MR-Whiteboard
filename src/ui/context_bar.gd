class_name ContextBar
extends FloatPanel
## The bar above the selection, on the canvas. It offers what fits what is selected:
##   everything    recolour, duplicate, to the front, to the back
##   text          its style (H1 .. Small), bold, italic, weight, edit; other readings of converted handwriting, back to the ink
##   ink strokes   to text
##   closed shapes a label, filled or not
## Undo, redo and delete stay the round buttons beside the selection box (they also work right after a delete).

const LIFT := 0.1                          # metres above the selection box (clear of its turning handle)

var _row: HBoxContainer
var _extra: VBoxContainer
var _sig := ""
var _palette_open := false
var _weight_chip: Btn


func _init() -> void:
	super()
	id = "context"
	kind = "canvas"
	pivot = Vector2(0.5, 1.0)
	max_size = Vector2(900, 260)
	add_theme_stylebox_override("panel", UITheme.glass(30, 6.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 2)
	v.add_child(_row)
	_extra = VBoxContainer.new()
	_extra.add_theme_constant_override("separation", 6)
	v.add_child(_extra)


## Where it goes: above the middle of the selection box.
func place_for(board: Board) -> bool:
	var items := board.selected_items()
	if items.is_empty() or board.sel_frame == "" or not board.frame_nodes.has(board.sel_frame):
		return false
	var fn: FrameNode = board.frame_nodes[board.sel_frame]
	if not fn.is_canvas:
		return false
	var r := board.pen_ctl.group_bounds(items)
	anchor = {"frame": board.sel_frame, "pos": Vector2(r.get_center().x, r.end.y + LIFT / fn.data.scale), "lift": 0.012}
	return true


func refresh() -> void:
	var b: Board = shell.board
	var items := b.selected_items()
	var kinds := {}
	for it in items:
		var item: Item = it
		kinds[_kind_of(item)] = true
	var one: Item = items[0] if items.size() == 1 else null
	var sig := "%s|%s|%s|%s" % [",".join(PackedStringArray(b.selection)), ",".join(PackedStringArray(kinds.keys())), _palette_open,
		(one.text + "/" + ",".join(one.alternatives) + str(one.ink.size())) if one != null and one.kind == Item.TEXT else ""]
	if sig != _sig:
		_sig = sig
		_rebuild(items, kinds, one)
	_kit.sync()


func reset() -> void:
	_palette_open = false
	_sig = ""


func _kind_of(item: Item) -> String:
	if item.kind == Item.TEXT:
		return "text"
	if item.kind == Item.STROKE:
		return "stroke"
	if item.kind == Item.SHAPE and not item.is_line():
		return "shape"
	return "line"


func _rebuild(items: Array, kinds: Dictionary, one: Item) -> void:
	_kit = UiKit.new()
	UiKit.clear(_row)
	UiKit.clear(_extra)
	_weight_chip = null
	var b: Board = shell.board
	if items.is_empty():
		return
	# recolour
	var col := (items[0] as Item).color
	var sw := Btn.new("", "", true)
	sw.variant = "tool"
	sw.swatch = Color(col.r, col.g, col.b, 1.0)
	sw.hint = "Colour"
	sw.custom_minimum_size = Vector2(46, 46)
	sw.on = _palette_open
	sw.toggled.connect(func(v: bool):
		_palette_open = v
		refresh())
	_row.add_child(sw)
	UiKit.divider(_row)
	var only := kinds.keys()
	if only.size() == 1 and only[0] == "text":
		_text_tools(items, one)
		UiKit.divider(_row)
	elif kinds.has("stroke"):
		_row.add_child(_action("aa", "To text", func(): b.ink.convert_ink(b.selected_items()), true))
		UiKit.divider(_row)
	if only.size() == 1 and only[0] == "shape" and items.size() == 1:
		_row.add_child(_tool("text", "Label", func(): shell.open_text_entry()))
		var fill := _tool("shapes", "Filled", func(): b.toggle_fill_selection())
		fill.on = (items[0] as Item).fill.a > 0.0
		_row.add_child(fill)
		UiKit.divider(_row)
	if _row.get_child_count() > 0 and not (_row.get_child(_row.get_child_count() - 1) is ColorRect):
		UiKit.divider(_row)
	_row.add_child(_tool("copy", "Duplicate", func(): b.duplicate_selection()))
	_row.add_child(_tool("front", "To the front", func(): b.bring_to_front()))
	_row.add_child(_tool("back", "To the back", func(): b.send_to_back()))
	if _palette_open:
		var pal := HBoxContainer.new()
		pal.add_theme_constant_override("separation", 2)
		pal.alignment = BoxContainer.ALIGNMENT_CENTER
		_extra.add_child(pal)
		for hex in UITheme.PALETTE:
			var c := Color(hex)
			var s := Btn.new("", "")
			s.variant = "tool"
			s.swatch = c
			s.custom_minimum_size = Vector2(40, 40)
			s.on = c.is_equal_approx(Color(col.r, col.g, col.b, 1.0))
			s.pressed.connect(func():
				b.recolor_selection(c)
				shell.set_color(c, false))
			pal.add_child(s)
	if one != null and one.kind == Item.TEXT and (not one.alternatives.is_empty() or not one.ink.is_empty()):
		_readings(one)


func _text_tools(items: Array, _one: Item) -> void:
	var b: Board = shell.board
	var styles := HBoxContainer.new()
	styles.add_theme_constant_override("separation", 2)
	_row.add_child(styles)
	var sbtns: Array = []
	for st in TextLayout.STYLES:
		var sid: String = st[0]
		var short: String = {"h1": "H1", "h2": "H2", "h3": "H3", "body": "Body", "small": "Small"}[sid]
		var c := UiKit.chip(short, func(): b.texts.apply_style(sid), "", 42.0)
		c.variant = "ghost"
		c.font_weight = 600
		c.hint = str(st[1])
		styles.add_child(c)
		sbtns.append([sid, c])
	_kit.syncers.append(func():
		var texts := b.texts.selected_texts()
		for pair in sbtns:
			(pair[1] as Btn).on = texts.all(func(t): return TextLayout.style_id((t as Item).font_size, (t as Item).weight) == pair[0]))
	UiKit.divider(_row)
	var bold := _tool("bold", "Bold", func():
		var heavy := b.texts.selected_texts().all(func(t): return (t as Item).weight >= 600)
		b.texts.set_style(400 if heavy else 700, null))
	_row.add_child(bold)
	var ital := _tool("italic", "Italic", func():
		var all_it := b.texts.selected_texts().all(func(t): return (t as Item).italic)
		b.texts.set_style(null, not all_it))
	_row.add_child(ital)
	_weight_chip = UiKit.chip("Regular", func():
		var texts := b.texts.selected_texts()
		if texts.is_empty():
			return
		var cur := (texts[0] as Item).weight
		var ws: Array = TextLayout.WEIGHTS.map(func(w): return int(w[0]))
		var i := ws.find(cur)
		b.texts.set_style(ws[(i + 1) % ws.size()] if i >= 0 else 400, null), "", 42.0)
	_weight_chip.variant = "ghost"
	_weight_chip.hint = "Weight: tap for the next one"
	_weight_chip.custom_minimum_size.x = 104
	_row.add_child(_weight_chip)
	_row.add_child(_tool("keyboard", "Edit the words", func(): shell.open_text_entry()))
	_kit.syncers.append(func():
		var texts := b.texts.selected_texts()
		if texts.is_empty():
			return
		bold.on = texts.all(func(t): return (t as Item).weight >= 600)
		ital.on = texts.all(func(t): return (t as Item).italic)
		var w := (texts[0] as Item).weight
		for x in TextLayout.WEIGHTS:
			if int(x[0]) == w:
				_weight_chip.text = str(x[1]))


## Converted handwriting: the recogniser's other readings, one tap each, and the way back to the ink.
func _readings(it: Item) -> void:
	var b: Board = shell.board
	var f := UiKit.flow(_extra, 6)
	var id := it.id
	for reading in it.alternatives.slice(0, 4):
		var r: String = reading
		f.add_child(UiKit.chip(r, func(): b.ink.choose_alternative(id, r)))
	if not it.ink.is_empty():
		var back := UiKit.chip("Handwriting", func(): b.ink.revert_to_ink(id), "undo")
		back.variant = "ghost"
		f.add_child(back)


func _tool(icon: String, hint: String, cb: Callable) -> Btn:
	return UiKit.tool(icon, hint, cb, 46.0)


func _action(icon: String, text: String, cb: Callable, strong: bool = false) -> Btn:
	var b := UiKit.chip(text, cb, icon, 42.0)
	b.variant = "ghost"
	b.on = strong
	return b
