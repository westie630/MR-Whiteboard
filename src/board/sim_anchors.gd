class_name SimAnchors
extends AnchorService
## Anchors for the PC build. They behave like the headset's: they persist (user://sim_anchors.json), they belong to a room, and
## they only have a pose while you are "in" that room. Switch the simulated room (App setting `sim_room`: A, B, C) to test what
## the app does when you walk into another room, a new room, or back again.

const FILE := "user://sim_anchors.json"

var _store := {}                           # uuid -> {pose: Array, room: String}
var _tracked := {}                         # uuid -> true
var _path := FILE


func _init(path: String = FILE) -> void:
	_path = path
	_load()


func _ready() -> void:
	App.setting_changed.connect(func(k: String):
		if k == "sim_room":
			for u in _tracked.keys():
				tracking_changed.emit(u, has_pose(u)))


func is_supported() -> bool:
	return true


func create(world_pose: Transform3D, tag: String) -> void:
	var uuid := U.uid("sim")
	_store[uuid] = {"pose": U.xf_to_array(world_pose), "room": str(App.val("sim_room"))}
	_tracked[uuid] = true
	_save()
	_answer.call_deferred(tag, uuid)


func _answer(tag: String, uuid: String) -> void:
	created.emit(tag, uuid)


func track(uuids: Array) -> void:
	for u in uuids:
		if _store.has(u):
			_tracked[u] = true
			tracking_changed.emit(u, has_pose(u))


func untrack(uuid: String) -> void:
	_tracked.erase(uuid)


func erase(uuid: String) -> void:
	_tracked.erase(uuid)
	if _store.erase(uuid):
		_save()


func has_pose(uuid: String) -> bool:
	return _tracked.has(uuid) and _store.has(uuid) and str(_store[uuid].room) == str(App.val("sim_room"))


func pose(uuid: String) -> Transform3D:
	return U.xf_from_array(_store[uuid].pose) if _store.has(uuid) else Transform3D.IDENTITY


func status() -> String:
	return "simulated anchors: %d stored, room %s" % [_store.size(), str(App.val("sim_room"))]


func _load() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path)) if FileAccess.file_exists(_path) else null
	if parsed is Dictionary:
		_store = parsed


func _save() -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_store))
		f.close()
