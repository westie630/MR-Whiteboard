class_name Board
extends Node3D
## The whiteboard world. It owns the open Document, one FrameNode per canvas (or 3D sketch) and one ModelNode per 3D model, the rooms and
## spatial anchors that keep every frame fixed in the real room, the selection, and the pen / hand / model controllers that edit the document.
## A rig (headset or PC) feeds it the pen and hand state each frame through tick().

signal toast(text: String)
signal changed()                           # tool, selection, room or document state changed: the UI refreshes
signal document_opened()

const ROOM_SEARCH_S := 10.0                # how long to look for a known room (with the headset on) before showing the last one in front of the user
const ROOM_HOLD_S := 2.0                   # a room whose anchors drop out for less than this (the headset re-localising) stays where it was
const ROOM_PICK_S := 3.0                   # after the start (or the headset put back on) the room shown may still change this long (see _pick_room)...
const ROOM_NEARER_M := 0.5                 # ...to a room the user is at least this much nearer to
const REACH_DIST := 0.6                    # metres in front of the eyes where a canvas is put to be drawn on (arm's length)
const DESK_DIST := 0.45                    # ...and along the floor where a canvas lying flat is put (on a desk in front of you)
const RECONCILE_S := 0.6
const ANCHOR_LOST_S := 14.0                # a frame anchor without a pose for this long, in a room that is here, is considered lost
const REFRESH_M := 0.01                    # a canvas's place in its room is corrected from its own anchor when they disagree by more than this...
const REFRESH_DEG := 0.5                   # ...or this
const AGREE_M := 0.05                      # anchors that put a room within this of each other agree on where it is
const RETRY_MIN_S := 3.0                   # an anchor that could not be made is tried again after this, doubling up to RETRY_MAX_S
const RETRY_MAX_S := 60.0
const AUTOSAVE_S := 1.5
const CAPTURE := InputTuning.CAPTURE       # a pen this close (m) to a canvas draws on it
const HOVER_RANGE := InputTuning.HOVER_RANGE

var doc: Document
var history: History
var anchors: AnchorService
var head_provider := Callable()            # -> Transform3D, the head in world space
var surface_hit := Callable()              # (origin, dir) -> {point, normal} for real surfaces (Meta scene walls and tables), optional

var current_room := ""
var room_state := "none"                   # none | searching | found | assumed (anchors not found: shown in front) | unanchored
## False while the headset is off or its session is not running (set by the XR rig): anchors have no pose then, and that is not a
## reason to give up on the room.
var tracking_live := true
var last_pen: PenState                     # the pen of the latest tick (the PC's mouse pen)
var stylus_pen: PenState                   # in the headset: the real stylus, which `last_pen` is not while a menu holds it or it is missing
var _assumed := {}                         # room id -> world pose it is shown at while its anchors are not found
var _located := {}                         # room id -> world pose from its anchors this tick (or held through a short dropout)
var _located_by := {}                      # room id -> "room" (its own anchor) | "frame" (a canvas's anchor) | "hold"
var _last_world := {}                      # room id -> {xf, age}: the last pose its anchors gave
var _moved_unanchored := {}                # frame id -> true: put somewhere while its room was only assumed; it gets its own anchor there
var _retry_at := {}                        # anchor tag -> msec before which it is not tried again (after a failure)
var _fails := {}                           # anchor tag -> failures in a row
var _fail_toast_ms := -100000
var frame_nodes: Dictionary = {}           # frame id -> FrameNode
var model_nodes: Dictionary = {}           # frame id -> ModelNode (the frames of kind "model")
var active_frame := ""                     # the canvas last drawn on / selected: the one Home > Canvases styles
var selection: Array = []                  # selected item ids (all on sel_frame)
var sel_frame := ""
## Where the selection's undo / redo / delete buttons were when the selection went away through a delete, undo or redo: {frame, rect,
## serial}. The undo and redo buttons stay there until something new is done, so a delete can be taken back with them.
var bar_ghost: Dictionary = {}
var stencil := "rect"
var placing: Dictionary = {}               # canvas placement in progress: {kind, ghost, size}
var placing_text: Dictionary = {}          # text placement in progress: {text, wrap, frame, item (the ghost), center}; see begin_place_text()
var grabs: Dictionary = {}                 # frame id -> {xf: Transform3D (world), scale: float} while a hand holds it
var remote_grabs: Dictionary = {}          # frame id -> {xf: Transform3D (in its room), scale} while somebody else of the session carries it (LivePreview)
var pen_ctl: PenController
var hand_ctl: HandController
var ink: InkController
var speech: SpeechController
var texts: TextController
var ai: AiController                       # the AI assistant (ask a language model about a canvas; its suggestion layers)
var surface: SurfaceController             # the desk: canvases bound to a physical surface found with the stylus nib
var share: ExportServer                   # the web server that lets a PC browser view / download the canvases (off until switched on)
var pdfs: PdfLibrary                      # the PDFs on this device, and the pages made from them (canvases that show a PDF ask it)
var models: ModelLibrary                  # the 3D models on this device (glTF, OBJ), loaded for the model frames that show them
var model_ctl: ModelController             # what the pointers do to 3D models: select, carry, the gizmo's handles
var lighting: ModelLighting                # the light the 3D models are seen in
var session: Session                       # a session: this headset hosting one (the owner) or in one (a guest); see Session
var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))

var _import_time := -100000                # when a canvas was last added from the web page, and where its right edge is (metres along the viewer's right)
var _import_right := 0.0
var _held: Dictionary = {}                 # pose smoothing per anchor
var _pending: Dictionary = {}              # anchor creations in flight (tag -> true)
var _no_room_t := 0.0
var _reconcile_t := 0.0
var _save_due := -1.0
var _room_auto_t := 0.0
var _picking := true                       # the board is still choosing which of the rooms found the user is in (see _pick_room)
var _pick_t := 0.0
var _overlay_cb: Dictionary = {}
var _lost_t: Dictionary = {}
var _pending_pose: Dictionary = {}
var _pending_guess: Dictionary = {}        # anchor tag -> true when it is made while the room's place is only guessed
var _orphans: Array = []
var _was_down := false
var _was_back := false
var _denied_t := -100000                   # when the guest was last told that editing is off (ticks, ms)


func _init() -> void:
	name = "Board"
	pen_ctl = PenController.new(self)
	hand_ctl = HandController.new(self)
	ink = InkController.new(self)
	speech = SpeechController.new(self)
	texts = TextController.new(self)
	ai = AiController.new(self)
	surface = SurfaceController.new(self)
	pdfs = PdfLibrary.new()
	pdfs.name = "Pdfs"
	pdfs.dir = App.pdf_dir
	pdfs.budget = PdfBudget.for_tier(PdfBudget.detect_tier(str(App.val("pdf_tier"))))
	pdfs.page_ready.connect(_on_pdf_page)
	pdfs.page_failed.connect(_on_pdf_failed)
	pdfs.changed.connect(_on_pdfs_changed)
	pdfs.progress_changed.connect(func(_id): _on_pdfs_changed())
	add_child(pdfs)
	models = ModelLibrary.new()
	models.name = "Models"
	models.dir = App.model_dir
	models.budget = ModelBudget.for_tier(ModelBudget.detect_tier(str(App.val("model_tier"))))
	models.model_ready.connect(_on_model_ready)
	models.model_failed.connect(_on_model_failed)
	models.changed.connect(_on_models_changed)
	models.progress_changed.connect(func(_id): _on_models_changed())
	add_child(models)
	model_ctl = ModelController.new(self)
	add_child(model_ctl.gizmo)
	lighting = ModelLighting.new()
	add_child(lighting)
	share = ExportServer.new()
	share.name = "Share"
	share.doc_source = func(): return doc
	share.room_source = func(): return current_room
	share.active_source = func(): return active_frame
	share.backing_source = func(): return App.val("backing")
	share.delete_canvas = _web_delete
	share.rename_canvas = rename_frame
	share.import_svg = import_svg
	share.pdf_library = pdfs
	share.show_pdf = place_pdf
	share.model_library = models
	share.show_model = place_model
	share.ai_api = func(cmd: String, data: Dictionary) -> Dictionary: return ai.api(cmd, data)
	share.keys_api = func(cmd: String, data: Dictionary) -> Dictionary: return ApiKeys.new(ai).api(cmd, data)
	share.state_changed.connect(func(): changed.emit())
	add_child(share)
	session = Session.new()
	session.board = self
	session.said.connect(func(t: String): toast.emit(t))
	session.changed.connect(_on_session_changed)
	add_child(session)


func setup(anchor_service: AnchorService) -> void:
	anchors = anchor_service
	anchors.created.connect(_on_anchor_created)
	anchors.create_failed.connect(_on_anchor_failed)
	session.bind(anchors)
	App.setting_changed.connect(_on_setting)


# ------------------------------------------------------------------------------------------------ documents

func open(d: Document) -> void:
	if session.role == Session.Role.CLIENT and d != session.client_doc and not session.opening:
		session.leave(true, false)                 # a guest who opens a document of their own has left the session
	close_document()
	doc = d
	history = History.new(d)
	history.read_only = not can_edit()
	history.refused.connect(deny_edit)
	history.changed.connect(func(): changed.emit())
	doc.item_added.connect(_on_item_added)
	doc.item_removed.connect(_on_item_removed)
	doc.item_changed.connect(_on_item_changed)
	doc.frame_added.connect(_on_frame_added)
	doc.frame_removed.connect(_on_frame_removed)
	doc.frame_changed.connect(_on_frame_changed)
	doc.changed.connect(_on_doc_changed)
	for f in doc.frames.values():
		if (f as FrameData).is_model():
			_make_model_node(f)
		else:
			_make_frame_node(f)
	current_room = ""
	room_state = "searching" if not doc.rooms.is_empty() else "none"
	_assumed.clear()
	_located.clear()
	_located_by.clear()
	_last_world.clear()
	_moved_unanchored.clear()
	_retry_at.clear()
	_fails.clear()
	_no_room_t = 0.0
	_room_auto_t = 0.0
	_picking = true
	_pick_t = 0.0
	selection.clear()
	sel_frame = ""
	active_frame = ""
	if anchors != null:
		anchors.track(DocStore.anchors_of(doc))
	if not doc.transient:
		App.put("last_doc", doc.id)
	ai.open_doc()
	document_opened.emit()
	changed.emit()


func close_document() -> void:
	if doc == null:
		return
	flush_save()
	# the document's anchors stay tracked: going back to it later finds its room at once instead of searching again
	for fn in frame_nodes.values():
		(fn as Node).queue_free()
	frame_nodes.clear()
	model_ctl.reset()
	for mn in model_nodes.values():
		(mn as Node).queue_free()
	model_nodes.clear()
	grabs.clear()
	remote_grabs.clear()
	_held.clear()
	_pending.clear()
	_pending_pose.clear()
	_pending_guess.clear()
	ink.reset()
	cancel_place()
	surface.reset()
	_disconnect_doc()
	ai.close_doc()
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
	fn.pdfs = pdfs
	add_child(fn)
	fn.setup(f, doc)
	fn.visible = false
	frame_nodes[f.id] = fn
	return fn


