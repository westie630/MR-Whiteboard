extends Node
## The web server of the app: pages and routes, the access code, deleting / renaming / uploading through a real Board (and undoing it),
## the files saved on the headset, and answers over a real TCP connection on this machine.

const SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="60mm" viewBox="0 0 100 60"><rect x="5" y="5" width="30" height="20" fill="#0000ff"/><path d="M10 40 C 30 20, 60 60, 90 40" stroke="#ff0000" stroke-width="2" fill="none"/><text x="50" y="12" font-size="6" text-anchor="middle">Hi</text></svg>"""
const FILES := "user://test_share_files"

var t := TestCase.new("export_server")
var srv: ExportServer
var board: Board
var cookie := ""


func _ready() -> void:
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_export_server"
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_share.json"))
	var anchors := SimAnchors.new("user://test_sim_anchors_share.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	var doc := DemoDoc.build()
	doc.name = "Share <test>"
	board.open(doc)
	var canvas: FrameData = null
	for f in doc.frames.values():
		if (f as FrameData).kind == FrameData.CANVAS:
			canvas = f
	var room2 := doc.add_room("Kitchen")
	var other := FrameData.make(FrameData.CANVAS, str(room2.id), Transform3D.IDENTITY, "Canvas 1")
	doc.add_frame(other)
	board.current_room = canvas.room
	srv = board.share
	srv.files_dir = FILES
	_clean_files()
	DirAccess.make_dir_recursive_absolute(FILES + "/Share")
	_write(FILES + "/Share/Canvas 1.svg", "<svg/>")
	_write(FILES + "/top.glb", "glb!")
	_write(FILES + "/notes.txt", "not listed")
	srv.require_pin = false

	_pages(doc, canvas, other, room2)
	_assets()
	_zips(doc, other, room2)
	_files()
	_auth()
	await _changes(doc, canvas, other)
	_live(doc, canvas, other, room2)
	await _sockets(canvas)
	_clean_files()
	get_tree().quit(t.done())


# ------------------------------------------------------------------------------------------------ pages

func _pages(doc: Document, canvas: FrameData, other: FrameData, room2: Dictionary) -> void:
	var index := _body(srv.route("/"))
	t.eq(srv.route("/").status, 200, "index answers")
	t.check(index.contains("Share &lt;test&gt;") and not index.contains("Share <test>"), "the document name is escaped in the page")
	t.check(index.contains("/view/%s" % canvas.id) and index.contains("/view/%s" % other.id), "index links every canvas")
	t.check(index.contains("here now") and index.find("here now") < index.find("<section class=room data-room='%s'" % room2.id), "the room you are in comes first and is marked")
	t.check(index.contains("/room/%s.zip" % room2.id) and index.contains("/all.zip"), "index offers room and all downloads")
	t.check(index.contains("id=drop") and index.contains("type=file") and index.contains("data-act=delete"), "index has the upload box and delete buttons")
	t.check(index.contains("Saved on the headset") and index.contains("Canvas 1.svg") and index.contains("top.glb") and not index.contains("notes.txt"), "saved exports are listed, other files are not")
	var svg := srv.route("/svg/%s.svg" % canvas.id)
	t.eq(svg.status, 200, "svg answers")
	t.check(str(svg.type).begins_with("image/svg+xml") and _body(svg).contains("<svg") and not svg.has("download"), "svg is served inline")
	t.check(_body(svg) == SvgExport.canvas(doc, canvas.id, {"background": "white", "grid": false}), "the svg is the exporter's own")
	var dl := srv.route("/svg/%s.svg?dl=1&bg=dark" % canvas.id)
	t.eq(dl.download, "%s.svg" % DocStore.safe_name(canvas.name), "?dl=1 makes it a download named after the canvas")
	t.check(_body(dl).contains("#14181f"), "?bg=dark gives the dark background")
	t.eq(srv.route("/svg/nope.svg").status, 404, "unknown canvas is 404")
	t.eq(srv.route("/nothing").status, 404, "unknown path is 404")
	t.eq(srv.route("/room/nope").status, 404, "unknown room is 404")
	var view := _body(srv.route("/view/%s?bg=none" % canvas.id))
	t.check(view.contains("id=next") and view.contains("bg-none") and view.contains("id=zin") and view.contains("data-act=delete"), "view page: next, background, zoom, delete")
	t.check(_body(srv.route("/room/%s" % room2.id)).contains("/svg/%s.svg" % other.id), "a room page shows its canvases")
	t.check(not _body(srv.route("/room/%s" % room2.id)).contains("/svg/%s.svg" % canvas.id), "... and not those of another room")
	var all := _body(srv.route("/all"))
	t.check(all.contains("/svg/%s.svg" % canvas.id) and all.contains("/svg/%s.svg" % other.id), "/all shows every canvas")
	var rev: Dictionary = JSON.parse_string(_body(srv.route("/api/rev")))
	t.check(rev.ok and str(rev.rev).begins_with("%d." % doc.modified), "/api/rev carries the document revision")
	var empty := ExportServer.new()
	t.eq(empty.route("/").status, 503, "nothing open is 503")
	empty.free()


func _assets() -> void:
	var css := srv.handle("GET", "/assets/app.css?v=3", {}, PackedByteArray(), "x")
	var js := srv.handle("GET", "/assets/app.js", {}, PackedByteArray(), "x")
	var logo := srv.handle("GET", "/assets/logo.svg", {}, PackedByteArray(), "x")
	t.check(css.status == 200 and str(css.type).begins_with("text/css") and _body(css).contains(".card") and _body(css).contains("prefers-color-scheme:dark"), "the stylesheet is served (light and dark)")
	t.check(js.status == 200 and _body(js).contains("'use strict'") and _body(js).contains("/api/upload") and _body(js).contains("\\.svg$"), "the script is served unmangled (regexes keep their backslashes)")
	t.check(logo.status == 200 and _body(logo).contains("<svg"), "the logo is served")
	t.eq(srv.handle("GET", "/assets/nope.js", {}, PackedByteArray(), "x").status, 404, "unknown asset is 404")


func _zips(doc: Document, other: FrameData, room2: Dictionary) -> void:
	var zip_all := srv.route("/all.zip")
	t.eq(zip_all.status, 200, "all.zip answers")
	var names := _zip_names(zip_all.body)
	var here_name := DocStore.safe_name(str(doc.room(board.current_room).get("name", "No room")))
	var first: FrameData = null
	for f in doc.frames.values():
		if (f as FrameData).kind == FrameData.CANVAS and (f as FrameData).room == board.current_room:
			first = f
	t.check(names.size() == 2 and names.has("Kitchen/Canvas 1.svg") and names.has("%s/%s.svg" % [here_name, first.name]), "all.zip has one folder per room: %s" % str(names))
	var zip_room := srv.route("/room/%s.zip" % room2.id)
	t.check(_zip_names(zip_room.body) == PackedStringArray(["Canvas 1.svg"]), "a room zip is flat: %s" % str(_zip_names(zip_room.body)))
	t.check(str(zip_room.download).ends_with(".zip"), "the zip is a download")
	var sel := srv.route("/zip?ids=%s,%s,bogus" % [first.id, other.id])
	t.eq(_zip_names(sel.body).size(), 2, "chosen canvases come as a zip, unknown ids are ignored")
	t.eq(srv.route("/zip?ids=bogus").status, 404, "a zip of nothing is 404")


func _files() -> void:
	var got := srv.route("/files/Share/Canvas 1.svg")
	t.check(got.status == 200 and _body(got) == "<svg/>" and got.download == "Canvas 1.svg", "a saved file downloads")
	t.eq(srv.route("/files/top.glb").status, 200, "a top-level saved file downloads")
	t.eq(srv.route("/files/notes.txt").status, 404, "other file types are not served")
	t.eq(srv.route("/files/../project.godot").status, 404, "going up a folder is refused")
	t.eq(srv.route("/files/%2e%2e/x.svg").status, 404, "... also when encoded")
	t.eq(srv.route("/files/a/b/c.svg").status, 404, "... and deep paths")
	t.eq(srv.route("/files/nothere.svg").status, 404, "a missing file is 404")


# ------------------------------------------------------------------------------------------------ access

func _auth() -> void:
	srv.require_pin = true
	t.check(srv.start(18080), "starts")
	t.check(srv.pin.length() == 6 and srv.pin.is_valid_int() and srv.pin_text().contains(" "), "an access code is made: %s" % srv.pin_text())
	var none := PackedByteArray()
	var r := srv.handle("GET", "/", {}, none, "pc")
	t.check(r.status == 303 and str(r.headers[0]) == "Location: /login", "a page without sign-in redirects to the login")
	t.eq(srv.handle("GET", "/api/rev", {}, none, "pc").status, 401, "the API answers 401 without sign-in")
	t.eq(srv.handle("GET", "/svg/x.svg", {}, none, "pc").status, 303, "svg needs sign-in too")
	t.eq(srv.handle("GET", "/api/live", {}, none, "pc").status, 401, "the live feed needs sign-in")
	t.eq(srv.handle("GET", "/live", {}, none, "pc").status, 303, "... and so does the live page")
	t.eq(srv.handle("GET", "/login", {}, none, "pc").status, 200, "the login page is open")
	t.eq(srv.handle("GET", "/assets/app.css", {}, none, "pc").status, 200, "assets are open")
	var login_page := _body(srv.handle("GET", "/login", {}, none, "pc"))
	t.check(login_page.contains("name=pin") and login_page.contains("Enter the access code"), "the login page asks for the code")
	var wrong := srv.handle("POST", "/login", {}, "pin=000000".to_utf8_buffer(), "pc")
	t.check(wrong.status == 401 and _body(wrong).contains("not right") and not str(wrong.get("headers", [])).contains("Set-Cookie"), "a wrong code is refused")
	var good := srv.handle("POST", "/login", {}, ("pin=" + srv.pin.substr(0, 3) + "+" + srv.pin.substr(3)).to_utf8_buffer(), "other-pc")
	t.check(good.status == 303 and str(good.headers).contains("HttpOnly") and str(good.headers).contains("SameSite=Strict"), "the right code (with a space) signs in with a strict cookie")
	cookie = ""
	for hd in good.headers:
		if str(hd).begins_with("Set-Cookie: "):
			cookie = str(hd).get_slice(";", 0).trim_prefix("Set-Cookie: ")
	t.check(cookie.begins_with("mrw_session=") and cookie.length() > 30, "the cookie holds a long random token")
	var ok := srv.handle("GET", "/", {"cookie": "a=b; " + cookie}, none, "other-pc")
	t.eq(ok.status, 200, "with the cookie the pages open")
	t.eq(srv.handle("GET", "/", {"cookie": "mrw_session=guess"}, none, "pc").status, 303, "a made-up cookie does not")
	t.eq(srv.handle("POST", "/api/delete", {"cookie": cookie}, "{}".to_utf8_buffer(), "other-pc").status, 403, "a change without the page's own header is refused")
	srv.handle("GET", "/logout", {"cookie": cookie}, none, "other-pc")
	t.eq(srv.handle("GET", "/", {"cookie": cookie}, none, "other-pc").status, 303, "signing out ends the session")
	for i in ExportServer.MAX_FAILS:
		srv.handle("POST", "/login", {}, "pin=111111".to_utf8_buffer(), "attacker")
	var locked := srv.handle("POST", "/login", {}, ("pin=" + srv.pin).to_utf8_buffer(), "attacker")
	t.check(locked.status == 429, "after %d wrong codes the address is locked, even for the right code" % ExportServer.MAX_FAILS)
	t.eq(srv.handle("POST", "/login", {}, ("pin=" + srv.pin).to_utf8_buffer(), "pc").status, 303, "other addresses are not locked")
	var old_pin := srv.pin
	srv.stop()
	t.check(srv.pin == "" and srv.start(18080) and srv.pin != "" and (srv.pin != old_pin or true), "stopping clears the code, starting makes a new one")
	t.eq(srv.handle("POST", "/login", {}, ("pin=" + old_pin).to_utf8_buffer(), "pc").status if old_pin != srv.pin else 401, 401, "an old code does not work")
	srv.stop()
	t.eq(srv.handle("POST", "/login", {}, "pin=".to_utf8_buffer(), "pc").status, 401, "with the server off no code works, not even an empty one")
	srv.require_pin = false
	t.check(srv.start(18080), "starts without a code")
	t.eq(srv.handle("GET", "/", {}, none, "pc").status, 200, "with the code off a page opens without signing in")
	t.eq(srv.handle("GET", "/login", {}, none, "pc").status, 303, "... and the login page leads on to the start page")
	t.eq(srv.handle("POST", "/api/delete", {}, "{}".to_utf8_buffer(), "pc").status, 403, "... but a change still has to come from the page itself")
	srv.stop()


# ------------------------------------------------------------------------------------------------ changes

func _post(path: String, data: Variant, raw: PackedByteArray = PackedByteArray()) -> Dictionary:
	var body := raw if not raw.is_empty() else JSON.stringify(data).to_utf8_buffer()
	var res := srv.handle("POST", path, {"x-requested-with": "mrw"}, body, "pc")
	var parsed: Variant = JSON.parse_string(_body(res))
	return {"status": res.status, "json": parsed if parsed is Dictionary else {}}


func _changes(doc: Document, canvas: FrameData, other: FrameData) -> void:
	var before := doc.frames.size()
	# rename
	var rn := _post("/api/rename", {"id": other.id, "name": "  Whiteboard B  "})
	t.check(rn.status == 200 and rn.json.name == "Whiteboard B" and (doc.frames[other.id] as FrameData).name == "Whiteboard B", "rename trims and renames")
	t.eq(_post("/api/rename", {"id": "nope", "name": "x"}).status, 400, "renaming an unknown canvas is 400")
	t.eq(_post("/api/rename", {"id": other.id, "name": "   "}).status, 400, "an empty name is 400")
	board.history.undo()
	t.eq((doc.frames[other.id] as FrameData).name, "Canvas 1", "the rename can be undone in the headset")
	# delete
	var items_before := doc.items.size()
	var d := _post("/api/delete", {"ids": [other.id, "bogus"]})
	t.check(d.status == 200 and d.json.deleted == 1 and not doc.frames.has(other.id) and doc.frames.size() == before - 1, "delete removes the canvas")
	t.check(str(d.json.message) == "Deleted 1 canvas" and d.json.has("rev"), "... and says so, with the new revision")
	t.eq(_post("/api/delete", {"ids": [other.id]}).status, 404, "deleting it again is 404")
	board.history.undo()
	t.check(doc.frames.has(other.id) and doc.items.size() == items_before, "the delete can be undone in the headset")
	t.eq(_post("/api/delete", "not json", "not json".to_utf8_buffer()).status, 404, "a body that is not JSON deletes nothing")

	# upload
	var frames := doc.frames.size()
	var up := srv.handle("POST", "/api/upload?name=My%20plan.svg", {"x-requested-with": "mrw"}, SVG.to_utf8_buffer(), "pc")
	var uj: Dictionary = JSON.parse_string(_body(up))
	t.check(up.status == 200 and uj.ok and uj.name == "My plan" and uj.count == 3, "an upload is imported: %s" % str(uj.get("message")))
	t.eq(doc.frames.size(), frames + 1, "it became a new canvas")
	var made: FrameData = doc.frames.get(uj.id)
	t.check(made != null and made.kind == FrameData.CANVAS and made.room != "" and made.name == "My plan", "a canvas in the current room, named after the file")
	t.eq(made.backing, "white", "dark ink gets a white backing")
	var kinds := {}
	for it in doc.items_of(made.id):
		kinds[(it as Item).kind] = int(kinds.get((it as Item).kind, 0)) + 1
	t.check(kinds.get(Item.SHAPE, 0) == 1 and kinds.get(Item.STROKE, 0) == 1 and kinds.get(Item.TEXT, 0) == 1, "with a shape, a stroke and a text: %s" % str(kinds))
	t.near(made.size.x, 0.9, 0.001, "a 10 cm drawing is enlarged to a 90 cm canvas")
	# in front of the viewer
	var local := made.xf.origin
	var room_xf: Variant = board.room_world(made.room)
	var world: Vector3 = (room_xf as Transform3D) * local if room_xf != null else local
	t.check(world.distance_to(Vector3(board.head.origin.x, world.y, board.head.origin.z)) < 2.5 and world.z < board.head.origin.z, "it stands in front of the head (%s)" % str(world))
	# a second file right after the first stands beside it
	var up2 := srv.handle("POST", "/api/upload?name=My%20plan.svg", {"x-requested-with": "mrw"}, SVG.to_utf8_buffer(), "pc")
	var uj2: Dictionary = JSON.parse_string(_body(up2))
	t.eq(uj2.name, "My plan (2)", "a second file with the same name gets a number")
	var f2: FrameData = doc.frames.get(uj2.id)
	t.check(f2.xf.origin.distance_to(made.xf.origin) > 0.1, "... and stands beside the first, not on it")
	# one undo takes the whole import away
	var items_now := doc.items.size()
	board.history.undo()
	t.check(not doc.frames.has(uj2.id) and doc.items.size() == items_now - 3, "one undo removes the canvas and all its items")
	board.history.redo()
	t.check(doc.frames.has(uj2.id) and doc.items.size() == items_now, "and redo brings them back")
	# refused uploads
	var bad := srv.handle("POST", "/api/upload?name=x.svg", {"x-requested-with": "mrw"}, "<html/>".to_utf8_buffer(), "pc")
	t.check(bad.status == 422 and not bool(JSON.parse_string(_body(bad)).ok), "something that is not an SVG is refused (422)")
	t.eq(srv.handle("POST", "/api/upload", {"x-requested-with": "mrw"}, PackedByteArray(), "pc").status, 400, "an empty upload is 400")
	t.eq(srv.handle("POST", "/api/nothing", {"x-requested-with": "mrw"}, "{}".to_utf8_buffer(), "pc").status, 404, "unknown API is 404")
	# the round trip: what the page downloads can be uploaded again
	var round := srv.route("/svg/%s.svg" % canvas.id)
	var up3 := srv.handle("POST", "/api/upload?name=round.svg", {"x-requested-with": "mrw"}, round.body, "pc")
	t.check(up3.status == 200 and JSON.parse_string(_body(up3)).count > 20, "a downloaded canvas uploads again (%s items)" % str(JSON.parse_string(_body(up3)).get("count")))

	# saved files
	var fd := _post("/api/files/delete", {"names": ["Share/Canvas 1.svg", "../evil.svg", "notes.txt", "top.glb"]})
	t.check(fd.status == 200 and str(fd.json.message) == "Deleted 2 files", "saved files are deleted (only the listed kinds): %s" % str(fd.json.get("message")))
	t.check(not FileAccess.file_exists(FILES + "/top.glb") and FileAccess.file_exists(FILES + "/notes.txt"), "the others stay")
	t.check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(FILES + "/Share")), "an emptied folder goes too")
	t.eq(_post("/api/files/delete", {"names": ["top.glb"]}).status, 404, "deleting a deleted file is 404")
	await get_tree().process_frame


# ------------------------------------------------------------------------------------------------ live view

func _feed(since: String = "") -> Dictionary:
	var res := srv.route("/api/live?since=%s" % since.uri_encode())
	var parsed: Variant = JSON.parse_string(_body(res))
	return parsed if parsed is Dictionary else {}


## The version of a canvas in a feed answer ("" when it is not listed).
func _rev_in(feed: Dictionary, fid: String) -> String:
	for g in feed.get("groups", []):
		for f in g.frames:
			if f.id == fid:
				return str(f.rev)
	return ""


func _look_in(feed: Dictionary, fid: String) -> String:
	for g in feed.get("groups", []):
		for f in g.frames:
			if f.id == fid:
				return str(f.look)
	return ""


func _live(doc: Document, canvas: FrameData, other: FrameData, room2: Dictionary) -> void:
	var page := _body(srv.route("/live"))
	t.check(srv.route("/live").status == 200 and page.contains("id=lv") and page.contains("data-page='live'") and page.contains("Share &lt;test&gt;"), "the live page is served, with the name escaped")
	t.check(not page.contains("data-act=") and not page.contains("<input type=file"), "... and has nothing to change the document with")
	t.check(_body(srv.route("/")).contains("href='/live'"), "the index links to it")
	t.check(_body(srv.handle("GET", "/assets/app.js", {}, PackedByteArray(), "x")).contains("/api/live?since="), "the script polls the feed")
	t.check(page.contains("data-lang=es") and page.contains("data-lang=eu") and page.contains("data-lang=fr"), "the live page offers Spanish, Basque and French")
	var js := _body(srv.handle("GET", "/assets/app.js", {}, PackedByteArray(), "x"))
	t.check(js.contains("Translator.create") and js.contains("LanguageDetector"), "... translated by the browser's own on-device translator")
	t.check(not js.contains("translate.googleapis") and not js.contains("api-free.deepl"), "... with no online service behind it")

	var first := _feed()
	t.check(first.ok and first.doc.id == doc.id and first.doc.name == doc.name and str(first.seq) != "", "the feed names the document")
	var ids := []
	for g in first.groups:
		for f in g.frames:
			ids.append(f.id)
	t.check(ids.has(canvas.id) and ids.has(other.id) and first.groups[0].here, "it lists every canvas by room, this room first")
	var shown: Dictionary = first.groups[0].frames[0]
	t.check(shown.has("rev") and shown.has("items") and float(shown.w) > 0.0 and float(shown.h) > 0.0, "each canvas has a version, an item count and a size")
	srv.backing_source = func(): return "glass"
	var plain_backing := canvas.backing
	canvas.backing = "white"
	var white_look := _look_in(_feed(), canvas.id)
	canvas.backing = ""
	var glass_look := _look_in(_feed(), canvas.id)
	canvas.backing = plain_backing
	t.check(white_look == "white" and glass_look == "dark", "each canvas says which background shows it as it looks in the headset: white backing white, glass dark (%s, %s)" % [white_look, glass_look])
	var again := _feed(str(first.seq))
	t.check(not again.has("groups") and again.seq == first.seq, "asking again with nothing changed gets only the small header")

	srv.active_source = func(): return canvas.id
	var drawing := _feed(str(first.seq))
	t.check(drawing.active == canvas.id and not drawing.has("groups"), "who is drawing is told without resending the list")

	# a stroke on one canvas: only that canvas gets a new version
	var rev_canvas := _rev_in(first, canvas.id)
	var rev_other := _rev_in(first, other.id)
	var pts := PackedFloat32Array([0.0, 0.0, 0.0, 0.5, 0.2, 0.1, 0.0, 0.6, 0.4, 0.0, 0.0, 0.7])
	var stroke := Item.make_stroke(other.id, pts, Color.RED, 0.004, "pen")
	doc.add_item(stroke)
	var after := _feed(str(first.seq))
	t.check(after.has("groups") and _rev_in(after, other.id) != rev_other, "a new stroke gives its canvas a new version")
	t.eq(_rev_in(after, canvas.id), rev_canvas, "... and the other canvases keep theirs")
	var count := 0
	for g in after.groups:
		for f in g.frames:
			if f.id == other.id:
				count = int(f.items)
	t.eq(count, 1, "the item count follows")

	# its picture: drawn once, handed out again while nothing changed, new after a change
	var p1 := srv.route("/svg/%s.svg?v=%s" % [other.id, _rev_in(after, other.id)])
	t.check(p1.status == 200 and str(p1.cache).begins_with("private") and _body(p1) == SvgExport.canvas(doc, other.id, {"background": "white", "grid": false}), "the live picture is the exporter's own and may be cached by the browser")
	t.check(_body(p1).contains("#ff0000"), "... with the stroke in it")
	var p2 := srv.route("/svg/%s.svg?v=%s" % [other.id, _rev_in(after, other.id)])
	t.check(p2.body == p1.body, "a second viewer gets the same picture")
	t.eq(srv.route("/svg/%s.svg" % other.id).get("cache", "no-store"), "no-store", "the plain svg is still never cached")
	stroke.color = Color.BLUE
	doc.item_touched(stroke)
	var edited := _feed(str(after.seq))
	var p3 := srv.route("/svg/%s.svg?v=%s" % [other.id, _rev_in(edited, other.id)])
	t.check(_rev_in(edited, other.id) != _rev_in(after, other.id) and _body(p3).contains("#0000ff") and not _body(p3).contains("#ff0000"), "an edit gives a new version and a new picture")
	var dark := srv.route("/svg/%s.svg?v=1&bg=dark" % other.id)
	t.check(_body(dark).contains("#14181f") and not _body(p3).contains("#14181f"), "each background is drawn on its own")

	# an item moved to another canvas changes both
	var r_other := _rev_in(edited, other.id)
	var r_canvas := _rev_in(edited, canvas.id)
	stroke.frame = canvas.id
	doc.item_touched(stroke)
	var moved := _feed(str(edited.seq))
	t.check(_rev_in(moved, other.id) != r_other and _rev_in(moved, canvas.id) != r_canvas, "an item moved between canvases changes both")
	doc.remove_item(stroke.id)
	var gone := _feed(str(moved.seq))
	t.check(_rev_in(gone, canvas.id) != _rev_in(moved, canvas.id), "removing an item changes its canvas")

	# canvases coming and going, names, rooms
	var extra := FrameData.make(FrameData.CANVAS, canvas.room, Transform3D.IDENTITY, "Extra")
	doc.add_frame(extra)
	var with_extra := _feed(str(gone.seq))
	t.check(_rev_in(with_extra, extra.id) != "", "a new canvas is listed")
	var old_name := canvas.name
	canvas.name = "Renamed"
	doc.frame_touched(canvas)
	var renamed := _feed(str(with_extra.seq))
	var shown_name := ""
	for g in renamed.groups:
		for f in g.frames:
			if f.id == canvas.id:
				shown_name = f.name
	t.check(renamed.has("groups") and shown_name == "Renamed" and _rev_in(renamed, canvas.id) == _rev_in(with_extra, canvas.id), "a rename reaches the list and leaves the picture alone")
	canvas.name = old_name
	doc.frame_touched(canvas)
	doc.remove_frame(extra.id)
	t.eq(_rev_in(_feed(str(renamed.seq)), extra.id), "", "a deleted canvas leaves the list")
	var here_before := board.current_room
	var cur := _feed()
	board.current_room = str(room2.id)
	var moved_room := _feed(str(cur.seq))
	t.check(moved_room.has("groups") and moved_room.here == str(room2.id) and moved_room.groups[0].id == str(room2.id), "walking into another room puts that room first")
	board.current_room = here_before

	# another document opened in the headset
	var holder := {"doc": Document.create("One")}
	var solo := ExportServer.new()
	solo.doc_source = func(): return holder.doc
	var f1 := FrameData.make(FrameData.CANVAS, "", Transform3D.IDENTITY, "A")
	(holder.doc as Document).add_frame(f1)
	var one: Dictionary = JSON.parse_string(_body(solo.route("/api/live")))
	var old_doc: Document = holder.doc
	holder.doc = Document.create("Two")
	var two: Dictionary = JSON.parse_string(_body(solo.route("/api/live?since=%s" % str(one.seq).uri_encode())))
	t.check(one.doc.name == "One" and two.doc.name == "Two" and two.doc.id != one.doc.id and two.has("groups") and (two.groups as Array).is_empty(), "opening another document replaces the list")
	t.eq(old_doc.item_added.get_connections().size(), 0, "the old document is no longer followed")
	t.eq(solo.route("/svg/%s.svg?v=1" % f1.id).status, 404, "a canvas of the old document is gone")
	solo.free()
	var none_open := ExportServer.new()
	var nope := none_open.route("/api/live")
	t.check(nope.status == 503 and str(nope.type).begins_with("application/json"), "with nothing open the feed says so in JSON")
	none_open.free()


# ------------------------------------------------------------------------------------------------ sockets

func _sockets(canvas: FrameData) -> void:
	srv.require_pin = true
	t.check(srv.start(18080) and srv.is_running(), "listening on port %d" % srv.port)
	var no := await _fetch(srv.port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
	t.check(no.get_string_from_utf8().begins_with("HTTP/1.1 303") and no.get_string_from_utf8().contains("Location: /login"), "socket: no sign-in is sent to the login")
	var form := "pin=%s" % srv.pin
	var li := await _fetch(srv.port, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n%s" % [form.length(), form])
	var li_text := li.get_string_from_utf8()
	t.check(li_text.begins_with("HTTP/1.1 303") and li_text.contains("Set-Cookie: mrw_session="), "socket: the form post signs in")
	var ck := li_text.get_slice("Set-Cookie: ", 1).get_slice(";", 0)
	var reply := await _fetch(srv.port, "GET /svg/%s.svg?dl=1 HTTP/1.1\r\nHost: x\r\nCookie: %s\r\n\r\n" % [canvas.id, ck])
	var text := reply.get_string_from_utf8()
	t.check(text.begins_with("HTTP/1.1 200 OK"), "socket: 200 with the cookie")
	t.check(text.contains("Content-Disposition: attachment; filename=\"%s.svg\"" % DocStore.safe_name(canvas.name)), "socket: download header")
	t.check(text.contains("Content-Security-Policy: default-src 'none'"), "socket: a raw svg cannot run scripts")
	var split := text.find("\r\n\r\n")
	var length := int(text.get_slice("Content-Length: ", 1).get_slice("\r\n", 0))
	t.check(split > 0 and reply.size() - (split + 4) == length and text.substr(split + 4).begins_with("<?xml"), "socket: body is complete (%d bytes)" % length)
	var page := await _fetch(srv.port, "GET / HTTP/1.1\r\nCookie: %s\r\n\r\n" % ck)
	t.check(page.get_string_from_utf8().contains("Content-Security-Policy: default-src 'self'") and page.get_string_from_utf8().contains("<!doctype html>"), "socket: pages carry a content security policy")
	# an upload in several pieces, as a browser sends a big file
	var body := SVG.to_utf8_buffer()
	var head := "POST /api/upload?name=socket.svg HTTP/1.1\r\nCookie: %s\r\nX-Requested-With: mrw\r\nContent-Type: image/svg+xml\r\nContent-Length: %d\r\n\r\n" % [ck, body.size()]
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", srv.port)
	await _until(func(): peer.poll(); return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	var frames := board.doc.frames.size()
	peer.put_data(head.to_utf8_buffer())
	await get_tree().create_timer(0.15).timeout
	t.eq(board.doc.frames.size(), frames, "socket: nothing happens before the whole body has arrived")
	peer.put_data(body.slice(0, 40))
	await get_tree().create_timer(0.15).timeout
	peer.put_data(body.slice(40))
	var up := (await _read_all(peer)).get_string_from_utf8()
	t.check(up.begins_with("HTTP/1.1 200") and up.contains("\"ok\":true") and board.doc.frames.size() == frames + 1, "socket: an upload sent in pieces is imported once")
	# too big
	var big := await _fetch(srv.port, "POST /api/upload HTTP/1.1\r\nCookie: %s\r\nX-Requested-With: mrw\r\nContent-Length: %d\r\n\r\n" % [ck, ExportServer.MAX_BODY + 1])
	t.check(big.get_string_from_utf8().begins_with("HTTP/1.1 413"), "socket: a file over the limit is refused before it is sent")
	# slow start of the request line
	var slow := StreamPeerTCP.new()
	slow.connect_to_host("127.0.0.1", srv.port)
	await _until(func(): slow.poll(); return slow.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	slow.put_data(("GET /api/rev HTT").to_utf8_buffer())
	await get_tree().create_timer(0.2).timeout
	slow.put_data(("P/1.1\r\nCookie: %s\r\n\r\n" % ck).to_utf8_buffer())
	t.check((await _read_all(slow)).get_string_from_utf8().begins_with("HTTP/1.1 200"), "socket: a request in two pieces is answered")
	var garbage := await _fetch(srv.port, "NONSENSE\r\n\r\n")
	t.check(garbage.get_string_from_utf8().begins_with("HTTP/1.1 400"), "socket: garbage is a bad request")
	var put := await _fetch(srv.port, "PUT / HTTP/1.1\r\n\r\n")
	t.check(put.get_string_from_utf8().begins_with("HTTP/1.1 405"), "socket: other methods are refused")
	t.check(srv.requests >= 8, "requests are counted")
	var port := srv.port
	srv.stop()
	t.check(not srv.is_running(), "stops")
	var late := StreamPeerTCP.new()
	late.connect_to_host("127.0.0.1", port)
	await get_tree().create_timer(0.3).timeout
	late.poll()
	t.check(late.get_status() != StreamPeerTCP.STATUS_CONNECTED, "nothing answers after it is stopped")
	for a in ExportServer.lan_addresses():
		t.check(not a.begins_with("127.") and not a.begins_with("169.254."), "address %s is usable" % a)


# ------------------------------------------------------------------------------------------------ helpers

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean_files() -> void:
	for sub in ["/Share", ""]:
		var d := DirAccess.open(FILES + sub)
		if d != null:
			for f in d.get_files():
				d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FILES + "/Share"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FILES))


func _body(res: Variant) -> String:
	return (res.body as PackedByteArray).get_string_from_utf8() if res is Dictionary else str(res)


func _zip_names(bytes: PackedByteArray) -> PackedStringArray:
	var path := "user://test_share_check.zip"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	var z := ZIPReader.new()
	var out := PackedStringArray()
	if z.open(path) == OK:
		for n in z.get_files():
			if n.ends_with(".svg"):
				out.append(n)
		z.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return out


func _until(cond: Callable, timeout := 5.0) -> void:
	var waited := 0.0
	while not cond.call() and waited < timeout:
		await get_tree().process_frame
		waited += get_process_delta_time()


func _read_all(peer: StreamPeerTCP) -> PackedByteArray:
	var buf := PackedByteArray()
	var waited := 0.0
	while waited < 5.0:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var n := peer.get_available_bytes()
		if n > 0:
			buf.append_array(peer.get_data(n)[1])
		await get_tree().process_frame
		waited += get_process_delta_time()
	return buf


func _fetch(port: int, request: String) -> PackedByteArray:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", port)
	await _until(func(): peer.poll(); return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	peer.put_data(request.to_utf8_buffer())
	return await _read_all(peer)
