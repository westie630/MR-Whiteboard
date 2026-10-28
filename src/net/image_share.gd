class_name ImageShare
extends RefCounted
## Pictures in a session. The document carries only WHICH picture an item shows (its content id) and where; the file goes on the file channel,
## once, to the headsets that need it, the way PdfShare and ModelShare do PDFs and models. Unlike those, a picture can come from a GUEST: a
## guest who drops one on a canvas offers its file to the owner (img_offer), the owner asks for it if it does not have it (img_take), checks it
## (the id is a hash of the content) and from then on gives it out like its own. Guests that asked before it arrived are given it then.
##
##   guest -> owner   img? {id}  img_stop {id}  img_offer {id, size, name, ext}  imgp {id, i, d}
##   owner -> guest   img {id, n, size, name, ext}  imgc {id, i, d}  img_no {id, why}  img_take {id}  img_have {id}
##
## The owner only gives out a picture an item of the shared room shows, one transfer at a time per guest (the rest wait their turn), and takes
## one from a guest only while that guest may edit.

const CHUNK := 96 * 1024

var session                                   # Session (untyped: Session holds this object)
var rate := 6.0 * 1048576.0                   # bytes a second, each way (tests raise it)

var _out: Dictionary = {}                     # owner: peer id -> {id, bytes, next, n, credit}
var _queue: Dictionary = {}                   # owner: peer id -> [picture ids waiting their turn]
var _waiting: Dictionary = {}                 # owner: picture id -> [peer ids that asked before it arrived]
var _pushed: Dictionary = {}                  # owner: peer id -> {id, n, size, name, ext, buf, i}: a guest's picture arriving
var _in: Dictionary = {}                      # guest: picture id -> {n, size, name, ext, buf, i}
var _asked: Dictionary = {}                   # guest: picture id -> true while a request is out
var _refused: Dictionary = {}                 # guest: picture id -> why not
var _push: Dictionary = {}                    # guest: {id, bytes, next, n, credit} while sending one to the owner
var _offers: Array = []                       # guest: picture ids to offer the owner, in turn


func reset() -> void:
	_out.clear()
	_queue.clear()
	_waiting.clear()
	_pushed.clear()
	_in.clear()
	_asked.clear()
	_refused.clear()
	_push = {}
	_offers.clear()


func drop_peer(peer: int) -> void:
	_out.erase(peer)
	_queue.erase(peer)
	_pushed.erase(peer)
	for id in _waiting:
		(_waiting[id] as Array).erase(peer)


func _lib() -> ImageLibrary:
	return session.board.images


# ------------------------------------------------------------------------------------------------ owner

func host_request(from: int, msg: Dictionary) -> void:
	var id := str(msg.get("id", ""))
	if not _referenced(id):
		session.net.send(from, {"t": "img_no", "id": id, "why": "This picture is not part of the session."}, SessionNet.CH_FILE)
		return
	if not _lib().has(id):
		if not _waiting.has(id):
			_waiting[id] = []
		if not (_waiting[id] as Array).has(from):
			(_waiting[id] as Array).append(from)                  # (it is on its way from the guest who put it down)
		return
	_serve(from, id)


func _serve(peer: int, id: String) -> void:
	if _out.has(peer):
		if str((_out[peer] as Dictionary).id) == id:
			return
		if not _queue.has(peer):
			_queue[peer] = []
		if not (_queue[peer] as Array).has(id):
			(_queue[peer] as Array).append(id)
		return
	var lib := _lib()
	var bytes := lib.file_bytes(id)
	var e := lib.entry(id)
	var n := maxi(ceili(float(bytes.size()) / CHUNK), 1)
	session.net.send(peer, {"t": "img", "id": id, "n": n, "size": bytes.size(), "name": str(e.get("name", "Picture")), "ext": str(e.get("ext", "png"))}, SessionNet.CH_FILE)
	_out[peer] = {"id": id, "bytes": bytes, "next": 0, "n": n, "credit": 0.0}


func host_stop(from: int, msg: Dictionary) -> void:
	if _out.has(from) and str((_out[from] as Dictionary).id) == str(msg.get("id", "")):
		_out.erase(from)
		_next(from)


func _next(peer: int) -> void:
	var q: Array = _queue.get(peer, [])
	while not q.is_empty():
		var id: String = q.pop_front()
		if _lib().has(id):
			_serve(peer, id)
			return


