class_name TelegramBridge
extends Node
## Files between the headset and the user's own Telegram, through a bot the user makes with @BotFather. No server of ours is involved: the
## headset asks Telegram for the bot's new messages itself (long polling getUpdates over HTTPS), so it works on any network with internet.
##
##   Set up:  the bot token is pasted on the web page's keys page (or typed in Home > Share). The headset checks it (getMe) and shows a
##            6-digit code; the user sends the bot "/start <code>" (or just the code) from a private chat, and that one chat is linked.
##            Nobody else can use the bot: messages from any other chat are ignored once a chat is linked, and before that a wrong code
##            five times in a row locks a chat out for a minute (twenty wrong codes in all and the code changes).
##   In:      a PDF, an SVG, a 3D model (.glb, .gltf, .obj, .zip) or a .mrw document sent to the bot comes into the headset the way an
##            upload from the web page does (PDFs and models are put in front of the viewer); plain text is put down with the text
##            placement tool. Up to 20 MB (Telegram's limit for bots), and no more than this headset's own limits.
##   Out:     /svg, /glb, /mrw in the chat, or Home > Docs > Send to Telegram, send the open document's exports back as files.
##
## In a session, what the owner receives reaches the guests the usual way (DocSync for canvases, PdfShare and ModelShare for the files).
## A guest's own bot works too, but a PDF or model it receives stays in that headset's library: files only go from the owner to guests.
##
## The token is kept only in the app's settings, like the AI keys, and never written to the log.

signal changed()

const MAX_FAILS := 5                       # wrong codes in a row from one chat before it is locked out...
const LOCK_MS := 60 * 1000                 # ...for this long
const MAX_WRONG := 20                      # wrong codes from anyone before the code is replaced
const RETRY_MIN_S := 2.0                   # after a failed request: wait, doubling up to RETRY_MAX_S
const RETRY_MAX_S := 60.0
const MAX_LOOSE := 4                       # more SVGs than this go out as one .zip
const TMP_ZIP := "user://telegram_out.zip"
const HELP := "Send me a PDF, an SVG, a 3D model (.glb, .gltf, .obj or a .zip of one) or a .mrw document and it appears in the headset. Text you send me can be put on a canvas there.\n\nTo get files back: /svg (the canvases), /glb (the ink in 3D), /mrw (the document file). /status says what is open."

var board: Board
## (method, url, headers, body, timeout_s, done(result, code, body)): sends one HTTP request. Tests replace it with a fake.
var http := Callable()
var wait_s := TelegramApi.POLL_S           # how long a getUpdates may wait for a message on Telegram's side (tests: 0)
var state := "off"                         # off | checking | bad_token | unlinked | linked | offline | conflict
var error := ""                            # the last problem, in words
var code := ""                             # the linking code while no chat is linked
var busy := ""                             # what is being received or sent, in words

var _gen := 0                              # answers to requests made before the last restart are dropped
var _me_ok := false                        # getMe answered for this token
var _poll_out := false
var _next_ms := 0                          # when the next getUpdates (or getMe, while offline) may go
var _retry_s := 0.0
var _jobs: Array = []                      # messages to send, files to fetch or send: one at a time, in order
var _job_out := false
var _fails := {}                           # chat -> {n, until}: wrong codes before a chat is linked
var _wrong := 0


func _init() -> void:
	name = "Telegram"
	http = _send


func _ready() -> void:
	App.setting_changed.connect(_on_setting)
	restart()


func token() -> String:
	return str(App.val("tg_token")).strip_edges()


func bot() -> String:
	return str(App.val("tg_bot"))


func linked_chat() -> String:
	return str(App.val("tg_chat"))


func is_linked() -> bool:
	return state == "linked" or (linked_chat() != "" and state in ["offline", "conflict"])


## "482 913": the code as it is shown.
func code_text() -> String:
	return "%s %s" % [code.substr(0, 3), code.substr(3)] if code.length() == 6 else code


