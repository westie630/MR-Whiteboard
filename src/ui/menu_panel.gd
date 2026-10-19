class_name MenuPanel
extends PanelContainer
## The whole interface in one panel: Draw, Shapes, Canvas, Docs, Rooms and More tabs, a selection strip and undo / redo.
## The same Control tree is docked on the screen on the PC and floats in the room (inside a SubViewport) in the headset.

const TABS := [["draw", "draw", "Draw"], ["shapes", "shapes", "Shapes"], ["canvas", "canvas", "Canvas"], ["docs", "doc", "Docs"], ["rooms", "room", "Rooms"], ["more", "settings", "More"]]
const TOOLS := [["draw", "draw", "Draw"], ["shape", "shapes", "Shapes"], ["write", "write", "Write"], ["select", "select", "Select"], ["erase", "erase", "Erase"]]
const SIZES := [["Small", Vector2(0.6, 0.4)], ["Medium", Vector2(1.2, 0.8)], ["Large", Vector2(2.4, 1.6)]]
const DESIGN_SIZE := Vector2(560, 800)

signal hide_requested()                   # the close button: the host hides the menu (palm up / Tab brings it back)

var board: Board
var design_size := DESIGN_SIZE
var canvas_size_idx := 1

var _tab := "draw"
var _tab_btns: Dictionary = {}
var _pages: Dictionary = {}
var _syncers: Array = []                  # state refreshers of the permanent widgets
var _dyn_syncers: Array = []              # ... of widgets that are rebuilt with their list (dropped on every rebuild)
var _target: Array = []                   # where _segmented() / _toggle() / _slider_row() register their refresher
var _sel_bar: Control
var _sel_label: Label
var _alt_box: HFlowContainer
var _alt_sig := ""
var _sel_text_btn: Btn
var _sel_convert_btn: Btn
var _sel_edit_btn: Btn
var _toast_label: Label
var _toast_t := 0.0
var _title: Label
var _status: Label
var _undo_btn: Btn
var _redo_btn: Btn
var _ink_btn: Btn
var _mic_btn: Btn
var _type_btn: Btn
var _token_edit: LineEdit
var _tabs_row: Control
var _holder: Control
var _bottom: Control
var _entry: TextEntry
var _entry_cb := Callable()
var _keyboard: VKeyboard
var _sel_wanted := false
var _custom_picker: HsvPicker
var _lists_dirty := true
var _confirm_delete := ""
var _last_export := ""
var _export_label: Label


func setup(b: Board) -> void:
	board = b
	_target = _syncers
	theme = UITheme.theme()
	add_theme_stylebox_override("panel", UITheme.box(UITheme.BG, 26))
	custom_minimum_size = design_size
	_build()
	board.changed.connect(func(): _lists_dirty = true)
	board.toast.connect(show_toast)
	App.setting_changed.connect(func(_k): _sync())
	_sync()


func _process(delta: float) -> void:
	if board == null:
		return
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast_label.visible = false
	if _lists_dirty:
		_lists_dirty = false
		_refresh_dynamic()
		_sync()
	_update_typing_layout()


# ------------------------------------------------------------------------------------------------ building

