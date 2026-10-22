class_name History
extends RefCounted
## Undo / redo for a Document. Each entry is an operation that knows how to be applied forwards and backwards.
## Entries: add (items), remove (items), modify (item snapshots before/after), xform (items moved by a 2D or 3D transform),
## frame (frame snapshots before/after), frame_add / frame_remove (frame with its items), group (several of these).

signal changed()

const LIMIT := 200

var doc: Document
var undo_stack: Array = []
var redo_stack: Array = []
var serial := 0                            # counts new operations (not undo / redo): tells "nothing has been done since" apart
var _group: Array = []
var _grouping := 0


func _init(d: Document) -> void:
	doc = d


func can_undo() -> bool:
	return not undo_stack.is_empty()


func can_redo() -> bool:
	return not redo_stack.is_empty()


func clear() -> void:
	undo_stack.clear()
	redo_stack.clear()
	changed.emit()


# ------------------------------------------------------------------------------------------------ recording

## Apply an operation and remember it.
func do(op: Dictionary) -> void:
	_apply(op, false)
	_record(op)


## Remember an operation that has already been applied (live edits such as a drag).
func record(op: Dictionary) -> void:
	_record(op)


func _record(op: Dictionary) -> void:
	if _grouping > 0:
		_group.append(op)
		return
	serial += 1
	undo_stack.append(op)
	if undo_stack.size() > LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	changed.emit()


func begin_group() -> void:
	_grouping += 1


func end_group() -> void:
	_grouping = maxi(_grouping - 1, 0)
	if _grouping == 0 and not _group.is_empty():
		var g := _group
		_group = []
		_record({"type": "group", "ops": g})


func undo() -> bool:
	if undo_stack.is_empty():
		return false
	var op: Dictionary = undo_stack.pop_back()
	_apply(op, true)
	redo_stack.append(op)
	changed.emit()
	return true


func redo() -> bool:
	if redo_stack.is_empty():
		return false
	var op: Dictionary = redo_stack.pop_back()
	_apply(op, false)
	undo_stack.append(op)
	changed.emit()
	return true


# ------------------------------------------------------------------------------------------------ undo / redo of some items only

## Undo the latest operation that touches only `ids` (and connector lines, which follow their shapes); operations on other items are
## left alone. Returns the operation, or {} when there is none. An operation that touches `ids` together with other items blocks
## the search (undoing something older on those items could overwrite it).
func undo_local(ids: Array) -> Dictionary:
	var i := _find_local(undo_stack, ids)
	if i < 0:
		return {}
	var op: Dictionary = undo_stack.pop_at(i)
	_apply(op, true)
	redo_stack.append(op)
	changed.emit()
	return op


## The same for redo: the latest undone operation that touches only `ids`.
func redo_local(ids: Array) -> Dictionary:
	var i := _find_local(redo_stack, ids)
	if i < 0:
		return {}
	var op: Dictionary = redo_stack.pop_at(i)
	_apply(op, false)
	undo_stack.append(op)
	changed.emit()
	return op


func can_undo_local(ids: Array) -> bool:
	return _find_local(undo_stack, ids) >= 0


func can_redo_local(ids: Array) -> bool:
	return _find_local(redo_stack, ids) >= 0


func _find_local(stack: Array, ids: Array) -> int:
	for i in range(stack.size() - 1, -1, -1):
		var touched: Dictionary = {}
		_collect(stack[i], touched)
		var hit := false
		var foreign := false
		for id in touched:
			if ids.has(id):
				hit = true
			elif not touched[id]:
				foreign = true
		if hit:
			return -1 if foreign else i
	return -1


