class_name ExportServer
extends Node
## A small web server inside the app, so the canvases of the open document can be looked at, saved, deleted and added to from a PC
## browser on the same Wi-Fi: open http://<headset address>:8080, type the access code the headset shows, and pick what you want.
## Files are made when they are asked for, from the document as it is right now (nothing is stored on the headset for viewing).
##
##   GET  /                   rooms and canvases as thumbnails, upload box, files saved on the headset
##   GET  /view/<canvas>      one canvas large (background choice, zoom, next / previous)
##   GET  /room/<room>        all canvases of a room, large            /room/<room>.zip   the same as SVG files
##   GET  /all  /all.zip      the whole document                       /zip?ids=a,b,c     chosen canvases as a zip
##   GET  /svg/<canvas>.svg   the SVG itself (?dl=1 downloads it; ?bg=white|dark|none and ?grid=1 set how it looks)
##   GET  /pdf/<id>.pdf       a PDF of the headset's library (?dl=1 downloads it, otherwise the browser shows it)
##   GET  /files/<name>       a file saved on the headset by the app's Export buttons
##   GET  /live               the live view: every canvas of the open document, redrawn as the headset changes it (read-only, many viewers)
##   GET  /api/live?since=    what the live view polls: the document's canvases with a version each, only when something changed
##   POST /api/delete        {ids: [...]}          delete canvases (undoable in the headset)
##   POST /api/rename         {id, name}            rename a canvas
##   POST /api/upload?name=   the raw .svg          import it as a new canvas, as shapes, strokes and text that can be edited
##   POST /api/pdf?name=      the raw .pdf          take it into the headset's PDF library and put it in front of the viewer (?show=0 only stores it)
##   POST /api/pdf/show       {id}                  put a PDF of the library in front of the viewer     /api/pdf/delete {ids}   /api/pdf/rename {id, name}
##   POST /api/files/delete   {names: [...]}        delete saved files
##   GET  /ai                 the AI assistant: API keys, models and thinking levels, asking about a canvas, its suggestions
##   GET  /api/ai/state       what the AI page shows (keys only as their last four characters)
##   POST /api/ai/<command>   key | select | refresh | ask | accept | discard | show | forget  (see AiController.api)
##   GET  /keys               the API keys page: Claude, OpenAI, MiniMax and Wit.ai (GET /api/keys/state; POST /api/keys/set)
##
## It listens only while it is switched on. Because it can change things, every page needs the 6-digit access code shown in the
## headset (a new one each time it is switched on; a wrong code five times in a row locks that address for a minute), and every
## change must come from the page itself (a cookie that only the same site sends, plus a header other sites cannot add). The
## connection is plain HTTP: use it on a network you trust.

signal state_changed()

const DEFAULT_PORT := 8080
const PORT_TRIES := 10
const MAX_HEAD := 16384
const MAX_BODY := 16 * 1024 * 1024
const IDLE_TIMEOUT_S := 15.0
const CHUNK := 262144
const BACKGROUNDS := ["white", "dark", "none"]
const TMP_ZIP := "user://share_tmp.zip"
const COOKIE := "mrw_session"
const SESSION_MS := 8 * 3600 * 1000
const MAX_FAILS := 5
const LOCK_MS := 60 * 1000
const LIVE_CACHE := 96                    # pictures kept for the live view
const FILE_EXTS := ["svg", "glb", "mrw"]
const FILE_TYPES := {"svg": "image/svg+xml", "glb": "model/gltf-binary", "mrw": "application/json"}

var doc_source := Callable()              # -> Document or null: what is served
var room_source := Callable()             # -> String: the room the viewer is in now (marked "here now")
var delete_canvas := Callable()           # (frame id): removes a canvas (the Board does it as an undoable step)
var rename_canvas := Callable()           # (frame id, name)
var import_svg := Callable()              # (svg text, file name) -> {ok, message, id?, name?, count?}
var active_source := Callable()           # -> String: the canvas drawn on last (the live view can follow it)
var backing_source := Callable()          # -> String: the backing canvases have unless they say otherwise (none | glass | dark | white)
var ai_api := Callable()                  # (command, data) -> Dictionary: the AI assistant's page (AiController.api)
var keys_api := Callable()                # (command, data) -> Dictionary: the API keys page (ApiKeys.api)
var pdf_library: PdfLibrary               # the PDFs of the headset (null: no PDF section)
var show_pdf := Callable()                # (pdf id) -> {ok, message, id, name}: puts one in front of the viewer
var require_pin := true
var files_dir := ""                       # where saved exports are listed from ("" = the app's export folder)
var pin := ""                             # the access code while running
var port := 0
var requests := 0                         # answered so far

var _tcp: TCPServer
var _clients: Array = []                  # {peer, inbuf, outbuf, sent, age, replied, hdr, scan, need}
var _sessions := {}                       # token -> expiry (ticks, ms)
var _fails := {}                          # address -> {n, until}

# What the live view needs: which canvas changed when. Kept from the document's own signals while the server is asked about it.
var _watched: Document
var _epoch := int(Time.get_unix_time_from_system() * 1000.0)   # new each time the server starts: versions never repeat across runs
var _seq := 0                             # counts every change
var _base := 0                            # version of a canvas nobody changed since the document was first looked at
var _frame_rev := {}                      # canvas id -> _seq at its last change
var _item_frame := {}                     # item id -> the canvas it was on (an item can move to another canvas)
var _dims := {}                           # canvas id -> {rev, items, w, h}
var _svg_cache := {}                      # "canvas|background|grid" -> {rev, bytes}


