class_name MetaAnchors
extends AnchorService
## Persistent spatial anchors on the Quest (XR_FB_spatial_entity + storage, through the Godot OpenXR Vendors plugin's
## OpenXRFbSpatialAnchorManager). An anchor is tied to the real room: it is saved on the device, found again at the next launch
## and follows the room whenever the headset re-localises. Many anchors at once: one per room and one per canvas / 3D sketch.
##
## Written from what works in the Apex MR app on the same headset, and what the Quest 3 logs showed:
##  - anchors are looked up with a storage query by uuid (load_anchors() was observed to accept a request and never answer) and
##    tracked here: track() on the entity, which makes the plugin locate it every frame, and an XRAnchor3D on that tracker. Not through
##    the manager's track_anchor(): that saves the anchor to storage again first and tracks it only if the save succeeds, and after the
##    headset has been off every one of those saves fails ("Unable to save spatial anchor ... to local storage"), so no anchor ever
##    came back and every room was shown in front of the user instead;
##  - just after the headset is put on (hand tracking not even up yet) the stored anchors are found at once but take well over 5 s to
##    become locatable: giving up on them then put every room in front of the user and moved the panels' anchor to where they had been
##    put meanwhile. Such an anchor is `locating()` for LOCATE_S, and the board and the panels wait for it;
##  - new anchors are created one at a time through the manager and saved to storage, with retries;
##  - when the VR session stops (headset off) the manager drops the anchors it made, and the ones tracked here are let go too. The
##    session itself lives on, and so do the entities: when it runs again each is tracked again at once, without a query.

const STORAGE_LOCAL := 0
const SAVE_ATTEMPTS := 4
const QUERY_TIMEOUT_MS := 10000
const RETRY_S := 12.0
const MAX_RETRIES := 6
const LOCATABLE_WAIT_S := 8.0              # a stored anchor made locatable is looked up again (a fresh entity) if it is not after this
const LOCATE_S := 30.0                     # an anchor found on the device is "locating" (worth waiting for) this long, headset on, until placed

var _mgr: Node
var _origin: Node3D
var _supported := false
var _live := true                          # false while the VR session is stopped (the headset is off)
var _locatable := 0                        # OpenXRFbSpatialEntity.COMPONENT_TYPE_LOCATABLE
var _wanted: Dictionary = {}               # uuid -> true: anchors the document uses
var _nodes: Dictionary = {}                # uuid -> XRAnchor3D (tracked now)
var _own: Dictionary = {}                  # uuid -> true: its node is ours (_follow), not the manager's
var _enabling: Dictionary = {}             # uuid -> seconds: being made locatable (see _follow)
var _entities: Dictionary = {}             # uuid -> OpenXRFbSpatialEntity
var _had_pose: Dictionary = {}
var _create_queue: Array = []              # [{pose, tag}]
var _creating: Dictionary = {}
var _query: Object
var _query_started_ms := 0
var _retry_t := 0.0
var _retries := 0
var _missing: Dictionary = {}              # uuid -> true: asked for, not found on this device (yet)
var _found: Dictionary = {}                # uuid -> seconds (headset on) since it was found on the device without a pose (see locating)
var _log: PackedStringArray = []


func setup(origin: Node3D) -> bool:
	_origin = origin
	_supported = _extensions_supported() and ClassDB.class_exists("OpenXRFbSpatialAnchorManager")
	if not _supported:
		print("[anchors] spatial entity extensions are not available")
		return false
	_locatable = ClassDB.class_get_integer_constant("OpenXRFbSpatialEntity", "COMPONENT_TYPE_LOCATABLE")
	_mgr = ClassDB.instantiate("OpenXRFbSpatialAnchorManager")
	var ps := PackedScene.new()
	var n := Node3D.new()
	n.name = "AnchorMarker"
	ps.pack(n)
	n.free()
	_mgr.set("scene", ps)
	_mgr.set("visible", false)
	origin.add_child(_mgr)
	_mgr.connect("openxr_fb_spatial_anchor_tracked", _on_tracked)
	_mgr.connect("openxr_fb_spatial_anchor_create_failed", _on_create_failed)
	_mgr.connect("openxr_fb_spatial_anchor_load_failed", func(u, _d, _l): _note("loading %s failed" % str(u).substr(0, 8)))
	_mgr.connect("openxr_fb_spatial_anchor_track_failed", func(_e): _note("tracking an anchor failed"))
	_mgr.connect("openxr_fb_spatial_anchor_untracked", _on_untracked)
	print("[anchors] ready")
	return true