func _make_model_node(f: FrameData) -> ModelNode:
	var mn := ModelNode.new()
	model_nodes[f.id] = mn
	mn.measured.connect(_on_model_measured)
	add_child(mn)
	mn.visible = false
	mn.setup(f, models)
	return mn


func _on_frame_added(f: FrameData) -> void:
	if f.is_model():
		if not model_nodes.has(f.id):
			_make_model_node(f)
		changed.emit()
		return
	if not frame_nodes.has(f.id):
		_make_frame_node(f)
		ai.render(f.id)
	changed.emit()


func _on_frame_removed(f: FrameData) -> void:
	if model_nodes.has(f.id):
		(model_nodes[f.id] as Node).queue_free()
		model_nodes.erase(f.id)
		if model_ctl.selected == f.id:
			model_ctl.deselect()
	if frame_nodes.has(f.id):
		(frame_nodes[f.id] as Node).queue_free()
		frame_nodes.erase(f.id)
	grabs.erase(f.id)
	_held.erase("frame:" + f.id)
	if sel_frame == f.id:
		clear_selection()
	if active_frame == f.id:
		active_frame = ""
	changed.emit()


func _on_frame_changed(f: FrameData) -> void:
	var mn: ModelNode = model_nodes.get(f.id)
	if mn != null:
		mn.data = f
		mn.refresh()
		changed.emit()
		return
	var fn: FrameNode = frame_nodes.get(f.id)
	if fn != null:
		fn.data = f
		fn.refresh_bend()
		fn.apply_style()
		fn.invalidate_bounds()
		fn.refresh_pdf()
		if f.pdf != "" and sel_frame == f.id and not selection.is_empty():
			var pg := doc.page_of(f.id)
			for sid in selection:
				var si: Item = doc.items.get(sid)
				if si != null and si.page != pg:
					clear_selection()                          # the page turned: what was selected is on another page
					break
	if f.hidden and sel_frame == f.id and not selection.is_empty():
		clear_selection()                                  # it was hidden: what was selected on it is out of reach
	changed.emit()


func _on_item_added(it: Item) -> void:
	var fn: FrameNode = frame_nodes.get(it.frame)
	if fn != null and fn.shows_item(it):
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
	if fn != null and fn.shows_item(it):
		fn.refresh_view(it)
		fn.invalidate_bounds()
	if selection.has(it.id):
		_dirty_overlay(it.frame)


## May this headset change what is on the canvases? Always, unless it is a guest whose owner has switched editing off.
func can_edit() -> bool:
	return session == null or session.can_edit()


## May it add, remove, restyle or move canvases? A guest only with the owner's say-so; `announce` tells them when not.
func canvas_edit_ok(announce: bool = true) -> bool:
	if session == null or session.can_edit_canvases():
		return true
	if announce:
		deny_edit()
	return false


## Say, at most every few seconds, why nothing happened.
func deny_edit() -> void:
	var now := Time.get_ticks_msec()
	if now - _denied_t < 3000:
		return
	_denied_t = now
	if session != null and session.is_client() and not session.can_edit():
		toast.emit("The owner has switched editing off: you can look, not change.")
	else:
		toast.emit("Only the owner can add, remove or move canvases.")


func _on_session_changed() -> void:
	if history != null:
		history.read_only = not can_edit()
	changed.emit()


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
	if session.is_client():
		return session.room_world(room_id)         # the session's room is wherever this guest's alignment puts it
	if anchors == null or not anchors.is_supported():
		return Transform3D.IDENTITY
	var r := doc.room(room_id)
	if r.is_empty():
		return null
	if _located.has(room_id):
		return _located[room_id]               # where its anchors put it this tick (see _locate_rooms)
	if _assumed.has(room_id):
		return _assumed[room_id]               # its anchors are not found: shown where the board put it (see _assume_room)
	if str(r.anchor) == "":
		return r.anchor_xf                    # made this session, its anchor is still being created
	return null


## Where a room is, from its anchors: its own anchor when that is tracked; failing that, any canvas of the room whose own anchor is
## tracked (each was made at a known place in the room, anchor_xf), the place most of them agree on. Anchors made while the room's
## place was only guessed count only when there is nothing else ("guess": the room is then where it was guessed to be, which is where
## the user last saw it). Only the turn about the vertical is kept: rooms stand level, and the tilt a tracked anchor wobbles by would
## swing canvases metres away by centimetres. {xf, by: room | frame | guess} or {} when none of them is tracked.
func _anchored_room(room_id: String) -> Dictionary:
	var r := doc.room(room_id)
	if r.is_empty():
		return {}
	var a := str(r.anchor)
	if a != "" and anchors.has_pose(a):
		return {"xf": _level(anchors.pose(a)), "by": "room"}
	var cands: Array = []
	var guesses: Array = []
	var ids: Array = doc.frames_in(room_id).map(func(f): return (f as FrameData).id)
	ids.sort()
	for fid in ids:
		var fd: FrameData = doc.frames[fid]
		if fd.anchor != "" and not _pending.has("frame:" + fd.id) and anchors.has_pose(fd.anchor):
			(guesses if fd.anchor_guess else cands).append(_level(anchors.pose(fd.anchor) * fd.anchor_xf.affine_inverse()))
	var by := "frame"
	if cands.is_empty():
		cands = guesses
		by = "guess"
	if cands.is_empty():
		return {}
	var best: Transform3D = cands[0]
	var best_n := -1
	for c in cands:
		var n := 0
		for o in cands:
			if (c as Transform3D).origin.distance_to((o as Transform3D).origin) < AGREE_M:
				n += 1
		if n > best_n:
			best_n = n
			best = c
	return {"xf": best, "by": by}


static func _level(xf: Transform3D) -> Transform3D:
	var f := -xf.basis.z
	if Vector2(f.x, f.z).length() < 0.2:                # (an anchor lying flat: its y axis is the heading)
		f = xf.basis.y
	return Transform3D(Basis(Vector3.UP, atan2(-f.x, -f.z)), xf.origin)


## Every room's pose for this tick, from its anchors; a room whose anchors dropped out a moment ago keeps its last pose for ROOM_HOLD_S
## (the headset re-localising), unless tracking was reset meanwhile (see tracking_reset).
func _locate_rooms(dt: float) -> void:
	_located.clear()
	_located_by.clear()
	for r in doc.rooms:
		var rid := str(r.id)
		var got := _anchored_room(rid)
		if not got.is_empty():
			var xf := _smooth("room:" + rid, got.xf, dt)
			_located[rid] = xf
			_located_by[rid] = got.by
			_last_world[rid] = {"xf": xf, "age": 0.0}
		elif _last_world.has(rid):
			var lw: Dictionary = _last_world[rid]
			lw.age = float(lw.age) + (dt if tracking_live else 0.0)
			if float(lw.age) < ROOM_HOLD_S:
				_located[rid] = lw.xf
				_located_by[rid] = "hold"
			else:
				_last_world.erase(rid)
				_held.erase("room:" + rid)


## The headset's tracking space moved under the room (it was recentred, or the headset was taken off and put back on): every pose
## remembered in tracking space is wrong now. What is anchored is found again through its anchors; a room only assumed is put in front
## of the user again. The user may have walked into another room meanwhile: the room is chosen again (see _pick_room).
func tracking_reset() -> void:
	_last_world.clear()
	_located.clear()
	_located_by.clear()
	_held.clear()
	_no_room_t = 0.0
	_picking = true
	_pick_t = 0.0
	if doc != null and room_state == "assumed" and current_room != "":
		_assume_room(current_room, false)


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
	if remote_grabs.has(f.id):
		var rwg: Variant = room_world(f.room)
		if rwg != null:
			return (rwg as Transform3D) * ((remote_grabs[f.id] as Dictionary).xf as Transform3D)
	if anchors != null and anchors.is_supported() and f.anchor != "" and not f.anchor_stale() and anchors.has_pose(f.anchor) and not session.is_client():
		return _smooth("frame:" + f.id, anchors.pose(f.anchor), dt)
	var rw: Variant = room_world(f.room)
	if rw != null:
		return (rw as Transform3D) * f.xf
	return null


func _update_rooms(dt: float) -> void:
	if session.is_client():
		# a guest sees the owner's room, wherever their alignment puts it: it is "found" once that place is known
		if current_room != session.room_id:
			current_room = session.room_id
			changed.emit()
		var st := "found" if session.room_world(current_room) != null else "searching"
		if st != room_state:
			room_state = st
			changed.emit()
		return
	if anchors == null or not anchors.is_supported():
		room_state = "unanchored"
		if doc.rooms.is_empty():
			create_room_here("My room", false)
		elif current_room == "" or doc.room(current_room).is_empty():
			current_room = str(doc.rooms[0].id)
			changed.emit()
		return
	_locate_rooms(dt)
	var present: Array = []
	for r in doc.rooms:
		if _located.has(r.id):
			present.append(r.id)
		elif str(r.anchor) == "" and r.id == current_room:
			present.append(r.id)                 # just created here, anchor pending
	# a room that has no anchor yet (imported, or made while anchors were unavailable) can only be "here": it adopts this place
	if present.is_empty() or (present.size() == 1 and str(doc.room(str(present[0])).get("anchor", "x")) == ""):
		for r in doc.rooms:
			if str(r.anchor) == "" and not present.has(r.id):
				present.append(r.id)
				break
	if current_room != "" and str(doc.room(current_room).get("anchor", "x")) == "" and _may_create("room:" + current_room):
		_pending["room:" + current_room] = true
		var at: Variant = room_world(current_room)
		anchors.create(at if at != null else doc.room(current_room).anchor_xf, "room:" + current_room)
	var before := current_room
	var before_state := room_state
	var pick := _pick_room(present, dt)
	if pick != "" and pick != current_room:
		current_room = pick
		room_state = "found"
		_no_room_t = 0.0
		_assumed.clear()
		doc.set_room_field(current_room, "used", int(Time.get_unix_time_from_system()))
		doc.last_room = current_room
		_log_room(present)
	elif present.has(current_room):
		room_state = "found"
		_no_room_t = 0.0
		_assumed.erase(current_room)
		if not room_guessed(current_room):
			_moved_unanchored.clear()
	elif room_state == "assumed" and not doc.room(current_room).is_empty():
		pass                                     # keep showing the assumed room until its anchors (or another room's) turn up
	else:
		current_room = ""
		if doc.rooms.is_empty():
			room_state = "none"
			_room_auto_t += dt
			if _room_auto_t > 1.2:
				create_room_here("", true)          # a new document: the first room is made where you stand
		else:
			if tracking_live:
				_no_room_t += dt                   # (with the headset off its anchors cannot be found: that is no reason to give up)
			room_state = "searching"
			if _no_room_t >= ROOM_SEARCH_S and not _locating():
				# nothing anchored is found (the headset lost its map, or this is another room): never leave the user with an empty
				# board, show the last room in front of them. Not while the headset is still placing anchors it has found: that is
				# only slow (a Quest 3 just put on), and showing the room in front then was showing it in the wrong place
				_assume_room(doc.last_room if not doc.room(doc.last_room).is_empty() else str(doc.rooms[0].id))
	if before != current_room or before_state != room_state:
		changed.emit()