func _ready() -> void:
	set_process(is_running())


func _exit_tree() -> void:
	stop()


func is_running() -> bool:
	return _tcp != null and _tcp.is_listening()


## Starts listening on the preferred port, or the next free one, with a fresh access code. Returns false when no port was free.
func start(preferred: int = DEFAULT_PORT) -> bool:
	stop()
	var tcp := TCPServer.new()
	for i in PORT_TRIES:
		if tcp.listen(preferred + i) == OK:
			_tcp = tcp
			_epoch = int(Time.get_unix_time_from_system() * 1000.0)
			port = preferred + i
			pin = "%06d" % (Crypto.new().generate_random_bytes(4).decode_u32(0) % 1000000)
			_sessions.clear()
			_fails.clear()
			set_process(true)
			state_changed.emit()
			return true
	return false


func stop() -> void:
	var was := is_running()
	for c in _clients:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	if _tcp != null:
		_tcp.stop()
		_tcp = null
	port = 0
	pin = ""
	_sessions.clear()
	_unwatch()
	set_process(false)
	if was:
		state_changed.emit()


## "482 913": the code as it is shown.
func pin_text() -> String:
	return "%s %s" % [pin.substr(0, 3), pin.substr(3)] if pin.length() == 6 else pin


## The addresses a PC can use to reach this device, most likely first (home networks before the rest).
static func lan_addresses() -> PackedStringArray:
	var rx := RegEx.create_from_string(r"^\d{1,3}(\.\d{1,3}){3}$")
	var home := PackedStringArray()
	var other := PackedStringArray()
	for a in IP.get_local_addresses():
		var s := str(a)
		if rx.search(s) == null or s.begins_with("127.") or s.begins_with("169.254.") or s == "0.0.0.0":
			continue
		if s.begins_with("192.168.") or s.begins_with("10."):
			home.append(s)
		else:
			other.append(s)
	home.append_array(other)
	return home


func urls() -> PackedStringArray:
	var out := PackedStringArray()
	if not is_running():
		return out
	for a in lan_addresses():
		out.append("http://%s:%d" % [a, port])
	return out


# ------------------------------------------------------------------------------------------------ connections

func _process(delta: float) -> void:
	if _tcp == null:
		return
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		peer.set_no_delay(true)
		_clients.append({"peer": peer, "inbuf": PackedByteArray(), "outbuf": PackedByteArray(), "sent": 0, "age": 0.0, "replied": false,
			"hdr": -1, "scan": 0, "need": 0})
	var alive: Array = []
	for c in _clients:
		if _serve(c, delta):
			alive.append(c)
	_clients = alive


## One step for one connection; false once it is finished (or broken) and has been closed.
func _serve(c: Dictionary, delta: float) -> bool:
	var peer: StreamPeerTCP = c.peer
	peer.poll()
	c.age += delta
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or c.age > IDLE_TIMEOUT_S:
		peer.disconnect_from_host()
		return false
	if not c.replied:
		var n := peer.get_available_bytes()
		var inbuf: PackedByteArray = c.inbuf
		if n > 0:
			var got := peer.get_data(n)
			if int(got[0]) == OK:
				inbuf.append_array(got[1])
				c.inbuf = inbuf
				c.age = 0.0
		if int(c.hdr) < 0:
			c.hdr = _head_end(inbuf, maxi(0, int(c.scan) - 3))
			c.scan = inbuf.size()
			if int(c.hdr) < 0:
				if inbuf.size() > MAX_HEAD:
					peer.disconnect_from_host()
					return false
				return true
			var length := _content_length(inbuf.slice(0, int(c.hdr)).get_string_from_utf8())
			if length > MAX_BODY:
				c.outbuf = _wire(_json(413, {"ok": false, "message": "That file is too big (the limit is %d MB)." % (MAX_BODY / 1048576)}), false)
				c.replied = true
			else:
				c.need = int(c.hdr) + 4 + length
		if not c.replied:
			if inbuf.size() < int(c.need):
				return true
			var head := inbuf.slice(0, int(c.hdr)).get_string_from_utf8()
			c.outbuf = answer(head, inbuf.slice(int(c.hdr) + 4, int(c.need)), peer.get_connected_host())
			c.replied = true
	var out: PackedByteArray = c.outbuf
	var sent: int = c.sent
	if sent < out.size():
		var r := peer.put_partial_data(out.slice(sent, sent + CHUNK))
		if int(r[0]) != OK:
			peer.disconnect_from_host()
			return false
		if int(r[1]) > 0:
			c.sent = sent + int(r[1])
			c.age = 0.0
	if int(c.sent) >= out.size():
		peer.disconnect_from_host()
		return false
	return true


## The biggest body a request may carry: a PDF may be as big as the headset takes in, anything else is small.
func _body_limit(head: String) -> int:
	if pdf_library != null and head.begins_with("POST /api/pdf"):
		return maxi(pdf_library.budget.max_file_mb * 1048576, MAX_BODY)
	return MAX_BODY


