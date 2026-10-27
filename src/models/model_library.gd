class_name ModelLibrary
extends Node
## The 3D models on this device: the files (named by their content, so the same model is the same file on every headset of a session), a small
## index of what they are, and the worker that loads one into something to show. Like PdfLibrary: nothing outside this class opens a model
## file; a ModelNode asks for an id and is told when the model is ready (or why it cannot be shown on this device).
##
## A model that is several files (an .obj with its .mtl and pictures, a .gltf with its .bin) is kept as ONE .zip, so it travels and is
## named as one thing. Loading happens on one worker thread (a big model takes seconds: the headset must not stop meanwhile); a few loaded
## models are kept ready, as many as the device's budget allows, and each ModelNode shows its own copy of one.
##
## The files of one model may also come one after another (an .obj, then its .mtl and pictures: a phone sends one file at a time). A part
## that comes on its own waits HOLD_SEC for the model that needs it; one that a model added in that time lacks is joined to it, which makes
## it a new file (a new id): `replaced` says so, and the frames that showed the old one show the new one.

signal changed()                                  # a model was added, renamed or removed
signal model_ready(model_id: String)
signal model_failed(model_id: String, message: String)
signal progress_changed(model_id: String)
signal wanted(model_id: String)                   # a frame shows a model that is not on this device: whoever can fetch it (a session) should
signal replaced(old_id: String, new_id: String)   # a model got the files it lacked (its .mtl sent after it): a new file, the old one is gone

const INDEX_NAME := "index.json"
const MAX_NAME := 80
const HOLD_SEC := 600                             # how long a part sent on its own waits for its model, and a model for its parts

var dir := "user://models"                        # tests point it elsewhere
var budget: ModelBudget = ModelBudget.for_tier("high")
var threaded := true                              # false: models are loaded on the spot (tests)

var _index: Dictionary = {}                       # id -> {id, name, ext, size, added, cached, format, triangles, box, animations, notes}
var _loaded := false
var _models: Dictionary = {}                      # id -> {root: Node3D (a template, not in the tree), triangles, box, animations, notes}
var _models_order: Array = []
var _failed: Dictionary = {}                      # id -> why it cannot be shown here
var _jobs: Array = []
var _pending: Dictionary = {}
var _thread: Thread
var _sem := Semaphore.new()
var _mutex := Mutex.new()
var _quit := false
var _results: Array = []
var _wanted: Dictionary = {}
var _progress: Dictionary = {}
var _loose: Dictionary = {}                       # lower-case file name -> {name, bytes, t}: parts sent on their own, waiting for their model
var _held: Dictionary = {}                        # lower-case file name -> {files, main, name, t}: a .gltf refused for lack of its parts


func _ready() -> void:
	_load_index()


func _enter_tree() -> void:
	_quit = false


func _exit_tree() -> void:
	if _thread != null:
		_quit = true
		_sem.post()
		_thread.wait_to_finish()
		_thread = null
		_quit = false
		_jobs.clear()
		_pending.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for k in _models:
			var r: Node = (_models[k] as Dictionary).root
			if is_instance_valid(r):
				r.free()
		_models.clear()


func _process(_delta: float) -> void:
	if _results.is_empty():
		return
	_mutex.lock()
	var got := _results
	_results = []
	_mutex.unlock()
	for r in got:
		_done(str(r[0]), r[1])


func _done(id: String, res: Dictionary) -> void:
	_pending.erase(id)
	if not has(id):
		if res.get("root") is Node:
			(res.root as Node).free()
		return
	if not bool(res.get("ok", false)):
		_failed[id] = str(res.get("message", "The model could not be loaded."))
		print("[models] %s: %s" % [str(entry(id).get("name", id)), _failed[id]])
		model_failed.emit(id, _failed[id])
		return
	_failed.erase(id)
	_models[id] = {"root": res.root, "triangles": int(res.get("triangles", 0)), "box": res.box, "animations": res.get("animations", PackedStringArray()),
		"notes": res.get("notes", PackedStringArray())}
	_touch(id)
	var e: Dictionary = _index[id]
	if not e.has("box"):
		var b: AABB = res.box
		e["box"] = [b.position.x, b.position.y, b.position.z, b.size.x, b.size.y, b.size.z]
		e["triangles"] = int(res.get("triangles", 0))
		e["animations"] = Array(res.get("animations", PackedStringArray()))
		_save_index()
	print("[models] %s ready: %s triangles, %.2f x %.2f x %.2f (its own units)" % [str(e.name), ModelLoader.count_text(int(res.get("triangles", 0))),
		(res.box as AABB).size.x, (res.box as AABB).size.y, (res.box as AABB).size.z])
	_trim()
	model_ready.emit(id)


