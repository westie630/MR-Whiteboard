class_name AiController
extends RefCounted
## The AI assistant: ask a language model (Claude, OpenAI or MiniMax, with your own API key) about the canvas in front of you.
##
## A button picks what is asked (Opinion, Improve it, Continue, ...; or your own typed / spoken question); the app writes the prompt,
## describes the canvas (CanvasBrief: what is on it, plus a picture) and sends it with the earlier questions about that canvas, so
## follow-ups work. The answer comes back in two parts:
##   * words: shown in the menu and on the web page, and placed as a text note beside the drawing when nothing is drawn;
##   * a drawing: a suggestion layer shown over the canvas (outlined, items it would change are swapped in, items it would delete are
##     crossed out) that you Accept (one undo step) or Discard. It is kept in its own file next to the document (<doc id>.ai.json),
##     never in the document itself, until you accept it.
## Keys, model and thinking level per provider are settings; the model lists are fetched from the providers and kept in a file.

const NOTE_WRAP := 44
const HISTORY_TURNS := 8                  # earlier messages about a canvas sent along with a new request
const KEEP_TURNS := 80                    # messages kept per canvas for the conversation shown in the assistant

var board: Board
var client                                # LlmClient (tests put a fake here)
var models_path := "user://ai_models.json"
var busy := false
var status := ""                          # what is going on, or what went wrong, in a few words
var last := {}                            # the latest answer: {frame, action, label, say, model, provider, time, error, draws}
var layer := {}                           # frame id -> suggestion {items, changed, removed, say, label, model, time, visible}
var chat := {}                            # frame id -> [{role, text, label?, say?, model?, draws?}] (the model is sent role and text)
var asking := {}                          # the question on its way: {frame, label, action}, {} when none
var models := {}                          # provider -> {time, models: [{id, name, vision, modes}], error}
var fetching := {}                        # provider -> true while its model list is being fetched

var _doc_id := ""


func _init(b: Board) -> void:
	board = b
	client = LlmClient.new(b)
	_load_models()


# ------------------------------------------------------------------------------------------------ settings

func provider() -> String:
	var p := str(App.val("ai_provider"))
	return p if LlmApi.is_provider(p) else "anthropic"


func key(p: String = "") -> String:
	return str(App.val("ai_key_" + (p if p != "" else provider()))).strip_edges()


func model(p: String = "") -> String:
	p = p if p != "" else provider()
	var m := str(App.val("ai_model_" + p))
	return m if m != "" else str(LlmApi.PROVIDERS[p].default_model)


func mode(p: String = "") -> String:
	p = p if p != "" else provider()
	var want := str(App.val("ai_think_" + p))
	for m in modes(p):
		if m[0] == want:
			return want
	return "default"


## The models known for a provider: [{id, name, vision, modes}].
func model_list(p: String = "") -> Array:
	return (models.get(p if p != "" else provider(), {}) as Dictionary).get("models", [])


func model_info(p: String = "", id: String = "") -> Dictionary:
	p = p if p != "" else provider()
	id = id if id != "" else model(p)
	for m in model_list(p):
		if m.id == id:
			return m
	return {}


func model_name(p: String = "") -> String:
	var info := model_info(p)
	return str(info.get("name", model(p))) if not info.is_empty() else model(p)


## Thinking modes of the chosen model: [[id, label], ...] (just the model's default until the list has been fetched).
func modes(p: String = "") -> Array:
	var info := model_info(p)
	if info.is_empty():
		p = p if p != "" else provider()
		return LlmApi.anthropic_modes(null) if p == "anthropic" else LlmApi.guess_modes(p, model(p))
	return info.modes


func set_provider(p: String) -> void:
	if LlmApi.is_provider(p):
		App.put("ai_provider", p)
		if key(p) != "" and model_list(p).is_empty() and not fetching.has(p):
			refresh_models(p)
		board.changed.emit()


func set_key(p: String, k: String) -> void:
	if not LlmApi.is_provider(p):
		return
	App.put("ai_key_" + p, k.strip_edges())
	models.erase(p)
	_save_models()
	if k.strip_edges() != "":
		refresh_models(p)
	board.changed.emit()


