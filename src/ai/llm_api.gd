class_name LlmApi
extends RefCounted
## The language-model services the AI assistant can talk to, as plain request builders and answer parsers (no network here, so
## everything is testable): Claude (Anthropic Messages API), OpenAI (Responses API) and MiniMax (its OpenAI-compatible Chat
## Completions API). LlmClient sends what these build.
##
## Models come from each provider's own model list. Claude's list also says which thinking modes and effort levels each model
## supports, so those are offered exactly; OpenAI and MiniMax list only names, so their thinking options are the documented ones
## for the model family, and a model that refuses one is asked again without it (see LlmClient).

const ORDER := ["anthropic", "openai", "minimax"]
const PROVIDERS := {
	"anthropic": {"name": "Claude", "maker": "Anthropic", "base": "https://api.anthropic.com", "keys_url": "https://console.anthropic.com/settings/keys",
		"default_model": "claude-opus-5-5"},
	"openai": {"name": "OpenAI", "maker": "OpenAI", "base": "https://api.openai.com", "keys_url": "https://platform.openai.com/api-keys",
		"default_model": ""},
	"minimax": {"name": "MiniMax", "maker": "MiniMax", "base": "https://api.minimax.io", "keys_url": "https://platform.minimax.io/user-center/basic-information/interface-key",
		"default_model": "MiniMax-M3"},
}
const ANTHROPIC_VERSION := "2023-06-01"
const MAX_OUT := 16000                    # output tokens per answer (thinking included on Claude)
const BUDGET := 8000                      # thinking budget for older Claude models that take one
const EFFORTS := ["low", "medium", "high", "xhigh", "max"]
const EFFORT_NAMES := {"low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra high", "max": "Max"}
const DEFAULT_MODE := ["default", "Model default"]


## JSON text as a value, or null; quietly (an answer that is not JSON is common and not an error here).
static func parse_json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


static func name_of(provider: String) -> String:
	return str((PROVIDERS.get(provider, {}) as Dictionary).get("name", provider))


static func is_provider(provider: String) -> bool:
	return PROVIDERS.has(provider)


# ------------------------------------------------------------------------------------------------ model lists

## {url, headers} of the request that lists the provider's models.
static func models_request(provider: String, key: String) -> Dictionary:
	var base := str(PROVIDERS[provider].base)
	match provider:
		"anthropic":
			return {"url": base + "/v1/models?limit=1000", "headers": PackedStringArray(["x-api-key: " + key, "anthropic-version: " + ANTHROPIC_VERSION])}
		_:
			return {"url": base + "/v1/models", "headers": PackedStringArray(["Authorization: Bearer " + key])}


## The answer to models_request: {ok, models: [{id, name, vision, modes: [[id, label], ...]}], error}. Only models that can chat are
## kept, newest first.
static func parse_models(provider: String, result: int, code: int, body: String) -> Dictionary:
	var err := http_error(provider, result, code, body)
	if err != "":
		return {"ok": false, "models": [], "error": err}
	var parsed: Variant = parse_json(body)
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("data") is Array):
		return {"ok": false, "models": [], "error": "%s sent a model list this app does not understand." % name_of(provider)}
	var rows: Array = []
	for m in parsed.data:
		if not (m is Dictionary) or str(m.get("id", "")) == "":
			continue
		var id := str(m.id)
		if not chat_model(provider, id):
			continue
		var row := {"id": id, "name": str(m.get("display_name", id)), "vision": true, "created": _created(m)}
		if provider == "anthropic":
			var caps: Variant = m.get("capabilities")
			row["modes"] = anthropic_modes(caps)
			if caps is Dictionary and (caps as Dictionary).get("image_input") is Dictionary:
				row["vision"] = bool(caps.image_input.get("supported", true))
		else:
			row["modes"] = guess_modes(provider, id)
		rows.append(row)
	rows.sort_custom(func(a, b): return int(a.created) > int(b.created) or (int(a.created) == int(b.created) and str(a.id) < str(b.id)))
	for r in rows:
		r.erase("created")
	if rows.is_empty():
		return {"ok": false, "models": [], "error": "%s lists no models this key can chat with." % name_of(provider)}
	return {"ok": true, "models": rows, "error": ""}


static func _created(m: Dictionary) -> int:
	var c: Variant = m.get("created", m.get("created_at", 0))
	if c is String:
		return int(Time.get_unix_time_from_datetime_string(str(c)))
	return int(c)


## Can this model hold a conversation (the lists also hold speech, image, embedding ... models)?
static func chat_model(provider: String, id: String) -> bool:
	var l := id.to_lower()
	match provider:
		"anthropic":
			return l.begins_with("claude")
		"openai":
			if not (l.begins_with("gpt-") or l.begins_with("chatgpt") or RegEx.create_from_string(r"^o\d").search(l) != null):
				return false
			for bad in ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "moderation", "instruct", "codex", "computer-use", "deep-research"]:
				if l.contains(bad):
					return false
			return true
		"minimax":
			for bad in ["speech", "video", "image", "music", "hailuo", "embo", "voice"]:
				if l.contains(bad):
					return false
			return true
	return false