# ------------------------------------------------------------------------------------------------ files and index

func _path(id: String) -> String:
	return "%s/%s.%s" % [dir, id, str(_index.get(id, {}).get("ext", "glb"))]


func _load_index() -> void:
	if _loaded:
		return
	_loaded = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var p := "%s/%s" % [dir, INDEX_NAME]
	if FileAccess.file_exists(p):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if parsed is Dictionary:
			for k in parsed:
				var e: Variant = (parsed as Dictionary)[k]
				if e is Dictionary and _valid_id(str(k)) and FileAccess.file_exists("%s/%s.%s" % [dir, str(k), str((e as Dictionary).get("ext", "glb"))]):
					_index[str(k)] = e
	# files that are here but not in the index (copied in by hand, or the index was lost) are taken in again
	for f in DirAccess.get_files_at(dir):
		var id := f.get_basename()
		if ModelLoader.EXTS.has(f.get_extension()) and not _index.has(id) and _valid_id(id):
			_index[id] = {"id": id, "name": id.left(8), "ext": f.get_extension(), "size": FileAccess.get_file_as_bytes("%s/%s" % [dir, f]).size(),
				"added": int(Time.get_unix_time_from_system()), "cached": false, "format": _format(f.get_extension())}


func _save_index() -> void:
	var f := FileAccess.open("%s/%s" % [dir, INDEX_NAME], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_index))


static func _valid_id(id: String) -> bool:
	return id.length() >= 16 and id.length() <= 64 and id.is_valid_hex_number(false)


static func id_of(bytes: PackedByteArray) -> String:
	return PdfLibrary.id_of(bytes)


static func _format(ext: String) -> String:
	match ext:
		"glb", "gltf":
			return "glTF"
		"obj":
			return "OBJ"
	return "bundle"


static func clean_name(raw: String) -> String:
	var n := raw.get_file().strip_edges()
	for ext in ModelLoader.EXTS:
		if n.to_lower().ends_with("." + ext):
			n = n.substr(0, n.length() - ext.length() - 1)
	var out := ""
	for i in n.length():
		var c := n.unicode_at(i)
		if c >= 32 and c != 127:
			out += n[i]
	out = out.strip_edges().left(MAX_NAME)
	return out if out != "" else "Model"


## Takes one model file in (a .glb, .gltf, .obj or a .zip of a model and its files). See add_files.
func add(bytes: PackedByteArray, file_name: String, cached: bool = false) -> Dictionary:
	_load_index()
	var kind := ModelLoader.detect(bytes)
	if kind == "":
		if ModelLoader.PARTS.has(file_name.get_extension().to_lower()):
			return add_files({file_name.get_file(): bytes}, "", cached)
		return {"ok": false, "message": "%s is not a 3D model the headset can read (glTF .glb / .gltf, or .obj)." % file_name.get_file()}
	if kind == "zip":
		if bytes.size() > budget.max_file_mb * 1048576:
			return _too_big()
		return add_files(ModelLoader.unzip(bytes, "%s/upload.tmp" % dir), file_name, cached, bytes)
	return add_files({file_name.get_file() if file_name.get_extension().to_lower() == kind else "model." + kind: bytes}, file_name, cached)


