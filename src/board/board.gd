class_name Board
extends Node3D
## The whiteboard world. It owns the open Document, one FrameNode per frame (canvas or 3D sketch), the rooms and spatial anchors
## that keep every frame fixed in the real room, the selection, and the pen / hand controllers that edit the document.
## A rig (headset or PC) feeds it the pen and hand state each frame through tick().

signal toast(text: String)
signal changed()                           # tool, selection, room or document state changed: the UI refreshes
signal document_opened()

const ROOM_SEARCH_S := 7.0                 # how long to look for a known room before asking what to do
const RECONCILE_S := 0.6
const ANCHOR_LOST_S := 14.0                # a frame anchor without a pose for this long, in a room that is here, is considered lost
const AUTOSAVE_S := 1.5
const CAPTURE := 0.12                      # a pen this close (m) to a canvas draws on it
const HOVER_RANGE := 0.28

var doc: Document
var history: History
var anchors: AnchorService
var head_provider := Callable()            # -> Transform3D, the head in world space
var surface_hit := Callable()              # (origin, dir) -> {point, normal} for real surfaces (Meta scene walls and tables), optional

var current_room := ""
var room_state := "none"                   # none | searching | found | needs_room | unanchored
var frame_nodes: Dictionary = {}           # frame id -> FrameNode
var active_frame := ""                     # the canvas last drawn on / selected: the target of the Canvas tab
var volume_id := ""                        # the 3D sketch new air strokes go into
var selection: Array = []                  # selected item ids (all on sel_frame)
var sel_frame := ""
var stencil := "rect"
var placing: Dictionary = {}               # canvas placement in progress: {kind, ghost, size}
var grabs: Dictionary = {}                 # frame id -> {xf: Transform3D (world), scale: float} while a hand holds it
var pen_ctl: PenController
var hand_ctl: HandController
var ink: InkController
var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))

var _held: Dictionary = {}                 # pose smoothing per anchor
var _pending: Dictionary = {}              # anchor creations in flight (tag -> true)
var _no_room_t := 0.0
var _reconcile_t := 0.0
var _save_due := -1.0
var _room_auto_t := 0.0
var _overlay_cb: Dictionary = {}
var _lost_t: Dictionary = {}
var _pending_pose: Dictionary = {}
var _orphans: Array = []
var _was_down := false
var _was_back := false


func _init() -> void:
	name = "Board"
	pen_ctl = PenController.new(self)
	hand_ctl = HandController.new(self)
	ink = InkController.new(self)


func setup(anchor_service: AnchorService) -> void:
	anchors = anchor_service
	anchors.created.connect(_on_anchor_created)
	anchors.create_failed.connect(_on_anchor_failed)
	App.setting_changed.connect(_on_setting)


# ------------------------------------------------------------------------------------------------ documents

func open(d: Document) -> void:
	close_document()
	doc = d
	history = History.new(d)
	history.changed.connect(func(): changed.emit())
	doc.item_added.connect(_on_item_added)
	doc.item_removed.connect(_on_item_removed)
	doc.item_changed.connect(_on_item_changed)
	doc.frame_added.connect(_on_frame_added)
	doc.frame_removed.connect(_on_frame_removed)
	doc.frame_changed.connect(_on_frame_changed)
	doc.changed.connect(_on_doc_changed)
	for f in doc.frames.values():
		_make_frame_node(f)
	current_room = ""
	room_state = "searching" if not doc.rooms.is_empty() else "none"
	_no_room_t = 0.0
	_room_auto_t = 0.0
	selection.clear()
	sel_frame = ""
	active_frame = ""
	volume_id = ""
	for f in doc.frames.values():
		if (f as FrameData).kind == FrameData.VOLUME:
			volume_id = (f as FrameData).id
	if anchors != null:
		anchors.track(DocStore.anchors_of(doc))
	App.put("last_doc", doc.id)
	document_opened.emit()
	changed.emit()


func close_document() -> void:
	if doc == null:
		return
	flush_save()
	if anchors != null:
		for a in DocStore.anchors_of(doc):
			anchors.untrack(a)
	for fn in frame_nodes.values():
		(fn as Node).queue_free()
	frame_nodes.clear()
	grabs.clear()
	_held.clear()
	_pending.clear()
	ink.reset()
	cancel_place()
	_disconnect_doc()
	for a in _orphans:
		if anchors != null:
			anchors.erase(a)
	_orphans.clear()
	doc = null
	history = null


func _disconnect_doc() -> void:
	for pair in [[doc.item_added, _on_item_added], [doc.item_removed, _on_item_removed], [doc.item_changed, _on_item_changed],
			[doc.frame_added, _on_frame_added], [doc.frame_removed, _on_frame_removed], [doc.frame_changed, _on_frame_changed],
			[doc.changed, _on_doc_changed]]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])


func new_document(doc_name: String = "") -> void:
	open(DocStore.create_new(doc_name))


