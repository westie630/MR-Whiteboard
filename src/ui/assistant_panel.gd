class_name AssistantPanel
extends FloatPanel
## The AI assistant as a conversation about the canvas in front of you (or the selection): your messages and its answers as a thread,
## a suggestion it drew shown as a card in its answer (accept, discard, hide), a typing indicator while it thinks, quick requests
## above the box you write in (type, or speak). The provider, model, thinking level and key fold away under the model's name.
## Each canvas has its own conversation; it is kept with the document (in the suggestion file).

const W := 540.0
const H := 760.0
const BUBBLE_W := 390.0

var composer: LineEdit                     # PC: typed into directly (the headset opens the typing card instead)

var _about: Label
var _model_chip: Btn
var _settings: VBoxContainer
var _models_box: VBoxContainer
var _modes_box: HFlowContainer
var _key_btn: Btn
var _key_note: Label
var _scroll: ScrollContainer
var _thread: VBoxContainer
var _chips: Array = []
var _send: Btn
var _mic: Btn
var _sig := ""
var _thread_sig := ""
var grip: Dock.Grip


func _init() -> void:
	super()
	id = "assistant"
	kind = "side"
	side = 1
	movable = true
	auto_size = false
	pivot = Vector2(0.5, 0.5)
	max_size = Vector2(W + 40, H + 40)
	ppm = 1500.0
	custom_minimum_size = Vector2(W, H)
	var sb := UITheme.glass(26, 16.0)
	sb.border_color = Color(UITheme.AI.r, UITheme.AI.g, UITheme.AI.b, 0.28)
	add_theme_stylebox_override("panel", sb)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	# header: what the conversation is about, the model (tap: settings), a new conversation, close
	var head := UiKit.hrow(root, 4)
	grip = Dock.Grip.new()
	grip.custom_minimum_size = Vector2(18, 44)
	head.add_child(grip)
	var spark := Btn.new("ai", "")
	spark.variant = "tool"
	spark.accent = UITheme.AI
	spark.on = true
	spark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spark.custom_minimum_size = Vector2(44, 44)
	head.add_child(spark)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -4)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(titles)
	var title := UiKit.label("Assistant", false, UITheme.FONT, 600)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	titles.add_child(title)
	_about = UiKit.label("", true, UITheme.FONT_TINY)
	_about.autowrap_mode = TextServer.AUTOWRAP_OFF
	_about.clip_text = true
	titles.add_child(_about)
	_model_chip = UiKit.chip("", func(): _settings.visible = not _settings.visible, "", 38.0)
	_model_chip.variant = "ghost"
	_model_chip.hint = "Model, thinking and key"
	_model_chip.custom_minimum_size.x = 150
	head.add_child(_model_chip)
	head.add_child(UiKit.tool("plus", "New conversation", func(): shell.board.ai.forget(), 44.0))
	head.add_child(UiKit.tool("close", "Close", func(): shell.close_side("assistant"), 44.0))

	_settings = UiKit.vcol(root, 10)
	_settings.visible = false
	_build_settings(_settings)

	# the conversation
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)
	_thread = VBoxContainer.new()
	_thread.add_theme_constant_override("separation", 10)
	_thread.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_thread)

	# quick requests
	var chips := UiKit.flow(root, 6)
	for a in AiPrompts.ACTIONS:
		var aid: String = a[0]
		var c := UiKit.chip(str(a[1]), func(): _ask(aid), str(a[2]), 38.0)
		c.variant = "ghost"
		c.accent = UITheme.AI
		c.tint = UITheme.AI
		chips.add_child(c)
		_chips.append(c)

	# the box to write in
	var comp := PanelContainer.new()
	var csb := UITheme.box(Color(0, 0, 0, 0.28), 24, Color(1, 1, 1, 0.1), 1)
	csb.content_margin_left = 6
	csb.content_margin_right = 6
	csb.content_margin_top = 4
	csb.content_margin_bottom = 4
	comp.add_theme_stylebox_override("panel", csb)
	root.add_child(comp)
	var cr := UiKit.hrow(comp, 4)
	if App.xr_active:
		# in the headset the keyboard lives with the typing card: the box opens it
		var open := Btn.new("", "Message the assistant...")
		open.variant = "ghost"
		open.align = HORIZONTAL_ALIGNMENT_LEFT
		open.custom_minimum_size = Vector2(0, 46)
		open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		open.pressed.connect(_type_in_card)
		cr.add_child(open)
	else:
		composer = LineEdit.new()
		composer.placeholder_text = "Message the assistant..."
		composer.custom_minimum_size = Vector2(0, 46)
		composer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		composer.virtual_keyboard_enabled = false
		composer.context_menu_enabled = false
		composer.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		composer.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		composer.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
		composer.text_submitted.connect(func(_t: String): _send_text())
		composer.text_changed.connect(func(_t: String): _sync_send())
		cr.add_child(composer)
	_mic = UiKit.tool("mic", "Ask by voice", func(): shell.board.speech.toggle(func(t: String): shell.board.ai.ask("ask", t)), 46.0)
	cr.add_child(_mic)
	_send = UiKit.tool("send", "Send", func():
		if composer != null and composer.text.strip_edges() != "":
			_send_text()
		else:
			_type_in_card(), 46.0)
	_send.accent = UITheme.AI
	cr.add_child(_send)