## Takes a model in from its files (name or path -> bytes): one file is kept as it is, several as one .zip. {ok, message, id, name, dup, notes}.
## `cached` marks one received from a session (it may be cleaned up). `as_zip`: the bytes of the .zip they came in, kept as they are.
## Parts that came before it (add_parts) are added to it. Parts without a model are add_parts.
func add_files(files: Dictionary, display_name: String, cached: bool = false, as_zip: PackedByteArray = PackedByteArray()) -> Dictionary:
	_load_index()
	var total := 0
	var kept := {}
	for p in files:
		var ext := String(p).get_extension().to_lower()
		if ModelLoader.EXTS.has(ext) or ModelLoader.PARTS.has(ext):
			kept[p] = files[p]
			total += (files[p] as PackedByteArray).size()
	if kept.is_empty():
		return {"ok": false, "message": "There is no model among these files: a .glb, .gltf or .obj file is needed."}
	var main0 := ModelLoader.main_of(kept)
	if main0 == "":
		if cached:
			return {"ok": false, "message": "There is no model among these files: a .glb, .gltf or .obj file is needed."}
		return add_parts(kept)
	if not cached and _fill(kept, main0):
		as_zip = PackedByteArray()                     # (parts sent before it were added: packed again)
		total = 0
		for p in kept:
			total += (kept[p] as PackedByteArray).size()
	if total > budget.max_file_mb * 1048576 or as_zip.size() > budget.max_file_mb * 1048576:
		return _too_big()
	var chk := ModelLoader.check(kept)
	if not bool(chk.ok):
		if not cached and not ModelLoader.missing(kept, main0).is_empty():
			_held[main0.get_file().to_lower()] = {"files": kept, "main": main0, "name": display_name, "t": Time.get_unix_time_from_system()}
			return {"ok": false, "message": "%s Or send them in the next %d minutes: they are joined to it." % [str(chk.message), HOLD_SEC / 60]}
		return {"ok": false, "message": str(chk.message)}
	var main: String = chk.main
	var nm := clean_name(display_name if display_name.strip_edges() != "" else main)
	var bytes: PackedByteArray
	var ext := str(chk.kind)
	if kept.size() == 1 and as_zip.is_empty():
		bytes = kept[main]
	elif not as_zip.is_empty():
		bytes = as_zip
		ext = "zip"
	else:
		bytes = _zip(kept)
		ext = "zip"
		if bytes.is_empty():
			return {"ok": false, "message": "The files could not be stored on the device."}
	var id := id_of(bytes)
	if _index.has(id):
		var e: Dictionary = _index[id]
		return {"ok": true, "message": "Already here", "id": id, "name": e.name, "dup": true, "notes": chk.notes}
	var f := FileAccess.open("%s/%s.%s" % [dir, id, ext], FileAccess.WRITE)
	if f == null:
		return {"ok": false, "message": "The file could not be stored on the device."}
	f.store_buffer(bytes)
	f.close()
	_index[id] = {"id": id, "name": nm, "ext": ext, "size": bytes.size(), "added": int(Time.get_unix_time_from_system()), "cached": cached,
		"format": _format(str(chk.kind)), "notes": Array(chk.notes)}
	_save_index()
	changed.emit()
	return {"ok": true, "message": "Added", "id": id, "name": nm, "dup": false, "notes": chk.notes}


## Parts of a model sent without it (an .mtl, a .bin, pictures): joined to a model added in the last HOLD_SEC that lacks them (it becomes a
## new file: `replaced`; the answer has `old`), or to a .gltf refused for lack of them; else kept for the model sent next (`held`). Pictures
## alone are kept only when a waiting .mtl names them: other pictures are not a model's.
func add_parts(parts: Dictionary) -> Dictionary:
	_load_index()
	_expire()
	var now := Time.get_unix_time_from_system()
	var names := PackedStringArray()
	var only_pictures := true
	for p in parts:
		var nm := String(p).get_file()
		_loose[nm.to_lower()] = {"name": nm, "bytes": parts[p], "t": now}
		names.append(nm)
		if nm.get_extension().to_lower() in ["mtl", "bin"]:
			only_pictures = false
	# a .gltf that was waiting for them
	for k in _held.keys():
		var h: Dictionary = _held[k]
		var hf: Dictionary = h.files
		if _fill(hf, str(h.main)) and ModelLoader.missing(hf, str(h.main)).is_empty():
			_held.erase(k)
			return add_files(hf, str(h.name))
	# a model added a moment ago that lacks them
	for e in list():
		if bool(e.get("cached", false)) or str(e.get("format", "")) != "OBJ" or now - float(e.get("added", 0)) > HOLD_SEC:
			continue
		var old := str(e.id)
		var files := _files_of(old)
		var main := ModelLoader.main_of(files)
		if main == "" or not _fill(files, main):
			continue
		var res := add_files(files, str(e.name))
		if bool(res.ok) and str(res.id) != old:
			_index[str(res.id)]["name"] = str(e.name)
			_save_index()
			replaced.emit(old, str(res.id))
			remove(old)
			res["old"] = old
			res["name"] = str(e.name)
			res["dup"] = false
			res["message"] = "Joined to %s" % str(e.name)
		return res
	# nothing needs them yet
	if only_pictures:
		var named := {}
		for k in _loose:
			if String(k).get_extension() == "mtl":
				for pic in ModelLoader._mtl_pictures((_loose[k] as Dictionary).bytes as PackedByteArray):
					named[pic.get_file().to_lower()] = true
		var used := false
		for nm in names:
			used = used or named.has(nm.to_lower())
		if not used:
			for nm in names:
				_loose.erase(nm.to_lower())
			return {"ok": false, "message": "No 3D model sent in the last %d minutes uses %s. Send a model's pictures with its .obj and .mtl (or all of them in one .zip)." % [HOLD_SEC / 60, ", ".join(names)]}
	return {"ok": true, "held": true, "id": "", "name": ", ".join(names), "dup": false, "notes": PackedStringArray(),
		"message": "Kept %s: send the model that uses %s in the next %d minutes and they are put together." % [", ".join(names), "it" if names.size() == 1 else "them", HOLD_SEC / 60]}