func open_id(id: String) -> bool:
	var d := DocStore.open(id)
	if d == null:
		toast.emit("Could not open that document.")
		return false
	open(d)
	toast.emit("Opened \"%s\"" % d.name)
	return true


func flush_save() -> void:
	if doc != null and _save_due >= 0.0:
		_save_due = -1.0
		var err := doc.save()
		if err != OK:
			toast.emit("Saving failed (error %d)" % err)


func _on_doc_changed() -> void:
	_save_due = AUTOSAVE_S


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_PREDELETE:
		if doc != null:
			flush_save()


# ------------------------------------------------------------------------------------------------ document -> scene

func _make_frame_node(f: FrameData) -> FrameNode:
	var fn := FrameNode.new()
	add_child(fn)
	fn.setup(f, doc)
	fn.visible = false
	frame_nodes[f.id] = fn
	return fn


func _on_frame_added(f: FrameData) -> void:
	if not frame_nodes.has(f.id):
		_make_frame_node(f)
	if f.kind == FrameData.VOLUME:
		volume_id = f.id
	changed.emit()


func _on_frame_removed(f: FrameData) -> void:
	if frame_nodes.has(f.id):
		(frame_nodes[f.id] as Node).queue_free()
		frame_nodes.erase(f.id)
	grabs.erase(f.id)
	_held.erase("frame:" + f.id)
	if sel_frame == f.id:
		clear_selection()
	if active_frame == f.id:
		active_frame = ""
	if volume_id == f.id:
		volume_id = ""
		for g in doc.frames.values():
			if (g as FrameData).kind == FrameData.VOLUME and (g as FrameData).room == f.room:
				volume_id = (g as FrameData).id
	changed.emit()


func _on_frame_changed(f: FrameData) -> void:
	var fn: FrameNode = frame_nodes.get(f.id)
	if fn != null:
		fn.data = f
		fn.apply_style()
		fn.invalidate_bounds()
	changed.emit()


func _on_item_added(it: Item) -> void:
	var fn: FrameNode = frame_nodes.get(it.frame)
	if fn != null:
		fn.add_view(it)
		fn.invalidate_bounds()


func _on_item_removed(it: Item) -> void:
	var fn: FrameNode = frame_nodes.get(it.frame)
	if fn != null:
		fn.remove_view(it.id)
		fn.invalidate_bounds()
	if selection.has(it.id):
		selection.erase(it.id)
		changed.emit()
	ink.forget(it.id)


func _on_item_changed(it: Item) -> void:
	var fn: FrameNode = frame_nodes.get(it.frame)
	if fn != null:
		fn.refresh_view(it)
		fn.invalidate_bounds()
	if selection.has(it.id):
		_dirty_overlay(it.frame)


func _on_setting(key: String) -> void:
	if key in ["grid", "grid_minor", "backing", "grid_focus"]:
		for fn in frame_nodes.values():
			(fn as FrameNode).apply_style()
	elif key in ["color", "width", "fill", "fill_alpha", "brush"] and not selection.is_empty() and str(App.val("tool")) == "select":
		apply_style_to_selection()
	if key == "tool" or key == "brush":
		changed.emit()


# ------------------------------------------------------------------------------------------------ rooms & anchors

## World pose of a room's anchor (null when the room is not here).
func room_world(room_id: String) -> Variant:
	if room_id == "" or doc == null:
		return null
	if anchors == null or not anchors.is_supported():
		return Transform3D.IDENTITY
	var r := doc.room(room_id)
	if r.is_empty():
		return null
	var a := str(r.anchor)
	if a != "" and anchors.has_pose(a):
		return _smooth("room:" + room_id, anchors.pose(a), 0.016)
	if a == "":
		return r.anchor_xf                    # made this session, its anchor is still being created
	return null


func _smooth(key: String, target: Transform3D, dt: float) -> Transform3D:
	if not _held.has(key):
		_held[key] = target
		return target
	var h: Transform3D = _held[key]
	var d := h.origin.distance_to(target.origin)
	var a := h.basis.get_rotation_quaternion().angle_to(target.basis.get_rotation_quaternion())
	if d > 0.15 or a > deg_to_rad(8.0):
		_held[key] = target
		return target
	if d < 0.0015 and a < deg_to_rad(0.12):
		return h
	h = h.interpolate_with(target, 1.0 - exp(-dt / 0.18))
	_held[key] = h
	return h


## World pose of a frame (without scale), or null while its place is not known.
func frame_world(f: FrameData, dt: float = 0.016) -> Variant:
	if grabs.has(f.id):
		return (grabs[f.id] as Dictionary).xf
	if anchors != null and anchors.is_supported() and f.anchor != "" and not f.anchor_stale() and anchors.has_pose(f.anchor):
		return _smooth("frame:" + f.id, anchors.pose(f.anchor), dt)
	var rw: Variant = room_world(f.room)
	if rw != null:
		return (rw as Transform3D) * f.xf
	return null


