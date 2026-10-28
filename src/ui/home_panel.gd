class_name HomePanel
extends FloatPanel
## Everything that is not drawing, in one card opened from the dock: Documents (open, new, rename, export), Canvases (the canvases
## of this room and how the selected one looks), Rooms, Share (the web page for a PC on the Wi-Fi) and Settings.

const TABS := [["docs", "doc", "Docs"], ["canvas", "canvas", "Canvases"], ["rooms", "room", "Rooms"], ["share", "wifi", "Share"], ["session", "session", "Session"], ["settings", "settings", "Settings"],
	["guide", "help", "Guide"]]                # the guide has no tab: the "?" in the header opens it
const W := 600.0
const H := 760.0

var tab := "docs"
var quit_btn: Btn

var _title: Btn
var _room_chip: Label
var _tab_btns := {}
var _pages := {}
var _scroll: ScrollContainer
var _quit_armed := 0.0
var _confirm := ""
var _lists_sig := ""
var _docs_list: VBoxContainer
var _pdf_list: VBoxContainer
var _image_list: VBoxContainer
var _model_list: VBoxContainer
var _canvas_list: VBoxContainer
var _canvas_style: VBoxContainer
var _rooms_list: VBoxContainer
var _room_card: Label
var _sim_box: VBoxContainer
var _export_label: Label
var _share_switch: Switch
var _share_code: Label
var _share_label: Label
var _token_btn: Btn
var _tg_switch: Switch
var _tg_token_btn: Btn
var _tg_code: Label
var _tg_label: Label
var _tg_unlink: Btn
var _tg_send: VBoxContainer
var grip: Dock.Grip
var session_page := SessionPage.new()
var guide_page := GuidePage.new()
var help_btn: Btn


func _init() -> void:
	super()
	id = "home"
	kind = "side"
	side = -1
	movable = true
	auto_size = false
	pivot = Vector2(0.5, 0.5)
	max_size = Vector2(W + 40, H + 40)
	ppm = 1500.0
	custom_minimum_size = Vector2(W, H)
	add_theme_stylebox_override("panel", UITheme.glass(26, 18.0))
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	add_child(root)
	# header: the document's name (tap to rename), the room, quit and close
	var head := UiKit.hrow(root, 6)
	grip = Dock.Grip.new()
	grip.custom_minimum_size = Vector2(18, 44)
	head.add_child(grip)
	_title = Btn.new("", "")
	_title.variant = "ghost"
	_title.font_weight = 600
	_title.font_size = UITheme.FONT
	_title.align = HORIZONTAL_ALIGNMENT_LEFT
	_title.hint = "Rename the document"
	_title.custom_minimum_size = Vector2(0, 48)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.pressed.connect(func(): _rename_doc())
	head.add_child(_title)
	_room_chip = UiKit.label("", true, UITheme.FONT_TINY, 500)
	_room_chip.size_flags_horizontal = Control.SIZE_SHRINK_END
	_room_chip.autowrap_mode = TextServer.AUTOWRAP_OFF
	head.add_child(_room_chip)
	help_btn = UiKit.tool("help", "How to use it: the guide", func(): select_tab("docs" if tab == "guide" else "guide"), 44.0)
	head.add_child(help_btn)
	quit_btn = UiKit.chip("Quit", _on_quit, "power", 40.0)
	quit_btn.variant = "ghost"
	quit_btn.danger = true
	quit_btn.custom_minimum_size.x = 104
	head.add_child(quit_btn)
	head.add_child(UiKit.tool("close", "Close", func(): shell.close_side("home"), 44.0))
	# tabs
	var tabs := UiKit.hrow(root, 4)
	for t in TABS:
		var tid: String = t[0]
		if tid == "guide":
			continue
		var b := Btn.new("", t[2])
		b.variant = "chip"
		b.custom_minimum_size = Vector2(0, 44)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): select_tab(tid))
		tabs.add_child(b)
		_tab_btns[tid] = b
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)
	var pages := VBoxContainer.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pages)
	for t in TABS:
		var pg := VBoxContainer.new()
		pg.add_theme_constant_override("separation", 12)
		pg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pg.visible = false
		pages.add_child(pg)
		_pages[t[0]] = pg
	_build_docs(_pages.docs)
	_build_canvas(_pages.canvas)
	_build_rooms(_pages.rooms)
	_build_share(_pages.share)
	_build_telegram(_pages.share)
	session_page.build(_pages["session"], self)
	_build_settings(_pages.settings)
	guide_page.build(_pages.guide, self)
	var want := str(App.val("menu_tab"))
	select_tab(want if _pages.has(want) and want != "guide" else "docs")


func select_tab(t: String) -> void:
	tab = t
	if t != "guide":
		App.put("menu_tab", t)                         # the guide is a visit: Home opens on the tab you left, not on the guide
	for k in _pages:
		(_pages[k] as Control).visible = k == t
	for k in _tab_btns:
		(_tab_btns[k] as Btn).on = k == t
	help_btn.on = t == "guide"
	scroll_to_top()
	_lists_sig = ""
	if shell != null:
		refresh()


