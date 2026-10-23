class_name SuggestionBar
extends FloatPanel
## The assistant's suggestion, decided where it is: pinned above the canvas it is drawn on, with what it would do and Accept,
## Discard and Hide / Show.

var _label: Label
var _show: Btn


func _init() -> void:
	super()
	id = "suggestion"
	kind = "canvas"
	pivot = Vector2(0.5, 0.0)                  # hangs just inside the canvas's top edge
	max_size = Vector2(820, 110)
	var sb := UITheme.glass(30, 6.0)
	sb.border_color = Color(UITheme.AI.r, UITheme.AI.g, UITheme.AI.b, 0.55)
	add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	var spark := Btn.new("ai", "")
	spark.variant = "tool"
	spark.accent = UITheme.AI
	spark.on = true
	spark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spark.custom_minimum_size = Vector2(46, 46)
	row.add_child(spark)
	_label = UiKit.label("", false, UITheme.FONT_SMALL, 500)
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2(150, 0)
	_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_label)
	var ok := UiKit.chip("Accept", func(): shell.board.ai.accept(), "check", 46.0)
	ok.accent = UITheme.AI
	ok.on = true
	row.add_child(ok)
	row.add_child(UiKit.chip("Discard", func(): shell.board.ai.discard(), "close", 46.0))
	_show = UiKit.tool("eye", "Hide", func():
		var cur: Dictionary = shell.board.ai.current_layer()
		if not cur.is_empty():
			shell.board.ai.set_visible(str(cur.frame), not bool(cur.visible)), 46.0)
	row.add_child(_show)


func place_for(board: Board) -> bool:
	var cur := board.ai.current_layer()
	if cur.is_empty() or not board.frame_nodes.has(str(cur.frame)):
		return false
	var fn: FrameNode = board.frame_nodes[str(cur.frame)]
	if not fn.visible:
		return false
	var r := fn.bounds()
	anchor = {"frame": str(cur.frame), "pos": Vector2(r.get_center().x, r.end.y - 0.03 / fn.data.scale), "lift": 0.012}
	return true


func refresh() -> void:
	var cur: Dictionary = shell.board.ai.current_layer()
	if cur.is_empty():
		return
	_label.text = "Suggestion: %s" % str(cur.counts)
	_show.icon = "eye_off" if bool(cur.visible) else "eye"
	_show.hint = "Hide it" if bool(cur.visible) else "Show it"