## Whether a file of this name is a part a model is waiting for: a waiting .mtl names it, or a model added in the last HOLD_SEC (or a
## refused .gltf) lacks it. A picture that is goes to add_parts, not among the canvases' pictures.
func wants_part(file_name: String) -> bool:
	_load_index()
	_expire()
	var want := file_name.get_file().to_lower()
	for k in _loose:
		if String(k).get_extension() == "mtl":
			for pic in ModelLoader._mtl_pictures((_loose[k] as Dictionary).bytes as PackedByteArray):
				if pic.get_file().to_lower() == want:
					return true
	for h in _held.values():
		for m in ModelLoader.missing((h as Dictionary).files, str(h.main)):
			if m.to_lower() == want:
				return true
	var now := Time.get_unix_time_from_system()
	for e in list():
		if bool(e.get("cached", false)) or str(e.get("format", "")) != "OBJ" or now - float(e.get("added", 0)) > HOLD_SEC:
			continue
		var files := _files_of(str(e.id))
		for m in ModelLoader.missing(files, ModelLoader.main_of(files)):
			if m.to_lower() == want:
				return true
	return false


## Adds to `files` what its model lacks from the parts that wait (taking them). True when anything was added.
func _fill(files: Dictionary, main: String) -> bool:
	_expire()
	var folder := main.get_base_dir()
	var any := false
	var took := true
	while took:
		took = false
		for m in ModelLoader.missing(files, main):
			var part: Dictionary = _loose.get(m.to_lower(), {})
			if part.is_empty():
				continue
			files[(folder + "/" if folder != "" else "") + str(part.name)] = part.bytes
			_loose.erase(m.to_lower())
			took = true
			any = true
	return any


func _expire() -> void:
	var now := Time.get_unix_time_from_system()
	for pool: Dictionary in [_loose, _held]:
		for k in pool.keys():
			if now - float((pool[k] as Dictionary).t) > HOLD_SEC:
				pool.erase(k)


## The files a model of the library is made of (name -> bytes).
func _files_of(id: String) -> Dictionary:
	var ext := str(entry(id).get("ext", "glb"))
	if ext == "zip":
		return ModelLoader.unzip(file_bytes(id), "%s/parts.tmp" % dir)
	return {"model." + ext: file_bytes(id)}


func _too_big() -> Dictionary:
	return {"ok": false, "message": "That model is too big for this headset (the limit is %d MB)." % budget.max_file_mb}


## Several files as one .zip (the same files give the same bytes: sorted, no dates).
func _zip(files: Dictionary) -> PackedByteArray:
	var tmp := "%s/pack.tmp" % dir
	var z := ZIPPacker.new()
	if z.open(tmp) != OK:
		return PackedByteArray()
	var names: Array = files.keys()
	names.sort()
	for p in names:
		z.start_file(String(p).replace("\\", "/").trim_prefix("/"))
		z.write_file(files[p])
		z.close_file()
	z.close()
	var out := FileAccess.get_file_as_bytes(tmp)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	return out


func has(id: String) -> bool:
	_load_index()
	return _index.has(id)


func entry(id: String) -> Dictionary:
	_load_index()
	return _index.get(id, {})


## Every model, newest first.
func list() -> Array:
	_load_index()
	var out: Array = _index.values()
	out.sort_custom(func(a, b): return int(a.added) > int(b.added))
	return out


func file_bytes(id: String) -> PackedByteArray:
	if not has(id):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(_path(id))


