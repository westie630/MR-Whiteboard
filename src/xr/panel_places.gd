class_name PanelPlaces
extends RefCounted
## Where the movable panels of the headset's interface (the dock, Home, the assistant) were left, kept in the real room: across
## restarts, the headset being taken off and put back on, and recentring. Their poses are stored relative to a spatial anchor of their
## own (one for all of them, made where the dock is), in user://panel_places.json, together with which side panels were open, so they
## follow the room whenever the headset moves its tracking space under it. They do not belong to a document: switching documents leaves
## them where they are. Without anchors (the PC) the poses are kept as they are.
##
## The rig asks place_of() where a panel goes, and tells put() whenever the user puts panels somewhere (moved by the handle, summoned,
## opened beside the dock). A dock put far from the anchor gets a new anchor where it is (anchors are exact near themselves).

const FILE := "user://panel_places.json"
const TAG := "ui:panels"
const REANCHOR_M := 1.5
const RETRY_MIN_S := 3.0
const RETRY_MAX_S := 60.0

var anchors: AnchorService
var path := FILE
var anchor := ""                           # uuid of the panels' anchor ("" = none yet)
var rel := {}                              # panel id -> Transform3D relative to the anchor (unanchored: world)
var open := {}                             # side panel id -> true while it is open
var _world := {}                           # panel id -> world pose it was last put at (re-based when a new anchor arrives)
var _pending := false
var _pending_pose := Transform3D.IDENTITY
var _pending_old: Variant = null           # the old anchor's pose when the new one was asked for (null: it was not tracked)
var _want := false                         # a new anchor is wanted (none yet, or the dock was put far from it, or making one failed)
var _held := false                         # panels were put while the anchor was still being placed: no new anchor until it is decided
var _retry_at := 0
var _fails := 0
var _smooth := AnchorSmoother.new()
var _frame := Transform3D.IDENTITY


func setup(service: AnchorService, file: String = FILE) -> void:
	anchors = service
	path = file
	_load()
	if anchors != null:
		anchors.created.connect(_on_created)
		anchors.create_failed.connect(_on_failed)
		if anchor != "":
			anchors.track([anchor])


## Are the places kept in the room by an anchor (the headset), rather than as poses in the tracking space (the PC)?
func anchored() -> bool:
	return anchors != null and anchors.is_supported()


func has(id: String) -> bool:
	return rel.has(id)


## Is it known where the saved places are right now? (Anchored: the anchor is tracked.)
func known() -> bool:
	return not anchored() or (anchor != "" and anchors.has_pose(anchor))


## Every frame: steadies the anchor's pose (see AnchorSmoother) and asks again for an anchor that could not be made.
func update(dt: float) -> void:
	if not anchored():
		return
	if anchor != "" and anchors.has_pose(anchor):
		_frame = _smooth.feed(anchors.pose(anchor), dt)
	else:
		_smooth.reset()
	if _held:
		if known():
			# it was only slow: the places it holds stand, and the panels go back to them (where they were put meanwhile was only
			# the stand-in for those places: in front of the user at the start)
			_held = false
			_want = false
			_world.clear()
		elif not anchors.locating(anchor):
			_held = false                          # it is not here after all: what was put meanwhile gets an anchor of its own
	if _want and not _pending and not _held and Time.get_ticks_msec() >= _retry_at and _world.has("dock"):
		_request(_world["dock"])


## The tracking space moved under the room (recentred, headset back on): the steadied pose starts afresh.
func tracking_reset() -> void:
	_smooth.reset()


## Where a panel goes now (world), or null while it has no saved place or the anchor is not tracked.
func place_of(id: String) -> Variant:
	if not rel.has(id):
		return null
	if not anchored():
		return rel[id]
	if not known():
		return null
	if not _smooth.has_pose():
		update(0.0)
	return _frame * (rel[id] as Transform3D)


