class_name WitSpeech
extends SpeechRecognizer
## Speech to text through Wit.ai (Meta's free speech service). It needs a Wit.ai server access token (More tab; or a file
## user://wit_token.txt; or, for the headset, res://wit_token.txt which `tools/quest.ps1 -WitToken` bundles into a personal build)
## and an internet connection; only the recorded audio is sent. The language is the one the Wit.ai app is set to.
## One request carries at most about 20 seconds of speech, which is what the recorder is capped to.

const URL := "https://api.wit.ai/dictation?v=20240304"
const TIMEOUT_S := 20.0
const TOKEN_FILES := ["user://wit_token.txt", "res://wit_token.txt"]

var host: Node


func _init(host_node: Node) -> void:
	host = host_node


func name_of() -> String:
	return "wit"


## The token from the settings, else from a token file (the way to give it to the headset, which has no keyboard).
static func token() -> String:
	var t := str(App.val("wit_token")).strip_edges()
	for f in TOKEN_FILES:
		if t == "" and FileAccess.file_exists(f):
			t = FileAccess.get_file_as_string(f).strip_edges()
	return t


func ready_reason() -> String:
	if token() == "":
		if App.xr_active:
			return "Speech to text needs a Wit.ai token. Rebuild with: pwsh tools/quest.ps1 -WitToken <token>"
		return "Speech to text needs a Wit.ai token: Home > Settings > Speech to text."
	return ""


func transcribe(pcm: PackedByteArray, rate: int, done: Callable) -> void:
	var why := ready_reason()
	if why != "":
		done.call({"ok": false, "text": "", "error": why})
		return
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_S
	host.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, data: PackedByteArray):
		http.queue_free()
		done.call(parse_response(result, code, data)), CONNECT_ONE_SHOT)
	var headers := PackedStringArray([
		"Authorization: Bearer " + token(),
		"Content-Type: " + content_type(rate),
		"Accept: application/json"])
	var err := http.request_raw(URL, headers, HTTPClient.METHOD_POST, pcm)
	if err != OK:
		http.queue_free()
		done.call({"ok": false, "text": "", "error": "Could not start the request (%d)." % err})


static func content_type(rate: int) -> String:
	return "audio/raw;encoding=signed-integer;bits=16;rate=%d;endian=little" % rate


static func parse_response(result: int, code: int, data: PackedByteArray) -> Dictionary:
	var fail := func(msg: String) -> Dictionary:
		return {"ok": false, "text": "", "error": msg}
	if result != HTTPRequest.RESULT_SUCCESS:
		return fail.call("No internet connection for speech recognition (error %d)." % result)
	var objects := split_json_objects(data.get_string_from_utf8())
	if code == 401 or code == 403:
		return fail.call("Wit.ai did not accept the token. Check it in Home > Settings > Speech to text.")
	if code == 429:
		return fail.call("Wit.ai is busy (rate limit). Try again in a moment.")
	if code != 200:
		var msg := ""
		for o in objects:
			if o is Dictionary and (o as Dictionary).has("error"):
				msg = str(o.error)
		return fail.call("Wit.ai answered with HTTP %d. %s" % [code, msg])
	# The answer is a stream of JSON objects: partial transcriptions, then the final one (is_final).
	var text := ""
	for o in objects:
		if not (o is Dictionary):
			continue
		var d := o as Dictionary
		if d.has("error") and not d.has("text"):
			return fail.call("Wit.ai: " + str(d.error))
		if d.has("text") and str(d.text).strip_edges() != "":
			text = str(d.text).strip_edges()
			if bool(d.get("is_final", false)):
				break
	if text == "":
		return fail.call("Could not make out any words.")
	return {"ok": true, "text": text, "error": ""}


## Wit.ai answers with several JSON objects one after the other (separated by line breaks). Split them by brace depth.
static func split_json_objects(s: String) -> Array:
	var out: Array = []
	var depth := 0
	var start := -1
	var in_str := false
	var esc := false
	for i in s.length():
		var c := s[i]
		if in_str:
			if esc:
				esc = false
			elif c == "\\":
				esc = true
			elif c == "\"":
				in_str = false
			continue
		if c == "\"":
			in_str = true
		elif c == "{":
			if depth == 0:
				start = i
			depth += 1
		elif c == "}" and depth > 0:
			depth -= 1
			if depth == 0 and start >= 0:
				var v: Variant = JSON.parse_string(s.substr(start, i - start + 1))
				if v != null:
					out.append(v)
				start = -1
	return out