func _extensions_supported() -> bool:
	for pair in [["OpenXRFbSpatialEntityExtension", "is_spatial_entity_supported"], ["OpenXRFbSpatialEntityStorageExtension", "is_spatial_entity_storage_supported"]]:
		if not Engine.has_singleton(pair[0]):
			return false
		var ext: Object = Engine.get_singleton(pair[0])
		if not ext.has_method(pair[1]) or not bool(ext.call(pair[1])):
			return false
	return true


func is_supported() -> bool:
	return _supported


func status() -> String:
	var placing := 0
	for u in _found:
		if locating(u):
			placing += 1
	return "anchors: %d wanted, %d tracked, %d locating, %d missing, queue %d" % [_wanted.size(), _nodes.size(), placing, _missing.size(), _create_queue.size()]


func _note(s: String) -> void:
	print("[anchors] ", s)
	_log.append(s)
	if _log.size() > 40:
		_log.remove_at(0)


# ------------------------------------------------------------------------------------------------ queries

func has_pose(uuid: String) -> bool:
	var n: Variant = _nodes.get(uuid)                      # Variant: the plugin frees these nodes when the session ends, and a typed variable cannot hold a freed one
	return n != null and is_instance_valid(n) and bool((n as Node3D).call("get_has_tracking_data")) and bool((n as Node3D).call("get_is_active"))


func known() -> Array:
	return _nodes.keys()


func pose(uuid: String) -> Transform3D:
	var n: Variant = _nodes.get(uuid)
	return (n as Node3D).global_transform if n != null and is_instance_valid(n) else Transform3D.IDENTITY


## Found on the device, not placed yet, for less than LOCATE_S with the headset on: the room is still being found (a Quest 3 put back
## on took more than 5 s, and the board and the panels gave up on anchors that were only slow, see AnchorService.locating).
func locating(uuid: String) -> bool:
	return _found.has(uuid) and float(_found[uuid]) < LOCATE_S and not has_pose(uuid)


func _has_node(uuid: String) -> bool:
	return _nodes.has(uuid) and is_instance_valid(_nodes[uuid])


func _process(delta: float) -> void:
	if not _supported:
		return
	# the manager dropped the nodes of the anchors it made (the session stopped): they are tracked again when it runs
	var lost := false
	for u in _nodes.keys():
		if not is_instance_valid(_nodes[u]):
			_nodes.erase(u)
			_own.erase(u)
			lost = true
	if lost and _live:
		_note("anchor nodes dropped: tracking them again")
		reload()
	_settle(delta)
	for u in _found.keys():
		if has_pose(u) or not _wanted.has(u):
			_found.erase(u)
		elif _live:
			_found[u] = float(_found[u]) + delta
	for u in _wanted.keys():
		var now := has_pose(u)
		if now != bool(_had_pose.get(u, false)):
			_had_pose[u] = now
			tracking_changed.emit(u, now)
	# anchors that were not found yet are asked for again for a while (the headset may still be localising)
	if not _missing.is_empty() and _query == null:
		_retry_t += delta
		if _retry_t > RETRY_S and _retries < MAX_RETRIES:
			_retry_t = 0.0
			_retries += 1
			_lookup()


## The session runs (again): track every wanted anchor that is not tracked (the ones known from before at once, the rest looked up).
func reload() -> void:
	_live = true
	_retries = 0
	_retry_t = 0.0
	for u in _wanted:
		if not has_pose(u) and (_entities.has(u) or _found.has(u)):
			_found[u] = 0.0                      # known from before the headset was off: placed again, which takes a while
	_lookup()


## The VR session stopped (the headset was taken off): the anchors tracked here are let go like the manager's, with no pose until it
## runs again (reload). Their entities are kept for that, unless `lost`: the session itself is gone, and their handles with it.
func suspend(lost: bool = false) -> void:
	if not _supported:
		return
	_live = false
	for u in _own.keys():
		var n: Variant = _nodes.get(u)
		if n != null and is_instance_valid(n):
			(n as Node).queue_free()
		_nodes.erase(u)
		var e: Object = _entities.get(u)
		if e != null:
			e.call("untrack")
	_own.clear()
	_enabling.clear()
	if lost:
		_entities.clear()


func track(uuids: Array) -> void:
	if not _supported:
		return
	for u in uuids:
		_wanted[str(u)] = true
	_lookup()


