extends Node
## PDFs through the web page: the upload (taken into the library and put in front of the viewer, or only stored), what is refused, the list on the
## dashboard with its buttons, the file itself (shown in the browser or downloaded), renaming and deleting, the size limits of a Quest 3 and a
## Quest 2, and an upload of a few hundred kilobytes in pieces over a real connection.

const FIX := "res://tests/fixtures/pdf/"
const HEAD := {"x-requested-with": "mrw"}

var t := TestCase.new("pdf_web")
var board: Board
var srv: ExportServer


func _ready() -> void:
	App.settings_path = "user://test_settings_pdf_web.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_pdf_web"
	App.pdf_dir = "user://test_pdfs_web"
	_clean(App.pdf_dir)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_pdf_web.json"))
	var anchors := SimAnchors.new("user://test_sim_anchors_pdf_web.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.pdfs.threaded = false
	var doc := Document.create("Web <pdf>")
	doc.add_room("Studio")
	board.open(doc)
	for i in 5:
		await get_tree().process_frame
		board.tick(PenState.new(), [], 0.016)
	srv = board.share
	srv.require_pin = false
	_upload()
	_dashboard()
	_files()
	_changes()
	_limits()
	await _sockets()
	_clean(App.pdf_dir)
	get_tree().quit(t.done())


func _clean(dir: String) -> void:
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


func _bytes(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(FIX + name)


func _post(path: String, body: PackedByteArray) -> Dictionary:
	var res := srv.handle("POST", path, HEAD, body, "x")
	return JSON.parse_string((res.body as PackedByteArray).get_string_from_utf8())


func _body(res: Dictionary) -> String:
	return (res.body as PackedByteArray).get_string_from_utf8()


func _upload() -> void:
	var frames := board.doc.frames.size()
	var j := _post("/api/pdf?name=Lecture%20notes.pdf", _bytes("base14.pdf"))
	t.check(bool(j.ok) and str(j.name) == "Lecture notes" and int(j.pages) == 2 and bool(j.shown), "an uploaded PDF is taken in and put in front of the viewer: %s" % str(j.message))
	t.eq(board.doc.frames.size(), frames + 1, "as a canvas of its own")
	var f: FrameData = board.doc.frames[board.active_frame]
	t.check(f.is_pdf() and f.pdf == str(j.id) and f.name == "Lecture notes", "that shows the PDF")
	t.check(board.pdfs.has(str(j.id)), "and the library has it")
	var again := _post("/api/pdf?name=Lecture%20notes.pdf", _bytes("base14.pdf"))
	t.check(bool(again.ok) and str(again.message).contains("already") and board.doc.frames.size() == frames + 2, "the same file again is not stored twice but is put down again")
	var quiet := _post("/api/pdf?name=Many.pdf&show=0", _bytes("many.pdf"))
	t.check(bool(quiet.ok) and not quiet.has("shown") and board.doc.frames.size() == frames + 2, "show=0 only stores it")
	var bad := srv.handle("POST", "/api/pdf?name=x.pdf", HEAD, "not a pdf".to_utf8_buffer(), "x")
	t.eq(bad.status, 422, "something that is not a PDF is refused (422)")
	t.check(not bool(JSON.parse_string(_body(bad)).ok), "with a reason")
	var locked := srv.handle("POST", "/api/pdf?name=l.pdf", HEAD, _bytes("locked.pdf"), "x")
	t.check(locked.status == 422 and _body(locked).contains("password"), "a PDF that needs a password says so")
	t.eq(srv.handle("POST", "/api/pdf?name=x.pdf", HEAD, PackedByteArray(), "x").status, 400, "an empty body is a bad request")
	t.eq(srv.handle("POST", "/api/pdf?name=x.pdf", {}, _bytes("base14.pdf"), "x").status, 403, "an upload not made from the page itself is refused")
	var enc := _post("/api/pdf?name=e.pdf&show=0", _bytes("aes_256.pdf"))
	t.check(bool(enc.ok), "a restricted PDF (AES-256, opens without a password) is taken in")


func _dashboard() -> void:
	var page := _body(srv.route("/"))
	t.check(page.contains("id=pdfs") and page.contains("PDF documents") and page.contains("Lecture notes"), "the dashboard lists the PDFs")
	t.check(page.contains("data-act=pdf-show") and page.contains("data-act=pdf-delete") and page.contains("data-act=pdf-rename"), "with Show in headset, rename and delete")
	t.check(page.contains("accept='.pdf,application/pdf,.svg") and page.contains("Drop pictures, PDF, SVG or 3D model"), "and the drop box takes PDFs and SVGs (and 3D models and pictures)")
	t.check(page.contains("2</td>") and page.contains("KB"), "with their pages and size")
	var js := _body(srv.handle("GET", "/assets/app.js", {}, PackedByteArray(), "x"))
	t.check(js.contains("/api/pdf?name=") and js.contains("application/pdf") and js.contains("/api/pdf/show"), "the script sends PDFs to the PDF address")
	var rev: Dictionary = JSON.parse_string(_body(srv.route("/api/rev")))
	var before := str(rev.rev)
	board.pdfs.remove(board.pdfs.list()[0].id)
	t.check(str(JSON.parse_string(_body(srv.route("/api/rev"))).rev) != before, "a change to the PDFs changes the revision (the page tells you to refresh)")
	_post("/api/pdf?name=Lecture%20notes.pdf&show=0", _bytes("base14.pdf"))


func _files() -> void:
	var id := ""
	for e in board.pdfs.list():
		if str(e.name) == "Lecture notes":
			id = str(e.id)
	var inline := srv.route("/pdf/%s.pdf" % id)
	t.check(inline.status == 200 and str(inline.type) == "application/pdf" and inline.body == _bytes("base14.pdf"), "the PDF is served as it was stored")
	t.check(not inline.has("download") and str(inline.headers[0]).begins_with("Content-Disposition: inline"), "the browser shows it")
	var dl := srv.route("/pdf/%s.pdf?dl=1" % id)
	t.eq(str(dl.download), "Lecture notes.pdf", "or downloads it under its name")
	t.eq(srv.route("/pdf/00000000000000000000000000000000.pdf").status, 404, "an unknown PDF is 404")
	var wire := srv.answer("GET /pdf/%s.pdf HTTP/1.1\r\n" % id, PackedByteArray(), "x")
	var wire_head := wire.slice(0, 400).get_string_from_utf8()
	t.check(wire_head.contains("Content-Type: application/pdf") and not wire_head.contains("Content-Security-Policy"), "no page policy is put on a PDF (the browser's own viewer must run)")


func _changes() -> void:
	var id := ""
	for e in board.pdfs.list():
		if str(e.name) == "Lecture notes":
			id = str(e.id)
	var shown := board.doc.frames.size()
	var s := _post("/api/pdf/show", JSON.stringify({"id": id}).to_utf8_buffer())
	t.check(bool(s.ok) and board.doc.frames.size() == shown + 1, "Show in headset puts it down again")
	t.check(not bool(_post("/api/pdf/show", JSON.stringify({"id": "nope"}).to_utf8_buffer()).ok), "an unknown PDF cannot be shown")
	var r := _post("/api/pdf/rename", JSON.stringify({"id": id, "name": "  New name "}).to_utf8_buffer())
	t.check(bool(r.ok) and str(r.name) == "New name" and str(board.pdfs.entry(id).name) == "New name", "a PDF is renamed")
	t.eq(srv.handle("POST", "/api/pdf/rename", HEAD, JSON.stringify({"id": id, "name": " "}).to_utf8_buffer(), "x").status, 400, "not to nothing")
	var d := _post("/api/pdf/delete", JSON.stringify({"ids": [id]}).to_utf8_buffer())
	t.check(bool(d.ok) and not board.pdfs.has(id), "a PDF is deleted")
	t.eq(srv.handle("POST", "/api/pdf/delete", HEAD, JSON.stringify({"ids": [id]}).to_utf8_buffer(), "x").status, 404, "and then it is gone")
	var gone_canvas := false
	for f in board.doc.frames.values():
		if (f as FrameData).pdf == id:
			gone_canvas = true
	t.check(gone_canvas, "the canvases that showed it stay (with their drawings), waiting for the file")


func _limits() -> void:
	var plain := ExportServer.new()
	t.eq(plain._body_limit("POST /api/pdf?name=a HTTP/1.1"), ExportServer.MAX_BODY, "without a library the limit is the ordinary one")
	plain.free()
	t.eq(srv._body_limit("POST /api/upload HTTP/1.1"), ExportServer.MAX_BODY, "an SVG stays under the ordinary limit")
	t.eq(srv._body_limit("POST /api/pdf?name=a HTTP/1.1"), 64 * 1048576, "a PDF may be as big as a Quest 3 takes in (64 MB)")
	var low := PdfBudget.for_tier("low")
	var old := board.pdfs.budget
	board.pdfs.budget = low
	t.eq(srv._body_limit("POST /api/pdf HTTP/1.1"), 48 * 1048576, "and as big as a Quest 2 takes in (48 MB)")
	var big := PackedByteArray()
	big.resize(49 * 1048576)
	var res := srv.handle("POST", "/api/pdf?name=big.pdf", HEAD, big, "x")
	t.check(res.status == 422 and _body(res).contains("too big"), "a PDF over the Quest 2's limit is refused with the reason")
	board.pdfs.budget = old


func _until(cond: Callable, timeout := 5.0) -> void:
	var waited := 0.0
	while not cond.call() and waited < timeout:
		await get_tree().process_frame
		waited += get_process_delta_time()


func _read_all(peer: StreamPeerTCP) -> PackedByteArray:
	var buf := PackedByteArray()
	var waited := 0.0
	while waited < 8.0:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var n := peer.get_available_bytes()
		if n > 0:
			buf.append_array(peer.get_data(n)[1])
		await get_tree().process_frame
		waited += get_process_delta_time()
	return buf


func _sockets() -> void:
	srv.require_pin = false
	t.check(srv.start(18090), "listening")
	var body := _bytes("embedded.pdf")
	var head := "POST /api/pdf?name=socket.pdf HTTP/1.1\r\nX-Requested-With: mrw\r\nContent-Type: application/pdf\r\nContent-Length: %d\r\n\r\n" % body.size()
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", srv.port)
	await _until(func(): peer.poll(); return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	var frames := board.doc.frames.size()
	peer.put_data(head.to_utf8_buffer())
	var at := 0
	while at < body.size():
		var n := mini(8000, body.size() - at)
		peer.put_data(body.slice(at, at + n))
		at += n
		await get_tree().process_frame
	var up := (await _read_all(peer)).get_string_from_utf8()
	t.check(up.begins_with("HTTP/1.1 200") and up.contains("\"ok\":true") and board.doc.frames.size() == frames + 1, "socket: a %d KB PDF sent in pieces is taken in once and put down" % (body.size() / 1024))
	# over the limit: refused before the body is sent
	var huge := ("POST /api/pdf HTTP/1.1\r\nX-Requested-With: mrw\r\nContent-Length: %d\r\n\r\n" % (70 * 1048576)).to_utf8_buffer()
	var peer2 := StreamPeerTCP.new()
	peer2.connect_to_host("127.0.0.1", srv.port)
	await _until(func(): peer2.poll(); return peer2.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	peer2.put_data(huge)
	t.check((await _read_all(peer2)).get_string_from_utf8().begins_with("HTTP/1.1 413"), "socket: a PDF beyond the limit is refused before it is sent")
	srv.stop()
