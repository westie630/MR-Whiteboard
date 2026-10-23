extends Node
## The AI assistant without the network: the three providers' requests and answers (model lists with thinking levels, the chat
## formats, errors), the canvas description and picture, reading a model's answer into items (glued arrows, changes, removals),
## and the whole loop through a real Board with a fake model: a note in words, a suggestion layer shown over the canvas, accepted as
## one undo step or discarded, kept in its own file, and driven from the web page (keys never come back out).

class FakeClient extends RefCounted:
	var answer := ""
	var fail := ""
	var asked: Array = []                 # [provider, model, mode, system, history, prompt, png size]
	var listed: Array = []

	func list_models(provider: String, _key: String, done: Callable) -> void:
		listed.append(provider)
		done.call({"ok": true, "error": "", "models": [{"id": "model-a", "name": "Model A", "vision": true, "modes": [["default", "Model default"], ["high", "High"]]}]})

	func chat(provider: String, _key: String, model: String, mode: String, system: String, history: Array, prompt: String, png: PackedByteArray, done: Callable) -> void:
		asked.append([provider, model, mode, system, history.duplicate(true), prompt, png.size()])
		if fail != "":
			done.call({"ok": false, "text": "", "error": fail, "left_out": PackedStringArray()})
		else:
			done.call({"ok": true, "text": answer, "error": "", "left_out": PackedStringArray()})


var t := TestCase.new("ai")


func _ready() -> void:
	App.settings_path = "user://test_settings_ai.cfg"
	App.docs_dir = "user://test_docs_ai"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(App.settings_path))
	App.reload()
	_providers()
	_answers()
	var board := _board()
	var doc := board.doc
	var fid := _canvas(doc)
	_brief(doc, fid)
	_reply(doc, fid)
	await _controller(board, fid)
	_web(board, fid)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(App.settings_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_ai_models.json"))
	get_tree().quit(t.done())


func _board() -> Board:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_ai.json"))
	var anchors := SimAnchors.new("user://test_sim_anchors_ai.json")
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	var doc := DemoDoc.build()
	doc.id = "ai-test"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DocStore.ai_path(doc.id)))
	board.open(doc)
	return board


func _canvas(doc: Document) -> String:
	for f in doc.frames.values():
		if (f as FrameData).kind == FrameData.CANVAS and not doc.items_of((f as FrameData).id).is_empty():
			return (f as FrameData).id
	return ""


# ------------------------------------------------------------------------------------------------ providers

