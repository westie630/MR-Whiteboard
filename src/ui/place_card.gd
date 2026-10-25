class_name PlaceCard
extends FloatPanel
## The placement tool for words (Board.begin_place_text): the card that stands on the dock while a text waits for its place. It shows
## the start of the text, which canvas the stylus (or hand) points at, and two ways out: put it on the canvas you are looking at, or
## cancel. Pointing and tapping with the stylus tip or a pinch puts it down exactly where the ghost is.

var _sub: Label
var _preview: Label
var _line: Label


func _init() -> void:
	super()
	id = "place"
	kind = "compose"
	pivot = Vector2(0.5, 1.0)
	max_size = Vector2(620, 420)
	add_theme_stylebox_override("panel", UITheme.glass(26, 16.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.custom_minimum_size = Vector2(520, 0)
	add_child(v)
	var head := UiKit.hrow(v, 12)
	var icon := Btn.new("pin", "")
	icon.variant = "tool"
	icon.accent = UITheme.AI
	icon.on = true
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(46, 46)
	head.add_child(icon)
	var titles := UiKit.vcol(head, 0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(UiKit.label("Place the text", false, UITheme.FONT, 600))
	_sub = UiKit.label("", true, UITheme.FONT_TINY)
	titles.add_child(_sub)
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", UITheme.box(UITheme.WELL, 16))
	v.add_child(well)
	_preview = UiKit.label("", false, UITheme.FONT_SMALL)
	_preview.custom_minimum_size = Vector2(480, 0)
	well.add_child(_preview)
	_line = UiKit.label("", true, UITheme.FONT_TINY)
	v.add_child(_line)
	var row := UiKit.hrow(v, 8)
	var here := UiKit.chip("Where I look", func(): shell.board.place_text_here(), "eye", 52.0)
	here.accent = UITheme.AI
	here.on = true
	here.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(here)
	var no := UiKit.chip("Cancel", func(): shell.board.cancel_place_text(), "close", 52.0)
	no.variant = "ghost"
	no.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(no)


func refresh() -> void:
	var b: Board = shell.board
	if b.placing_text.is_empty():
		return
	var text := str(b.placing_text.text)
	_preview.text = text if text.length() <= 160 else text.left(160).strip_edges() + "..."
	var fid := str(b.placing_text.frame)
	var fd: FrameData = b.doc.frames.get(fid) if b.doc != null and fid != "" else null
	_sub.text = "Pointing at nothing yet" if fd == null else "Pointing at %s" % fd.name
	_line.text = "Point at a canvas: the text follows. Tap with the stylus tip or pinch to put it down there; the back button cancels. Undo takes it back."
