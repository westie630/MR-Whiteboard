class_name LlmClient
extends RefCounted
## Sends the requests LlmApi builds, one HTTPRequest node each (added under `host`), and hands the parsed answer to a callback.
## When a model refuses a request as invalid and the request carried something optional (the picture, a thinking level), it is
## asked once more without those, and the answer says what was left out. Tests replace this class with a fake.

const TIMEOUT_S := 300.0                  # a model that thinks hard can take minutes

var host: Node


func _init(host_node: Node) -> void:
	host = host_node


## done({ok, models, error})
func list_models(provider: String, key: String, done: Callable) -> void:
	var req := LlmApi.models_request(provider, key)
	_send(req.url, req.headers, HTTPClient.METHOD_GET, "", func(result: int, code: int, body: String):
		done.call(LlmApi.parse_models(provider, result, code, body)))


## done({ok, text, error, left_out: PackedStringArray})
func chat(provider: String, key: String, model: String, mode: String, system: String, history: Array, prompt: String, png: PackedByteArray, done: Callable) -> void:
	var req := LlmApi.chat_request(provider, key, model, mode, system, history, prompt, png)
	_send(req.url, req.headers, HTTPClient.METHOD_POST, req.body, func(result: int, code: int, body: String):
		var res := LlmApi.parse_chat(provider, result, code, body)
		var lean: Array = req.lean
		if not bool(res.ok) and bool(res.rejected) and not lean.is_empty():
			var again := LlmApi.chat_request(provider, key, model, "default", system, history, prompt, PackedByteArray())
			_send(again.url, again.headers, HTTPClient.METHOD_POST, again.body, func(r2: int, c2: int, b2: String):
				var res2 := LlmApi.parse_chat(provider, r2, c2, b2)
				res2["left_out"] = PackedStringArray(lean)
				if not bool(res2.ok):
					res2.error = str(res.error)
				done.call(res2))
			return
		res["left_out"] = PackedStringArray()
		done.call(res))


func _send(url: String, headers: PackedStringArray, method: int, body: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_S
	host.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, data: PackedByteArray):
		http.queue_free()
		cb.call(result, code, data.get_string_from_utf8()), CONNECT_ONE_SHOT)
	var err := http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		cb.call(HTTPRequest.RESULT_CANT_CONNECT, 0, "")