func _providers() -> void:
	# Claude: the model list says which thinking modes and effort levels each model has
	var claude := JSON.stringify({"data": [
		{"id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "created_at": "2026-09-01T00:00:00Z", "capabilities": {
			"image_input": {"supported": true}, "thinking": {"supported": true, "types": {"enabled": {"supported": false}, "adaptive": {"supported": true}}},
			"effort": {"supported": true, "low": {"supported": true}, "medium": {"supported": true}, "high": {"supported": true}, "xhigh": {"supported": true}, "max": {"supported": true}}}},
		{"id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5", "created_at": "2025-10-01T00:00:00Z", "capabilities": {
			"image_input": {"supported": true}, "thinking": {"supported": true, "types": {"enabled": {"supported": true}, "adaptive": {"supported": false}}},
			"effort": {"supported": false}}}]})
	var res := LlmApi.parse_models("anthropic", HTTPRequest.RESULT_SUCCESS, 200, claude)
	t.check(bool(res.ok), "the Claude model list is read")
	t.eq(res.models.size(), 2, "both Claude models are listed")
	t.eq(str(res.models[0].id), "claude-opus-5-5", "newest first")
	t.eq((res.models[0].modes as Array).map(func(m): return m[0]), ["default", "low", "medium", "high", "xhigh", "max"], "the effort levels the model reports are offered")
	t.eq((res.models[1].modes as Array).map(func(m): return m[0]), ["default", "think"], "a budget-only model offers think on / off")
	t.eq(LlmApi.models_request("anthropic", "K").url, "https://api.anthropic.com/v1/models?limit=1000", "Claude's model list address")
	# OpenAI: only chat models, thinking levels for reasoning families
	var oa := JSON.stringify({"object": "list", "data": [{"id": "gpt-5.2", "created": 300}, {"id": "gpt-4o", "created": 200}, {"id": "text-embedding-3-large", "created": 400},
		{"id": "gpt-4o-realtime-preview", "created": 250}, {"id": "dall-e-3", "created": 100}, {"id": "o3", "created": 150}, {"id": "whisper-1", "created": 90}]})
	var res2 := LlmApi.parse_models("openai", HTTPRequest.RESULT_SUCCESS, 200, oa)
	t.eq((res2.models as Array).map(func(m): return m.id), ["gpt-5.2", "gpt-4o", "o3"], "OpenAI: speech, image, embedding and realtime models are left out")
	t.check((res2.models[0].modes as Array).size() > 1 and (res2.models[1].modes as Array).size() == 1, "reasoning models get thinking levels, gpt-4o does not")
	var mm := JSON.stringify({"object": "list", "data": [{"id": "MiniMax-M3.1-Flash", "created": 2}, {"id": "MiniMax-M3", "created": 1}, {"id": "speech-2.6-hd", "created": 3}]})
	var res3 := LlmApi.parse_models("minimax", HTTPRequest.RESULT_SUCCESS, 200, mm)
	t.eq(res3.models.size(), 2, "MiniMax: the speech model is left out")
	t.check((res3.models[0].modes as Array).size() == 6 and (res3.models[1].modes as Array).map(func(m): return m[0]).has("off"), "M3.1-Flash has effort levels, M3 can switch thinking off")
	t.check(str(LlmApi.parse_models("openai", HTTPRequest.RESULT_SUCCESS, 401, '{"error": {"message": "Incorrect API key provided"}}').error).contains("did not accept the API key"), "a wrong key is explained")
	t.check(str(LlmApi.parse_models("minimax", HTTPRequest.RESULT_CANT_CONNECT, 0, "").error).contains("internet"), "no network is explained")

	# requests
	var png := PackedByteArray([137, 80, 78, 71])
	var hist := [{"role": "user", "text": "Opinion"}, {"role": "assistant", "text": "Nice."}]
	var r1 := LlmApi.chat_request("anthropic", "KEY", "claude-opus-5-5", "high", "SYS", hist, "PROMPT", png)
	var b1: Dictionary = JSON.parse_string(r1.body)
	t.eq(r1.url, "https://api.anthropic.com/v1/messages", "Claude Messages API")
	t.check(r1.headers.has("x-api-key: KEY") and r1.headers.has("anthropic-version: 2023-06-01"), "Claude headers")
	t.eq(b1.thinking, {"type": "adaptive"}, "an effort level turns on adaptive thinking")
	t.eq(b1.output_config, {"effort": "high"}, "... at that effort")
	t.eq(b1.system, "SYS", "the system prompt")
	t.eq((b1.messages as Array).size(), 3, "earlier turns go along")
	t.eq(str(b1.messages[2].content[0].type), "image", "the picture comes before the words")
	t.eq(str(b1.messages[2].content[0].source.media_type), "image/png", "as a PNG")
	t.check(not JSON.parse_string(LlmApi.chat_request("anthropic", "K", "m", "default", "S", [], "P", PackedByteArray()).body).has("thinking"), "Model default sends no thinking setting")
	t.eq(JSON.parse_string(LlmApi.chat_request("anthropic", "K", "m", "think", "S", [], "P", PackedByteArray()).body).thinking.budget_tokens, float(LlmApi.BUDGET), "older models get a thinking budget")
	t.eq(r1.lean, ["picture", "mode"], "the picture and the thinking level can be dropped on a refusal")
	var r2 := LlmApi.chat_request("openai", "KEY", "gpt-5.2", "medium", "SYS", hist, "PROMPT", png)
	var b2: Dictionary = JSON.parse_string(r2.body)
	t.eq(r2.url, "https://api.openai.com/v1/responses", "OpenAI Responses API")
	t.check(r2.headers.has("Authorization: Bearer KEY"), "OpenAI key header")
	t.eq(b2.reasoning, {"effort": "medium"}, "OpenAI reasoning effort")
	t.eq(b2.instructions, "SYS", "OpenAI instructions")
	t.check(str(b2.input[2].content[1].image_url).begins_with("data:image/png;base64,"), "OpenAI picture as a data URL")
	var r3 := LlmApi.chat_request("minimax", "KEY", "MiniMax-M3", "off", "SYS", [], "PROMPT", png)
	var b3: Dictionary = JSON.parse_string(r3.body)
	t.eq(r3.url, "https://api.minimax.io/v1/chat/completions", "MiniMax chat completions")
	t.eq(b3.thinking, {"type": "disabled"}, "MiniMax M3 thinking off")
	t.eq(str(b3.messages[0].role), "system", "MiniMax system message first")
	t.eq(str(b3.messages[1].content[1].type), "image_url", "MiniMax picture")
	t.eq(JSON.parse_string(LlmApi.chat_request("minimax", "K", "MiniMax-M3.1-Flash", "max", "S", [], "P", PackedByteArray()).body).reasoning_effort, "max", "MiniMax effort")