func set_model(p: String, id: String) -> void:
	App.put("ai_model_" + p, id)
	board.changed.emit()


func set_mode(p: String, m: String) -> void:
	App.put("ai_think_" + p, m)
	board.changed.emit()


## "…a1b2": enough of a key to tell which one is saved, never the key itself.
func key_hint(p: String) -> String:
	var k := key(p)
	return "" if k == "" else "…" + k.right(4)


# ------------------------------------------------------------------------------------------------ model lists

func refresh_models(p: String = "") -> void:
	p = p if p != "" else provider()
	if key(p) == "":
		models[p] = {"time": 0, "models": [], "error": "Add a %s API key first." % LlmApi.name_of(p)}
		board.changed.emit()
		return
	if fetching.has(p):
		return
	fetching[p] = true
	board.changed.emit()
	client.list_models(p, key(p), func(res: Dictionary):
		fetching.erase(p)
		if bool(res.ok):
			models[p] = {"time": int(Time.get_unix_time_from_system()), "models": res.models, "error": ""}
			if model_info(p).is_empty() or str(App.val("ai_model_" + p)) == "":
				App.put("ai_model_" + p, _pick_default(p))
		else:
			var keep: Array = model_list(p)
			models[p] = {"time": int(Time.get_unix_time_from_system()), "models": keep, "error": str(res.error)}
			board.toast.emit(str(res.error))
		_save_models()
		board.changed.emit())


## The model a provider starts with: its suggested one when the list has it, else the newest full-size model.
func _pick_default(p: String) -> String:
	var want := str(LlmApi.PROVIDERS[p].default_model)
	var list := model_list(p)
	for m in list:
		if m.id == want:
			return want
	for m in list:
		var l := str(m.id).to_lower()
		if not (l.contains("mini") or l.contains("nano") or l.contains("haiku") or l.contains("flash") or l.contains("preview")):
			return str(m.id)
	return str(list[0].id) if not list.is_empty() else want


func _load_models() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(models_path)) if FileAccess.file_exists(models_path) else null
	models = parsed if parsed is Dictionary else {}


func _save_models() -> void:
	var f := FileAccess.open(models_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(models))
		f.close()


# ------------------------------------------------------------------------------------------------ the suggestion file

func open_doc() -> void:
	_doc_id = board.doc.id if board.doc != null else ""
	layer = {}
	chat = {}
	last = {}
	asking = {}
	status = ""
	var p := DocStore.ai_path(_doc_id)
	if _doc_id != "" and FileAccess.file_exists(p):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if parsed is Dictionary:
			layer = parsed.get("layer", {}) if parsed.get("layer") is Dictionary else {}
			chat = parsed.get("chat", {}) if parsed.get("chat") is Dictionary else {}
	for fid in layer.keys():
		render(str(fid))


func close_doc() -> void:
	_doc_id = ""
	layer = {}
	chat = {}


func _save() -> void:
	if _doc_id == "":
		return
	var p := DocStore.ai_path(_doc_id)
	if layer.is_empty() and chat.is_empty():
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		return
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"format": "mr-whiteboard-ai", "doc": _doc_id, "layer": layer, "chat": chat}))
		f.close()


# ------------------------------------------------------------------------------------------------ asking

## The canvas a request is about: the one with the selection, else the one in front of you, else the last one drawn on.
func target_frame() -> String:
	if board.doc == null:
		return ""
	if board.sel_frame != "" and not board.selection.is_empty():
		return board.sel_frame
	var spot := board.dictation_spot()
	if not spot.is_empty():
		return str(spot.frame)
	return board.active_frame if board.doc.frames.has(board.active_frame) else ""


## Why asking cannot start right now ("" when it can).
func ready_reason() -> String:
	if key() == "":
		return "Add your %s API key: tap the model at the top of the assistant, or paste it on the web page (Home > Share, then AI at the top)." % LlmApi.name_of(provider())
	if busy:
		return "Still waiting for the last answer."
	return ""