func _update_rooms(dt: float) -> void:
	if anchors == null or not anchors.is_supported():
		room_state = "unanchored"
		if doc.rooms.is_empty():
			create_room_here("My room", false)
		elif current_room == "" or doc.room(current_room).is_empty():
			current_room = str(doc.rooms[0].id)
			changed.emit()
		return
	var present: Array = []
	for r in doc.rooms:
		if str(r.anchor) == "" and r.id == current_room:
			present.append(r.id)                 # just created here, anchor pending
		elif str(r.anchor) != "" and anchors.has_pose(str(r.anchor)):
			present.append(r.id)
	var before := current_room
	var before_state := room_state
	if present.has(current_room):
		room_state = "found"
		_no_room_t = 0.0
	elif not present.is_empty():
		current_room = doc.last_room if present.has(doc.last_room) else str(present[0])
		room_state = "found"
		_no_room_t = 0.0
		doc.set_room_field(current_room, "used", int(Time.get_unix_time_from_system()))
		doc.last_room = current_room
	else:
		current_room = ""
		if doc.rooms.is_empty():
			room_state = "none"
			_room_auto_t += dt
			if _room_auto_t > 1.2:
				create_room_here("", true)          # a new document: the first room is made where you stand
		else:
			_no_room_t += dt
			room_state = "searching" if _no_room_t < ROOM_SEARCH_S else "needs_room"
	if before != current_room or before_state != room_state:
		changed.emit()


## Make a new room at the user's feet (the floor under the head), with its own anchor, and move into it.
func create_room_here(room_name: String = "", announce: bool = true) -> void:
	if doc == null:
		return
	var pose := Transform3D(Basis(Vector3.UP, _head_yaw()), Vector3(head.origin.x, 0.0, head.origin.z))
	var r := doc.add_room(room_name if room_name != "" else doc.next_room_name(), "", pose)
	current_room = r.id
	room_state = "found"
	_no_room_t = 0.0
	if anchors != null and anchors.is_supported():
		_pending["room:" + r.id] = true
		anchors.create(pose, "room:" + r.id)
	if announce:
		toast.emit("Room \"%s\" created here" % r.name)
	changed.emit()


func _head_yaw() -> float:
	var f := -head.basis.z
	return atan2(-f.x, -f.z)


func select_room(room_id: String) -> void:
	## Manually declare which room this is (when the anchors cannot be found): the room's frames are then placed by its remembered pose.
	if doc == null or doc.room(room_id).is_empty():
		return
	current_room = room_id
	room_state = "found"
	doc.last_room = room_id
	changed.emit()


func delete_room(room_id: String) -> void:
	if doc == null:
		return
	var erase: Array = doc.remove_room(room_id)
	for a in erase:
		anchors.untrack(a)
		anchors.erase(a)
	if current_room == room_id:
		current_room = ""
	changed.emit()


func rename_room(room_id: String, new_name: String) -> void:
	if new_name.strip_edges() != "":
		doc.set_room_field(room_id, "name", new_name.strip_edges())
		changed.emit()


## Re-create the current room's anchor at the user's feet (when the old one was lost, e.g. after a Space Setup reset).
func reanchor_room() -> void:
	if doc == null or current_room == "":
		return
	var old := str(doc.room(current_room).anchor)
	var yaw := _head_yaw()
	var pose := Transform3D(Basis(Vector3.UP, yaw), Vector3(head.origin.x, 0.0, head.origin.z))
	doc.set_room_field(current_room, "anchor", "")
	doc.set_room_field(current_room, "anchor_xf", pose)
	if old != "":
		anchors.untrack(old)
		anchors.erase(old)
	if anchors.is_supported():
		_pending["room:" + current_room] = true
		anchors.create(pose, "room:" + current_room)
	toast.emit("Room anchor re-created here. Frames keep their place relative to the old room origin.")


func _on_anchor_created(tag: String, uuid: String) -> void:
	_pending.erase(tag)
	var parts := tag.split(":")
	if doc == null or parts.size() < 2:
		anchors.erase(uuid)
		return
	if parts[0] == "room":
		if doc.room(parts[1]).is_empty():
			anchors.erase(uuid)
			return
		doc.set_room_field(parts[1], "anchor", uuid)
	elif parts[0] == "frame":
		var f: FrameData = doc.frames.get(parts[1])
		if f == null:
			anchors.erase(uuid)
			return
		var old := f.anchor
		var upd := f.copy()
		upd.anchor = uuid
		upd.anchor_xf = _pending_pose.get(tag, f.xf)
		doc.replace_frame(upd)
		_pending_pose.erase(tag)
		_held.erase("frame:" + f.id)
		if old != "" and old != uuid:
			anchors.untrack(old)
			anchors.erase(old)


func _on_anchor_failed(tag: String) -> void:
	_pending.erase(tag)
	_pending_pose.erase(tag)
	toast.emit("Could not create a spatial anchor. Is the Space Setup done for this room?")