func _answers() -> void:
	var ok := LlmApi.parse_chat("anthropic", HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "Hello "}, {"type": "text", "text": "there"}], "stop_reason": "end_turn"}))
	t.eq(ok.text, "Hello there", "Claude: the text blocks, not the thinking")
	t.check(not bool(LlmApi.parse_chat("anthropic", HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"content": [], "stop_reason": "refusal"})).ok), "a refusal is an error")
	var bad := LlmApi.parse_chat("anthropic", HTTPRequest.RESULT_SUCCESS, 400, JSON.stringify({"type": "error", "error": {"type": "invalid_request_error", "message": "effort not supported"}}))
	t.check(bool(bad.rejected) and str(bad.error).contains("effort not supported"), "an invalid request is marked for a leaner retry, with the service's words")
	var oa := LlmApi.parse_chat("openai", HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"status": "completed", "output": [{"type": "reasoning", "summary": []}, {"type": "message", "content": [{"type": "output_text", "text": "{\"say\": \"hi\"}"}]}]}))
	t.eq(oa.text, "{\"say\": \"hi\"}", "OpenAI: the message's output text")
	var mm := LlmApi.parse_chat("minimax", HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"choices": [{"message": {"content": "<think>hmm</think>\nAnswer"}}], "base_resp": {"status_code": 0}}))
	t.eq(mm.text, "Answer", "inline thinking is removed")
	t.check(str(LlmApi.parse_chat("minimax", HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"base_resp": {"status_code": 1004, "status_msg": "login fail"}})).error).contains("login fail"), "MiniMax errors in a 200 answer")
	t.check(str(LlmApi.parse_chat("openai", HTTPRequest.RESULT_SUCCESS, 429, "{}").error).contains("credit"), "rate limits are explained")
	t.check(str(LlmApi.parse_chat("anthropic", HTTPRequest.RESULT_TIMEOUT, 0, "").error).contains("too long"), "a timeout is explained")
	# the JSON in an answer
	t.eq(AiReply.extract("{\"say\": \"a\", \"add\": []}").say, "a", "plain JSON")
	t.eq(AiReply.extract("Sure!\n```json\n{\"say\": \"b {x}\", \"add\": [{\"type\": \"text\"}]}\n```").say, "b {x}", "fenced JSON with text around it")
	t.eq(AiReply.extract("Just words, no JSON.").say, "Just words, no JSON.", "prose becomes the words")


# ------------------------------------------------------------------------------------------------ canvas description

func _brief(doc: Document, fid: String) -> void:
	var list := doc.items_of(fid)
	var b := CanvasBrief.make(doc, fid, [list[0].id])
	var parsed: Variant = JSON.parse_string(b.json)
	t.check(parsed is Dictionary and (parsed.items as Array).size() == list.size(), "every item is described")
	t.eq(b.ids.size(), list.size(), "every item has a short id")
	var box: Item = null
	for it in list:
		if (it as Item).kind == Item.SHAPE and not (it as Item).is_line() and (it as Item).label != "":
			box = it
			break
	t.check(box != null, "the demo has a labelled box")
	var row: Dictionary = {}
	for r in parsed.items:
		if b.ids.get(str(r.id), "") == box.id:
			row = r
	t.eq(str(row.get("label", "")), box.label, "the label is in the description")
	var corner := b.to_frame(float(row.x), float(row.y))
	t.near(corner.x, box.center.x - box.size.x * 0.5, 0.002, "x: centimetres from the left edge")
	t.near(corner.y, box.center.y + box.size.y * 0.5, 0.002, "y: centimetres down from the top (the top-left corner)")
	var arrows := (parsed.items as Array).filter(func(r): return str(r.get("type", "")) in ["arrow", "elbow"] and r.has("from") and r.has("to"))
	t.check(not arrows.is_empty(), "glued arrows say which shapes they connect")
	t.check((parsed.items as Array).any(func(r): return bool(r.get("selected", false))), "the selection is marked")
	var strokes := (parsed.items as Array).filter(func(r): return str(r.get("type", "")) == "stroke")
	t.check(not strokes.is_empty() and strokes.all(func(r): return (r.points as Array).size() <= CanvasBrief.MAX_POINTS), "freehand ink is a few points along it")
	var png := CanvasBrief.picture(doc, fid, true)
	var img := Image.new()
	t.check(png.size() > 1000 and img.load_png_from_buffer(png) == OK and maxi(img.get_width(), img.get_height()) == CanvasBrief.PICTURE_PX, "the picture is a PNG %d px across" % CanvasBrief.PICTURE_PX)


