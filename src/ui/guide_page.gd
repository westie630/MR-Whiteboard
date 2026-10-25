class_name GuidePage
extends RefCounted
## The user guide, inside Home (the "?" in its header; the first start opens it): a list of topics, and for each one a few steps in plain
## words, a small table where it helps (the stylus's buttons, the hand gestures, the colours of the ring) and "Try it" buttons that
## do the thing for real: pick the tool, open its options, start placing a canvas, and make a ring breathe around the real button on the
## dock, so you can see where it is without reading about it. It stays beside the dock while you try, so you can read, do and read on.
##
## A topic is {id, icon, title, sum, blocks}. A block is one of
##   ["text", string]                         a paragraph
##   ["steps", [string, ...]]                 numbered steps
##   ["pairs", [[left, right, colour?], ...]] a two-column table (a colour puts a dot before the left cell)
##   ["try", [[icon, label, action], ...]]    buttons, shown first; an action is "what:argument", see do()

const TOPICS := [
	{"id": "start", "icon": "help", "title": "The basics", "sum": "Pressing buttons, the toolbar, hands and stylus", "blocks": [
		["text", "You work with two things: the stylus draws, your hands arrange. The toolbar (the dock) floats low in front of you like a keyboard."],
		["steps", [
			"Press a button by touching it with the stylus tip or a fingertip. Or point at it from a distance (a ring shows where, and a line runs to it from the stylus) and pinch; with the stylus, press its front button.",
			"Lost the toolbar? Turn a hand palm up for a moment, or hold the stylus front button with nothing to grab. It comes back in front of you.",
			"Every panel has a bar under it. Grab the bar (pinch, or the stylus front button) and move the panel where you like. It stays there, even after you take the headset off or restart the app.",
			"Hover over an icon for a moment and it tells you its name.",
		]],
		["text", "The stylus"],
		["pairs", [
			["Tip or middle button", "Draw, write, erase, select: whatever tool is on. Press harder for a heavier line."],
			["Front button", "Grab, like a pinch: select and drag a drawing, carry a canvas by the bar under it, resize it at a corner."],
			["Back button", "Undo, at once. Hold the front button as well to redo."],
			["Front button, nothing to grab", "Hold it for a moment and the toolbar comes to you."],
		]],
		["text", "Your hands"],
		["pairs", [
			["Point and pinch", "A ring shows where you point. Pinch to press a button or to grab."],
			["Touch", "Close to a canvas or a panel, the fingertip or the stylus tip itself picks what it touches."],
			["Palm up", "Open a hand palm up for a moment: the toolbar comes to you."],
			["Two hands", "Pinch the same canvas with both hands to turn it and make it bigger or smaller."],
		]],
		["text", "The ring where you point"],
		["pairs", [
			["Teal", "On a panel or a button.", Color(0.25, 0.88, 0.78)],
			["Light blue", "On a drawing: a grab selects it.", Color(0.45, 0.95, 1.0)],
			["Amber", "On the bar under a canvas or on a corner: a grab carries or resizes the canvas.", Color(1.0, 0.72, 0.2)],
			["White", "On empty canvas.", Color(1, 1, 1)],
			["Green", "Pressed.", Color(0.4, 1.0, 0.7)],
		]],
		["try", [["menu", "Light up the toolbar", "all:"]]],
	]},
	{"id": "draw", "icon": "draw", "title": "Draw", "sum": "The pen, brushes, colours, snapping to shapes", "blocks": [
		["steps", [
			"Pick the Pen on the toolbar. Press the stylus tip (or its middle button) on a canvas and draw. Press harder for a heavier line.",
			"You draw on canvases only, within a hand's width of one. No canvas yet? Add (+) on the toolbar, then On a wall.",
			"Tap the Pen again, or the coloured dot beside the tools, for the brush: eight brushes, 14 colours or any colour, and the width.",
			"Hold the stylus still for a moment at the end of a stroke and it snaps to a clean line, arrow, box, circle, triangle and so on. A ring fills while it decides.",
			"A mistake? Press the stylus back button, or Undo on the toolbar.",
		]],
		["try", [["draw", "Pick the Pen", "tool:draw"], ["palette", "Open the brush", "pop:brush"], ["undo", "Where is Undo?", "pulse:undo"]]],
	]},
	{"id": "shapes", "icon": "shapes", "title": "Shapes and diagrams", "sum": "Boxes, arrows and connectors that stay attached", "blocks": [
		["steps", [
			"Tap Shapes and pick a stencil: process, decision, start and end, database, document, arrows, elbow connectors and more.",
			"Drag on a canvas to size it, or just tap for the default size. Hold the front button while you drag for a perfect square or circle.",
			"Arrows and connectors stick to the shapes at their ends and follow them when you move the shapes.",
			"In the same panel: Fill with colour, and Connectors stick to shapes.",
			"Quicker: draw a rough box with the Pen and hold still. It snaps into a real shape you can select, resize and recolour.",
		]],
		["try", [["shapes", "Open the shapes", "pop:shapes"]]],
	]},
	{"id": "write", "icon": "write", "title": "Handwriting to text", "sum": "Write with the stylus, get typed text", "blocks": [
		["steps", [
			"Choose Write. Write words with the stylus and pause. After two seconds they turn into typed text, right where you wrote.",
			"Lines, underlines, boxes round the words and arrows that you draw among them stay drawings.",
			"Write inside a box and the text becomes the box's label.",
			"Misread? Select the text: the bar above it offers the other readings. You can also retype it, or go back to your handwriting.",
			"With the plain Pen, words are noticed too: a small chip beside them offers Convert to text.",
			"Reading needs internet. Writing a little larger and slower reads best. Text style (H1 to Small) and language: tap Write again.",
		]],
		["try", [["write", "Pick Write", "tool:write"], ["text", "Open its options", "pop:write"]]],
	]},
	{"id": "type", "icon": "keyboard", "title": "Type and dictate", "sum": "Text from a keyboard or your voice", "blocks": [
		["steps", [
			"Add (+), then Type text. A box with a keyboard opens: type, then OK. The text lands on the canvas in front of you, selected, so you can move it.",
			"To change text, select it and open Type again (or tap Edit in the bar above it). With a box selected, what you type becomes its label.",
			"Dictate (the microphone right of the Pen): its card stays open. Tap Dictate, speak, pause: the words follow your stylus or hand over the canvases. Tap with the stylus tip or pinch to put them down there; Where I look uses the canvas in front of you, Cancel throws them away. Tap the microphone button again to close the card.",
			"Dictation needs a free Wit.ai token: Home, Settings, Speech to text.",
			"A Bluetooth keyboard works too: pair it, then start typing.",
		]],
		["try", [["keyboard", "Type some text", "type:"], ["mic", "Open Dictate", "pop:dictate"], ["plus", "Where is Add?", "pulse:add"]]],
	]},
	{"id": "select", "icon": "select", "title": "Select, move, resize", "sum": "Pinch a drawing to pick it up", "blocks": [
		["steps", [
			"Pinch a drawing (or press the stylus front button on it) to select it, and drag it where you want it. Hands do this with any tool.",
			"Drag the handles of the selection box: the corners resize it and the one on top turns it.",
			"A bar appears above the selection with what fits it: colour, text style, to text, label, fill, duplicate, to the front or back.",
			"Three round buttons beside the box: undo, redo and delete. A delete can be undone.",
			"With the Select tool, draw a loop round several things to pick them all. Tap empty canvas to let go.",
		]],
		["try", [["select", "Pick Select", "tool:select"]]],
	]},
	{"id": "erase", "icon": "erase", "title": "Erase and undo", "sum": "Sweep to remove, step back anytime", "blocks": [
		["steps", [
			"Pick Erase and sweep the stylus tip over what you want gone. One sweep is one undo step.",
			"Undo: the stylus back button, or Undo on the toolbar. Redo: Redo on the toolbar, or hold the front button and press the back one.",
			"There are 200 steps of undo. Deleting a canvas can be undone as well.",
		]],
		["try", [["erase", "Pick Erase", "tool:erase"], ["undo", "Where is Undo?", "pulse:undo"]]],
	]},
	{"id": "canvas", "icon": "canvas", "title": "Canvases", "sum": "Put them on walls and tables, carry and resize", "blocks": [
		["steps", [
			"Add (+), then On a wall or On a table. A ghost of the canvas snaps to the walls and tables your headset scanned. Press the stylus tip, or pinch, to put it down. The back button cancels.",
			"Pick Small, Medium or Large in the same panel. A canvas grows when you draw past its edge, so it never runs out.",
			"Carry a canvas by the bar under it. Resize it by a corner. Two hands, or a hand and the stylus front button, turn and scale it.",
			"Home, Canvases lists them: rename, lock, clear, delete, grid and backing. Bring to me fetches one that is far away.",
			"Canvases are fixed in the room by spatial anchors: after a restart, or with the headset taken off and put back on, they are where you left them, at the size you left them. Home, Rooms keeps them apart by room.",
		]],
		["try", [["canvas", "Put one on a wall", "place:wall"], ["canvas", "List my canvases", "tab:canvas"], ["room", "Rooms", "tab:rooms"]]],
	]},
	{"id": "desk", "icon": "desk", "title": "A canvas on your desk", "sum": "Find the surface with the stylus tip", "blocks": [
		["steps", [
			"Add (+), then On my desk. A card appears.",
			"Press the stylus tip on your desk in several places, spread out, or rub it across. The tip feels the surface, and every press is a point of it.",
			"When the card says it is ready, tap Done. The canvas lies on the desk, and can only slide, turn and grow along it.",
			"It works on a wall too. The desk button in Home, Canvases lets a canvas go again; Free it and stand it upright (under the canvas's settings) lets it go and turns it vertical, facing you.",
		]],
		["try", [["desk", "Find my desk", "desk:"]]],
	]},
	{"id": "ai", "icon": "ai", "title": "The assistant", "sum": "Ask about a canvas, get a suggestion drawn on it", "blocks": [
		["steps", [
			"Once: open the assistant (the spark on the toolbar), tap the model name at its top, then Set the API key for Claude, OpenAI or MiniMax. You can also paste the key on the Keys page of the Share web page, together with the Wit.ai token for speech to text.",
			"It looks at the canvas in front of you, or at what is selected. Tap Opinion, Improve it, Continue, Tidy up, Explain or Find mistakes, or write or say your own question (the microphone next to the box: the answer stays in the conversation, never on the canvas). Under an answer, Place on canvas puts its words on a canvas of your choice.",
			"A drawing comes back as a violet suggestion over the canvas. Accept it (one undo step), Discard it, or Hide it, from its card or from the bar at the top of the canvas.",
			"Nothing leaves the headset until you ask. Each question sends that one canvas to the provider you chose.",
		]],
		["try", [["ai", "Open the assistant", "side:assistant"]]],
	]},
	{"id": "docs", "icon": "doc", "title": "Documents and sharing", "sum": "Saving, exporting, the web page for your PC", "blocks": [
		["steps", [
			"Everything saves by itself. Home, Docs: New, Duplicate, Save, and the list of your documents. Tap the name at the top of Home to rename it.",
			"Export gives SVG (one file per canvas, for Inkscape, Illustrator or Figma), a 3D .glb of the ink, or the .mrw document.",
			"Home, Share: switch on the web page, open its address on a PC on the same Wi-Fi and type the code. There you view, download and delete canvases, add SVG files, and follow a live view, even on a projector.",
		]],
		["try", [["doc", "Documents", "tab:docs"], ["wifi", "Share with a PC", "tab:share"]]],
	]},
	{"id": "pdf", "icon": "pdf", "title": "Read a PDF", "sum": "Upload one from your PC, turn the pages, draw on them", "blocks": [
		["steps", [
			"On a PC on the same Wi-Fi: Home, Share, switch on the web page, open its address and type the code. Drop a PDF on the page: the headset keeps it and puts it in front of you.",
			"A PDF the headset has already: Add (+), PDF, then tap it. Or Home, Docs, PDF documents.",
			"Turn the pages with the bar under the page: the arrows, or slide over all of them. With a keyboard: Page Up and Page Down, Home and End.",
			"It is a canvas like any other: carry it by the bar under it, resize it at a corner, or use both hands. The text and the drawings in it are vectors, so they stay sharp however near you come.",
			"Draw on it with the stylus. A drawing belongs to the page it was drawn on and is there when you come back to that page.",
			"In a session every headset is given the PDF by the owner, once. The owner's page turns are everybody's. A guest who may not move canvases looks at other pages for themselves; a button on the bar takes them back to the owner's page.",
			"A Quest 2 draws a lighter page than a Quest 3 and takes smaller files (48 MB, against 64 MB). If it cannot, the page says why.",
		]],
		["try", [["pdf", "My PDFs", "tab:docs"], ["wifi", "Share with a PC", "tab:share"]]],
	]},
	{"id": "session", "icon": "session", "title": "Running a session", "sum": "One owner, many guests, the same canvases", "blocks": [
		["steps", [
			"Owner: Home, Session, Start a session. Tell the guests the four-digit code.",
			"Guests: Home, Session, pick the session from the list (or Join by address) and type the code.",
			"Everybody sees and edits the same canvases. The owner decides whether guests may draw, and whether they may move canvases (not at first).",
			"Guests choose where they are. In the owner's room: touch the same two real places as the owner, in the same order, with the stylus tip or a pinch (the owner touches them too). Then every canvas stands on the same real spot for all of you, and nothing shows until you have.",
			"Somewhere else: the board is put in front of you, wherever you are. Everything on it, and everyone's pointer, is the same; only where it stands in the room is yours.",
			"Only one stylus? The others point and arrange, and can draw with their fingers: Home, Settings, Draw with a pinch.",
		]],
		["try", [["session", "Open Session", "tab:session"]]],
	]},
	{"id": "comfort", "icon": "settings", "title": "Make it comfortable", "sum": "Size, hand, feedback, snapping", "blocks": [
		["steps", [
			"Home, Settings, Display: Interface size makes every panel bigger or smaller. Fade the interface while drawing keeps panels out of the way.",
			"Pen and hands: choose the hand that holds the stylus, switch the clicks and stylus pulses on or off, and set how long you hold still to snap a shape.",
			"Canvas defaults: grid lines or dots, and the backing (clear, glass, dark or white), for new canvases. Each canvas can differ in Home, Canvases.",
			"On-screen keyboard or a pad to write on: Settings, Display.",
		]],
		["try", [["settings", "Open Settings", "tab:settings"]]],
	]},
	{"id": "pc", "icon": "keyboard", "title": "On the PC", "pc": true, "sum": "Mouse, keyboard and shortcuts", "blocks": [
		["pairs", [
			["Left mouse", "The stylus tip: draws on the canvas under the pointer."],
			["Shift + left mouse", "The stylus front button: grab."],
			["Middle mouse", "A pinch: carry a canvas. The wheel scales it, Q and E turn it."],
			["Right mouse, WASD", "Look around, walk."],
			["1 to 5, B", "Tools, the brush."],
			["T, C, F", "Type, place a canvas, find the desk."],
			["Ctrl+Z, Ctrl+Y", "Undo, redo."],
			["Tab, Esc", "Hide the interface, close the top panel."],
		]],
	]},
]

