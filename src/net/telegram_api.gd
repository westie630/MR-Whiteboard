class_name TelegramApi
extends RefCounted
## The Telegram Bot API as plain data: the addresses of its methods, its answers read into dictionaries, a file upload built as
## multipart/form-data, and what kind of file a name is. No network here (TelegramBridge sends), so all of it is tested without one.
## https://core.telegram.org/bots/api

const BASE := "https://api.telegram.org"
const POLL_S := 25                         # how long one getUpdates waits on Telegram's side for a message (long polling)
const MAX_DOWNLOAD := 20 * 1048576         # the biggest file a bot may fetch from Telegram (getFile)
const MAX_UPLOAD := 50 * 1048576           # the biggest file a bot may send (sendDocument)
const MAX_TEXT := 4000                     # a message holds 4096 characters; longer text is cut
const KINDS := {"pdf": "pdf", "svg": "svg", "glb": "model", "gltf": "model", "obj": "model", "zip": "model", "mtl": "model", "bin": "model", "mrw": "mrw"}
## The commands the chat's "/" menu offers (setMyCommands).
const COMMANDS := [
	["svg", "The canvases of the open document as SVG"],
	["glb", "The open document's ink as a 3D .glb"],
	["mrw", "The open document's file (.mrw)"],
	["status", "What is open in the headset"],
	["help", "What you can send me"],
]


## Does it look like a bot token ("123456789:AA...")? BotFather gives a number, a colon and 35 characters.
static func is_token(s: String) -> bool:
	return RegEx.create_from_string(r"^\d{5,16}:[A-Za-z0-9_-]{30,64}$").search(s.strip_edges()) != null


static func method_url(token: String, method: String, query: Dictionary = {}) -> String:
	var url := "%s/bot%s/%s" % [BASE, token, method]
	if not query.is_empty():
		var parts := PackedStringArray()
		for k in query:
			parts.append("%s=%s" % [str(k).uri_encode(), str(query[k]).uri_encode()])
		url += "?" + "&".join(parts)
	return url


## Where a file found with getFile is downloaded from.
static func file_url(token: String, file_path: String) -> String:
	return "%s/file/bot%s/%s" % [BASE, token, file_path]


## The getUpdates request for the next messages after `offset` (only messages: edits, reactions and the rest are not asked for).
static func updates_url(token: String, offset: int, wait_s: int = POLL_S) -> String:
	var q := {"timeout": wait_s, "allowed_updates": "[\"message\"]"}
	if offset > 0:
		q["offset"] = offset
	return method_url(token, "getUpdates", q)


## An answer of the Bot API: {ok, result, error, code (HTTP), retry_after (s, when Telegram asks to slow down)}.
static func parse(result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "result": null, "code": 0, "error": "No connection to Telegram (%s)." % _result_text(result), "retry_after": 0}
	var json := JSON.new()                 # (not JSON.parse_string: an error page from a proxy would print an engine error)
	var parsed: Variant = json.data if json.parse(body.get_string_from_utf8()) == OK else null
	if not (parsed is Dictionary):
		return {"ok": false, "result": null, "code": code, "error": "Telegram gave an answer that could not be read (HTTP %d)." % code, "retry_after": 0}
	var d: Dictionary = parsed
	if bool(d.get("ok", false)) and code == 200:
		return {"ok": true, "result": d.get("result"), "code": code, "error": "", "retry_after": 0}
	var params: Dictionary = d.get("parameters", {}) if d.get("parameters") is Dictionary else {}
	return {"ok": false, "result": null, "code": int(d.get("error_code", code)), "error": str(d.get("description", "HTTP %d" % code)),
		"retry_after": int(params.get("retry_after", 0))}


static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE: return "no internet?"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "secure connection failed"
		HTTPRequest.RESULT_TIMEOUT: return "timed out"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "too big"
	return "error %d" % result