func _reply(doc: Document, fid: String) -> void:
	var b := CanvasBrief.make(doc, fid)
	var parsed: Dictionary = JSON.parse_string(b.json)
	var box_sid := ""
	var text_sid := ""
	var stroke_sid := ""
	for r in parsed.items:
		if str(r.get("type", "")) == "shape" and box_sid == "":
			box_sid = str(r.id)
		elif str(r.get("type", "")) == "text" and text_sid == "":
			text_sid = str(r.id)
		elif str(r.get("type", "")) == "stroke" and stroke_sid == "":
			stroke_sid = str(r.id)
	var answer := JSON.stringify({"say": "Added a review step.", "add": [
		{"type": "shape", "shape": "diamond", "id": "n1", "x": 10, "y": 120, "w": 24, "h": 16, "label": "Reviewed?", "fill": "#ffd166"},
		{"type": "arrow", "from": box_sid, "to": "n1"},
		{"type": "text", "text": "Legend", "x": 5, "y": 150, "size": "h2"},
		{"type": "stroke", "points": [[0, 0], [10, 5], [20, 0]], "color": "#ff0000"},
		{"type": "wobble"}, {"type": "arrow", "from": "nobody", "to": "n1"}],
		"change": [{"id": box_sid, "label": "Renamed"}, {"id": text_sid, "x": 1, "y": 1}, {"id": "zz9", "label": "x"}],
		"remove": [stroke_sid, "zz9"]})
	var r := AiReply.build("Here you go:\n" + answer, b, doc)
	t.eq(r.say, "Added a review step.", "the words")
	t.eq(r.items.size(), 4, "diamond, arrow, text and stroke are made")
	t.eq(r.skipped, 3, "the unknown type, the arrow from nowhere and the unknown id are skipped")
	var diamond: Item = r.items[0]
	t.eq(diamond.shape, "diamond", "a decision diamond")
	t.near(diamond.size.x, 0.24, 1e-4, "its size in metres")
	t.near(diamond.fill.a, float(App.val("fill_alpha")), 1e-3, "an opaque fill is made see-through like the app's fills")
	var corner := b.to_frame(10, 120)
	t.near(diamond.center.x - diamond.size.x * 0.5, corner.x, 1e-4, "placed by its top-left corner")
	var arrow: Item = null
	for it in r.items:
		if (it as Item).is_line():
			arrow = it
	t.check(arrow != null and str(arrow.glue_a.get("item", "")) == str(b.ids[box_sid]) and str(arrow.glue_b.get("item", "")) == diamond.id, "the arrow is glued from the existing box to the new diamond")
	t.check(arrow != null and arrow.b.distance_to(Shapes.port_world(diamond, int(arrow.glue_b.port)).pos) < 1e-5, "... ending on a port of the diamond")
	t.eq(r.changed.size(), 2, "two changes")
	t.eq((r.changed[0] as Item).id, str(b.ids[box_sid]), "a change keeps the item's id")
	t.eq((r.changed[0] as Item).label, "Renamed", "the new label")
	t.eq(r.removed, [str(b.ids[stroke_sid])], "the removal names the real item; unknown ids are ignored")
	t.check(AiReply.build("{\"say\": \"Fine as it is.\"}", b, doc).draws() == false, "words only: nothing drawn")


# ------------------------------------------------------------------------------------------------ the whole loop