## Thinking modes of a Claude model from its capabilities (Models API): [[id, label], ...]. "default" sends nothing (the model's own
## default); an effort level turns on adaptive thinking at that effort; older models that take a fixed budget get "think".
static func anthropic_modes(caps: Variant) -> Array:
	var modes: Array = [DEFAULT_MODE]
	if not (caps is Dictionary):
		for e in ["low", "medium", "high"]:
			modes.append([e, EFFORT_NAMES[e]])
		return modes
	var c: Dictionary = caps
	var think: Dictionary = c.get("thinking", {}) if c.get("thinking") is Dictionary else {}
	var types: Dictionary = think.get("types", {}) if think.get("types") is Dictionary else {}
	var adaptive := _supported(types.get("adaptive"))
	var budget := _supported(types.get("enabled"))
	var effort: Dictionary = c.get("effort", {}) if c.get("effort") is Dictionary else {}
	if adaptive or bool(effort.get("supported", false)):
		for e in EFFORTS:
			if _supported(effort.get(e)):
				modes.append([e, EFFORT_NAMES[e]])
	elif budget:
		modes.append(["think", "Think"])
	return modes


static func _supported(v: Variant) -> bool:
	return v is Dictionary and bool((v as Dictionary).get("supported", false))


## Documented thinking modes for OpenAI and MiniMax models (their model lists do not say).
static func guess_modes(provider: String, id: String) -> Array:
	var l := id.to_lower()
	var modes: Array = [DEFAULT_MODE]
	match provider:
		"openai":
			if RegEx.create_from_string(r"^(o\d|gpt-([5-9]|\d\d))").search(l) != null:
				for e in ["low", "medium", "high", "xhigh"]:
					modes.append([e, EFFORT_NAMES[e]])
		"minimax":
			if l.contains("m3.1") or l.contains("flash"):
				for e in EFFORTS:
					modes.append([e, EFFORT_NAMES[e]])
			elif l.contains("m3"):
				modes.append(["off", "No thinking"])
	return modes


# ------------------------------------------------------------------------------------------------ asking

