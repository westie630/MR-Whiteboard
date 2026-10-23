class_name UiShell
extends Node
## The interface: small floating surfaces that appear where and when they are needed, instead of one panel holding everything.
##   Dock          the toolbar, always there (tap the active tool again for its options)
##   Popover       a dock button's options: brush, shapes, handwriting, add
##   ContextBar    above the selection, on the canvas: what fits what is selected
##   InkChip       beside handwriting: "convert to text?" while drawing, the other readings right after converting
##   SuggestionBar above a canvas the assistant drew a suggestion on: accept, discard, hide
##   Home          documents, canvases, rooms, sharing, settings (opened from the dock)
##   Assistant     the AI assistant (opened from the dock)
##   Compose       the typing card with its keyboard
##   SurfaceCard   finding the desk with the stylus nib (stands on the dock like the typing card)
##   Toast         short messages
## While the pen draws or a hand carries something, the surfaces fade back and the ones on the canvas step away, so the interface
## never covers the work. The shell owns no layout: the rig puts each surface on the screen (PC) or in the room (headset).

signal opened(id: String)                  # a surface was opened by the user (the headset rig places it then)

const CALM_S := 0.35                       # the surfaces come back this long after the pen and hands are done
const FADED := 0.28                        # how opaque the dock is while you draw
const SIDE_FADED := 0.4

var board: Board
var dock: Dock
var popover: Popover
var context: ContextBar
var ink_chip: InkChip
var suggestion: SuggestionBar
var home: HomePanel
var assistant: AssistantPanel
var compose: ComposePanel
var surface_card: SurfaceCard
var toast: ToastView
var panels: Array = []                     # every surface, back to front
var popover_id := ""
var canvas_size_idx := 1
var hidden := false                        # PC: Tab hides everything but the messages

var _side := {"home": false, "assistant": false}
var _dirty := true
var _calm_t := 10.0
var _entry_cb := Callable()
var _sel_sig := ""


func setup(b: Board) -> void:
	board = b
	dock = Dock.new()
	popover = Popover.new()
	context = ContextBar.new()
	ink_chip = InkChip.new()
	suggestion = SuggestionBar.new()
	home = HomePanel.new()
	assistant = AssistantPanel.new()
	compose = ComposePanel.new()
	surface_card = SurfaceCard.new()
	toast = ToastView.new()
	panels = [context, ink_chip, suggestion, dock, home, assistant, popover, compose, surface_card, toast]
	for p in panels:
		(p as FloatPanel).shell = self
	compose.entry.accepted.connect(_entry_ok)
	compose.entry.cancelled.connect(close_entry)
	compose.entry.mic_btn.pressed.connect(func(): board.speech.toggle(func(t: String): compose.entry.insert(t)))
	compose.entry.keyboard_toggled.connect(func(): App.put("vkeyboard", not bool(App.val("vkeyboard"))))
	board.changed.connect(func(): _dirty = true)
	board.toast.connect(show_toast)
	App.setting_changed.connect(func(_k): _dirty = true)
	dock.wanted = true
	update(0.0)
	for p in panels:
		(p as FloatPanel).snap_fade()


func _process(delta: float) -> void:
	update(delta)


# ------------------------------------------------------------------------------------------------ per frame

## Busy: the pen is drawing, erasing, selecting or dragging, a hand carries something, or a canvas is being placed.
func engaged() -> bool:
	if board == null:
		return false
	return board.pen_ctl.state != PenController.S.IDLE or board.hand_ctl.is_holding() or not board.grabs.is_empty() or not board.placing.is_empty()


func update(delta: float) -> void:
	if board == null:
		return
	var busy := engaged()
	_calm_t = 0.0 if busy else _calm_t + delta
	var calm := _calm_t >= CALM_S
	var fade := bool(App.val("ui_fade"))
	var st := board.pen_ctl.state
	if busy and popover_id != "" and st in [PenController.S.DRAWING, PenController.S.ERASING, PenController.S.SHAPE_DRAG, PenController.S.LASSO]:
		close_popover()                                  # drawing on a canvas closes the options
	var typing := entry_open()
	var has_doc := board.doc != null
	dock.wanted = not hidden
	dock.dim = 1.0 if (calm or not fade) else FADED
	popover.wanted = popover_id != "" and not hidden and not typing
	for id in _side:
		var p: FloatPanel = home if id == "home" else assistant
		p.wanted = bool(_side[id]) and not hidden and has_doc
		p.dim = 1.0 if (calm or not fade) else SIDE_FADED
	compose.wanted = typing
	surface_card.wanted = board.surface.finding() and not hidden and not typing
	var on_canvas := not hidden and calm and has_doc and not typing
	var sel_sig := ",".join(PackedStringArray(board.selection))
	if sel_sig != _sel_sig:
		_sel_sig = sel_sig
		context.reset()
	context.wanted = on_canvas and not board.selection.is_empty() and context.place_for(board)
	ink_chip.wanted = on_canvas and ink_chip.place_for(board)
	suggestion.wanted = on_canvas and not board.ai.busy and suggestion.place_for(board)
	toast.tick(delta)
	if typing:
		_keep_focus()
	if _dirty:
		_dirty = false
		for p in panels:
			var fp := p as FloatPanel
			if fp.wanted or fp.visible:
				fp.refresh()