func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var head := HBoxContainer.new()
	root.add_child(head)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", UITheme.FONT_BIG)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	head.add_child(_title)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_status.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	head.add_child(_status)
	var close := Btn.new("close", "")
	close.small = true
	close.custom_minimum_size = Vector2(48, 44)
	close.pressed.connect(func(): hide_requested.emit())
	head.add_child(close)

	var tabs := HBoxContainer.new()
	_tabs_row = tabs
	root.add_child(tabs)
	for t in TABS:
		var b := Btn.new(t[1], t[2])
		b.custom_minimum_size = Vector2(0, 84)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.pressed.connect(_select_tab.bind(t[0]))
		tabs.add_child(b)
		_tab_btns[t[0]] = b

	_toast_label = Label.new()
	_toast_label.visible = false
	_toast_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_toast_label.add_theme_color_override("font_color", UITheme.WARN)
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.custom_minimum_size = Vector2(0, 0)
	root.add_child(_toast_label)

	var holder := Control.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.clip_contents = true
	_holder = holder
	root.add_child(holder)
	for t in TABS:
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sc.follow_focus = true
		sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		sc.visible = false
		holder.add_child(sc)
		var page := VBoxContainer.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_theme_constant_override("separation", 12)
		sc.add_child(page)
		_pages[t[0]] = {"scroll": sc, "page": page}
	_build_draw(_pages.draw.page)
	_build_shapes(_pages.shapes.page)
	_build_canvas(_pages.canvas.page)
	_build_docs(_pages.docs.page)
	_build_rooms(_pages.rooms.page)
	_build_more(_pages.more.page)

	_entry = _build_entry()
	root.add_child(_entry)

	_sel_bar = PanelContainer.new()
	(_sel_bar as PanelContainer).add_theme_stylebox_override("panel", UITheme.box(UITheme.PANEL, 14))
	var sel_col := VBoxContainer.new()
	sel_col.add_theme_constant_override("separation", 8)
	_sel_bar.add_child(sel_col)
	_alt_box = HFlowContainer.new()
	_alt_box.add_theme_constant_override("h_separation", 8)
	_alt_box.add_theme_constant_override("v_separation", 8)
	_alt_box.visible = false
	sel_col.add_child(_alt_box)
	var sv := HBoxContainer.new()
	sel_col.add_child(sv)
	_sel_label = Label.new()
	_sel_label.custom_minimum_size = Vector2(110, 0)
	_sel_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	sv.add_child(_sel_label)
	for spec in [["trash", "Delete"], ["copy", "Copy"], ["front", "Front"], ["back", "Back"]]:
		var sb := Btn.new(spec[0], "")
		sb.custom_minimum_size = Vector2(56, 52)
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.danger = spec[0] == "trash"
		sb.pressed.connect(_selection_action.bind(spec[0]))
		sv.add_child(sb)
	_sel_convert_btn = Btn.new("convert", "")
	_sel_convert_btn.custom_minimum_size = Vector2(56, 52)
	_sel_convert_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_convert_btn.pressed.connect(_selection_action.bind("convert"))
	sv.add_child(_sel_convert_btn)
	_sel_text_btn = Btn.new("text", "")
	_sel_text_btn.custom_minimum_size = Vector2(56, 52)
	_sel_text_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_text_btn.pressed.connect(_selection_action.bind("next_reading"))
	sv.add_child(_sel_text_btn)
	_sel_edit_btn = Btn.new("keyboard", "")
	_sel_edit_btn.custom_minimum_size = Vector2(56, 52)
	_sel_edit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_edit_btn.pressed.connect(func(): open_text_entry())
	sv.add_child(_sel_edit_btn)
	root.add_child(_sel_bar)

	var bottom := HBoxContainer.new()
	_bottom = bottom
	root.add_child(bottom)
	_undo_btn = Btn.new("undo", "")
	_undo_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_undo_btn.size_flags_stretch_ratio = 0.7
	_undo_btn.pressed.connect(func(): board.undo())
	bottom.add_child(_undo_btn)
	_redo_btn = Btn.new("redo", "")
	_redo_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_redo_btn.size_flags_stretch_ratio = 0.7
	_redo_btn.pressed.connect(func(): board.redo())
	bottom.add_child(_redo_btn)
	_ink_btn = Btn.new("convert", "To text")
	_ink_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ink_btn.pressed.connect(func(): board.ink.convert_ink())
	bottom.add_child(_ink_btn)
	_mic_btn = Btn.new("mic", "Dictate")
	_mic_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mic_btn.pressed.connect(func(): board.speech.toggle())
	bottom.add_child(_mic_btn)
	_type_btn = Btn.new("keyboard", "Type")
	_type_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_type_btn.pressed.connect(func(): open_text_entry())
	bottom.add_child(_type_btn)

	_keyboard = VKeyboard.new()
	_keyboard.visible = false
	root.add_child(_keyboard)
	_select_tab(App.val("menu_tab") if _pages.has(str(App.val("menu_tab"))) else "draw")


func _select_tab(id: String) -> void:
	_tab = id
	App.put("menu_tab", id)
	for k in _pages.keys():
		(_pages[k].scroll as Control).visible = k == id
	_sync()


# --- small builders ---------------------------------------------------------------------------------------------

func _label(text: String, dim: bool = false, size: int = UITheme.FONT_SMALL) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", UITheme.TEXT_DIM if dim else UITheme.TEXT)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _header(parent: Control, text: String) -> void:
	var l := _label(text.to_upper(), true, 15)
	l.add_theme_constant_override("line_spacing", 0)
	parent.add_child(l)


func _btn(icon: String, text: String, cb: Callable, tile_h: float = UITheme.ROW_H) -> Btn:
	var b := Btn.new(icon, text)
	b.custom_minimum_size = Vector2(0, tile_h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b


## A row of mutually exclusive buttons bound to a getter and a setter; kept in step by _sync().
func _segmented(parent: Control, options: Array, getter: Callable, setter: Callable, tile_h: float = 52.0) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var btns: Array = []
	for o in options:
		var b := Btn.new("", o[1])
		b.small = true
		b.custom_minimum_size = Vector2(0, tile_h)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			setter.call(o[0])
			_sync())
		row.add_child(b)
		btns.append([o[0], b])
	_target.append(func():
		var cur: Variant = getter.call()
		for pair in btns:
			if is_instance_valid(pair[1]):
				(pair[1] as Btn).on = pair[0] == cur)