var _home: HomePanel
var _list: VBoxContainer
var _view: VBoxContainer
var _open := ""


func build(p: VBoxContainer, home: HomePanel) -> void:
	_home = home
	_list = UiKit.vcol(p, 10)
	_view = UiKit.vcol(p, 12)
	UiKit.note(_list, "Pick a topic. It shows the steps, and buttons that do the thing for real or light up where its button is.")
	for t in topics():
		var tid: String = t.id
		var b := TopicBtn.new(str(t.icon), str(t.title), str(t.sum))
		b.pressed.connect(func(): show_topic(tid))
		_list.add_child(b)
	show_topic("")


## The topics that apply here (the PC's keys are no use in the headset).
static func topics() -> Array:
	return TOPICS.filter(func(t): return not bool(t.get("pc", false)) or not App.xr_active)


func open_topic() -> String:
	return _open


## A topic (or, with "", the list).
func show_topic(id: String) -> void:
	_open = id
	_list.visible = id == ""
	_view.visible = id != ""
	if id == "":
		_scroll_top()
		return
	UiKit.clear(_view)
	var all := topics()
	var at := -1
	for i in all.size():
		if all[i].id == id:
			at = i
	if at < 0:
		_open = ""
		_list.visible = true
		_view.visible = false
		return
	var t: Dictionary = all[at]
	var top := UiKit.hrow(_view, 8)
	var back := UiKit.chip("All topics", func(): show_topic(""), "left", 40.0)
	top.add_child(back)
	var of := UiKit.label("%d of %d" % [at + 1, all.size()], true, UITheme.FONT_SMALL)
	of.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top.add_child(of)
	var head := UiKit.hrow(_view, 12)
	var ic := Btn.new(str(t.icon), "")
	ic.variant = "tool"
	ic.on = true
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ic.custom_minimum_size = Vector2(52, 52)
	head.add_child(ic)
	var title := UiKit.label(str(t.title), false, UITheme.FONT_BIG, 600)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(title)
	for blk in t.blocks:                           # the buttons first: they are why the guide stays open beside the dock
		if blk[0] == "try":
			_try(_view, blk[1])
	for blk in t.blocks:
		match str(blk[0]):
			"text":
				_text(_view, str(blk[1]))
			"steps":
				_steps(_view, blk[1])
			"pairs":
				_pairs(_view, blk[1])
	var nav := UiKit.hrow(_view, 8)
	if at > 0:
		var prev: String = all[at - 1].id
		nav.add_child(UiKit.button("left", "Previous", func(): show_topic(prev), 52.0, "ghost"))
	if at < all.size() - 1:
		var next: String = all[at + 1].id
		nav.add_child(UiKit.button("right", "Next: %s" % all[at + 1].title, func(): show_topic(next), 52.0))
	else:
		nav.add_child(UiKit.button("check", "Done", func(): show_topic(""), 52.0))
	_scroll_top()