func scroll_to_top() -> void:
	_scroll.scroll_vertical = 0


## The end of the Docs page, where the PDFs are listed.
func scroll_to_bottom() -> void:
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _process(delta: float) -> void:
	super(delta)
	session_page.tick(delta)
	if _quit_armed > 0.0:
		_quit_armed -= delta
		if _quit_armed <= 0.0:
			quit_btn.text = "Quit"


func refresh() -> void:
	var b: Board = shell.board
	if b.doc == null:
		return
	_title.text = b.doc.name
	var room := b.doc.room(b.current_room)
	var waiting := "Waiting to be aligned..." if b.session.is_client() else "Looking for the room..."      # (a guest in the owner's room sees nothing until aligned)
	_room_chip.text = str(room.get("name", "")) if b.room_state in ["found", "assumed"] else (waiting if b.room_state == "searching" else "")
	var sig := "%s|%s|%s|%s|%s|%d|%d|%s" % [tab, b.doc.id, b.doc.name, b.current_room, b.active_frame, b.doc.frames.size(), b.doc.rooms.size(), _confirm]
	for e in b.pdfs.list():
		sig += "|" + str(e.id) + str(e.name)
	for e in b.images.list():
		sig += "|" + str(e.id) + str(e.name)
	for e in b.models.list():
		sig += "|" + str(e.id) + str(e.name) + str(e.get("triangles", 0))
	for f in b.doc.frames.values():
		sig += "/" + (f as FrameData).name + str((f as FrameData).locked) + str((f as FrameData).place_locked) + str((f as FrameData).hidden) + str((f as FrameData).surface) + str((f as FrameData).bend)
		if (f as FrameData).bend:
			sig += "%d,%d" % [roundi((f as FrameData).bend_at * 100.0), roundi((f as FrameData).bend_radius * 100.0)]
	if sig != _lists_sig:
		_lists_sig = sig
		_kit_dynamic_reset()
		match tab:
			"docs":
				_refresh_docs()
				_refresh_images()
				_refresh_pdfs()
				_refresh_models()
			"canvas":
				_refresh_canvas()
			"rooms":
				_refresh_rooms()
	_kit.sync()
	_dyn.sync()
	_sync_share()
	_sync_telegram()
	if tab == "session":
		session_page.refresh()


var _dyn := UiKit.new()                    # refreshers of widgets rebuilt with their list


func _kit_dynamic_reset() -> void:
	_dyn = UiKit.new()


# ------------------------------------------------------------------------------------------------ documents

func _build_docs(p: VBoxContainer) -> void:
	var c := UiKit.card(p)
	var r := UiKit.hrow(c, 8)
	r.add_child(UiKit.button("plus", "New", func():
		shell.board.new_document()
		_lists_sig = "", 52.0))
	r.add_child(UiKit.button("copy", "Duplicate", func():
		var b: Board = shell.board
		b.flush_save()
		var d := DocStore.clone(b.doc.id)
		if d != null:
			b.open(d), 52.0))
	r.add_child(UiKit.button("doc", "Save", func():
		var b: Board = shell.board
		b.flush_save()
		b.doc.save()
		b.toast.emit("Saved"), 52.0))
	UiKit.header(p, "Export")
	var ex := UiKit.hrow(p, 8)
	ex.add_child(UiKit.button("export", "SVG", func(): _export("svg"), 52.0))
	ex.add_child(UiKit.button("volume", "3D .glb", func(): _export("glb"), 52.0))
	ex.add_child(UiKit.button("doc", "File .mrw", func(): _export("mrw"), 52.0))
	_export_label = UiKit.note(p, "SVG: one vector file per canvas (Inkscape, Illustrator, Figma). 3D: the ink as a glTF model.")
	_tg_send = UiKit.vcol(p, 8)                    # shown once a Telegram chat is linked (Share)
	UiKit.header(_tg_send, "Send to Telegram")
	var tr := UiKit.hrow(_tg_send, 8)
	tr.add_child(UiKit.button("send", "SVG", func(): _send_telegram("svg"), 52.0))
	tr.add_child(UiKit.button("volume", "3D .glb", func(): _send_telegram("glb"), 52.0))
	tr.add_child(UiKit.button("doc", "File .mrw", func(): _send_telegram("mrw"), 52.0))
	UiKit.header(p, "All documents")
	_docs_list = UiKit.vcol(p, 6)
	UiKit.header(p, "Pictures")
	_image_list = UiKit.vcol(p, 6)
	UiKit.header(p, "PDF documents")
	_pdf_list = UiKit.vcol(p, 6)
	UiKit.header(p, "3D models")
	_model_list = UiKit.vcol(p, 6)