## Ask about a canvas. `action` is an AiPrompts action id, or "ask" with your own `question`. Returns false when it could not start.
## `note` false keeps the answer in the assistant's conversation (the chat never writes onto the canvas by itself: see `write` and
## the Place button for that); true follows the "Answers also as a note" setting (the web page).
func ask(action: String, question: String = "", frame_id: String = "", note: bool = true) -> bool:
	var why := ready_reason()
	if why == "" and action == "ask" and question.strip_edges() == "":
		why = "Type or say a question first."
	var fid := frame_id if frame_id != "" else target_frame()
	if why == "" and (fid == "" or board.doc == null or not board.doc.frames.has(fid)):
		why = "Place a canvas first: the assistant talks about the canvas in front of you."
	if why != "":
		status = why
		board.toast.emit(why)
		board.changed.emit()
		return false
	var p := provider()
	var dark := is_dark(fid)
	var sel: Array = board.selection.duplicate() if board.sel_frame == fid else []
	var brief := CanvasBrief.make(board.doc, fid, sel, dark)
	var png := PackedByteArray()
	if bool(App.val("ai_picture")) and brief.count > 0 and bool(model_info(p).get("vision", true)):
		png = CanvasBrief.picture(board.doc, fid, dark)
	var label := AiPrompts.label_of(action) if action != "ask" else question.strip_edges()
	var prompt := AiPrompts.request(action, question, brief.json, not png.is_empty(), sel.size())
	var history: Array = (chat.get(fid, []) as Array).slice(-HISTORY_TURNS)
	var m := model(p)
	busy = true
	asking = {"frame": fid, "label": label, "action": action, "note": note}
	status = "%s is thinking about \"%s\"..." % [model_name(p), label.left(60)]
	board.changed.emit()
	var started := Time.get_ticks_msec()
	client.chat(p, key(p), m, mode(p), AiPrompts.SYSTEM, history, prompt, png, func(res: Dictionary):
		_on_answer(res, fid, action, label, brief, p, m, started))
	return true


## AI text: have the model write words for a canvas ("a short agenda for a stand-up", typed or spoken). The words come back as a
## pending text on the board's placement tool: point at a canvas and tap to put them down, back to throw them away. Returns false
## when it could not start.
func write(prompt: String) -> bool:
	var why := ready_reason()
	if why == "" and prompt.strip_edges() == "":
		why = "Type or say what the text should be about."
	if why == "" and board.doc == null:
		why = "Open a document first."
	if why != "":
		status = why
		board.toast.emit(why)
		board.changed.emit()
		return false
	var p := provider()
	var m := model(p)
	var label := prompt.strip_edges()
	busy = true
	asking = {"frame": "", "label": label, "action": "write", "note": false}
	status = "%s is writing \"%s\"..." % [model_name(p), label.left(60)]
	board.changed.emit()
	client.chat(p, key(p), m, mode(p), AiPrompts.TEXT_SYSTEM, [], label, PackedByteArray(), func(res: Dictionary):
		busy = false
		asking = {}
		if not bool(res.ok):
			status = str(res.error)
			board.toast.emit(status)
			board.changed.emit()
			return
		var words := AiPrompts.clean_text(str(res.text))
		if words == "":
			status = "The model sent no text."
			board.toast.emit(status)
			board.changed.emit()
			return
		status = "%s wrote the text: point at a canvas and tap to place it." % model_name(p)
		board.begin_place_text(words)
		board.changed.emit())
	return true