## Is the headset still placing one of the document's anchors (found on the device, no pose yet)? See AnchorService.locating.
func _locating() -> bool:
	for r in doc.rooms:
		if str(r.anchor) != "" and anchors.locating(str(r.anchor)):
			return true
	for fid in doc.frames:
		var f: FrameData = doc.frames[fid]
		if f.anchor != "" and anchors.locating(f.anchor):
			return true
	return false


## The room the user is in, of those whose anchors are here ("" when there is none). A headset's map can span the whole home (a
## Quest 3 maps every room it has been in), and then the anchors of the rooms next door are found too: the user is in the one they are
## nearest to (_room_dist), not the one used last. At the start, and with the headset put back on, the rooms are found one after the
## other, so for ROOM_PICK_S after the first one (longer while the headset is still placing anchors) a room the user is clearly nearer
## to takes over. After that the room stays until its anchors are gone or the user picks another (Home > Rooms). It never changes while
## something is drawn, carried or placed, nor during a session (the owner's room is everybody's).
func _pick_room(present: Array, dt: float) -> String:
	if present.is_empty():
		return ""
	if not present.has(current_room):
		return _nearest_room(present)
	if not _picking:
		return current_room
	if session.is_active():
		_picking = false
		return current_room
	if tracking_live:
		_pick_t += dt
	var pick := current_room
	if grabs.is_empty() and placing.is_empty() and placing_text.is_empty() and pen_ctl.state == PenController.S.IDLE and not surface.finding() and not surface.aligning():
		var near := _nearest_room(present)
		if near == session.resume_room() or _room_dist(near) + ROOM_NEARER_M < _room_dist(current_room):
			pick = near
	if _pick_t > ROOM_PICK_S and not _locating():
		_picking = false                         # (a room placed late was looked at above, in the tick it was placed)
	return pick


## Of these rooms, the one the user is nearest to; the room of a session that is being started again when it is one of them.
func _nearest_room(rooms: Array) -> String:
	if rooms.has(session.resume_room()):
		return session.resume_room()
	var best := str(rooms[0])
	var best_d := INF
	for rid in rooms:
		var d := _room_dist(str(rid))
		if d < best_d:
			best = str(rid)
			best_d = d
	return best


## How far the user stands from a room, along the floor: from the nearest of the place it was made at (where its maker stood) and its
## canvases.
func _room_dist(room_id: String) -> float:
	var rw: Variant = room_world(room_id)
	if rw == null:
		return INF
	var me := Vector2(head.origin.x, head.origin.z)
	var o := (rw as Transform3D).origin
	var d := me.distance_to(Vector2(o.x, o.z))
	for f in doc.frames_in(room_id):
		if (f as FrameData).kind == FrameData.CANVAS or (f as FrameData).is_model():
			var p := (rw as Transform3D) * (f as FrameData).xf.origin
			d = minf(d, me.distance_to(Vector2(p.x, p.z)))
	return d


func _log_room(present: Array) -> void:
	var seen := PackedStringArray()
	for rid in present:
		seen.append("%s %.1f m" % [str(doc.room(str(rid)).get("name", rid)), _room_dist(str(rid))])
	print("[board] in room %s (found: %s)" % [str(doc.room(current_room).get("name", current_room)), ", ".join(seen)])


## Make a new room at the user's feet (the floor under the head), with its own anchor, and move into it.
func create_room_here(room_name: String = "", announce: bool = true) -> void:
	if doc == null:
		return
	var pose := Transform3D(Basis(Vector3.UP, _head_yaw()), Vector3(head.origin.x, 0.0, head.origin.z))
	var r := doc.add_room(room_name if room_name != "" else doc.next_room_name(), "", pose)
	current_room = r.id
	room_state = "found"
	_no_room_t = 0.0
	_picking = false
	if anchors != null and anchors.is_supported():
		_pending["room:" + r.id] = true
		anchors.create(pose, "room:" + r.id)
	if announce:
		toast.emit("Room \"%s\" created here" % r.name)
	changed.emit()


## Show a room whose anchors are not found in front of the user: its main canvas within reach (REACH_DIST), facing them, the room's
## other frames around it as they were. The room is only turned about the vertical, so it stays level: a canvas lying on a desk still
## lies flat (in front of the user, at its height in the room: on the desk if the floor is where it was), one on a wall still stands.
## Nothing is changed in the document; if the real anchors turn up, everything moves back to its anchored place. Re-anchor room keeps it
## where it is shown.
func _assume_room(room_id: String, announce: bool = true) -> void:
	if doc == null or doc.room(room_id).is_empty():
		return
	var yaw := _head_yaw()
	var fwd := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z)
	fwd = fwd.normalized() if fwd.length() > 0.05 else Vector3.FORWARD
	var pose := Transform3D(Basis(Vector3.UP, yaw), Vector3(head.origin.x, 0.0, head.origin.z))
	var main := _main_canvas(room_id)
	if main != null:
		var turn := Basis(Vector3.UP, yaw - SharedSpace.heading(-SharedSpace.facing_of(main.xf)))
		var at := head.origin + fwd * REACH_DIST + Vector3(0.0, -0.2, 0.0)
		if absf(main.xf.basis.z.normalized().y) > 0.85:
			at = head.origin + fwd * DESK_DIST
			at.y = clampf(main.xf.origin.y, head.origin.y - 1.2, head.origin.y - 0.15)
		pose = Transform3D(turn, at - turn * main.xf.origin)
	_assumed[room_id] = pose
	_held.clear()
	current_room = room_id
	room_state = "assumed"
	doc.last_room = room_id
	if announce:
		toast.emit("The anchors of \"%s\" were not found, so it is shown in front of you. Home > Rooms > Re-anchor keeps it here." % str(doc.room(room_id).get("name", "the room")))
	changed.emit()


## The canvas a room is shown by when it has to be placed by hand: the active one, else the one with the most on it.
func main_canvas(room_id: String) -> FrameData:
	return _main_canvas(room_id)


func _main_canvas(room_id: String) -> FrameData:
	var best: FrameData = null
	var most := -1
	for f in doc.frames_in(room_id):
		var fd: FrameData = f
		if fd.kind != FrameData.CANVAS:
			continue
		if fd.id == active_frame:
			return fd
		var n := doc.items_of(fd.id).size()
		if n > most:
			most = n
			best = fd
	return best


func _head_yaw() -> float:
	var f := -head.basis.z
	return atan2(-f.x, -f.z)


func select_room(room_id: String) -> void:
	## Manually declare which room this is (when the anchors cannot be found): the room's frames are then placed by its remembered pose.
	if doc == null or doc.room(room_id).is_empty():
		return
	_picking = false                           # the user's choice: not changed for them
	var a := str(doc.room(room_id).anchor)
	if anchors != null and anchors.is_supported() and a != "" and not _located.has(room_id) and not anchors.has_pose(a):
		_assume_room(room_id)                  # its anchors are not here: show it in front of the user
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
	var by := str(_located_by.get(current_room, ""))
	var shown: bool = _assumed.has(current_room) or by == "frame" or by == "guess" or by == "hold"
	if shown:
		pose = _assumed[current_room] if _assumed.has(current_room) else _located[current_room]   # keep the room where it is shown now
	doc.set_room_field(current_room, "anchor", "")
	doc.set_room_field(current_room, "anchor_xf", pose)
	if old != "":
		anchors.untrack(old)
		anchors.erase(old)
	# the room's guessed place is its real place from now on: the canvases anchored under the guess agree with it
	for f in doc.frames_in(current_room):
		if (f as FrameData).anchor_guess:
			var upd := (f as FrameData).copy()
			upd.anchor_guess = false
			doc.replace_frame(upd)
	_moved_unanchored.clear()
	_retry_at.erase("room:" + current_room)
	_fails.erase("room:" + current_room)
	if anchors.is_supported():
		_pending["room:" + current_room] = true
		anchors.create(pose, "room:" + current_room)
	if shown:
		room_state = "found"
		toast.emit("Room anchored here: its canvases stay where they are now.")
	else:
		toast.emit("Room anchor re-created here. Frames keep their place relative to the old room origin.")


func _on_anchor_created(tag: String, uuid: String) -> void:
	var parts := tag.split(":")
	if parts.size() < 2 or not (parts[0] in ["room", "frame"]):
		return                                   # someone else's (the session's alignment, the panels)
	_pending.erase(tag)
	_retry_at.erase(tag)
	_fails.erase(tag)
	if doc == null:
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
		upd.anchor_guess = bool(_pending_guess.get(tag, false))
		doc.replace_frame(upd)
		_pending_pose.erase(tag)
		_pending_guess.erase(tag)
		_held.erase("frame:" + f.id)
		_moved_unanchored.erase(f.id)
		if old != "" and old != uuid:
			anchors.untrack(old)
			anchors.erase(old)


## An anchor could not be made (no Space Setup yet, the permission not granted yet, the headset still mapping the room): it is tried
## again later, waiting longer each time, and the user is told now and then, not on every try.
func _on_anchor_failed(tag: String) -> void:
	var parts := tag.split(":")
	if parts.size() < 2 or not (parts[0] in ["room", "frame"]):
		return
	_pending.erase(tag)
	_pending_pose.erase(tag)
	_pending_guess.erase(tag)
	var n := int(_fails.get(tag, 0)) + 1
	_fails[tag] = n
	_retry_at[tag] = Time.get_ticks_msec() + int(minf(RETRY_MIN_S * pow(2.0, n - 1), RETRY_MAX_S) * 1000.0)
	if Time.get_ticks_msec() - _fail_toast_ms > 30000:
		_fail_toast_ms = Time.get_ticks_msec()
		toast.emit("Could not create a spatial anchor (trying again). Is the Space Setup done for this room?")


## Is a room shown at a guessed place (its anchors not found: in front of the user, or where anchors made under such a guess say)?
## What the user puts somewhere then is anchored right there, but nothing else is.
func room_guessed(room_id: String) -> bool:
	return (room_state == "assumed" and room_id == current_room) or str(_located_by.get(room_id, "")) == "guess"


## May an anchor with this tag be asked for now (none in flight, and not waiting after a failure)?
func _may_create(tag: String) -> bool:
	return not _pending.has(tag) and Time.get_ticks_msec() >= int(_retry_at.get(tag, 0))


