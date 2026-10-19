class_name TextController
extends RefCounted
## Text items made from words rather than ink: typed (virtual or physical keyboard) or dictated. New text goes on the canvas the head is
## looking at, below any text already there, and is selected so it can be moved or corrected; editing an item keeps its size and place.
## Both are single undo steps.

const EM := 0.045                          # size of new text (m)
const WRAP_CHARS := 30                     # lines are broken at about this many characters

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
	var col: Color = App.val("color")
	var t := Item.make_text(frame_id, wrap_text(text, WRAP_CHARS), Color(col.r, col.g, col.b, 1.0), EM)
	t.center = _clear_spot(frame_id, s.center, t.size)
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
