class_name GoogleInk
extends InkRecognizer
## Handwriting recognition through Google's handwriting input service (the one behind Google Input Tools / Gboard on the web).
## It reads real pen strokes (with timing), so it handles cursive, print, mixed case, digits and symbols in many languages.
## It needs an internet connection; the strokes (not the document) are sent, and nothing is stored by the app.
## Unofficial endpoint: if Google changes it, recognition reports a clear error and the ink stays as ink.

const URL := "https://inputtools.google.com/request?itc=%s-t-i0-handwrit&app=mobilesearch"
const TIMEOUT_S := 12.0

var host: Node


func _init(host_node: Node) -> void:
	host = host_node


func name_of() -> String:
	return "google"


func recognize(strokes: Array, area: Vector2, language: String, done: Callable) -> void:
	var body := build_request(strokes, area, language)
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_S
	host.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, data: PackedByteArray):
		http.queue_free()
		done.call(parse_response(result, code, data)), CONNECT_ONE_SHOT)
	var err := http.request(URL % language, PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		done.call({"ok": false, "candidates": PackedStringArray(), "error": "Could not start the request (%d)." % err})


static func build_request(strokes: Array, area: Vector2, language: String) -> Dictionary:
	var ink: Array = []
	for s in strokes:
		var xs: Array = []
		var ys: Array = []
		var ts: Array = []
		for i in (s.x as PackedFloat32Array).size():
			xs.append(snappedf(s.x[i], 0.1))
			ys.append(snappedf(s.y[i], 0.1))
			ts.append(int(s.t[i]))
		ink.append([xs, ys, ts])
	return {"app_version": 0.4, "api_level": "537.36", "device": "MR Whiteboard", "input_type": 0, "options": "enable_pre_space",
		"requests": [{"writing_guide": {"writing_area_width": int(area.x), "writing_area_height": int(area.y)}, "pre_context": "",
			"max_num_results": 8, "max_completions": 0, "language": language, "ink": ink}]}


static func parse_response(result: int, code: int, data: PackedByteArray) -> Dictionary:
	var fail := func(msg: String) -> Dictionary:
		return {"ok": false, "candidates": PackedStringArray(), "error": msg}
	if result != HTTPRequest.RESULT_SUCCESS:
		return fail.call("No internet connection for handwriting recognition (error %d)." % result)
	if code != 200:
		return fail.call("The handwriting service answered with HTTP %d." % code)
	var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
	if not (parsed is Array) or (parsed as Array).size() < 2 or str(parsed[0]) != "SUCCESS":
		return fail.call("The handwriting service did not understand the strokes.")
	var res: Array = parsed[1]
	if res.is_empty() or not (res[0] is Array) or (res[0] as Array).size() < 2 or not (res[0][1] is Array):
		return fail.call("The handwriting service returned no text.")
	var cands := PackedStringArray()
	for c in res[0][1]:
		cands.append(str(c))
	return {"ok": not cands.is_empty(), "candidates": cands, "error": "" if not cands.is_empty() else "No text recognised."}