## The request that asks a model. `history` is the earlier turns [{role: "user"|"assistant", text}], `prompt` the new message,
## `png` an optional picture (PNG bytes), `mode` a thinking mode id. Returns {url, headers, body (JSON text), lean (what can be
## dropped if the model refuses it: "picture", "mode")}.
static func chat_request(provider: String, key: String, model: String, mode: String, system: String, history: Array, prompt: String, png: PackedByteArray) -> Dictionary:
	var base := str(PROVIDERS[provider].base)
	var b64 := Marshalls.raw_to_base64(png) if not png.is_empty() else ""
	var lean: Array = []
	if b64 != "":
		lean.append("picture")
	if mode != "" and mode != "default":
		lean.append("mode")
	var body := {}
	match provider:
		"anthropic":
			var msgs: Array = []
			for h in history:
				msgs.append({"role": h.role, "content": str(h.text)})
			var content: Array = []
			if b64 != "":
				content.append({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}})
			content.append({"type": "text", "text": prompt})
			msgs.append({"role": "user", "content": content})
			body = {"model": model, "max_tokens": MAX_OUT, "system": system, "messages": msgs}
			if EFFORTS.has(mode):
				body["thinking"] = {"type": "adaptive"}
				body["output_config"] = {"effort": mode}
			elif mode == "think":
				body["thinking"] = {"type": "enabled", "budget_tokens": BUDGET}
			return {"url": base + "/v1/messages", "headers": PackedStringArray(["x-api-key: " + key, "anthropic-version: " + ANTHROPIC_VERSION,
				"content-type: application/json"]), "body": JSON.stringify(body), "lean": lean}
		"openai":
			var input: Array = []
			for h in history:
				input.append({"role": h.role, "content": str(h.text)})
			var parts: Array = [{"type": "input_text", "text": prompt}]
			if b64 != "":
				parts.append({"type": "input_image", "image_url": "data:image/png;base64," + b64})
			input.append({"role": "user", "content": parts})
			body = {"model": model, "instructions": system, "input": input, "max_output_tokens": MAX_OUT, "store": false}
			if EFFORTS.has(mode):
				body["reasoning"] = {"effort": mode}
			return {"url": base + "/v1/responses", "headers": PackedStringArray(["Authorization: Bearer " + key, "Content-Type: application/json"]),
				"body": JSON.stringify(body), "lean": lean}
		_:
			var msgs2: Array = [{"role": "system", "content": system}]
			for h in history:
				msgs2.append({"role": h.role, "content": str(h.text)})
			var parts2: Array = [{"type": "text", "text": prompt}]
			if b64 != "":
				parts2.append({"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}})
			msgs2.append({"role": "user", "content": parts2})
			body = {"model": model, "messages": msgs2, "max_completion_tokens": MAX_OUT}
			if EFFORTS.has(mode):
				body["reasoning_effort"] = mode
			elif mode == "off":
				body["thinking"] = {"type": "disabled"}
			return {"url": base + "/v1/chat/completions", "headers": PackedStringArray(["Authorization: Bearer " + key, "Content-Type: application/json"]),
				"body": JSON.stringify(body), "lean": lean}


## The model's answer: {ok, text, error, rejected (true when the request itself was refused as invalid: worth a leaner retry)}.
static func parse_chat(provider: String, result: int, code: int, body: String) -> Dictionary:
	var err := http_error(provider, result, code, body)
	if err != "":
		return {"ok": false, "text": "", "error": err, "rejected": code == 400 or code == 422}
	var parsed: Variant = parse_json(body)
	if not (parsed is Dictionary):
		return {"ok": false, "text": "", "error": "%s sent an answer this app does not understand." % name_of(provider), "rejected": false}
	var d: Dictionary = parsed
	var text := ""
	match provider:
		"anthropic":
			for blk in d.get("content", []):
				if blk is Dictionary and str(blk.get("type", "")) == "text":
					text += str(blk.get("text", ""))
			var stop := str(d.get("stop_reason", ""))
			if stop == "refusal":
				return {"ok": false, "text": "", "error": "Claude declined to answer this request.", "rejected": false}
			if stop == "max_tokens" and text.strip_edges() == "":
				return {"ok": false, "text": "", "error": "The answer was cut off before it began: try a lower thinking level.", "rejected": false}
		"openai":
			for out in d.get("output", []):
				if out is Dictionary and str(out.get("type", "")) == "message":
					for c in out.get("content", []):
						if c is Dictionary and str(c.get("type", "")) == "output_text":
							text += str(c.get("text", ""))
						elif c is Dictionary and str(c.get("type", "")) == "refusal":
							return {"ok": false, "text": "", "error": "OpenAI declined: " + str(c.get("refusal", "")), "rejected": false}
			if text.strip_edges() == "" and str(d.get("status", "")) == "incomplete":
				return {"ok": false, "text": "", "error": "The answer was cut off (%s): try a lower thinking level." % str((d.get("incomplete_details", {}) as Dictionary).get("reason", "incomplete")), "rejected": false}
		_:
			var base_resp: Variant = d.get("base_resp")
			if base_resp is Dictionary and int(base_resp.get("status_code", 0)) != 0:
				return {"ok": false, "text": "", "error": "MiniMax: %s" % str(base_resp.get("status_msg", "error %d" % int(base_resp.status_code))), "rejected": false}
			var choices: Array = d.get("choices", []) if d.get("choices") is Array else []
			if not choices.is_empty() and choices[0] is Dictionary and choices[0].get("message") is Dictionary:
				text = str(choices[0].message.get("content", ""))
	text = strip_think(text).strip_edges()
	if text == "":
		return {"ok": false, "text": "", "error": "%s answered with nothing." % name_of(provider), "rejected": false}
	return {"ok": true, "text": text, "error": "", "rejected": false}


## Reasoning some models write inline (<think> ... </think>) is not part of the answer.
static func strip_think(text: String) -> String:
	var rx := RegEx.create_from_string(r"(?s)<think>.*?</think>")
	text = rx.sub(text, "", true)
	var open := text.find("<think>")
	return text.substr(0, open) if open >= 0 else text


## "" when the HTTP exchange went well, else a message for the user.
static func http_error(provider: String, result: int, code: int, body: String) -> String:
	var who := name_of(provider)
	if result != HTTPRequest.RESULT_SUCCESS:
		if result == HTTPRequest.RESULT_TIMEOUT:
			return "%s took too long to answer. Try a lower thinking level." % who
		return "Could not reach %s: no internet connection? (error %d)" % [who, result]
	if code >= 200 and code < 300:
		return ""
	var msg := ""
	var parsed: Variant = parse_json(body)
	if parsed is Dictionary:
		var e: Variant = (parsed as Dictionary).get("error")
		if e is Dictionary:
			msg = str((e as Dictionary).get("message", ""))
		elif e is String:
			msg = str(e)
		if msg == "" and (parsed as Dictionary).get("base_resp") is Dictionary:
			msg = str(parsed.base_resp.get("status_msg", ""))
	match code:
		401, 403:
			return "%s did not accept the API key. Check it on the web page (AI)." % who + (" (%s)" % msg if msg != "" else "")
		404:
			return "%s does not know that model. Refresh the model list. %s" % [who, msg]
		429:
			return "%s says: too many requests or no credit left. %s" % [who, msg]
	if code >= 500:
		return "%s is busy or having trouble (HTTP %d). Try again in a moment." % [who, code]
	return "%s answered with HTTP %d. %s" % [who, code, msg]
