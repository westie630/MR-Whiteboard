class_name DocSync
extends RefCounted
## Replication of one Document between headsets. It keeps no copy of the document: it listens to the document's own signals and
## remembers WHICH items and frames changed or went away, builds a batch of their current state when asked (take_batch), and applies
## a batch that came from somewhere else (apply). State, not operations: a batch says "item x is now this", "item y is gone", so
## history, undo, imports, the AI's accepted suggestions and every other way of editing the document are carried for free, and a
## batch that arrives twice or late does no harm.
##
## Only one room is shared: the frames of `room` and the items on them. What belongs to a device (a frame's spatial anchor) never
## goes over the wire and is never taken from it.

signal dirty()

const MAX_BATCH_ITEMS := 20000             # more than this in one batch is not a drawing, it is an attack
const MAX_ID := 64
const MAX_SNAPSHOT := 256 * 1024 * 1024    # decompressed

var doc: Document
var room := ""                             # the shared room's id ("" = the whole document)

var _items: Dictionary = {}                # id -> true: changed since the last batch
var _gone_items: Dictionary = {}
var _frames: Dictionary = {}
var _gone_frames: Dictionary = {}
var _applying := 0                         # > 0 while a batch is put into the document and its signals must not count as local edits


func attach(d: Document, shared_room: String = "") -> void:
	detach()
	doc = d
	room = shared_room
	clear()
	doc.item_added.connect(_on_item)
	doc.item_changed.connect(_on_item)
	doc.item_removed.connect(_on_item_removed)
	doc.frame_added.connect(_on_frame)
	doc.frame_changed.connect(_on_frame)
	doc.frame_removed.connect(_on_frame_removed)


func detach() -> void:
	if doc != null:
		for pair in [[doc.item_added, _on_item], [doc.item_changed, _on_item], [doc.item_removed, _on_item_removed],
				[doc.frame_added, _on_frame], [doc.frame_changed, _on_frame], [doc.frame_removed, _on_frame_removed]]:
			if (pair[0] as Signal).is_connected(pair[1]):
				(pair[0] as Signal).disconnect(pair[1])
	doc = null
	clear()


func clear() -> void:
	_items.clear()
	_gone_items.clear()
	_frames.clear()
	_gone_frames.clear()


func is_dirty() -> bool:
	return not (_items.is_empty() and _gone_items.is_empty() and _frames.is_empty() and _gone_frames.is_empty())


# ------------------------------------------------------------------------------------------------ what changed

func in_scope_frame(frame_id: String) -> bool:
	if doc == null:
		return false
	var f: FrameData = doc.frames.get(frame_id)
	return f != null and (room == "" or f.room == room)


func _on_item(it: Item) -> void:
	if _applying > 0 or not in_scope_frame(it.frame):
		return
	_items[it.id] = true
	_gone_items.erase(it.id)
	dirty.emit()


func _on_item_removed(it: Item) -> void:
	if _applying > 0 or not in_scope_frame(it.frame):
		return
	_gone_items[it.id] = true
	_items.erase(it.id)
	dirty.emit()


func _on_frame(f: FrameData) -> void:
	if _applying > 0 or (room != "" and f.room != room):
		return
	_frames[f.id] = true
	_gone_frames.erase(f.id)
	dirty.emit()


func _on_frame_removed(f: FrameData) -> void:
	if _applying > 0 or (room != "" and f.room != room):
		return
	_gone_frames[f.id] = true
	_frames.erase(f.id)
	dirty.emit()


## Everything that changed since the last call, as the state it is in now: {frames, items, gone_frames, gone_items} (empty lists
## left out). The list is cleared.
func take_batch() -> Dictionary:
	var out := {}
	if doc == null:
		return out
	var frames: Array = []
	for id in _frames:
		var f: FrameData = doc.frames.get(id)
		if f != null:
			frames.append(frame_to_wire(f))
	var items: Array = []
	for id in _items:
		var it: Item = doc.items.get(id)
		if it != null and in_scope_frame(it.frame):
			items.append(it.to_dict())
	if not frames.is_empty():
		out["frames"] = frames
	if not items.is_empty():
		out["items"] = items
	if not _gone_frames.is_empty():
		out["gone_frames"] = _gone_frames.keys()
	if not _gone_items.is_empty():
		out["gone_items"] = _gone_items.keys()
	clear()
	return out


## The ids a batch mentions (to tell which ones an acknowledgement is about).
static func ids_of(batch: Dictionary) -> Array:
	var out: Array = []
	for key in ["frames", "items"]:
		for d in batch.get(key, []):
			if d is Dictionary:
				out.append(str((d as Dictionary).get("id", "")))
	for key in ["gone_frames", "gone_items"]:
		for id in batch.get(key, []):
			out.append(str(id))
	return out


static func is_empty_batch(batch: Dictionary) -> bool:
	for key in ["frames", "items", "gone_frames", "gone_items"]:
		if not (batch.get(key, []) as Array).is_empty():
			return false
	return true