## Index of the blank line that ends the request head (CR LF CR LF), -1 while it has not arrived.
static func _head_end(buf: PackedByteArray, from: int) -> int:
	for i in range(from, buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


static func _content_length(head: String) -> int:
	for line in head.split("\n"):
		var l := String(line)
		if l.to_lower().begins_with("content-length:"):
			return maxi(l.get_slice(":", 1).strip_edges().to_int(), 0)
	return 0


## The full HTTP answer (status line, headers, body) to a request: its head ("GET /all HTTP/1.1 ..."), its body and who sent it.
func answer(head: String, body: PackedByteArray = PackedByteArray(), remote: String = "") -> PackedByteArray:
	requests += 1
	var lines := head.split("\n")
	var parts := String(lines[0]).strip_edges().split(" ")
	if parts.size() < 2:
		return _wire(_text(400, "Bad request"), false)
	var headers := {}
	for i in range(1, lines.size()):
		var kv := String(lines[i]).split(":", true, 1)
		if kv.size() == 2:
			headers[kv[0].strip_edges().to_lower()] = kv[1].strip_edges()
	var method := parts[0]
	if method != "GET" and method != "HEAD" and method != "POST":
		var res := _text(405, "Only GET and POST are supported")
		res["headers"] = ["Allow: GET, HEAD, POST"]
		return _wire(res, false)
	return _wire(handle(method, parts[1], headers, body, remote), method == "HEAD")


func _wire(res: Dictionary, head_only: bool) -> PackedByteArray:
	var status := int(res.status)
	var body: PackedByteArray = res.body
	var type := str(res.type)
	var lines := PackedStringArray(["HTTP/1.1 %d %s" % [status, _reason(status)],
		"Content-Type: %s" % type, "Content-Length: %d" % body.size(),
		"Cache-Control: %s" % res.get("cache", "no-store"),
		"X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "Connection: close"])
	if type.begins_with("text/html"):
		lines.append("Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
	elif type.begins_with("image/svg"):
		lines.append("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox")
	if res.has("download"):
		lines.append("Content-Disposition: attachment; filename=\"%s\"" % res.download)
	for extra in res.get("headers", []):
		lines.append(str(extra))
	var out := ("\r\n".join(lines) + "\r\n\r\n").to_utf8_buffer()
	if not head_only:
		out.append_array(body)
	return out


func _reason(status: int) -> String:
	match status:
		200: return "OK"
		204: return "No Content"
		303: return "See Other"
		400: return "Bad Request"
		401: return "Unauthorized"
		403: return "Forbidden"
		404: return "Not Found"
		405: return "Method Not Allowed"
		413: return "Payload Too Large"
		422: return "Unprocessable Content"
		429: return "Too Many Requests"
		501: return "Not Implemented"
		503: return "Service Unavailable"
	return "Error"


# ------------------------------------------------------------------------------------------------ access

## Sign-in, assets and the access check in front of everything else.
func handle(method: String, target: String, headers: Dictionary, body: PackedByteArray, remote: String) -> Dictionary:
	var path := target.get_slice("?", 0).uri_decode()
	if path.begins_with("/assets/"):
		return _asset(path)
	if path == "/favicon.ico":
		return {"status": 204, "type": "text/plain", "body": PackedByteArray()}
	if path == "/login":
		return _login(body, remote) if method == "POST" else _html(200, WebPages.login())
	if path == "/logout":
		var tok := _cookie(headers)
		_sessions.erase(tok)
		return _redirect("/login", ["Set-Cookie: %s=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" % COOKIE])
	if require_pin and not _signed_in(headers):
		if path.begins_with("/api/"):
			return _json(401, {"ok": false, "message": "Signed out"})
		return _redirect("/login")
	if method == "POST":
		if str(headers.get("x-requested-with", "")) != "mrw":
			return _json(403, {"ok": false, "message": "Not allowed from here."})
		return _api(path, target.get_slice("?", 1) if target.contains("?") else "", body)
	return route(target)


func _cookie(headers: Dictionary) -> String:
	for part in str(headers.get("cookie", "")).split(";"):
		var kv := String(part).strip_edges().split("=", true, 1)
		if kv.size() == 2 and kv[0] == COOKIE:
			return kv[1]
	return ""


func _signed_in(headers: Dictionary) -> bool:
	var tok := _cookie(headers)
	return tok != "" and int(_sessions.get(tok, 0)) > Time.get_ticks_msec()


func _login(body: PackedByteArray, remote: String) -> Dictionary:
	var now := Time.get_ticks_msec()
	var fail: Dictionary = _fails.get(remote, {"n": 0, "until": 0})
	if int(fail.until) > now:
		return _html(429, WebPages.login("Too many wrong codes. Wait a minute and try again."))
	var form := {}
	for kv in body.get_string_from_utf8().split("&", false):
		var pair := String(kv).split("=", true, 1)
		form[pair[0].uri_decode()] = pair[1].replace("+", " ").uri_decode() if pair.size() > 1 else ""
	var given := str(form.get("pin", "")).replace(" ", "")
	if pin != "" and given.length() == pin.length() and given == pin:
		_fails.erase(remote)
		var tok := Crypto.new().generate_random_bytes(16).hex_encode()
		_sessions[tok] = now + SESSION_MS
		return _redirect("/", ["Set-Cookie: %s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Strict" % [COOKIE, tok, SESSION_MS / 1000]])
	fail["n"] = int(fail.n) + 1
	if int(fail.n) >= MAX_FAILS:
		fail["n"] = 0
		fail["until"] = now + LOCK_MS
	_fails[remote] = fail
	return _html(401, WebPages.login("That code is not right. Look at the headset: Docs, then Manage on your PC."))


func _redirect(location: String, extra: Array = []) -> Dictionary:
	var hs: Array = ["Location: %s" % location]
	hs.append_array(extra)
	return {"status": 303, "type": "text/plain", "body": PackedByteArray(), "headers": hs}


func _asset(path: String) -> Dictionary:
	var cache := "public, max-age=3600"
	match path:
		"/assets/app.css":
			return {"status": 200, "type": "text/css; charset=utf-8", "body": WebAssets.CSS.to_utf8_buffer(), "cache": cache}
		"/assets/app.js":
			return {"status": 200, "type": "text/javascript; charset=utf-8", "body": WebAssets.JS.to_utf8_buffer(), "cache": cache}
		"/assets/logo.svg":
			return {"status": 200, "type": "image/svg+xml", "body": WebAssets.LOGO.to_utf8_buffer(), "cache": cache}
	return _text(404, "Not found")


# ------------------------------------------------------------------------------------------------ pages (GET)

## {status, type, body, download?} for a GET request target such as "/svg/f0123.svg?bg=dark". No sign-in check (see handle()).
func route(target: String) -> Dictionary:
	var path := target.get_slice("?", 0)
	var query := _query(target.get_slice("?", 1) if target.contains("?") else "")
	path = path.uri_decode()
	var doc: Document = doc_source.call() if doc_source.is_valid() else null
	if doc == null:
		if path.begins_with("/api/"):
			return _json(503, {"ok": false, "message": "No document is open in the app."})
		return _html(503, WebPages.message("No document", "No document is open in the app."))
	_watch(doc)
	var bg := str(query.get("bg", "white"))
	if not BACKGROUNDS.has(bg):
		bg = "white"
	var opts := {"background": bg, "grid": query.get("grid", "") == "1"}
	if path == "/":
		return _html(200, WebPages.dashboard(_snapshot(doc), _export_files(), _pdf_list()))
	if path == "/api/rev":
		return _json(200, {"ok": true})
	if path == "/live":
		return _html(200, WebPages.live(doc.name))
	if path == "/ai":
		return _html(200, WebPages.ai(doc.name))
	if path == "/keys":
		return _html(200, WebPages.keys(doc.name))
	if path == "/api/keys/state":
		if not keys_api.is_valid():
			return _json_plain(501, {"ok": false, "message": "The keys page is not available."})
		return _json_plain(200, keys_api.call("state", {}))
	if path == "/api/ai/state":
		if not ai_api.is_valid():
			return _json_plain(501, {"ok": false, "message": "The assistant is not available."})
		return _json_plain(200, ai_api.call("state", {}))
	if path == "/api/live":
		return _json_plain(200, _live(doc, str(query.get("since", ""))))
	if path == "/all":
		return _gallery(doc, "")
	if path == "/all.zip":
		return _zip(doc, _entries(doc, ""), doc.name, opts)
	if path == "/zip":
		var entries: Array = []
		for id in str(query.get("ids", "")).split(",", false):
			if _is_canvas(doc, id):
				entries.append({"folder": "", "frame": doc.frames[id]})
		return _zip(doc, entries, "%s - selected" % doc.name, opts)
	if path.begins_with("/room/"):
		var rest := path.substr(6)
		if rest.ends_with(".zip"):
			var rid := rest.trim_suffix(".zip")
			return _zip(doc, _entries(doc, rid), "%s - %s" % [doc.name, str(_group(doc, rid).get("name", ""))], opts)
		return _gallery(doc, rest)
	if path.begins_with("/svg/") and path.ends_with(".svg"):
		var fid := path.substr(5).trim_suffix(".svg")
		if not _is_canvas(doc, fid):
			return _html(404, WebPages.message("Not found", "There is no such canvas."))
		if query.has("v") and query.get("dl", "") != "1":
			# the live view: ?v= is the canvas version the page was told about; one drawing of it serves every viewer
			return {"status": 200, "type": "image/svg+xml; charset=utf-8", "body": _live_svg(doc, fid, bg, opts), "cache": "private, max-age=600"}
		var res := {"status": 200, "type": "image/svg+xml; charset=utf-8", "body": SvgExport.canvas(doc, fid, opts).to_utf8_buffer()}
		if query.get("dl", "") == "1":
			res["download"] = "%s.svg" % DocStore.safe_name((doc.frames[fid] as FrameData).name)
		return res
	if path.begins_with("/view/"):
		var vid := path.substr(6)
		if not _is_canvas(doc, vid):
			return _html(404, WebPages.message("Not found", "There is no such canvas."))
		return _view(doc, vid, bg)
	if path.begins_with("/files/"):
		return _file(path.substr(7))
	if path.begins_with("/pdf/") and path.ends_with(".pdf"):
		return _pdf_file(path.substr(5).trim_suffix(".pdf"), query.get("dl", "") == "1")
	return _html(404, WebPages.message("Not found", "There is nothing at this address."))


func _query(qs: String) -> Dictionary:
	var out := {}
	for kv in qs.split("&", false):
		var pair := String(kv).split("=", true, 1)
		out[pair[0].uri_decode()] = pair[1].replace("+", " ").uri_decode() if pair.size() > 1 else "1"
	return out


func _is_canvas(doc: Document, fid: String) -> bool:
	return doc.frames.has(fid) and (doc.frames[fid] as FrameData).kind == FrameData.CANVAS


## Rooms with their canvases: the room you are in first, then the others, then canvases whose room is gone. [{id, name, here, frames}]
func _groups(doc: Document) -> Array:
	var here := str(room_source.call()) if room_source.is_valid() else ""
	var by_room := {}
	for f in doc.frames.values():
		var fd: FrameData = f
		if fd.kind != FrameData.CANVAS:
			continue
		if not by_room.has(fd.room):
			by_room[fd.room] = []
		by_room[fd.room].append(fd)
	var out: Array = []
	var known := {}
	for r in doc.rooms:
		known[str(r.id)] = true
		var list: Array = by_room.get(str(r.id), [])
		if not list.is_empty():
			out.append({"id": str(r.id), "name": str(r.name), "here": str(r.id) == here, "frames": _sorted(list)})
	var lost: Array = []
	for rid in by_room.keys():
		if not known.has(rid):
			lost.append_array(by_room[rid])
	if not lost.is_empty():
		out.append({"id": "none", "name": "No room", "here": false, "frames": _sorted(lost)})
	for i in out.size():
		if out[i].here:
			out.push_front(out.pop_at(i))
			break
	return out


func _sorted(list: Array) -> Array:
	list.sort_custom(func(a, b): return a.created < b.created or (a.created == b.created and a.name < b.name))
	return list


func _group(doc: Document, rid: String) -> Dictionary:
	for g in _groups(doc):
		if g.id == rid:
			return g
	return {}


func _entries(doc: Document, rid: String) -> Array:
	var groups: Array = [_group(doc, rid)] if rid != "" else _groups(doc)
	var out: Array = []
	for g in groups:
		if (g as Dictionary).is_empty():
			continue
		var folder := ""
		if rid == "" and groups.size() > 1:
			folder = DocStore.safe_name(g.name) + "/"
		for f in g.frames:
			out.append({"folder": folder, "frame": f})
	return out


## What the pages need to know about the document, as plain data.
func _snapshot(doc: Document) -> Dictionary:
	var groups: Array = []
	var total := 0
	for g in _groups(doc):
		var frames: Array = []
		for f in g.frames:
			var fd: FrameData = f
			var list := doc.items_of(fd.id)
			var bb := _extent(fd, list)
			frames.append({"id": fd.id, "name": fd.name, "items": list.size(), "w": bb.x, "h": bb.y})
		total += frames.size()
		groups.append({"id": g.id, "name": g.name, "here": g.here, "frames": frames})
	return {"doc": doc.name, "rev": _rev(doc), "total": total, "items": doc.items.size(), "groups": groups}


## Width and height in metres of what is on a canvas (the canvas itself while it is empty).
func _extent(fd: FrameData, list: Array) -> Vector2:
	if list.is_empty():
		return fd.size
	var r := Rect2()
	var first := true
	for it in list:
		var ib: Rect2 = (it as Item).bounds()
		r = ib if first else r.merge(ib)
		first = false
	return r.size * fd.scale


func _rev(doc: Document) -> String:
	var files := _export_files()
	var newest := 0
	for f in files:
		newest = maxi(newest, int(f.modified))
	var pdf_stamp := 0
	for e in _pdf_list():
		pdf_stamp += int(e.added) + int(e.pages)
	return "%d.%d.%d.%d.%d.%d" % [doc.modified, doc.frames.size(), doc.items.size(), files.size(), newest, pdf_stamp]


func _gallery(doc: Document, rid: String) -> Dictionary:
	var groups: Array = [_group(doc, rid)] if rid != "" else _groups(doc)
	if groups.size() == 1 and (groups[0] as Dictionary).is_empty():
		return _html(404, WebPages.message("Not found", "There is no such room."))
	var snap := _snapshot(doc)
	var shown: Array = []
	for g in snap.groups:
		if rid == "" or g.id == rid:
			shown.append(g)
	var title := "All canvases" if rid == "" else str((groups[0] as Dictionary).name)
	return _html(200, WebPages.gallery(snap, title, shown, "/all.zip" if rid == "" else "/room/%s.zip" % rid.uri_encode()))


func _view(doc: Document, fid: String, bg: String) -> Dictionary:
	var order: Array = []
	for g in _groups(doc):
		order.append_array(g.frames)
	var at := -1
	for i in order.size():
		if (order[i] as FrameData).id == fid:
			at = i
	var snap := _snapshot(doc)
	var info := {"id": fid, "name": (doc.frames[fid] as FrameData).name}
	var prev_id := (order[at - 1] as FrameData).id if at > 0 else ""
	var next_id := (order[at + 1] as FrameData).id if at >= 0 and at < order.size() - 1 else ""
	return _html(200, WebPages.viewer(snap, info, prev_id, next_id, bg))


func _zip(doc: Document, entries: Array, label: String, opts: Dictionary) -> Dictionary:
	if entries.is_empty():
		return _html(404, WebPages.message("Nothing to download", "There are no canvases to put in a zip."))
	var packer := ZIPPacker.new()
	if packer.open(TMP_ZIP) != OK:
		return _html(503, WebPages.message("Could not zip", "The device could not create the zip file."))
	var by_folder := {}
	for e in entries:
		if not by_folder.has(e.folder):
			by_folder[e.folder] = []
		by_folder[e.folder].append(e.frame)
	for folder in by_folder.keys():
		var frames: Array = by_folder[folder]
		var names := SvgExport.file_names(frames)
		for f in frames:
			var fd: FrameData = f
			packer.start_file("%s%s.svg" % [folder, names[fd.id]])
			packer.write_file(SvgExport.canvas(doc, fd.id, opts).to_utf8_buffer())
			packer.close_file()
	packer.close()
	var bytes := FileAccess.get_file_as_bytes(TMP_ZIP)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_ZIP))
	return {"status": 200, "type": "application/zip", "body": bytes, "download": "%s.zip" % DocStore.safe_name(label)}


# ------------------------------------------------------------------------------------------------ live view

## Starts following a document's signals, so that it is known which canvas changed when. Called on every request: only a different
## document (the headset opened another one) does anything.
func _watch(doc: Document) -> void:
	if doc == _watched:
		return
	_unwatch()
	_watched = doc
	_base = _bump()
	for it in doc.items.values():
		_item_frame[(it as Item).id] = (it as Item).frame
	doc.item_added.connect(_on_item_added)
	doc.item_removed.connect(_on_item_removed)
	doc.item_changed.connect(_on_item_changed)
	doc.frame_added.connect(_on_frame_changed)
	doc.frame_removed.connect(_on_frame_changed)
	doc.frame_changed.connect(_on_frame_changed)
	doc.changed.connect(_bump)


func _unwatch() -> void:
	if _watched != null:
		_watched.item_added.disconnect(_on_item_added)
		_watched.item_removed.disconnect(_on_item_removed)
		_watched.item_changed.disconnect(_on_item_changed)
		_watched.frame_added.disconnect(_on_frame_changed)
		_watched.frame_removed.disconnect(_on_frame_changed)
		_watched.frame_changed.disconnect(_on_frame_changed)
		_watched.changed.disconnect(_bump)
		_watched = null
	_frame_rev.clear()
	_item_frame.clear()
	_dims.clear()
	_svg_cache.clear()


func _bump() -> int:
	_seq += 1
	return _seq


func _on_item_added(it: Item) -> void:
	_item_frame[it.id] = it.frame
	_frame_rev[it.frame] = _bump()


func _on_item_removed(it: Item) -> void:
	_item_frame.erase(it.id)
	_frame_rev[it.frame] = _bump()


func _on_item_changed(it: Item) -> void:
	var was := str(_item_frame.get(it.id, it.frame))
	_item_frame[it.id] = it.frame
	var n := _bump()
	_frame_rev[it.frame] = n
	if was != it.frame:
		_frame_rev[was] = n


## A canvas itself changed (named, moved, resized, added, removed). Moving one changes nothing on it; only an empty canvas is drawn
## from its size.
func _on_frame_changed(f: FrameData) -> void:
	_dims.erase(f.id)
	if _watched != null and _watched.items_of(f.id).is_empty():
		_frame_rev[f.id] = _bump()


func _frame_version(fid: String) -> int:
	return int(_frame_rev.get(fid, _base))


## What the live page is told about a canvas, and puts in the address of its picture: different whenever the picture would differ.
func _version_text(fid: String) -> String:
	return "%d.%d" % [_epoch, _frame_version(fid)]


## The answer to /api/live?since=<token>. The token changes with every edit and with the room you are in; while it is the one the page
## already has, only the small header comes back (who is drawing where), otherwise the whole list of rooms and canvases with versions.
func _live(doc: Document, since: String) -> Dictionary:
	var here := str(room_source.call()) if room_source.is_valid() else ""
	var token := "%d.%d.%s" % [_epoch, _seq, here]
	var out := {"ok": true, "seq": token, "doc": {"id": doc.id, "name": doc.name}, "active": str(active_source.call()) if active_source.is_valid() else "", "here": here}
	if since == token:
		return out
	var groups: Array = []
	for g in _groups(doc):
		var frames: Array = []
		for f in g.frames:
			var fd: FrameData = f
			var d := _live_dims(doc, fd)
			frames.append({"id": fd.id, "name": fd.name, "rev": _version_text(fd.id), "items": d.items, "w": d.w, "h": d.h, "look": _look(fd)})
		groups.append({"id": g.id, "name": g.name, "here": g.here, "frames": frames})
	out["groups"] = groups
	return out


## The background that shows a canvas as it looks in the headset: white on a white backing, dark on the others (ink is mostly light
## on the glass of the passthrough).
func _look(fd: FrameData) -> String:
	var backing := fd.backing
	if backing == "" and backing_source.is_valid():
		backing = str(backing_source.call())
	return "white" if backing == "white" else "dark"


func _live_dims(doc: Document, fd: FrameData) -> Dictionary:
	var rev := _frame_version(fd.id)
	var c: Dictionary = _dims.get(fd.id, {})
	if int(c.get("rev", -1)) != rev:
		var list := doc.items_of(fd.id)
		var ext := _extent(fd, list)
		c = {"rev": rev, "items": list.size(), "w": ext.x, "h": ext.y}
		_dims[fd.id] = c
	return c


## The picture of a canvas as the live view asks for it. Drawn once per change, however many people are watching.
func _live_svg(doc: Document, fid: String, bg: String, opts: Dictionary) -> PackedByteArray:
	var key := "%s|%s|%s" % [fid, bg, opts.grid]
	var rev := _frame_version(fid)
	var hit: Dictionary = _svg_cache.get(key, {})
	if int(hit.get("rev", -1)) == rev:
		return hit.bytes
	if _svg_cache.size() >= LIVE_CACHE:
		_svg_cache.clear()
	var bytes := SvgExport.canvas(doc, fid, opts).to_utf8_buffer()
	_svg_cache[key] = {"rev": rev, "bytes": bytes}
	return bytes


# ------------------------------------------------------------------------------------------------ saved files

func _files_root() -> String:
	return files_dir if files_dir != "" else DocStore.export_dir()


## Files the app's Export buttons saved: [{rel, ext, size, modified}], newest first. One folder level is looked into.
func _export_files() -> Array:
	var root := _files_root()
	var out: Array = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	for fname in dir.get_files():
		_add_file(out, "", fname, root)
	for sub in dir.get_directories():
		var d2 := DirAccess.open("%s/%s" % [root, sub])
		if d2 != null:
			for fname in d2.get_files():
				_add_file(out, sub + "/", fname, root)
	out.sort_custom(func(a, b): return a.modified > b.modified)
	return out


func _add_file(out: Array, folder: String, fname: String, root: String) -> void:
	var rel := folder + fname
	if _file_path(rel) == "":
		return
	var path := "%s/%s" % [root, rel]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	out.append({"rel": rel, "ext": fname.get_extension().to_lower(), "size": f.get_length(), "modified": FileAccess.get_modified_time(path)})


## Absolute path of a saved file given its name as listed ("Doc/Canvas 1.svg"), "" if the name is not one the listing could contain.
func _file_path(rel: String) -> String:
	if rel == "" or not RegEx.create_from_string(r"^[A-Za-z0-9 _.\-]+(/[A-Za-z0-9 _.\-]+)?$").search(rel):
		return ""
	var dots := RegEx.create_from_string(r"^[ .]*$")
	for seg in rel.split("/"):
		if dots.search(seg) != null or String(seg).begins_with("."):
			return ""
	if not FILE_EXTS.has(rel.get_extension().to_lower()):
		return ""
	return "%s/%s" % [_files_root(), rel]


func _file(rel: String) -> Dictionary:
	var path := _file_path(rel)
	if path == "" or not FileAccess.file_exists(path):
		return _html(404, WebPages.message("Not found", "That file is not on the headset any more."))
	return {"status": 200, "type": FILE_TYPES[rel.get_extension().to_lower()], "body": FileAccess.get_file_as_bytes(path), "download": rel.get_file()}


# ------------------------------------------------------------------------------------------------ PDFs

func _pdf_list() -> Array:
	return pdf_library.list() if pdf_library != null else []


func _pdf_file(id: String, download: bool) -> Dictionary:
	if pdf_library == null or not pdf_library.has(id):
		return _html(404, WebPages.message("Not found", "That PDF is not on the headset any more."))
	var name := "%s.pdf" % DocStore.safe_name(str(pdf_library.entry(id).name))
	var res := {"status": 200, "type": "application/pdf", "body": pdf_library.file_bytes(id)}
	if download:
		res["download"] = name
	else:
		res["headers"] = ["Content-Disposition: inline; filename=\"%s\"" % name]
	return res


# ------------------------------------------------------------------------------------------------ changes (POST)

func _api(path: String, qs: String, body: PackedByteArray) -> Dictionary:
	var doc: Document = doc_source.call() if doc_source.is_valid() else null
	if doc == null:
		return _json(503, {"ok": false, "message": "No document is open in the app."})
	if path.begins_with("/api/keys/"):
		if not keys_api.is_valid():
			return _json_plain(501, {"ok": false, "message": "The keys page is not available."})
		var kres: Dictionary = keys_api.call(path.substr(10), _json_body(body))
		return _json_plain(200 if bool(kres.get("ok", false)) else 422, kres)
	if path.begins_with("/api/ai/"):
		if not ai_api.is_valid():
			return _json_plain(501, {"ok": false, "message": "The assistant is not available."})
		var res: Dictionary = ai_api.call(path.substr(8), _json_body(body))
		return _json_plain(200 if bool(res.get("ok", false)) else 422, res)
	match path:
		"/api/delete":
			var data := _json_body(body)
			var removed := 0
			for id in (data.get("ids", []) as Array).slice(0, 500):
				if _is_canvas(doc, str(id)) and delete_canvas.is_valid():
					delete_canvas.call(str(id))
					removed += 1
			if removed == 0:
				return _json(404, {"ok": false, "message": "Those canvases are already gone."}, doc)
			return _json(200, {"ok": true, "deleted": removed, "message": "Deleted %s" % WebPages.plural(removed, "canvas", "canvases")}, doc)
		"/api/rename":
			var data2 := _json_body(body)
			var id2 := str(data2.get("id", ""))
			var new_name := str(data2.get("name", "")).strip_edges().left(80)
			if not _is_canvas(doc, id2) or new_name == "" or not rename_canvas.is_valid():
				return _json(400, {"ok": false, "message": "That canvas cannot be renamed."}, doc)
			rename_canvas.call(id2, new_name)
			return _json(200, {"ok": true, "name": (doc.frames[id2] as FrameData).name}, doc)
		"/api/upload":
			if not import_svg.is_valid():
				return _json(501, {"ok": false, "message": "Importing is not available."})
			if body.is_empty():
				return _json(400, {"ok": false, "message": "The file is empty."})
			var fname := str(_query(qs).get("name", "drawing.svg")).get_file().get_basename().strip_edges().left(60)
			var res: Dictionary = import_svg.call(body.get_string_from_utf8(), fname if fname != "" else "Imported")
			return _json(200 if bool(res.get("ok", false)) else 422, res, doc)
		"/api/pdf":
			if pdf_library == null:
				return _json(501, {"ok": false, "message": "PDFs are not available."})
			if body.is_empty():
				return _json(400, {"ok": false, "message": "The file is empty."})
			var q := _query(qs)
			var added := pdf_library.add(body, str(q.get("name", "document.pdf")))
			if not bool(added.ok):
				return _json(422, added, doc)
			if str(q.get("show", "1")) != "0" and show_pdf.is_valid():
				var shown: Dictionary = show_pdf.call(str(added.id))
				added["shown"] = bool(shown.get("ok", false))
				if bool(added.shown):
					added["message"] = "%s: %s, %s. It is in front of you." % [added.name, WebPages.plural(int(added.pages), "page"), "added" if not bool(added.dup) else "it was here already"]
				else:
					added["message"] = "%s (not put in front of you: %s)" % [added.message, str(shown.get("message", ""))]
			return _json(200, added, doc)
		"/api/pdf/show":
			var dp := _json_body(body)
			if pdf_library == null or not show_pdf.is_valid():
				return _json(501, {"ok": false, "message": "PDFs are not available."})
			var sres: Dictionary = show_pdf.call(str(dp.get("id", "")))
			return _json(200 if bool(sres.get("ok", false)) else 422, sres, doc)
		"/api/pdf/delete":
			var dd := _json_body(body)
			var gone_pdfs := 0
			for pid in (dd.get("ids", []) as Array).slice(0, 100):
				if pdf_library != null and pdf_library.remove(str(pid)):
					gone_pdfs += 1
			if gone_pdfs == 0:
				return _json(404, {"ok": false, "message": "Those PDFs are already gone."}, doc)
			return _json(200, {"ok": true, "message": "Deleted %s" % WebPages.plural(gone_pdfs, "PDF")}, doc)
		"/api/pdf/rename":
			var dr := _json_body(body)
			if pdf_library == null or not pdf_library.has(str(dr.get("id", ""))) or str(dr.get("name", "")).strip_edges() == "":
				return _json(400, {"ok": false, "message": "That PDF cannot be renamed."}, doc)
			pdf_library.rename(str(dr.id), str(dr.name))
			return _json(200, {"ok": true, "name": str(pdf_library.entry(str(dr.id)).name)}, doc)
		"/api/files/delete":
			var data3 := _json_body(body)
			var gone := 0
			for rel in (data3.get("names", []) as Array).slice(0, 200):
				var p := _file_path(str(rel))
				if p != "" and FileAccess.file_exists(p) and DirAccess.remove_absolute(p) == OK:
					gone += 1
					var folder := p.get_base_dir()
					if folder != _files_root() and DirAccess.get_files_at(folder).is_empty() and DirAccess.get_directories_at(folder).is_empty():
						DirAccess.remove_absolute(folder)
			if gone == 0:
				return _json(404, {"ok": false, "message": "Those files are already gone."}, doc)
			return _json(200, {"ok": true, "message": "Deleted %s" % WebPages.plural(gone, "file")}, doc)
	return _json(404, {"ok": false, "message": "Unknown request."})


func _json_body(body: PackedByteArray) -> Dictionary:
	var text := body.get_string_from_utf8().strip_edges()
	if not text.begins_with("{"):
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


# ------------------------------------------------------------------------------------------------ answers

func _text(status: int, text: String) -> Dictionary:
	return {"status": status, "type": "text/plain; charset=utf-8", "body": text.to_utf8_buffer()}


func _html(status: int, html: String) -> Dictionary:
	return {"status": status, "type": "text/html; charset=utf-8", "body": html.to_utf8_buffer()}


## A JSON answer; with the document given it carries the document's revision, so the page knows the change was its own.
func _json(status: int, data: Dictionary, doc: Document = null) -> Dictionary:
	var d := data.duplicate()
	if doc != null:
		d["rev"] = _rev(doc)
	elif status == 200 and data.get("ok", false) and not data.has("rev"):
		var cur: Document = doc_source.call() if doc_source.is_valid() else null
		if cur != null:
			d["rev"] = _rev(cur)
	return _json_plain(status, d)


func _json_plain(status: int, data: Dictionary) -> Dictionary:
	return {"status": status, "type": "application/json; charset=utf-8", "body": JSON.stringify(data).to_utf8_buffer()}
