class_name Document
extends RefCounted
## One whiteboard document ("like a Word document"): rooms, frames (canvases and 3D sketches) and the items on them.
## Saved as JSON (.mrw). Every mutation goes through this class so views and autosave can follow the signals.

signal item_added(item: Item)
signal item_removed(item: Item)
signal item_changed(item: Item)
signal frame_added(frame: FrameData)
signal frame_removed(frame: FrameData)
signal frame_changed(frame: FrameData)
signal rooms_changed()
signal changed()                          # anything at all (autosave trigger)

const VERSION := 1
const EXT := "mrw"

var id := ""
var name := "Untitled"
var created := 0
var modified := 0
var rooms: Array = []                     # {id, name, anchor, anchor_xf (Transform3D, tracking space when made), used}
var frames: Dictionary = {}               # id -> FrameData
var items: Dictionary = {}                # id -> Item
var next_z := 1
var last_room := ""
var path := ""
var transient := false                    # a copy that belongs to a shared session (DocSync): never written to the documents folder

var _by_frame: Dictionary = {}            # frame id -> Array of item ids (kept in z order lazily)
var _dirty_index := true


static func create(doc_name: String = "Untitled") -> Document:
	var d := Document.new()
	d.id = U.uid("d")
	d.name = doc_name
	d.created = int(Time.get_unix_time_from_system())
	d.modified = d.created
	return d


func rename(new_name: String) -> void:
	if new_name.strip_edges() != "":
		name = new_name.strip_edges()
		_touch()


# ------------------------------------------------------------------------------------------------ rooms

func add_room(room_name: String, anchor_uuid: String = "", anchor_xf: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	var r := {"id": U.uid("r"), "name": room_name, "anchor": anchor_uuid, "anchor_xf": anchor_xf, "used": int(Time.get_unix_time_from_system())}
	rooms.append(r)
	last_room = r.id
	rooms_changed.emit()
	_touch()
	return r


func room(room_id: String) -> Dictionary:
	for r in rooms:
		if r.id == room_id:
			return r
	return {}


func set_room_field(room_id: String, key: String, value: Variant) -> void:
	for r in rooms:
		if r.id == room_id:
			r[key] = value
			rooms_changed.emit()
			_touch()
			return


func remove_room(room_id: String) -> Array:
	## Removes a room and everything in it; returns the anchors that were used (so they can be erased on the device).
	var anchors: Array = []
	for r in rooms.duplicate():
		if r.id == room_id:
			if str(r.anchor) != "":
				anchors.append(r.anchor)
			rooms.erase(r)
	for fid in frames.keys():
		if (frames[fid] as FrameData).room == room_id:
			var f: FrameData = frames[fid]
			if f.anchor != "":
				anchors.append(f.anchor)
			remove_frame(fid)
	if last_room == room_id:
		last_room = str(rooms[0].id) if not rooms.is_empty() else ""
	rooms_changed.emit()
	_touch()
	return anchors


func next_room_name() -> String:
	var names := ["Living room", "Office", "Studio", "Bedroom", "Kitchen", "Dining room", "Garage", "Lounge", "Workshop"]
	var used: Array = []
	for r in rooms:
		used.append(r.name)
	for n in names:
		if not used.has(n):
			return n
	return "Room %d" % (rooms.size() + 1)


# ------------------------------------------------------------------------------------------------ frames

func add_frame(f: FrameData) -> void:
	if f.name == "":
		f.name = _next_frame_name(f.kind)
	frames[f.id] = f
	frame_added.emit(f)
	_touch()


func remove_frame(frame_id: String) -> Array:
	## Removes a frame and its items; returns the removed items (for undo).
	var removed: Array = []
	for it in items_of(frame_id):
		removed.append(it)
		remove_item(it.id)
	if frames.has(frame_id):
		var f: FrameData = frames[frame_id]
		frames.erase(frame_id)
		frame_removed.emit(f)
	_touch()
	return removed


func replace_frame(f: FrameData) -> void:
	frames[f.id] = f
	frame_changed.emit(f)
	_touch()


func frame_touched(f: FrameData) -> void:
	frame_changed.emit(f)
	_touch()


func frames_in(room_id: String) -> Array:
	var out: Array = []
	for f in frames.values():
		if (f as FrameData).room == room_id:
			out.append(f)
	return out


func _next_frame_name(kind: String) -> String:
	var base := "Canvas" if kind == FrameData.CANVAS else "3D sketch"
	var k := 1
	while true:
		var cand := "%s %d" % [base, k]
		var taken := false
		for f in frames.values():
			if (f as FrameData).name == cand:
				taken = true
		if not taken:
			return cand
		k += 1
	return base


# ------------------------------------------------------------------------------------------------ items

func add_item(it: Item) -> void:
	if it.z == 0:
		it.z = next_z
	next_z = maxi(next_z, it.z + 1)
	items[it.id] = it
	_dirty_index = true
	item_added.emit(it)
	_touch()


func remove_item(item_id: String) -> void:
	if not items.has(item_id):
		return
	var it: Item = items[item_id]
	items.erase(item_id)
	_dirty_index = true
	item_removed.emit(it)
	_touch()


## Swap in a changed copy of an item (undo/redo, property edits).
func replace_item(it: Item) -> void:
	if not items.has(it.id):
		add_item(it)
		return
	items[it.id] = it
	_dirty_index = true
	item_changed.emit(it)
	_touch()


func item_touched(it: Item) -> void:
	item_changed.emit(it)
	_touch()


func items_of(frame_id: String) -> Array:
	if _dirty_index:
		_by_frame.clear()
		for it in items.values():
			var fid: String = (it as Item).frame
			if not _by_frame.has(fid):
				_by_frame[fid] = []
			_by_frame[fid].append(it)
		for k in _by_frame.keys():
			(_by_frame[k] as Array).sort_custom(func(a, b): return a.z < b.z or (a.z == b.z and a.id < b.id))   # the id breaks a tie the same way on every headset
		_dirty_index = false
	return (_by_frame.get(frame_id, []) as Array).duplicate()


func top_z() -> int:
	var t := next_z
	next_z += 1
	return t


## Shapes whose boundary the point touches, topmost first (frame coordinates).
func pick(frame_id: String, p: Vector2, tol: float) -> Item:
	var list := items_of(frame_id)
	for i in range(list.size() - 1, -1, -1):
		var it: Item = list[i]
		if it.hit(p, tol):
			return it
	return null


## Closed shape (filled or not) containing the point, smallest first: the target for a label written inside a box.
func shape_containing(frame_id: String, p: Vector2) -> Item:
	var best: Item = null
	var best_area := INF
	for it in items_of(frame_id):
		var item: Item = it
		if item.kind != Item.SHAPE or item.is_line():
			continue
		var poly := item.poly if item.shape == "poly" else Shapes.world_fill_poly(item)
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly):
			var area := Geom2D.polygon_area(poly)
			if area < best_area:
				best_area = area
				best = item
	return best