func _toggle(parent: Control, icon: String, text: String, key: String) -> Btn:
	var b := Btn.new(icon, text, true)
	b.custom_minimum_size = Vector2(0, UITheme.ROW_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.toggled.connect(func(v: bool): App.put(key, v))
	parent.add_child(b)
	_target.append(func(): b.on = bool(App.val(key)))
	return b


func _slider_row(parent: Control, text: String, lo: float, hi: float, key: String, step: float, fmt: Callable) -> FlatSlider:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	parent.add_child(box)
	var l := _label("", false)
	box.add_child(l)
	var s := FlatSlider.new(lo, hi, float(App.val(key)), step)
	box.add_child(s)
	s.value_changed.connect(func(v: float): App.put(key, v))
	_target.append(func():
		l.text = "%s   %s" % [text, fmt.call(float(App.val(key)))]
		if absf(s.value - float(App.val(key))) > 0.0001:
			s.value = float(App.val(key)))
	return s


# ------------------------------------------------------------------------------------------------ Draw tab

func _build_draw(p: VBoxContainer) -> void:
	_header(p, "Tool")
	var tools := HBoxContainer.new()
	p.add_child(tools)
	var tool_btns: Array = []
	for t in TOOLS:
		var b := Btn.new(t[1], t[2])
		b.custom_minimum_size = Vector2(0, 96)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			App.put("tool", t[0])
			if t[0] != "select":
				board.clear_selection())
		tools.add_child(b)
		tool_btns.append([t[0], b])
	_syncers.append(func():
		for pair in tool_btns:
			(pair[1] as Btn).on = App.val("tool") == pair[0])

	_header(p, "Brush")
	var grid := GridContainer.new()
	grid.columns = 4
	p.add_child(grid)
	var brush_btns: Array = []
	for br in Brushes.LIST:
		var b2 := Btn.new(br.id, br.name)
		b2.custom_minimum_size = Vector2(0, 92)
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b2.pressed.connect(func():
			App.put("brush", br.id)
			if str(App.val("tool")) in ["shape", "select", "erase"]:
				App.put("tool", "draw"))
		grid.add_child(b2)
		brush_btns.append([br.id, b2])
	_syncers.append(func():
		for pair in brush_btns:
			(pair[1] as Btn).on = App.val("brush") == pair[0]
			(pair[1] as Btn).tint = App.val("color") if App.val("brush") == pair[0] else Color(0, 0, 0, 0))

	_header(p, "Colour")
	var sw := GridContainer.new()
	sw.columns = 7
	p.add_child(sw)
	var sw_btns: Array = []
	for hex in UITheme.PALETTE:
		var c := Color(hex)
		var b3 := Btn.new("", "")
		b3.swatch = c
		b3.custom_minimum_size = Vector2(0, 62)
		b3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b3.pressed.connect(func(): App.put("color", c))
		sw.add_child(b3)
		sw_btns.append([c, b3])
	var more := Btn.new("plus", "", true)
	more.custom_minimum_size = Vector2(0, 62)
	more.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sw.add_child(more)
	_custom_picker = HsvPicker.new()
	_custom_picker.visible = false
	_custom_picker.custom_minimum_size = Vector2(0, 210)
	_custom_picker.color_changed.connect(func(c: Color): App.put("color", c))
	p.add_child(_custom_picker)
	more.toggled.connect(func(v: bool): _custom_picker.visible = v)
	_syncers.append(func():
		var cur: Color = App.val("color")
		for pair in sw_btns:
			(pair[1] as Btn).on = (pair[0] as Color).is_equal_approx(cur)
		if _custom_picker.visible and not _custom_picker.current().is_equal_approx(cur):
			_custom_picker.set_color(cur))

	_header(p, "Size")
	_slider_row(p, "Line width", 0.001, 0.04, "width", 0.0005, func(v: float): return "%.1f mm" % (v * 1000.0))

	_header(p, "Snap lines and shapes")
	_segmented(p, [["off", "Off"], ["hold", "Hold still"], ["auto", "Always"]], func(): return App.val("recognize"), func(v): App.put("recognize", v))
	p.add_child(_label("Hold still at the end of a stroke and a line, box, circle, triangle or arrow snaps to a clean vector shape.", true))


# ------------------------------------------------------------------------------------------------ Shapes tab

func _build_shapes(p: VBoxContainer) -> void:
	_header(p, "Flow diagram")
	_stencil_grid(p, "flow")
	_header(p, "Basic shapes")
	_stencil_grid(p, "basic")
	_header(p, "Lines and connectors")
	_stencil_grid(p, "line")
	p.add_child(_label("Pick a shape, then drag on a canvas to size it (tap for the default size). Arrows and lines stick to the middle of a box's sides and follow it when the box moves.", true))
	_header(p, "Style")
	_toggle(p, "shapes", "Fill shapes with colour", "fill")
	_slider_row(p, "Fill strength", 0.05, 0.9, "fill_alpha", 0.05, func(v: float): return "%d %%" % int(v * 100.0))
	_toggle(p, "anchor", "Connectors stick to shapes", "snap_connectors")


func _stencil_grid(p: VBoxContainer, group: String) -> void:
	var grid := GridContainer.new()
	grid.columns = 4
	p.add_child(grid)
	var btns: Array = []
	for s in Shapes.STENCILS:
		if s.group != group:
			continue
		var b := Btn.new(s.id, s.name)
		b.custom_minimum_size = Vector2(0, 96)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			board.stencil = s.id
			App.put("tool", "shape")
			_sync())
		grid.add_child(b)
		btns.append([s.id, b])
	_syncers.append(func():
		for pair in btns:
			(pair[1] as Btn).on = board.stencil == pair[0] and App.val("tool") == "shape")