func _lookup() -> void:
	if not _supported or not _live:
		return
	var need: Array = []
	for u in _wanted.keys():
		if _has_node(u) or _enabling.has(u):
			continue
		if _entities.has(u):
			_follow(_entities[u])                    # known from before the headset was off
		else:
			need.append(StringName(u))
	if need.is_empty():
		return
	if _query != null and Time.get_ticks_msec() - _query_started_ms < QUERY_TIMEOUT_MS:
		return
	_query = ClassDB.instantiate("OpenXRFbSpatialEntityQuery")
	_query.call("set_max_results", maxi(need.size() + 8, 32))
	_query.call("set_timeout", 8.0)
	_query.call("query_by_uuid", need, STORAGE_LOCAL)
	_query.connect("openxr_fb_spatial_entity_query_completed", _on_query_done.bind(need), CONNECT_ONE_SHOT)
	_query_started_ms = Time.get_ticks_msec()
	var rc := int(_query.call("execute"))
	if rc != 0:
		_note("the storage query could not start (code %d)" % rc)
		_query = null


func _on_query_done(results: Array, asked: Array) -> void:
	_query = null
	var found := {}
	for e in results:
		found[str(e.get("uuid"))] = e
	for a in asked:
		if found.has(str(a)):
			_missing.erase(str(a))
			if not _found.has(str(a)) and not has_pose(str(a)):
				_found[str(a)] = 0.0
		else:
			_missing[str(a)] = true              # (one found before stays `locating` until LOCATE_S: a query that failed answers "none")
	_note("storage query: asked %d, found %d" % [asked.size(), found.size()])
	for id in found:
		if _wanted.has(id) and not _has_node(id):
			_follow(found[id])


## Track a stored anchor here (see the top of this file): make it locatable if it is not yet, then follow it. The headset answers
## the request before its status says so (the plugin's track() refuses it then), so it is followed only once the status agrees: _settle.
func _follow(e: Object) -> void:
	var u := str(e.get("uuid"))
	_entities[u] = e
	if not _live or not _wanted.has(u) or _has_node(u) or _enabling.has(u):
		return
	if bool(e.call("is_component_enabled", _locatable)):
		_attach(e)
		return
	_enabling[u] = 0.0
	e.connect("openxr_fb_spatial_entity_set_component_enabled_completed", func(ok, _component, _enabled):
		if not ok and not _has_node(u) and not bool(e.call("is_component_enabled", _locatable)):
			_give_up(u, e, "could not be made locatable"), CONNECT_ONE_SHOT)
	e.call("set_component_enabled", _locatable, true)


## Every frame: the anchors being made locatable are followed as soon as the headset says they are. One that is not after
## LOCATABLE_WAIT_S is looked up again at once: a fresh entity of an anchor the headset has placed meanwhile is locatable straight away
## (seen on a Quest 3 put back on). It stays `locating` all the while, so nothing gives up on it.
func _settle(delta: float) -> void:
	var again := false
	for u in _enabling.keys():
		var e: Object = _entities.get(u)
		if e == null or not _live or not _wanted.has(u) or _has_node(u):
			_enabling.erase(u)
		elif bool(e.call("is_component_enabled", _locatable)):
			_enabling.erase(u)
			_attach(e)
		else:
			_enabling[u] = float(_enabling[u]) + delta
			if float(_enabling[u]) > LOCATABLE_WAIT_S:
				_give_up(u, e, "is not locatable yet: looking it up again")
				again = true
	if again:
		_lookup()


## An anchor that cannot be followed: its entity is forgotten and it is looked up again in a while.
func _give_up(u: String, e: Object, why: String) -> void:
	_enabling.erase(u)
	if _entities.get(u) == e:
		_entities.erase(u)
		_missing[u] = true
		_note("anchor %s %s" % [u.substr(0, 8), why])


func _attach(e: Object) -> void:
	var u := str(e.get("uuid"))
	if not _live or not _wanted.has(u) or _has_node(u):
		return
	e.call("track")
	if not bool(e.call("is_tracked")):
		_give_up(u, e, "could not be tracked")
		return
	var node := XRAnchor3D.new()
	node.name = "Anchor_" + u.substr(0, 8)
	node.tracker = StringName(u)
	_origin.add_child(node)
	_nodes[u] = node
	_own[u] = true
	_missing.erase(u)
	_note("tracking stored anchor %s" % u.substr(0, 8))
	tracking_changed.emit(u, has_pose(u))


