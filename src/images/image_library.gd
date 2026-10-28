class_name ImageLibrary
extends Node
## The pictures on this device (PNG, JPEG, WebP, BMP), for picture items on canvases. Like the PDF and model libraries: the files are named by their
## content (the same picture is the same file on every headset of a session), a small index says what they are, and nothing outside this class
## opens one. An ItemView asks for a picture's texture by id and is told when it is ready.
##
## A picture is kept as it was sent and made into a texture when a canvas shows it: decoded on a worker thread (a 12 megapixel photo takes a
## moment), turned upright from its EXIF orientation (phone photos are often stored on their side), made no bigger than this device's budget
## allows (a Quest 2 less than a Quest 3), with mipmaps so it stays smooth from any distance. A few textures are kept ready, as many as fit the
## budget's memory.

signal changed()                                  # a picture was added, renamed or removed
signal image_ready(image_id: String)
signal image_failed(image_id: String, message: String)
signal progress_changed(image_id: String)
signal wanted(image_id: String)                   # a canvas shows a picture that is not on this device: whoever can fetch it (a session) should

const INDEX_NAME := "index.json"
const MAX_NAME := 80
const EXTS := ["png", "jpg", "jpeg", "webp", "bmp"]
const MIME := {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp", "bmp": "image/bmp"}
## How much a picture may ask of a device: the longest side of its texture (px), the biggest file taken (MB), the textures kept ready (MB).
const TIERS := {
	"low": {"max_px": 2048, "max_file_mb": 24, "cache_mb": 128},
	"high": {"max_px": 3072, "max_file_mb": 32, "cache_mb": 384},
}

var dir := "user://images"                        # tests point it elsewhere
var tier := "high"
var threaded := true                              # false: textures are made on the spot (tests)

var _index: Dictionary = {}                       # id -> {id, name, ext, size, w, h, added, cached}
var _loaded := false
var _tex: Dictionary = {}                         # id -> {tex: ImageTexture, bytes: int}
var _order: Array = []                            # ids of _tex, least recently used first
var _failed: Dictionary = {}                      # id -> why it cannot be shown here
var _pending: Dictionary = {}                     # id -> the worker task making it (-1 when made on the spot)
var _seed: Dictionary = {}                        # the last picture added, decoded (it is usually shown at once: saves decoding it again)
var _mutex := Mutex.new()
var _results: Array = []                          # [{id, image or null, message}] from the worker
var _wanted: Dictionary = {}
var _progress: Dictionary = {}


func _init() -> void:
	name = "Images"


func _ready() -> void:
	_load_index()


func _exit_tree() -> void:
	for id in _pending:
		if int(_pending[id]) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(_pending[id]))
	_pending.clear()
	_mutex.lock()
	_results.clear()
	_mutex.unlock()


func max_px() -> int:
	return int(TIERS[tier].max_px)


func max_file_mb() -> int:
	return int(TIERS[tier].max_file_mb)


static func id_of(bytes: PackedByteArray) -> String:
	return PdfLibrary.id_of(bytes)


static func mime_of(ext: String) -> String:
	return str(MIME.get("jpg" if ext == "jpeg" else ext, "application/octet-stream"))


## What a file is by its first bytes: png | jpg | webp | bmp, or a word for what it is not ("gif", "heic", "svg", "").
static func detect(bytes: PackedByteArray) -> String:
	if bytes.size() < 12:
		return ""
	if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
		return "png"
	if bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		return "jpg"
	if bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		return "webp"
	if bytes[0] == 0x42 and bytes[1] == 0x4D:
		return "bmp"
	if bytes.slice(0, 4).get_string_from_ascii() == "GIF8":
		return "gif"
	var brand := bytes.slice(4, 12).get_string_from_ascii()
	if brand.begins_with("ftyp") and (brand.contains("hei") or brand.contains("hev") or brand.contains("mif1") or brand.contains("avif")):
		return "heic"
	var head := bytes.slice(0, mini(bytes.size(), 256)).get_string_from_utf8().strip_edges().to_lower()
	if head.begins_with("<svg") or (head.begins_with("<?xml") and head.contains("<svg")):
		return "svg"
	return ""