# ------------------------------------------------------------------------------------------------ Canvas tab

var _canvas_list: VBoxContainer
var _canvas_style: VBoxContainer


func _build_canvas(p: VBoxContainer) -> void:
	_header(p, "New canvas")
	var row := HBoxContainer.new()
	p.add_child(row)
	row.add_child(_btn("canvas", "On a wall", func(): board.begin_place("wall", SIZES[canvas_size_idx][1]), 72))
	row.add_child(_btn("canvas", "On a table", func(): board.begin_place("table", SIZES[canvas_size_idx][1]), 72))
	var szs := HBoxContainer.new()
	p.add_child(szs)
	var size_btns: Array = []
	for i in SIZES.size():
		var b := Btn.new("", "%s  %s" % [SIZES[i][0], "%d x %d cm" % [int((SIZES[i][1] as Vector2).x * 100), int((SIZES[i][1] as Vector2).y * 100)]])
		b.small = true
		b.custom_minimum_size = Vector2(0, 48)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			canvas_size_idx = i
			_sync())
		szs.add_child(b)
		size_btns.append([i, b])
	_syncers.append(func():
		for pair in size_btns:
			(pair[1] as Btn).on = canvas_size_idx == pair[0])
	p.add_child(_label("The grid fades in around the stylus and fades out as you step away. Draw past the edge and the canvas grows: it is infinite.", true))
	p.add_child(_btn("volume", "New 3D sketch here", func():
		var pos := board.head.origin + (-board.head.basis.z) * 0.6
		board.new_volume_at(pos)
		board.toast.emit("3D sketch started. Draw in the air with the stylus."), 60))
	_header(p, "In this room")
	_canvas_list = VBoxContainer.new()
	p.add_child(_canvas_list)
	_header(p, "Selected canvas")
	_canvas_style = VBoxContainer.new()
	p.add_child(_canvas_style)


func _refresh_canvas_tab() -> void:
	_dyn_syncers.clear()
	_target = _dyn_syncers
	_refresh_canvas_tab_body()
	_target = _syncers


func _refresh_canvas_tab_body() -> void:
	_clear(_canvas_list)
	var frames := board.doc.frames_in(board.current_room) if board.doc != null else []
	if frames.is_empty():
		_canvas_list.add_child(_label("No canvases in this room yet.", true))
	for f in frames:
		var fd: FrameData = f
		var row := HBoxContainer.new()
		_canvas_list.add_child(row)
		var name_btn := Btn.new("canvas" if fd.kind == FrameData.CANVAS else "volume", fd.name)
		name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_btn.on = board.active_frame == fd.id
		name_btn.pressed.connect(func():
			board.active_frame = fd.id
			_lists_dirty = true)
		row.add_child(name_btn)
		var ren := Btn.new("text", "")
		ren.custom_minimum_size = Vector2(60, 0)
		ren.pressed.connect(func(): _ask_name("Rename", fd.name, func(t: String): board.rename_frame(fd.id, t)))
		row.add_child(ren)
		var lk := Btn.new("lock", "", true)
		lk.custom_minimum_size = Vector2(60, 0)
		lk.on = fd.locked
		lk.toggled.connect(func(v: bool): board.set_frame_prop(fd.id, "locked", v))
		row.add_child(lk)
		var clr := Btn.new("erase", "")
		clr.custom_minimum_size = Vector2(60, 0)
		clr.pressed.connect(func(): board.clear_frame(fd.id))
		row.add_child(clr)
		var del := Btn.new("trash", "")
		del.custom_minimum_size = Vector2(60, 0)
		del.danger = true
		del.on = _confirm_delete == fd.id
		del.pressed.connect(func():
			if _confirm_delete == fd.id:
				_confirm_delete = ""
				board.delete_frame(fd.id)
			else:
				_confirm_delete = fd.id
				board.toast.emit("Press the bin again to delete \"%s\" (undo brings it back)." % fd.name)
				_lists_dirty = true)
		row.add_child(del)
	_clear(_canvas_style)
	var active: FrameData = board.doc.frames.get(board.active_frame) if board.doc != null else null
	if active == null or active.kind != FrameData.CANVAS:
		_canvas_style.add_child(_label("Touch a canvas with the stylus, or pick one above.", true))
		return
	_canvas_style.add_child(_label(active.name, false, UITheme.FONT))
	_header(_canvas_style, "Grid")
	_segmented(_canvas_style, [["", "Default"], ["lines", "Lines"], ["dots", "Dots"], ["none", "None"]],
		func(): return active.grid, func(v): board.set_frame_prop(active.id, "grid", v))
	_header(_canvas_style, "Backing")
	_segmented(_canvas_style, [["", "Default"], ["none", "None"], ["glass", "Glass"], ["dark", "Dark"], ["white", "White"]],
		func(): return active.backing, func(v): board.set_frame_prop(active.id, "backing", v))
	var hb := HBoxContainer.new()
	_canvas_style.add_child(hb)
	hb.add_child(_btn("canvas", "Reset size", func():
		var fr: FrameData = board.doc.frames.get(active.id)
		if fr != null:
			var upd := fr.copy()
			upd.scale = 1.0
			board.history.do(History.op_frame(fr, upd))))
	hb.add_child(_btn("pin", "Bring to me", func(): _bring_to_me(active.id)))


