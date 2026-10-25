extends Node
## A PDF as a canvas on a real board: put down in front of you, its page on it, turning pages (and what that does to drawings, undo, saving),
## a guest turning pages for themselves, drawings that belong to a page, keys, the page bar, and what a missing file looks like.

const FIX := "res://tests/fixtures/pdf/"

var t := TestCase.new("pdf_canvas")
var board: Board
var anchors: SimAnchors


func _ready() -> void:
	App.settings_path = "user://test_settings_pdf_canvas.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_pdf_canvas"
	App.pdf_dir = "user://test_pdfs_canvas"
	_clean(App.docs_dir)
	_clean(App.pdf_dir)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_pdf_canvas.json"))
	anchors = SimAnchors.new("user://test_sim_anchors_pdf_canvas.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.pdfs.threaded = false
	var doc := Document.create("Reading")
	doc.add_room("Studio")
	board.open(doc)
	for i in 5:
		await get_tree().process_frame
		board.tick(PenState.new(), [], 0.016)
	await _placing()
	await _turning()
	await _drawings()
	await _saving()
	_keys_and_bar()
	await _missing()
	_clean(App.docs_dir)
	_clean(App.pdf_dir)
	get_tree().quit(t.done())


func _clean(dir: String) -> void:
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


func _wait_state(fn: FrameNode, state: String, seconds: float = 8.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while fn.pdf_state != state and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	return fn.pdf_state == state


func _add(name: String) -> String:
	var r := board.pdfs.add(FileAccess.get_file_as_bytes(FIX + name), name)
	return str(r.id)


func _placing() -> void:
	var id := _add("base14.pdf")
	var res := board.place_pdf(id)
	t.check(bool(res.ok), "a PDF is put down: %s" % str(res.message))
	var f: FrameData = board.doc.frames[str(res.id)]
	t.check(f.is_pdf() and f.pdf == id and f.page == 1 and f.pdf_pages == 2, "the canvas names the PDF, the page and how many pages")
	t.check(f.kind == FrameData.CANVAS and f.name == "base14", "it is an ordinary canvas, named after the file")
	t.near(f.size.x / f.size.y, 300.0 / 200.0, 0.01, "its shape is the page's")
	t.check(f.size.x <= 1.2 and f.size.y <= 1.2 and f.size.x > 0.5, "put down at a size one can read from (%s m)" % str(f.size))
	var fn: FrameNode = board.frame_nodes[f.id]
	t.check(await _wait_state(fn, "ready"), "the page arrives on the canvas")
	t.check(fn.page_rect().size.is_equal_approx(Vector2(f.pdf_width, f.pdf_width * 200.0 / 300.0)), "the page fills the canvas: %s" % str(fn.page_rect().size))
	t.check(not fn._grid.visible, "no grid under a page")
	# the page bar belongs to the PDF in view
	board.head = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	board._place_frames(0.016)
	t.check(board.current_pdf_frame() == fn, "the page bar's canvas is the PDF in view")
	var again := board.place_pdf("0123456789abcdef0123456789abcdef")
	t.check(not bool(again.ok), "a PDF that is not in the library is not put down")
	var second := board.place_pdf(id)
	t.check(bool(second.ok) and board.doc.frames[str(second.id)].name == "base14 (2)", "put down again, the canvas gets another name")


func _turning() -> void:
	var fid := _first_pdf_frame()
	var fn: FrameNode = board.frame_nodes[fid]
	var f: FrameData = board.doc.frames[fid]
	var size1 := f.size
	t.check(board.pdf_turn(fid, 2), "the page is turned")
	f = board.doc.frames[fid]
	t.check(f.page == 2 and board.doc.page_of(fid) == 2, "the canvas is on page 2 for everybody")
	t.near(f.size.x / f.size.y, 400.0 / 220.0, 0.01, "and takes the shape of that page, at the same width")
	t.near(f.size.x, size1.x, 0.001, "(the width is kept)")
	t.check(await _wait_state(fn, "ready"), "the new page arrives")
	t.check(fn._pdf_key.ends_with(":2"), "and it is page 2 that is shown")
	board.pdf_turn(fid, 99)
	t.eq(board.doc.frames[fid].page, 2, "there is no page 99: it stays on the last one")
	board.pdf_turn(fid, -4)
	t.eq(board.doc.frames[fid].page, 1, "nor page -4: the first")
	# undo does not turn pages back
	board.history.do(History.op_frame(board.doc.frames[fid], _moved(board.doc.frames[fid])))
	board.pdf_turn(fid, 2)
	board.undo()
	t.eq(board.doc.frames[fid].page, 2, "undoing a move does not turn the page back")
	board.pdf_turn(fid, 1)


func _moved(f: FrameData) -> FrameData:
	var m := f.copy()
	m.xf = Transform3D(m.xf.basis, m.xf.origin + Vector3(0.1, 0, 0))
	return m


func _first_pdf_frame() -> String:
	for f in board.doc.frames.values():
		if (f as FrameData).is_pdf():
			return (f as FrameData).id
	return ""


func _stroke(frame_id: String) -> Item:
	var pts := PackedFloat32Array([0.0, 0.0, 0.0, 1.0, 0.1, 0.1, 0.0, 1.0])
	return Item.make_stroke(frame_id, pts, Color.RED, 0.004, "pen")


func _drawings() -> void:
	var fid := _first_pdf_frame()
	var fn: FrameNode = board.frame_nodes[fid]
	var a := _stroke(fid)
	board.history.do(History.op_add([a]))
	t.eq((board.doc.items[a.id] as Item).page, 1, "a drawing on page 1 belongs to page 1")
	t.eq(fn.views.size(), 1, "and is shown there")
	board.pdf_turn(fid, 2)
	t.eq(fn.views.size(), 0, "on page 2 it is not shown")
	t.eq(board.doc.items_of(fid).size(), 0, "nor does anything else (pick, erase, export) find it there")
	var b := _stroke(fid)
	board.history.do(History.op_add([b]))
	t.eq((board.doc.items[b.id] as Item).page, 2, "a drawing on page 2 belongs to page 2")
	t.check(board.doc.items_all_of(fid).size() == 2, "the document holds both")
	board.pdf_turn(fid, 1)
	t.check(fn.views.size() == 1 and fn.views.has(a.id) and not fn.views.has(b.id), "back on page 1 its own drawing is back")
	# a selection does not follow to another page
	board.select_items([a.id], fid)
	board.pdf_turn(fid, 2)
	t.check(board.selection.is_empty(), "turning the page lets go of the selection")
	# clearing a page clears that page
	board.clear_frame(fid)
	t.check(board.doc.items.has(a.id) and not board.doc.items.has(b.id), "clearing the canvas clears the page shown, not the others")
	# the whole canvas goes with all of its drawings
	var spare := board.place_pdf(board.doc.frames[fid].pdf)
	var sid: String = spare.id
	board.pdf_turn(sid, 2)
	board.history.do(History.op_add([_stroke(sid)]))
	board.pdf_turn(sid, 1)
	board.history.do(History.op_add([_stroke(sid)]))
	var before := board.doc.items.size()
	board.delete_frame(sid)
	t.eq(board.doc.items.size(), before - 2, "deleting the canvas takes the drawings of every page")
	board.undo()
	t.check(board.doc.items.size() == before and board.doc.frames.has(sid), "and undo brings the canvas and both drawings back")
	t.eq(board.doc.frames[sid].page, 1, "on the page it was on")
	board.pdf_turn(fid, 1)


func _saving() -> void:
	var fid := _first_pdf_frame()
	board.pdf_turn(fid, 2)
	var copy := Document.from_dict(JSON.parse_string(JSON.stringify(board.doc.to_dict())))
	var f: FrameData = copy.frames[fid]
	t.check(f.pdf == board.doc.frames[fid].pdf and f.page == 2 and f.pdf_pages == 2 and f.pdf_width > 0.0, "the PDF, the page and the width survive saving")
	var drawn := 0
	for it in copy.items.values():
		if (it as Item).page > 0:
			drawn += 1
	t.check(drawn >= 1, "and so do the pages the drawings belong to")
	var plain := FrameData.make(FrameData.CANVAS, "", Transform3D.IDENTITY, "Plain")
	t.check(not plain.to_dict().has("pdf") or str(plain.to_dict().pdf) == "", "an ordinary canvas names no PDF")
	var old := FrameData.from_dict({"id": "f1", "kind": "canvas"})
	t.check(old.pdf == "" and old.page == 1, "a canvas from an older file is an ordinary canvas")
	board.pdf_turn(fid, 1)


func _keys_and_bar() -> void:
	var fid := _first_pdf_frame()
	board.head = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	board._place_frames(0.016)
	var fn := board.current_pdf_frame()
	t.check(fn != null, "a PDF is in view for the keys")
	if fn == null:
		return
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_PAGEDOWN
	t.check(Shortcuts.edit_key(board, key), "Page Down is taken")
	t.eq(board.doc.page_of(fn.data.id), 2, "and turns to the next page")
	key = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_HOME
	Shortcuts.edit_key(board, key)
	t.eq(board.doc.page_of(fn.data.id), 1, "Home goes to the first page")
	key = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_END
	Shortcuts.edit_key(board, key)
	t.eq(board.doc.page_of(fn.data.id), 2, "End to the last")
	board.pdf_turn(fn.data.id, 1)
	# the bar
	var ui := UiShell.new()
	add_child(ui)
	ui.setup(board)
	ui.refresh_all()
	ui.update(0.5)
	t.check(ui.pdf_bar.wanted and ui.pdf_bar.anchor.frame == fn.data.id, "the page bar is under the PDF in view")
	ui.pdf_bar.refresh()
	t.check(ui.pdf_bar._count.text == "1 / 2" and ui.pdf_bar._prev.disabled and not ui.pdf_bar._next.disabled, "it says 1 / 2, with no way back from the first page")
	ui.pdf_bar._step(1)
	ui.pdf_bar.refresh()
	t.check(ui.pdf_bar._count.text == "2 / 2" and ui.pdf_bar._next.disabled, "Next turns the page")
	ui.pdf_bar._slider.value_changed.emit(1.0)
	t.eq(board.doc.page_of(fn.data.id), 1, "and the slider goes to any page")
	t.check(not ui.pdf_bar._follow.visible, "nobody has turned away, so there is no way back to offer")
	# Home lists the PDFs
	ui.home._refresh_pdfs()
	t.check(ui.home._pdf_list.get_child_count() >= 1, "Home lists the PDFs of the headset")
	ui.queue_free()


func _missing() -> void:
	# a canvas whose PDF is not on this device says so, and shows the page when the file arrives
	var fid := _first_pdf_frame()
	var f: FrameData = board.doc.frames[fid]
	var pdf_id := f.pdf
	var bytes := board.pdfs.file_bytes(pdf_id)
	var asked: Array = []
	board.pdfs.wanted.connect(func(id: String): asked.append(id))
	board.pdfs.remove(pdf_id)
	await get_tree().process_frame
	var fn: FrameNode = board.frame_nodes[fid]
	fn.refresh_pdf()
	t.eq(fn.pdf_state, "missing", "a canvas whose PDF is gone says it is missing")
	t.check(asked.has(pdf_id), "and asks whoever can fetch it (a session) for it")
	t.check(fn._pdf_label.visible and fn.pdf_note != "", "its canvas says so: \"%s\"" % fn.pdf_note)
	board.pdfs.set_progress(pdf_id, "Receiving the PDF... 40 %")
	t.check(fn.pdf_note.contains("40"), "and how far the file has come")
	board.pdfs.set_progress(pdf_id, "")
	var back := board.pdfs.add(bytes, "base14.pdf", true)
	t.check(bool(back.ok) and str(back.id) == pdf_id, "the same file coming back has the same id")
	t.check(await _wait_state(fn, "ready"), "and the page is shown when it has")
