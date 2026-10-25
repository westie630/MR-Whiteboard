class_name Shortcuts
extends RefCounted
## Editing keys of a physical keyboard, the same on the PC and in the headset (a Bluetooth keyboard): undo / redo, save, duplicate,
## delete, cancel. Letters that start something (tools, new canvas) stay with the PC rig.


## Handle a key press. Returns true when it was one of the editing keys.
static func edit_key(board: Board, k: InputEventKey) -> bool:
	if not k.pressed or k.echo or board == null:
		return false
	var cmd := k.ctrl_pressed or k.meta_pressed
	match k.keycode:
		KEY_Z:
			if not cmd:
				return false
			if k.shift_pressed:
				board.redo()
			else:
				board.undo()
		KEY_Y:
			if not cmd:
				return false
			board.redo()
		KEY_S:
			if not cmd or board.doc == null:
				return false
			board.flush_save()
			board.doc.save()
			board.toast.emit("Saved")
		KEY_D:
			if not cmd:
				return false
			board.duplicate_selection()
		KEY_DELETE, KEY_BACKSPACE:
			board.delete_selection()
		KEY_PAGEUP, KEY_PAGEDOWN, KEY_HOME, KEY_END, KEY_LEFT, KEY_RIGHT:
			return _page_key(board, k)
		KEY_ESCAPE:
			if not board.placing.is_empty():
				board.cancel_place()
			elif not board.placing_text.is_empty():
				board.cancel_place_text()
			elif board.surface.finding():
				board.surface.cancel()
			elif board.surface.aligning():
				board.surface.cancel_align()
			else:
				board.clear_selection()
		_:
			return false
	return true


## A key that types a character (not a shortcut): what starts a new text when no field is being edited.
static func is_printable(k: InputEventKey) -> bool:
	return k.pressed and k.unicode >= 32 and k.unicode != 127 and not (k.ctrl_pressed or k.alt_pressed or k.meta_pressed)


## Page Up / Page Down (and the arrow keys, Home and End) turn the pages of the PDF canvas in view; with none in view they are not ours.
static func _page_key(board: Board, k: InputEventKey) -> bool:
	if k.ctrl_pressed or k.alt_pressed or k.meta_pressed:
		return false
	var fn := board.current_pdf_frame()
	if fn == null or board.doc == null:
		return false
	var page := board.doc.page_of(fn.data.id)
	match k.keycode:
		KEY_PAGEUP, KEY_LEFT:
			page -= 1
		KEY_PAGEDOWN, KEY_RIGHT:
			page += 1
		KEY_HOME:
			page = 1
		KEY_END:
			page = 1000000
	board.pdf_turn(fn.data.id, page)
	return true