## Frames whose pose differs from the one their anchor was made at (or that have none) get a new anchor at their current place. Anchors
## that are lost (never tracked although the room is here) are replaced, the room's own included. And while the room's own anchor is
## tracked, each canvas's place in the room is kept true to its own anchor, so the room alone still puts it in the right place (when
## its anchor is lost, and on the guests' headsets in a session, which see canvases by their place in the room).
func _reconcile(dt: float) -> void:
	_reconcile_t += dt
	if _reconcile_t < RECONCILE_S:
		return
	_reconcile_t = 0.0
	if anchors == null or not anchors.is_supported() or current_room == "" or session.is_client() or not tracking_live:
		return
	var r := doc.room(current_room)
	if r.is_empty():
		return
	if room_guessed(current_room):
		# the room's anchors are not found: only what the user puts somewhere meanwhile is anchored, right where they put it (the
		# rest would be anchored at a guessed place)
		for fid in _moved_unanchored.keys():
			var fa: FrameData = doc.frames.get(fid)
			if fa == null or fa.room != current_room:
				_moved_unanchored.erase(fid)
			else:
				_anchor_frame(fa, true)
		return
	if room_state != "found":
		return
	var by := str(_located_by.get(current_room, ""))
	if by == "hold" or (by == "" and str(r.anchor) != ""):
		return                                           # no fresh pose to make anchors at
	# the room's own anchor lost while its canvases' anchors still find the room: a new one where they say the room is
	if by == "frame" and str(r.anchor) != "" and _may_create("room:" + current_room):
		_lost_t["room:" + current_room] = float(_lost_t.get("room:" + current_room, 0.0)) + RECONCILE_S
		if float(_lost_t["room:" + current_room]) > ANCHOR_LOST_S:
			_lost_t.erase("room:" + current_room)
			var gone := str(r.anchor)
			doc.set_room_field(current_room, "anchor", "")
			doc.set_room_field(current_room, "anchor_xf", _located[current_room])
			anchors.untrack(gone)
			print("[board] the anchor of room %s was lost: making a new one where its canvases are" % current_room)
	else:
		_lost_t.erase("room:" + current_room)
	for f in doc.frames_in(current_room):
		var fd: FrameData = f
		var tag := "frame:" + fd.id
		# an anchor that never gets a pose although the room is here has been lost (the headset's space map was reset): make a new one
		# (one the headset is still placing is not lost yet)
		if fd.anchor != "" and not anchors.has_pose(fd.anchor):
			if not anchors.locating(fd.anchor):
				_lost_t[fd.id] = float(_lost_t.get(fd.id, 0.0)) + RECONCILE_S
			if float(_lost_t.get(fd.id, 0.0)) > ANCHOR_LOST_S and not _pending.has(tag):
				var lost := fd.copy()
				lost.anchor = ""
				doc.replace_frame(lost)
				_lost_t.erase(fd.id)
				fd = lost
		else:
			_lost_t.erase(fd.id)
			if by == "room" and fd.anchor != "" and not fd.anchor_stale() and not grabs.has(fd.id) and not remote_grabs.has(fd.id) and not _pending.has(tag) \
					and (not fd.surface or fd.anchor_guess):
				fd = _refresh_from_anchor(fd)
		_anchor_frame(fd)


## A new anchor for a frame at the place it is shown now, if it has none or it moved since its anchor was made. `guess`: the room is
## only shown at a guessed place (see FrameData.anchor_guess).
func _anchor_frame(fd: FrameData, guess: bool = false) -> void:
	var tag := "frame:" + fd.id
	if grabs.has(fd.id) or not _may_create(tag) or not fd.anchor_stale():
		return
	var w: Variant = frame_world(fd)
	if w == null:
		return
	_pending[tag] = true
	_pending_pose[tag] = fd.xf
	_pending_guess[tag] = guess
	anchors.create(Transform3D((w as Transform3D).basis.orthonormalized(), (w as Transform3D).origin), tag)


## The headset refines its map and the anchors shift against each other by a little: when a canvas's own anchor and the room's
## disagree about where in the room the canvas is, the anchor on the canvas is right. Its place in the room follows (not an undo step).
## An anchor made while the room was guessed gets its true place in the room this way. Returns the frame as it is now.
func _refresh_from_anchor(fd: FrameData) -> FrameData:
	var rel: Transform3D = (_located[current_room] as Transform3D).affine_inverse() * anchors.pose(fd.anchor)
	rel = Transform3D(rel.basis.orthonormalized(), rel.origin)
	var moved := rel.origin.distance_to(fd.xf.origin)
	var turned := rel.basis.get_rotation_quaternion().angle_to(fd.xf.basis.get_rotation_quaternion())
	if moved < REFRESH_M and turned < deg_to_rad(REFRESH_DEG) and not fd.anchor_guess:
		return fd
	var upd := fd.copy()
	upd.xf = upd.on_surface(rel) if fd.surface else rel
	upd.anchor_xf = upd.xf
	upd.anchor_guess = false
	doc.replace_frame(upd)
	print("[board] %s: its place in the room follows its anchor (%.1f cm, %.2f deg)" % [fd.name, moved * 100.0, rad_to_deg(turned)])
	return upd


# ------------------------------------------------------------------------------------------------ frames

## Place every frame node from its anchor / room pose and show only the frames of the room we are in.
func _place_frames(dt: float) -> void:
	for fid in frame_nodes.keys():
		var fn: FrameNode = frame_nodes[fid]
		var f := fn.data
		# canvases only: 3D sketches in older documents stay in the file but are not shown (drawing in 3D is switched off)
		var show := f.kind == FrameData.CANVAS and not f.hidden and (f.room == current_room or room_state == "unanchored") and room_state != "searching"
		var w: Variant = frame_world(f, dt) if show else null
		fn.visible = show and w != null
		if fn.visible:
			var xf := w as Transform3D
			if f.surface and grabs.has(fid):
				xf = _on_surface_world(f, xf)               # carried or turned, a desk canvas slides along its surface
			var sc: float = (grabs[fid] as Dictionary).scale if grabs.has(fid) else (float((remote_grabs[fid] as Dictionary).scale) if remote_grabs.has(fid) else f.scale)
			if fn.bend != null:
				# a curved desk keeps its size (its bend is in real metres): its scale zooms the contents on it, which also slide along the
				# surface by the pan of whoever holds it
				var g: Dictionary = grabs.get(fid, remote_grabs.get(fid, {}))
				fn.set_bend_live(float(g.get("bend_at", f.bend_at)), float(g.get("bend_radius", f.bend_radius)), g.get("pan", f.bend_pan), sc)
				sc = 1.0
			fn.transform = Transform3D(xf.basis.orthonormalized().scaled(Vector3.ONE * sc), xf.origin)
	_place_models(dt)


## Every model node from its anchor / room pose (or the hand carrying it), only the models of the room we are in, with their shadows.
func _place_models(dt: float) -> void:
	var shadows := models.budget.shadow and bool(App.val("model_shadow"))
	for fid in model_nodes.keys():
		var mn: ModelNode = model_nodes[fid]
		var f := mn.data
		var show := not f.hidden and (f.room == current_room or room_state == "unanchored") and room_state != "searching"
		var w: Variant = frame_world(f, dt) if show else null
		mn.visible = show and w != null
		if not mn.visible:
			mn.place_shadow(null, false)
			continue
		var xf := w as Transform3D
		var g: Dictionary = grabs.get(fid, remote_grabs.get(fid, {}))
		var sc := f.clamp_scale(float(g.get("scale", f.scale)))
		mn.transform = Transform3D(xf.basis.orthonormalized().scaled(Vector3.ONE * sc), xf.origin)
		if not grabs.has(fid):                                 # (this headset's own hold sets it: ModelController)
			mn.set_live_stretch(g.get("stretch"))              # somebody else of the session may be stretching it
		mn.place_shadow(_floor_under(mn.global_position) if shadows else null, shadows)


## The height of the real surface under a point: a table the headset knows (Meta's scene) or the simulated room's, else the room's floor.
## null when there is neither.
func _floor_under(p: Vector3) -> Variant:
	if surface_hit.is_valid():
		var hit: Dictionary = surface_hit.call(p, Vector3.DOWN)
		if not hit.is_empty() and absf((hit.normal as Vector3).normalized().y) > 0.85 and (hit.point as Vector3).y < p.y + 0.01:
			return (hit.point as Vector3).y
	return floor_y()


## The floor's height (world): where the room was made (rooms are made on the floor, under the head), else 0.
func floor_y() -> float:
	var rw: Variant = room_world(current_room)
	return (rw as Transform3D).origin.y if rw != null else 0.0


func visible_frames(kind: String = "") -> Array:
	var out: Array = []
	for fn in frame_nodes.values():
		var n := fn as FrameNode
		if n.visible and (kind == "" or n.data.kind == kind):
			out.append(n)
	return out


## A world pose of a desk canvas put onto its surface (FrameData.on_surface works in room space).
func _on_surface_world(f: FrameData, world_xf: Transform3D) -> Transform3D:
	var rw: Variant = room_world(f.room)
	if rw == null:
		return world_xf
	return (rw as Transform3D) * f.on_surface((rw as Transform3D).affine_inverse() * world_xf)


## Who is dragging the selection right now (the stylus's controller, or one of the hands'), for drawing the selection as it moves.
func drag_driver() -> PenController:
	for c in [pen_ctl] + hand_ctl.controllers():
		var ctl := c as PenController
		if ctl.state == PenController.S.DRAG_ITEMS or ctl.state == PenController.S.DRAG_HANDLE:
			return ctl
	return pen_ctl


## How the selection is shown on a frame: see PenController.selection_view().
func selection_view(fn: FrameNode) -> Dictionary:
	return drag_driver().selection_view(fn)


## The canvas the pen is working on: the nearest canvas within `reach` metres of the tip (in front of or behind it) whose extent
## (grown by `slack` so drawing past the edge extends it) contains the tip. {fn, local, dist} or {}.
func pen_target(tip: Vector3, reach: float = CAPTURE, slack: float = InputTuning.SLACK) -> Dictionary:
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


## Where dictated text goes: the point of the canvas the head looks at; failing that the middle of the active canvas, or of the
## canvas nearest the head. {frame, center} (frame coordinates) or {} when there is no canvas to write on.
func dictation_spot() -> Dictionary:
	var best := {}
	var best_t := INF
	var nearest: FrameNode = null
	var nearest_d := INF
	var gaze := -head.basis.z
	for fn in visible_frames(FrameData.CANVAS):
		var n := fn as FrameNode
		if n.data.locked:
			continue
		var d := n.global_position.distance_to(head.origin)
		if n.data.id == active_frame:
			d *= 0.25
		if d < nearest_d:
			nearest_d = d
			nearest = n
		var hit := n.ray_hit(head.origin, gaze, 0.001)
		if hit.is_empty():
			continue
		var t := float(hit.t)
		if t >= best_t:
			continue
		var g: Vector3 = hit.local
		if n.bounds().has_point(Vector2(g.x, g.y)):
			best_t = t
			best = {"frame": n.data.id, "center": Vector2(g.x, g.y)}
	if best.is_empty() and nearest != null:
		best = {"frame": nearest.data.id, "center": nearest.bounds().get_center()}
	return best


func begin_grab(f: FrameData) -> void:
	if grabs.has(f.id) or f.locked:
		return
	if not canvas_edit_ok():
		return
	var w: Variant = frame_world(f)
	if w == null:
		return
	grabs[f.id] = {"xf": w, "xf0": w, "scale": f.scale, "before": f.copy()}
	if f.bend:
		(grabs[f.id] as Dictionary).merge({"pan": f.bend_pan, "bend_at": f.bend_at, "bend_radius": f.bend_radius})
	_dirty_overlay(f.id)