## Bring every surface in step now (tests; after the rig moved things about).
func refresh_all() -> void:
	_dirty = true
	update(0.0)


# ------------------------------------------------------------------------------------------------ the dock's buttons

## A tool button: picks the tool; on the tool that is already active it opens (or closes) that tool's options.
func tool_pressed(tid: String) -> void:
	var opt: String = Dock.OPTIONS.get(tid, "")
	if str(App.val("tool")) == tid:
		if opt != "":
			toggle_popover(opt)
		return
	App.put("tool", tid)
	if tid != "select":
		board.clear_selection()
	if tid == "shape":
		open_popover("shapes")                          # a shape has to be picked first
	elif popover_id != "" and popover_id != "add":
		if opt != "":
			open_popover(opt)
		else:
			close_popover()
	_dirty = true


func pick_stencil(sid: String) -> void:
	board.stencil = sid
	App.put("tool", "shape")
	board.clear_selection()
	close_popover()
	show_toast("%s: drag on a canvas to place it" % Shapes.name_of(sid))


## A colour from the palette: the pen's colour, and the selection's when something is selected.
func set_color(c: Color, to_selection: bool = true) -> void:
	App.put("color", c)
	if to_selection and not board.selection.is_empty():
		board.recolor_selection(c)


func open_popover(id: String) -> void:
	popover_id = id
	popover.open(id)
	popover.wanted = true
	opened.emit("popover")
	_dirty = true


func close_popover() -> void:
	if popover_id == "":
		return
	popover_id = ""
	popover.wanted = false
	_dirty = true


func toggle_popover(id: String) -> void:
	if popover_id == id:
		close_popover()
	else:
		open_popover(id)


func is_side_open(id: String) -> bool:
	return bool(_side.get(id, false))


func open_side(id: String) -> void:
	_side[id] = true
	close_popover()
	opened.emit(id)
	_dirty = true


func close_side(id: String) -> void:
	_side[id] = false
	_dirty = true


func toggle_side(id: String) -> void:
	if is_side_open(id):
		close_side(id)
	else:
		open_side(id)


## Esc: the topmost thing that is open closes (the typing box, a popover, the side panels), then the selection is let go.
func back() -> bool:
	if entry_open():
		close_entry()
		return true
	if board.surface.finding():
		board.surface.cancel()
		return true
	if popover_id != "":
		close_popover()
		return true
	if is_side_open("assistant") or is_side_open("home"):
		close_side("assistant")
		close_side("home")
		return true
	if not board.selection.is_empty():
		board.clear_selection()
		return true
	return false


func show_toast(text: String) -> void:
	if toast != null:
		toast.show_text(text)


## The Home panel on one of its tabs (also used by --tab on the command line).
func show_home(tab: String) -> void:
	home.select_tab(tab)
	open_side("home")


# ------------------------------------------------------------------------------------------------ typing

## Open the box for the thing that is selected: a text item is edited, a closed shape gets a label, otherwise new text for the
## canvas in front of you. False when there is nowhere to put new text.
func open_text_entry() -> bool:
	var txt := board.texts.selected_text()
	if txt != null:
		var id := txt.id
		open_entry("Edit text", txt.text, true, func(t: String): board.texts.edit(id, t))
		return true
	var shp := board.texts.selected_shape()
	if shp != null:
		var sid := shp.id
		open_entry("Label for this shape", shp.label, true, func(t: String): board.texts.set_label(sid, t), true)
		return true
	if board.texts.spot().is_empty():
		board.toast.emit("Place a canvas first (Add on the toolbar), then type your text.")
		return false
	open_entry("New text on the canvas", "", true, func(t: String): board.texts.place(t))
	return true


func ask_name(title: String, current: String, cb: Callable) -> void:
	open_entry(title, current, false, cb)


func ask_secret(title: String, cb: Callable) -> void:
	open_entry(title, "", false, cb, false, true)


func open_entry(title: String, current: String, multiline: bool, cb: Callable, empty_ok: bool = false, secret: bool = false) -> void:
	_entry_cb = cb
	close_popover()
	compose.entry.open(title, current, multiline, board.ink.provider().recognize, str(App.val("ink_language")), empty_ok, secret)
	compose.wanted = true
	compose.refresh()
	opened.emit("compose")
	_dirty = true


func close_entry() -> void:
	compose.entry.close()
	compose.wanted = false
	_entry_cb = Callable()
	_dirty = true


func _entry_ok(text: String) -> void:
	var cb := _entry_cb
	close_entry()
	if cb.is_valid():
		cb.call(text)


func entry_open() -> bool:
	return compose != null and compose.entry.is_open()


## True while the typing box is open (or, on the PC, the assistant's message box has the keyboard): the rig then passes keys to it
## instead of using them as shortcuts.
func is_typing() -> bool:
	return entry_open() or (assistant != null and assistant.typing())


## The viewport the typing box is in (the headset passes a Bluetooth keyboard's keys there).
func typing_viewport() -> Viewport:
	return compose.get_viewport() if compose.is_inside_tree() else null


func _keep_focus() -> void:
	if not compose.is_inside_tree():
		return
	var f := compose.entry.field()
	if f.is_visible_in_tree() and compose.get_viewport().gui_get_focus_owner() == null:
		f.grab_focus()
