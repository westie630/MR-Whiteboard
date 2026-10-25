class_name PdfShare
extends RefCounted
## PDFs in a session. The document of a session carries only WHICH PDF a canvas shows (its content id) and which page; the file itself goes
## to a guest the first time a canvas of the session needs it, from the owner, once, on a channel of its own (so that a 40 MB file never holds
## up a pen stroke). The guest checks that what arrived is the file it asked for (the id is a hash of the content) and keeps it with the
## other PDFs of that headset; each headset then makes its own pages from it, at the quality its own hardware can bear (PdfBudget).
##
## The owner only gives a file out when a canvas of the shared room names it, and to one request at a time per guest.

const CHUNK := 96 * 1024
const MAX_STORE_LOG := 6

var session                                   # Session (untyped: Session holds this object)
var rate := 6.0 * 1048576.0                   # bytes a second the owner sends a guest (tests raise it)

var _out: Dictionary = {}                     # owner: peer id -> {id, bytes, next, n}
var _in: Dictionary = {}                      # guest: pdf id -> {n, size, name, buf, have, i}
var _asked: Dictionary = {}                   # guest: pdf id -> true while a request is out
var _refused: Dictionary = {}                 # guest: pdf id -> why not (so it is not asked again and again)


func reset() -> void:
	_out.clear()
	_in.clear()
	_asked.clear()
	_refused.clear()


func drop_peer(peer: int) -> void:
	_out.erase(peer)


# ------------------------------------------------------------------------------------------------ owner

## A guest asks for a PDF.
func host_request(from: int, msg: Dictionary) -> void:
	var id := str(msg.get("id", ""))
	var lib: PdfLibrary = session.board.pdfs
	if not _referenced(id):
		session.net.send(from, {"t": "pdf_no", "id": id, "why": "This PDF is not part of the session."}, SessionNet.CH_FILE)
		return
	if not lib.has(id):
		session.net.send(from, {"t": "pdf_no", "id": id, "why": "The owner does not have this PDF any more."}, SessionNet.CH_FILE)
		return
	if _out.has(from):
		return                                                 # one at a time: the guest asks again for the next
	var bytes := lib.file_bytes(id)
	var n := maxi(ceili(float(bytes.size()) / CHUNK), 1)
	session.net.send(from, {"t": "pdf", "id": id, "n": n, "size": bytes.size(), "name": str(lib.entry(id).name)}, SessionNet.CH_FILE)
	_out[from] = {"id": id, "bytes": bytes, "next": 0, "n": n, "credit": 0.0}


func host_stop(from: int, msg: Dictionary) -> void:
	if _out.has(from) and str((_out[from] as Dictionary).id) == str(msg.get("id", "")):
		_out.erase(from)


## Sends the next pieces of what is on its way, as fast as the rate allows.
func host_tick(delta: float) -> void:
	for peer in _out.keys():
		var t: Dictionary = _out[peer]
		t.credit = minf(float(t.credit) + rate * delta, rate * 0.25 + CHUNK * 4)
		var bytes: PackedByteArray = t.bytes
		while int(t.next) < int(t.n) and float(t.credit) >= CHUNK * 0.5:
			var i := int(t.next)
			session.net.send(peer, {"t": "pdfc", "id": t.id, "i": i, "d": bytes.slice(i * CHUNK, mini((i + 1) * CHUNK, bytes.size()))}, SessionNet.CH_FILE)
			t.next = i + 1
			t.credit = float(t.credit) - CHUNK
		if int(t.next) >= int(t.n):
			_out.erase(peer)


## Does a canvas of the shared room show this PDF?
func _referenced(id: String) -> bool:
	if id == "" or session.sync.doc == null:
		return false
	for f in session.sync.doc.frames.values():
		var fd: FrameData = f
		if fd.pdf == id and session.sync.in_scope_frame(fd.id):
			return true
	return false


# ------------------------------------------------------------------------------------------------ guest

## This headset needs a PDF a canvas of the session shows: ask the owner (once).
func client_want(id: String) -> void:
	var lib: PdfLibrary = session.board.pdfs
	if lib.has(id) or _asked.has(id) or _in.has(id) or _refused.has(id):
		return
	_asked[id] = true
	lib.set_progress(id, "Asking the owner for the PDF...")
	session.net.send(SessionNet.SERVER, {"t": "pdf?", "id": id}, SessionNet.CH_FILE)


## Ask again for everything the canvases of the session show that is not here (after joining, or the link coming back).
func client_rescan() -> void:
	if session.sync.doc == null:
		return
	var lib: PdfLibrary = session.board.pdfs
	for f in session.sync.doc.frames.values():
		var fd: FrameData = f
		if fd.pdf != "" and not lib.has(fd.pdf):
			lib.forget_wanted(fd.pdf)
			_asked.erase(fd.pdf)
			_refused.erase(fd.pdf)
			lib.want(fd.pdf)


func client_msg(msg: Dictionary) -> void:
	var lib: PdfLibrary = session.board.pdfs
	var id := str(msg.get("id", ""))
	match str(msg.t):
		"pdf":
			if not _asked.has(id):
				return
			var size := int(msg.get("size", 0))
			var limit := lib.budget.max_file_mb * 1048576
			if size <= 0 or size > limit:
				_refuse(id, "This PDF is too big for this headset (%d MB; it takes %d)." % [ceili(size / 1048576.0), lib.budget.max_file_mb])
				session.net.send(SessionNet.SERVER, {"t": "pdf_stop", "id": id}, SessionNet.CH_FILE)
				return
			_in[id] = {"n": clampi(int(msg.get("n", 1)), 1, 100000), "size": size, "name": str(msg.get("name", "Document")), "buf": PackedByteArray(), "i": 0}
			lib.set_progress(id, "Receiving the PDF... 0 %")
		"pdfc":
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
				_refuse(id, "The PDF that arrived was not the one asked for.")
				return
			if int(t.i) >= int(t.n):
				_finish(id, t)
			else:
				lib.set_progress(id, "Receiving the PDF... %d %%" % int(100.0 * float(buf.size()) / maxf(float(t.size), 1.0)))
		"pdf_no":
			_refuse(id, str(msg.get("why", "The owner could not send this PDF.")))


func _finish(id: String, t: Dictionary) -> void:
	var lib: PdfLibrary = session.board.pdfs
	_in.erase(id)
	_asked.erase(id)
	var bytes: PackedByteArray = t.buf
	if PdfLibrary.id_of(bytes) != id:
		_refuse(id, "The PDF that arrived was damaged: it is asked for again when you rejoin.")
		return
	var res := lib.add(bytes, str(t.name), true)
	lib.set_progress(id, "")
	lib.forget_wanted(id)
	if not bool(res.ok):
		_refuse(id, str(res.message))
	else:
		session.say("\"%s\" arrived." % str(t.name))


func _refuse(id: String, why: String) -> void:
	_asked.erase(id)
	_in.erase(id)
	_refused[id] = why
	session.board.pdfs.set_progress(id, why)