## Frames whose pose differs from the one their anchor was made at (or that have none) get a new anchor at their current place.
func _reconcile(dt: float) -> void:
	_reconcile_t += dt
	if _reconcile_t < RECONCILE_S:
		return
	_reconcile_t = 0.0
	if anchors == null or not anchors.is_supported() or room_state != "found" or current_room == "":
		return
	var r := doc.room(current_room)
	if r.is_empty():
		return
	if str(r.anchor) != "" and not anchors.has_pose(str(r.anchor)):
		return
	for f in doc.frames_in(current_room):
		var fd: FrameData = f
		var tag := "frame:" + fd.id
		# an anchor that never gets a pose although the room is here has been lost (the headset's space map was reset): make a new one
		if fd.anchor != "" and not anchors.has_pose(fd.anchor):
			_lost_t[fd.id] = float(_lost_t.get(fd.id, 0.0)) + RECONCILE_S
			if float(_lost_t[fd.id]) > ANCHOR_LOST_S and not _pending.has(tag):
				var lost := fd.copy()
				lost.anchor = ""
				doc.replace_frame(lost)
				_lost_t.erase(fd.id)
				fd = lost
		else:
			_lost_t.erase(fd.id)
		if grabs.has(fd.id) or _pending.has(tag) or not fd.anchor_stale():
			continue
		var w: Variant = frame_world(fd)
		if w == null:
			continue
		var pose := Transform3D((w as Transform3D).basis.orthonormalized(), (w as Transform3D).origin)
		_pending[tag] = true
		_pending_pose[tag] = fd.xf
		anchors.create(pose, tag)


# ------------------------------------------------------------------------------------------------ frames

## Place every frame node from its anchor / room pose and show only the frames of the room we are in.
func _place_frames(dt: float) -> void:
	for fid in frame_nodes.keys():
		var fn: FrameNode = frame_nodes[fid]
		var f := fn.data
		var show := (f.room == current_room or room_state == "unanchored") and room_state != "searching" and room_state != "needs_room"
		var w: Variant = frame_world(f, dt) if show else null
		fn.visible = show and w != null
		if fn.visible:
			var xf := w as Transform3D
			var sc: float = (grabs[fid] as Dictionary).scale if grabs.has(fid) else f.scale
			fn.transform = Transform3D(xf.basis.orthonormalized().scaled(Vector3.ONE * sc), xf.origin)


func visible_frames(kind: String = "") -> Array:
	var out: Array = []
	for fn in frame_nodes.values():
		var n := fn as FrameNode
		if n.visible and (kind == "" or n.data.kind == kind):
			out.append(n)
	return out


## The canvas the pen is working on: the nearest canvas within `reach` metres of the tip (in front of or behind it) whose extent
## (grown by `slack` so drawing past the edge extends it) contains the tip. {fn, local, dist} or {}.
func pen_target(tip: Vector3, reach: float = CAPTURE, slack: float = 0.6) -> Dictionary:
	var best := {}
	var bd := INF
	for fn in visible_frames(FrameData.CANVAS):
		var n := fn as FrameNode
		if n.data.locked:
			continue
		var l := n.to_local_point(tip)
		var dz := absf(l.z) * n.data.scale
		if dz > reach:
			continue
		if not n.bounds().grow(slack / n.data.scale).has_point(Vector2(l.x, l.y)):
			continue
		if dz < bd:
			bd = dz
			best = {"fn": n, "local": l, "dist": dz}
	return best


## The frame a hand's pinch grabs: a canvas whose plane is within reach and whose extent contains the point, or a 3D sketch
## whose box is near. {fn, local, corner (index or -1)} or {}.
func pick_frame(p: Vector3) -> Dictionary:
	var best := {}
	var bd := INF
	for fn in visible_frames():
		var n := fn as FrameNode
		var l := n.to_local_point(p)
		var s := n.data.scale
		var d := INF
		var corner := -1
		if n.is_canvas:
			var dz := absf(l.z) * s
			var b := n.bounds()
			if dz > 0.09 or not b.grow(0.05 / s).has_point(Vector2(l.x, l.y)):
				continue
			d = dz
			var cs: Array = [b.position, Vector2(b.end.x, b.position.y), b.end, Vector2(b.position.x, b.end.y)]
			for i in 4:
				if (cs[i] as Vector2).distance_to(Vector2(l.x, l.y)) * s < 0.07:
					corner = i
		else:
			var cb := n.content_bounds()
			if cb.size == Vector2.ZERO:
				cb = Rect2(Vector2(-0.06, -0.06), Vector2(0.12, 0.12))
			var box := cb.grow(0.07 / s)
			var dz2 := absf(l.z) * s
			if dz2 > 0.35 or not box.has_point(Vector2(l.x, l.y)):
				continue
			d = 0.0 if dz2 < 0.12 else dz2
		if d < bd:
			bd = d
			best = {"fn": n, "local": l, "corner": corner}
	return best


func begin_grab(f: FrameData) -> void:
	if grabs.has(f.id) or f.locked:
		return
	var w: Variant = frame_world(f)
	if w == null:
		return
	grabs[f.id] = {"xf": w, "scale": f.scale, "before": f.copy()}
	_dirty_overlay(f.id)