func _controller(board: Board, fid: String) -> void:
	var ai := board.ai
	ai.models_path = "user://test_ai_models.json"
	var fake := FakeClient.new()
	ai.client = fake
	App.put("ai_provider", "anthropic")
	App.put("ai_key_anthropic", "")
	t.check(not ai.ask("opinion", "", fid), "without a key nothing is sent")
	t.check(ai.status.contains("API key"), "... and the user is told to add one")
	ai.set_key("anthropic", "sk-ant-test-1234")
	t.eq(fake.listed, ["anthropic"], "a new key fetches the model list")
	t.eq(ai.model("anthropic"), "model-a", "the first listed model is chosen when the suggested one is not there")
	t.eq(ai.modes("anthropic").size(), 2, "its thinking modes come from the list")
	t.eq(ai.key_hint("anthropic"), "…1234", "the key is shown only by its end")

	# words only: a note beside the drawing, one undo step
	var before := board.doc.items_of(fid).size()
	fake.answer = "{\"say\": \"Clear flow. The loop back is unlabelled.\", \"add\": [], \"change\": [], \"remove\": []}"
	t.check(ai.ask("opinion", "", fid), "the request starts")
	t.eq(fake.asked.size(), 1, "the model is asked once")
	var sent: Array = fake.asked[0]
	t.check(str(sent[5]).contains("honest opinion") and str(sent[5]).contains("\"items\""), "the prompt holds the request and the canvas")
	t.check(int(sent[6]) > 1000, "a picture goes along")
	t.eq(str(sent[3]), AiPrompts.SYSTEM, "the app's system prompt")
	t.eq(board.doc.items_of(fid).size(), before + 1, "the answer is placed as a note")
	var note: Item = board.doc.items.get(str(ai.last.get("note", "")))
	t.check(note != null and note.kind == Item.TEXT and note.text.contains("Clear flow."), "the note holds the words")
	board.undo()
	t.eq(board.doc.items_of(fid).size(), before, "undo removes the note")

	# a follow-up carries the earlier turns
	fake.answer = JSON.stringify({"say": "Added a review step.", "add": [{"type": "shape", "shape": "rect", "id": "n1", "x": 5, "y": 5, "w": 20, "h": 10, "label": "Review"}],
		"change": [], "remove": []})
	ai.ask("ask", "Add a review step", fid)
	t.eq((fake.asked[1][4] as Array).size(), 2, "the earlier question and answer are sent with the next one")
	t.check(str(fake.asked[1][5]).begins_with("Add a review step"), "your own words are the request")
	t.eq(board.doc.items_of(fid).size(), before, "a drawing is not put in the document by itself")
	t.check(ai.has_layer(fid), "it becomes a suggestion layer")
	var fn: FrameNode = board.frame_nodes[fid]
	t.check(fn.ai_shown(), "the layer is shown over the canvas")
	t.check(FileAccess.file_exists(DocStore.ai_path(board.doc.id)), "the suggestion is kept in its own file")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DocStore.ai_path(board.doc.id)))
	t.check(saved.layer.has(fid) and not FileAccess.get_file_as_string(board.doc.path if board.doc.path != "" else DocStore.path_for(board.doc.id)).contains("Review\""), "... not in the document")
	ai.set_visible(fid, false)
	t.check(not fn.ai_shown(), "Hide takes it off the canvas")
	ai.set_visible(fid, true)
	t.check(ai.accept(fid), "Accept")
	t.eq(board.doc.items_of(fid).size(), before + 1, "the suggested box is in the document")
	t.check(not ai.has_layer(fid) and not fn.ai_shown(), "the layer is gone")
	t.eq(board.selection.size(), 1, "the new box is selected so it can be moved")
	board.undo()
	t.eq(board.doc.items_of(fid).size(), before, "one undo takes the whole suggestion back")

	# a change hides the original while it is suggested; a removal is marked; Discard leaves the document alone
	var box: Item = null
	for it in board.doc.items_of(fid):
		if (it as Item).kind == Item.SHAPE and not (it as Item).is_line():
			box = it
			break
	var b := CanvasBrief.make(board.doc, fid)
	var sid := str(b.short[box.id])
	fake.answer = JSON.stringify({"say": "Renamed it.", "change": [{"id": sid, "label": "Better name"}]})
	ai.ask("improve", "", fid)
	t.check(not fn.view_of(box.id).visible, "the item being changed is hidden behind its suggested version")
	ai.discard(fid)
	t.check(fn.view_of(box.id).visible and (board.doc.items[box.id] as Item).label != "Better name", "Discard shows the original again, unchanged")
	ai.ask("improve", "", fid)
	ai.accept(fid)
	t.eq((board.doc.items[box.id] as Item).label, "Better name", "accepting a change changes the item")
	board.undo()

	# the file comes back with the document
	fake.answer = JSON.stringify({"say": "x", "add": [{"type": "text", "text": "Later", "x": 0, "y": 0}]})
	ai.ask("continue", "", fid)
	board.flush_save()
	board.doc.save()
	var id := board.doc.id
	board.open_id(id)
	t.check(board.ai.has_layer(fid) and (board.frame_nodes[fid] as FrameNode).ai_shown(), "an open suggestion is shown again when the document is reopened")
	t.eq((board.ai.chat.get(fid, []) as Array).size(), 10, "the conversation is kept too")
	board.ai.forget(fid)
	t.check(not board.ai.chat.has(fid), "New conversation forgets it")
	board.ai.client = fake

	# errors
	fake.fail = "Claude did not accept the API key."
	board.ai.ask("explain", "", fid)
	t.eq(board.ai.status, fake.fail, "an error is shown")
	t.check(not board.ai.busy, "and the assistant is free again")
	fake.fail = ""
	await get_tree().process_frame