func _bring_to_me(frame_id: String) -> void:
	var fd: FrameData = board.doc.frames.get(frame_id)
	if fd == null:
		return
	var h := board.head
	var pos := h.origin + (-h.basis.z) * 0.9
	pos.y = clampf(pos.y - 0.1, 0.6, 1.8)
	var yaw := atan2(h.origin.x - pos.x, h.origin.z - pos.z)
	var rw: Variant = board.room_world(fd.room)
	var world := Transform3D(Basis(Vector3.UP, yaw), pos)
	var upd := fd.copy()
	upd.xf = (rw as Transform3D).affine_inverse() * world if rw != null else world
	board.history.do(History.op_frame(fd, upd))


# ------------------------------------------------------------------------------------------------ Docs tab

var _docs_list: VBoxContainer
var _doc_name: Label


func _build_docs(p: VBoxContainer) -> void:
	_header(p, "This document")
	_doc_name = _label("", false, UITheme.FONT_BIG)
	p.add_child(_doc_name)
	var row := HBoxContainer.new()
	p.add_child(row)
	row.add_child(_btn("plus", "New", func():
		board.new_document()
		_lists_dirty = true))
	row.add_child(_btn("text", "Rename", func(): _ask_name("Rename document", board.doc.name if board.doc != null else "", func(t: String):
		board.doc.rename(t)
		_lists_dirty = true)))
	var row2 := HBoxContainer.new()
	p.add_child(row2)
	row2.add_child(_btn("copy", "Duplicate", func():
		board.flush_save()
		var d := DocStore.clone(board.doc.id)
		if d != null:
			board.open(d)))
	row2.add_child(_btn("doc", "Save now", func():
		board.flush_save()
		board.doc.save()
		board.toast.emit("Saved")))
	_header(p, "Export")
	var ex := HBoxContainer.new()
	p.add_child(ex)
	ex.add_child(_btn("export", "SVG", func(): _do_export("svg"), 64))
	ex.add_child(_btn("volume", "3D (.glb)", func(): _do_export("glb"), 64))
	ex.add_child(_btn("doc", "File (.mrw)", func(): _do_export("mrw"), 64))
	_export_label = _label("SVG: one vector file per canvas, opens in Inkscape, Illustrator, Figma. 3D: the air drawings as a glTF model.", true)
	p.add_child(_export_label)
	_header(p, "All documents")
	_docs_list = VBoxContainer.new()
	p.add_child(_docs_list)


func _do_export(kind: String) -> void:
	if board.doc == null:
		return
	board.flush_save()
	var res: Dictionary
	match kind:
		"svg":
			res = Exporter.svg(board.doc, {"background": "white", "grid": false})
		"glb":
			res = Exporter.glb(board.doc)
		_:
			res = Exporter.document(board.doc)
	_last_export = str(res.message)
	_export_label.text = _last_export
	board.toast.emit(_last_export)


func _refresh_docs_tab() -> void:
	if board.doc == null:
		return
	_doc_name.text = board.doc.name
	_clear(_docs_list)
	for s in DocStore.list():
		var row := HBoxContainer.new()
		_docs_list.add_child(row)
		var is_cur: bool = s.id == board.doc.id
		var d := Time.get_datetime_dict_from_unix_time(int(s.modified))
		var b := Btn.new("doc", "%s" % s.name)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 64)
		b.on = is_cur
		b.pressed.connect(func():
			if not is_cur:
				board.flush_save()
				board.open_id(s.id))
		row.add_child(b)
		var info := _label("%d canvas / %d items\n%02d-%02d %02d:%02d" % [s.frames, s.items, d.month, d.day, d.hour, d.minute], true, 14)
		info.custom_minimum_size = Vector2(130, 0)
		info.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(info)
		if not is_cur:
			var del := Btn.new("trash", "")
			del.custom_minimum_size = Vector2(60, 0)
			del.danger = true
			del.on = _confirm_delete == str(s.id)
			del.pressed.connect(func():
				if _confirm_delete == str(s.id):
					_confirm_delete = ""
					for a in DocStore.delete(s.id):
						board.anchors.erase(a)
					board.toast.emit("Deleted \"%s\"" % s.name)
					_lists_dirty = true
				else:
					_confirm_delete = str(s.id)
					board.toast.emit("Press the bin again to delete \"%s\"." % s.name)
					_lists_dirty = true)
			row.add_child(del)


# ------------------------------------------------------------------------------------------------ Rooms tab

var _room_card: Label
var _rooms_list: VBoxContainer
var _sim_box: VBoxContainer