func end_grab(f: FrameData) -> void:
	if not grabs.has(f.id):
		return
	var g: Dictionary = grabs[f.id]
	if f.bend:
		_end_bend_grab(f, g)
		return
	var rw: Variant = room_world(f.room)
	var after := f.copy()
	var xf := g.xf as Transform3D
	after.xf = (rw as Transform3D).affine_inverse() * xf if rw != null else xf
	after.xf = after.on_surface(after.xf)
	if f.is_model():
		after.stretch = g.get("stretch", f.stretch)
		after.xf = Transform3D(after.xf.basis.orthonormalized(), after.xf.origin)
	after.scale = f.clamp_scale(float(g.scale))
	if xf.is_equal_approx(g.xf0 as Transform3D) and is_equal_approx(after.scale, f.scale) and after.stretch.is_equal_approx(f.stretch) and (f.place_locked or f.is_model()):
		grabs.erase(f.id)                            # its place is locked and it was only held: it keeps its pose (and its anchor)
		_dirty_overlay(f.id)
		return
	grabs.erase(f.id)
	_held.erase("frame:" + f.id)
	var before: FrameData = g.before
	if room_guessed(f.room):
		_moved_unanchored[f.id] = true               # anchored right where it was put, although the room's place is a guess
	history.do(History.op_frame(before, after))     # applies `after`: the anchor is then re-created at the new place by _reconcile()
	_dirty_overlay(f.id)


## A curved desk is let go: where the contents slid to and how far they were zoomed, the numbers of the bend a marker set, and where the desk
## was carried to (on the desk's plane, keeping its size) are kept.
func _end_bend_grab(f: FrameData, g: Dictionary) -> void:
	var after := f.copy()
	after.bend_pan = g.get("pan", f.bend_pan)
	after.scale = DeskBend.clamp_zoom(float(g.scale))
	after.bend_at = DeskBend.clamp_at(float(g.get("bend_at", f.bend_at)))
	after.bend_radius = DeskBend.clamp_radius(float(g.get("bend_radius", f.bend_radius)))
	var carried := not (g.xf as Transform3D).is_equal_approx(g.get("xf0", g.xf) as Transform3D)
	if carried:
		var rw: Variant = room_world(f.room)
		after.xf = after.on_surface((rw as Transform3D).affine_inverse() * (g.xf as Transform3D) if rw != null else g.xf as Transform3D)
		_held.erase("frame:" + f.id)
		if room_guessed(f.room):
			_moved_unanchored[f.id] = true
	grabs.erase(f.id)
	_dirty_overlay(f.id)
	var before: FrameData = g.before
	if not carried and after.bend_pan.is_equal_approx(before.bend_pan) and is_equal_approx(after.scale, before.scale) and is_equal_approx(after.bend_at, before.bend_at) \
			and is_equal_approx(after.bend_radius, before.bend_radius) and after.size.is_equal_approx(before.size) and after.offset.is_equal_approx(before.offset):
		return                                          # a touch that moved nothing
	history.do(History.op_frame(before, after))


## A canvas whose place is locked (FrameData.place_locked) stays where it is, facing the same way: says so and returns true when `f` is one.
func place_locked(f: FrameData) -> bool:
	if f == null or not f.place_locked:
		return false
	toast.emit("\"%s\" has its place locked: it stays where it is (two hands still resize it). Unlock it in Home > Canvases to move it." % f.name)
	return true


## Bring the canvas you are looking at (else the active one, else the nearest) within reach of the stylus: its middle 0.6 m in front
## of you, a little below the eyes, facing you. Done as a grab, so it is undoable and gets a new anchor like any move.
func bring_canvas_here() -> void:
	var spot := dictation_spot()
	var fn: FrameNode = frame_nodes.get(str(spot.get("frame", "")))
	if fn == null:
		toast.emit("There is no canvas here yet: place one with On a wall or On a table.")
		return
	var f := fn.data
	if f.locked:
		toast.emit("That canvas is locked.")
		return
	if f.surface:
		toast.emit("That canvas lies on your desk: it stays there. Free it in Home > Canvases to bring it.")
		return
	if place_locked(f):
		return
	begin_grab(f)
	if not grabs.has(f.id):
		return
	var fwd := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z)
	fwd = fwd.normalized() if fwd.length() > 0.05 else Vector3.FORWARD
	var basis := Basis(Vector3.UP, _head_yaw())
	var middle := fn.bounds().get_center()
	var want := head.origin + fwd * REACH_DIST + Vector3(0.0, -0.2, 0.0)
	(grabs[f.id] as Dictionary).xf = Transform3D(basis, want - basis * (Vector3(middle.x, middle.y, 0.0) * f.scale))
	end_grab(f)
	active_frame = f.id
	toast.emit("Canvas brought within reach.")


# ------------------------------------------------------------------------------------------------ the curved desk

const CHEST := 0.15                        # a curved desk starts this far in front of the head (horizontally), where the chest is
const CURVE_LEVEL := 0.9                   # the desk must be this level (its normal's up component) to curve up into a wall
const CURVE_FRONT := 0.3                   # the contents of a canvas that is curved are put this far along the surface, on the flat part

## Is the desk this frame lies on level enough to curve up into a wall?
func can_curve(f: FrameData) -> bool:
	var rw: Variant = room_world(f.room)
	if not f.surface or rw == null:
		return false
	return ((rw as Transform3D).basis * f.plane_normal).normalized().y >= CURVE_LEVEL


## Make `f` (a canvas on a level desk; `rw` its room's world pose) a curved desk, aligned to the user: its edge in front of the chest, its
## top (the way the surface runs) away from the head, level with the desk. Its contents are put on the flat part in front of you. Changes `f`.
func make_curved(f: FrameData, rw: Transform3D) -> void:
	var n := (rw.basis * f.plane_normal).normalized()
	var p0 := rw * f.plane_point
	var fwd := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z)
	fwd = fwd.normalized() if fwd.length() > 0.05 else Vector3.FORWARD
	var edge := Vector3(head.origin.x, 0.0, head.origin.z) + fwd * CHEST
	edge.y = p0.y - (n.x * (edge.x - p0.x) + n.z * (edge.z - p0.z)) / maxf(n.y, 0.1)       # the point of the desk under it
	var y := (fwd - n * n.dot(fwd)).normalized()
	var world := Transform3D(Basis(y.cross(n).normalized(), y, n), edge)
	var content := Rect2()
	var first := true
	for it in doc.items_of(f.id):
		var b: Rect2 = (it as Item).bounds()
		content = b if first else content.merge(b)
		first = false
	var c := Vector2.ZERO if first else content.get_center()
	f.xf = rw.affine_inverse() * world
	f.scale = DeskBend.clamp_zoom(f.scale)              # (what is drawn keeps the size it had; the desk itself is in real metres)
	f.bend = true
	f.bend_at = DeskBend.DEFAULT_AT
	f.bend_radius = DeskBend.DEFAULT_RADIUS
	f.size = DeskBend.DEFAULT_SIZE
	f.offset = Vector2(0.0, f.size.y * 0.5)
	f.bend_pan = Vector2(-c.x * f.scale, CURVE_FRONT - c.y * f.scale) if not first else Vector2.ZERO


## Make `f` (a curved desk) a flat canvas again: it keeps what it shows where it is on the desk (the contents have slid by `bend_pan`) and
## as big (its scale, the zoom, stays). Changes `f`.
func make_flat(f: FrameData) -> void:
	if not f.bend:
		return
	f.xf = Transform3D(f.xf.basis, f.xf.origin + f.xf.basis * Vector3(f.bend_pan.x, f.bend_pan.y, 0.0))
	f.offset = (f.offset - f.bend_pan) / f.scale        # (the shown part was in surface metres: now canvas coordinates)
	f.size /= f.scale
	f.bend = false
	f.bend_pan = Vector2.ZERO


## A canvas lying on a level desk curves up into a wall (on), or lies flat again where it is (off). One undo step.
func curve_frame(frame_id: String, on: bool) -> bool:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null or f.kind != FrameData.CANVAS or not canvas_edit_ok():
		return false
	if f.locked:
		toast.emit("That canvas is locked.")
		return false
	if on == f.bend:
		return true
	var upd := f.copy()
	if on:
		if f.is_pdf():
			toast.emit("A PDF stays flat.")
			return false
		if place_locked(f):
			return false                                     # (curving puts it in front of you: flattening keeps it where it is, so that may)
		if not can_curve(f):
			toast.emit("Lay the canvas on a level desk first (Add > On my desk): only a level desk can curve up into a wall.")
			return false
		var rw: Variant = room_world(f.room)
		make_curved(upd, rw as Transform3D)
	else:
		make_flat(upd)
		toast.emit("\"%s\" lies flat on your desk again." % f.name)
	history.do(History.op_frame(f, upd))
	active_frame = f.id
	if on:
		surface.begin_align(f.id)                        # line it up with the real desk (the head only gave a first guess)
	return true


const ALIGN_MIN := 0.15                    # the wall must be at least this far (along the desk) from the front edge touched
const WALL_ABOVE := 0.6                    # after lining up, the shown part reaches at least this far up the wall

## Line curved desk `frame_id` up with the real desk from two world points the nib touched: `edge` on the desk's front edge in front of you,
## `wall` on the wall behind it (or the desk's far edge). The canvas then starts at the edge, runs from it towards the wall, level with the
## desk, and bends so that its upright part lies on the wall (the radius is kept, the distance is the edge's to the wall less the radius).
## One undo step. "" when done, else what is wrong.
func align_curved(frame_id: String, edge: Vector3, wall: Vector3) -> String:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null or not f.bend or not canvas_edit_ok():
		return "That canvas is not a curved desk."
	if f.place_locked:
		return "\"%s\" has its place locked. Unlock it in Home > Canvases to line it up." % f.name
	var rw_v: Variant = room_world(f.room)
	var rw: Transform3D = rw_v as Transform3D if rw_v != null else Transform3D.IDENTITY
	var n := (rw.basis * f.plane_normal).normalized()
	var p0 := rw * f.plane_point
	var e := edge - n * n.dot(edge - p0)                # the edge, on the desk's plane
	var run := wall - e
	run -= n * n.dot(run)                               # along the desk
	var d := run.length()
	if d < ALIGN_MIN:
		return "The wall (or the far edge) must be at least %d cm from the front edge. Touch the front edge again." % int(ALIGN_MIN * 100.0)
	var y := run / d
	var world := Transform3D(Basis(y.cross(n).normalized(), y, n), e)
	var upd := f.copy()
	upd.xf = rw.affine_inverse() * world
	upd.bend_radius = DeskBend.clamp_radius(minf(f.bend_radius, d - DeskBend.MIN_AT))
	upd.bend_at = DeskBend.clamp_at(d - upd.bend_radius)
	var reach := upd.bend_at + PI * 0.5 * upd.bend_radius + WALL_ABOVE
	if upd.size.y < reach:
		upd.size.y = reach
	upd.offset = Vector2(upd.offset.x, upd.size.y * 0.5)  # (the shown part starts at the front edge)
	history.do(History.op_frame(f, upd))
	active_frame = f.id
	toast.emit("Lined up: \"%s\" starts at the front edge and climbs the wall %d cm from it. Push what you draw away from you to send it up the wall." % [f.name, roundi(d * 100.0)])
	return ""