## id -> true when the item is a line (a connector), for every item an operation touches.
func _collect(op: Dictionary, out: Dictionary) -> void:
	match str(op.type):
		"add", "remove":
			for d in op["items"]:
				out[str(d.id)] = Item.from_dict(d).is_line()
		"modify":
			for d in op["after"]:
				out[str(d.id)] = Item.from_dict(d).is_line()
		"xform":
			for id in op["ids"]:
				out[str(id)] = doc.items.has(id) and (doc.items[id] as Item).is_line()
		"group":
			for o in op["ops"]:
				_collect(o, out)
		_:
			out["frame:" + str(op.get("frame", op.get("before", {})).get("id", ""))] = false


# ------------------------------------------------------------------------------------------------ operation builders

static func op_add(items: Array) -> Dictionary:
	var snaps: Array = []
	for it in items:
		snaps.append((it as Item).to_dict())
	return {"type": "add", "items": snaps}


static func op_remove(items: Array) -> Dictionary:
	var snaps: Array = []
	for it in items:
		snaps.append((it as Item).to_dict())
	return {"type": "remove", "items": snaps}


static func op_modify(before: Array, after: Array) -> Dictionary:
	var b: Array = []
	var a: Array = []
	for it in before:
		b.append((it as Item).to_dict())
	for it in after:
		a.append((it as Item).to_dict())
	return {"type": "modify", "before": b, "after": a}


static func op_xform2(ids: Array, t: Transform2D) -> Dictionary:
	return {"type": "xform", "ids": ids.duplicate(), "t2": t}


static func op_xform3(ids: Array, t: Transform3D) -> Dictionary:
	return {"type": "xform", "ids": ids.duplicate(), "t3": t}


static func op_frame(before: FrameData, after: FrameData) -> Dictionary:
	return {"type": "frame", "before": before.to_dict(), "after": after.to_dict()}


static func op_frame_add(f: FrameData) -> Dictionary:
	return {"type": "frame_add", "frame": f.to_dict(), "items": []}


static func op_frame_remove(f: FrameData, items: Array) -> Dictionary:
	var snaps: Array = []
	for it in items:
		snaps.append((it as Item).to_dict())
	return {"type": "frame_remove", "frame": f.to_dict(), "items": snaps}


# ------------------------------------------------------------------------------------------------ applying

func _apply(op: Dictionary, reverse: bool) -> void:
	match op.type:
		"add":
			_add_items(op["items"]) if not reverse else _remove_items(op["items"])
		"remove":
			_remove_items(op["items"]) if not reverse else _add_items(op["items"])
		"modify":
			for d in (op["before"] if reverse else op["after"]):
				doc.replace_item(Item.from_dict(d))
		"xform":
			var ids: Array = op["ids"]
			for id in ids:
				if not doc.items.has(id):
					continue
				var it: Item = doc.items[id]
				if op.has("t2"):
					it.apply_xform((op["t2"] as Transform2D).affine_inverse() if reverse else op["t2"])
				else:
					it.apply_xform3((op["t3"] as Transform3D).affine_inverse() if reverse else op["t3"])
				doc.item_touched(it)
		"frame":
			doc.replace_frame(FrameData.from_dict(op["before"] if reverse else op["after"]))
		"frame_add":
			if reverse:
				doc.remove_frame(str(op["frame"].id))
			else:
				doc.add_frame(FrameData.from_dict(op["frame"]))
				_add_items(op["items"])
		"frame_remove":
			if reverse:
				doc.add_frame(FrameData.from_dict(op["frame"]))
				_add_items(op["items"])
			else:
				doc.remove_frame(str(op["frame"].id))
		"group":
			var ops: Array = op["ops"]
			if reverse:
				for i in range(ops.size() - 1, -1, -1):
					_apply(ops[i], true)
			else:
				for o in ops:
					_apply(o, false)


func _add_items(snaps: Array) -> void:
	for d in snaps:
		var it := Item.from_dict(d)
		if doc.items.has(it.id):
			doc.replace_item(it)
		else:
			doc.add_item(it)


func _remove_items(snaps: Array) -> void:
	for d in snaps:
		doc.remove_item(str(d.id))
