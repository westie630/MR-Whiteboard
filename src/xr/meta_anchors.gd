class_name MetaAnchors
extends AnchorService
## Persistent spatial anchors on the Quest (XR_FB_spatial_entity + storage, through the Godot OpenXR Vendors plugin's
## OpenXRFbSpatialAnchorManager). An anchor is tied to the real room: it is saved on the device, found again at the next launch
## and follows the room whenever the headset re-localises. Many anchors at once: one per room and one per canvas / 3D sketch.
##
## Written from what works in the Apex MR app on the same headset:
##  - anchors are looked up with a storage query by uuid and then handed to the manager to track (load_anchors() was observed
##    to accept a request and never answer);
##  - new anchors are created one at a time and saved to storage, with retries;
##  - when the VR session ends (headset off) the plugin drops every anchor node: they are looked up again when it comes back.

const STORAGE_LOCAL := 0
const SAVE_ATTEMPTS := 4
const QUERY_TIMEOUT_MS := 10000
const RETRY_S := 12.0
const MAX_RETRIES := 6

var _mgr: Node
var _origin: Node3D
var _supported := false
var _wanted: Dictionary = {}               # uuid -> true: anchors the document uses
var _nodes: Dictionary = {}                # uuid -> XRAnchor3D (tracked now)
var _entities: Dictionary = {}             # uuid -> OpenXRFbSpatialEntity
var _had_pose: Dictionary = {}
var _create_queue: Array = []              # [{pose, tag}]
var _creating: Dictionary = {}
var _query: Object
var _query_started_ms := 0
var _retry_t := 0.0
var _retries := 0
var _missing: Dictionary = {}              # uuid -> true: asked for, not found on this device (yet)
var _log: PackedStringArray = []


func setup(origin: Node3D) -> bool:
	_origin = origin
	_supported = _extensions_supported() and ClassDB.class_exists("OpenXRFbSpatialAnchorManager")
	if not _supported:
		print("[anchors] spatial entity extensions are not available")
		return false
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
	return "anchors: %d wanted, %d tracked, %d missing, queue %d" % [_wanted.size(), _nodes.size(), _missing.size(), _create_queue.size()]


func _note(s: String) -> void:
	print("[anchors] ", s)
	_log.append(s)
	if _log.size() > 40:
		_log.remove_at(0)


# ------------------------------------------------------------------------------------------------ queries

func has_pose(uuid: String) -> bool:
	var n: Variant = _nodes.get(uuid)                      # Variant: the plugin frees these nodes when the session ends, and a typed variable cannot hold a freed one
	return n != null and is_instance_valid(n) and bool((n as Node3D).call("get_has_tracking_data")) and bool((n as Node3D).call("get_is_active"))


func pose(uuid: String) -> Transform3D:
	var n: Variant = _nodes.get(uuid)
	return (n as Node3D).global_transform if n != null and is_instance_valid(n) else Transform3D.IDENTITY


func _process(delta: float) -> void:
	if not _supported:
		return
	# the VR session ended and took the anchor nodes with it: forget them, they are looked up again
	var lost := false
	for u in _nodes.keys():
		if not is_instance_valid(_nodes[u]):
			_nodes.erase(u)
			_entities.erase(u)
			lost = true
	if lost:
		_note("anchor nodes dropped by the session: looking them up again")
		reload()
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


## Look every wanted anchor up again (after the headset was off, or when the session comes back).
func reload() -> void:
	_retries = 0
	_retry_t = 0.0
	_lookup()


func track(uuids: Array) -> void:
	if not _supported:
		return
	for u in uuids:
		_wanted[str(u)] = true
	_lookup()


func _lookup() -> void:
	if not _supported:
		return
	var need: Array = []
	for u in _wanted.keys():
		if not _nodes.has(u) or not is_instance_valid(_nodes[u]):
			need.append(StringName(u))
	if need.is_empty():
		_missing.clear()
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
		var id := str(e.get("uuid"))
		found[id] = true
		if _wanted.has(id) and not (_nodes.has(id) and is_instance_valid(_nodes[id])):
			_entities[id] = e
			_mgr.call("track_anchor", e)
	_missing.clear()
	for a in asked:
		if not found.has(str(a)):
			_missing[str(a)] = true
	_note("storage query: asked %d, found %d" % [asked.size(), found.size()])


func _on_tracked(anchor_node: Node, entity: Object, is_new: bool) -> void:
	var uuid := str(entity.get("uuid"))
	if is_new:
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
	else:
		if not _wanted.has(uuid):
			_mgr.call("untrack_anchor", StringName(uuid))
			return
		_nodes[uuid] = anchor_node
		_entities[uuid] = entity
		_missing.erase(uuid)
		_note("tracking stored anchor %s" % uuid.substr(0, 8))
		tracking_changed.emit(uuid, has_pose(uuid))


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
	if _nodes.has(uuid) and _mgr != null:
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