## Set where the flat part of a curved desk ends and how round the bend is (one undo step).
func set_bend(frame_id: String, at: float, radius: float) -> void:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null or not f.bend or not canvas_edit_ok():
		return
	var upd := f.copy()
	upd.bend_at = DeskBend.clamp_at(at)
	upd.bend_radius = DeskBend.clamp_radius(radius)
	if is_equal_approx(upd.bend_at, f.bend_at) and is_equal_approx(upd.bend_radius, f.bend_radius):
		return
	history.do(History.op_frame(f, upd))


## `plane` ({point, normal, error, count}, world space) puts the new canvas on a physical surface (SurfaceController.finish).
func add_frame(kind: String, world_xf: Transform3D, size: Vector2 = Vector2(1.2, 0.8), plane: Dictionary = {}, props: Dictionary = {}) -> FrameData:
	if doc == null or not canvas_edit_ok():
		return null
	if current_room == "":
		create_room_here("", false)
	var rw: Variant = room_world(current_room)
	var f := FrameData.make(kind, current_room, (rw as Transform3D).affine_inverse() * world_xf if rw != null else world_xf)
	f.size = size
	for k in props:
		f.set(k, props[k])
	if not plane.is_empty():
		surface.apply_plane(f, rw, plane)
		f.xf = f.on_surface(f.xf)
		if f.bend:
			make_curved(f, rw as Transform3D if rw != null else Transform3D.IDENTITY)
	if room_guessed(current_room):
		_moved_unanchored[f.id] = true
	history.do(History.op_frame_add(f))
	var made: FrameData = doc.frames.get(f.id)
	if kind == FrameData.CANVAS:
		active_frame = f.id
	changed.emit()
	return made


func delete_frame(frame_id: String) -> void:
	var f: FrameData = doc.frames.get(frame_id)
	if f == null or not canvas_edit_ok():
		return
	var items := doc.items_all_of(frame_id)
	var old_anchor := f.anchor
	history.do(History.op_frame_remove(f, items))
	# the anchor is erased from the device only when the deletion can no longer be undone: keep it until the document is closed
	if old_anchor != "":
		_orphans.append(old_anchor)
	changed.emit()


func rename_frame(frame_id: String, new_name: String) -> void:
	var f: FrameData = doc.frames.get(frame_id)
	if f != null and new_name.strip_edges() != "" and canvas_edit_ok():
		var upd := f.copy()
		upd.name = new_name.strip_edges()
		history.do(History.op_frame(f, upd))


## The web page deleted a canvas: the same undoable step as the bin in the menu.
func _web_delete(frame_id: String) -> void:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null:
		return
	if sel_frame == frame_id:
		selection.clear()
		sel_frame = ""
	if active_frame == frame_id:
		active_frame = ""
	delete_frame(frame_id)
	toast.emit("\"%s\" was deleted from the web page (undo brings it back)." % f.name)


## Where something added from outside (an SVG or a PDF from the web page) is put: in front of the viewer, facing them; several added one
## after another stand side by side.
func _front_pose(size: Vector2) -> Transform3D:
	var basis := Basis(Vector3.UP, _head_yaw())
	var fwd := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z)
	fwd = fwd.normalized() if fwd.length() > 0.05 else Vector3.FORWARD
	var now := Time.get_ticks_msec()
	var shift := 0.0
	if now - _import_time < 90000:
		shift = _import_right + 0.12 + size.x * 0.5
	_import_time = now
	_import_right = shift + size.x * 0.5
	var dist := clampf(0.9 + size.x * 0.35, 0.9, 1.7)
	var pos := Vector3(head.origin.x, clampf(head.origin.y - 0.1, 0.8, 1.9), head.origin.z) + fwd * dist + basis.x * shift
	return Transform3D(basis, pos)


func _unique_frame_name(base: String) -> String:
	var taken := {}
	for f in doc.frames.values():
		taken[(f as FrameData).name] = true
	var final_name := base
	var k := 2
	while taken.has(final_name):
		final_name = "%s (%d)" % [base, k]
		k += 1
	return final_name


## Adds an SVG as a new canvas in front of the viewer: its shapes, strokes and text become ordinary items that can be selected and
## edited. One undo step removes it all. Returns {ok, message, id, name, count}.
func import_svg(svg: String, canvas_name: String = "") -> Dictionary:
	if doc == null:
		return {"ok": false, "message": "No document is open in the headset."}
	var res := SvgImport.parse(svg)
	if not res.ok:
		return {"ok": false, "message": str(res.message)}
	var size: Vector2 = res.size
	var base := canvas_name.strip_edges()
	if base == "":
		base = str(res.title) if str(res.title) != "" else "Imported"
	var taken := {}
	for f in doc.frames.values():
		taken[(f as FrameData).name] = true
	var final_name := base
	var k := 2
	while taken.has(final_name):
		final_name = "%s (%d)" % [base, k]
		k += 1
	var world := _front_pose(size)
	history.begin_group()
	var frame := add_frame(FrameData.CANVAS, world, size)
	if frame == null:
		history.end_group()
		return {"ok": false, "message": "The canvas could not be created."}
	rename_frame(frame.id, final_name)
	if str(res.backing) != "":
		set_frame_prop(frame.id, "backing", str(res.backing))
	for it in res.items:
		(it as Item).frame = frame.id
	history.do(History.op_add(res.items))
	history.end_group()
	var msg := "%s added: %d items" % [final_name, int(res.count)]
	var left := SvgImport.skipped_text(res.skipped)
	if left != "":
		msg += " (left out: %s)" % left
	toast.emit("\"%s\" was added from the web page: it is in front of you." % final_name)
	changed.emit()
	return {"ok": true, "message": msg, "id": frame.id, "name": final_name, "count": int(res.count)}


func set_frame_prop(frame_id: String, key: String, value: Variant) -> void:
	var f: FrameData = doc.frames.get(frame_id)
	if f == null or not canvas_edit_ok():
		return
	var upd := f.copy()
	upd.set(key, value)
	history.do(History.op_frame(f, upd))


# ------------------------------------------------------------------------------------------------ PDFs

const PDF_LONG_SIDE := 0.85                # a portrait page is put down this tall (metres), a landscape one this wide times 1.3

## Puts a PDF of the library down as a canvas in front of the viewer, on its first page (or `page`). {ok, message, id, name}.
func place_pdf(pdf_id: String, page: int = 1) -> Dictionary:
	if doc == null:
		return {"ok": false, "message": "No document is open in the headset."}
	if not pdfs.has(pdf_id):
		return {"ok": false, "message": "That PDF is not on the headset."}
	if not canvas_edit_ok():
		return {"ok": false, "message": "This session does not let guests add canvases."}
	var e := pdfs.entry(pdf_id)
	page = clampi(page, 1, maxi(int(e.pages), 1))
	var pts := pdfs.page_size(pdf_id, page)
	if pts == Vector2.ZERO:
		pts = Vector2(595.0, 842.0)
	var width := PDF_LONG_SIDE * pts.x / pts.y if pts.y >= pts.x else PDF_LONG_SIDE * 1.3
	var size := Vector2(width, width * pts.y / pts.x)
	var world := _front_pose(size)
	history.begin_group()
	var frame := add_frame(FrameData.CANVAS, world, size, {}, {"pdf": pdf_id, "page": page, "pdf_pages": int(e.pages), "pdf_width": width,
		"grid": "none", "backing": "none"})
	if frame == null:
		history.end_group()
		return {"ok": false, "message": "The canvas could not be created."}
	var nm := _unique_frame_name(str(e.name))
	rename_frame(frame.id, nm)
	history.end_group()
	active_frame = frame.id
	toast.emit("\"%s\" is in front of you." % nm)
	changed.emit()
	return {"ok": true, "message": "Placed", "id": frame.id, "name": nm}


## Turns a PDF canvas to a page. The owner's (or anybody allowed to move canvases) turn is everybody's: the frame's page. A guest who may
## not change canvases only looks at another page on their own headset (and is told so); `follow_pdf` brings them back to the owner's page.
func pdf_turn(frame_id: String, page: int) -> bool:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null or not f.is_pdf():
		return false
	var count := maxi(f.pdf_pages, pdfs.page_count(f.pdf))
	page = clampi(page, 1, maxi(count, 1))
	if page == doc.page_of(frame_id) and not doc.view_pages.has(frame_id):
		return true
	if session != null and not session.can_edit_canvases() and not f.locked:
		doc.view_pages[frame_id] = page if page != f.page else doc.view_pages.get(frame_id, page)
		if page == f.page:
			doc.view_pages.erase(frame_id)
		_pdf_page_changed(frame_id)
		return true
	if f.locked:
		deny_edit()
		return false
	doc.view_pages.erase(frame_id)
	var upd := f.copy()
	upd.page = page
	var pts := pdfs.page_size(f.pdf, page)
	if pts != Vector2.ZERO and f.pdf_width > 0.0:
		upd.size = Vector2(f.pdf_width, f.pdf_width * pts.y / pts.x)       # the page's own shape, at the width the canvas has
		upd.offset = Vector2.ZERO
	var keep_anchor := f
	upd.keep_anchor_of(keep_anchor)
	doc.replace_frame(upd)
	_pdf_page_changed(frame_id)
	return true


## May this headset turn the pages for everybody? (A guest may not unless the owner lets guests move canvases: they look on their own.)
func can_edit_pdf_pages() -> bool:
	return session == null or session.can_edit_canvases()


## A guest who looked at another page than the owner's goes back to it.
func pdf_follow(frame_id: String) -> void:
	if doc != null and doc.view_pages.has(frame_id):
		doc.view_pages.erase(frame_id)
		_pdf_page_changed(frame_id)


func pdf_is_following(frame_id: String) -> bool:
	return doc == null or not doc.view_pages.has(frame_id)


func _pdf_page_changed(frame_id: String) -> void:
	var fn: FrameNode = frame_nodes.get(frame_id)
	if fn != null:
		fn.refresh_pdf()
	if sel_frame == frame_id:
		clear_selection()
	changed.emit()


func _on_pdf_page(pdf_id: String, page: int, data: PdfPageData) -> void:
	for fn in frame_nodes.values():
		(fn as FrameNode).on_pdf_page(pdf_id, page, data)
	# the pages next to the one shown are made ahead (not on a Quest 2: its memory and its processor are for the page in front of you)
	if pdfs.budget.prefetch:
		for fn in frame_nodes.values():
			var n := fn as FrameNode
			if n.visible and n.data.pdf == pdf_id and doc.page_of(n.data.id) == page and page < pdfs.page_count(pdf_id):
				pdfs.request(pdf_id, page + 1)


func _on_pdf_failed(pdf_id: String, page: int, message: String) -> void:
	for fn in frame_nodes.values():
		(fn as FrameNode).on_pdf_failed(pdf_id, page, message)


func _on_pdfs_changed() -> void:
	for fn in frame_nodes.values():
		var n := fn as FrameNode
		if n.data.is_pdf():
			n.pdf_state = "" if n.pdf_state in ["missing", "failed"] else n.pdf_state
			n.refresh_pdf()
	changed.emit()