func _build_rooms(p: VBoxContainer) -> void:
	_header(p, "Where you are")
	_room_card = _label("", false, UITheme.FONT)
	p.add_child(_room_card)
	p.add_child(_label("Each room is remembered by a spatial anchor. Canvases stay fixed in the room, and come back where you left them when you return.", true))
	var row := HBoxContainer.new()
	p.add_child(row)
	row.add_child(_btn("room", "New room here", func(): board.create_room_here(), 64))
	row.add_child(_btn("anchor", "Re-anchor room", func(): board.reanchor_room(), 64))
	_header(p, "Rooms in this document")
	_rooms_list = VBoxContainer.new()
	p.add_child(_rooms_list)
	_sim_box = VBoxContainer.new()
	p.add_child(_sim_box)
	_header(_sim_box, "PC test: simulated room")
	_segmented(_sim_box, [["A", "Room A"], ["B", "Room B"], ["C", "Room C"]], func(): return App.val("sim_room"), func(v): App.put("sim_room", v))
	_sim_box.add_child(_label("Moves you to another simulated room: canvases of the other rooms disappear, exactly like walking through a door in the headset.", true))


func _refresh_rooms_tab() -> void:
	var st := board.room_state
	var cur := board.doc.room(board.current_room) if board.doc != null else {}
	match st:
		"found":
			_room_card.text = "In \"%s\"" % cur.get("name", "this room")
			_room_card.add_theme_color_override("font_color", UITheme.GOOD)
		"searching":
			_room_card.text = "Looking for a room you have used before..."
			_room_card.add_theme_color_override("font_color", UITheme.WARN)
		"needs_room":
			_room_card.text = "This room is new to this document. Create it, or pick a room below."
			_room_card.add_theme_color_override("font_color", UITheme.WARN)
		"unanchored":
			_room_card.text = "Spatial anchors are not available: content will not stay in place between sessions."
			_room_card.add_theme_color_override("font_color", UITheme.BAD)
		_:
			_room_card.text = "Setting up the first room..."
			_room_card.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_sim_box.visible = board.anchors is SimAnchors
	_clear(_rooms_list)
	if board.doc == null:
		return
	for r in board.doc.rooms:
		var room: Dictionary = r
		var row := HBoxContainer.new()
		_rooms_list.add_child(row)
		var here: bool = room.id == board.current_room
		var b := Btn.new("room", "%s%s" % [room.name, "  (here)" if here else ""])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 60)
		b.on = here
		b.pressed.connect(func(): board.select_room(room.id))
		row.add_child(b)
		var ren := Btn.new("text", "")
		ren.custom_minimum_size = Vector2(60, 0)
		ren.pressed.connect(func(): _ask_name("Rename room", room.name, func(t: String): board.rename_room(room.id, t)))
		row.add_child(ren)
		var del := Btn.new("trash", "")
		del.custom_minimum_size = Vector2(60, 0)
		del.danger = true
		del.on = _confirm_delete == str(room.id)
		del.pressed.connect(func():
			if _confirm_delete == str(room.id):
				_confirm_delete = ""
				board.delete_room(room.id)
			else:
				_confirm_delete = str(room.id)
				board.toast.emit("Press the bin again: this deletes the room and everything in it.")
				_lists_dirty = true)
		row.add_child(del)


# ------------------------------------------------------------------------------------------------ More tab