## Starts again from the token in the settings (called when the token or the switch changes).
func restart() -> void:
	_gen += 1
	_me_ok = false
	_poll_out = false
	_job_out = false
	_jobs.clear()
	_retry_s = 0.0
	error = ""
	busy = ""
	if token() == "" or not bool(App.val("tg_on")):
		state = "off"
		code = ""
		set_process(false)
		changed.emit()
		return
	state = "checking"
	set_process(true)
	changed.emit()
	_get_me()


## Forgets the linked chat: a new code is shown and the next chat that sends it is linked.
func unlink() -> void:
	App.put("tg_chat", "")
	App.put("tg_who", "")
	code = _new_code()
	_fails.clear()
	_wrong = 0
	if _me_ok:
		state = "unlinked"
	changed.emit()


func _on_setting(key: String) -> void:
	match key:
		"tg_token":
			# another bot: its chats, its name and its message count are not this one's
			App.put("tg_chat", "")
			App.put("tg_who", "")
			App.put("tg_bot", "")
			App.put("tg_offset", 0)
			restart()
		"tg_on":
			restart()


func _new_code() -> String:
	return "%06d" % (Crypto.new().generate_random_bytes(4).decode_u32(0) % 1000000)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not _job_out and not _jobs.is_empty() and _me_ok:
		_run_job(_jobs.pop_front())
	if _poll_out or now < _next_ms:
		return
	match state:
		"unlinked", "linked", "conflict":
			_poll()
		"offline":
			if _me_ok:
				_poll()
			else:
				_get_me()


func _settle() -> void:
	var was := state
	state = "linked" if linked_chat() != "" else "unlinked"
	if state == "unlinked" and code == "":
		code = _new_code()
	error = ""
	_retry_s = 0.0
	if state != was:
		changed.emit()


## After a failed request: waits longer each time (or as long as Telegram asked).
func _back_off(res: Dictionary, why: String) -> void:
	_retry_s = clampf(_retry_s * 2.0, RETRY_MIN_S, RETRY_MAX_S)
	var wait := maxf(_retry_s, float(res.get("retry_after", 0)))
	_next_ms = Time.get_ticks_msec() + int(wait * 1000.0)
	error = why
	changed.emit()


## A token Telegram does not know (401 / 404): nothing more is tried until it changes.
func _refused(res: Dictionary) -> bool:
	if int(res.code) == 401 or int(res.code) == 404:
		state = "bad_token"
		error = "Telegram does not know this bot token. Copy it again from @BotFather (/mybots, your bot, API Token)."
		set_process(false)
		changed.emit()
		return true
	return false


# ------------------------------------------------------------------------------------------------ the bot and its messages

func _get_me() -> void:
	var gen := _gen
	_poll_out = true
	http.call(HTTPClient.METHOD_GET, TelegramApi.method_url(token(), "getMe"), PackedStringArray(), PackedByteArray(), 30.0,
		func(result: int, status: int, body: PackedByteArray):
			if gen != _gen:
				return
			_poll_out = false
			var res := TelegramApi.parse(result, status, body)
			if not bool(res.ok):
				if not _refused(res):
					state = "offline"
					_back_off(res, str(res.error))
				return
			var me: Dictionary = res.result if res.result is Dictionary else {}
			App.put("tg_bot", str(me.get("username", "")))
			_me_ok = true
			_next_ms = 0
			print("[telegram] connected as @%s" % bot())
			_settle()
			changed.emit()
			_jobs.push_front({"t": "call", "method": "setMyCommands", "body": TelegramApi.commands_body(), "gen": _gen}))


func _poll() -> void:
	var gen := _gen
	_poll_out = true
	http.call(HTTPClient.METHOD_GET, TelegramApi.updates_url(token(), int(App.val("tg_offset")), wait_s), PackedStringArray(), PackedByteArray(),
		float(wait_s) + 20.0, func(result: int, status: int, body: PackedByteArray): _on_updates(gen, result, status, body))