func _on_answer(res: Dictionary, fid: String, action: String, label: String, brief: CanvasBrief, p: String, m: String, started: int) -> void:
	var note_wanted := bool(asking.get("note", true))
	busy = false
	asking = {}
	var secs := float(Time.get_ticks_msec() - started) / 1000.0
	last = {"frame": fid, "action": action, "label": label, "provider": p, "model": model_name(p), "time": int(Time.get_unix_time_from_system()),
		"say": "", "error": "", "draws": false, "seconds": snappedf(secs, 0.1)}
	if not bool(res.ok):
		last.error = str(res.error)
		status = str(res.error)
		board.toast.emit(status)
		board.changed.emit()
		return
	if board.doc == null or not board.doc.frames.has(fid):
		status = "The canvas went away before the answer came."
		board.changed.emit()
		return
	var reply := AiReply.build(str(res.text), brief, board.doc)
	var say := reply.say
	var left_out: PackedStringArray = res.get("left_out", PackedStringArray())
	last.say = say
	last.draws = reply.draws()
	var turns: Array = chat.get(fid, [])
	turns.append({"role": "user", "text": label if action != "ask" else "Question: " + label, "label": label, "action": action})
	var summary := say
	if reply.draws():
		summary += "\n[I proposed: %d new, %d changed, %d removed items.]" % [reply.items.size(), reply.changed.size(), reply.removed.size()]
	var counts := _counts({"items": reply.items, "changed": reply.changed, "removed": reply.removed}) if reply.draws() else ""
	turns.append({"role": "assistant", "text": summary if summary.strip_edges() != "" else "(no words)", "say": say, "model": model_name(p), "draws": counts, "time": last.time})
	chat[fid] = turns.slice(-KEEP_TURNS)
	if reply.draws():
		var items: Array = []
		for it in reply.items:
			items.append((it as Item).to_dict())
		var changed: Array = []
		for it in reply.changed:
			changed.append((it as Item).to_dict())
		layer[fid] = {"items": items, "changed": changed, "removed": reply.removed.duplicate(), "say": say, "label": label,
			"model": model_name(p), "time": last.time, "visible": true}
		render(fid)
		status = "%s suggests %s on \"%s\": Accept or Discard." % [model_name(p), _counts(layer[fid]), _frame_name(fid)]
	else:
		status = "%s answered (%.0f s)." % [model_name(p), secs]
		if say != "" and note_wanted and bool(App.val("ai_note")):
			var note := place_note(fid, say)
			if note != null:
				last["note"] = note.id
	if not left_out.is_empty():
		var what := PackedStringArray()
		for x in left_out:
			what.append("picture" if x == "picture" else "thinking level")
		status += " (The model did not take the %s, so it was asked without.)" % " / ".join(what)
	_save()
	board.toast.emit(status)
	board.changed.emit()


func _counts(s: Dictionary) -> String:
	var parts := PackedStringArray()
	var n := (s.get("items", []) as Array).size()
	var c := (s.get("changed", []) as Array).size()
	var r := (s.get("removed", []) as Array).size()
	if n > 0:
		parts.append("%d new" % n)
	if c > 0:
		parts.append("%d changed" % c)
	if r > 0:
		parts.append("%d removed" % r)
	return ", ".join(parts) if not parts.is_empty() else "nothing"


func _frame_name(fid: String) -> String:
	var f: FrameData = board.doc.frames.get(fid) if board.doc != null else null
	return f.name if f != null else fid


## Does the canvas look dark in the headset (light ink on glass / dark backing)?
func is_dark(fid: String) -> bool:
	var f: FrameData = board.doc.frames.get(fid)
	var backing := f.backing if f != null and f.backing != "" else str(App.val("backing"))
	return backing != "white"


## The answer as a text item beside what is drawn (to its right, level with its top): one undo step.
func place_note(fid: String, text: String) -> Item:
	var words := TextController.wrap_text(text.strip_edges(), NOTE_WRAP)
	if words == "" or board.doc == null:
		return null
	var st := TextLayout.style("small")
	var col := Color("#c4b5fd") if is_dark(fid) else Color("#6d28d9")
	var t := Item.make_text(fid, words, col, float(st[2]), int(st[3]))
	var list := board.doc.items_of(fid)
	if list.is_empty():
		var fn: FrameNode = board.frame_nodes.get(fid)
		t.center = fn.bounds().get_center() if fn != null else Vector2.ZERO
	else:
		var r := Rect2()
		var first := true
		for it in list:
			r = (it as Item).bounds() if first else r.merge((it as Item).bounds())
			first = false
		t.center = Vector2(r.end.x + 0.08 + t.size.x * 0.5, r.end.y - t.size.y * 0.5)
	board.history.do(History.op_add([t]))
	return t


# ------------------------------------------------------------------------------------------------ the suggestion layer

func has_layer(fid: String) -> bool:
	return layer.has(fid)


