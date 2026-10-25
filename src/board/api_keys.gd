class_name ApiKeys
extends RefCounted
## Every API key the app can use, for the web page (ExportServer, /keys): the three AI providers and the Wit.ai speech token.
## The page can set or remove a key and learns only the last four characters of a saved one. AI keys go through AiController (it
## fetches the model list when one is saved); the Wit.ai token is the `wit_token` setting that WitSpeech reads.

const WIT := "wit"

var ai: AiController


func _init(controller: AiController) -> void:
	ai = controller


## What the keys page shows: [{id, name, what, has_key, key_hint, keys_url, note}] in display order.
func state() -> Dictionary:
	var services: Array = []
	for p in LlmApi.ORDER:
		services.append({"id": p, "name": LlmApi.name_of(p), "what": "AI assistant", "has_key": ai.key(p) != "", "key_hint": ai.key_hint(p),
			"keys_url": str(LlmApi.PROVIDERS[p].keys_url), "note": ""})
	var tok := WitSpeech.token()
	var own := str(App.val("wit_token")).strip_edges() != ""
	services.append({"id": WIT, "name": "Wit.ai", "what": "Speech to text", "has_key": tok != "", "key_hint": "" if tok == "" else "…" + tok.right(4),
		"keys_url": "https://wit.ai/apps", "note": "" if own or tok == "" else "This one comes from a file in the app, not from a setting; saving a token here replaces it."})
	return {"ok": true, "services": services}


func api(cmd: String, data: Dictionary) -> Dictionary:
	match cmd:
		"state":
			return state()
		"set":
			var id := str(data.get("service", ""))
			var k := str(data.get("key", "")).strip_edges()
			if k.length() > 400 or k.contains(" ") or k.contains("\n"):
				return {"ok": false, "message": "That does not look like an API key."}
			if id == WIT:
				App.put("wit_token", k)
				return {"ok": true, "message": "Wit.ai token saved on the headset." if k != "" else "Wit.ai token removed."}
			if LlmApi.is_provider(id):
				return ai.api("key", {"provider": id, "key": k, "use": "1" if str(data.get("use", "")) != "" else ""})
	return {"ok": false, "message": "Unknown request."}