static func is_image_name(file_name: String) -> bool:
	return EXTS.has(file_name.get_extension().to_lower())


## The picture decoded and turned upright (EXIF orientation of a JPEG), or null.
static func decode(bytes: PackedByteArray, kind: String = "") -> Image:
	if kind == "":
		kind = detect(bytes)
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match kind:
		"png":
			err = img.load_png_from_buffer(bytes)
		"jpg":
			err = img.load_jpg_from_buffer(bytes)
		"webp":
			err = img.load_webp_from_buffer(bytes)
		"bmp":
			err = img.load_bmp_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	if kind == "jpg":
		orient(img, jpeg_orientation(bytes))
	return img


## The EXIF orientation of a JPEG (1 = as stored, 6 = turn a quarter clockwise, ...), 1 when it says none.
static func jpeg_orientation(b: PackedByteArray) -> int:
	if b.size() < 4 or b[0] != 0xFF or b[1] != 0xD8:
		return 1
	var i := 2
	while i + 4 <= b.size():
		if b[i] != 0xFF:
			return 1
		var marker := b[i + 1]
		if marker == 0xD9 or marker == 0xDA:
			return 1                                           # the picture itself starts: no EXIF before it
		var seg := (b[i + 2] << 8) | b[i + 3]
		if marker == 0xE1 and seg >= 16 and i + 2 + seg <= b.size() and b.slice(i + 4, i + 10) == PackedByteArray([0x45, 0x78, 0x69, 0x66, 0, 0]):
			var t := i + 10
			var le := b[t] == 0x49
			var end := i + 2 + seg
			var ifd := t + _u32(b, t + 4, le)
			if ifd + 2 > end:
				return 1
			for k in _u16(b, ifd, le):
				var e := ifd + 2 + k * 12
				if e + 12 > end:
					return 1
				if _u16(b, e, le) == 0x0112:
					var o := _u16(b, e + 8, le)
					return o if o >= 1 and o <= 8 else 1
			return 1
		i += 2 + seg
	return 1


static func _u16(b: PackedByteArray, at: int, le: bool) -> int:
	return (b[at] | (b[at + 1] << 8)) if le else ((b[at] << 8) | b[at + 1])


static func _u32(b: PackedByteArray, at: int, le: bool) -> int:
	return (_u16(b, at, le) | (_u16(b, at + 2, le) << 16)) if le else ((_u16(b, at, le) << 16) | _u16(b, at + 2, le))


## Turns a picture upright for its EXIF orientation.
static func orient(img: Image, o: int) -> void:
	match o:
		2:
			img.flip_x()
		3:
			img.rotate_180()
		4:
			img.flip_y()
		5:
			img.rotate_90(CLOCKWISE)
			img.flip_x()
		6:
			img.rotate_90(CLOCKWISE)
		7:
			img.rotate_90(COUNTERCLOCKWISE)
			img.flip_x()
		8:
			img.rotate_90(COUNTERCLOCKWISE)


static func clean_name(raw: String) -> String:
	var n := raw.get_file().strip_edges()
	if is_image_name(n):
		n = n.get_basename()
	var out := ""
	for i in n.length():
		var c := n.unicode_at(i)
		if c >= 32 and c != 127:
			out += n[i]
	out = out.strip_edges().left(MAX_NAME)
	return out if out != "" else "Picture"


# ------------------------------------------------------------------------------------------------ the library

func _path(id: String) -> String:
	return "%s/%s.%s" % [dir, id, str(entry(id).get("ext", "png"))]


func _load_index() -> void:
	if _loaded:
		return
	_loaded = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [dir, INDEX_NAME])) if FileAccess.file_exists("%s/%s" % [dir, INDEX_NAME]) else null
	_index = {}
	if parsed is Dictionary:
		for id in parsed:
			var e: Variant = parsed[id]
			if e is Dictionary and FileAccess.file_exists("%s/%s.%s" % [dir, id, str(e.get("ext", ""))]):
				_index[str(id)] = e