## A guest has a picture it put down: the owner asks for it unless it has it, and only from a guest who may edit.
func host_offer(from: int, msg: Dictionary) -> void:
	var id := str(msg.get("id", ""))
	var size := int(msg.get("size", 0))
	if _pushed.has(from):
		return
	if _lib().has(id):
		session.net.send(from, {"t": "img_have", "id": id}, SessionNet.CH_FILE)
		return
	if not ImageLibrary.EXTS.has(str(msg.get("ext", ""))) or not bool((session.peers.get(from, {}) as Dictionary).get("can_edit", session.edit_all)):
		session.net.send(from, {"t": "img_no", "id": id, "why": "The owner's headset did not take the picture: the others will not see it."}, SessionNet.CH_FILE)
		return
	if size <= 0 or size > _lib().max_file_mb() * 1048576:
		session.net.send(from, {"t": "img_no", "id": id, "why": "The picture is too big for the owner's headset."}, SessionNet.CH_FILE)
		return
	_pushed[from] = {"id": id, "n": clampi(int(msg.get("n", 1)), 1, 100000), "size": size, "name": str(msg.get("name", "Picture")).left(ImageLibrary.MAX_NAME),
		"ext": str(msg.ext), "buf": PackedByteArray(), "i": 0}
	session.net.send(from, {"t": "img_take", "id": id}, SessionNet.CH_FILE)


func host_piece(from: int, msg: Dictionary) -> void:
	var t: Variant = _pushed.get(from)
	var d: Variant = msg.get("d")
	if t == null or str((t as Dictionary).id) != str(msg.get("id", "")) or not (d is PackedByteArray) or int(msg.get("i", -1)) != int((t as Dictionary).i):
		return
	var buf: PackedByteArray = t.buf
	buf.append_array(d)
	t.buf = buf
	t.i = int(t.i) + 1
	if buf.size() > int(t.size) + CHUNK:
		_pushed.erase(from)
		return
	if int(t.i) < int(t.n):
		return
	_pushed.erase(from)
	var id := str(t.id)
	if ImageLibrary.id_of(buf) != id:
		return
	var res := _lib().add(buf, "%s.%s" % [str(t.name), str(t.ext)])
	if not bool(res.ok) or str(res.id) != id:
		return
	var who: Array = _waiting.get(id, [])
	_waiting.erase(id)
	for peer in who:
		if session.peers.has(peer):
			_serve(int(peer), id)


func host_tick(delta: float) -> void:
	for peer in _out.keys():
		var t: Dictionary = _out[peer]
		t.credit = minf(float(t.credit) + rate * delta, rate * 0.25 + CHUNK * 4)
		var bytes: PackedByteArray = t.bytes
		while int(t.next) < int(t.n) and float(t.credit) >= CHUNK * 0.5:
			var i := int(t.next)
			session.net.send(peer, {"t": "imgc", "id": t.id, "i": i, "d": bytes.slice(i * CHUNK, mini((i + 1) * CHUNK, bytes.size()))}, SessionNet.CH_FILE)
			t.next = i + 1
			t.credit = float(t.credit) - CHUNK
		if int(t.next) >= int(t.n):
			_out.erase(peer)
			_next(peer)


## Does an item of the shared room show this picture?
func _referenced(id: String) -> bool:
	if id == "" or session.sync.doc == null:
		return false
	for it in session.sync.doc.items.values():
		var item: Item = it
		if item.kind == Item.IMAGE and item.image == id and session.sync.in_scope_frame(item.frame):
			return true
	return false


# ------------------------------------------------------------------------------------------------ guest

func client_want(id: String) -> void:
	var lib := _lib()
	if lib.has(id) or _asked.has(id) or _in.has(id) or _refused.has(id):
		return
	_asked[id] = true
	lib.set_progress(id, "Asking the owner for the picture...")
	session.net.send(SessionNet.SERVER, {"t": "img?", "id": id}, SessionNet.CH_FILE)


## Ask again for every picture the items of the session show that is not here (after joining, or the link coming back).
func client_rescan() -> void:
	if session.sync.doc == null:
		return
	var lib := _lib()
	for it in session.sync.doc.items.values():
		var item: Item = it
		if item.kind == Item.IMAGE and item.image != "" and not lib.has(item.image):
			lib.forget_wanted(item.image)
			_asked.erase(item.image)
			_refused.erase(item.image)
			lib.want(item.image)


## This guest put a picture down: offer its file to the owner (who asks for it only if it does not have it).
func client_offer(id: String) -> void:
	if not _lib().has(id) or _offers.has(id) or (not _push.is_empty() and str(_push.id) == id):
		return
	_offers.append(id)
	if _push.is_empty() and _offers.size() == 1:
		_send_offer()