func _build_more(p: VBoxContainer) -> void:
	_header(p, "Handwriting")
	_segmented(p, [["google", "Online reading"], ["none", "Off"]], func(): return App.val("ink_provider"), func(v): App.put("ink_provider", v))
	var lang := Btn.new("text", "")
	lang.custom_minimum_size = Vector2(0, UITheme.ROW_H)
	lang.pressed.connect(func():
		var i := 0
		for k in InkRecognizer.LANGUAGES.size():
			if InkRecognizer.LANGUAGES[k][0] == App.val("ink_language"):
				i = k
		App.put("ink_language", InkRecognizer.LANGUAGES[(i + 1) % InkRecognizer.LANGUAGES.size()][0]))
	p.add_child(lang)
	_syncers.append(func():
		for l in InkRecognizer.LANGUAGES:
			if l[0] == App.val("ink_language"):
				lang.text = "Language: %s  (tap to change)" % l[1])
	_toggle(p, "convert", "Convert automatically after a pause", "ink_auto")
	_slider_row(p, "Pause before converting", 1.0, 5.0, "ink_pause", 0.25, func(v: float): return "%.1f s" % v)
	p.add_child(_label("Use the Write tool: write words with the stylus and pause. They turn into text of the same size, right where you wrote. Needs internet. Misread? Select the text: pick another reading, retype it, or go back to your handwriting. Writing larger and a little slower helps.", true))
	_header(p, "Speech to text")
	_segmented(p, [["wit", "Wit.ai"], ["none", "Off"]], func(): return App.val("speech_provider"), func(v): App.put("speech_provider", v))
	_token_edit = LineEdit.new()
	_token_edit.custom_minimum_size = Vector2(0, 52)
	_token_edit.secret = true
	_token_edit.placeholder_text = "Wit.ai server access token"
	_token_edit.virtual_keyboard_enabled = false        # the on-screen keyboard below is ours, not the system's
	_token_edit.context_menu_enabled = false
	_token_edit.text_submitted.connect(func(_t: String): _token_edit.release_focus())
	_token_edit.text_changed.connect(func(t: String): App.put("wit_token", t.strip_edges()))
	p.add_child(_token_edit)
	_syncers.append(func():
		if _token_edit.text != str(App.val("wit_token")) and not _token_edit.has_focus():
			_token_edit.text = str(App.val("wit_token")))
	p.add_child(_label("Tap Dictate, say something and pause: the words appear as text on the canvas you are looking at (or in the correction box). Needs a free Wit.ai account: create an app at wit.ai, copy its Server Access Token into this box (in the headset tap the box to type it with the on-screen or a Bluetooth keyboard, or put it in a file wit_token.txt, see the README). Speech goes to Wit.ai only while you dictate.", true))
	_header(p, "Stylus and hands")
	_segmented(p, [["auto", "Stylus hand: auto"], ["left", "Left"], ["right", "Right"]], func(): return App.val("stylus_hand"), func(v): App.put("stylus_hand", v))
	_toggle(p, "pin", "Haptic ticks", "haptics")
	_toggle(p, "pen", "Draw with a pinch if there is no stylus", "finger_draw")
	_slider_row(p, "Hold-still time for snapping", 0.25, 1.2, "hold_seconds", 0.05, func(v: float): return "%.2f s" % v)
	_header(p, "Canvas defaults")
	_segmented(p, [["lines", "Lines"], ["dots", "Dots"], ["none", "None"]], func(): return App.val("grid"), func(v): App.put("grid", v))
	_segmented(p, [["none", "None"], ["glass", "Glass"], ["dark", "Dark"], ["white", "White"]], func(): return App.val("backing"), func(v): App.put("backing", v))
	_slider_row(p, "Grid disappears at", 1.0, 5.0, "grid_fade_viewer", 0.25, func(v: float): return "%.1f m" % v)
	_slider_row(p, "Grid light around the stylus", 0.25, 1.2, "grid_focus", 0.05, func(v: float): return "%.2f m" % v)
	_header(p, "Controls")
	p.add_child(_label("Stylus tip or middle button: draw.\nFront button: grab and move what the tip touches.\nBack button: undo (double tap: redo).\nPinch a canvas: carry it. Both hands: turn and resize.\nPinch a corner: change the extent.\nOpen palm facing up: bring this menu to you.", true))
	_header(p, "Display")
	_slider_row(p, "Menu size", 0.7, 1.6, "ui_scale", 0.05, func(v: float): return "%d %%" % int(v * 100.0))


# ------------------------------------------------------------------------------------------------ text entry

func _build_entry() -> TextEntry:
	var e := TextEntry.new()
	e.accepted.connect(_entry_ok)
	e.cancelled.connect(close_entry)
	e.mic_btn.pressed.connect(func(): board.speech.toggle(func(t: String): _entry.insert(t)))
	e.keyboard_toggled.connect(func():
		App.put("vkeyboard", not bool(App.val("vkeyboard")))
		_sync())
	return e


## Open the box for the thing that is selected: a text item is edited, a closed shape gets a label, otherwise new text for the
## canvas in front of you. False when there is nowhere to put new text.
func open_text_entry() -> bool:
	var txt := board.texts.selected_text()
	if txt != null:
		var id := txt.id
		_open_entry("Edit text", txt.text, true, func(t: String): board.texts.edit(id, t))
		return true
	var shp := board.texts.selected_shape()
	if shp != null:
		var sid := shp.id
		_open_entry("Label for this shape", shp.label, true, func(t: String): board.texts.set_label(sid, t), true)
		return true
	if board.texts.spot().is_empty():
		board.toast.emit("Place a canvas first (Canvas tab), then type your text.")
		return false
	_open_entry("New text on the canvas", "", true, func(t: String): board.texts.place(t))
	return true


func _ask_name(title: String, current: String, cb: Callable) -> void:
	_open_entry(title, current, false, cb)


func _open_entry(title: String, current: String, multiline: bool, cb: Callable, empty_ok: bool = false) -> void:
	_entry_cb = cb
	_entry.open(title, current, multiline, board.ink.provider().recognize, str(App.val("ink_language")), empty_ok)
	_sync()


func close_entry() -> void:
	_entry.close()
	_entry_cb = Callable()
	_lists_dirty = true
	_sync()


func _entry_ok(text: String) -> void:
	var cb := _entry_cb
	close_entry()
	if cb.is_valid():
		cb.call(text)


func entry_open() -> bool:
	return _entry != null and _entry.is_open()


## True while a text field of the menu has the keyboard focus: the rig must then pass keys to it instead of using them as shortcuts.
func is_typing() -> bool:
	var f := _focused_field()
	return f != null