## The PDF canvas the interface's page bar belongs to: the one being looked at or worked on, else the nearest one in view.
func current_pdf_frame() -> FrameNode:
	var best: FrameNode = null
	var best_score := -INF
	for fn in frame_nodes.values():
		var n := fn as FrameNode
		if not n.visible or not n.data.is_pdf():
			continue
		var d := n.global_position.distance_to(head.origin)
		var score := -d + n.hover * 2.0 + (1.5 if n.data.id == active_frame else 0.0)
		if d < 4.0 and score > best_score:
			best_score = score
			best = n
	return best


func clear_frame(frame_id: String) -> void:
	var items := doc.items_of(frame_id)
	if items.is_empty():
		return
	history.do(History.op_remove(items))
	toast.emit("Canvas cleared (undo brings it back)")


# ------------------------------------------------------------------------------------------------ 3D models

## The size a model is first given: its real size when its longest side, read as metres, is a plausible size for a thing in a room
## (InputTuning.MODEL_REAL; glTF files are in metres), else InputTuning.MODEL_FIT along its longest side.
static func fit_scale(box: AABB) -> float:
	var l := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if l <= 0.0:
		return 1.0
	if l >= InputTuning.MODEL_REAL.x and l <= InputTuning.MODEL_REAL.y:
		return 1.0
	return InputTuning.MODEL_FIT / l


## Puts a model of the library down in front of the viewer, facing them, selected. {ok, message, id, name}.
func place_model(model_id: String) -> Dictionary:
	if doc == null:
		return {"ok": false, "message": "No document is open in the headset."}
	if not models.has(model_id):
		return {"ok": false, "message": "That model is not on the headset."}
	if not canvas_edit_ok():
		return {"ok": false, "message": "This session does not let guests add things."}
	var e := models.entry(model_id)
	var box := models.box_of(model_id)                  # (known when it was loaded on this headset before)
	var props := {"model": model_id}
	if box.size.length() > 0.0:
		props["model_box"] = box
		props["scale"] = fit_scale(box)
	var size := box.size * float(props.get("scale", 1.0)) if box.size.length() > 0.0 else Vector3.ONE * ModelNode.PLACEHOLDER
	history.begin_group()
	var frame := add_frame(FrameData.MODEL, _model_pose(size), Vector2(size.x, size.y), {}, props)
	if frame == null:
		history.end_group()
		return {"ok": false, "message": "The model could not be put down."}
	var nm := _unique_frame_name(str(e.get("name", "Model")))
	rename_frame(frame.id, nm)
	history.end_group()
	model_ctl.select(frame.id)
	toast.emit("\"%s\" is in front of you." % nm)
	changed.emit()
	return {"ok": true, "message": "Placed", "id": frame.id, "name": nm}


## Where a model of `size` (metres) is put: in front of the viewer, facing them (its +Z towards them), clear of them; a tall one stands on
## the floor, a smaller one at chest height.
func _model_pose(size: Vector3) -> Transform3D:
	var basis := Basis(Vector3.UP, _head_yaw())
	var fwd := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z)
	fwd = fwd.normalized() if fwd.length() > 0.05 else Vector3.FORWARD
	var r := size.length() * 0.5
	var pos := Vector3(head.origin.x, 0.0, head.origin.z) + fwd * maxf(InputTuning.MODEL_FRONT, 0.35 + r * 1.3)
	var fy := floor_y()
	pos.y = fy + size.y * 0.5 if size.y > 0.9 else clampf(head.origin.y - 0.25, fy + size.y * 0.5, fy + 1.9)
	return Transform3D(basis, pos)


## A model was loaded and measured for the first time (anywhere): it gets its size (fit_scale) and, now that its size is known, a place that
## suits it (a tall one on the floor, out of the viewer's way). Not an undo step: it is what putting it down meant.
func _on_model_measured(frame_id: String, box: AABB) -> void:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null or f.model_measured() or box.size.length() <= 0.0 or not canvas_edit_ok(false):
		return
	var upd := f.copy()
	upd.model_box = box
	upd.scale = upd.clamp_scale(fit_scale(box))
	var rw: Variant = room_world(f.room)
	if rw != null and not f.place_locked:
		var size := upd.model_size()
		var w := (rw as Transform3D) * f.xf
		var c := w.origin
		var flat := Vector3(c.x - head.origin.x, 0.0, c.z - head.origin.z)
		var need := 0.35 + size.length() * 0.5 * 1.3
		if flat.length() < need:
			var away := flat.normalized() if flat.length() > 0.05 else Vector3(-head.basis.z.x, 0.0, -head.basis.z.z).normalized()
			c += away * (need - flat.length())
		if size.y > 0.9:
			c.y = floor_y() + size.y * 0.5
		upd.xf = (rw as Transform3D).affine_inverse() * Transform3D(w.basis.orthonormalized(), c)
	upd.keep_anchor_of(f)
	doc.replace_frame(upd)
	print("[models] %s measured: %s" % [f.name, ModelController.size_text(upd.model_size())])


func _on_model_ready(model_id: String) -> void:
	for mn in model_nodes.values():
		if (mn as ModelNode).data.model == model_id:
			(mn as ModelNode).on_ready(model_id)
	changed.emit()


func _on_model_failed(model_id: String, message: String) -> void:
	for mn in model_nodes.values():
		(mn as ModelNode).on_failed(model_id, message)
	changed.emit()


func _on_models_changed() -> void:
	for mn in model_nodes.values():
		var n := mn as ModelNode
		if n.state != "ready":
			n.refresh()
	changed.emit()


## A change to a model frame as one undo step (`fn` changes the copy; returns false to do nothing). `moves`: it changes where the model
## is or which way it faces (refused while its place is locked).
func _model_op(frame_id: String, moves: bool, fn: Callable) -> bool:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null or not f.is_model() or not canvas_edit_ok():
		return false
	if f.locked:
		toast.emit("\"%s\" is locked." % f.name)
		return false
	if moves and place_locked(f):
		return false
	var upd := f.copy()
	if not bool(fn.call(upd)):
		return false
	upd.keep_anchor_of(f)
	history.do(History.op_frame(f, upd))
	return true


## The model comes down (or up) until it stands on the surface under it: a table the headset knows, else the floor.
func lay_down_model(frame_id: String) -> void:
	var mn: ModelNode = model_nodes.get(frame_id)
	var rw: Variant = room_world(current_room)
	if mn == null or not mn.visible or rw == null:
		return
	var low := INF
	for c in mn.corners():
		low = minf(low, (c as Vector3).y)
	var under: Variant = _floor_under(mn.global_position)
	if under == null:
		return
	var dy := float(under) - low
	if absf(dy) < 0.001:
		toast.emit("It is standing on the surface already.")
		return
	var room := rw as Transform3D
	var done := _model_op(frame_id, true, func(u: FrameData) -> bool:
		var w := room * u.xf
		w.origin.y += dy
		u.xf = room.affine_inverse() * w
		return true)
	if done:
		toast.emit("Put down on the %s." % ("floor" if absf(float(under) - floor_y()) < 0.02 else "surface under it"))


## Upright (turned only about the vertical, the way it faces kept), not stretched, at its first size.
func reset_model(frame_id: String) -> void:
	_model_op(frame_id, false, func(u: FrameData) -> bool:
		var b := u.xf.basis.orthonormalized()
		var z := Vector3(b.z.x, 0.0, b.z.z)
		if z.length() < 0.2:
			z = Vector3(-b.y.x, 0.0, -b.y.z) if b.z.y > 0.0 else Vector3(b.y.x, 0.0, b.y.z)
		z = z.normalized() if z.length() > 1e-3 else Vector3.BACK
		u.xf.basis = Basis(Vector3.UP, atan2(z.x, z.z))
		u.stretch = Vector3.ONE
		u.scale = u.clamp_scale(fit_scale(u.model_box))
		return true)


## The size the file says, read as metres (glTF files are in metres; an OBJ says nothing about its units).
func real_size_model(frame_id: String) -> void:
	var done := _model_op(frame_id, false, func(u: FrameData) -> bool:
		u.scale = u.clamp_scale(1.0)
		u.stretch = Vector3.ONE
		return true)
	if done:
		toast.emit("Real size: %s." % ModelController.size_text((doc.frames[frame_id] as FrameData).model_size()))


## A copy beside it (to its right as you look at it), selected.
func duplicate_model(frame_id: String) -> void:
	var f: FrameData = doc.frames.get(frame_id) if doc != null else null
	if f == null or not f.is_model() or not canvas_edit_ok():
		return
	var c := f.copy()
	c.id = U.uid("f")
	c.name = _unique_frame_name(f.name)
	c.keep_anchor_of(null)
	c.locked = false
	c.place_locked = false
	c.created = int(Time.get_unix_time_from_system())
	var rw: Variant = room_world(f.room)
	var right := Vector3(head.basis.x.x, 0.0, head.basis.x.z).normalized()
	var w: Transform3D = (rw as Transform3D) * f.xf if rw != null else f.xf
	var size := f.model_size() if f.model_measured() else Vector3.ONE * ModelNode.PLACEHOLDER
	w.origin += right * (size.length() * 0.6 + 0.05)
	c.xf = (rw as Transform3D).affine_inverse() * w if rw != null else w
	if room_guessed(c.room):
		_moved_unanchored[c.id] = true
	history.do(History.op_frame_add(c))
	model_ctl.select(c.id)


## Brings a model within reach: its middle in front of you, the way it faces kept (one undo step, a new anchor where it lands).
func bring_model(frame_id: String) -> void:
	var rw: Variant = room_world(current_room)
	if rw == null:
		return
	var room := rw as Transform3D
	_model_op(frame_id, true, func(u: FrameData) -> bool:
		var size := u.model_size() if u.model_measured() else Vector3.ONE * ModelNode.PLACEHOLDER
		var pose := _model_pose(size)
		u.xf = room.affine_inverse() * Transform3D((room * u.xf).basis.orthonormalized(), pose.origin)
		return true)


# ------------------------------------------------------------------------------------------------ canvas placement

## Start placing a new canvas: a ghost follows the pen / hand ray until it is confirmed (kind: "wall" | "table").
func begin_place(kind: String = "wall", size: Vector2 = Vector2(1.2, 0.8)) -> void:
	if not canvas_edit_ok():
		return
	cancel_place()
	surface.cancel()
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


# ------------------------------------------------------------------------------------------------ text placement

## The placement tool for words (the AI's text): a ghost of the text follows the pen / hand ray over the canvas it points at; tap
## with the stylus tip or pinch to put it down there (one undo step, selected so it can be moved), the back button cancels.
func begin_place_text(text: String, wrap: int = TextController.AI_WRAP) -> void:
	if doc == null or text.strip_edges() == "":
		return
	cancel_place()
	cancel_place_text()
	surface.cancel()
	placing_text = {"text": text.strip_edges(), "wrap": wrap, "frame": "", "item": null, "center": Vector2.ZERO}
	toast.emit("Point at a canvas and tap with the stylus or pinch to put the text down. Back cancels.")
	changed.emit()