func end_grab(f: FrameData) -> void:
	if not grabs.has(f.id):
		return
	var g: Dictionary = grabs[f.id]
	var rw: Variant = room_world(f.room)
	var after := f.copy()
	var xf := g.xf as Transform3D
	after.xf = (rw as Transform3D).affine_inverse() * xf if rw != null else xf
	after.scale = clampf(float(g.scale), 0.15, 8.0)
	grabs.erase(f.id)
	_held.erase("frame:" + f.id)
	var before: FrameData = g.before
	history.do(History.op_frame(before, after))     # applies `after`: the anchor is then re-created at the new place by _reconcile()
	_dirty_overlay(f.id)


func add_frame(kind: String, world_xf: Transform3D, size: Vector2 = Vector2(1.2, 0.8)) -> FrameData:
	if doc == null:
		return null
	if current_room == "":
		create_room_here("", false)
	var rw: Variant = room_world(current_room)
	var f := FrameData.make(kind, current_room, (rw as Transform3D).affine_inverse() * world_xf if rw != null else world_xf)
	f.size = size
	history.do(History.op_frame_add(f))
	var made: FrameData = doc.frames.get(f.id)
	if kind == FrameData.CANVAS:
		active_frame = f.id
	changed.emit()
	return made


func delete_frame(frame_id: String) -> void:
	var f: FrameData = doc.frames.get(frame_id)
	if f == null:
		return
	var items := doc.items_of(frame_id)
	var old_anchor := f.anchor
	history.do(History.op_frame_remove(f, items))
	# the anchor is erased from the device only when the deletion can no longer be undone: keep it until the document is closed
	if old_anchor != "":
		_orphans.append(old_anchor)
	changed.emit()


func rename_frame(frame_id: String, new_name: String) -> void:
	var f: FrameData = doc.frames.get(frame_id)
	if f != null and new_name.strip_edges() != "":
		var upd := f.copy()
		upd.name = new_name.strip_edges()
		history.do(History.op_frame(f, upd))


func set_frame_prop(frame_id: String, key: String, value: Variant) -> void:
	var f: FrameData = doc.frames.get(frame_id)
	if f == null:
		return
	var upd := f.copy()
	upd.set(key, value)
	history.do(History.op_frame(f, upd))


func clear_frame(frame_id: String) -> void:
	var items := doc.items_of(frame_id)
	if items.is_empty():
		return
	history.do(History.op_remove(items))
	toast.emit("Canvas cleared (undo brings it back)")


func active_volume() -> FrameNode:
	if volume_id != "" and frame_nodes.has(volume_id) and (frame_nodes[volume_id] as FrameNode).data.room == current_room:
		return frame_nodes[volume_id]
	for fn in frame_nodes.values():
		var n := fn as FrameNode
		if n.data.kind == FrameData.VOLUME and n.data.room == current_room:
			volume_id = n.data.id
			return n
	return null


## A new 3D sketch at a world position (air strokes then go into it).
func new_volume_at(world_pos: Vector3) -> FrameNode:
	var f := add_frame(FrameData.VOLUME, Transform3D(Basis(Vector3.UP, _head_yaw()), world_pos))
	if f == null:
		return null
	volume_id = f.id
	return frame_nodes.get(f.id)


# ------------------------------------------------------------------------------------------------ canvas placement

## Start placing a new canvas: a ghost follows the pen / hand ray until it is confirmed (kind: "wall" | "table").
func begin_place(kind: String = "wall", size: Vector2 = Vector2(1.2, 0.8)) -> void:
	cancel_place()
	var tmp := Document.create("ghost")
	var gf := FrameData.make(FrameData.CANVAS, "", Transform3D.IDENTITY, "")
	gf.size = size
	var ghost := FrameNode.new()
	add_child(ghost)
	ghost.setup(gf, tmp)
	ghost.set_hover(1.0)
	placing = {"kind": kind, "ghost": ghost, "size": size, "tmp": tmp}
	toast.emit("Point where the canvas goes, then tap with the stylus or pinch to place it.")
	changed.emit()


func cancel_place() -> void:
	if placing.is_empty():
		return
	(placing.ghost as Node).queue_free()
	placing = {}
	changed.emit()


func confirm_place() -> void:
	if placing.is_empty():
		return
	var ghost := placing.ghost as FrameNode
	var xf := Transform3D(ghost.transform.basis.orthonormalized(), ghost.transform.origin)
	var size: Vector2 = placing.size
	cancel_place()
	var f := add_frame(FrameData.CANVAS, xf, size)
	if f != null:
		toast.emit("Canvas \"%s\" placed" % f.name)