## The name a downloaded copy gets ("Chair.glb", "Teapot.zip").
func file_name(id: String) -> String:
	var e := entry(id)
	return "%s.%s" % [DocStore.safe_name(str(e.get("name", "model"))), str(e.get("ext", "glb"))]


func remove(id: String) -> bool:
	_load_index()
	if not _index.has(id):
		return false
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_path(id)))
	_index.erase(id)
	_save_index()
	_drop(id)
	_failed.erase(id)
	changed.emit()
	return true


func rename(id: String, new_name: String) -> void:
	if has(id):
		_index[id]["name"] = clean_name(new_name)
		_save_index()
		changed.emit()


## Received-from-session copies beyond the newest `keep` are deleted (called when a session ends).
func trim_cached(keep: int = 6) -> void:
	var cached: Array = []
	for e in list():
		if bool(e.get("cached", false)):
			cached.append(e)
	for i in range(keep, cached.size()):
		remove(str(cached[i].id))


## Its bounds in its own units, as measured when it was first loaded here (an empty AABB before).
func box_of(id: String) -> AABB:
	var b: Array = entry(id).get("box", [])
	return AABB(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5])) if b.size() >= 6 else AABB()


## A model a frame needs and this device does not have. Said once; the session (or the person) takes it from there.
func want(id: String) -> void:
	if not _wanted.has(id):
		_wanted[id] = true
		wanted.emit(id)


func forget_wanted(id: String) -> void:
	_wanted.erase(id)


func state_text(id: String) -> String:
	if _progress.has(id):
		return str((_progress[id] as Dictionary).get("text", "Receiving the model..."))
	return "This model is not on this headset."


func set_progress(id: String, text: String) -> void:
	if text == "":
		_progress.erase(id)
	else:
		_progress[id] = {"text": text}
	progress_changed.emit(id)


# ------------------------------------------------------------------------------------------------ loading

## Asks for a model to be loaded. model_ready (or model_failed) follows; one that is ready already is announced on the next frame.
func request(id: String) -> void:
	if not has(id):
		return
	if _models.has(id):
		_touch(id)
		model_ready.emit.call_deferred(id)
		return
	if _failed.has(id):
		model_failed.emit.call_deferred(id, str(_failed[id]))
		return
	if _pending.has(id):
		return
	_pending[id] = true
	if not threaded:
		_done.call_deferred(id, _load(id, _path(id)))      # (announced on the next frame, as from the worker)
		return
	_mutex.lock()
	_jobs.append([id, _path(id)])                  # (the worker never reads the index: the main thread changes it)
	_mutex.unlock()
	if _thread == null:
		_thread = Thread.new()
		_thread.start(_work)
	_sem.post()


func is_loading(id: String) -> bool:
	return _pending.has(id)


func failure(id: String) -> String:
	return str(_failed.get(id, ""))


## A copy of a loaded model to show (it shares meshes, materials and pictures with the others), or null when it is not loaded.
func instance(id: String) -> Node3D:
	var r: Dictionary = _models.get(id, {})
	if r.is_empty():
		return null
	_touch(id)
	return (r.root as Node3D).duplicate() as Node3D


## {triangles, box, animations, notes} of a loaded model ({} when it is not loaded).
func stats(id: String) -> Dictionary:
	var r: Dictionary = _models.get(id, {})
	if r.is_empty():
		return {}
	return {"triangles": r.triangles, "box": r.box, "animations": r.animations, "notes": r.notes}


func _touch(id: String) -> void:
	_models_order.erase(id)
	_models_order.append(id)


func _trim() -> void:
	while _models_order.size() > budget.cached:
		_drop(str(_models_order[0]))


func _drop(id: String) -> void:
	_models_order.erase(id)
	if _models.has(id):
		var r: Node = (_models[id] as Dictionary).root
		if is_instance_valid(r):
			r.free()
		_models.erase(id)


func _work() -> void:
	while true:
		_sem.wait()
		if _quit:
			return
		_mutex.lock()
		var job: Array = _jobs.pop_front() if not _jobs.is_empty() else []
		_mutex.unlock()
		if job.is_empty():
			continue
		var id := str(job[0])
		var res := _load(id, str(job[1]))
		_mutex.lock()
		_results.append([id, res])
		_mutex.unlock()


func _load(id: String, path: String) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var res := ModelLoader.load_model(FileAccess.get_file_as_bytes(path), budget, "%s/%s.unzip.tmp" % [dir, id])
	res["ms"] = Time.get_ticks_msec() - t0
	return res