func _build_settings(p: VBoxContainer) -> void:
	var c := UiKit.card(p)
	UiKit.header(c, "Provider")
	_kit.segmented(c, [["anthropic", "Claude"], ["openai", "OpenAI"], ["minimax", "MiniMax"]], func(): return shell.board.ai.provider(), func(v): shell.board.ai.set_provider(v))
	UiKit.header(c, "Model")
	_models_box = UiKit.vcol(c, 6)
	UiKit.header(c, "Thinking")
	_modes_box = UiKit.flow(c, 6)
	_key_btn = UiKit.button("keyboard", "", _set_key, 46.0, "ghost")
	c.add_child(_key_btn)
	_key_note = UiKit.note(c, "")
	_kit.switch(c, "Send a picture of the canvas", "ai_picture")
	_kit.switch(c, "Answers also as a note on the canvas", "ai_note")


func _set_key() -> void:
	var ai: AiController = shell.board.ai
	var pv := ai.provider()
	shell.ask_secret("%s API key" % LlmApi.name_of(pv), func(t: String): ai.set_key(pv, t.strip_edges()))


func _ask(action: String) -> void:
	shell.board.ai.ask(action)


func _send_text() -> void:
	var t := composer.text.strip_edges()
	if t == "":
		return
	if shell.board.ai.ask("ask", t):
		composer.text = ""
		_sync_send()


func _type_in_card() -> void:
	shell.open_entry("Message the assistant", "", true, func(t: String): shell.board.ai.ask("ask", t))


func _sync_send() -> void:
	_send.on = composer != null and composer.text.strip_edges() != ""


## The box to write in has the keyboard (PC): keys are not shortcuts then.
func typing() -> bool:
	return composer != null and composer.has_focus() and composer.is_visible_in_tree()


func refresh() -> void:
	_kit.sync()
	var b: Board = shell.board
	var ai: AiController = b.ai
	var p := ai.provider()
	_model_chip.text = ai.model_name(p)
	var fid := ai.target_frame()
	var fd: FrameData = b.doc.frames.get(fid) if b.doc != null and fid != "" else null
	var sel: int = b.selection.size() if b.sel_frame == fid else 0
	_about.text = "No canvas in front of you" if fd == null else ("About %d selected item%s on %s" % [sel, "" if sel == 1 else "s", fd.name] if sel > 0 else "About %s" % fd.name)
	for c in _chips:
		(c as Btn).disabled = ai.busy or fd == null
	_mic.on = b.speech.listening()
	_send.disabled = ai.busy
	_sync_send()
	_key_btn.text = ("Key saved (%s): change it" % ai.key_hint(p)) if ai.key(p) != "" else "Set the %s API key" % LlmApi.name_of(p)
	_key_note.text = "Or paste it on the web page: Home > Share, then AI at the top. Keys: %s" % str(LlmApi.PROVIDERS[p].keys_url)
	_refresh_thread(fid)
	_refresh_models()