## Show (or clear) a canvas's suggestion layer in the room.
func render(fid: String) -> void:
	var fn: FrameNode = board.frame_nodes.get(fid)
	if fn == null:
		return
	var s: Dictionary = layer.get(fid, {})
	if s.is_empty() or not bool(s.get("visible", true)):
		fn.show_ai([], [], [])
		return
	var shown: Array = []
	var hidden: Array = []
	var marks: Array = []
	var z := board.doc.next_z + 1000
	for d in s.get("items", []):
		var it := Item.from_dict(d)
		it.z = z
		z += 1
		shown.append(it)
		marks.append({"rect": it.bounds(), "kind": "new"})
	for d in s.get("changed", []):
		var c := Item.from_dict(d)
		if not board.doc.items.has(c.id):
			continue
		c.z = z
		z += 1
		shown.append(c)
		hidden.append(c.id)
		marks.append({"rect": c.bounds(), "kind": "new"})
	for id in s.get("removed", []):
		var old: Item = board.doc.items.get(str(id))
		if old != null:
			marks.append({"rect": old.bounds(), "kind": "removed"})
	fn.show_ai(shown, hidden, marks)


func set_visible(fid: String, on: bool) -> void:
	if layer.has(fid):
		layer[fid].visible = on
		render(fid)
		_save()
		board.changed.emit()


## Put the suggestion into the document: one undo step. The new items are selected so they can be moved straight away.
func accept(fid: String = "") -> bool:
	fid = fid if fid != "" else _layer_frame()
	var s: Dictionary = layer.get(fid, {})
	if s.is_empty() or board.doc == null or board.history == null:
		return false
	var doc := board.doc
	var removed: Array = []
	for id in s.get("removed", []):
		if doc.items.has(str(id)):
			removed.append(doc.items[str(id)])
	var before: Array = []
	var after: Array = []
	var moved: Array = []
	for d in s.get("changed", []):
		var c := Item.from_dict(d)
		if doc.items.has(c.id) and not s.get("removed", []).has(c.id):
			before.append(doc.items[c.id])
			after.append(c)
			moved.append(c.id)
	var added: Array = []
	for d in s.get("items", []):
		var it := Item.from_dict(d)
		it.z = 0
		it.frame = fid
		added.append(it)
	board.history.begin_group()
	if not removed.is_empty():
		board._release_glue_to(removed)
		board.history.do(History.op_remove(removed))
	if not before.is_empty():
		board.history.do(History.op_modify(before, after))
		board.follow_connectors(moved, fid)
	if not added.is_empty():
		board.history.do(History.op_add(added))
	board.history.end_group()
	layer.erase(fid)
	render(fid)
	_save()
	var ids: Array = []
	for it in added:
		if doc.items.has((it as Item).id):
			ids.append((it as Item).id)
	if not ids.is_empty():
		board.select_items(ids, fid)
	status = "Suggestion added to \"%s\" (undo takes it back)." % _frame_name(fid)
	board.toast.emit(status)
	board.changed.emit()
	return true


func discard(fid: String = "") -> bool:
	fid = fid if fid != "" else _layer_frame()
	if not layer.has(fid):
		return false
	layer.erase(fid)
	render(fid)
	_save()
	status = "Suggestion discarded."
	board.changed.emit()
	return true


## Forget the conversation about a canvas (the next question starts afresh).
func forget(fid: String = "") -> void:
	fid = fid if fid != "" else target_frame()
	chat.erase(fid)
	_save()
	status = "The assistant has forgotten the earlier questions about this canvas."
	board.changed.emit()


## The canvas whose suggestion the menu's buttons act on: the one you are asking about, else any canvas with one.
func _layer_frame() -> String:
	var fid := target_frame()
	if layer.has(fid):
		return fid
	for k in layer.keys():
		if board.doc != null and board.doc.frames.has(str(k)):
			return str(k)
	return ""


## The suggestion the menu shows: {frame, name, counts, say, visible} or {}.
func current_layer() -> Dictionary:
	var fid := _layer_frame()
	if fid == "":
		return {}
	var s: Dictionary = layer[fid]
	return {"frame": fid, "name": _frame_name(fid), "counts": _counts(s), "say": str(s.get("say", "")), "visible": bool(s.get("visible", true)),
		"model": str(s.get("model", "")), "label": str(s.get("label", ""))}


# ------------------------------------------------------------------------------------------------ the web page

