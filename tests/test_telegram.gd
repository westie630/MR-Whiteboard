extends Node
## Telegram (TelegramApi + TelegramBridge) on a real Board, with the network replaced by a fake that answers like the Bot API: the token
## checked, a chat linked with the code (wrong codes, a group, a locked-out chat, strangers once linked), files received (PDF, SVG, OBJ,
## .mrw; refused kinds, sizes, pictures), text put down with the placement tool, exports sent back as files, Telegram's errors (a bad token,
## a webhook in the way, no connection), a guest of a session, a Quest 2's limits, and the keys page's Telegram part.

const TOKEN := "123456789:AAH-abcdefghijklmnopqrstuvwxyz012345"
const SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="60mm" viewBox="0 0 100 60"><rect x="5" y="5" width="30" height="20" fill="#0000ff"/></svg>"""
const OBJ := "v 0 0 0\nv 0.3 0 0\nv 0 0.3 0\nv 0 0 0.3\nf 1 2 3\nf 1 3 4\nf 1 4 2\nf 2 4 3\n"

var t := TestCase.new("telegram")
var board: Board
var tg: TelegramBridge
var reqs: Array = []                        # requests the bridge made and nobody answered yet: {method, url, headers, body, done}
var sent: Array = []                        # every request made, answered or not
var files := {}                             # file_path -> bytes the fake's file server holds


func _ready() -> void:
	App.settings_path = "user://test_settings_telegram.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(App.settings_path))
	App.reload()
	App.docs_dir = "user://test_docs_telegram"
	App.pdf_dir = "user://test_pdfs_telegram"
	App.model_dir = "user://test_models_telegram"
	App.image_dir = "user://test_images_telegram"
	for d in [App.docs_dir, App.pdf_dir, App.model_dir, App.image_dir]:
		_clean(d)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_telegram.json"))
	var anchors := SimAnchors.new("user://test_sim_anchors_telegram.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.pdfs.threaded = false
	board.models.threaded = false
	var doc := Document.create("Export test")
	doc.add_room("Studio")
	board.open(doc)
	tg = board.telegram
	tg.http = _fake
	tg.wait_s = 0
	await _frames(3)

	_api()
	t.eq(tg.state, "off", "no token: the connection is off")
	await _connect()
	await _link()
	await _receive()
	await _limits()
	await _text_and_commands()
	await _send()
	await _keys()
	await _guest()
	await _errors()
	for d in [App.docs_dir, App.pdf_dir, App.model_dir, App.image_dir]:
		_clean(d)
	get_tree().quit(t.done())


# ------------------------------------------------------------------------------------------------ the fake Bot API

func _fake(method: int, url: String, headers: PackedStringArray, body: PackedByteArray, _timeout: float, done: Callable) -> void:
	var r := {"method": method, "url": url, "headers": headers, "body": body, "done": done}
	reqs.append(r)
	sent.append(r)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Answers the oldest open request whose address holds `part` with a Bot API answer; false if there was none.
func _answer(part: String, result: Variant, ok: bool = true, code: int = 200, extra: Dictionary = {}) -> bool:
	for i in reqs.size():
		var r: Dictionary = reqs[i]
		if str(r.url).contains(part):
			reqs.remove_at(i)
			var body := {"ok": ok}
			if ok:
				body["result"] = result
			else:
				body["error_code"] = code
				body["description"] = str(result)
			body.merge(extra)
			(r.done as Callable).call(HTTPRequest.RESULT_SUCCESS, code, JSON.stringify(body).to_utf8_buffer())
			return true
	return false


## Answers every open request the bridge makes along the way (messages, commands, files) until nothing but the next poll is left.
func _settle(max_rounds: int = 40) -> void:
	for i in max_rounds:
		await _frames(1)
		var progressed := false
		for r in reqs.duplicate():
			var url := str(r.url)
			if url.contains("/getUpdates"):
				continue
			reqs.erase(r)
			progressed = true
			if url.contains("/getFile"):
				var fid := url.get_slice("file_id=", 1)
				var have: bool = files.has("documents/" + fid)
				var body: Dictionary = {"ok": true, "result": {"file_id": fid, "file_path": "documents/" + fid}} if have else {"ok": false, "error_code": 400, "description": "Bad Request: file not found"}
				(r.done as Callable).call(HTTPRequest.RESULT_SUCCESS, 200 if have else 400, JSON.stringify(body).to_utf8_buffer())
			elif url.contains("/file/bot"):
				var fp := url.get_slice("/file/bot", 1).get_slice("/", 1) + "/" + url.get_slice("/file/bot", 1).get_slice("/", 2)
				(r.done as Callable).call(HTTPRequest.RESULT_SUCCESS, 200 if files.has(fp) else 404, files.get(fp, PackedByteArray()))
			else:
				(r.done as Callable).call(HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"ok": true, "result": true}).to_utf8_buffer())
		if not progressed and i > 2:
			return


## The next poll answered with these messages.
func _deliver(updates: Array) -> void:
	for i in 10:
		if _has_open("/getUpdates"):
			break
		await _frames(1)
	t.check(_answer("/getUpdates", updates), "a getUpdates was waiting to be answered")
	await _settle()


## Polls made before a restart: their answers would be dropped by the bridge, so the fake forgets them.
func _drop_polls() -> void:
	for r in reqs.duplicate():
		if str(r.url).contains("/getUpdates"):
			reqs.erase(r)


func _has_open(part: String) -> bool:
	for r in reqs:
		if str(r.url).contains(part):
			return true
	return false


var _uid := 100


func _msg(chat: Variant, text: String = "", type: String = "private", extra: Dictionary = {}) -> Dictionary:
	_uid += 1
	var m := {"message_id": _uid, "chat": {"id": float(chat), "type": type, "first_name": "Rob"}, "from": {"id": float(chat), "first_name": "Rob"}, "date": 0}
	if text != "":
		m["text"] = text
	m.merge(extra)
	return {"update_id": _uid, "message": m}


func _doc_msg(chat: Variant, fname: String, bytes: PackedByteArray, size: int = -1) -> Dictionary:
	var fid := "f%d" % (_uid + 1)
	files["documents/" + fid] = bytes
	return _msg(chat, "", "private", {"document": {"file_id": fid, "file_name": fname, "file_size": bytes.size() if size < 0 else size}})


## The texts of the messages sent since `from` (an index into `sent`).
func _texts(from: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(from, sent.size()):
		var r: Dictionary = sent[i]
		if str(r.url).contains("/sendMessage"):
			var d: Dictionary = JSON.parse_string((r.body as PackedByteArray).get_string_from_utf8())
			out.append(str(d.get("chat_id", "")) + ": " + str(d.text))
	return out


func _count(from: int, part: String) -> int:
	var n := 0
	for i in range(from, sent.size()):
		if str(sent[i].url).contains(part):
			n += 1
	return n


func _clean(dir: String) -> void:
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


# ------------------------------------------------------------------------------------------------ TelegramApi

func _api() -> void:
	t.check(TelegramApi.is_token(TOKEN) and not TelegramApi.is_token("123:short") and not TelegramApi.is_token("sk-ant-abc"), "bot tokens are told from other keys")
	t.eq(TelegramApi.code_in("/start 482913"), "482913", "the code after /start")
	t.eq(TelegramApi.code_in("482 913"), "482913", "the code as the headset shows it")
	t.eq(TelegramApi.code_in("/start"), "", "no code")
	t.eq(TelegramApi.code_in("hello 482913"), "", "not a code")
	t.eq(TelegramApi.command_of("/svg@wb_bot now"), "svg", "a command, with the bot's name")
	t.eq(TelegramApi.command_of("svg"), "", "plain text is not a command")
	t.eq(TelegramApi.kind_of("Plan.PDF"), "pdf", "kinds by extension")
	t.eq(TelegramApi.kind_of("car.gltf"), "model", "a .gltf is a model")
	t.eq(TelegramApi.kind_of("notes.docx"), "", "a kind the app cannot take")
	var u := TelegramApi.read_update({"update_id": 7, "message": {"chat": {"id": 5551234567.0, "type": "private"}, "from": {"first_name": "Rob"}, "caption": " hi ",
		"document": {"file_id": "X", "file_name": "../a.pdf", "file_size": 12}}})
	t.eq(u.chat, "5551234567", "a chat id is whole, as text")
	t.eq(u.text, "hi", "a caption is the text")
	t.eq(u.file.name, "a.pdf", "a file name keeps only its name")
	var bad := TelegramApi.parse(HTTPRequest.RESULT_SUCCESS, 429, '{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}'.to_utf8_buffer())
	t.check(not bad.ok and bad.code == 429 and bad.retry_after == 7, "Telegram asking to slow down is read")
	t.check(not TelegramApi.parse(HTTPRequest.RESULT_CANT_RESOLVE, 0, PackedByteArray()).ok, "no connection is an error")
	t.check(not TelegramApi.parse(HTTPRequest.RESULT_SUCCESS, 502, "<html>".to_utf8_buffer()).ok, "an answer that is not JSON is an error")
	var url := TelegramApi.updates_url(TOKEN, 42, 25)
	t.check(url.begins_with("https://api.telegram.org/bot" + TOKEN + "/getUpdates?") and url.contains("offset=42") and url.contains("timeout=25") and url.contains("allowed_updates=%5B%22message%22%5D"), "the getUpdates address")
	var form := TelegramApi.multipart({"chat_id": "222"}, "document", "a\"b.svg", "DATA".to_utf8_buffer(), "BND")
	var text := (form.body as PackedByteArray).get_string_from_utf8()
	t.eq(text, "--BND\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n222\r\n--BND\r\nContent-Disposition: form-data; name=\"document\"; filename=\"a'b.svg\"\r\nContent-Type: application/octet-stream\r\n\r\nDATA\r\n--BND--\r\n", "the multipart body")
	t.eq(form.headers[0], "Content-Type: multipart/form-data; boundary=BND", "its header")
	t.eq(TelegramApi.start_link("wb_bot", "123456"), "https://t.me/wb_bot?start=123456", "the link that sends /start with the code")


# ------------------------------------------------------------------------------------------------ the bot

func _connect() -> void:
	App.put("tg_token", TOKEN)
	t.eq(tg.state, "checking", "a token is checked at once")
	t.check(_has_open("/bot%s/getMe" % TOKEN), "with getMe")
	t.check(_answer("/getMe", {"id": 1, "is_bot": true, "username": "wb_bot"}), "getMe answered")
	t.eq(tg.state, "unlinked", "a good token and no chat: waiting for the code")
	t.eq(App.val("tg_bot"), "wb_bot", "the bot's name is kept")
	t.check(RegEx.create_from_string(r"^\d{6}$").search(tg.code) != null, "a 6-digit code is shown")
	await _settle()
	t.eq(_count(0, "/setMyCommands"), 1, "the chat's command menu is set")
	t.check(_has_open("/getUpdates"), "and the bot's messages are asked for")


func _link() -> void:
	var from := sent.size()
	var code := tg.code
	var wrong := "000000" if code != "000000" else "111111"
	await _deliver([_msg(-100, "/start " + code, "group")])
	t.eq(tg.state, "unlinked", "a group is never linked, even with the code")
	t.eq(_texts(from).size(), 0, "and not answered")
	await _deliver([_msg(111, "/start")])
	t.check(_texts(from)[0].contains("6-digit code"), "/start without the code says what to send")
	for i in TelegramBridge.MAX_FAILS:
		await _deliver([_msg(111, wrong)])
	var n := _texts(from).size()
	t.eq(n, 1 + TelegramBridge.MAX_FAILS, "every wrong code is answered")
	await _deliver([_msg(111, code)])
	t.eq(tg.state, "unlinked", "a chat that got it wrong five times is locked out, even with the right code")
	t.eq(_texts(from).size(), n, "and not answered while locked")
	await _deliver([_msg(222, "/start " + code)])
	t.eq(tg.state, "linked", "the right code links the chat")
	t.eq(App.val("tg_chat"), "222", "that chat")
	t.eq(App.val("tg_who"), "Rob", "and who it is")
	t.eq(tg.code, "", "the code is used up")
	t.check(_texts(from)[-1].begins_with("222: Linked"), "the chat is told")
	t.eq(int(App.val("tg_offset")), _uid + 1, "messages taken are counted, so a restart does not take them again")
	from = sent.size()
	await _deliver([_msg(333, "/svg"), _msg(333, "", "private", {"document": {"file_id": "zz", "file_name": "x.pdf", "file_size": 10}})])
	t.eq(sent.size() - from, 1, "a stranger is ignored once a chat is linked (only the next poll goes out)")


func _receive() -> void:
	var frames := board.doc.frames.size()
	var from := sent.size()
	await _deliver([_doc_msg(222, "base14.pdf", FileAccess.get_file_as_bytes("res://tests/fixtures/pdf/base14.pdf"))])
	t.eq(board.pdfs.list().size(), 1, "a PDF sent to the bot is in the library")
	t.eq(board.doc.frames.size(), frames + 1, "and put up as a canvas")
	var pdf_frame: FrameData = null
	for f in board.doc.frames.values():
		if (f as FrameData).pdf != "":
			pdf_frame = f
	t.check(pdf_frame != null and pdf_frame.pdf == str(board.pdfs.list()[0].id), "the canvas shows that PDF")
	t.check(_texts(from)[-1].contains("in front of you"), "the chat is told where it is: %s" % _texts(from)[-1])
	t.eq(_count(from, "/getFile"), 1, "the file was found with getFile")
	t.eq(_count(from, "/file/bot%s/documents/" % TOKEN), 1, "and fetched from the file address")

	from = sent.size()
	await _deliver([_doc_msg(222, "Sketch.svg", SVG.to_utf8_buffer())])
	var names := []
	for f in board.doc.frames.values():
		names.append((f as FrameData).name)
	t.check(names.has("Sketch"), "an SVG becomes a canvas named after the file")
	t.check(_texts(from)[-1].contains("Sketch"), "the chat is told")

	from = sent.size()
	await _deliver([_doc_msg(222, "tetra.obj", OBJ.to_utf8_buffer())])
	t.eq(board.models.list().size(), 1, "an OBJ is in the model library")
	t.eq(board.model_nodes.size(), 1, "and stands in front of the viewer")
	t.check(_texts(from)[-1].contains("in front of you"), "the chat is told: %s" % _texts(from)[-1])

	var other := Document.create("From the phone")
	other.add_room("Hall")
	var before := DocStore.list().size()
	from = sent.size()
	await _deliver([_doc_msg(222, "phone.mrw", JSON.stringify(other.to_dict()).to_utf8_buffer())])
	t.eq(DocStore.list().size(), before + 1, "a .mrw becomes a document of its own")
	var found := false
	for s in DocStore.list():
		if str(s.name) == "From the phone":
			found = s.id != other.id
	t.check(found, "with a new id (it never replaces one)")
	t.eq(board.doc.name, "Export test", "the open document stays open")
	await _deliver([_doc_msg(222, "fake.mrw", "{\"format\":\"other\"}".to_utf8_buffer())])
	t.check(_texts(from)[-1].contains("not an MR Whiteboard document"), "a file that is not one is refused")


func _limits() -> void:
	var from := sent.size()
	await _deliver([_doc_msg(222, "notes.docx", "x".to_utf8_buffer())])
	t.check(_texts(from)[-1].contains("not something the whiteboard can take"), "a kind the app cannot take is refused")
	await _deliver([_doc_msg(222, "huge.pdf", "x".to_utf8_buffer(), 25 * 1048576)])
	t.check(_texts(from)[-1].contains("20 MB"), "a file over Telegram's 20 MB is refused before fetching")
	t.eq(_count(from, "/getFile"), 0, "nothing was fetched")
	# a photo: Telegram sends it in several sizes; the biggest is fetched and goes into the headset's hand to drop on a canvas
	var shot := Image.create(400, 200, false, Image.FORMAT_RGBA8)
	shot.fill(Color(0.2, 0.5, 0.9))
	files["documents/big"] = shot.save_jpg_to_buffer()
	from = sent.size()
	await _deliver([_msg(222, "", "private", {"photo": [{"file_id": "small", "width": 90, "height": 45, "file_size": 900}, {"file_id": "big", "width": 400, "height": 200, "file_size": 9000}]})])
	t.check(_count(from, "file_id=big") == 1 and _count(from, "file_id=small") == 0, "a photo is fetched at its biggest size")
	t.check(str(board.placing_text.get("image", "")) != "", "and goes into the headset's hand, to drop on a canvas")
	t.check(_texts(from)[-1].contains("point at a canvas"), "the chat is told: %s" % _texts(from)[-1])
	board.cancel_place_text()
	from = sent.size()
	await _deliver([_doc_msg(222, "plan.png", shot.save_png_to_buffer())])
	t.check(str(board.placing_text.get("image", "")) != "", "a picture sent as a file too")
	board.cancel_place_text()
	from = sent.size()
	# a Quest 2 takes smaller models than Telegram allows
	var keep := board.models.budget
	board.models.budget = ModelBudget.for_tier("low")
	board.models.budget.max_file_mb = 1
	from = sent.size()
	await _deliver([_doc_msg(222, "big.glb", "x".to_utf8_buffer(), 3 * 1048576)])
	t.check(_texts(from)[-1].contains("more than this headset takes (1 MB)"), "this headset's own limit is checked before fetching")
	t.eq(_count(from, "/getFile"), 0, "and nothing fetched")
	board.models.budget = keep


func _text_and_commands() -> void:
	var from := sent.size()
	await _deliver([_msg(222, "Buy milk")])
	t.eq(str(board.placing_text.get("text", "")), "Buy milk", "plain text starts the text placement tool")
	t.check(_texts(from)[-1].contains("point at a canvas"), "the chat is told what to do in the headset")
	board.cancel_place_text()
	await _deliver([_msg(222, "/status")])
	t.check(_texts(from)[-1].contains("Export test") and _texts(from)[-1].contains("1 PDF"), "/status says what is open: %s" % _texts(from)[-1])
	await _deliver([_msg(222, "/help")])
	t.check(_texts(from)[-1].contains("/svg"), "/help lists the commands")
	await _deliver([_msg(222, "/dance")])
	t.check(_texts(from)[-1].begins_with("222: I do not know"), "an unknown command")


func _send() -> void:
	var from := sent.size()
	var res := tg.send_export("svg")
	t.check(bool(res.ok), "the canvases go out as SVG: %s" % res.message)
	await _settle()
	var docs: Array = []
	for i in range(from, sent.size()):
		if str(sent[i].url).contains("/sendDocument"):
			docs.append(sent[i])
	t.check(docs.size() >= 1 and str(res.message).contains(str(docs.size())), "one file per canvas: %s, %d sent" % [res.message, docs.size()])
	if not docs.is_empty():
		var d: Dictionary = docs[0]
		var body := (d.body as PackedByteArray).get_string_from_utf8()
		t.check(str(d.headers[0]).begins_with("Content-Type: multipart/form-data; boundary="), "sent as multipart")
		t.check(body.contains("name=\"chat_id\"\r\n\r\n222\r\n") and body.contains(".svg\"") and body.contains("<svg"), "to the linked chat, with the SVG in it")
		t.eq(d.method, HTTPClient.METHOD_POST, "with POST")
	# the SVG export writes into Documents/MR Whiteboard/<document>/ on a PC (the repository itself here): left clean
	var folder := Exporter.folder_for(board.doc)
	for f in DirAccess.get_files_at(folder):
		if str(f).get_extension() == "svg":
			DirAccess.remove_absolute(folder + "/" + str(f))
	if DirAccess.get_files_at(folder).is_empty():
		DirAccess.remove_absolute(folder)
	from = sent.size()
	t.check(bool(tg.send_export("mrw").ok), "the document file goes out too")
	await _settle()
	t.eq(_count(from, "/sendDocument"), 1, "as one file")
	from = sent.size()
	await _deliver([_msg(222, "/mrw")])
	t.eq(_count(from, "/sendDocument"), 1, "/mrw in the chat sends it")


func _keys() -> void:
	var keys := ApiKeys.new(board.ai, tg, true)
	var st := keys.state()
	var svc: Dictionary = {}
	for s in st.services:
		if s.id == "telegram":
			svc = s
	t.check(bool(svc.get("has_key", false)) and str(svc.key_hint) == "…" + TOKEN.right(4), "the keys page shows the token only by its end")
	t.check(not JSON.stringify(st).contains(TOKEN), "and never the whole token")
	t.check(str(svc.note).contains("linked to Rob"), "the note says who is linked")
	t.check(bool(st.telegram.linked) and str(st.telegram.state) == "linked", "the page sees the connection")
	t.check(not bool(keys.api("set", {"service": "telegram", "key": "sk-not-a-bot"}).ok), "a key that is not a bot token is refused")
	var from := sent.size()
	t.check(bool(keys.api("telegram", {"do": "test"}).ok), "the page sends a test message")
	await _settle()
	t.check(_texts(from)[-1].contains("A test from the whiteboard"), "it arrives in the linked chat")
	t.check(bool(keys.api("telegram", {"do": "off"}).ok) and tg.state == "off", "the page switches it off")
	_drop_polls()
	t.check(bool(keys.api("telegram", {"do": "on"}).ok) and tg.state == "checking", "and on again")
	t.check(_answer("/getMe", {"username": "wb_bot"}), "getMe again")
	t.eq(tg.state, "linked", "still linked after switching off and on")
	t.check(bool(keys.api("telegram", {"do": "unlink"}).ok) and tg.state == "unlinked", "the page unlinks the chat")
	st = keys.state()
	t.eq(str(st.telegram.link), "https://t.me/wb_bot?start=" + tg.code, "with the access code on, the page gets the link that links a chat")
	var open_page := ApiKeys.new(board.ai, tg, false).state()
	t.check(str(open_page.telegram.link) == "" and bool(open_page.telegram.code_in_headset) and not JSON.stringify(open_page).contains(tg.code), "without the access code the page never sees the code")
	await _settle()
	await _deliver([_msg(222, tg.code)])
	t.eq(tg.state, "linked", "linked again with the new code")


func _guest() -> void:
	board.session.role = Session.Role.CLIENT
	var frames := board.doc.frames.size()
	var res := tg.take("pdf", FileAccess.get_file_as_bytes("res://tests/fixtures/pdf/embedded.pdf"), "embedded.pdf")
	t.check(bool(res.ok) and str(res.message).contains("guest"), "a guest's PDF says why it was not put up: %s" % res.message)
	t.eq(board.doc.frames.size(), frames, "a guest's PDF is not put up as a canvas the others could not get")
	t.eq(board.pdfs.list().size(), 2, "it is kept in that headset's library")
	board.session.role = Session.Role.NONE
	# a phone sends one file at a time: an .obj, then its .mtl, which is joined to it where it stands
	t.eq(TelegramApi.kind_of("tet.mtl"), "model", "an .mtl is taken as part of a model")
	var obj := tg.take("model", "mtllib tet.mtl\nv 0 0 0\nv 0.2 0 0\nv 0 0.2 0\nusemtl blue\nf 1 3 2\n".to_utf8_buffer(), "Tet.obj")
	t.check(bool(obj.ok), "the .obj is put down: %s" % obj.message)
	var mtl := tg.take("model", "newmtl blue\nKd 0.1 0.2 0.9\n".to_utf8_buffer(), "tet.mtl")
	t.check(bool(mtl.ok) and str(mtl.message).contains("materials"), "its .mtl sent next is joined to it: %s" % mtl.message)
	var shown := ""
	for f in board.doc.frames.values():
		if (f as FrameData).is_model():
			shown = (f as FrameData).model
	t.check(shown != "" and board.models.entry(shown).get("ext", "") == "zip", "the model standing there is the one with its .mtl")


func _errors() -> void:
	# a webhook set on the bot blocks getUpdates: it is switched off
	var from := sent.size()
	await _frames(2)
	t.check(_answer("/getUpdates", "Conflict: can't use getUpdates method while webhook is active; use deleteWebhook to delete the webhook first", false, 409), "409 answered")
	t.eq(tg.state, "conflict", "a conflict is shown")
	await _settle()
	t.eq(_count(from, "/deleteWebhook"), 1, "the webhook is switched off")
	# no connection: tried again later, still linked
	await _frames(2)
	for r in reqs.duplicate():
		reqs.erase(r)
	tg._next_ms = 0
	await _frames(2)
	if _has_open("/getUpdates"):
		for i in reqs.size():
			if str(reqs[i].url).contains("/getUpdates"):
				var r: Dictionary = reqs[i]
				reqs.remove_at(i)
				(r.done as Callable).call(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray())
				break
	t.eq(tg.state, "offline", "no connection is shown")
	t.check(tg.is_linked(), "and the chat stays linked")
	t.check(tg._next_ms > Time.get_ticks_msec(), "it waits before trying again")
	# a token Telegram does not know
	tg._next_ms = 0
	await _frames(2)
	t.check(_answer("/getUpdates", "Unauthorized", false, 401), "401 answered")
	t.eq(tg.state, "bad_token", "a token Telegram refuses is shown")
	t.check(not tg.is_processing(), "and nothing more is tried")
	# another token: a new bot, so the chat is linked again
	App.put("tg_token", "987654321:BBH-abcdefghijklmnopqrstuvwxyz012345")
	t.eq(App.val("tg_chat"), "", "another token forgets the linked chat")
	t.eq(int(App.val("tg_offset")), 0, "and the message count")
	t.eq(tg.state, "checking", "and checks the new token")
	App.put("tg_token", "")
	t.eq(tg.state, "off", "no token: off")