func _refresh_models() -> void:
	var ai: AiController = shell.board.ai
	var p := ai.provider()
	var info: Dictionary = ai.models.get(p, {})
	var sig := "%s|%s|%s|%d|%s|%s" % [p, ai.model(p), ai.mode(p), ai.model_list(p).size(), ai.fetching.has(p), str(info.get("error", ""))]
	if sig == _sig:
		return
	_sig = sig
	UiKit.clear(_models_box)
	if ai.fetching.has(p):
		UiKit.note(_models_box, "Fetching the model list...")
	else:
		if str(info.get("error", "")) != "":
			UiKit.note(_models_box, str(info.error))
		var f := UiKit.flow(_models_box, 6)
		for m in ai.model_list(p):
			var mid := str(m.id)
			var mb := UiKit.chip(str(m.name), func(): ai.set_model(p, mid), "", 38.0)
			mb.on = mid == ai.model(p)
			f.add_child(mb)
		var again := UiKit.chip("Fetch again", func(): ai.refresh_models(p), "undo", 38.0)
		again.variant = "ghost"
		f.add_child(again)
	UiKit.clear(_modes_box)
	for md in ai.modes(p):
		var mode_id := str(md[0])
		var b := UiKit.chip(str(md[1]), func(): ai.set_mode(p, mode_id), "", 38.0)
		b.on = mode_id == ai.mode(p)
		_modes_box.add_child(b)


# ------------------------------------------------------------------------------------------------ the conversation

func _refresh_thread(fid: String) -> void:
	var ai: AiController = shell.board.ai
	var turns: Array = ai.chat.get(fid, []) if fid != "" else []
	var lay: Dictionary = ai.layer.get(fid, {})
	var waiting := ai.busy and str(ai.asking.get("frame", "")) == fid
	var err := str(ai.last.get("error", "")) if str(ai.last.get("frame", "")) == fid else ""
	var sig := "%s|%d|%s|%s|%s|%s|%s|%s" % [fid, turns.size(), waiting, err, lay.is_empty(), lay.get("visible", true), ai.key() != "", str(ai.status) if waiting else ""]
	if sig == _thread_sig:
		return
	_thread_sig = sig
	UiKit.clear(_thread)
	if turns.is_empty() and not waiting and err == "":
		_empty_state(fid)
	var last_draw := -1
	for i in turns.size():
		if str((turns[i] as Dictionary).get("draws", "")) != "" or str((turns[i] as Dictionary).get("text", "")).contains("[I proposed:"):
			last_draw = i
	for i in turns.size():
		var turn: Dictionary = turns[i]
		if str(turn.get("role", "")) == "user":
			_thread.add_child(Bubble.new(_user_text(turn), true))
		else:
			var bub := Bubble.new(_assistant_text(turn), false, str(turn.get("model", "")))
			_thread.add_child(bub)
			if i == last_draw and not lay.is_empty():
				bub.body.add_child(_suggestion_card(fid, lay))
			elif str(turn.get("draws", "")) != "":
				var gone := UiKit.label("Suggested %s (since decided)" % str(turn.draws), true, UITheme.FONT_TINY)
				bub.body.add_child(gone)
	if waiting:
		if turns.is_empty() or str((turns[turns.size() - 1] as Dictionary).get("role", "")) != "user":
			_thread.add_child(Bubble.new(str(ai.asking.get("label", "")), true))
		var think := Bubble.new("", false, ai.model_name())
		think.body.add_child(Dots.new())
		_thread.add_child(think)
	elif err != "":
		var eb := Bubble.new(err, false, "", true)
		_thread.add_child(eb)
	_scroll_to_end()


func _empty_state(fid: String) -> void:
	var ai: AiController = shell.board.ai
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_thread.add_child(box)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 40)
	box.add_child(pad)
	var big := Btn.new("ai", "")
	big.variant = "tool"
	big.accent = UITheme.AI
	big.on = true
	big.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big.custom_minimum_size = Vector2(0, 76)
	box.add_child(big)
	var h := UiKit.label("Ask about this canvas" if fid != "" else "Place a canvas to talk about", false, UITheme.FONT, 600)
	h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(h)
	var s := UiKit.label("It sees what is on the canvas (shapes, labels, arrows, text, your ink) and a picture of it, and remembers this conversation. Select items to ask about just those. Drawings it suggests wait here for your yes.", true, UITheme.FONT_SMALL)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(s)
	if ai.key() == "":
		var c := UiKit.card(box)
		var l := UiKit.label("No %s key yet. It is your own key; questions are billed to it." % LlmApi.name_of(ai.provider()), false, UITheme.FONT_SMALL)
		c.add_child(l)
		var k := UiKit.button("keyboard", "Set the API key", _set_key, 48.0)
		k.accent = UITheme.AI
		k.on = true
		c.add_child(k)
		c.add_child(UiKit.button("settings", "Choose the provider and model", func(): _settings.visible = true, 44.0, "ghost"))


