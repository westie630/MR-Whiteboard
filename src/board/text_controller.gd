class_name TextController
extends RefCounted
## Text items made from words rather than ink: typed (virtual or physical keyboard) or dictated. New text goes on the canvas the head is
## looking at, below any text already there, and is selected so it can be moved or corrected; editing an item keeps its size and place.
## Both are single undo steps.

const WRAP_CHARS := 30                     # lines are broken at about this many characters
const AI_WRAP := 40                        # the same for text written by the AI (longer than a typed line)

var board: Board


func _init(b: Board) -> void:
	board = b


## Where new text would go ({frame, center}), or {} when there is no canvas to put it on.
func spot() -> Dictionary:
	return board.dictation_spot() if board.doc != null else {}


## Put text on the canvas the head is looking at. Returns the new item, or null when there is nowhere to put it.
func place(text: String) -> Item:
	text = text.strip_edges()
	if board.doc == null or text == "":
		return null
	var s := spot()
	if s.is_empty():
		board.toast.emit("Place a canvas first, then add text. Your text: \"%s\"" % text.left(60))
		return null
	var frame_id: String = s.frame
	var t := make(text, frame_id, WRAP_CHARS)
	t.center = _clear_spot(frame_id, s.center, t.size)
	board.history.do(History.op_add([t]))
	board.select_items([t.id], frame_id)
	return t


## A text item in the current colour and text style, not in the document yet (the placement tool shows it as a ghost first).
func make(text: String, frame_id: String, wrap: int = WRAP_CHARS) -> Item:
	var col: Color = App.val("color")
	var st := TextLayout.style(str(App.val("text_style")))
	return Item.make_text(frame_id, wrap_text(text.strip_edges(), wrap), Color(col.r, col.g, col.b, 1.0), float(st[2]), int(st[3]))


## Put text on an existing canvas with its middle at `center` (frame coordinates): one undo step, selected afterwards so it can be
## moved. With `clear` it is moved down until it does not sit on other text. Null when the canvas is gone, locked or the text is empty.
func place_at(text: String, frame_id: String, center: Vector2, wrap: int = WRAP_CHARS, clear: bool = false) -> Item:
	var fd: FrameData = board.doc.frames.get(frame_id) if board.doc != null else null
	if fd == null or fd.kind != FrameData.CANVAS or fd.locked or text.strip_edges() == "":
		return null
	var t := make(text, frame_id, wrap)
	t.center = _clear_spot(frame_id, center, t.size) if clear else center
	board.history.do(History.op_add([t]))
	board.select_items([t.id], frame_id)
	return t


## Replace the words of a text item (one undo step). Empty text is ignored: delete the item to remove it.
func edit(item_id: String, text: String) -> bool:
	var it: Item = board.doc.items.get(item_id) if board.doc != null else null
	text = wrap_text(text.strip_edges(), WRAP_CHARS)
	if it == null or it.kind != Item.TEXT or text == "" or text == it.text:
		return false
	board.ink.set_text(item_id, text)
	return true


## Set the weight and/or italic (null = leave as is) of every selected text item: one undo step. The boxes are re-measured, since the
## letters get wider or narrower.
func set_style(weight: Variant, italic: Variant, em: Variant = null) -> bool:
	var before: Array = []
	var after: Array = []
	for it in selected_texts():
		var t := it as Item
		var upd := t.duplicate_item(false)
		if weight != null:
			upd.weight = clampi(int(weight), TextLayout.MIN_WEIGHT, TextLayout.MAX_WEIGHT)
		if italic != null:
			upd.italic = bool(italic)
		if em != null:
			upd.font_size = float(em)
		if upd.weight == t.weight and upd.italic == t.italic and is_equal_approx(upd.font_size, t.font_size):
			continue
		upd.refit_text()
		before.append(t)
		after.append(upd)
	if before.is_empty():
		return false
	board.history.do(History.op_modify(before, after))
	return true


## Give the selected text the size and weight of a style (Heading 1, Body, ...), and make it the style of new text.
func apply_style(style_id: String) -> bool:
	var st := TextLayout.style(style_id)
	App.put("text_style", st[0])
	return set_style(int(st[3]), null, float(st[2]))


## The selected text items.
func selected_texts() -> Array:
	var out: Array = []
	if board.doc != null:
		for it in board.selected_items():
			if (it as Item).kind == Item.TEXT:
				out.append(it)
	return out


## The selected text item when exactly one text item is selected.
func selected_text() -> Item:
	if board.doc == null or board.selection.size() != 1:
		return null
	var it: Item = board.doc.items.get(board.selection[0])
	return it if it != null and it.kind == Item.TEXT else null


## The selected closed shape (a box, circle, ...) when exactly one is selected: typed words become its label.
func selected_shape() -> Item:
	if board.doc == null or board.selection.size() != 1:
		return null
	var it: Item = board.doc.items.get(board.selection[0])
	return it if it != null and it.kind == Item.SHAPE and not it.is_line() else null


## Set (or, with empty text, clear) the label inside a shape.
func set_label(item_id: String, text: String) -> bool:
	var it: Item = board.doc.items.get(item_id) if board.doc != null else null
	text = wrap_text(text.strip_edges(), WRAP_CHARS)
	if it == null or it.kind != Item.SHAPE or text == it.label:
		return false
	var upd := it.duplicate_item(false)
	upd.label = text
	board.history.do(History.op_modify([it], [upd]))
	return true


## Move the wanted centre down until the new text does not sit on other text.
func _clear_spot(frame_id: String, want: Vector2, size: Vector2) -> Vector2:
	var c := want
	for _i in 40:
		var r := Rect2(c - size * 0.5, size).grow(size.y * 0.1)
		var hit := false
		for it in board.doc.items.values():
			if (it as Item).kind == Item.TEXT and (it as Item).frame == frame_id and r.intersects((it as Item).bounds()):
				hit = true
				break
		if not hit:
			break
		c.y -= size.y * 1.2
	return c


## Break text into lines of at most `width` characters, at spaces (a longer word keeps its own line). Line breaks already in the
## text stay where they are.
static func wrap_text(text: String, width: int) -> String:
	var lines := PackedStringArray()
	for para in text.split("\n"):
		var line := ""
		var any := false
		for w in para.split(" ", false):
			any = true
			if line != "" and line.length() + 1 + w.length() > width:
				lines.append(line)
				line = w
			else:
				line = w if line == "" else line + " " + w
		if line != "" or not any:
			lines.append(line)
	return "\n".join(lines)