## Pose of a canvas that would be placed along a ray: standing upright facing the user, or lying flat on a table.
func placement_pose(origin: Vector3, dir: Vector3, kind: String) -> Transform3D:
	var hit := {}
	if surface_hit.is_valid():
		hit = surface_hit.call(origin, dir)
	var to_head := head.origin
	if not hit.is_empty():
		var n: Vector3 = hit.normal
		var p: Vector3 = hit.point
		if n.dot(to_head - p) < 0.0:
			n = -n
		var up := Vector3.UP
		var yb: Vector3
		if absf(n.dot(up)) > 0.85:
			var away := Vector3(p.x - to_head.x, 0, p.z - to_head.z).normalized()
			yb = away
		else:
			yb = (up - n * n.dot(up)).normalized()
		var xb := yb.cross(n).normalized()
		return Transform3D(Basis(xb, yb, n), p + n * 0.003)
	var point := origin + dir.normalized() * 0.85
	if kind == "table":
		point.y = clampf(point.y, 0.2, 1.4)
		var flat_y := (Vector3(point.x - to_head.x, 0, point.z - to_head.z)).normalized()
		if flat_y.length() < 0.1:
			flat_y = Vector3.FORWARD
		return Transform3D(Basis(flat_y.cross(Vector3.UP).normalized() * -1.0, flat_y, Vector3.UP).orthonormalized(), point)
	point.y = clampf(point.y, 0.7, 1.9)
	var yaw := atan2(to_head.x - point.x, to_head.z - point.z)
	return Transform3D(Basis(Vector3.UP, yaw), point)


func _update_placing(pen: PenState, hands: Array, _dt: float) -> void:
	var ghost := placing.ghost as FrameNode
	var o := Vector3.ZERO
	var d := Vector3.FORWARD
	var have := false
	if pen.tracked and pen.source != "none":
		o = pen.tip
		d = pen.dir
		have = true
	else:
		for h in hands:
			var hi := h as HandInput
			if hi.tracked and hi.aiming:
				o = hi.aim_o
				d = hi.aim_d
				have = true
				break
	if have:
		var xf := placement_pose(o, d, placing.kind)
		ghost.transform = xf
	ghost.visible = have or ghost.visible
	var confirm := false
	if pen.tracked and pen.down and not _was_down:
		confirm = true
	for h in hands:
		if (h as HandInput).pinch_down:
			confirm = true
	_was_down = pen.down
	if pen.back and not _was_back:
		cancel_place()
		return
	_was_back = pen.back
	if confirm and have:
		confirm_place()


# ------------------------------------------------------------------------------------------------ selection and editing

func select_items(ids: Array, frame_id: String) -> void:
	var old := sel_frame
	selection = ids.duplicate()
	sel_frame = frame_id if not ids.is_empty() else ""
	if old != "":
		_dirty_overlay(old)
	if sel_frame != "":
		_dirty_overlay(sel_frame)
		active_frame = sel_frame if (doc.frames.get(sel_frame) as FrameData).kind == FrameData.CANVAS else active_frame
	changed.emit()


func clear_selection() -> void:
	select_items([], "")


func selected_items() -> Array:
	var out: Array = []
	for id in selection:
		if doc.items.has(id):
			out.append(doc.items[id])
	return out


func delete_selection() -> void:
	var items := selected_items()
	if items.is_empty():
		return
	history.begin_group()
	_release_glue_to(items)
	history.do(History.op_remove(items))
	history.end_group()
	clear_selection()


func duplicate_selection() -> void:
	var items := selected_items()
	if items.is_empty():
		return
	var copies: Array = []
	var ids: Array = []
	var map := {}
	for it in items:
		var c := (it as Item).duplicate_item()
		map[it.id] = c.id
		c.z = 0
		if (doc.frames[c.frame] as FrameData).kind == FrameData.VOLUME:
			c.apply_xform3(Transform3D(Basis.IDENTITY, Vector3(0.04, -0.04, 0.0)))
		else:
			c.apply_xform(Transform2D(0.0, Vector2(0.04, -0.04)))
		copies.append(c)
		ids.append(c.id)
	for c in copies:                              # connectors between duplicated shapes follow the copies
		if (c as Item).is_line():
			for key in ["glue_a", "glue_b"]:
				var g: Dictionary = c.get(key)
				if not g.is_empty():
					if map.has(g.item):
						g.item = map[g.item]
					else:
						c.set(key, {})
	history.do(History.op_add(copies))
	select_items(ids, sel_frame)


## Apply the current pen settings (colour, width, fill, brush) to the selected items.
func apply_style_to_selection() -> void:
	var items := selected_items()
	if items.is_empty():
		return
	var before: Array = []
	var after: Array = []
	for it in items:
		var item: Item = it
		before.append(item.duplicate_item(false))
		var c := item.duplicate_item(false)
		var col: Color = App.val("color")
		c.color = Color(col.r, col.g, col.b, c.color.a if c.kind != Item.TEXT else 1.0)
		if c.kind == Item.SHAPE:
			c.width = float(App.val("width"))
			if not c.is_line():
				var fc := col
				c.fill = Color(fc.r, fc.g, fc.b, float(App.val("fill_alpha"))) if bool(App.val("fill")) else Color(0, 0, 0, 0)
		elif c.kind == Item.STROKE:
			c.width = float(App.val("width"))
			c.brush = str(App.val("brush"))
		after.append(c)
	history.do(History.op_modify(before, after))