## The 3D models on the headset: tap one to put it in front of you, the bin (pressed twice) removes it from the headset.
func _refresh_models() -> void:
	var b: Board = shell.board
	UiKit.clear(_model_list)
	var list := b.models.list()
	if list.is_empty():
		UiKit.note(_model_list, "No 3D models yet. Switch on the web page in Share, open it on your PC and drop a model on it (glTF .glb or .gltf, or .obj with its .mtl and pictures, or all of them in a .zip): it arrives here and stands in front of you.")
		return
	for e in list:
		var mid: String = e.id
		var row := UiKit.hrow(_model_list, 6)
		var btn := Btn.new("model", str(e.name))
		btn.align = HORIZONTAL_ALIGNMENT_LEFT
		btn.small = true
		btn.custom_minimum_size = Vector2(0, 58)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.hint = "Put it in front of you"
		btn.pressed.connect(func():
			var res := b.place_model(mid)
			if not bool(res.ok):
				b.toast.emit(str(res.message)))
		row.add_child(btn)
		var tris := int(e.get("triangles", 0))
		var info := UiKit.label("%s%s\n%s" % [str(e.get("format", "")), "" if tris <= 0 else ", %s tri." % ModelLoader.count_text(tris), WebPages.size_text(int(e.size))], true, UITheme.FONT_TINY)
		info.custom_minimum_size = Vector2(110, 0)
		info.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(info)
		row.add_child(_bin("model" + mid, "Press again to delete \"%s\" from the headset." % e.name, func():
			b.models.remove(mid)
			b.toast.emit("Deleted \"%s\"" % e.name)))


