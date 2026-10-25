class_name PdfLibrary
extends Node
## The PDFs on this device: the files (named by their content, so the same PDF is the same on every headset of a session), a small index of
## what they are, and the worker that turns a page into something to show. Nothing outside this class opens a PDF file: a canvas that shows
## a PDF asks for (id, page) and is told when the page is ready.
##
## Pages are made on one worker thread, one at a time (a document caches what it reads, so it must not be shared between threads), and
## handed back as PdfPageData. A few pages are kept ready, as many as the device's budget allows.

signal changed()                                  # a PDF was added or removed
signal page_ready(pdf_id: String, page: int, data: PdfPageData)
signal page_failed(pdf_id: String, page: int, message: String)
signal progress_changed(pdf_id: String)
signal wanted(pdf_id: String)                     # a canvas shows a PDF that is not on this device: whoever can fetch it (a session) should

const INDEX_NAME := "index.json"
const MAX_NAME := 80
const MAX_PAGES := 3000

var dir := "user://pdfs"                          # tests point it elsewhere
var budget: PdfBudget = PdfBudget.for_tier("high")
var threaded := true                              # false: pages are made on the spot (tests)

var _index: Dictionary = {}                       # id -> {id, name, pages, size, added, title, sizes (flat list of w, h per page), cached}
var _loaded := false
var _readers: Dictionary = {}                     # worker only: id -> PdfReader
var _reader_order: Array = []
var _jobs: Array = []                             # [id, page]
var _pending: Dictionary = {}                     # "id:page" -> true while queued or being made
var _ready_cache: Dictionary = {}                 # "id:page" -> PdfPageData
var _ready_order: Array = []
var _thread: Thread
var _sem := Semaphore.new()
var _mutex := Mutex.new()
var _quit := false
var _wanted: Dictionary = {}
var _progress: Dictionary = {}
var _results: Array = []                          # filled by the worker: [id, page, data]


func _ready() -> void:
	_load_index()


func _enter_tree() -> void:
	_quit = false


## (A node can leave the tree and come back, so the worker is stopped and may be started again.)
func _exit_tree() -> void:
	if _thread != null:
		_quit = true
		_sem.post()
		_thread.wait_to_finish()
		_thread = null
		_quit = false
		_jobs.clear()
		_pending.clear()


func _process(_delta: float) -> void:
	if _results.is_empty():
		return
	_mutex.lock()
	var got := _results
	_results = []
	_mutex.unlock()
	for r in got:
		var key := "%s:%d" % [r[0], r[1]]
		_pending.erase(key)
		var data: PdfPageData = r[2]
		if data == null or not data.ok:
			page_failed.emit(r[0], r[1], data.message if data != null else "The page could not be made.")
			continue
		_keep(key, data)
		page_ready.emit(r[0], r[1], data)


# ------------------------------------------------------------------------------------------------ files and index

func _path(id: String) -> String:
	return "%s/%s.pdf" % [dir, id]


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
				if e is Dictionary and FileAccess.file_exists(_path(str(k))):
					_index[str(k)] = e
	# files that are here but not in the index (copied in by hand, or the index was lost) are read again
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".pdf"):
			var id := f.get_basename()
			if not _index.has(id) and _valid_id(id):
				var e2 := _describe(FileAccess.get_file_as_bytes("%s/%s" % [dir, f]), id, id)
				if e2.ok:
					_index[id] = e2.entry


func _save_index() -> void:
	var f := FileAccess.open("%s/%s" % [dir, INDEX_NAME], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_index))


static func _valid_id(id: String) -> bool:
	return id.length() >= 16 and id.length() <= 64 and id.is_valid_hex_number(false)


static func id_of(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().hex_encode().substr(0, 32)


static func clean_name(raw: String) -> String:
	var n := raw.get_file().strip_edges()
	if n.to_lower().ends_with(".pdf"):
		n = n.substr(0, n.length() - 4)
	var out := ""
	for i in n.length():
		var c := n.unicode_at(i)
		if c >= 32 and c != 127:
			out += n[i]
	out = out.strip_edges().left(MAX_NAME)
	return out if out != "" else "Document"


## What a PDF file is, read once when it is taken in: {ok, message, entry}.
func _describe(bytes: PackedByteArray, id: String, name: String) -> Dictionary:
	var doc := PdfDoc.open(bytes)
	if not doc.ok():
		return {"ok": false, "message": doc.error}
	var n := doc.page_count()
	if n <= 0 or n > MAX_PAGES:
		return {"ok": false, "message": "This PDF has %s." % ("no pages" if n <= 0 else "too many pages (%d)" % n)}
	var reader := PdfReader.new()
	reader.doc = doc
	reader.page_count = n
	var sizes := PackedFloat32Array()
	for i in n:
		var s := reader.page_size(i)
		sizes.append(s.x)
		sizes.append(s.y)
	var info := doc.d_dict(doc.trailer.get("Info"))
	var t: Variant = doc.res(info.get("Title"))
	var title := PdfReader._text(t) if t is PackedByteArray else ""
	return {"ok": true, "entry": {"id": id, "name": name, "pages": n, "size": bytes.size(), "added": int(Time.get_unix_time_from_system()), "title": title,
		"sizes": Array(sizes), "cached": false}}


## Takes a PDF in. {ok, message, id, name, pages, dup (it was here already)}. `cached` marks one received from a session (it may be cleaned up).
func add(bytes: PackedByteArray, file_name: String, cached: bool = false) -> Dictionary:
	_load_index()
	if bytes.size() < 20:
		return {"ok": false, "message": "The file is empty."}
	if bytes.size() > budget.max_file_mb * 1048576:
		return {"ok": false, "message": "That PDF is too big for this headset (the limit is %d MB)." % budget.max_file_mb}
	var id := id_of(bytes)
	if _index.has(id):
		var e: Dictionary = _index[id]
		return {"ok": true, "message": "Already here", "id": id, "name": e.name, "pages": int(e.pages), "dup": true}
	var nm := clean_name(file_name)
	var d := _describe(bytes, id, nm)
	if not d.ok:
		return {"ok": false, "message": str(d.message)}
	var f := FileAccess.open(_path(id), FileAccess.WRITE)
	if f == null:
		return {"ok": false, "message": "The file could not be stored on the device."}
	f.store_buffer(bytes)
	f.close()
	var entry: Dictionary = d.entry
	entry["cached"] = cached
	_index[id] = entry
	_save_index()
	changed.emit()
	return {"ok": true, "message": "Added", "id": id, "name": nm, "pages": int(entry.pages), "dup": false}


func has(id: String) -> bool:
	_load_index()
	return _index.has(id)


func entry(id: String) -> Dictionary:
	_load_index()
	return _index.get(id, {})


## Every PDF, newest first.
func list() -> Array:
	_load_index()
	var out: Array = _index.values()
	out.sort_custom(func(a, b): return int(a.added) > int(b.added))
	return out


func file_bytes(id: String) -> PackedByteArray:
	if not has(id):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(_path(id))


func remove(id: String) -> bool:
	_load_index()
	if not _index.has(id):
		return false
	_index.erase(id)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_path(id)))
	_save_index()
	for k in _ready_cache.keys():
		if str(k).begins_with(id + ":"):
			_ready_cache.erase(k)
			_ready_order.erase(k)
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