func bring_to_front() -> void:
	_reorder(true)


func send_to_back() -> void:
	_reorder(false)


func _reorder(front: bool) -> void:
	var items := selected_items()
	if items.is_empty():
		return
	items.sort_custom(func(a, b): return a.z < b.z)
	var before: Array = []
	var after: Array = []
	var lo := 0
	for it in doc.items.values():
		lo = mini(lo, (it as Item).z)
	for i in items.size():
		var it: Item = items[i]
		before.append(it.duplicate_item(false))
		var c := it.duplicate_item(false)
		c.z = doc.top_z() if front else lo - items.size() + i
		after.append(c)
	history.do(History.op_modify(before, after))


func undo() -> void:
	if history != null and history.undo():
		_after_history()


func redo() -> void:
	if history != null and history.redo():
		_after_history()


func _after_history() -> void:
	var keep: Array = []
	for id in selection:
		if doc.items.has(id):
			keep.append(id)
	if keep.size() != selection.size():
		select_items(keep, sel_frame)


# ------------------------------------------------------------------------------------------------ shapes and connectors

## A shape item for a recognised stroke or a stencil, in the pen's style.
func make_shape(frame_id: String, rec: Dictionary) -> Item:
	var col: Color = App.val("color")
	var it := Item.make_shape(frame_id, str(rec.shape), col, clampf(float(App.val("width")) * 1.0, 0.0015, 0.03), "pen")
	it.width = maxf(it.width, 0.003)
	if str(App.val("brush")) == "dashed":
		it.brush = "dashed"
	match str(rec.shape):
		"line", "arrow", "darrow", "elbow":
			it.a = rec.a
			it.b = rec.b
			it.head_b = bool(rec.get("head_b", false)) or str(rec.shape) in ["arrow", "darrow", "elbow"]
			it.head_a = bool(rec.get("head_a", false))
			if str(rec.shape) == "line" and it.head_b:
				it.shape = "arrow"
			snap_line_ends(it)
		"poly":
			it.poly = rec.poly
			it.fill = _fill_color(col)
		_:
			it.center = rec.center
			it.size = rec.size
			it.rot = float(rec.get("rot", 0.0))
			it.fill = _fill_color(col)
	return it


func _fill_color(col: Color) -> Color:
	return Color(col.r, col.g, col.b, float(App.val("fill_alpha"))) if bool(App.val("fill")) else Color(0, 0, 0, 0)


## Stick the ends of a line to nearby shape ports (flow-diagram connectors).
func snap_line_ends(line: Item, exclude: String = "") -> void:
	if not bool(App.val("snap_connectors")):
		return
	for end in ["a", "b"]:
		var p: Vector2 = line.get(end)
		var best := {"dist": 0.05}
		var best_item: Item = null
		for it in doc.items_of(line.frame):
			var item: Item = it
			if item.kind != Item.SHAPE or item.is_line() or item.id == exclude or item.shape == "poly":
				continue
			var np := Shapes.nearest_port(item, p)
			if np.idx >= 0 and float(np.dist) < float(best.dist):
				best = np
				best_item = item
		var glue_key: String = "glue_" + end
		var n_key: String = "n" + end
		if best_item != null:
			line.set(end, best.pos)
			line.set(glue_key, {"item": best_item.id, "port": best.idx})
			line.set(n_key, best.n)
		else:
			line.set(glue_key, {})
			line.set(n_key, Vector2.ZERO)


## Re-aim connectors whose glued shapes were moved, resized or rotated; records the change in the history.
func follow_connectors(shape_ids: Array, frame_id: String) -> void:
	var before: Array = []
	var after: Array = []
	for it in doc.items_of(frame_id):
		var line: Item = it
		if not line.is_line():
			continue
		var touched := false
		var c := line.duplicate_item(false)
		for end in ["a", "b"]:
			var g: Dictionary = c.get("glue_" + end)
			if g.is_empty():
				continue
			if not shape_ids.has(g.item):
				continue
			if not doc.items.has(g.item):
				c.set("glue_" + end, {})
				touched = true
				continue
			var pw := Shapes.port_world(doc.items[g.item], int(g.port))
			c.set(end, pw.pos)
			c.set("n" + end, pw.n)
			touched = true
		if touched:
			before.append(line.duplicate_item(false))
			after.append(c)
	if not before.is_empty():
		history.do(History.op_modify(before, after))


func _release_glue_to(removed: Array) -> void:
	var ids: Array = []
	for it in removed:
		ids.append((it as Item).id)
	var before: Array = []
	var after: Array = []
	var frames := {}
	for it in removed:
		frames[(it as Item).frame] = true
	for fid in frames.keys():
		for it in doc.items_of(fid):
			var line: Item = it
			if not line.is_line() or ids.has(line.id):
				continue
			var c := line.duplicate_item(false)
			var touched := false
			for end in ["a", "b"]:
				var g: Dictionary = c.get("glue_" + end)
				if not g.is_empty() and ids.has(g.item):
					c.set("glue_" + end, {})
					c.set("n" + end, Vector2.ZERO)
					touched = true
			if touched:
				before.append(line.duplicate_item(false))
				after.append(c)
	if not before.is_empty():
		history.do(History.op_modify(before, after))