## What the web page (ExportServer, /ai) asks and changes. Answers are plain dictionaries ({ok, message?, ...}).
func api(cmd: String, data: Dictionary) -> Dictionary:
	match cmd:
		"state":
			return web_state()
		"key":
			var p := str(data.get("provider", ""))
			if not LlmApi.is_provider(p):
				return {"ok": false, "message": "Unknown provider."}
			var k := str(data.get("key", "")).strip_edges()
			if k.length() > 400 or k.contains(" ") or k.contains("\n"):
				return {"ok": false, "message": "That does not look like an API key."}
			set_key(p, k)
			if k != "" and str(data.get("use", "")) != "":
				set_provider(p)
			return {"ok": true, "message": ("%s key saved on the headset. Fetching its models..." % LlmApi.name_of(p)) if k != "" else "%s key removed." % LlmApi.name_of(p)}
		"select":
			var p2 := str(data.get("provider", provider()))
			if not LlmApi.is_provider(p2):
				return {"ok": false, "message": "Unknown provider."}
			if bool(data.get("use", false)):
				set_provider(p2)
			if data.has("model"):
				set_model(p2, str(data.model))
			if data.has("mode"):
				set_mode(p2, str(data.mode))
			if data.has("picture"):
				App.put("ai_picture", bool(data.picture))
			if data.has("note"):
				App.put("ai_note", bool(data.note))
			return {"ok": true}
		"refresh":
			refresh_models(str(data.get("provider", provider())))
			return {"ok": true, "message": "Fetching the model list..."}
		"ask":
			var fid := str(data.get("frame", ""))
			if fid != "" and (board.doc == null or not board.doc.frames.has(fid)):
				return {"ok": false, "message": "That canvas is gone."}
			var act := str(data.get("action", "ask"))
			if act != "ask" and AiPrompts.action(act).is_empty():
				return {"ok": false, "message": "Unknown request."}
			if not ask(act, str(data.get("text", "")).left(4000), fid):
				return {"ok": false, "message": status}
			return {"ok": true, "message": status}
		"accept":
			return {"ok": accept(str(data.get("frame", ""))), "message": status}
		"discard":
			return {"ok": discard(str(data.get("frame", ""))), "message": status}
		"show":
			set_visible(str(data.get("frame", "")), bool(data.get("visible", true)))
			return {"ok": true}
		"forget":
			forget(str(data.get("frame", "")))
			return {"ok": true, "message": status}
	return {"ok": false, "message": "Unknown request."}


func web_state() -> Dictionary:
	var provs: Array = []
	for p in LlmApi.ORDER:
		var info: Dictionary = models.get(p, {})
		var list: Array = []
		for m in model_list(p):
			list.append({"id": m.id, "name": m.name})
		provs.append({"id": p, "name": LlmApi.name_of(p), "has_key": key(p) != "", "key_hint": key_hint(p), "keys_url": str(LlmApi.PROVIDERS[p].keys_url),
			"model": model(p), "mode": mode(p), "models": list, "modes": modes(p), "fetching": fetching.has(p), "error": str(info.get("error", "")),
			"exact_modes": p == "anthropic" and not model_info(p).is_empty()})
	var canvases: Array = []
	if board.doc != null:
		for f in board.doc.frames.values():
			var fd: FrameData = f
			if fd.kind == FrameData.CANVAS and (fd.room == board.current_room or board.current_room == ""):
				canvases.append({"id": fd.id, "name": fd.name, "items": board.doc.items_of(fd.id).size()})
	var layers: Array = []
	for fid in layer.keys():
		if board.doc != null and board.doc.frames.has(str(fid)):
			var s: Dictionary = layer[fid]
			layers.append({"frame": fid, "name": _frame_name(str(fid)), "counts": _counts(s), "say": str(s.get("say", "")), "visible": bool(s.get("visible", true)),
				"model": str(s.get("model", "")), "label": str(s.get("label", ""))})
	var actions: Array = []
	for a in AiPrompts.ACTIONS:
		actions.append([a[0], a[1], a[4]])
	return {"ok": true, "provider": provider(), "providers": provs, "busy": busy, "status": status, "last": last, "canvases": canvases,
		"target": target_frame(), "picture": bool(App.val("ai_picture")), "note": bool(App.val("ai_note")), "layers": layers, "actions": actions}