func _save_index() -> void:
	var f := FileAccess.open("%s/%s" % [dir, INDEX_NAME], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_index))
		f.close()


## Takes a picture in. {ok, message, id, name, w, h, dup}. `cached` marks one received from a session (it may be cleaned up later).
func add(bytes: PackedByteArray, file_name: String, cached: bool = false) -> Dictionary:
	_load_index()
	var kind := detect(bytes)
	var nm := file_name.get_file()
	match kind:
		"gif":
			return {"ok": false, "message": "%s is a GIF: save it as PNG or JPEG first." % nm}
		"heic":
			return {"ok": false, "message": "%s is an iPhone HEIC/AVIF picture: send it as JPEG (on the iPhone: Settings, Camera, Formats, Most Compatible; or share it as a photo)." % nm}
		"svg":
			return {"ok": false, "message": "%s is an SVG: send it as an SVG and it becomes a canvas of shapes you can change." % nm}
		"":
			return {"ok": false, "message": "%s is not a picture the headset can read (PNG, JPEG, WebP or BMP)." % nm}
	if bytes.size() > max_file_mb() * 1048576:
		return {"ok": false, "message": "%s is too big for this headset (the limit is %d MB)." % [nm, max_file_mb()]}
	var id := id_of(bytes)
	if _index.has(id):
		var old: Dictionary = _index[id]
		if not cached and bool(old.get("cached", false)):
			old["cached"] = false
			_save_index()
		return {"ok": true, "message": "%s was here already." % old.name, "id": id, "name": old.name, "w": int(old.w), "h": int(old.h), "dup": true}
	var img := decode(bytes, kind)
	if img == null:
		return {"ok": false, "message": "%s could not be read: the file may be damaged." % nm}
	var f := FileAccess.open("%s/%s.%s" % [dir, id, kind], FileAccess.WRITE)
	if f == null:
		return {"ok": false, "message": "The headset could not save %s." % nm}
	f.store_buffer(bytes)
	f.close()
	var e := {"id": id, "name": clean_name(file_name), "ext": kind, "size": bytes.size(), "w": img.get_width(), "h": img.get_height(),
		"added": int(Time.get_unix_time_from_system()), "cached": cached}
	_index[id] = e
	_save_index()
	_failed.erase(id)
	_wanted.erase(id)
	_seed.clear()
	_seed[id] = img
	changed.emit()
	_progress.erase(id)
	progress_changed.emit(id)                              # canvases that waited for it (a box saying it is not here) show it now
	return {"ok": true, "message": "%s added." % e.name, "id": id, "name": e.name, "w": e.w, "h": e.h, "dup": false}


func has(id: String) -> bool:
	_load_index()
	return _index.has(id)


func entry(id: String) -> Dictionary:
	_load_index()
	return _index.get(id, {})


## Width / height of the picture as it is shown (upright), 1.0 when it is not known.
func aspect(id: String) -> float:
	var e := entry(id)
	return float(e.w) / float(e.h) if int(e.get("h", 0)) > 0 else 1.0


## Every picture, newest first.
func list() -> Array:
	_load_index()
	var out: Array = _index.values()
	out.sort_custom(func(a, b): return int(a.added) > int(b.added))
	return out


func file_bytes(id: String) -> PackedByteArray:
	if not has(id):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(_path(id))


## The name a downloaded copy gets ("Holiday.jpg").
func file_name(id: String) -> String:
	var e := entry(id)
	return "%s.%s" % [DocStore.safe_name(str(e.get("name", "picture"))), str(e.get("ext", "png"))]


func remove(id: String) -> bool:
	_load_index()
	if not _index.has(id):
		return false
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_path(id)))
	_index.erase(id)
	_save_index()
	_drop(id)
	_seed.erase(id)
	changed.emit()
	return true


func rename(id: String, new_name: String) -> void:
	if has(id):
		_index[id]["name"] = clean_name(new_name)
		_save_index()
		changed.emit()