func _focused_field() -> Control:
	if not is_inside_tree():
		return null
	var f := get_viewport().gui_get_focus_owner()
	if f != null and (f is LineEdit or f is TextEdit) and is_ancestor_of(f) and f.is_visible_in_tree():
		return f
	return null


## Keyboard docked at the bottom while a field is being edited. The rest of the menu makes room: while the box is open it replaces
## the tabs, and the selection strip and bottom bar step aside so the panel never grows past its size.
func _update_typing_layout() -> void:
	if _keyboard == null:
		return
	var f := _focused_field()
	var open := entry_open()
	var kb := bool(App.val("vkeyboard")) and (open or f != null)
	if kb:
		_keyboard.target = _entry.field() if open else f
	if _keyboard.visible != kb:
		_keyboard.visible = kb
	_entry.show_pad(not bool(App.val("vkeyboard")))
	_tabs_row.visible = not open
	_holder.visible = not open
	_bottom.visible = not (open or kb)
	_sel_bar.visible = _sel_wanted and not (open or kb)


# ------------------------------------------------------------------------------------------------ selection strip

func _selection_action(what: String) -> void:
	match what:
		"trash":
			board.delete_selection()
		"copy":
			board.duplicate_selection()
		"front":
			board.bring_to_front()
		"back":
			board.send_to_back()
		"convert":
			board.ink.convert_ink(board.selected_items())
		"next_reading":
			if board.selection.size() == 1:
				board.ink.cycle_alternative(board.selection[0])


# ------------------------------------------------------------------------------------------------ state

func show_toast(text: String) -> void:
	if _toast_label == null:
		return
	_toast_label.text = text
	_toast_label.visible = true
	_toast_t = 4.5


func _refresh_dynamic() -> void:
	if board.doc == null:
		return
	_title.text = board.doc.name
	var room := board.doc.room(board.current_room)
	_status.text = str(room.get("name", "no room")) if board.room_state == "found" else ("searching..." if board.room_state == "searching" else board.room_state.replace("_", " "))
	_refresh_canvas_tab()
	_refresh_docs_tab()
	_refresh_rooms_tab()


func _sync() -> void:
	if board == null:
		return
	for k in _tab_btns.keys():
		(_tab_btns[k] as Btn).on = k == _tab
	for s in _syncers:
		s.call()
	for s in _dyn_syncers:
		s.call()
	var n := board.selection.size()
	_sel_wanted = n > 0
	_sel_label.text = "%d selected" % n
	var single_text := n == 1 and board.doc != null and board.doc.items.has(board.selection[0]) and (board.doc.items[board.selection[0]] as Item).kind == Item.TEXT
	_sel_text_btn.visible = single_text and not (board.doc.items[board.selection[0]] as Item).alternatives.is_empty()
	var any_stroke := false
	for it in board.selected_items():
		if (it as Item).kind == Item.STROKE:
			any_stroke = true
	_sel_convert_btn.visible = any_stroke
	_sel_edit_btn.visible = board.texts.selected_text() != null or board.texts.selected_shape() != null
	_refresh_readings(single_text)
	_undo_btn.modulate.a = 1.0 if board.history != null and board.history.can_undo() else 0.45
	_redo_btn.modulate.a = 1.0 if board.history != null and board.history.can_redo() else 0.45
	_ink_btn.visible = board.ink.has_pending() or board.ink.failed
	_ink_btn.text = "To text (%d)" % board.ink.pending.size() if not board.ink.busy else "Reading..."
	var sp := board.speech
	for mb in [_mic_btn, _entry.mic_btn]:
		(mb as Btn).on = sp.listening()
		(mb as Btn).text = "Listening..." if sp.listening() else ("Reading..." if sp.busy() else "Dictate")
	_update_typing_layout()


## Selected converted text: the other readings of the handwriting as one-tap choices, plus retype and back to ink.
func _refresh_readings(single_text: bool) -> void:
	var it: Item = null
	if single_text:
		it = board.doc.items[board.selection[0]]
	var sig := "" if it == null else "%s|%s|%d" % [it.id, it.text + "/" + ",".join(it.alternatives), it.ink.size()]
	if sig == _alt_sig:
		return
	_alt_sig = sig
	_clear(_alt_box)
	_alt_box.visible = it != null
	if it == null:
		return
	var id := it.id
	for reading in it.alternatives:
		var r: String = reading
		var b := Btn.new("", r)
		b.small = true
		b.custom_minimum_size = Vector2(0, 46)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): board.ink.choose_alternative(id, r))
		_alt_box.add_child(b)
	var edit := Btn.new("keyboard", "Edit text")
	edit.small = true
	edit.custom_minimum_size = Vector2(0, 46)
	edit.pressed.connect(func(): open_text_entry())
	_alt_box.add_child(edit)
	if not it.ink.is_empty():
		var back := Btn.new("undo", "Back to handwriting")
		back.small = true
		back.custom_minimum_size = Vector2(0, 46)
		back.pressed.connect(func(): board.ink.revert_to_ink(id))
		_alt_box.add_child(back)


func _clear(c: Control) -> void:
	for ch in c.get_children():
		ch.queue_free()