func _scroll_top() -> void:
	if _home != null:
		_home.scroll_to_top()


# ------------------------------------------------------------------------------------------------ blocks

func _text(p: Control, s: String) -> void:
	var l := UiKit.label(s, false, UITheme.FONT_SMALL, 400)
	# a short line on its own is a small heading for the table that follows
	if s.length() < 40:
		l = UiKit.label(s.to_upper(), true, UITheme.FONT_TINY, 600)
		l.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	p.add_child(l)


func _steps(p: Control, steps: Array) -> void:
	var c := UiKit.card(p, 14.0)
	c.add_theme_constant_override("separation", 14)
	for i in steps.size():
		var row := UiKit.hrow(c, 12)
		var n := UiKit.label(str(i + 1), false, UITheme.FONT_SMALL, 700)
		n.add_theme_color_override("font_color", UITheme.ACCENT)
		n.autowrap_mode = TextServer.AUTOWRAP_OFF
		n.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		n.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		n.custom_minimum_size = Vector2(18, 0)
		row.add_child(n)
		row.add_child(UiKit.label(str(steps[i]), false, UITheme.FONT_SMALL))


func _pairs(p: Control, rows: Array) -> void:
	var c := UiKit.card(p, 14.0)
	c.add_theme_constant_override("separation", 12)
	for r in rows:
		var row := UiKit.hrow(c, 12)
		var left := UiKit.hrow(row, 8)
		left.custom_minimum_size = Vector2(150, 0)
		left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		left.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		if r.size() > 2:
			var d := Dot.new(r[2])
			d.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			left.add_child(d)
		var name_l := UiKit.label(str(r[0]), false, UITheme.FONT_SMALL, 600)
		name_l.custom_minimum_size = Vector2(112 if r.size() > 2 else 150, 0)
		left.add_child(name_l)
		var right := UiKit.label(str(r[1]), true, UITheme.FONT_SMALL)
		right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(right)