## The state of the given ids as they are now, in the shape of a batch: the way to tell somebody the truth about them.
func state_of(ids: Array) -> Dictionary:
	var out := {}
	if doc == null:
		return out
	var frames: Array = []
	var items: Array = []
	var gone_frames: Array = []
	var gone_items: Array = []
	for id in ids:
		var sid := str(id)
		if doc.frames.has(sid) and in_scope_frame(sid):
			frames.append(frame_to_wire(doc.frames[sid]))
		elif doc.items.has(sid) and in_scope_frame((doc.items[sid] as Item).frame):
			items.append((doc.items[sid] as Item).to_dict())
		else:
			# not here (any more): tell them it is gone, whichever kind it was
			gone_frames.append(sid)
			gone_items.append(sid)
	if not frames.is_empty():
		out["frames"] = frames
	if not items.is_empty():
		out["items"] = items
	if not gone_frames.is_empty():
		out["gone_frames"] = gone_frames
		out["gone_items"] = gone_items
	return out


## A frame as it goes over the wire: without what only this device knows.
static func frame_to_wire(f: FrameData) -> Dictionary:
	var d := f.to_dict()
	d["anchor"] = ""
	d["anchor_xf"] = U.xf_to_array(Transform3D.IDENTITY)
	d["anchor_guess"] = false
	return d


# ------------------------------------------------------------------------------------------------ what arrived

## Put a batch into the document: frames, then items, then what went away. `count_as_local` leaves the document's signals counting
## as edits (the host passes it, so the change is passed on to the others); without it nothing is marked (a headset that is only
## being told). Malformed entries are skipped. Returns {frames, items, gone, skipped}.
func apply(batch: Dictionary, count_as_local: bool = false) -> Dictionary:
	var res := {"frames": 0, "items": 0, "gone": 0, "skipped": 0}
	if doc == null:
		return res
	if not count_as_local:
		_applying += 1
	var budget := MAX_BATCH_ITEMS
	for d in _list(batch, "frames"):
		if budget <= 0 or not _sane(d):
			res.skipped += 1
			continue
		budget -= 1
		var fd := FrameData.from_dict(d)
		if room != "" and fd.room != room:
			res.skipped += 1
			continue
		var have: FrameData = doc.frames.get(fd.id)
		fd.keep_anchor_of(have)                      # a spatial anchor belongs to the device that made it
		if have != null:
			doc.replace_frame(fd)
		else:
			doc.add_frame(fd)
		res.frames += 1
	for d in _list(batch, "items"):
		if budget <= 0 or not _sane(d):
			res.skipped += 1
			continue
		budget -= 1
		var it := Item.from_dict(d)
		if not in_scope_frame(it.frame):
			res.skipped += 1                          # a frame this document does not have (yet)
			continue
		if doc.items.has(it.id):
			doc.replace_item(it)
		else:
			doc.add_item(it)
		res.items += 1
	for id in batch.get("gone_items", []):
		var sid := str(id)
		var gone: Item = doc.items.get(sid)
		if gone != null and in_scope_frame(gone.frame):
			doc.remove_item(sid)
			res.gone += 1
	for id in batch.get("gone_frames", []):
		var sid := str(id)
		if doc.frames.has(sid) and in_scope_frame(sid):
			doc.remove_frame(sid)
			res.gone += 1
	if not count_as_local:
		_applying -= 1
	return res


func _list(batch: Dictionary, key: String) -> Array:
	var v: Variant = batch.get(key, [])
	return v if v is Array else []


func _sane(d: Variant) -> bool:
	if not (d is Dictionary):
		return false
	var id: Variant = (d as Dictionary).get("id")
	return id is String and (id as String) != "" and (id as String).length() <= MAX_ID


# ------------------------------------------------------------------------------------------------ whole documents

## The shared room as a document of its own, in the file format: what a joining headset is sent. Nothing of the host's other rooms,
## and no spatial anchors.
func snapshot() -> Dictionary:
	var d := doc.to_dict()
	var rooms: Array = []
	for r in d.get("rooms", []):
		if str(r.get("id", "")) == room:
			var rr: Dictionary = (r as Dictionary).duplicate()
			rr["anchor"] = ""
			rr["anchor_xf"] = U.xf_to_array(Transform3D.IDENTITY)
			rooms.append(rr)
	var frames: Array = []
	var keep := {}
	for f in d.get("frames", []):
		if room == "" or str(f.get("room", "")) == room:
			var ff: Dictionary = (f as Dictionary).duplicate()
			ff["anchor"] = ""
			ff["anchor_xf"] = U.xf_to_array(Transform3D.IDENTITY)
			frames.append(ff)
			keep[str(f.get("id", ""))] = true
	var items: Array = []
	for i in d.get("items", []):
		if keep.has(str(i.get("frame", ""))):
			items.append(i)
	d["rooms"] = rooms
	d["frames"] = frames
	d["items"] = items
	d["last_room"] = room
	return d


## A document dictionary as bytes for the wire (JSON, gzipped: the one method whose output size need not be known beforehand) and back. `unpack` gives {} for anything that is not one.
static func pack(d: Dictionary) -> PackedByteArray:
	return JSON.stringify(d).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)


static func unpack(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 18 or bytes[0] != 0x1f or bytes[1] != 0x8b:        # not a gzip stream: do not even try
		return {}
	var raw := bytes.decompress_dynamic(MAX_SNAPSHOT, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if parsed is Dictionary and (parsed as Dictionary).get("format", "") == "mr-whiteboard":
		return parsed
	return {}
