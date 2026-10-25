class_name Dock
extends FloatPanel
## The toolbar: the one surface that is always there. Tools on the left (tap the active tool again for its options), the current
## brush as a chip, undo and redo, then Add (text, dictation, a canvas), the assistant and Home (documents, rooms, settings), and the
## device's battery when it has one.
## Icons only; each says what it is when hovered.

const TOOLS := [["draw", "draw", "Pen", "1"], ["write", "write", "Write: handwriting to text", "3"], ["shape", "shapes", "Shapes", "2"],
	["select", "select", "Select", "4"], ["erase", "erase", "Erase", "5"]]
const OPTIONS := {"draw": "brush", "write": "write", "shape": "shapes"}

var tool_btns := {}                        # tool id -> Btn
var brush_chip: BrushChip
var undo_btn: Btn
var redo_btn: Btn
var add_btn: Btn
var ai_btn: Btn
var home_btn: Btn
var session_btn: Btn
var grip: Grip
var battery: BatteryGauge


func _init() -> void:
	super()
	id = "dock"
	kind = "dock"
	movable = true
	pivot = Vector2(0.5, 1.0)
	max_size = Vector2(1010, 140)              # room above the bar for the tooltips
	ppm = 1650.0
	add_theme_stylebox_override("panel", _pill())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(row)
	grip = Grip.new()
	row.add_child(grip)
	for t in TOOLS:
		var tid: String = t[0]
		var shortcut := "" if App.xr_active else "   %s" % t[3]
		var b := UiKit.tool(t[1], str(t[2]) + shortcut, func(): shell.tool_pressed(tid))
		b.marker = OPTIONS.has(tid)
		row.add_child(b)
		tool_btns[tid] = b
	UiKit.divider(row)
	brush_chip = BrushChip.new()
	brush_chip.hint = "Colour and brush"
	brush_chip.pressed.connect(func(): shell.toggle_popover("brush"))
	row.add_child(brush_chip)
	UiKit.divider(row)
	undo_btn = UiKit.tool("undo", "Undo", func(): shell.board.undo())
	row.add_child(undo_btn)
	redo_btn = UiKit.tool("redo", "Redo", func(): shell.board.redo())
	row.add_child(redo_btn)
	UiKit.divider(row)
	add_btn = UiKit.tool("plus", "Add: text, dictation, canvas", func(): shell.toggle_popover("add"))
	row.add_child(add_btn)
	ai_btn = UiKit.tool("ai", "Assistant", func(): shell.toggle_side("assistant"))
	ai_btn.accent = UITheme.AI
	row.add_child(ai_btn)
	home_btn = UiKit.tool("menu", "Home: documents, rooms, settings, guide", func(): shell.toggle_side("home"))
	row.add_child(home_btn)
	session_btn = UiKit.tool("session", "The session", func(): shell.show_home("session"))
	session_btn.visible = false
	row.add_child(session_btn)
	var bat_div := UiKit.divider(row)
	battery = BatteryGauge.new()
	row.add_child(battery)
	bat_div.visible = battery.visible
	battery.visibility_changed.connect(func(): bat_div.visible = battery.visible)


func _pill() -> StyleBoxFlat:
	var sb := UITheme.glass(40, 8.0)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	return sb


func refresh() -> void:
	var b: Board = shell.board
	var tool := str(App.val("tool"))
	for tid in tool_btns:
		(tool_btns[tid] as Btn).on = tid == tool
	brush_chip.on = shell.popover_id == "brush"
	brush_chip.queue_redraw()
	undo_btn.disabled = b.history == null or not b.history.can_undo()
	redo_btn.disabled = b.history == null or not b.history.can_redo()
	add_btn.on = shell.popover_id == "add"
	add_btn.badge = UITheme.BAD if b.speech.listening() else Color(0, 0, 0, 0)
	ai_btn.on = shell.is_side_open("assistant")
	ai_btn.busy = b.ai.busy
	ai_btn.badge = UITheme.AI if not b.ai.current_layer().is_empty() else Color(0, 0, 0, 0)
	home_btn.on = shell.is_side_open("home")
	var cs := b.session
	session_btn.visible = cs.is_active()
	session_btn.on = shell.is_side_open("home") and shell.home.tab == "session"
	session_btn.accent = UITheme.GOOD
	session_btn.hint = ("Your session: %d here" % maxi(cs.peers.size(), 1)) if cs.phase == "live" else cs.phase_text()
	session_btn.badge = UITheme.WARN if cs.is_client() and cs.phase != "live" else (UITheme.GOOD if cs.phase == "live" else Color(0, 0, 0, 0))
	grip.visible = not App.xr_active


## Make a ring breathe around one of the dock's buttons (the guide points at them): a tool id (draw, write, shape, select, erase),
## "brush", "undo", "redo", "add", "ai" or "home".
func pulse(what: String) -> void:
	var b: Btn = tool_btns.get(what)
	match what:
		"brush":
			b = brush_chip
		"undo":
			b = undo_btn
		"redo":
			b = redo_btn
		"add":
			b = add_btn
		"ai":
			b = ai_btn
		"home":
			b = home_btn
	if b != null:
		b.pulse()


## The x (in dock pixels) of a button's middle: where its popover's arrow points.
func button_x(popover: String) -> float:
	var c: Control = brush_chip
	match popover:
		"shapes":
			c = tool_btns["shape"]
		"write":
			c = tool_btns["write"]
		"add":
			c = add_btn
		"brush":
			c = brush_chip
	return c.get_global_rect().get_center().x - get_global_rect().position.x


## The current brush: a disc in the pen colour with a dot as wide as the line, and a ring when its options are open.
class BrushChip extends Btn:
	func _init() -> void:
		super("", "")
		variant = "tool"
		custom_minimum_size = Vector2(UITheme.TOOL, UITheme.TOOL)

	func _draw() -> void:
		var c := size * 0.5
		var rad := minf(size.x, size.y) * 0.3
		var col: Color = App.val("color")
		if is_hovered():
			draw_circle(c, rad + 9.0, Color(1, 1, 1, 0.07))
		if on:
			draw_arc(c, rad + 6.0, 0.0, TAU, 48, UITheme.ACCENT, 2.5, true)
		draw_circle(c, rad, col)
		draw_arc(c, rad, 0.0, TAU, 40, Color(1, 1, 1, 0.35 if col.get_luminance() < 0.25 else 0.15), 1.5, true)
		var w_mm := float(App.val("width")) * 1000.0
		var dot := clampf(1.5 + w_mm * 0.45, 2.0, rad * 0.8)
		var ink := Color(0, 0, 0, 0.55) if col.get_luminance() > 0.55 else Color(1, 1, 1, 0.8)
		draw_circle(c, dot, ink)
		super._draw_pulse()
		super._draw_hint_if_needed()


## A handle for dragging a surface around the PC window (in the headset the handle under it moves it in the room).
class Grip extends Control:
	signal dragged(relative: Vector2)

	var _down := false
	var _hover := false

	func _init() -> void:
		custom_minimum_size = Vector2(22, UITheme.TOOL)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_MOVE
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; queue_redraw())

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_down = (e as InputEventMouseButton).pressed
			accept_event()
		elif e is InputEventMouseMotion and _down:
			dragged.emit((e as InputEventMouseMotion).relative * get_global_transform().get_scale())
			accept_event()

	func _draw() -> void:
		var a := 0.5 if _hover or _down else 0.25
		for i in 3:
			for j in 2:
				draw_circle(Vector2(size.x * 0.5 + (j - 0.5) * 7.0, size.y * 0.5 + (i - 1) * 7.0), 1.8, Color(1, 1, 1, a))