func _on_tracked(anchor_node: Node, entity: Object, is_new: bool) -> void:
	if not is_new:
		return                                       # (stored anchors are tracked by _follow, not handed to the manager)
	var uuid := str(entity.get("uuid"))
	if _creating.is_empty():
		_note("an anchor appeared that nobody asked for: keeping it untracked")
		_mgr.call("untrack_anchor", StringName(uuid))
		return
	var tag: String = _creating.tag
	_creating = {}
	_nodes[uuid] = anchor_node
	_entities[uuid] = entity
	_wanted[uuid] = true
	_note("created %s for %s" % [uuid.substr(0, 8), tag])
	_save(entity, 1)
	created.emit(tag, uuid)
	_pump()


func _on_untracked(anchor_node: Node, entity: Object) -> void:
	var uuid := str(entity.get("uuid")) if entity != null else ""
	if uuid != "" and _nodes.get(uuid) == anchor_node:
		_nodes.erase(uuid)


# ------------------------------------------------------------------------------------------------ creating

func create(world_pose: Transform3D, tag: String) -> void:
	if not _supported:
		create_failed.emit(tag)
		return
	_create_queue.append({"pose": world_pose, "tag": tag})
	_pump()


func _pump() -> void:
	if not _creating.is_empty() or _create_queue.is_empty():
		return
	_creating = _create_queue.pop_front()
	var local := _origin.global_transform.affine_inverse() * (_creating.pose as Transform3D)
	_mgr.call("create_anchor", local, {"tag": _creating.tag})


func _on_create_failed(_t: Transform3D, _d: Dictionary) -> void:
	var tag := str(_creating.get("tag", ""))
	_creating = {}
	_note("creating the anchor for %s failed" % tag)
	create_failed.emit(tag)
	_pump()


## Write the anchor to the device's storage; one that is not stored is gone at the next launch, so a failed write is repeated.
func _save(entity: Object, attempt: int) -> void:
	entity.connect("openxr_fb_spatial_entity_saved", func(ok, _loc):
		_note("saved %s: %s%s" % [str(entity.get("uuid")).substr(0, 8), str(ok), "" if ok else " (attempt %d)" % attempt])
		if not ok and attempt < SAVE_ATTEMPTS and is_inside_tree():
			await get_tree().create_timer(2.0).timeout
			if _entities.get(str(entity.get("uuid"))) == entity:
				_save(entity, attempt + 1), CONNECT_ONE_SHOT)
	entity.call("save_to_storage", STORAGE_LOCAL)


# ------------------------------------------------------------------------------------------------ releasing

func untrack(uuid: String) -> void:
	_wanted.erase(uuid)
	_missing.erase(uuid)
	_had_pose.erase(uuid)
	_enabling.erase(uuid)
	if _own.has(uuid):
		_own.erase(uuid)
		if _has_node(uuid):
			(_nodes[uuid] as Node).queue_free()
		var e: Object = _entities.get(uuid)
		if e != null:
			e.call("untrack")
	elif _has_node(uuid) and _mgr != null:
		_mgr.call("untrack_anchor", StringName(uuid))
	_nodes.erase(uuid)


func erase(uuid: String) -> void:
	if not _supported or uuid == "":
		return
	var e: Object = _entities.get(uuid)
	untrack(uuid)
	if e != null:
		e.connect("openxr_fb_spatial_entity_erased", func(ok, _loc): _note("erased %s: %s" % [uuid.substr(0, 8), str(ok)]), CONNECT_ONE_SHOT)
		e.call("erase_from_storage", STORAGE_LOCAL)
		_entities.erase(uuid)
		return
	# not tracked right now: find it in storage and erase it
	var q: Object = ClassDB.instantiate("OpenXRFbSpatialEntityQuery")
	q.call("set_max_results", 4)
	q.call("set_timeout", 8.0)
	q.call("query_by_uuid", [StringName(uuid)], STORAGE_LOCAL)
	var keep: Array = [q]
	q.connect("openxr_fb_spatial_entity_query_completed", func(results: Array):
		for ent in results:
			if str(ent.get("uuid")) == uuid:
				ent.connect("openxr_fb_spatial_entity_erased", func(ok, _loc): _note("erased %s: %s" % [uuid.substr(0, 8), str(ok)]), CONNECT_ONE_SHOT)
				ent.call("erase_from_storage", STORAGE_LOCAL)
		keep.clear(), CONNECT_ONE_SHOT)
	if int(q.call("execute")) != 0:
		keep.clear()