func _suggestion_card(fid: String, lay: Dictionary) -> Control:
	var ai: AiController = shell.board.ai
	var card := PanelContainer.new()
	var sb := UITheme.box(Color(0, 0, 0, 0.22), 14, Color(UITheme.AI.r, UITheme.AI.g, UITheme.AI.b, 0.5), 1)
	sb.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	card.add_child(v)
	var cur := ai.current_layer()
	var l := UiKit.label("Suggestion on the canvas: %s" % (str(cur.counts) if str(cur.get("frame", "")) == fid else "ready"), false, UITheme.FONT_SMALL, 500)
	l.add_theme_color_override("font_color", UITheme.AI)
	v.add_child(l)
	var r := UiKit.hrow(v, 6)
	var ok := UiKit.chip("Accept", func(): ai.accept(fid), "check", 40.0)
	ok.accent = UITheme.AI
	ok.on = true
	r.add_child(ok)
	r.add_child(UiKit.chip("Discard", func(): ai.discard(fid), "close", 40.0))
	var shown := bool(lay.get("visible", true))
	var hide := UiKit.chip("Hide" if shown else "Show", func(): ai.set_visible(fid, not shown), "eye_off" if shown else "eye", 40.0)
	hide.variant = "ghost"
	r.add_child(hide)
	return card


static func _user_text(turn: Dictionary) -> String:
	var t := str(turn.get("label", turn.get("text", "")))
	return t.trim_prefix("Question: ")


static func _assistant_text(turn: Dictionary) -> String:
	if turn.has("say"):
		var s := str(turn.say).strip_edges()
		return s if s != "" else "Here is a suggestion."
	var t := str(turn.get("text", ""))
	var cut := t.find("\n[I proposed:")
	if cut >= 0:
		t = t.left(cut)
	return t.strip_edges() if t.strip_edges() != "" and t != "(no words)" else "Here is a suggestion."


func _scroll_to_end() -> void:
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


## One message: yours on the right in the accent colour, the assistant's on the left in violet with the model's name under it.
class Bubble extends HBoxContainer:
	var body: VBoxContainer

	func _init(text: String, mine: bool, who: String = "", error: bool = false) -> void:
		add_theme_constant_override("separation", 0)
		var col := UITheme.BAD if error else (UITheme.ACCENT if mine else UITheme.AI)
		var gap := Control.new()
		gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		gap.custom_minimum_size = Vector2(40, 0)
		if mine:
			add_child(gap)
		var col_box := VBoxContainer.new()
		col_box.add_theme_constant_override("separation", 2)
		add_child(col_box)
		var p := PanelContainer.new()
		var sb := UITheme.box(Color(col.r, col.g, col.b, 0.16 if mine else 0.1), 18, Color(col.r, col.g, col.b, 0.3), 1)
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 10
		sb.content_margin_bottom = 10
		if mine:
			sb.corner_radius_bottom_right = 6
		else:
			sb.corner_radius_bottom_left = 6
		p.add_theme_stylebox_override("panel", sb)
		col_box.add_child(p)
		body = VBoxContainer.new()
		body.add_theme_constant_override("separation", 8)
		p.add_child(body)
		if text != "":
			var l := UiKit.label(text, false, UITheme.FONT_SMALL)
			if error:
				l.add_theme_color_override("font_color", Color(1.0, 0.75, 0.8))
			var f := UITheme.font()
			var w := 0.0
			for line in text.split("\n"):
				w = maxf(w, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SMALL).x)
			l.custom_minimum_size = Vector2(minf(w + 4.0, AssistantPanel.BUBBLE_W), 0)
			body.add_child(l)
		if who != "" and not mine:
			var n := UiKit.label(who, true, UITheme.FONT_TINY)
			n.autowrap_mode = TextServer.AUTOWRAP_OFF
			col_box.add_child(n)
		if not mine:
			add_child(gap)


## The typing indicator: three dots that rise and fall in turn.
class Dots extends Control:
	var _t := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(56, 20)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		for i in 3:
			var k := 0.5 + 0.5 * sin(_t * 6.0 - i * 0.9)
			draw_circle(Vector2(10 + i * 18, size.y * 0.5 - k * 4.0), 5.0, Color(UITheme.AI.r, UITheme.AI.g, UITheme.AI.b, 0.4 + 0.6 * k))