func _send_offer() -> void:
	if _offers.is_empty():
		return
	var id: String = _offers[0]
	var lib := _lib()
	var e := lib.entry(id)
	var size := int(e.get("size", 0))
	session.net.send(SessionNet.SERVER, {"t": "img_offer", "id": id, "size": size, "n": maxi(ceili(float(size) / CHUNK), 1), "name": str(e.get("name", "Picture")),
		"ext": str(e.get("ext", "png"))}, SessionNet.CH_FILE)


func client_tick(delta: float) -> void:
	if _push.is_empty():
		return
	var t := _push
	t.credit = minf(float(t.credit) + rate * delta, rate * 0.25 + CHUNK * 4)
	var bytes: PackedByteArray = t.bytes
	while int(t.next) < int(t.n) and float(t.credit) >= CHUNK * 0.5:
		var i := int(t.next)
		session.net.send(SessionNet.SERVER, {"t": "imgp", "id": t.id, "i": i, "d": bytes.slice(i * CHUNK, mini((i + 1) * CHUNK, bytes.size()))}, SessionNet.CH_FILE)
		t.next = i + 1
		t.credit = float(t.credit) - CHUNK
	if int(t.next) >= int(t.n):
		_push = {}
		_send_offer()


func client_msg(msg: Dictionary) -> void:
	var lib := _lib()
	var id := str(msg.get("id", ""))
	match str(msg.t):
		"img":
			if not _asked.has(id):
				return
			var size := int(msg.get("size", 0))
			if size <= 0 or size > lib.max_file_mb() * 1048576:
				_refuse(id, "This picture is too big for this headset (%d MB; it takes %d)." % [ceili(size / 1048576.0), lib.max_file_mb()])
				session.net.send(SessionNet.SERVER, {"t": "img_stop", "id": id}, SessionNet.CH_FILE)
				return
			var ext := str(msg.get("ext", "png"))
			_in[id] = {"n": clampi(int(msg.get("n", 1)), 1, 100000), "size": size, "name": str(msg.get("name", "Picture")).left(ImageLibrary.MAX_NAME),
				"ext": ext if ImageLibrary.EXTS.has(ext) else "png", "buf": PackedByteArray(), "i": 0}
			lib.set_progress(id, "Receiving the picture... 0 %")
		"imgc":
			var t: Variant = _in.get(id)
			var d: Variant = msg.get("d")
			if t == null or not (d is PackedByteArray) or int(msg.get("i", -1)) != int((t as Dictionary).i):
				return
			var buf: PackedByteArray = t.buf
			buf.append_array(d)
			t.buf = buf
			t.i = int(t.i) + 1
			if buf.size() > int(t.size) + CHUNK:
				_refuse(id, "The picture that arrived was not the one asked for.")
				return
			if int(t.i) >= int(t.n):
				_finish(id, t)
			else:
				lib.set_progress(id, "Receiving the picture... %d %%" % int(100.0 * float(buf.size()) / maxf(float(t.size), 1.0)))
		"img_no":
			if _offers.has(id):
				_offers.erase(id)
				session.say(str(msg.get("why", "The owner did not take the picture.")))
				_send_offer()
			else:
				_refuse(id, str(msg.get("why", "The owner could not send this picture.")))
		"img_have":
			if not _offers.is_empty() and str(_offers[0]) == id:
				_offers.pop_front()
				_send_offer()
		"img_take":
			if _offers.is_empty() or str(_offers[0]) != id or not lib.has(id):
				return
			_offers.pop_front()
			var bytes := lib.file_bytes(id)
			_push = {"id": id, "bytes": bytes, "next": 0, "n": maxi(ceili(float(bytes.size()) / CHUNK), 1), "credit": 0.0}


func _finish(id: String, t: Dictionary) -> void:
	var lib := _lib()
	_in.erase(id)
	_asked.erase(id)
	var bytes: PackedByteArray = t.buf
	if ImageLibrary.id_of(bytes) != id:
		_refuse(id, "The picture that arrived was damaged: it is asked for again when you rejoin.")
		return
	var res := lib.add(bytes, "%s.%s" % [str(t.name), str(t.ext)], true)
	lib.set_progress(id, "")
	lib.forget_wanted(id)
	if not bool(res.ok):
		_refuse(id, str(res.message))
	elif str(res.id) != id:
		_refuse(id, "The picture that arrived could not be kept as it was sent.")


func _refuse(id: String, why: String) -> void:
	_asked.erase(id)
	_in.erase(id)
	_refused[id] = why
	_lib().set_progress(id, why)