func cancel_place_text() -> void:
	if placing_text.is_empty():
		return
	_clear_text_ghost()
	placing_text = {}
	changed.emit()


## Put the text down where the ghost is (on the canvas pointed at). Returns the new item, or null when no canvas is pointed at.
func confirm_place_text() -> Item:
	if placing_text.is_empty():
		return null
	if str(placing_text.frame) == "":
		toast.emit("Point at a canvas first.")
		return null
	var t: Item = texts.place_at(str(placing_text.text), str(placing_text.frame), placing_text.center, int(placing_text.wrap))
	if t == null:
		toast.emit("That canvas cannot take the text (it is locked).")
		return null
	cancel_place_text()
	toast.emit("Text placed (undo takes it back).")
	return t


## No pointing needed: put the text on the canvas you are looking at, below the text already there.
func place_text_here() -> Item:
	if placing_text.is_empty():
		return null
	var text := str(placing_text.text)
	var wrap := int(placing_text.wrap)
	var spot := dictation_spot()
	if spot.is_empty():
		toast.emit("Place a canvas first, then put the text on it.")
		return null
	cancel_place_text()
	return texts.place_at(text, str(spot.frame), spot.center, wrap, true)


## The canvas a ray from `o` along `d` hits first: {fn, local (frame metres)} or {} (locked canvases and the ones behind are skipped).
func ray_canvas(o: Vector3, d: Vector3) -> Dictionary:
	var best := {}
	var best_t := INF
	for fn in visible_frames(FrameData.CANVAS):
		var n := fn as FrameNode
		if n.data.locked:
			continue
		var hit := n.ray_hit(o, d, 0.001)
		if hit.is_empty() or float(hit.t) >= best_t:
			continue
		var g: Vector3 = hit.local
		if n.bounds().has_point(Vector2(g.x, g.y)):
			best_t = float(hit.t)
			best = {"fn": n, "local": Vector2(g.x, g.y)}
	return best


func _clear_text_ghost() -> void:
	var fn: FrameNode = frame_nodes.get(str(placing_text.get("frame", "")))
	if fn != null:
		fn.show_ghost(null, Vector2.ZERO)


func _update_placing_text(pen: PenState, hands: Array) -> void:
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
		var hit := ray_canvas(o, d)
		var old := str(placing_text.frame)
		var fid := "" if hit.is_empty() else (hit.fn as FrameNode).data.id
		if fid != old:
			_clear_text_ghost()
			placing_text.frame = fid
			placing_text.item = null
			changed.emit()                                  # the card names the canvas pointed at
		if fid != "":
			if placing_text.item == null:
				var g := texts.make(str(placing_text.text), fid, int(placing_text.wrap))
				g.color = Color(g.color.r, g.color.g, g.color.b, 0.65)
				g.center = Vector2.ZERO
				placing_text.item = g
			placing_text.center = _text_centre(hit.local, (placing_text.item as Item).size, hit.fn)
			(hit.fn as FrameNode).show_ghost(placing_text.item, placing_text.center)
	var confirm := false
	if pen.tracked and pen.down and not _was_down:
		confirm = true
	for h in hands:
		if (h as HandInput).pinch_down:
			confirm = true
	_was_down = pen.down
	if pen.back and not _was_back:
		cancel_place_text()
		return
	_was_back = pen.back
	if confirm and have:
		confirm_place_text()


## The pointed-at spot as the text's middle, kept so the whole text stays on the canvas's drawn area where it fits.
func _text_centre(p: Vector2, size: Vector2, fn: FrameNode) -> Vector2:
	var r := fn.bounds()
	var lo := r.position + size * 0.5
	var hi := r.end - size * 0.5
	return Vector2(clampf(p.x, lo.x, maxf(lo.x, hi.x)) if hi.x >= lo.x else r.get_center().x, clampf(p.y, lo.y, maxf(lo.y, hi.y)) if hi.y >= lo.y else r.get_center().y)


# ------------------------------------------------------------------------------------------------ selection and editing

func select_items(ids: Array, frame_id: String) -> void:
	if not ids.is_empty() and model_ctl.selected != "":
		model_ctl.deselect()                         # one selection at a time: items on a canvas, or a model
	var old := sel_frame
	selection = ids.duplicate()
	sel_frame = frame_id if not ids.is_empty() else ""
	if not ids.is_empty():
		bar_ghost = {}
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
	var gh := _bar_snapshot()
	history.begin_group()
	_release_glue_to(items)
	history.do(History.op_remove(items))
	history.end_group()
	clear_selection()
	gh.serial = history.serial
	bar_ghost = gh


## The selection's button column as it is now (for bar_ghost), or {} with nothing selected.
func _bar_snapshot() -> Dictionary:
	var items := selected_items()
	if items.is_empty() or sel_frame == "":
		return {}
	return {"frame": sel_frame, "rect": pen_ctl.group_bounds(items), "serial": history.serial, "ids": selection.duplicate()}


## The items the buttons beside the selection act on: the selection, or what it was just before it went away.
func bar_ids() -> Array:
	if not selection.is_empty():
		return selection
	return bar_ghost.get("ids", [])


## Undo (or redo) the latest operation on the buttons' items only.
func _bar_history(redo_it: bool) -> bool:
	var ids := bar_ids()
	var gh := _bar_snapshot()
	if gh.is_empty() and not bar_ghost.is_empty():
		gh = bar_ghost
	var op := history.redo_local(ids) if redo_it else history.undo_local(ids)
	if op.is_empty():
		return false
	# taking back a delete selects what came back, so the buttons stay for redo
	var back: Array = []
	if not redo_it:
		for id in _removed_ids(op):
			if doc.items.has(id):
				back.append(id)
	if not back.is_empty():
		select_items(back, (doc.items[back[0]] as Item).frame)
	else:
		_after_history(gh)
	return true


## The undo / redo buttons that stay behind on `frame_id` after the selection went away, or {}.
func ghost_bar(frame_id: String) -> Dictionary:
	if bar_ghost.is_empty() or not selection.is_empty() or bar_ghost.frame != frame_id or int(bar_ghost.serial) != history.serial:
		return {}
	return bar_ghost


## A button beside the selection was pressed ("undo", "redo" or "delete").
func bar_action(id: String) -> void:
	match id:
		"undo":
			toast.emit("Undo" if _bar_history(false) else "Nothing to undo for this")
		"redo":
			toast.emit("Redo" if _bar_history(true) else "Nothing to redo for this")
		"delete":
			delete_selection()
			toast.emit("Deleted: undo brings it back")


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


## Give the selected items another colour (only the colour: widths, brushes and fill strength stay). One undo step.
func recolor_selection(col: Color) -> void:
	var items := selected_items()
	if items.is_empty():
		return
	var before: Array = []
	var after: Array = []
	for it in items:
		var item: Item = it
		before.append(item.duplicate_item(false))
		var c := item.duplicate_item(false)
		c.color = Color(col.r, col.g, col.b, c.color.a if c.kind != Item.TEXT else 1.0)
		if c.kind == Item.SHAPE and c.fill.a > 0.0:
			c.fill = Color(col.r, col.g, col.b, c.fill.a)
		after.append(c)
	history.do(History.op_modify(before, after))


## Fill the selected closed shapes with their colour, or take the fill away when they are all filled. One undo step.
func toggle_fill_selection() -> void:
	var shapes: Array = selected_items().filter(func(it): return (it as Item).kind == Item.SHAPE and not (it as Item).is_line())
	if shapes.is_empty():
		return
	var all_filled := shapes.all(func(it): return (it as Item).fill.a > 0.0)
	var before: Array = []
	var after: Array = []
	for it in shapes:
		var item: Item = it
		before.append(item.duplicate_item(false))
		var c := item.duplicate_item(false)
		c.fill = Color(0, 0, 0, 0) if all_filled else Color(c.color.r, c.color.g, c.color.b, float(App.val("fill_alpha")))
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
	if history == null:
		return
	var gh := _bar_snapshot()
	if history.undo():
		_after_history(gh)


func redo() -> void:
	if history == null:
		return
	var gh := _bar_snapshot()
	if history.redo():
		_after_history(gh)


## Ids of the items an operation removes (inside groups too).
func _removed_ids(op: Dictionary) -> Array:
	var out: Array = []
	match str(op.type):
		"remove":
			for d in op["items"]:
				out.append(str(d.id))
		"group":
			for o in op["ops"]:
				out.append_array(_removed_ids(o))
	return out


func _after_history(gh: Dictionary = {}) -> void:
	var keep: Array = []
	for id in selection:
		if doc.items.has(id):
			keep.append(id)
	if keep.size() != selection.size():
		select_items(keep, sel_frame)
	if selection.is_empty() and not gh.is_empty():
		bar_ghost = gh


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
	last_pen = pen
	if doc == null:
		return
	if head_provider.is_valid():
		head = head_provider.call()
	_update_rooms(dt)
	_place_frames(dt)
	_reconcile(dt)
	session.tick(pen, hands, dt)
	if not placing.is_empty():
		_update_placing(pen, hands, dt)
	elif not placing_text.is_empty():
		_update_placing_text(pen, hands)
	elif surface.finding() or surface.aligning():
		surface.update(pen, dt)                       # the nib is feeling for the desk: it neither draws nor grabs meanwhile
	elif session.aligning():
		session.align_update(pen, hands, dt)          # the nib (or a pinch) is touching the two points the session lines up on: nothing draws or grabs
	else:
		# a pointer on a 3D model (or one of its handles) is the model's: the canvases' controllers leave it alone this frame
		model_ctl.update(hands, dt, pen)
		hand_ctl.skip = model_ctl.claimed
		# the front button grabs with the same rules as a pinch (HandController); while it holds something no stroke may start
		hand_ctl.update(hands, dt, pen)
		pen_ctl.blocked = hand_ctl.pen_busy() or model_ctl.pen_busy()
		pen_ctl.update(pen, dt)
		surface.track(pen, dt)
	if not (placing.is_empty() and placing_text.is_empty() and not surface.finding() and not surface.aligning() and not session.aligning()):
		model_ctl.layout()                            # (nothing points at models meanwhile, but the handles follow the model)
	lighting.follow(head, dt)
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
			var gh := fn.ray_hit(gaze_o, gaze_d, 0.001)
			if not gh.is_empty():
				var g: Vector3 = gh.local
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
	if not bar_ghost.is_empty():
		if ghost_bar(str(bar_ghost.frame)).is_empty():
			bar_ghost = {}
		else:
			active[str(bar_ghost.frame)] = true
	if pen_ctl.cursor_frame != "":
		active[pen_ctl.cursor_frame] = true
	for c in hand_ctl.controllers():                  # a loop drawn from a distance
		var ctl := c as PenController
		if ctl.state == PenController.S.LASSO and ctl.working_frame() != null:
			active[ctl.working_frame().data.id] = true
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
	for c in hand_ctl.controllers():
		(c as PenController).draw_lasso(od, fn)


func _process(_delta: float) -> void:
	if doc != null:
		refresh_overlays()
		pen_ctl.flush_live()