func _on_updates(gen: int, result: int, status: int, body: PackedByteArray) -> void:
	if gen != _gen:
		return
	_poll_out = false
	var res := TelegramApi.parse(result, status, body)
	if not bool(res.ok):
		if _refused(res):
			return
		if int(res.code) == 409:
			state = "conflict"
			if str(res.error).to_lower().contains("webhook"):
				_jobs.push_front({"t": "call", "method": "deleteWebhook", "body": TelegramApi.json_body({}), "gen": _gen})
				_back_off(res, "The bot was set up to send its messages to a web address (a webhook): that is being switched off.")
			else:
				_back_off(res, "Another device or program is reading this bot's messages. Use one bot per headset.")
			return
		state = "offline"
		_back_off(res, str(res.error))
		return
	if state != "linked" and state != "unlinked":
		_settle()
	_retry_s = 0.0
	_next_ms = 0
	var updates: Array = res.result if res.result is Array else []
	var offset := int(App.val("tg_offset"))
	for u in updates:
		if u is Dictionary:
			var m := TelegramApi.read_update(u)
			offset = maxi(offset, int(m.update_id) + 1)
			_handle(m)
	if offset != int(App.val("tg_offset")):
		App.put("tg_offset", offset)          # kept: messages already taken are not taken again after a restart


func _handle(m: Dictionary) -> void:
	var chat := str(m.chat)
	if chat == "":
		return
	if linked_chat() == "":
		_try_link(m)
		return
	if chat != linked_chat():
		return                                                     # not the owner of this headset: not answered at all
	if m.has("file"):
		_receive(m.file)
		return
	if bool(m.photo):
		reply("Pictures are not something the whiteboard can show yet. Send a PDF, an SVG, a 3D model (.glb, .gltf, .obj or a .zip) or a .mrw document.")
		return
	var text := str(m.text)
	match TelegramApi.command_of(text):
		"":
			if text != "":
				_place_text(text)
		"start", "help":
			reply(HELP)
		"svg", "glb", "mrw":
			var res := send_export(TelegramApi.command_of(text))
			if not bool(res.ok):
				reply(str(res.message))
		"status":
			reply(_status())
		_:
			reply("I do not know that command.\n\n" + HELP)


func _try_link(m: Dictionary) -> void:
	if str(m.chat_type) != "private":
		return
	var chat := str(m.chat)
	var now := Time.get_ticks_msec()
	var f: Dictionary = _fails.get(chat, {"n": 0, "until": 0})
	if int(f.until) > now:
		return
	var given := TelegramApi.code_in(str(m.text))
	if given != "" and code != "" and given == code:
		App.put("tg_chat", chat)
		App.put("tg_who", str(m.who))
		code = ""
		_fails.clear()
		_wrong = 0
		state = "linked"
		changed.emit()
		reply("Linked to the whiteboard, %s.\n\n%s" % [str(m.who), HELP])
		_say("Telegram is linked to %s." % str(m.who))
		return
	if given == "":
		_reply_to(chat, "To link this chat to your headset, send me the 6-digit code it shows in Home > Share > Telegram.")
		return
	f["n"] = int(f.n) + 1
	if int(f.n) >= MAX_FAILS:
		f["n"] = 0
		f["until"] = now + LOCK_MS
	_fails[chat] = f
	_wrong += 1
	if _wrong >= MAX_WRONG:
		_wrong = 0
		code = _new_code()
		changed.emit()
	_reply_to(chat, "That code is not right. Look in the headset: Home > Share > Telegram.")


func _status() -> String:
	if board == null or board.doc == null:
		return "No document is open in the headset."
	var canvases := 0
	for f in board.doc.frames.values():
		if (f as FrameData).kind == FrameData.CANVAS:
			canvases += 1
	var s := "Open: \"%s\", %s." % [board.doc.name, WebPages.plural(canvases, "canvas", "canvases")]
	s += "\nIn the headset: %s, %s." % [WebPages.plural(board.pdfs.list().size(), "PDF"), WebPages.plural(board.models.list().size(), "3D model")]
	if board.session != null and board.session.role != Session.Role.NONE:
		s += "\nIn a session, as %s." % ("a guest" if board.session.is_client() else "its owner")
	return s