## One update of getUpdates as what the bridge needs: {update_id, chat, chat_type, who, text, file?, photo}. `file` is {id, name, size}
## for a document; `photo` is true for a picture sent as a photo (compressed, no file name).
static func read_update(u: Dictionary) -> Dictionary:
	var out := {"update_id": int(u.get("update_id", 0)), "chat": "", "chat_type": "", "who": "", "text": "", "photo": false}
	var m: Variant = u.get("message")
	if not (m is Dictionary):
		return out
	var chat: Dictionary = m.get("chat", {}) if m.get("chat") is Dictionary else {}
	out["chat"] = _id_text(chat.get("id", ""))
	out["chat_type"] = str(chat.get("type", ""))
	var from: Dictionary = m.get("from", {}) if m.get("from") is Dictionary else {}
	var who := str(from.get("first_name", chat.get("first_name", ""))).strip_edges()
	var uname := str(from.get("username", chat.get("username", ""))).strip_edges()
	out["who"] = who if who != "" else ("@" + uname if uname != "" else "you")
	out["text"] = str(m.get("text", m.get("caption", ""))).strip_edges()
	if m.get("document") is Dictionary:
		var doc: Dictionary = m.document
		out["file"] = {"id": str(doc.get("file_id", "")), "name": str(doc.get("file_name", "file")).get_file(), "size": int(doc.get("file_size", 0))}
	out["photo"] = m.get("photo") is Array
	return out


## Chat ids are whole numbers that JSON hands over as floats: kept as text, without a ".0".
static func _id_text(v: Variant) -> String:
	if v is float or v is int:
		return str(int(v))
	return str(v)


## What the app does with a file of this name: pdf | svg | model | mrw, or "" for something it cannot take.
static func kind_of(file_name: String) -> String:
	return str(KINDS.get(file_name.get_extension().to_lower(), ""))


## A command ("/svg" or "/svg@my_bot" -> "svg"), or "" when the text is not one.
static func command_of(text: String) -> String:
	if not text.begins_with("/"):
		return ""
	return text.substr(1).get_slice(" ", 0).get_slice("@", 0).to_lower()


## The linking code in "/start 482913", "482 913" or "482913", or "" when there is none.
static func code_in(text: String) -> String:
	var t := text.strip_edges()
	if t.to_lower().begins_with("/start"):
		t = t.substr(6)
	t = t.replace(" ", "").replace("-", "")
	return t if RegEx.create_from_string(r"^\d{6}$").search(t) != null else ""


## A JSON body for a method that takes no file.
static func json_body(data: Dictionary) -> PackedByteArray:
	return JSON.stringify(data).to_utf8_buffer()


static func json_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json"])


## sendDocument's body: the plain fields, then the file. Returns {headers, body}.
static func multipart(fields: Dictionary, file_field: String, file_name: String, bytes: PackedByteArray, boundary: String = "") -> Dictionary:
	if boundary == "":
		boundary = "mrw" + Crypto.new().generate_random_bytes(12).hex_encode()
	var body := PackedByteArray()
	for k in fields:
		body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % [boundary, k, str(fields[k])]).to_utf8_buffer())
	var safe := file_name.replace("\"", "'").replace("\r", "").replace("\n", "")
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: application/octet-stream\r\n\r\n" % [boundary, file_field, safe]).to_utf8_buffer())
	body.append_array(bytes)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	return {"headers": PackedStringArray(["Content-Type: multipart/form-data; boundary=%s" % boundary]), "body": body}


static func commands_body() -> PackedByteArray:
	var list: Array = []
	for c in COMMANDS:
		list.append({"command": c[0], "description": c[1]})
	return json_body({"commands": list})


## The link that opens the bot in Telegram and sends "/start <code>" when Start is pressed.
static func start_link(bot: String, code: String = "") -> String:
	return "https://t.me/%s%s" % [bot, "" if code == "" else "?start=" + code]