func _try(p: Control, acts: Array) -> void:
	UiKit.header(p, "Try it")
	var f := UiKit.flow(p, 8)
	for a in acts:
		var action: String = a[2]
		var b := UiKit.chip(str(a[1]), func(): do(action), str(a[0]), 48.0)
		f.add_child(b)


# ------------------------------------------------------------------------------------------------ doing it for real

## "what:argument". The guide stays open: read, try, read on.
func do(action: String) -> void:
	var sh: UiShell = _home.shell
	if sh == null or sh.board == null or sh.board.doc == null:
		return
	var b: Board = sh.board
	var arg := action.get_slice(":", 1)
	match action.get_slice(":", 0):
		"tool":                                     # the tool, and a ring round its button
			sh.close_popover()
			App.put("tool", arg)
			if arg != "select":
				b.clear_selection()
			sh.dock.pulse(arg)
		"pop":                                      # a tool's options, and a ring round the button they belong to
			sh.open_popover(arg)
			sh.dock.pulse({"brush": "brush", "shapes": "shape", "write": "write", "add": "add", "dictate": "dictate"}.get(arg, arg))
		"pulse":
			sh.dock.pulse(arg)
		"all":
			for k in ["draw", "write", "shape", "select", "erase", "brush", "undo", "redo", "dictate", "add", "ai", "home"]:
				sh.dock.pulse(k)
		"tab":
			_home.select_tab(arg)
		"side":
			sh.open_side(arg)
		"type":
			sh.open_text_entry()
		"place":
			sh.close_popover()
			b.begin_place(arg, Popover.SIZES[sh.canvas_size_idx][2])
		"desk":
			sh.close_popover()
			b.surface.begin("", Popover.SIZES[sh.canvas_size_idx][2])