func _place_text(text: String) -> void:
	if board == null or board.doc == null:
		reply("No document is open in the headset.")
		return
	board.begin_place_text(text.left(TelegramApi.MAX_TEXT))
	reply("In the headset: point at a canvas and tap (or pinch) to put the text down. Back cancels.")


## A message to the linked chat (queued behind what is already being sent).
func reply(text: String) -> void:
	if linked_chat() != "":
		_reply_to(linked_chat(), text)


func _reply_to(chat: String, text: String) -> void:
	_jobs.append({"t": "msg", "chat": chat, "text": text.left(TelegramApi.MAX_TEXT), "gen": _gen})


func _say(text: String) -> void:
	if board != null:
		board.toast.emit(text)


# ------------------------------------------------------------------------------------------------ files in

func _receive(file: Dictionary) -> void:
	var fname := str(file.name)
	var kind := TelegramApi.kind_of(fname)
	if kind == "":
		reply("\"%s\" is not something the whiteboard can take. Send a PDF, an SVG, a 3D model (.glb, .gltf, .obj or a .zip of one) or a .mrw document." % fname)
		return
	var size := int(file.size)
	if size > TelegramApi.MAX_DOWNLOAD:
		reply("\"%s\" is %s: Telegram lets a bot fetch files of up to 20 MB. Use the web page on the Wi-Fi for it (Home > Share)." % [fname, WebPages.size_text(size)])
		return
	var limit := limit_mb(kind)
	if size > limit * 1048576:
		reply("\"%s\" is %s, more than this headset takes (%d MB)." % [fname, WebPages.size_text(size), limit])
		return
	_jobs.append({"t": "get", "file": file, "kind": kind, "gen": _gen})


## The biggest file of a kind this headset takes, in MB (a Quest 2 takes less than a Quest 3).
func limit_mb(kind: String) -> int:
	match kind:
		"pdf":
			return board.pdfs.budget.max_file_mb if board != null else 48
		"model":
			return board.models.budget.max_file_mb if board != null else 48
	return ExportServer.MAX_BODY / 1048576


## Takes a received file in, the way the web page's upload does. {ok, message}: the message goes back to the chat.
func take(kind: String, bytes: PackedByteArray, fname: String) -> Dictionary:
	if board == null or board.doc == null:
		return {"ok": false, "message": "No document is open in the headset."}
	var guest := board.session != null and board.session.is_client()
	var only_here := "You are a guest in a session, so it was kept in your headset's library and not put up for everyone (files go from the session's owner to the guests). Send it to the owner's bot, or put it up later from Home > Docs once you are on your own."
	match kind:
		"pdf":
			var added := board.pdfs.add(bytes, fname)
			if not bool(added.ok):
				return added
			var what := "\"%s\": %s%s" % [added.name, WebPages.plural(int(added.pages), "page"), " (it was there already)" if bool(added.get("dup", false)) else ""]
			if guest:
				return {"ok": true, "message": "%s. %s" % [what, only_here]}
			var shown := board.place_pdf(str(added.id))
			return {"ok": true, "message": "%s. %s" % [what, "It is in front of you in the headset." if bool(shown.ok) else "Kept in the headset (not put up: %s)" % shown.message]}
		"model":
			var got := board.models.add(bytes, fname)
			if not bool(got.ok) or bool(got.get("held", false)):
				return got
			if str(got.get("old", "")) != "":
				return {"ok": true, "message": "%s now has %s: it is shown with %s in the headset." % [got.name, fname, "it" if fname.get_extension().to_lower() != "mtl" else "its materials"]}
			var mwhat := "\"%s\"%s" % [got.name, " (it was there already)" if bool(got.get("dup", false)) else ""]
			if guest:
				return {"ok": true, "message": "%s. %s" % [mwhat, only_here]}
			var put := board.place_model(str(got.id))
			return {"ok": true, "message": "%s. %s" % [mwhat, "It stands in front of you in the headset." if bool(put.ok) else "Kept in the headset (not put down: %s)" % put.message]}
		"svg":
			if not board.canvas_edit_ok(false):
				return {"ok": false, "message": "This session does not let guests add canvases."}
			var res := board.import_svg(bytes.get_string_from_utf8(), fname.get_basename().strip_edges().left(60))
			if bool(res.get("ok", false)):
				_say("\"%s\" came from Telegram." % str(res.get("name", fname)))
				return {"ok": true, "message": "\"%s\" is a canvas in front of you in the headset." % str(res.get("name", fname))}
			return res
		"mrw":
			return import_document(bytes)
	return {"ok": false, "message": "Unknown kind of file."}