func _web(board: Board, fid: String) -> void:
	var srv := board.share
	srv.require_pin = false
	var page := srv.route("/ai")
	t.eq(page.status, 200, "the AI page answers")
	t.check((page.body as PackedByteArray).get_string_from_utf8().contains("id=ai-provs"), "it has the keys and models section")
	t.check(WebPages.shell("x", "").contains("href='/ai'"), "every page links to it")
	var st: Dictionary = JSON.parse_string((srv.route("/api/ai/state").body as PackedByteArray).get_string_from_utf8())
	t.check(bool(st.ok) and (st.providers as Array).size() == 3, "the state lists the three providers")
	t.check(not JSON.stringify(st).contains("sk-ant-test-1234"), "the key itself never leaves the device")
	t.check(JSON.stringify(st).contains("…1234"), "only its last four characters")
	t.check((st.layers as Array).size() == 1, "the open suggestion is listed")
	var hdr := {"x-requested-with": "mrw"}
	var res := srv.handle("POST", "/api/ai/key", hdr, JSON.stringify({"provider": "openai", "key": "sk-openai-9876", "use": "1"}).to_utf8_buffer(), "127.0.0.1")
	t.eq(res.status, 200, "a key can be saved from the page")
	t.eq(App.val("ai_key_openai"), "sk-openai-9876", "it is stored on the device")
	t.eq(board.ai.provider(), "openai", "and that provider is used")
	var bad := srv.handle("POST", "/api/ai/key", hdr, JSON.stringify({"provider": "openai", "key": "not a key"}).to_utf8_buffer(), "127.0.0.1")
	t.eq(bad.status, 422, "something that is not a key is refused")
	var forged := srv.handle("POST", "/api/ai/key", {}, JSON.stringify({"provider": "openai", "key": "x"}).to_utf8_buffer(), "127.0.0.1")
	t.eq(forged.status, 403, "other sites cannot set a key")
	srv.handle("POST", "/api/ai/select", hdr, JSON.stringify({"provider": "openai", "mode": "high", "picture": false}).to_utf8_buffer(), "127.0.0.1")
	t.eq(board.ai.mode("openai"), "high", "the thinking level is set from the page")
	t.eq(App.val("ai_picture"), false, "the picture option is set from the page")
	var fake: FakeClient = board.ai.client
	var n := fake.asked.size()
	fake.answer = "{\"say\": \"ok\"}"
	var asked := srv.handle("POST", "/api/ai/ask", hdr, JSON.stringify({"action": "explain", "frame": fid}).to_utf8_buffer(), "127.0.0.1")
	t.eq(asked.status, 200, "a question can be asked from the page")
	t.eq(fake.asked.size(), n + 1, "... and reaches the model")
	t.eq(int(fake.asked[n][6]), 0, "without the picture when it is switched off")
	var acc := srv.handle("POST", "/api/ai/accept", hdr, JSON.stringify({"frame": fid}).to_utf8_buffer(), "127.0.0.1")
	t.eq(acc.status, 200, "the suggestion is accepted from the page")
	App.put("ai_picture", true)
	App.put("ai_provider", "anthropic")