# ------------------------------------------------------------------------------------------------ save / load

func _touch() -> void:
	modified = int(Time.get_unix_time_from_system())
	changed.emit()


func to_dict() -> Dictionary:
	var ritems: Array = []
	for r in rooms:
		ritems.append({"id": r.id, "name": r.name, "anchor": r.anchor, "anchor_xf": U.xf_to_array(r.anchor_xf), "used": r.used})
	var fr: Array = []
	for f in frames.values():
		fr.append((f as FrameData).to_dict())
	var its: Array = []
	var sorted: Array = items.values()
	sorted.sort_custom(func(a, b): return a.z < b.z)
	for it in sorted:
		its.append((it as Item).to_dict())
	return {"format": "mr-whiteboard", "version": VERSION, "id": id, "name": name, "created": created, "modified": modified,
		"next_z": next_z, "last_room": last_room, "rooms": ritems, "frames": fr, "items": its}


static func from_dict(d: Dictionary) -> Document:
	var doc := Document.new()
	doc.id = str(d.get("id", U.uid("d")))
	doc.name = str(d.get("name", "Untitled"))
	doc.created = int(d.get("created", 0))
	doc.modified = int(d.get("modified", doc.created))
	doc.next_z = int(d.get("next_z", 1))
	doc.last_room = str(d.get("last_room", ""))
	for r in d.get("rooms", []):
		doc.rooms.append({"id": str(r.get("id", U.uid("r"))), "name": str(r.get("name", "Room")), "anchor": str(r.get("anchor", "")),
			"anchor_xf": U.xf_from_array(r.get("anchor_xf")), "used": int(r.get("used", 0))})
	for f in d.get("frames", []):
		var fd := FrameData.from_dict(f)
		doc.frames[fd.id] = fd
	for i in d.get("items", []):
		var it := Item.from_dict(i)
		doc.items[it.id] = it
		doc.next_z = maxi(doc.next_z, it.z + 1)
	return doc


func save(file_path: String = "") -> Error:
	if transient and file_path == "":
		return OK
	if file_path != "":
		path = file_path
	if path == "":
		path = "%s/%s.%s" % [App.docs_dir, id, EXT]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict()))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path + ".bak")
		DirAccess.rename_absolute(path, path + ".bak")
	return DirAccess.rename_absolute(tmp, path)


static func load_file(file_path: String) -> Document:
	var parsed: Variant = _parse(file_path)
	if parsed == null and recover_file(file_path):
		parsed = _parse(file_path)
	if parsed == null:
		return null
	var doc := Document.from_dict(parsed)
	doc.path = file_path
	return doc


## The file's contents if it is a whole document, else null.
static func _parse(file_path: String) -> Variant:
	if not FileAccess.file_exists(file_path):
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file_path))
	if not (parsed is Dictionary) or (parsed as Dictionary).get("format", "") != "mr-whiteboard":
		return null
	return parsed


## A save cut short (the app killed or the headset switched off between writing the new file and putting it in place) leaves the
## document missing, or damaged, with a whole copy beside it: the new one (.tmp, written completely but not yet renamed) or the one
## before (.bak). The newest whole copy is put back in place; a damaged file is kept aside as .damaged. False if there is none.
static func recover_file(file_path: String) -> bool:
	for cand in [file_path + ".tmp", file_path + ".bak"]:
		if _parse(cand) == null:
			continue
		if FileAccess.file_exists(file_path):
			DirAccess.remove_absolute(file_path + ".damaged")
			DirAccess.rename_absolute(file_path, file_path + ".damaged")
		if DirAccess.copy_absolute(cand, file_path) != OK:
			return false
		print("[docs] %s was recovered from %s" % [file_path.get_file(), cand.get_file()])
		return true
	return false