## The user put panels somewhere: `poses` is panel id -> world pose. Saved at once.
func put(poses: Dictionary) -> void:
	if poses.is_empty():
		return
	for id in poses:
		_world[id] = poses[id]
	if not anchored():
		for id in poses:
			rel[id] = poses[id]
		_save()
		return
	var dock: Transform3D = _world.get("dock", poses.values()[0])
	if known():
		if not _smooth.has_pose():
			update(0.0)
		for id in poses:
			rel[id] = _frame.affine_inverse() * (poses[id] as Transform3D)
		_save()
		if _frame.origin.distance_to(dock.origin) > REANCHOR_M:
			_want = true                       # still right, but a new anchor near the dock is more exact
	else:
		_want = true                           # no anchor, or it is not here (another room, a reset Space Setup): a new one
		if anchor != "" and anchors.locating(anchor):
			_held = true                       # ...unless the headset is still placing it (just put on): wait for it, see update()
	if _want and not _pending and not _held and Time.get_ticks_msec() >= _retry_at:
		_request(dock)


func set_open(id: String, on: bool) -> void:
	if bool(open.get(id, false)) == on:
		return
	if on:
		open[id] = true
	else:
		open.erase(id)
	_save()


func is_open(id: String) -> bool:
	return bool(open.get(id, false))


func _request(at: Transform3D) -> void:
	_want = false
	_pending = true
	if known() and not _smooth.has_pose():
		update(0.0)
	_pending_old = _frame if (anchor != "" and known()) else null
	var f := -at.basis.z
	_pending_pose = Transform3D(Basis(Vector3.UP, atan2(-f.x, -f.z)), at.origin)       # standing level, turned like the dock
	anchors.create(_pending_pose, TAG)


func _on_created(tag: String, uuid: String) -> void:
	if tag != TAG:
		return
	if not _pending:
		anchors.erase(uuid)
		return
	_pending = false
	_fails = 0
	# every panel keeps its place in the room: the ones put since the last anchor from where they were put, the others through the old
	# anchor as it was when the new one was asked for (all in the tracking space of that moment, so a recentre since changes nothing)
	var old := anchor
	var worlds := _world.duplicate()
	if _pending_old != null:
		for id in rel:
			if not worlds.has(id):
				worlds[id] = (_pending_old as Transform3D) * (rel[id] as Transform3D)
	var inv := _pending_pose.affine_inverse()
	rel.clear()
	for id in worlds:
		rel[id] = inv * (worlds[id] as Transform3D)
	_world.clear()
	anchor = uuid
	_smooth.reset()
	_save()
	if old != "" and old != uuid:
		anchors.untrack(old)
		anchors.erase(old)
	print("[panels] anchored to the room (%s), %d places" % [uuid.substr(0, 8), rel.size()])


func _on_failed(tag: String) -> void:
	if tag != TAG:
		return
	_pending = false
	_want = true
	_fails += 1
	_retry_at = Time.get_ticks_msec() + int(minf(RETRY_MIN_S * pow(2.0, _fails - 1), RETRY_MAX_S) * 1000.0)


func _load() -> void:
	var from := path if FileAccess.file_exists(path) else path + ".tmp"     # (a save cut short between its two steps)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(from)) if FileAccess.file_exists(from) else null
	if not (parsed is Dictionary):
		return
	var d: Dictionary = parsed
	anchor = str(d.get("anchor", ""))
	var r: Variant = d.get("rel", {})
	if r is Dictionary:
		for id in r:
			if r[id] is Array and (r[id] as Array).size() == 12:
				rel[str(id)] = U.xf_from_array(r[id])
	var o: Variant = d.get("open", {})
	if o is Dictionary:
		for id in o:
			if bool(o[id]):
				open[str(id)] = true


func _save() -> void:
	var r := {}
	for id in rel:
		r[id] = U.xf_to_array(rel[id])
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"anchor": anchor, "rel": r, "open": open}))
	f.close()
	DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp, path)
