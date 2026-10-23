class_name InkChip
extends FloatPanel
## Handwriting, predicted. Pinned beside the ink on the canvas:
##   "suggest"   strokes drawn with the pen look like words: one tap turns them into text (or a tap on x leaves them as they are)
##   "readings"  handwriting was just turned into text: the recogniser's other readings are right there, one tap fixes a misread,
##               and "Handwriting" brings the ink back. It goes away by itself after a few seconds.

var mode := ""
var _row: HBoxContainer
var _sig := ""


func _init() -> void:
	super()
	id = "ink"
	kind = "canvas"
	pivot = Vector2(0.0, 0.5)
	max_size = Vector2(760, 110)
	add_theme_stylebox_override("panel", UITheme.glass(28, 6.0))
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 4)
	add_child(_row)


## Decide what to show from the ink controller's state. False when there is nothing to offer.
func place_for(board: Board) -> bool:
	var ink := board.ink
	if not ink.suggestion.is_empty():
		var s: Dictionary = ink.suggestion
		var fn: FrameNode = board.frame_nodes.get(s.frame)
		if fn == null:
			return false
		var r: Rect2 = s.rect
		mode = "suggest"
		pivot = Vector2(0.0, 0.5)
		anchor = {"frame": s.frame, "pos": Vector2(r.end.x + 0.025 / fn.data.scale, r.get_center().y), "lift": 0.012}
		return true
	var conv := ink.recent_text()
	if conv != null and (not conv.alternatives.is_empty() or not conv.ink.is_empty()) and board.frame_nodes.has(conv.frame):
		var fn2: FrameNode = board.frame_nodes[conv.frame]
		var r2 := conv.bounds()
		mode = "readings"
		pivot = Vector2(0.5, 0.0)
		anchor = {"frame": conv.frame, "pos": Vector2(r2.get_center().x, r2.position.y - 0.02 / fn2.data.scale), "lift": 0.012, "item": conv.id}
		return true
	mode = ""
	return false


func refresh() -> void:
	var b: Board = shell.board
	var sig := mode
	var conv: Item = null
	if mode == "readings":
		conv = b.doc.items.get(str(anchor.get("item", ""))) if b.doc != null else null
		if conv != null:
			sig += "|%s|%s" % [conv.id, ",".join(conv.alternatives)]
	elif mode == "suggest":
		sig += "|" + ",".join(PackedStringArray(b.ink.suggestion.get("ids", [])))
	if sig == _sig:
		return
	_sig = sig
	UiKit.clear(_row)
	match mode:
		"suggest":
			var go := UiKit.chip("Convert to text", func(): b.ink.accept_suggestion(), "aa", 46.0)
			go.on = true
			_row.add_child(go)
			var no := UiKit.tool("close", "Keep as drawing", func(): b.ink.dismiss_suggestion(), 46.0)
			_row.add_child(no)
		"readings":
			if conv == null:
				return
			var id := conv.id
			var lbl := UiKit.label("Or:", true, UITheme.FONT_SMALL)
			lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			lbl.custom_minimum_size = Vector2(36, 0)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_row.add_child(lbl)
			for reading in conv.alternatives.slice(0, 3):
				var r: String = reading
				_row.add_child(UiKit.chip(r, func(): b.ink.choose_alternative(id, r), "", 44.0))
			if not conv.ink.is_empty():
				var back := UiKit.chip("Handwriting", func(): b.ink.revert_to_ink(id), "undo", 44.0)
				back.variant = "ghost"
				_row.add_child(back)
			_row.add_child(UiKit.tool("close", "It is right", func(): b.ink.clear_recent(), 44.0))