## A .mrw file becomes a document of its own (a new id, so it never replaces one). It is not opened: that would close the one in use.
func import_document(bytes: PackedByteArray) -> Dictionary:
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed is Dictionary) or str((parsed as Dictionary).get("format", "")) != "mr-whiteboard":
		return {"ok": false, "message": "That .mrw file is not an MR Whiteboard document."}
	var d := Document.from_dict(parsed)
	d.id = U.uid("d")
	d.path = DocStore.path_for(d.id)
	if d.save() != OK:
		return {"ok": false, "message": "The headset could not save the document."}
	_say("The document \"%s\" came from Telegram: open it in Home > Docs." % d.name)
	return {"ok": true, "message": "\"%s\" is saved in the headset as a document: open it in Home > Docs." % d.name, "id": d.id}


# ------------------------------------------------------------------------------------------------ files out

## Exports the open document (svg | glb | mrw) and sends the files to the linked chat. {ok, message}
func send_export(kind: String) -> Dictionary:
	if linked_chat() == "" or token() == "":
		return {"ok": false, "message": "Link Telegram first: Home > Share > Telegram."}
	if board == null or board.doc == null:
		return {"ok": false, "message": "No document is open in the headset."}
	board.flush_save()
	var res: Dictionary
	match kind:
		"svg":
			res = Exporter.svg(board.doc, {"background": "white", "grid": false})
		"glb":
			res = Exporter.glb(board.doc)
		"mrw":
			res = Exporter.document(board.doc)
		_:
			return {"ok": false, "message": "Unknown export."}
	if not bool(res.ok):
		return res
	var paths: PackedStringArray = res.paths
	var caption := board.doc.name
	if paths.size() > MAX_LOOSE:
		var zipped := _zip(paths)
		if zipped.is_empty():
			return {"ok": false, "message": "The headset could not make the zip."}
		_jobs.append({"t": "send", "name": "%s.zip" % DocStore.safe_name(board.doc.name), "bytes": zipped, "caption": caption, "gen": _gen})
	else:
		for p in paths:
			_jobs.append({"t": "send", "name": p.get_file(), "path": p, "caption": caption, "gen": _gen})
	var n := 1 if paths.size() > MAX_LOOSE else paths.size()
	return {"ok": true, "message": "Sending %s to Telegram..." % WebPages.plural(n, "file")}


func _zip(paths: PackedStringArray) -> PackedByteArray:
	var packer := ZIPPacker.new()
	if packer.open(TMP_ZIP) != OK:
		return PackedByteArray()
	for p in paths:
		packer.start_file(p.get_file())
		packer.write_file(FileAccess.get_file_as_bytes(p))
		packer.close_file()
	packer.close()
	var bytes := FileAccess.get_file_as_bytes(TMP_ZIP)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_ZIP))
	return bytes


# ------------------------------------------------------------------------------------------------ the queue

func _run_job(job: Dictionary) -> void:
	if int(job.gen) != _gen:
		return
	_job_out = true
	match str(job.t):
		"msg":
			_post("sendMessage", TelegramApi.json_body({"chat_id": job.chat, "text": job.text}), TelegramApi.json_headers(), func(_res: Dictionary): _job_done())
		"call":
			_post(str(job.method), job.body, TelegramApi.json_headers(), func(_res: Dictionary): _job_done())
		"get":
			_fetch(job)
		"send":
			_upload(job)