## Received-from-session copies beyond the newest `keep` are deleted (called when a session ends).
func trim_cached(keep: int = 24) -> void:
	var cached: Array = []
	for e in list():
		if bool(e.get("cached", false)):
			cached.append(e)
	for i in range(keep, cached.size()):
		remove(str(cached[i].id))


# ------------------------------------------------------------------------------------------------ textures

## The picture as a texture, or null while it is made (image_ready follows), when it is not on this device (wanted is said) or cannot be shown.
func texture(id: String) -> Texture2D:
	if _tex.has(id):
		_order.erase(id)
		_order.append(id)
		return (_tex[id] as Dictionary).tex
	if _failed.has(id) or _pending.has(id):
		return null
	if not has(id):
		want(id)
		return null
	_pending[id] = -1
	var bytes := file_bytes(id)
	var kind := str(entry(id).get("ext", ""))
	var seed: Image = _seed.get(id)
	_seed.erase(id)
	var cap := max_px()
	if threaded:
		_pending[id] = WorkerThreadPool.add_task(func(): _make(id, bytes, kind, seed, cap))
	else:
		_make(id, bytes, kind, seed, cap)
		_drain()
	return null


## What a canvas says in place of a picture that is not shown.
func state_text(id: String) -> String:
	if _progress.has(id):
		return str(_progress[id])
	if _failed.has(id):
		return str(_failed[id])
	if not has(id):
		return "This picture is not on this headset."
	return "Loading the picture..."


func failed(id: String) -> bool:
	return _failed.has(id)


## (worker) decode, turn upright, fit the budget, mipmaps.
func _make(id: String, bytes: PackedByteArray, kind: String, seed: Image, cap: int) -> void:
	var img := seed if seed != null else decode(bytes, kind)
	var msg := ""
	if img == null:
		msg = "This picture could not be read."
	else:
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		if maxi(w, h) > cap:
			var k := float(cap) / float(maxi(w, h))
			img.resize(maxi(1, roundi(w * k)), maxi(1, roundi(h * k)), Image.INTERPOLATE_LANCZOS)
		img.generate_mipmaps()
	_mutex.lock()
	_results.append({"id": id, "image": img if msg == "" else null, "message": msg})
	_mutex.unlock()


func _process(_delta: float) -> void:
	if not _pending.is_empty():
		_drain()


func _drain() -> void:
	_mutex.lock()
	var done := _results.duplicate()
	_results.clear()
	_mutex.unlock()
	for r in done:
		var id := str(r.id)
		if not _pending.has(id):
			continue
		if int(_pending[id]) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(_pending[id]))
		_pending.erase(id)
		if r.image == null:
			_failed[id] = str(r.message)
			image_failed.emit(id, str(r.message))
			continue
		var img: Image = r.image
		var tex := ImageTexture.create_from_image(img)
		_tex[id] = {"tex": tex, "bytes": img.get_data_size()}
		_order.append(id)
		_trim()
		image_ready.emit(id)


## Keeps the textures ready within the budget's memory (the least recently asked for go first; a canvas that shows one keeps its own reference).
func _trim() -> void:
	var limit := int(TIERS[tier].cache_mb) * 1048576
	var total := 0
	for id in _tex:
		total += int((_tex[id] as Dictionary).bytes)
	while total > limit and _order.size() > 1:
		var old: String = _order.pop_front()
		total -= int((_tex[old] as Dictionary).bytes)
		_tex.erase(old)


func _drop(id: String) -> void:
	_tex.erase(id)
	_order.erase(id)
	_failed.erase(id)


# ------------------------------------------------------------------------------------------------ sessions

## A picture a canvas needs and this device does not have. Said once; the session takes it from there.
func want(id: String) -> void:
	if not _wanted.has(id):
		_wanted[id] = true
		wanted.emit(id)


func forget_wanted(id: String) -> void:
	_wanted.erase(id)


func set_progress(id: String, text: String) -> void:
	if text == "":
		_progress.erase(id)
	else:
		_progress[id] = text
	progress_changed.emit(id)