## The pictures on the headset: tap one to drop it on a canvas (its ghost follows the pointer), the bin (pressed twice) removes it.
func _refresh_images() -> void:
	var b: Board = shell.board
	UiKit.clear(_image_list)
	var list := b.images.list()
	if list.is_empty():
		UiKit.note(_image_list, "No pictures yet. Drop a PNG, JPEG or WebP on the web page (Share), or send a photo to your Telegram bot: point at a canvas and tap to drop it there.")
		return
	for e in list:
		var iid: String = e.id
		var row := UiKit.hrow(_image_list, 6)
		var btn := Btn.new("canvas", str(e.name))
		btn.align = HORIZONTAL_ALIGNMENT_LEFT
		btn.small = true
		btn.custom_minimum_size = Vector2(0, 58)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.hint = "Drop it on a canvas"
		btn.pressed.connect(func():
			var res := b.begin_place_image(iid)
			if not bool(res.ok):
				b.toast.emit(str(res.message)))
		row.add_child(btn)
		var info := UiKit.label("%d x %d
%s" % [int(e.get("w", 0)), int(e.get("h", 0)), WebPages.size_text(int(e.size))], true, UITheme.FONT_TINY)
		info.custom_minimum_size = Vector2(110, 0)
		info.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(info)
		row.add_child(_bin("image" + iid, "Press again to delete \"%s\" from the headset." % e.name, func():
			b.images.remove(iid)
			b.toast.emit("Deleted \"%s\"" % e.name)))


## The PDFs on the headset: tap one to put it in front of you, the bin (pressed twice) removes it.
func _refresh_pdfs() -> void:
	var b: Board = shell.board
	UiKit.clear(_pdf_list)
	var list := b.pdfs.list()
	if list.is_empty():
		UiKit.note(_pdf_list, "No PDFs yet. Switch on the web page in Share, open it on your PC and drop a PDF on it: it arrives here and is put in front of you, one page at a time, to read and to draw on.")
		return
	for e in list:
		var pid: String = e.id
		var row := UiKit.hrow(_pdf_list, 6)
		var btn := Btn.new("pdf", str(e.name))
		btn.align = HORIZONTAL_ALIGNMENT_LEFT
		btn.small = true
		btn.custom_minimum_size = Vector2(0, 58)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.hint = "Put it in front of you"
		btn.pressed.connect(func():
			var res := b.place_pdf(pid)
			if not bool(res.ok):
				b.toast.emit(str(res.message)))
		row.add_child(btn)
		var info := UiKit.label("%d page%s
%s" % [int(e.pages), "" if int(e.pages) == 1 else "s", WebPages.size_text(int(e.size))], true, UITheme.FONT_TINY)
		info.custom_minimum_size = Vector2(110, 0)
		info.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(info)
		row.add_child(_bin("pdf" + pid, "Press again to delete \"%s\" from the headset." % e.name, func():
			b.pdfs.remove(pid)
			b.toast.emit("Deleted \"%s\"" % e.name)))


func _rename_doc() -> void:
	var b: Board = shell.board
	if b.doc == null:
		return
	shell.ask_name("Rename document", b.doc.name, func(t: String):
		b.doc.rename(t)
		_lists_sig = "")


func _export(kind_id: String) -> void:
	var b: Board = shell.board
	if b.doc == null:
		return
	b.flush_save()
	var res: Dictionary
	match kind_id:
		"svg":
			res = Exporter.svg(b.doc, {"background": "white", "grid": false})
		"glb":
			res = Exporter.glb(b.doc)
		_:
			res = Exporter.document(b.doc)
	_export_label.text = str(res.message)
	b.toast.emit(str(res.message))

func _send_telegram(kind_id: String) -> void:
	var res := (shell.board as Board).telegram.send_export(kind_id)
	_export_label.text = str(res.message)
	shell.board.toast.emit(str(res.message))


func _refresh_docs() -> void:
	var b: Board = shell.board
	UiKit.clear(_docs_list)
	for s in DocStore.list():
		var is_cur: bool = s.id == b.doc.id
		var row := UiKit.hrow(_docs_list, 6)
		var d := Time.get_datetime_dict_from_unix_time(int(s.modified))
		var btn := Btn.new("doc", str(s.name))
		btn.align = HORIZONTAL_ALIGNMENT_LEFT
		btn.small = true
		btn.custom_minimum_size = Vector2(0, 58)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.on = is_cur
		var sid: String = s.id
		btn.pressed.connect(func():
			if not is_cur:
				b.flush_save()
				b.open_id(sid))
		row.add_child(btn)
		var info := UiKit.label("%d canvas%s\n%02d-%02d  %02d:%02d" % [s.frames, "" if int(s.frames) == 1 else "es", d.month, d.day, d.hour, d.minute], true, UITheme.FONT_TINY)
		info.custom_minimum_size = Vector2(110, 0)
		info.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(info)
		if not is_cur:
			row.add_child(_bin(sid, "Press again to delete \"%s\"." % s.name, func():
				for a in DocStore.delete(sid):
					b.anchors.erase(a)
				b.toast.emit("Deleted \"%s\"" % s.name)))


## A bin that asks for a second press (a stray pinch must not delete a document, a canvas or a room).
func _bin(key: String, ask: String, act: Callable) -> Btn:
	var del := UiKit.tool("trash", "Delete", func():
		if _confirm == key:
			_confirm = ""
			act.call()
		else:
			_confirm = key
			shell.board.toast.emit(ask)
		_lists_sig = "", 52.0)
	del.danger = true
	del.on = _confirm == key
	del.accent = UITheme.BAD
	return del


# ------------------------------------------------------------------------------------------------ canvases

func _build_canvas(p: VBoxContainer) -> void:
	var r := UiKit.hrow(p, 8)
	r.add_child(UiKit.button("canvas", "New on a wall", func(): shell.board.begin_place("wall", Popover.SIZES[shell.canvas_size_idx][2]), 52.0))
	r.add_child(UiKit.button("canvas", "New on a table", func(): shell.board.begin_place("table", Popover.SIZES[shell.canvas_size_idx][2]), 52.0))
	var rd := UiKit.hrow(p, 8)
	var desk := UiKit.button("desk", "New on my desk", func(): shell.board.surface.begin("", Popover.SIZES[shell.canvas_size_idx][2]), 52.0)
	desk.tint = UITheme.DESK
	rd.add_child(desk)
	var curved := UiKit.button("curve", "New curved desk", func(): shell.board.surface.begin("", DeskBend.DEFAULT_SIZE, true), 52.0)
	curved.tint = UITheme.DESK
	rd.add_child(curved)
	UiKit.header(p, "In this room")
	_canvas_list = UiKit.vcol(p, 6)
	UiKit.header(p, "Selected canvas")
	_canvas_style = UiKit.vcol(p, 10)


func _refresh_canvas() -> void:
	var b: Board = shell.board
	UiKit.clear(_canvas_list)
	var frames := b.doc.frames_in(b.current_room)
	if frames.is_empty():
		UiKit.note(_canvas_list, "No canvases in this room yet: Add (+) on the toolbar places one.")
	for f in frames:
		var fd: FrameData = f
		var fid := fd.id
		var row := UiKit.hrow(_canvas_list, 4)
		var nb := Btn.new("canvas" if fd.kind == FrameData.CANVAS else ("model" if fd.is_model() else "volume"), fd.name)
		nb.align = HORIZONTAL_ALIGNMENT_LEFT
		nb.small = true
		nb.custom_minimum_size = Vector2(0, 54)
		nb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nb.on = b.active_frame == fid or b.model_ctl.selected == fid
		nb.pressed.connect(func():
			if fd.is_model():
				b.model_ctl.select(fid)                      # its handles and its bar appear
			else:
				b.active_frame = fid
			_lists_sig = "")
		row.add_child(nb)
		row.add_child(UiKit.tool("text", "Rename", func(): shell.ask_name("Rename model" if fd.is_model() else "Rename canvas", fd.name, func(t: String): b.rename_frame(fid, t)), 52.0))
		if fd.is_model():
			row.add_child(UiKit.tool("pin", "Bring it to me", func(): b.bring_model(fid), 52.0))
		if fd.kind == FrameData.CANVAS:
			var dk := UiKit.tool("desk", "Free it from the desk" if fd.surface else "Lay it on the desk: feel for the desk with the stylus tip",
				func(): _toggle_desk(fid), 52.0)
			dk.on = fd.surface
			dk.accent = UITheme.DESK
			row.add_child(dk)
			if fd.surface and not fd.is_pdf():
				var cv := UiKit.tool("curve", "Flatten it again" if fd.bend else "Curve it: it bends up at the end of your desk and climbs the wall",
					func(): b.curve_frame(fid, not fd.bend), 52.0)
				cv.on = fd.bend
				cv.accent = UITheme.DESK
				row.add_child(cv)
		var vis := UiKit.tool("eye_off" if fd.hidden else "eye", "Show it again" if fd.hidden else "Visible: press to hide it (it stays in the document)",
			func(): b.set_frame_prop(fid, "hidden", not fd.hidden), 52.0)
		vis.on = not fd.hidden
		row.add_child(vis)
		var pl := UiKit.tool("lock_place", "Unlock its place" if fd.place_locked else "Lock its place: it stays where it is, facing the same way; two hands still resize it",
			func(): b.set_frame_prop(fid, "place_locked", not fd.place_locked), 52.0)
		pl.on = fd.place_locked
		row.add_child(pl)
		var lk := UiKit.tool("lock", "Lock", func(): b.set_frame_prop(fid, "locked", not fd.locked), 52.0)
		lk.on = fd.locked
		row.add_child(lk)
		if not fd.is_model():
			row.add_child(UiKit.tool("erase", "Clear", func(): b.clear_frame(fid), 52.0))
		row.add_child(_bin(fid, "Press the bin again to delete \"%s\" (undo brings it back)." % fd.name, func(): b.delete_frame(fid)))
	UiKit.clear(_canvas_style)
	var active: FrameData = b.doc.frames.get(b.active_frame)
	if active == null or active.kind != FrameData.CANVAS:
		UiKit.note(_canvas_style, "Touch a canvas with the stylus, or pick one above.")
		return
	var aid := active.id
	_canvas_style.add_child(UiKit.label(active.name, false, UITheme.FONT, 600))
	var c := UiKit.card(_canvas_style)
	UiKit.header(c, "Grid")
	_dyn.segmented(c, [["", "Default"], ["lines", "Lines"], ["dots", "Dots"], ["none", "None"]],
		func(): return (b.doc.frames.get(aid) as FrameData).grid if b.doc.frames.has(aid) else "", func(v): b.set_frame_prop(aid, "grid", v))
	UiKit.header(c, "Backing")
	_dyn.segmented(c, [["", "Default"], ["none", "None"], ["glass", "Glass"], ["dark", "Dark"], ["white", "White"]],
		func(): return (b.doc.frames.get(aid) as FrameData).backing if b.doc.frames.has(aid) else "", func(v): b.set_frame_prop(aid, "backing", v))
	var hb := UiKit.hrow(_canvas_style, 8)
	hb.add_child(UiKit.button("canvas", "Reset size", func():
		var fr: FrameData = b.doc.frames.get(aid)
		if fr != null:
			var upd := fr.copy()
			upd.scale = 1.0
			b.history.do(History.op_frame(fr, upd)), 52.0))
	hb.add_child(UiKit.button("pin", "Bring to me", func(): _bring_to_me(aid), 52.0))
	if active.bend:
		var cc := UiKit.card(_canvas_style)
		UiKit.header(cc, "Curved desk")
		var al := UiKit.button("curve", "Line it up with my desk", func(): b.surface.begin_align(aid), 52.0)
		al.tint = UITheme.DESK
		cc.add_child(al)
		UiKit.note(cc, "Touch the desk's front edge in front of you, then the wall behind it: the canvas starts at the edge and climbs the wall.")
		_stepper(cc, "Bends at", "from your edge", func(): return (b.doc.frames[aid] as FrameData).bend_at, 0.05,
			func(v: float): b.set_bend(aid, v, (b.doc.frames[aid] as FrameData).bend_radius))
		_stepper(cc, "Radius", "of the bend", func(): return (b.doc.frames[aid] as FrameData).bend_radius, 0.02,
			func(v: float): b.set_bend(aid, (b.doc.frames[aid] as FrameData).bend_at, v))
		UiKit.note(cc, "Or move the two round markers on the canvas's left edge. Push the contents away from you with a pinch (or the stylus front button) on the canvas.")
	if active.surface:
		var ub := UiKit.button("desk", "Free it and stand it upright", func(): b.surface.release(aid, true), 52.0)
		ub.tint = UITheme.DESK
		_canvas_style.add_child(ub)


## A number in centimetres with a minus and a plus (one undo step per press).
func _stepper(parent: Control, title: String, sub: String, getter: Callable, step: float, setter: Callable) -> void:
	var row := UiKit.hrow(parent, 8)
	var texts := UiKit.vcol(row, 0)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_child(UiKit.label(title, false, UITheme.FONT_SMALL, 600))
	texts.add_child(UiKit.label(sub, true, UITheme.FONT_SMALL))
	row.add_child(UiKit.chip("-", func(): setter.call(float(getter.call()) - step), "", 48.0))
	var v := UiKit.label("", false, UITheme.FONT, 600)
	v.custom_minimum_size = Vector2(84, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(v)
	row.add_child(UiKit.chip("+", func(): setter.call(float(getter.call()) + step), "", 48.0))
	_dyn.syncers.append(func(): v.text = "%d cm" % roundi(float(getter.call()) * 100.0))


## A canvas on the desk is let go of it; any other feels for the desk with the stylus tip and lies down on it.
func _toggle_desk(frame_id: String) -> void:
	var b: Board = shell.board
	var fd: FrameData = b.doc.frames.get(frame_id)
	if fd == null:
		return
	if fd.surface:
		b.surface.release(frame_id)
	else:
		b.surface.begin(frame_id)


func _bring_to_me(frame_id: String) -> void:
	var b: Board = shell.board
	var fd: FrameData = b.doc.frames.get(frame_id)
	if fd == null:
		return
	if fd.surface:
		b.toast.emit("That canvas lies on your desk: it stays there. Free it from the desk first.")
		return
	var h := b.head
	var pos := h.origin + (-h.basis.z) * 0.9
	pos.y = clampf(pos.y - 0.1, 0.6, 1.8)
	var yaw := atan2(h.origin.x - pos.x, h.origin.z - pos.z)
	var rw: Variant = b.room_world(fd.room)
	var world := Transform3D(Basis(Vector3.UP, yaw), pos)
	var upd := fd.copy()
	upd.xf = (rw as Transform3D).affine_inverse() * world if rw != null else world
	b.history.do(History.op_frame(fd, upd))


# ------------------------------------------------------------------------------------------------ rooms

func _build_rooms(p: VBoxContainer) -> void:
	var c := UiKit.card(p)
	_room_card = UiKit.label("", false, UITheme.FONT_SMALL, 500)
	c.add_child(_room_card)
	UiKit.note(c, "Each room is remembered by a spatial anchor: canvases stay where you left them and come back when you return.")
	var r := UiKit.hrow(p, 8)
	r.add_child(UiKit.button("room", "New room here", func(): shell.board.create_room_here(), 52.0))
	r.add_child(UiKit.button("anchor", "Re-anchor", func(): shell.board.reanchor_room(), 52.0))
	UiKit.header(p, "Rooms in this document")
	_rooms_list = UiKit.vcol(p, 6)
	_sim_box = UiKit.vcol(p, 8)
	UiKit.header(_sim_box, "PC test: simulated room")
	_kit.segmented(_sim_box, [["A", "Room A"], ["B", "Room B"], ["C", "Room C"]], func(): return App.val("sim_room"), func(v): App.put("sim_room", v))
	UiKit.note(_sim_box, "Like walking through a door in the headset: the other rooms' canvases disappear.")


func _refresh_rooms() -> void:
	var b: Board = shell.board
	var cur := b.doc.room(b.current_room)
	match b.room_state:
		"found":
			_room_card.text = "You are in \"%s\"" % cur.get("name", "this room")
			_room_card.add_theme_color_override("font_color", UITheme.GOOD)
		"searching":
			_room_card.text = b.session.align_text() if b.session.is_client() else "Looking for a room you have used before..."
			_room_card.add_theme_color_override("font_color", UITheme.WARN)
		"assumed":
			_room_card.text = "\"%s\" is shown in front of you: its anchors were not found here. Re-anchor keeps it here; New room here starts an empty one." % cur.get("name", "The room")
			_room_card.add_theme_color_override("font_color", UITheme.WARN)
		"unanchored":
			_room_card.text = "Spatial anchors are not available: content will not stay in place between sessions."
			_room_card.add_theme_color_override("font_color", UITheme.BAD)
		_:
			_room_card.text = "Setting up the first room..."
			_room_card.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_sim_box.visible = b.anchors is SimAnchors
	UiKit.clear(_rooms_list)
	for r in b.doc.rooms:
		var room: Dictionary = r
		var rid: String = room.id
		var here: bool = rid == b.current_room
		var row := UiKit.hrow(_rooms_list, 4)
		var rb := Btn.new("room", "%s%s" % [room.name, "  (here)" if here else ""])
		rb.align = HORIZONTAL_ALIGNMENT_LEFT
		rb.small = true
		rb.custom_minimum_size = Vector2(0, 54)
		rb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rb.on = here
		rb.pressed.connect(func(): b.select_room(rid))
		row.add_child(rb)
		row.add_child(UiKit.tool("text", "Rename", func(): shell.ask_name("Rename room", room.name, func(t: String): b.rename_room(rid, t)), 52.0))
		row.add_child(_bin(rid, "Press the bin again: this deletes the room and everything in it.", func(): b.delete_room(rid)))


# ------------------------------------------------------------------------------------------------ share

func _build_share(p: VBoxContainer) -> void:
	var c := UiKit.card(p)
	_share_switch = Switch.new("Web page on the Wi-Fi", "View, download and upload canvases from a PC")
	_share_switch.toggled.connect(_set_sharing)
	c.add_child(_share_switch)
	_share_code = UiKit.label("", false, UITheme.FONT_BIG, 600)
	_share_code.add_theme_color_override("font_color", UITheme.GOOD)
	c.add_child(_share_code)
	_share_label = UiKit.label("", true, UITheme.FONT_SMALL)
	c.add_child(_share_label)


func _set_sharing(on: bool) -> void:
	var b: Board = shell.board
	if on == b.share.is_running():
		return
	App.put("share_on", on)
	if on:
		if not b.share.start():
			b.toast.emit("Could not start the web server (no free port).")
	else:
		b.share.stop()
	_sync_share()


func _sync_share() -> void:
	var b: Board = shell.board
	var on := b.share.is_running()
	_share_switch.on = on
	_share_code.visible = on
	if not on:
		_share_label.text = "Switch on, open the address in a browser on a PC on the same Wi-Fi and type the access code. There you see, download and delete the canvases, upload SVG files (they arrive here as canvases), set up the assistant, and follow what you draw in the live view."
		return
	_share_code.text = "Code  %s" % b.share.pin_text()
	var urls := b.share.urls()
	if urls.is_empty():
		_share_label.text = "Waiting for a Wi-Fi connection: the address appears here (port %d)." % b.share.port
		return
	_share_label.text = "On your PC open:\n%s\n\nAnyone on this network who knows the code can change your canvases while this is on. It stays on, with a new code, the next time the app starts, until you switch it off." % "\n".join(urls.slice(0, 3))


## Telegram, under the web page: the bot token, the code that links a chat, and what the connection is doing (TelegramBridge).
func _build_telegram(p: VBoxContainer) -> void:
	UiKit.header(p, "Telegram")
	var c := UiKit.card(p)
	_tg_switch = Switch.new("Telegram", "Files from your phone to the headset, and exports back")
	_tg_switch.toggled.connect(func(v: bool): App.put("tg_on", v))
	c.add_child(_tg_switch)
	_tg_token_btn = UiKit.button("keyboard", "", func():
		shell.ask_secret("Telegram bot token (from @BotFather)", func(t: String):
			var k := t.strip_edges()
			if k != "" and not TelegramApi.is_token(k):
				shell.board.toast.emit("That does not look like a bot token: a number, a colon and a long code.")
				return
			App.put("tg_token", k)), 52.0, "ghost")
	c.add_child(_tg_token_btn)
	_tg_code = UiKit.label("", false, UITheme.FONT_BIG, 600)
	_tg_code.add_theme_color_override("font_color", UITheme.GOOD)
	c.add_child(_tg_code)
	_tg_label = UiKit.label("", true, UITheme.FONT_SMALL)
	c.add_child(_tg_label)
	_tg_unlink = UiKit.button("close", "", func():
		if _confirm == "tg_unlink":
			_confirm = ""
			(shell.board as Board).telegram.unlink()
			shell.board.toast.emit("Telegram unlinked: send the new code from the chat you want to link.")
		else:
			_confirm = "tg_unlink"
			shell.board.toast.emit("Press again to unlink the chat.")
		_sync_telegram(), 52.0, "ghost")
	c.add_child(_tg_unlink)


func _sync_telegram() -> void:
	var tg: TelegramBridge = (shell.board as Board).telegram
	var tok := tg.token()
	var bot := tg.bot()
	_tg_switch.on = bool(App.val("tg_on"))
	if tok == "":
		_tg_token_btn.text = "Set the bot token"
	elif bot != "":
		_tg_token_btn.text = "Bot @%s (...%s): change it" % [bot, tok.right(4)]
	else:
		_tg_token_btn.text = "Token saved (...%s): change it" % tok.right(4)
	_tg_code.visible = tg.state == "unlinked" and tg.code != ""
	_tg_code.text = "Code  %s" % tg.code_text()
	_tg_unlink.visible = tg.linked_chat() != ""
	_tg_unlink.text = "Press again to unlink" if _confirm == "tg_unlink" else "Unlink %s" % str(App.val("tg_who"))
	_tg_send.visible = tg.is_linked()
	var s := ""
	match tg.state:
		"off":
			if tok == "":
				s = "Make a bot: in Telegram open @BotFather, send /newbot and give it a name and a username that ends in \"bot\". Paste the token it gives you on the web page (API keys) or set it here."
			else:
				s = "Switched off: the headset does not read the bot's messages."
		"checking":
			s = "Checking the token with Telegram..."
		"unlinked":
			s = "In Telegram open @%s, press Start and send it the code above. Only that chat is linked: the bot ignores everyone else." % bot
		"linked":
			s = "Linked to %s through @%s. Send the bot a PDF, an SVG, a 3D model or a .mrw file and it appears here; text you send can be put on a canvas. /svg, /glb or /mrw in the chat, or Docs > Send to Telegram, get files back." % [str(App.val("tg_who")), bot]
		"offline":
			s = "No connection to Telegram, trying again. (%s)" % tg.error
		_:
			s = tg.error
	if tg.busy != "":
		s = tg.busy + "\n\n" + s
	_tg_label.text = s


# ------------------------------------------------------------------------------------------------ settings

func _build_settings(p: VBoxContainer) -> void:
	UiKit.header(p, "Handwriting")
	var hw := UiKit.card(p)
	_kit.segmented(hw, [["google", "Online reading"], ["none", "Off"]], func(): return App.val("ink_provider"), func(v): App.put("ink_provider", v))
	_kit.switch(hw, "Convert after a pause", "ink_auto", "Otherwise only when you press To text")
	_kit.slider(hw, "Pause before converting", 1.0, 5.0, "ink_pause", 0.25, func(v: float): return "%.1f s" % v)
	UiKit.header(hw, "Writing with the pen tool")
	_kit.segmented(hw, [["suggest", "Offer"], ["auto", "Convert"], ["off", "Off"]], func(): return App.val("smart_ink"), func(v): App.put("smart_ink", v))
	UiKit.note(hw, "Handwriting goes to Google's handwriting service (only the pen strokes). Writing a little larger and slower helps.")

	UiKit.header(p, "Pen and hands")
	var ph := UiKit.card(p)
	_kit.segmented(ph, [["auto", "Stylus hand: auto"], ["left", "Left"], ["right", "Right"]], func(): return App.val("stylus_hand"), func(v): App.put("stylus_hand", v))
	_kit.switch(ph, "Stylus model", "stylus_model", "Logitech's MX Ink drawn over the real stylus")
	_kit.switch(ph, "Pointing line", "stylus_ray", "A beam from the stylus to what it points at")
	_kit.switch(ph, "Feedback", "haptics", "Stylus haptics and click sounds for pinches")
	_kit.switch(ph, "Draw with a pinch", "finger_draw", "When there is no stylus")
	_kit.slider(ph, "Hold still to snap", 0.25, 1.2, "hold_seconds", 0.05, func(v: float): return "%.2f s" % v)

	UiKit.header(p, "Speech to text")
	var sp := UiKit.card(p)
	_kit.segmented(sp, [["wit", "Wit.ai"], ["none", "Off"]], func(): return App.val("speech_provider"), func(v): App.put("speech_provider", v))
	_token_btn = UiKit.button("keyboard", "", func():
		shell.ask_secret("Wit.ai server access token", func(t: String): App.put("wit_token", t.strip_edges())), 52.0, "ghost")
	sp.add_child(_token_btn)
	_kit.syncers.append(func():
		var tok := str(App.val("wit_token"))
		_token_btn.text = ("Token saved (...%s): change it" % tok.right(4)) if tok != "" else "Set the Wit.ai token")
	UiKit.note(sp, "Free at wit.ai: create an app and copy its Server Access Token. Speech goes to Wit.ai only while you dictate.")

	UiKit.header(p, "Canvas defaults")
	var cd := UiKit.card(p)
	_kit.segmented(cd, [["lines", "Lines"], ["dots", "Dots"], ["none", "No grid"]], func(): return App.val("grid"), func(v): App.put("grid", v))
	_kit.segmented(cd, [["none", "Clear"], ["glass", "Glass"], ["dark", "Dark"], ["white", "White"]], func(): return App.val("backing"), func(v): App.put("backing", v))
	_kit.slider(cd, "Grid fades out at", 1.0, 5.0, "grid_fade_viewer", 0.25, func(v: float): return "%.1f m" % v)
	_kit.slider(cd, "Grid light around the stylus", 0.25, 1.2, "grid_focus", 0.05, func(v: float): return "%.2f m" % v)

	UiKit.header(p, "3D models")
	var md := UiKit.card(p)
	_kit.segmented(md, [["soft", "Soft light"], ["studio", "Studio"], ["bright", "Bright"]], func(): return App.val("model_light"), func(v): App.put("model_light", v))
	_kit.switch(md, "Shadow under models", "model_shadow", "A soft shadow on the table or floor under each model")

	UiKit.header(p, "Display")
	var dp := UiKit.card(p)
	_kit.slider(dp, "Interface size", 0.7, 1.6, "ui_scale", 0.05, func(v: float): return "%d %%" % int(v * 100.0))
	_kit.switch(dp, "On-screen keyboard", "vkeyboard", "Otherwise a pad to write on")
	_kit.switch(dp, "Fade the interface while drawing", "ui_fade")
	_kit.switch(dp, "Keep running when taken off", "keep_awake", "The headset ignores its sensor: the screen stays on and the battery runs down" if ProximitySensor.available() else "Quest only: the headset ignores its sensor")
	_kit.switch(dp, "Show spatial anchors", "show_anchors", "Axes and a label where the headset holds the rooms, canvases and panels in place")

	UiKit.header(p, "How to use it")
	var hu := UiKit.card(p)
	hu.add_child(UiKit.button("help", "Open the guide: every feature, step by step", func(): select_tab("guide"), 52.0))
	UiKit.note(hu, "Stylus tip: the current tool. Hold still at the end of a stroke to snap it to a clean shape.\nFront button = grab (like a pinch): an item, the bar under a canvas, a corner. Back button: undo; with the front button held: redo.\nHands: point (a ring shows where) and pinch, or touch with the pinch. Hands arrange, the stylus draws.\nThe toolbar: open your palm facing up, or hold the stylus front button away from canvases, to bring it in front of you. Grab the bar under a panel to move it.")
	if not App.xr_active:
		UiKit.note(hu, "PC: left mouse = stylus, Shift+left = front button, middle mouse = pinch (wheel scales, Q / E turn), right mouse = look, WASD = walk, 1-5 tools, B brush, T type, C canvas, Tab hides the interface, Esc closes panels.")


# ------------------------------------------------------------------------------------------------ quit

## Quit needs two presses (a stray pinch must not close the app); the document is saved first.
func _on_quit() -> void:
	if _quit_armed <= 0.0:
		_quit_armed = 3.0
		quit_btn.text = "Sure?"
		return
	var b: Board = shell.board
	if b != null and b.doc != null:
		b.flush_save()
	get_tree().quit()


func tick_quit(delta: float) -> void:
	_process(delta)
