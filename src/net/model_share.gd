class_name ModelShare
extends RefCounted
## 3D models in a session, the way PdfShare does PDFs. The document of a session carries only WHICH model a frame shows (its content id), where
## and how big; the file itself goes to a guest the first time a frame of the session needs it, from the owner, once, on the file channel (so a
## 40 MB model never holds up a pen stroke). The guest checks that what arrived is the file it asked for (the id is a hash of the content) and
## keeps it with its other models; each headset then loads it itself, within what its own hardware can bear (ModelBudget: a Quest 2 may
## refuse a model a Quest 3 shows, and says so in the room, without holding the others up).
##
## The owner only gives a file out when a frame of the shared room names it, and to one request at a time per guest.

const CHUNK := 96 * 1024
const MAX_STORE_LOG := 6

var session                                   # Session (untyped: Session holds this object)
var rate := 6.0 * 1048576.0                   # bytes a second the owner sends a guest (tests raise it)

var _out: Dictionary = {}                     # owner: peer id -> {id, bytes, next, n, credit}
var _in: Dictionary = {}                      # guest: model id -> {n, size, name, ext, buf, i}
var _asked: Dictionary = {}                   # guest: model id -> true while a request is out
var _refused: Dictionary = {}                 # guest: model id -> why not (so it is not asked again and again)


func reset() -> void:
	_out.clear()
	_in.clear()
	_asked.clear()
	_refused.clear()


func drop_peer(peer: int) -> void:
	_out.erase(peer)


# ------------------------------------------------------------------------------------------------ owner

func host_request(from: int, msg: Dictionary) -> void:
	var id := str(msg.get("id", ""))
	var lib: ModelLibrary = session.board.models
	if not _referenced(id):
		session.net.send(from, {"t": "mdl_no", "id": id, "why": "This model is not part of the session."}, SessionNet.CH_FILE)
		return
	if not lib.has(id):
		session.net.send(from, {"t": "mdl_no", "id": id, "why": "The owner does not have this model any more."}, SessionNet.CH_FILE)
		return
	if _out.has(from):
		return                                                 # one at a time: the guest asks again for the next
	var bytes := lib.file_bytes(id)
	var e := lib.entry(id)
	var n := maxi(ceili(float(bytes.size()) / CHUNK), 1)
	session.net.send(from, {"t": "mdl", "id": id, "n": n, "size": bytes.size(), "name": str(e.get("name", "Model")), "ext": str(e.get("ext", "glb"))}, SessionNet.CH_FILE)
	_out[from] = {"id": id, "bytes": bytes, "next": 0, "n": n, "credit": 0.0}


func host_stop(from: int, msg: Dictionary) -> void:
	if _out.has(from) and str((_out[from] as Dictionary).id) == str(msg.get("id", "")):
		_out.erase(from)


func host_tick(delta: float) -> void:
	for peer in _out.keys():
		var t: Dictionary = _out[peer]
		t.credit = minf(float(t.credit) + rate * delta, rate * 0.25 + CHUNK * 4)
		var bytes: PackedByteArray = t.bytes
		while int(t.next) < int(t.n) and float(t.credit) >= CHUNK * 0.5:
			var i := int(t.next)
			session.net.send(peer, {"t": "mdlc", "id": t.id, "i": i, "d": bytes.slice(i * CHUNK, mini((i + 1) * CHUNK, bytes.size()))}, SessionNet.CH_FILE)
			t.next = i + 1
			t.credit = float(t.credit) - CHUNK
		if int(t.next) >= int(t.n):
			_out.erase(peer)


## Does a frame of the shared room show this model?
func _referenced(id: String) -> bool:
	if id == "" or session.sync.doc == null:
		return false
	for f in session.sync.doc.frames.values():
		var fd: FrameData = f
		if fd.model == id and session.sync.in_scope_frame(fd.id):
			return true
	return false


# ------------------------------------------------------------------------------------------------ guest

func client_want(id: String) -> void:
	var lib: ModelLibrary = session.board.models
	if lib.has(id) or _asked.has(id) or _in.has(id) or _refused.has(id):
		return
	_asked[id] = true
	lib.set_progress(id, "Asking the owner for the model...")
	session.net.send(SessionNet.SERVER, {"t": "mdl?", "id": id}, SessionNet.CH_FILE)


## Ask again for every model the frames of the session show that is not here (after joining, or the link coming back).
func client_rescan() -> void:
	if session.sync.doc == null:
		return
	var lib: ModelLibrary = session.board.models
	for f in session.sync.doc.frames.values():
		var fd: FrameData = f
		if fd.model != "" and not lib.has(fd.model):
			lib.forget_wanted(fd.model)
			_asked.erase(fd.model)
			_refused.erase(fd.model)
			lib.want(fd.model)


func client_msg(msg: Dictionary) -> void:
	var lib: ModelLibrary = session.board.models
	var id := str(msg.get("id", ""))
	match str(msg.t):
		"mdl":
			if not _asked.has(id):
				return
			var size := int(msg.get("size", 0))
			var limit := lib.budget.max_file_mb * 1048576
			if size <= 0 or size > limit:
				_refuse(id, "This model is too big for this headset (%d MB; it takes %d)." % [ceili(size / 1048576.0), lib.budget.max_file_mb])
				session.net.send(SessionNet.SERVER, {"t": "mdl_stop", "id": id}, SessionNet.CH_FILE)
				return
			var ext := str(msg.get("ext", "glb"))
			_in[id] = {"n": clampi(int(msg.get("n", 1)), 1, 100000), "size": size, "name": str(msg.get("name", "Model")).left(ModelLibrary.MAX_NAME),
				"ext": ext if ModelLoader.EXTS.has(ext) else "glb", "buf": PackedByteArray(), "i": 0}
			lib.set_progress(id, "Receiving the model... 0 %")
		"mdlc":
			var t: Variant = _in.get(id)
			var d: Variant = msg.get("d")
			if t == null or not (d is PackedByteArray) or int(msg.get("i", -1)) != int((t as Dictionary).i):
				return
			var buf: PackedByteArray = t.buf
			buf.append_array(d)
			t.buf = buf
			t.i = int(t.i) + 1
			if buf.size() > int(t.size) + CHUNK:
				_in.erase(id)
				_refuse(id, "The model that arrived was not the one asked for.")
				return
			if int(t.i) >= int(t.n):
				_finish(id, t)
			else:
				lib.set_progress(id, "Receiving the model... %d %%" % int(100.0 * float(buf.size()) / maxf(float(t.size), 1.0)))
		"mdl_no":
			_refuse(id, str(msg.get("why", "The owner could not send this model.")))


func _finish(id: String, t: Dictionary) -> void:
	var lib: ModelLibrary = session.board.models
	_in.erase(id)
	_asked.erase(id)
	var bytes: PackedByteArray = t.buf
	if ModelLibrary.id_of(bytes) != id:
		_refuse(id, "The model that arrived was damaged: it is asked for again when you rejoin.")
		return
	var res := lib.add(bytes, "%s.%s" % [str(t.name), str(t.ext)], true)
	lib.set_progress(id, "")
	lib.forget_wanted(id)
	if not bool(res.ok):
		_refuse(id, str(res.message))
	elif str(res.id) != id:
		_refuse(id, "The model that arrived could not be kept as it was sent.")
	else:
		session.say("\"%s\" arrived." % str(t.name))


func _refuse(id: String, why: String) -> void:
	_asked.erase(id)
	_in.erase(id)
	_refused[id] = why
	session.board.models.set_progress(id, why)