func _job_done() -> void:
	_job_out = false
	if busy != "":
		busy = ""
		changed.emit()


func _post(method: String, body: PackedByteArray, headers: PackedStringArray, done: Callable, timeout: float = 60.0) -> void:
	var gen := _gen
	http.call(HTTPClient.METHOD_POST, TelegramApi.method_url(token(), method), headers, body, timeout, func(result: int, status: int, data: PackedByteArray):
		if gen != _gen:
			return
		var res := TelegramApi.parse(result, status, data)
		if not bool(res.ok):
			print("[telegram] %s failed: %s" % [method, res.error])
		done.call(res))


## getFile (where the file is), then the file itself, then take() and the answer to the chat.
func _fetch(job: Dictionary) -> void:
	var file: Dictionary = job.file
	var fname := str(file.name)
	var kind := str(job.kind)
	var gen := _gen
	busy = "Receiving \"%s\" from Telegram..." % fname
	changed.emit()
	http.call(HTTPClient.METHOD_GET, TelegramApi.method_url(token(), "getFile", {"file_id": file.id}), PackedStringArray(), PackedByteArray(), 30.0,
		func(result: int, status: int, body: PackedByteArray):
			if gen != _gen:
				return
			var res := TelegramApi.parse(result, status, body)
			var where: Dictionary = res.result if res.result is Dictionary else {}
			if not bool(res.ok) or str(where.get("file_path", "")) == "":
				_job_done()
				reply("Could not fetch \"%s\" from Telegram: %s" % [fname, res.error if str(res.error) != "" else "no file"])
				return
			http.call(HTTPClient.METHOD_GET, TelegramApi.file_url(token(), str(where.file_path)), PackedStringArray(), PackedByteArray(), 300.0,
				func(r2: int, s2: int, bytes: PackedByteArray):
					if gen != _gen:
						return
					_job_done()
					if r2 != HTTPRequest.RESULT_SUCCESS or s2 != 200 or bytes.is_empty():
						reply("Could not fetch \"%s\" from Telegram (HTTP %d). Try again." % [fname, s2])
						return
					var took := take(kind, bytes, fname)
					reply(str(took.message))
					if not bool(took.ok):
						_say("From Telegram: %s" % str(took.message))))


func _upload(job: Dictionary) -> void:
	var fname := str(job.name)
	var bytes: PackedByteArray = job.bytes if job.has("bytes") else FileAccess.get_file_as_bytes(str(job.get("path", "")))
	if bytes.is_empty():
		_job_out = false
		_say("Could not read \"%s\" to send it." % fname)
		return
	if bytes.size() > TelegramApi.MAX_UPLOAD:
		_job_out = false
		_say("\"%s\" is %s: Telegram takes files of up to 50 MB from a bot." % [fname, WebPages.size_text(bytes.size())])
		return
	busy = "Sending \"%s\" to Telegram..." % fname
	changed.emit()
	var form := TelegramApi.multipart({"chat_id": linked_chat(), "caption": str(job.get("caption", ""))}, "document", fname, bytes)
	_post("sendDocument", form.body, form.headers, func(res: Dictionary):
		_job_done()
		_say(("Sent \"%s\" to Telegram." % fname) if bool(res.ok) else ("Could not send \"%s\" to Telegram: %s" % [fname, res.error])), 300.0)


## The real HTTP request: one HTTPRequest node each, on its own thread (a 20 MB download must not stall the frame).
func _send(method: int, url: String, headers: PackedStringArray, body: PackedByteArray, timeout: float, done: Callable) -> void:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = timeout
	req.body_size_limit = TelegramApi.MAX_DOWNLOAD + 1048576
	add_child(req)
	req.request_completed.connect(func(result: int, status: int, _h: PackedStringArray, data: PackedByteArray):
		req.queue_free()
		done.call(result, status, data), CONNECT_ONE_SHOT)
	var err := req.request_raw(url, headers, method, body)
	if err != OK:
		req.queue_free()
		done.call(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray())