# ------------------------------------------------------------------------------------------------ per-frame update

## Called every frame by the rig with the pen, the hands that are not busy with a menu, and the head pose.
func tick(pen: PenState, hands: Array, dt: float) -> void:
	if doc == null:
		return
	if head_provider.is_valid():
		head = head_provider.call()
	_update_rooms(dt)
	_place_frames(dt)
	_reconcile(dt)
	if not placing.is_empty():
		_update_placing(pen, hands, dt)
	else:
		pen_ctl.update(pen, dt)
		hand_ctl.update(hands, dt)
	_update_hover(pen, hands, dt)
	ink.update(dt)
	if _save_due >= 0.0:
		_save_due -= dt
		if _save_due < 0.0:
			_save_due = 0.0
			flush_save()


func _update_hover(pen: PenState, hands: Array, dt: float) -> void:
	var pointers: Array = []
	if pen.tracked:
		pointers.append(pen.tip)
	for h in hands:
		if (h as HandInput).tracked:
			pointers.append((h as HandInput).tip)
	var gaze_o := head.origin
	var gaze_d := -head.basis.z
	for fn_any in frame_nodes.values():
		var fn := fn_any as FrameNode
		if not fn.visible:
			continue
		var s := fn.data.scale
		var target := 0.0
		var focus := Vector3.ZERO
		var have_focus := false
		var near_pen := 0.0
		for p in pointers:
			var l := fn.to_local_point(p)
			var dz := absf(l.z) * s
			if fn.is_canvas:
				var b := fn.bounds().grow(0.3 / s)
				if b.has_point(Vector2(l.x, l.y)) and dz < HOVER_RANGE:
					var pr := 1.0 - clampf(dz / HOVER_RANGE, 0.0, 1.0)
					if pr > near_pen:
						near_pen = pr
						focus = Vector3(l.x, l.y, 0.0)
						have_focus = true
			else:
				var box := fn.content_bounds().grow(0.3)
				if box.has_point(Vector2(l.x, l.y)) and dz < 0.5:
					near_pen = maxf(near_pen, 1.0 - clampf(dz / 0.5, 0.0, 1.0))
		target = near_pen
		var lh := fn.to_local_point(gaze_o)
		var head_dist := absf(lh.z) * s
		if not have_focus and fn.is_canvas:
			var ld := fn.global_transform.basis.inverse() * gaze_d
			if absf(ld.z) > 0.05:
				var t := -lh.z / ld.z
				if t > 0.0:
					var g := lh + ld * t
					focus = Vector3(g.x, g.y, 0.0)
					have_focus = true
		if not have_focus:
			focus = Vector3(lh.x, lh.y, 0.0)
		var fade_r := float(App.val("grid_fade_viewer"))
		var va := 1.0 - smoothstep(fade_r * 0.55, fade_r, head_dist)
		fn.set_focus(focus, va)
		var gaze_target := 0.0
		if fn.is_canvas and have_focus and fn.bounds().grow(0.05).has_point(Vector2(focus.x, focus.y)):
			gaze_target = 0.18 * va
		fn.set_hover(lerpf(fn.hover, maxf(target, gaze_target), 1.0 - exp(-dt * 9.0)))
		if grabs.has(fn.data.id):
			fn.set_hover(1.0)


# ------------------------------------------------------------------------------------------------ overlay

func _dirty_overlay(frame_id: String) -> void:
	var fn: FrameNode = frame_nodes.get(frame_id)
	if fn == null:
		return
	if not _overlay_cb.has(frame_id):
		_overlay_cb[frame_id] = _draw_overlay.bind(frame_id)
	fn.set_overlay(_overlay_cb[frame_id])


func refresh_overlays() -> void:
	## Pen cursor, selection handles, lasso: redrawn every frame for the frames they are on.
	var active := {}
	if sel_frame != "":
		active[sel_frame] = true
	if pen_ctl.cursor_frame != "":
		active[pen_ctl.cursor_frame] = true
	for fid in active.keys():
		_dirty_overlay(fid)
		var fn: FrameNode = frame_nodes.get(fid)
		if fn != null:
			fn.mark_overlay_dirty()
	for fid in _overlay_cb.keys():
		if not active.has(fid) and frame_nodes.has(fid):
			var fn2: FrameNode = frame_nodes[fid]
			fn2.set_overlay(Callable())
			_overlay_cb.erase(fid)
			break


func _draw_overlay(od: OverlayDraw, frame_id: String) -> void:
	var fn: FrameNode = frame_nodes.get(frame_id)
	if fn == null:
		return
	pen_ctl.draw_overlay(od, fn)


func _process(_delta: float) -> void:
	if doc != null:
		refresh_overlays()
		pen_ctl.flush_live()