## The size of a page in points (from the index: no file is read), Vector2.ZERO if unknown.
func page_size(id: String, page: int) -> Vector2:
	var e := entry(id)
	var sizes: Array = e.get("sizes", [])
	var i := (page - 1) * 2
	if i < 0 or i + 1 >= sizes.size():
		return Vector2.ZERO
	return Vector2(float(sizes[i]), float(sizes[i + 1]))


func page_count(id: String) -> int:
	return int(entry(id).get("pages", 0))


## A PDF a canvas needs and this device does not have. Said once; the session (or the person) takes it from there.
func want(id: String) -> void:
	if not _wanted.has(id):
		_wanted[id] = true
		wanted.emit(id)


## What to tell about a PDF that is not here: how far it has come, or that nobody has it.
func state_text(id: String) -> String:
	if _progress.has(id):
		var p: Dictionary = _progress[id]
		return str(p.get("text", "Receiving the PDF..."))
	return "This PDF is not on this headset."


## A session says how far a PDF has come (text "" ends it): the canvases that wait for it say so.
func set_progress(id: String, text: String) -> void:
	if text == "":
		_progress.erase(id)
	else:
		_progress[id] = {"text": text}
	progress_changed.emit(id)


func forget_wanted(id: String) -> void:
	_wanted.erase(id)


# ------------------------------------------------------------------------------------------------ pages

## Asks for a page (1 = the first). page_ready (or page_failed) follows. A page that is ready already is announced on the next frame.
func request(id: String, page: int) -> void:
	if not has(id) or page < 1 or page > page_count(id):
		return
	var key := "%s:%d" % [id, page]
	if _ready_cache.has(key):
		_touch(key)
		_announce.call_deferred(id, page)
		return
	if _pending.has(key):
		return
	_pending[key] = true
	if not threaded:
		var data := _make(id, page)
		_pending.erase(key)
		if data.ok:
			_keep(key, data)
			_announce.call_deferred(id, page)
		else:
			page_failed.emit.call_deferred(id, page, data.message)
		return
	_jobs.append([id, page])
	if _thread == null:
		_thread = Thread.new()
		_thread.start(_work)
	_sem.post()


func _announce(id: String, page: int) -> void:
	var key := "%s:%d" % [id, page]
	if _ready_cache.has(key):
		page_ready.emit(id, page, _ready_cache[key])


func cached_page(id: String, page: int) -> PdfPageData:
	return _ready_cache.get("%s:%d" % [id, page])


func _keep(key: String, data: PdfPageData) -> void:
	_ready_cache[key] = data
	_ready_order.erase(key)
	_ready_order.append(key)
	while _ready_order.size() > budget.cached_pages:
		var old: String = _ready_order.pop_front()
		_ready_cache.erase(old)


func _touch(key: String) -> void:
	_ready_order.erase(key)
	_ready_order.append(key)


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
		var data := _make(str(job[0]), int(job[1]))
		_mutex.lock()
		_results.append([job[0], job[1], data])
		_mutex.unlock()


## The page itself (on the worker, or on the spot when not threaded).
func _make(id: String, page: int) -> PdfPageData:
	var reader: PdfReader = _readers.get(id)
	if reader == null:
		reader = PdfReader.open(FileAccess.get_file_as_bytes(_path(id)), budget)
		if not reader.ok():
			var bad := PdfPageData.new()
			bad.ok = false
			bad.message = reader.error if reader.error != "" else "This PDF could not be read."
			return bad
		_readers[id] = reader
		_reader_order.append(id)
		while _reader_order.size() > (2 if budget.tier == "low" else 4):
			_readers.erase(_reader_order.pop_front())
	return reader.render(page - 1)