## The actions the topics use, for the tests: every one must be one `do` knows.
static func known_actions() -> PackedStringArray:
	return PackedStringArray(["tool", "pop", "pulse", "all", "tab", "side", "type", "place", "desk"])


# ------------------------------------------------------------------------------------------------ widgets

## A topic in the list: icon, title, one line about it.
class TopicBtn extends Btn:
	var summary := ""

	func _init(icon_id: String, title: String, sum: String) -> void:
		super(icon_id, title)
		summary = sum
		custom_minimum_size = Vector2(0, 68)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		_draw_tile_bg(r)
		var ih := 34.0
		_draw_icon(Rect2(Vector2(18, (size.y - ih) * 0.5), Vector2(ih, ih)), UITheme.ACCENT if on else UITheme.TEXT)
		var tw := size.x - 70.0 - 44.0
		draw_string(UITheme.font(600), Vector2(70, size.y * 0.5 - 3.0), fit_text(UITheme.font(600), text, UITheme.FONT, tw), HORIZONTAL_ALIGNMENT_LEFT, tw, UITheme.FONT, UITheme.TEXT)
		draw_string(UITheme.font(), Vector2(70, size.y * 0.5 + 21.0), fit_text(UITheme.font(), summary, UITheme.FONT_SMALL, tw), HORIZONTAL_ALIGNMENT_LEFT, tw, UITheme.FONT_SMALL, UITheme.TEXT_DIM)
		Icons.draw(self, "right", Rect2(Vector2(size.x - 40, (size.y - 22.0) * 0.5), Vector2(22, 22)), UITheme.TEXT_FAINT)


## A round colour dot (the colours of the ring).
class Dot extends Control:
	var col := Color.WHITE

	func _init(c: Color) -> void:
		col = c
		custom_minimum_size = Vector2(22, 22)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_arc(size * 0.5, 8.0, 0.0, TAU, 28, col, 3.0, true)
