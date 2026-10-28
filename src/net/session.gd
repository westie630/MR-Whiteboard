class_name Session
extends Node
## A session: one owner's headset (the HOST) and any number of guests' headsets (CLIENTS) on the same network seeing and editing the
## same document. The host's document is the truth: edits made anywhere are sent to it, checked (is this guest allowed to edit? is that
## canvas locked?), applied, and passed on to everybody else, so every headset ends up with exactly what the host has. Each guest
## works on a copy of the shared room that is never saved into their own documents; when they leave, their own document comes back.
##
## What goes over the wire (SessionNet: control / data / live channels), who sends it:
##   hello  welcome  refuse  ready  snap + chunk   joining: the code, a name, then the shared room as a document
##   ops  ack                                      editing: what changed (DocSync), the host's answer
##   space                                         where the shared room is in the shared space (see SharedSpace)
##   roster                                        who is here and what they may do
##   ping  pong  status  ended                     liveness, how a guest is aligned, the end of the session
##   (live channel)                                where everyone's head and stylus are, a dozen times a second
##
## Editing is optimistic on a guest's headset: it shows its own edits at once and sends them; until the host has answered, news about
## the same things from others is held back, so everybody lands on the order the host chose. Docs: docs/SHARING.md.
##
## Two ways to be in a session, chosen by each guest (`place`): TOGETHER, in the owner's real room, where the canvases must stand on the
## same real spot for everybody (so a guest sees nothing until they and the owner have touched the same two places), and APART, in
## another room, where the board is put in front of the guest and only what is on it is shared. The owner needs no choice: it is the room.
##
## Places stay put for everybody. Until the owner aligns to two touched points, the shared space P is the shared room's own frame
## (held by the owner's room anchor), so the owner recentring, re-localising or restarting moves nobody's board. Every headset's
## alignment (points, or "in front of me") is held by a spatial anchor of its own, so it survives recentring and the headset being taken
## off; a reconnect keeps it. A session survives the apps being restarted: the owner's headset starts it again (same code, same space),
## and a guest's headset joins it again with the alignment it had (session_resume in the settings).

signal changed()                           # roster, state, alignment, permissions: the interface refreshes
signal said(text: String)                  # a line for the toast

enum Role { NONE, HOST, CLIENT }

const PROTOCOL := 4                        # (2: the file channel for PDFs; 3: 3D models, their files on it too; 4: pictures, both ways)
const PLACES: Array[String] = ["together", "apart"]
const HOST_ID := 1                         # the host's id in every roster
const PORT := 8190
const MAX_CLIENTS := 40
const MAX_NAME := 24
const HELLO_TIMEOUT_S := 6.0               # a headset that connects and says nothing is dropped
const PING_S := 2.0
const SILENT_S := 15.0                     # nothing heard for this long: gone
const PRESENCE_S := 0.1
const STALE_S := 2.5                       # a pose older than this is not shown
const SPACE_S := 0.25                      # how often the host looks whether its room moved
const RETRY_S := 3.0                       # a lost guest tries again this often...
const GIVE_UP_S := 120.0                   # ...for this long
const CHUNK := 96 * 1024                   # a document is sent in pieces this big
const FAIL_LIMIT := 5                      # wrong codes from one address...
const FAIL_LOCK_S := 60.0                  # ...and it is ignored for this long
const END_GRACE_S := 0.4                   # the host waits this long for "the session has ended" to be on its way
const KICK_GRACE_S := 0.5                  # ...and this long between telling a headset to go and cutting it off
const TAP_S := 0.12                        # aligning with the stylus: a press shorter than this is one point (its average)
const HAND_HOLD_S := 0.35                  # aligning with a pinch: held this long, the point is where the fingers were on average
const ALIGN_WAIT_S := 15.0                 # an alignment restored after a restart waits this long (headset on) for its anchor to be found
const RESUME_WAIT_S := 120.0               # the owner's headset waits this long (headset on) for the room before giving up starting the session again
const COLORS: Array[Color] = [Color("#3fe0c8"), Color("#ffb454"), Color("#ff5d8f"), Color("#b69cff"), Color("#4ea8ff"),
	Color("#a3e635"), Color("#ff9f43"), Color("#ef476f"), Color("#ffd166"), Color("#7b6cff")]
const REFUSALS := {"code": "That is not the session code.", "locked": "The session is closed to new people.", "full": "The session is full.",
	"version": "That headset runs another version of the app.", "wait": "Too many wrong codes: wait a minute."}

var board: Board
var net := SessionNet.new()
var disco := LanDiscovery.new()
var sync := DocSync.new()
var avatars: PeerAvatars
var live_out := LiveOut.new()              # what this headset is in the middle of doing, for the others
var pdf_share := PdfShare.new()            # PDFs: the owner gives a file out to a guest whose canvas shows it
var model_share := ModelShare.new()        # 3D models: the same, for a guest whose room shows a model it does not have
var image_share := ImageShare.new()        # pictures: the same, and a guest's own picture goes to the owner first
var previews: LivePreview                  # what the others are in the middle of doing

var role := Role.NONE
var phase := "idle"                        # idle | connecting | joining | live | reconnecting | ending
var my_id := 0
var my_name := ""
var session_title := ""
var host_name := ""
var doc_name := ""
var room_id := ""                          # the shared room (a guest's copy has just this one room, with the same id)
var room_name := ""
var code := ""                             # the session code ("" = none asked for)
var locked := false                        # host: no new guests
var edit_all := true                       # host: guests may draw, erase, write and move what is on the canvases
var canvas_edit := false                   # host: guests may also add, delete, rename, restyle and move canvases
var peers: Dictionary = {}                 # id -> {id, name, color, can_edit, align, place, device, ready, seen}
var presence: Dictionary = {}              # id -> {head: Transform3D (shared space), tracked, tip, dir, down, pressure, t}
var rtt_ms := 0
var client_doc: Document                   # guest: the copy of the shared room that is on the board
var opening := false                       # guest: the session itself is opening the document
var session_id := ""
var last_error := ""                       # why the last attempt to join failed (shown to the guest)
var scanning := false                      # listening for sessions on the network (only while a guest could pick one)
var scan_failed := false                   # ...but this network or device would not let it

# the shared space (SharedSpace): everything on the wire is in P; align_xf is where P is in this headset's tracking space
var place := "apart"                       # guest: together (in the owner's real room: align_mode is none until lined up, then points) | apart (here)
var align_mode := "none"                   # none | here | points
var align_xf := Transform3D.IDENTITY
var align_epoch := 0                       # the host's epoch the alignment was made in
var space_epoch := 1
var room_p := Transform3D.IDENTITY         # the shared room's origin in P
var host_head_p := Transform3D.IDENTITY
var have_space := false
var realign_hint := false                  # the owner aligned again after this guest did
var align_span := 0.0                      # points: how far apart the two touched points were
var align_marks_until := 0.0               # the two points are drawn in the room until then (seconds on the session clock)

var retry_s := RETRY_S                     # (tests make it shorter)

var _now := 0.0
var _hello: Dictionary = {}                # host: id -> {t, address} of headsets that connected and have not said hello
var _to_kick: Dictionary = {}              # host: id -> when to cut the connection (after the last thing said to them is on its way)
var _fails: Dictionary = {}                # host: address -> {n, until}
var _space_t := 0.0
var _space_sent := false
var _presence_t := 0.0
var _beacon_t := 0.0
var _ending_t := -1.0
var _snap: Dictionary = {}                 # guest: the document arriving
var _seq := 0
var _inflight: Dictionary = {}             # guest: seq -> ids the host has not answered for yet
var _pending: Dictionary = {}              # guest: id -> how many of its sends are unanswered
var _server_address := ""
var _server_port := 0
var _server_code := ""
var _prev_doc_id := ""
var _ping_t := 0.0
var _heard := 0.0
var _retry_t := 0.0
var _lost_t := 0.0
var _wanted_here := false
var _align: Dictionary = {}                # the stylus wizard: {points, press, note}; empty = not aligning
var _align_anchor := ""                    # a spatial anchor at the aligned frame (follows the room when the headset recentres)
var _align_pending := false
var _align_known := true                   # false while an alignment restored after a restart waits for its anchor (align_xf means nothing yet)
var _align_wait_t := 0.0
var host_session := ""                     # guest: the id of the session joined (the host's session_id)
var _resume: Dictionary = {}               # a session to start again or join again after the app was restarted (see resume_saved)
var _resume_t := 0.0
var _was_back := false
var _told_at := -100.0                     # when a guest was last told that something was refused
var _scan_sig := ""


func _init() -> void:
	name = "Session"
	net.peer_joined.connect(_on_peer_joined)
	net.peer_left.connect(_on_peer_left)
	net.received.connect(_on_received)
	net.received_live.connect(_on_live)
	net.connected.connect(_on_connected)
	net.failed.connect(_on_failed)
	pdf_share.session = self
	model_share.session = self
	image_share.session = self


func bind(anchors: AnchorService) -> void:
	if anchors != null and not anchors.created.is_connected(_on_anchor_created):
		anchors.created.connect(_on_anchor_created)


func _ready() -> void:
	avatars = PeerAvatars.new()
	avatars.session = self
	board.add_child.call_deferred(avatars)          # the board is still setting up its children
	live_out.board = board
	board.pdfs.wanted.connect(_on_pdf_wanted)
	board.models.wanted.connect(_on_model_wanted)
	board.images.wanted.connect(_on_image_wanted)
	previews = LivePreview.new()
	previews.session = self
	board.add_child.call_deferred(previews)


func _exit_tree() -> void:
	net.close()
	disco.stop_announcing()
	disco.stop_listening()


# ------------------------------------------------------------------------------------------------ what the rest of the app asks

func is_active() -> bool:
	return role != Role.NONE


func is_host() -> bool:
	return role == Role.HOST


func is_client() -> bool:
	return role == Role.CLIENT


## A guest whose copy of the document is on the board (also while the link is being re-made).
func has_copy() -> bool:
	return role == Role.CLIENT and client_doc != null and board.doc == client_doc


func can_edit() -> bool:
	if role != Role.CLIENT:
		return true
	return bool((peers.get(my_id, {}) as Dictionary).get("can_edit", edit_all))


func can_edit_canvases() -> bool:
	return role != Role.CLIENT or (can_edit() and canvas_edit)


func my_color() -> Color:
	return COLORS[int((peers.get(my_id, {}) as Dictionary).get("color", 0)) % COLORS.size()]


func color_of(id: int) -> Color:
	return COLORS[int((peers.get(id, {}) as Dictionary).get("color", id)) % COLORS.size()]


func peer_ids() -> Array:
	var ids: Array = peers.keys()
	ids.sort()
	return ids


## Guests (not the host) that are here.
func guest_count() -> int:
	return maxi(peers.size() - 1, 0)


func say(text: String) -> void:
	said.emit(text)


# ------------------------------------------------------------------------------------------------ hosting

## Start a session on the open document's current room. `use_code`: guests need the four-digit code. Returns OK or an Error.
func start_hosting(owner: String, title: String = "", use_code: bool = true) -> Error:
	if role != Role.NONE:
		return ERR_ALREADY_IN_USE
	if board.doc == null or board.current_room == "":
		return ERR_UNCONFIGURED
	var err := net.host(PORT, MAX_CLIENTS)
	if err != OK:
		return err
	role = Role.HOST
	phase = "live"
	session_id = U.uid("s")
	my_id = SessionNet.SERVER
	my_name = _clean_name(owner, "Owner")
	host_name = my_name
	session_title = title.strip_edges().left(MAX_NAME * 2) if title.strip_edges() != "" else "%s's session" % my_name
	code = new_code() if use_code else ""
	locked = false
	edit_all = true
	canvas_edit = false
	peers = {my_id: _peer_entry(my_id, my_name, "host", "together")}      # (the owner is the room the others are in, or not)
	presence.clear()
	align_mode = "none"
	align_xf = Transform3D.IDENTITY
	space_epoch = 1
	have_space = true
	_space_sent = false
	_space_t = SPACE_S
	_share_current()
	disco.own_id = session_id
	_announce()
	_save_resume()
	changed.emit()
	return OK


func new_code() -> String:
	return "%04d" % (Crypto.new().generate_random_bytes(4).decode_u32(0) % 10000)


## The host changes the code (the old one stops working; guests already in stay).
func change_code() -> void:
	if role == Role.HOST and code != "":
		code = new_code()
		_save_resume()
		changed.emit()


func _share_current() -> void:
	sync.attach(board.doc, board.current_room)
	doc_name = board.doc.name
	room_id = board.current_room
	room_name = str(board.doc.room(room_id).get("name", "Room"))


## The host opened another document (or walked into another room): everybody gets that one instead.
func _reshare() -> void:
	previews.clear_all()
	live_out.reset()
	_share_current()
	_space_sent = false
	for id in peers.keys():
		if id != my_id and bool(peers[id].get("ready", false)):
			_send_snapshot(id)
	_announce()
	changed.emit()


func end() -> void:
	if role == Role.HOST and phase != "ending":
		net.send(0, {"t": "ended"})
		phase = "ending"
		_ending_t = END_GRACE_S
		disco.stop_announcing()
		changed.emit()
	elif role == Role.CLIENT:
		leave()


func _finish_ending() -> void:
	_ending_t = -1.0
	net.close()
	sync.detach()
	peers.clear()
	presence.clear()
	_hello.clear()
	_to_kick.clear()
	previews.clear_all()
	live_out.reset()
	role = Role.NONE
	phase = "idle"
	my_id = 0
	_drop_align_anchor()
	align_mode = "none"
	align_xf = Transform3D.IDENTITY
	_align_known = true
	_clear_resume()                                   # ended on purpose: a restart does not start it again
	if avatars != null:
		avatars.refresh()
	changed.emit()


func set_locked(on: bool) -> void:
	if role == Role.HOST:
		locked = on
		_announce()
		_send_roster()
		_save_resume()


func set_edit_all(on: bool) -> void:
	if role != Role.HOST:
		return
	edit_all = on
	for id in peers.keys():
		if id != my_id:
			peers[id].can_edit = on
	_send_roster()
	_save_resume()


func set_peer_edit(id: int, on: bool) -> void:
	if role == Role.HOST and peers.has(id) and id != my_id:
		peers[id].can_edit = on
		_send_roster()


func set_canvas_edit(on: bool) -> void:
	if role == Role.HOST:
		canvas_edit = on
		_send_roster()
		_save_resume()


func kick(id: int) -> void:
	if role != Role.HOST or id == my_id or not peers.has(id):
		return
	net.send(id, {"t": "kicked"})
	_kick_later(id)
	say("%s was removed." % str(peers[id].name))
	_remove_peer(id)


## Cut a connection a moment from now: a connection cut at once can lose the message that says why.
func _kick_later(id: int) -> void:
	_to_kick[id] = _now + KICK_GRACE_S


func _announce() -> void:
	if role != Role.HOST:
		return
	var info := {"id": session_id, "name": session_title, "host": host_name, "doc": doc_name, "port": net.port, "pin": code != "", "locked": locked,
		"n": maxi(peers.size() - 1, 0)}
	if disco.announcing():
		disco.update_info(info)
	else:
		disco.announce(info)


# ------------------------------------------------------------------------------------------------ joining

## Look for sessions on the network (or stop looking). Only while nobody is in a session.
func scan(on: bool) -> void:
	if on and role == Role.NONE:
		if not disco.listening():
			scan_failed = not disco.listen()
		scanning = disco.listening()
	else:
		disco.stop_listening()
		scanning = false
		_scan_sig = ""


## A guest keeps what is on the board as a document of their own. Returns its name ("" if there is nothing to keep).
func save_copy() -> String:
	if role != Role.CLIENT or client_doc == null:
		return ""
	var d := Document.from_dict(client_doc.to_dict())
	d.id = U.uid("d")
	d.name = "%s (%s)" % [doc_name, session_title] if session_title != "" else doc_name
	d.transient = false
	d.created = int(Time.get_unix_time_from_system())
	# the anchors in the session's copy are the owner's (they mean nothing on this headset): the copy gets a room anchor of its own,
	# where the board is now, so it opens in the same place later; its canvases get theirs when it is opened
	for f in d.frames.values():
		(f as FrameData).keep_anchor_of(null)
	var rw: Variant = room_world(room_id)
	for r in d.rooms:
		d.set_room_field(str(r.id), "anchor", "")
		d.set_room_field(str(r.id), "anchor_xf", rw if rw != null else Transform3D.IDENTITY)
	d.save(DocStore.path_for(d.id))
	if rw != null and board.anchors != null and board.anchors.is_supported() and not d.rooms.is_empty():
		var f := -(rw as Transform3D).basis.z
		board.anchors.create(Transform3D(Basis(Vector3.UP, atan2(-f.x, -f.z)), (rw as Transform3D).origin), "copy:%s:%s" % [d.id, str(d.rooms[0].id)])
	return d.name


## Join the session at `address`. `name` is what the others see. `where`: "together" (in the owner's real room) or "apart" (somewhere
## else); empty is what this headset chose last. The answer comes as `said` lines and `phase`.
func join(address: String, port: int, session_code: String, guest: String, where: String = "") -> Error:
	if role != Role.NONE:
		return ERR_ALREADY_IN_USE
	scan(false)
	var err := net.join(address.strip_edges(), port)
	if err != OK:
		return err
	role = Role.CLIENT
	phase = "connecting"
	place = where if where in PLACES else str(App.val("session_place"))
	if not place in PLACES:
		place = "apart"
	my_name = _clean_name(guest, "Guest")
	_server_address = address.strip_edges()
	_server_port = port
	_server_code = session_code.strip_edges()
	last_error = ""
	_heard = _now
	_lost_t = 0.0
	align_mode = "none"
	align_xf = Transform3D.IDENTITY
	_align_known = true
	have_space = false
	realign_hint = false
	_snap = {}
	_wanted_here = true
	changed.emit()
	return OK


## Leave the session (a guest) or end it (the host). A guest's own document comes back unless `restore` is false.
func leave(quiet: bool = false, restore: bool = true) -> void:
	if role == Role.HOST:
		end()
		return
	if role != Role.CLIENT:
		return
	net.close()
	sync.detach()
	pdf_share.reset()
	board.pdfs.trim_cached(PdfShare.MAX_STORE_LOG)
	model_share.reset()
	board.models.trim_cached(ModelShare.MAX_STORE_LOG)
	image_share.reset()
	board.images.trim_cached()
	_clear_resume()                                   # left (or turned away, or the session ended): a restart does not join it again
	var had := client_doc
	role = Role.NONE
	phase = "idle"
	peers.clear()
	presence.clear()
	_snap = {}
	_inflight.clear()
	_pending.clear()
	_drop_align_anchor()
	align_mode = "none"
	align_xf = Transform3D.IDENTITY
	_align_known = true
	have_space = false
	_align = {}
	my_id = 0
	host_session = ""
	client_doc = null
	previews.clear_all()
	live_out.reset()
	if avatars != null:
		avatars.refresh()
	if restore and had != null and board.doc == had:
		var back: Document = DocStore.open(_prev_doc_id) if _prev_doc_id != "" else null
		if back == null:
			var list := DocStore.list()
			back = DocStore.open(str(list[0].id)) if not list.is_empty() else DocStore.create_new()
		board.open(back)
	if not quiet:
		say("You left the session.")
	changed.emit()


## A canvas shows a PDF this headset does not have: a guest asks the owner for it.
func _on_pdf_wanted(pdf_id: String) -> void:
	if role == Role.CLIENT and phase == "live":
		pdf_share.client_want(pdf_id)


## A frame shows a 3D model this headset does not have: a guest asks the owner for it.
func _on_model_wanted(model_id: String) -> void:
	if role == Role.CLIENT and phase == "live":
		model_share.client_want(model_id)


## A canvas shows a picture this headset does not have: a guest asks the owner for it.
func _on_image_wanted(image_id: String) -> void:
	if role == Role.CLIENT and phase == "live":
		image_share.client_want(image_id)


func _on_connected() -> void:
	if role != Role.CLIENT:
		return
	phase = "joining"
	_heard = _now
	net.send(SessionNet.SERVER, {"t": "hello", "v": PROTOCOL, "name": my_name, "code": _server_code, "device": "quest" if App.xr_active else "pc", "place": place})
	changed.emit()


func _on_failed() -> void:
	if role != Role.CLIENT:
		return
	if phase == "connecting" and client_doc == null and _resume.is_empty():
		last_error = "Could not reach %s. Is the session running, and are you on the same Wi-Fi?" % _server_address
		_give_up(last_error)
		return
	_lost()                                            # (also joining again after a restart: the owner's app may be starting too)


## The link dropped (the headset slept, the Wi-Fi blinked): keep what is on the board and try again for a while.
func _lost() -> void:
	if phase == "reconnecting":
		return
	net.close()
	phase = "reconnecting"
	_retry_t = 0.0
	_lost_t = 0.0
	presence.clear()
	_inflight.clear()
	_pending.clear()
	previews.clear_all()
	if avatars != null:
		avatars.refresh()
	say("Lost the connection to the session: trying again...")
	changed.emit()


func _give_up(text: String) -> void:
	last_error = text
	say(text)
	leave(true)


# ------------------------------------------------------------------------------------------------ every frame

func _process(delta: float) -> void:
	_now += delta
	net.poll()
	disco.update(delta)
	if disco.listening():
		var sig := ""
		for c in disco.sessions():
			sig += "%s%s%d%s;" % [c.address, c.name, c.n, c.locked]
		if sig != _scan_sig:
			_scan_sig = sig
			changed.emit()
	if not _resume.is_empty() and role == Role.NONE:
		_resume_update(delta)
	if not _align_known and role != Role.NONE:
		_align_wait(delta)
	match role:
		Role.HOST:
			_host_update(delta)
		Role.CLIENT:
			_client_update(delta)


func _host_update(delta: float) -> void:
	if _ending_t >= 0.0:
		_ending_t -= delta
		if _ending_t < 0.0:
			_finish_ending()
		return
	for id in _to_kick.keys():
		if _now >= float(_to_kick[id]):
			_to_kick.erase(id)
			net.kick(id)
	for id in _hello.keys():
		if _now - float(_hello[id].t) > HELLO_TIMEOUT_S:
			_hello.erase(id)
			net.kick(id)
	for id in peers.keys():
		if id != my_id and _now - float(peers[id].seen) > SILENT_S:
			net.kick(id)
			say("%s stopped answering." % str(peers[id].name))
			_remove_peer(id)
	if board.doc != null and (board.doc != sync.doc or (board.current_room != "" and board.current_room != room_id)):
		_reshare()
	_flush_host()
	pdf_share.host_tick(delta)
	model_share.host_tick(delta)
	image_share.host_tick(delta)
	_space_t += delta
	if _space_t >= SPACE_S:
		_space_t = 0.0
		_host_space()
	_beacon_t += delta
	if _beacon_t >= 2.0:
		_beacon_t = 0.0
		_announce()


func _client_update(delta: float) -> void:
	if phase == "live":
		_flush_client()
		image_share.client_tick(delta)
		_ping_t += delta
		if _ping_t >= PING_S:
			_ping_t = 0.0
			net.send(SessionNet.SERVER, {"t": "ping", "n": Time.get_ticks_msec()})
		if _now - _heard > SILENT_S:
			_lost()
	elif phase == "reconnecting":
		_lost_t += delta
		_retry_t += delta
		if _lost_t > GIVE_UP_S:
			_give_up("The session could not be reached again.")
			return
		if _retry_t >= retry_s:
			_retry_t = 0.0
			net.join(_server_address, _server_port)
	elif phase == "joining" and _now - _heard > SILENT_S:
		_give_up("The session did not answer.")


## Every frame, from the board: where my head and my pointer are (sent a dozen times a second). The pointer is the stylus when there
## is one (there is usually just one in a session), else the index finger of a tracked hand, "pressed" while it is pinching.
func tick(pen: PenState, hands: Array, dt: float) -> void:
	if role == Role.NONE or phase != "live":
		return
	_stream_edits(dt)
	if not in_shared_space():
		return                                                 # a pose in a space this headset does not share yet would put me in the wrong place
	_presence_t += dt
	if _presence_t < PRESENCE_S:
		return
	_presence_t = 0.0
	var inv := align_world().affine_inverse()
	var head_p := inv * board.head
	var ptr := _pointer(pen, hands)
	var tracked := bool(ptr.tracked)
	var tip_p: Vector3 = inv * (ptr.tip as Vector3) if tracked else Vector3.ZERO
	var dir_p: Vector3 = (inv.basis * (ptr.dir as Vector3)).normalized() if tracked else Vector3.FORWARD
	var entry := {"head": head_p, "tracked": tracked, "tip": tip_p, "dir": dir_p, "down": tracked and bool(ptr.down), "pressure": float(ptr.pressure), "t": _now}
	presence[my_id] = entry
	if role == Role.CLIENT:
		var b := PackedByteArray([0x50])
		b.append_array(encode_presence(my_id, entry))
		net.send_live(SessionNet.SERVER, b)
	else:
		_broadcast_presence()


# ------------------------------------------------------------------------------------------------ host: messages

func _on_peer_joined(id: int) -> void:
	if role != Role.HOST:
		return
	if locked and phase != "ending":
		pass                                      # told so when it says hello, so that it learns why
	_hello[id] = {"t": _now, "address": net.address_of(id)}


func _on_peer_left(id: int) -> void:
	if role == Role.HOST:
		_hello.erase(id)
		if peers.has(id):
			say("%s left." % str(peers[id].name))
			_remove_peer(id)


func _remove_peer(id: int) -> void:
	pdf_share.drop_peer(id)
	model_share.drop_peer(id)
	image_share.drop_peer(id)
	peers.erase(id)
	presence.erase(id)
	if previews != null:
		previews.clear_peer(id)
	if avatars != null:
		avatars.refresh()
	_send_roster()
	_announce()


func _on_received(from: int, _channel: int, msg: Dictionary) -> void:
	match role:
		Role.HOST:
			_host_msg(from, msg)
		Role.CLIENT:
			_client_msg(msg)


func _host_msg(from: int, msg: Dictionary) -> void:
	var kind := str(msg.t)
	if kind == "hello":
		_on_hello(from, msg)
		return
	var p: Dictionary = peers.get(from, {})
	if p.is_empty():
		return                                    # nobody who has not said hello is listened to
	p.seen = _now
	match kind:
		"pdf?":
			pdf_share.host_request(from, msg)
		"pdf_stop":
			pdf_share.host_stop(from, msg)
		"mdl?":
			model_share.host_request(from, msg)
		"mdl_stop":
			model_share.host_stop(from, msg)
		"img?":
			image_share.host_request(from, msg)
		"img_stop":
			image_share.host_stop(from, msg)
		"img_offer":
			image_share.host_offer(from, msg)
		"imgp":
			image_share.host_piece(from, msg)
		"ready":
			_send_snapshot(from)
			_send_space(from)
			_send_roster()
		"ops":
			_host_ops(from, msg)
		"ping":
			net.send(from, {"t": "pong", "n": msg.get("n", 0)})
		"status":
			var mode := str(msg.get("align", "none"))
			var where := str(msg.get("place", p.get("place", "apart")))
			if mode in ["none", "here", "points"] and where in PLACES:
				var arrived := where == "together" and str(p.place) != "together"
				p.align = mode
				p.place = where
				_send_roster()
				if arrived:
					_nudge_owner(str(p.name))


func _on_hello(from: int, msg: Dictionary) -> void:
	_hello.erase(from)
	if peers.has(from) or phase == "ending":
		return
	var address := net.address_of(from)
	var fail: Dictionary = _fails.get(address, {"n": 0, "until": 0.0})
	if float(fail.until) > _now:
		_refuse(from, "wait")
		return
	if int(msg.get("v", 0)) != PROTOCOL:
		_refuse(from, "version")
		return
	if code != "" and str(msg.get("code", "")) != code:
		fail.n = int(fail.n) + 1
		if int(fail.n) >= FAIL_LIMIT:
			fail.n = 0
			fail.until = _now + FAIL_LOCK_S
		_fails[address] = fail
		_refuse(from, "code")
		return
	if locked:
		_refuse(from, "locked")
		return
	if peers.size() > MAX_CLIENTS:
		_refuse(from, "full")
		return
	_fails.erase(address)
	var entry := _peer_entry(from, _unique_name(_clean_name(str(msg.get("name", "")), "Guest")), str(msg.get("device", "pc")), str(msg.get("place", "apart")))
	entry.can_edit = edit_all
	entry.color = _free_color()
	entry.seen = _now
	peers[from] = entry
	net.send(from, {"t": "welcome", "v": PROTOCOL, "you": from, "title": session_title, "host": host_name, "doc": doc_name, "room": room_name,
		"can_edit": edit_all, "epoch": space_epoch, "session": session_id})
	say("%s joined." % entry.name)
	_send_roster()
	_announce()
	_nudge_owner(str(entry.name) if entry.place == "together" else "")
	changed.emit()


func _refuse(to: int, reason: String) -> void:
	net.send(to, {"t": "refuse", "reason": reason})
	_kick_later(to)


func _peer_entry(id: int, who: String, device: String, where: String = "apart") -> Dictionary:
	return {"id": id, "name": who, "color": 0, "can_edit": true, "align": "none", "place": where if where in PLACES else "apart",
		"device": device if device in ["quest", "pc"] else "pc", "ready": false, "seen": _now}


## Somebody says they are in the owner's real room and the owner has not lined up with it: the canvases would not be on the same real spot.
func _nudge_owner(who: String) -> void:
	if who != "" and owner_should_align():
		say("%s is in your room. Home > Session > Align with the room, so that you both see the canvases on the same real spot." % who)


## The owner has people in their real room and has not touched the two places that line the headsets up.
func owner_should_align() -> bool:
	if role != Role.HOST or align_mode == "points":
		return false
	for id in peers:
		if id != my_id and str(peers[id].get("place", "apart")) == "together":
			return true
	return false


## Guests in the owner's real room, as names.
func together_names() -> Array:
	var out: Array = []
	for id in peer_ids():
		if id != my_id and str(peers[id].get("place", "apart")) == "together":
			out.append(str(peers[id].name))
	return out


## Something the person should do now (the dock's session button shows it): the owner has people in the room and is not aligned, or a
## guest in the owner's room is not lined up yet.
func needs_attention() -> bool:
	if phase != "live":
		return false
	if role == Role.HOST:
		return owner_should_align()
	return role == Role.CLIENT and place == "together" and (align_mode != "points" or waiting_for_owner())


## The host's own line in the roster says how the host is aligned (guests lined up on points need the owner on the same points).
func _sync_host_entry() -> void:
	if role == Role.HOST and peers.has(my_id):
		peers[my_id].align = align_mode


func _free_color() -> int:
	var used := {}
	for p in peers.values():
		used[int(p.color)] = true
	for i in COLORS.size():
		if not used.has(i):
			return i
	return peers.size() % COLORS.size()


func _unique_name(wanted: String) -> String:
	var taken := {}
	for p in peers.values():
		taken[str(p.name)] = true
	if not taken.has(wanted):
		return wanted
	var k := 2
	while taken.has("%s (%d)" % [wanted, k]):
		k += 1
	return "%s (%d)" % [wanted, k]


static func _clean_name(raw: String, fallback: String) -> String:
	var s := ""
	for i in raw.length():
		var c := raw.unicode_at(i)
		if c >= 32 and c != 127:
			s += raw[i]
	s = s.strip_edges().left(MAX_NAME).strip_edges()
	return s if s != "" else fallback


func _send_roster() -> void:
	if role != Role.HOST:
		return
	_sync_host_entry()
	var list: Array = []
	for id in peer_ids():
		var p: Dictionary = peers[id]
		list.append({"id": id, "name": p.name, "color": p.color, "can_edit": p.can_edit, "align": p.align, "place": p.place, "device": p.device})
	net.send(0, {"t": "roster", "peers": list, "title": session_title, "host": host_name, "doc": doc_name, "room": room_name, "locked": locked,
		"edit_all": edit_all, "canvas_edit": canvas_edit, "epoch": space_epoch})
	if board != null:
		changed.emit()


## The document, a piece at a time, on the data channel: everything the host sends after it builds on it.
func _send_snapshot(to: int) -> void:
	_flush_host()
	var bytes := DocSync.pack(sync.snapshot())
	var n := maxi(ceili(float(bytes.size()) / float(CHUNK)), 1)
	net.send(to, {"t": "snap", "n": n, "size": bytes.size(), "doc": doc_name, "room": room_id}, SessionNet.CH_DATA)
	for i in n:
		net.send(to, {"t": "chunk", "i": i, "d": bytes.slice(i * CHUNK, mini((i + 1) * CHUNK, bytes.size()))}, SessionNet.CH_DATA)
	if peers.has(to):
		peers[to].ready = true


## Pass on what changed on the host (everything dirty), to all headsets that have the document, except `except`.
func _flush_host(except: int = 0) -> void:
	if sync.doc == null or not sync.is_dirty():
		return
	var batch := sync.take_batch()
	if DocSync.is_empty_batch(batch):
		return
	batch["t"] = "ops"
	for id in peers.keys():
		if id != my_id and id != except and bool(peers[id].get("ready", false)):
			net.send(id, batch, SessionNet.CH_DATA)


## A guest's edits: checked against what the guest may do, applied, passed on to the others, and answered.
func _host_ops(from: int, msg: Dictionary) -> void:
	var p: Dictionary = peers.get(from, {})
	if p.is_empty() or not bool(p.get("ready", false)) or sync.doc == null:
		return
	_flush_host()                                 # everything before this goes out first: one order for everybody
	var batch := _batch_of(msg)
	var verdict := _check(batch, p)
	var applied: Dictionary = verdict.ok
	if not DocSync.is_empty_batch(applied):
		sync.apply(applied, true)
		_flush_host(from)
	var state := {}
	var rejected: Array = verdict.rejected
	if not rejected.is_empty():
		state = sync.state_of(rejected)
	net.send(from, {"t": "ack", "seq": int(msg.get("seq", 0)), "state": state, "why": verdict.why}, SessionNet.CH_DATA)


## What a guest may do: {ok: the part of the batch that is allowed, rejected: ids it is not, why: "" | off | locked | canvases}.
func _check(batch: Dictionary, p: Dictionary) -> Dictionary:
	var ok := {"frames": [], "items": [], "gone_frames": [], "gone_items": []}
	var rejected: Array = []
	var why := ""
	if not bool(p.can_edit):
		return {"ok": {}, "rejected": DocSync.ids_of(batch), "why": "off"}
	var doc := sync.doc
	var bad_frames := {}
	for d in batch.frames:
		if not (d is Dictionary):
			continue
		var fid := str((d as Dictionary).get("id", ""))
		var have: FrameData = doc.frames.get(fid)
		if not canvas_edit or have == null or have.locked or not sync.in_scope_frame(fid):
			rejected.append(fid)
			bad_frames[fid] = true
			why = "canvases" if not canvas_edit else "locked"
			continue
		(d as Dictionary)["locked"] = have.locked                     # only the owner locks a canvas
		(d as Dictionary)["room"] = room_id
		ok.frames.append(d)
	for fid in batch.gone_frames:
		var f: FrameData = doc.frames.get(str(fid))
		if not canvas_edit or f == null or f.locked or not sync.in_scope_frame(str(fid)):
			rejected.append(str(fid))
			bad_frames[str(fid)] = true
			why = "canvases" if not canvas_edit else "locked"
			continue
		ok.gone_frames.append(str(fid))
	for d in batch.items:
		if not (d is Dictionary):
			continue
		var iid := str((d as Dictionary).get("id", ""))
		var frame_id := str((d as Dictionary).get("frame", ""))
		var f2: FrameData = doc.frames.get(frame_id)
		var old: Item = doc.items.get(iid)
		var old_frame: FrameData = doc.frames.get(old.frame) if old != null else null
		if f2 == null or f2.locked or bad_frames.has(frame_id) or not sync.in_scope_frame(frame_id) or (old_frame != null and (old_frame.locked or bad_frames.has(old_frame.id))):
			rejected.append(iid)
			why = "locked" if (f2 != null and f2.locked) else (why if why != "" else "locked")
			continue
		ok.items.append(d)
	for iid in batch.gone_items:
		var it: Item = doc.items.get(str(iid))
		var fr: FrameData = doc.frames.get(it.frame) if it != null else null
		if it != null and (fr == null or fr.locked or bad_frames.has(it.frame) or not sync.in_scope_frame(it.frame)):
			rejected.append(str(iid))
			why = "locked"
			continue
		ok.gone_items.append(str(iid))
	return {"ok": ok, "rejected": rejected, "why": why}


## Only the four lists, only as lists: whatever else a message carries is not edits.
static func _batch_of(msg: Dictionary) -> Dictionary:
	var out := {"frames": [], "items": [], "gone_frames": [], "gone_items": []}
	for key in out.keys():
		var v: Variant = msg.get(key, [])
		if v is Array:
			out[key] = v
	return out


# ------------------------------------------------------------------------------------------------ the shared space (host)

## Where the shared room is in P, told to the guests when it changes (the host's anchors settled, the host aligned).
func _host_space() -> void:
	var rw: Variant = board.room_world(room_id)
	if rw == null or not align_known():
		return
	var inv := align_world().affine_inverse()
	var rp: Transform3D = inv * (rw as Transform3D)
	host_head_p = inv * board.head
	if not _space_sent or not SharedSpace.close(rp, room_p) or realign_hint:
		room_p = rp
		_space_sent = true
		realign_hint = false
		_send_space(0)


func _send_space(to: int) -> void:
	if role != Role.HOST:
		return
	if not _space_sent:
		_host_space()
		if not _space_sent:
			return
	net.send(to, {"t": "space", "epoch": space_epoch, "room": room_p, "head": host_head_p})


# ------------------------------------------------------------------------------------------------ guest: messages

func _client_msg(msg: Dictionary) -> void:
	_heard = _now
	match str(msg.t):
		"welcome":
			my_id = int(msg.get("you", net.my_id()))
			session_title = str(msg.get("title", "")).left(MAX_NAME * 2)
			host_name = str(msg.get("host", "")).left(MAX_NAME)
			doc_name = str(msg.get("doc", "")).left(MAX_NAME * 2)
			room_name = str(msg.get("room", "")).left(MAX_NAME)
			space_epoch = int(msg.get("epoch", 1))
			host_session = str(msg.get("session", "")).left(64)
			peers[my_id] = {"id": my_id, "name": my_name, "color": 0, "can_edit": bool(msg.get("can_edit", true)), "align": "none", "place": place,
				"device": "quest" if App.xr_active else "pc"}
			net.send(SessionNet.SERVER, {"t": "ready"})
		"refuse":
			var why := str(msg.get("reason", ""))
			_give_up(str(REFUSALS.get(why, "The session would not take you.")))
		"snap":
			_snap = {"n": clampi(int(msg.get("n", 1)), 1, 100000), "size": int(msg.get("size", 0)), "parts": {}, "have": 0}
		"chunk":
			_on_chunk(msg)
		"space":
			_on_space(msg)
		"pdf", "pdfc", "pdf_no":
			pdf_share.client_msg(msg)
		"mdl", "mdlc", "mdl_no":
			model_share.client_msg(msg)
		"img", "imgc", "img_no", "img_take", "img_have":
			image_share.client_msg(msg)
		"roster":
			_on_roster(msg)
		"ops":
			if phase == "live" and sync.doc != null:
				sync.apply(_without_pending(_batch_of(msg)), false)
		"ack":
			_on_ack(msg)
		"pong":
			rtt_ms = clampi(Time.get_ticks_msec() - int(msg.get("n", 0)), 0, 60000)
		"ended":
			say("The session has ended.")
			leave(true)
		"kicked":
			say("You were removed from the session.")
			leave(true)


func _on_chunk(msg: Dictionary) -> void:
	if _snap.is_empty():
		return
	var d: Variant = msg.get("d")
	var i := int(msg.get("i", -1))
	if not (d is PackedByteArray) or i < 0 or i >= int(_snap.n) or (_snap.parts as Dictionary).has(i):
		return
	_snap.have = int(_snap.have) + (d as PackedByteArray).size()
	if int(_snap.have) > DocSync.MAX_SNAPSHOT:
		_snap = {}
		return
	(_snap.parts as Dictionary)[i] = d
	if (_snap.parts as Dictionary).size() < int(_snap.n):
		return
	var bytes := PackedByteArray()
	for k in int(_snap.n):
		bytes.append_array((_snap.parts as Dictionary)[k])
	_snap = {}
	var d_doc := DocSync.unpack(bytes)
	if d_doc.is_empty() or (d_doc.get("rooms", []) as Array).is_empty():
		_give_up("The session sent something that is not a document.")
		return
	_client_open(d_doc)


func _client_open(d: Dictionary) -> void:
	var doc := Document.from_dict(d)
	doc.transient = true
	doc.id = "session-" + doc.id
	var same_room := client_doc != null and room_id == str(doc.rooms[0].id)      # a reconnect, or the owner shared the same room again
	room_id = str(doc.rooms[0].id)
	room_name = str(doc.rooms[0].name)
	doc_name = doc.name
	if client_doc == null:
		_prev_doc_id = board.doc.id if (board.doc != null and not board.doc.transient) else _prev_doc_id
	sync.attach(doc, room_id)
	client_doc = doc
	_inflight.clear()
	_pending.clear()
	live_out.reset()
	phase = "live"
	pdf_share.reset()
	model_share.reset()
	image_share.reset()
	opening = true
	board.open(doc)
	opening = false
	previews.clear_all()
	pdf_share.client_rescan()
	model_share.client_rescan()
	image_share.client_rescan()
	say("You joined \"%s\"." % session_title)
	if _wanted_here:
		_wanted_here = false
		if not _restore_align():
			if place == "together":
				_start_lining_up()
			elif not (align_mode == "points" and align_epoch == space_epoch):
				use_here()
	elif align_mode == "here" and not same_room:
		use_here()                                     # the owner shared another room: it is put in front of the guest
	_status()
	_save_resume()
	if avatars != null:
		avatars.refresh()
	changed.emit()


func _on_space(msg: Dictionary) -> void:
	var rp: Variant = msg.get("room")
	var hp: Variant = msg.get("head")
	if not (rp is Transform3D) or not (hp is Transform3D):
		return
	var moved := not have_space or not SharedSpace.close(room_p, rp)
	var had_space := have_space
	var old_room := room_p
	room_p = rp
	host_head_p = hp
	var epoch := int(msg.get("epoch", 1))
	have_space = true
	if epoch != space_epoch:
		space_epoch = epoch
		if align_mode == "points" and align_epoch != space_epoch:
			realign_hint = true
			say("The owner aligned again. If you both used the same two points you are fine; if not, align again.")
		elif place == "apart":
			if had_space and align_mode == "here" and align_known():
				_set_align("here", align_world() * old_room * room_p.affine_inverse())    # the owner's space changed under the board: it stays where it is
			else:
				use_here()
	elif moved and align_mode == "none" and place == "apart":
		use_here()
	changed.emit()


func _on_roster(msg: Dictionary) -> void:
	var list: Variant = msg.get("peers", [])
	if not (list is Array):
		return
	var np := {}
	for e in list:
		if e is Dictionary and int(e.get("id", 0)) > 0:
			var id := int(e.id)
			var where := str(e.get("place", "apart"))
			np[id] = {"id": id, "name": str(e.get("name", "")).left(MAX_NAME), "color": clampi(int(e.get("color", 0)), 0, COLORS.size() - 1),
				"can_edit": bool(e.get("can_edit", true)), "align": str(e.get("align", "none")), "place": where if where in PLACES else "apart",
				"device": str(e.get("device", "pc"))}
	if phase == "live":
		for id in np.keys():
			if not peers.has(id) and id != my_id:
				say("%s joined." % str(np[id].name))
		for id in peers.keys():
			if not np.has(id) and id != my_id:
				say("%s left." % str(peers[id].name))
				presence.erase(id)
				previews.clear_peer(id)
	peers = np
	session_title = str(msg.get("title", session_title)).left(MAX_NAME * 2)
	host_name = str(msg.get("host", host_name)).left(MAX_NAME)
	locked = bool(msg.get("locked", false))
	edit_all = bool(msg.get("edit_all", true))
	canvas_edit = bool(msg.get("canvas_edit", false))
	if avatars != null:
		avatars.refresh()
	changed.emit()


# ------------------------------------------------------------------------------------------------ guest: editing

## Send what changed here since last time, and remember that the host has not answered for it yet.
func _flush_client() -> void:
	if sync.doc == null or not sync.is_dirty() or not net.is_connected_to_server():
		return
	var batch := sync.take_batch()
	if DocSync.is_empty_batch(batch):
		return
	_seq += 1
	var ids := DocSync.ids_of(batch)
	_inflight[_seq] = ids
	for id in ids:
		_pending[id] = int(_pending.get(id, 0)) + 1
	batch["t"] = "ops"
	batch["seq"] = _seq
	net.send(SessionNet.SERVER, batch, SessionNet.CH_DATA)


## News from the host about things this guest has changed and not had answered is old news by the host's own order: dropped.
func _without_pending(batch: Dictionary) -> Dictionary:
	if _pending.is_empty():
		return batch
	var out := {"frames": [], "items": [], "gone_frames": [], "gone_items": []}
	for key in ["frames", "items"]:
		for d in batch[key]:
			if d is Dictionary and not _pending.has(str((d as Dictionary).get("id", ""))):
				out[key].append(d)
	for key in ["gone_frames", "gone_items"]:
		for id in batch[key]:
			if not _pending.has(str(id)):
				out[key].append(id)
	return out


func _on_ack(msg: Dictionary) -> void:
	var seq := int(msg.get("seq", 0))
	for id in _inflight.get(seq, []):
		var n := int(_pending.get(id, 0)) - 1
		if n <= 0:
			_pending.erase(id)
		else:
			_pending[id] = n
	_inflight.erase(seq)
	var state: Variant = msg.get("state", {})
	if state is Dictionary and not (state as Dictionary).is_empty() and sync.doc != null:
		sync.apply(_batch_of(state), false)                          # what the host says is true instead of what was tried
		if _now - _told_at > 4.0:
			_told_at = _now
			match str(msg.get("why", "")):
				"off":
					say("The owner has switched editing off.")
				"canvases":
					say("Only the owner can add, remove or move canvases.")
				_:
					say("That canvas is locked by the owner.")


# ------------------------------------------------------------------------------------------------ presence

static func encode_presence(id: int, e: Dictionary) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u32(id)
	var head: Transform3D = e.head
	var q := head.basis.get_rotation_quaternion()
	for v in [head.origin.x, head.origin.y, head.origin.z, q.x, q.y, q.z, q.w]:
		b.put_float(v)
	var tracked := bool(e.tracked)
	b.put_u8((1 if tracked else 0) | (2 if bool(e.down) else 0))
	if tracked:
		var tip: Vector3 = e.tip
		var dir: Vector3 = e.dir
		for v in [tip.x, tip.y, tip.z, dir.x, dir.y, dir.z]:
			b.put_float(v)
		b.put_u8(clampi(int(float(e.pressure) * 255.0), 0, 255))
	return b.data_array


## One presence entry from a buffer: {id, ...} in the shape of encode_presence's input, or {} when it is damaged.
static func decode_presence(b: StreamPeerBuffer) -> Dictionary:
	if b.get_available_bytes() < 4 + 28 + 1:
		return {}
	var id := b.get_u32()
	var f: Array = []
	for i in 7:
		f.append(b.get_float())
	var flags := b.get_u8()
	var tracked := (flags & 1) != 0
	var tip := Vector3.ZERO
	var dir := Vector3.FORWARD
	var pressure := 0.0
	if tracked:
		if b.get_available_bytes() < 25:
			return {}
		var g: Array = []
		for i in 6:
			g.append(b.get_float())
		tip = Vector3(g[0], g[1], g[2])
		dir = Vector3(g[3], g[4], g[5])
		pressure = float(b.get_u8()) / 255.0
	for v in f:
		if is_nan(v) or is_inf(v) or absf(v) > 1.0e5:
			return {}
	var q := Quaternion(f[3], f[4], f[5], f[6])
	if q.length() < 0.5 or tip.length() > 1.0e5 or not is_finite(tip.x + tip.y + tip.z + dir.x + dir.y + dir.z):
		return {}
	return {"id": int(id), "head": Transform3D(Basis(q.normalized()), Vector3(f[0], f[1], f[2])), "tracked": tracked, "tip": tip,
		"dir": dir.normalized() if dir.length() > 0.001 else Vector3.FORWARD, "down": (flags & 2) != 0, "pressure": pressure}


func _on_live(from: int, bytes: PackedByteArray) -> void:
	if bytes.size() < 2 or role == Role.NONE:
		return
	var b := StreamPeerBuffer.new()
	b.data_array = bytes
	var kind := b.get_u8()
	if kind == 0x50 and role == Role.HOST:                     # one guest's pose
		var e := decode_presence(b)
		if not e.is_empty() and int(e.id) == from and peers.has(from):
			e["t"] = _now
			presence[from] = e
			(peers[from] as Dictionary).seen = _now
	elif kind == 0x60 and role == Role.HOST:                 # a guest's stroke, drag or carry in progress: shown here, passed on to the others
		var p: Dictionary = peers.get(from, {})
		if p.is_empty() or not bool(p.get("ready", false)) or not bool(p.get("can_edit", false)):
			return
		var m := _live_message(bytes.slice(1))
		if m.is_empty():
			return
		previews.apply(from, m)
		var relayed := StreamPeerBuffer.new()
		relayed.put_u8(0x61)
		relayed.put_u32(from)
		relayed.put_data(bytes.slice(1))
		net.send_live(-from, relayed.data_array)
	elif kind == 0x61 and role == Role.CLIENT:               # somebody else's, by way of the host
		if bytes.size() < 6 or phase != "live":
			return
		var who := int(b.get_u32())
		if who == my_id or not peers.has(who):
			return
		var m2 := _live_message(bytes.slice(5))
		if not m2.is_empty():
			previews.apply(who, m2)
	elif kind == 0x51 and role == Role.CLIENT:               # everybody's
		var n := b.get_u8()
		for i in n:
			var e2 := decode_presence(b)
			if e2.is_empty():
				return
			if int(e2.id) != my_id and peers.has(int(e2.id)):
				e2["t"] = _now
				presence[int(e2.id)] = e2


func _broadcast_presence() -> void:
	var fresh: Array = []
	for id in presence.keys():
		if _now - float(presence[id].t) < STALE_S:
			fresh.append(id)
	if fresh.size() < 2 or fresh.size() > 255:
		return                                                 # nobody to tell
	var b := PackedByteArray([0x51, fresh.size()])
	for id in fresh:
		b.append_array(encode_presence(int(id), presence[id]))
	net.send_live(0, b)


## What I am in the middle of drawing, dragging or carrying, for the others to see while it happens (the finished edit follows as usual).
func _stream_edits(dt: float) -> void:
	if board.doc == null or not can_edit():
		return
	if board.doc != (client_doc if role == Role.CLIENT else sync.doc):
		return
	for m in live_out.update(dt):
		_send_live_edit(m)


func _send_live_edit(m: Dictionary) -> void:
	var b := StreamPeerBuffer.new()
	if role == Role.CLIENT:
		b.put_u8(0x60)                                        # to the host, who shows it and passes it on
	else:
		b.put_u8(0x61)                                        # from the host: who it is from, then what
		b.put_u32(my_id)
	b.put_data(var_to_bytes(m))
	net.send_live(SessionNet.SERVER if role == Role.CLIENT else 0, b.data_array)


## A live message's content: a dictionary, or {} for anything else.
static func _live_message(payload: PackedByteArray) -> Dictionary:
	if payload.size() < 4 or payload.size() > 262144:
		return {}
	var v: Variant = bytes_to_var(payload)
	return v if v is Dictionary else {}


## What this person is pointing with, in world space: {tracked, tip, dir, down, pressure}. The stylus, else a hand.
func _pointer(pen: PenState, hands: Array) -> Dictionary:
	if pen != null and pen.tracked and pen.source != "none":
		return {"tracked": true, "tip": pen.tip, "dir": pen.dir, "down": pen.down, "pressure": pen.pressure}
	var best: HandInput = null
	for h in hands:
		var hi := h as HandInput
		if hi == null or not hi.tracked:
			continue
		if best == null or (hi.pinching and not best.pinching) or (hi.aiming and not best.aiming and not best.pinching):
			best = hi
	if best == null:
		return {"tracked": false, "tip": Vector3.ZERO, "dir": Vector3.FORWARD, "down": false, "pressure": 0.0}
	var d := best.aim_d if best.aiming else (best.tip - best.knuckle)
	return {"tracked": true, "tip": best.tip, "dir": d.normalized() if d.length() > 0.001 else Vector3.FORWARD, "down": best.pinching,
		"pressure": 1.0 if best.pinching else 0.0}


## The presence of the others, fresh ones only: [{id, name, color, head (P), ...}].
func others() -> Array:
	var out: Array = []
	for id in presence.keys():
		if id == my_id or not peers.has(id) or _now - float(presence[id].t) > STALE_S:
			continue
		var e: Dictionary = (presence[id] as Dictionary).duplicate()
		e["id"] = id
		e["name"] = str(peers[id].name)
		e["color"] = color_of(id)
		e["align"] = str(peers[id].get("align", "none"))
		e["place"] = str(peers[id].get("place", "apart"))
		out.append(e)
	return out


func now() -> float:
	return _now


# ------------------------------------------------------------------------------------------------ the shared space (everyone)

## This headset's F now: the anchor's pose when a spatial anchor holds it (it follows a recentred or relocalised room; the last one is
## kept for a moment it is not tracked), else the transform it was made with. An owner who has not aligned to points uses the shared
## room itself: its anchor keeps it in the real room, so nothing the guests see moves when the owner's tracking space does.
func align_world() -> Transform3D:
	if _align_anchor != "" and board != null and board.anchors != null and board.anchors.has_pose(_align_anchor):
		align_xf = board.anchors.pose(_align_anchor)
		_align_known = true
		return align_xf
	if role == Role.HOST and align_mode == "none" and board != null:
		var rw: Variant = board.room_world(room_id)
		if rw != null:
			align_xf = rw                              # (kept for a moment the room is not found)
	return align_xf


## Is this headset's place for the shared space known? Not while an alignment restored after a restart waits for its anchor.
func align_known() -> bool:
	if not _align_known:
		align_world()
	return _align_known


## Does this headset know where the shared space is, so that what it sends and shows in it is in the right place? The owner always does
## (but for a moment after a restart). A guest in the owner's real room does only when they and the owner have touched the same two places;
## a guest elsewhere, as soon as the board is put in front of them.
func in_shared_space() -> bool:
	if role == Role.HOST:
		return align_known()
	return role == Role.CLIENT and have_space and align_mode != "none" and align_known() and not waiting_for_owner()


## A guest in the owner's real room who is lined up, while the owner is not: their two points mean nothing until the owner touches them too.
func waiting_for_owner() -> bool:
	return role == Role.CLIENT and place == "together" and str((peers.get(HOST_ID, {}) as Dictionary).get("align", "none")) != "points"


## The shared room's origin in this headset's world; null while it is not known (a guest that has not got the room's place yet).
func room_world(rid: String) -> Variant:
	if role != Role.CLIENT or rid != room_id or not in_shared_space():
		return null
	return align_world() * room_p


## A guest: stand the session's board in front of me (the main canvas, facing me); or, with no canvas yet, where the owner stands.
func use_here() -> void:
	if role != Role.CLIENT:
		return
	if not have_space or client_doc == null:
		_wanted_here = true
		return
	_wanted_here = false                               # (done: a later snapshot, such as a reconnect's, does not put it in front again)
	var f: Transform3D
	var main := board.main_canvas(room_id)
	if main != null:
		var pose := room_p * main.xf
		var middle := pose * (Vector3(main.offset.x, main.offset.y, 0.0) * main.scale)
		f = SharedSpace.here(middle, SharedSpace.facing_of(pose), board.head)
	else:
		f = SharedSpace.stand_with(host_head_p, board.head)
	_set_align("here", f)


## A guest says whether they are in the owner's real room ("together": the canvases must stand on the same real spot as the owner's, so
## nothing is shown until both have touched the same two places) or somewhere else ("apart": the board is put in front of them).
## Before and while joining it is what the guest asks to be; the choice is remembered for the next session.
func set_place(where: String) -> void:
	if not where in PLACES:
		return
	App.put("session_place", where)
	if where == place:
		return
	place = where
	if role != Role.CLIENT:
		return                                             # (not in a session: it is what the next one starts as)
	if phase != "live" or client_doc == null:
		return                                             # (still joining: the document's arrival does the rest)
	_align = {}
	if where == "apart":
		_drop_align_anchor()
		align_mode = "none"
		use_here()
	else:
		_start_lining_up()


## A guest in the owner's real room starts with nothing shown (a board anywhere else would not be in the room) and the card for touching
## the two places the owner touches.
func _start_lining_up() -> void:
	_drop_align_anchor()
	align_mode = "none"
	align_xf = Transform3D.IDENTITY
	_align_known = true
	realign_hint = false
	_wanted_here = false
	if avatars != null:
		avatars.refresh()
	_status()
	_save_resume()
	changed.emit()
	align_begin()


func _set_align(mode: String, f: Transform3D) -> void:
	_drop_align_anchor()
	align_mode = mode
	align_xf = f
	_align_known = true
	align_epoch = space_epoch
	realign_hint = false
	place = "together" if mode == "points" else "apart"       # touching the owner's two places means being in the owner's room
	if str(App.val("session_place")) != place:
		App.put("session_place", place)
	if mode != "none" and board.anchors != null and board.anchors.is_supported():
		_align_pending = true
		board.anchors.create(f, "session:align")      # in front of me or on the touched points: either way it stays in the room
	if avatars != null:
		avatars.refresh()
	_status()
	_save_resume()
	changed.emit()


func _drop_align_anchor() -> void:
	if _align_anchor != "" and board != null and board.anchors != null:
		board.anchors.untrack(_align_anchor)
		board.anchors.erase(_align_anchor)
	_align_anchor = ""
	_align_pending = false


func _on_anchor_created(tag: String, uuid: String) -> void:
	if tag.begins_with("copy:"):
		_copy_anchored(tag, uuid)
		return
	if tag != "session:align":
		return
	if not _align_pending or role == Role.NONE:
		board.anchors.erase(uuid)
		return
	_align_pending = false
	_align_anchor = uuid
	_save_resume()


## A guest's saved copy of the session got its room anchor: written into the copy's file.
func _copy_anchored(tag: String, uuid: String) -> void:
	var parts := tag.split(":")
	var d: Document = DocStore.open(parts[1]) if parts.size() >= 3 else null
	if d == null or d.room(parts[2]).is_empty() or (board.doc != null and board.doc.id == d.id):
		board.anchors.erase(uuid)
		return
	d.set_room_field(parts[2], "anchor", uuid)
	d.save()


# ------------------------------------------------------------------------------------------------ surviving a restart

## The session to come back to after the app is restarted (the headset slept, the app was closed, it crashed): saved whenever it
## changes, cleared when it is ended or left on purpose.
func _save_resume() -> void:
	var r := resume_state()
	if not r.is_empty():
		App.put("session_resume", r)


## What is saved to come back to this session after a restart ({} when there is nothing to come back to).
func resume_state() -> Dictionary:
	if role == Role.HOST and phase != "ending":
		return {"role": "host", "session": session_id, "title": session_title, "owner": my_name, "code": code,
			"locked": locked, "edit_all": edit_all, "canvas_edit": canvas_edit, "epoch": space_epoch, "align": align_mode,
			"anchor": _align_anchor if align_mode == "points" else "", "doc": board.doc.id if board.doc != null else "", "room": room_id}
	if role == Role.CLIENT and host_session != "":
		return {"role": "client", "address": _server_address, "port": _server_port, "code": _server_code, "name": my_name,
			"session": host_session, "epoch": align_epoch, "room": room_id, "align": align_mode, "anchor": _align_anchor, "place": place}
	return {}


func _clear_resume() -> void:
	_resume = {}
	if not (App.val("session_resume") as Dictionary).is_empty():
		App.put("session_resume", {})


## At start: go back to the session the app was in when it stopped (owner: start it again once its room is found, with the same code
## and space; guest: join it again, keeping the alignment if the session is still the same). Returns whether there was one.
func resume_saved() -> bool:
	var r: Variant = App.val("session_resume")
	if not (r is Dictionary) or (r as Dictionary).is_empty() or role != Role.NONE:
		return false
	_resume = (r as Dictionary).duplicate()
	_resume_t = 0.0
	if str(_resume.get("role", "")) == "client":
		var was := str(_resume.get("place", "together" if str(_resume.get("align", "")) == "points" else "apart"))
		var err := join(str(_resume.get("address", "")), int(_resume.get("port", PORT)), str(_resume.get("code", "")), str(_resume.get("name", "")), was)
		if err != OK:
			_resume = {}
			return false
		say("Joining the session again...")
	return true


## The room the owner's headset needs to start a session again (after a restart), or "".
func resume_room() -> String:
	return str(_resume.get("room", "")) if str(_resume.get("role", "")) == "host" else ""


## The owner's headset waits for the session's room, then starts the session again as it was.
func _resume_update(delta: float) -> void:
	if str(_resume.get("role", "")) != "host":
		return
	if board.doc == null or board.doc.id != str(_resume.get("doc", "")):
		_clear_resume()                                # another document was opened meanwhile: that session is over
		return
	if board.tracking_live:
		_resume_t += delta
	if board.current_room != str(_resume.get("room", "")) or board.room_state != "found":
		if _resume_t > RESUME_WAIT_S:
			say("The session could not be started again: its room was not found.")
			_clear_resume()
		return
	var r := _resume
	_resume = {}
	if start_hosting(str(r.get("owner", "")), str(r.get("title", "")), str(r.get("code", "")) != "") != OK:
		_clear_resume()
		return
	session_id = str(r.get("session", session_id))
	disco.own_id = session_id
	if str(r.get("code", "")) != "":
		code = str(r.get("code"))
	locked = bool(r.get("locked", false))
	edit_all = bool(r.get("edit_all", true))
	canvas_edit = bool(r.get("canvas_edit", false))
	space_epoch = int(r.get("epoch", 1))
	var a := str(r.get("anchor", ""))
	if str(r.get("align", "")) == "points" and a != "" and board.anchors != null and board.anchors.is_supported():
		align_mode = "points"
		align_epoch = space_epoch
		_align_anchor = a
		_align_known = false                          # the space is not told to anyone until the anchor of the touched points is found
		_align_wait_t = 0.0
		board.anchors.track([a])
	_announce()
	_save_resume()
	say("The session \"%s\" is running again (code %s)." % [session_title, code if code != "" else "none"])
	changed.emit()


## A guest joining again after a restart: the alignment it had is taken back if the session, its space and its room are the same.
func _restore_align() -> bool:
	if str(_resume.get("role", "")) != "client":
		return false
	var r := _resume
	_resume = {}
	var a := str(r.get("anchor", ""))
	var mode := str(r.get("align", "none"))
	if str(r.get("session", "")) != host_session or int(r.get("epoch", -1)) != space_epoch or str(r.get("room", "")) != room_id \
			or a == "" or mode == "none" or board.anchors == null or not board.anchors.is_supported():
		if mode == "points":
			realign_hint = true
			say("The session changed while you were away: align again.")
		return false
	align_mode = mode
	align_epoch = space_epoch
	_align_anchor = a
	_align_known = false
	_align_wait_t = 0.0
	board.anchors.track([a])
	return true


## An alignment restored after a restart whose anchor is not found in time (the Space Setup was reset, another room): the owner goes
## back to the room's own space (guests who aligned by points are asked to align again), a guest gets the board in front of them.
func _align_wait(delta: float) -> void:
	if align_known():
		return
	if board.tracking_live:
		_align_wait_t += delta
	if _align_wait_t < ALIGN_WAIT_S:
		return
	_align_known = true
	_align_anchor = ""
	if role == Role.HOST:
		align_reset()
		say("The two points the session was aligned on were not found: guests who aligned by points should align again.")
	elif place == "together":
		say("Your alignment was not found: touch the owner's two places again.")
		_start_lining_up()
	else:
		align_mode = "none"
		use_here()
		say("Your alignment was not found: the board is put in front of you.")


func _status() -> void:
	if role == Role.CLIENT and phase == "live":
		net.send(SessionNet.SERVER, {"t": "status", "align": align_mode, "place": place})


# ------------------------------------------------------------------------------------------------ the alignment wizard

func aligning() -> bool:
	return not _align.is_empty()


## Start aligning: touch the same two real places as everybody else, in the same order, with the stylus tip or by pinching on them.
func align_begin() -> void:
	if role == Role.NONE or phase != "live":
		return
	board.cancel_place()
	board.surface.cancel()
	_align = {"points": PackedVector3Array(), "press": {"down": false, "acc": PackedVector3Array(), "t": 0.0, "added": false, "src": ""}, "note": ""}
	_was_back = false
	say("Touch the first point with the stylus tip, or pinch on it. Everybody touches the same two places, in the same order.")
	changed.emit()


func align_cancel() -> void:
	if _align.is_empty():
		return
	_align = {}
	changed.emit()


## {aligning, step (0 or 1: which point is next), note}.
func align_status() -> Dictionary:
	if _align.is_empty():
		return {"aligning": false, "step": 0, "note": ""}
	return {"aligning": true, "step": (_align.points as PackedVector3Array).size(), "note": str(_align.note)}


func align_update(pen: PenState, hands: Array, dt: float) -> void:
	if _align.is_empty():
		return
	if pen.back and not _was_back:
		_was_back = true
		align_cancel()
		say("Cancelled.")
		return
	_was_back = pen.back
	# a press: the stylus tip on the place, else the fingers of a hand pinched on it
	var src := ""
	var at := Vector3.ZERO
	if pen.tracked and pen.down:
		src = "pen"
		at = pen.tip
	else:
		for h in hands:
			var hi := h as HandInput
			if hi != null and hi.tracked and hi.pinching:
				src = "hand"
				at = hi.pinch_point
				break
	var pr: Dictionary = _align.press
	if src != "":
		if not bool(pr.down) or str(pr.src) != src:
			pr.down = true
			pr.src = src
			pr.acc = PackedVector3Array()
			pr.t = 0.0
			pr.added = false
		var acc: PackedVector3Array = pr.acc
		acc.append(at)
		pr.acc = acc
		pr.t = float(pr.t) + dt
		if not bool(pr.added) and float(pr.t) >= (TAP_S if src == "pen" else HAND_HOLD_S):
			pr.added = true
			_align_point(_mean(acc), pen)
	else:
		pr.down = false


func _mean(pts: PackedVector3Array) -> Vector3:
	var s := Vector3.ZERO
	for p in pts:
		s += p
	return s / float(maxi(pts.size(), 1))


func _align_point(p: Vector3, pen: PenState) -> void:
	var pts: PackedVector3Array = _align.points
	pen.tick(0.35, 0.02)
	if pts.is_empty():
		pts.append(p)
		_align.points = pts
		_align.note = ""
		say("Now touch the second point, a good way from the first (at least %d cm; further is more exact)." % int(SharedSpace.MIN_SPAN * 100.0))
		changed.emit()
		return
	var r := SharedSpace.from_points(pts[0], p)
	if not bool(r.ok):
		_align.note = "That is only %d cm from the first: touch a point further away." % int(float(r.span) * 100.0)
		say(str(_align.note))
		changed.emit()
		return
	align_span = float(r.span)
	_align = {}
	if role == Role.HOST:
		_drop_align_anchor()
		align_mode = "points"
		align_xf = r.xf
		space_epoch += 1
		align_epoch = space_epoch
		_space_sent = false
		_space_t = SPACE_S
		if board.anchors != null and board.anchors.is_supported():
			_align_pending = true
			board.anchors.create(r.xf, "session:align")
		_align_known = true
		_host_space()                                 # (the new space first, then who is aligned: a guest never sees one without the other)
		_sync_host_entry()
		_send_roster()
		_save_resume()
	else:
		_set_align("points", r.xf)
	align_marks_until = _now + 20.0
	if waiting_for_owner():
		say("Aligned. The canvases appear as soon as the owner has touched the same two places.")
	else:
		say("Aligned: the room is now shared. The two points are marked for a few seconds: check that they sit on the places you touched.")
	if avatars != null:
		avatars.refresh()
	changed.emit()


## The host goes back to showing the room where its own tracking says (guests that aligned to points are told to align again).
func align_reset() -> void:
	if role != Role.HOST or align_mode == "none":
		return
	_drop_align_anchor()
	align_mode = "none"
	align_xf = Transform3D.IDENTITY
	_align_known = true
	space_epoch += 1
	_space_sent = false
	_space_t = SPACE_S
	_host_space()
	_sync_host_entry()
	_send_roster()
	_save_resume()
	changed.emit()


# ------------------------------------------------------------------------------------------------ text for the interface

func phase_text() -> String:
	match phase:
		"connecting":
			return "Connecting to %s..." % _server_address
		"joining":
			return "Joining..."
		"reconnecting":
			return "Connection lost: trying again..."
		"ending":
			return "Ending the session..."
	return ""


## Where this person sees the board, in a sentence.
func align_text() -> String:
	if role == Role.HOST:
		if align_mode == "points":
			return "Aligned to the room: guests in your room touch the same two places."
		var names := together_names()
		if not names.is_empty():
			return "%s in your room: align with the room so that you both see the canvases on the same spot." % ", ".join(names)
		return "Guests elsewhere see the board in front of them."
	if place == "together":
		if align_mode != "points":
			return "Touch the same two places as the owner to see the canvases."
		if waiting_for_owner():
			return "Aligned. The canvases appear when the owner has touched the same two places."
		return "Aligned to the owner's room." if not realign_hint else "The owner aligned again: align again to be sure."
	if align_mode == "here":
		return "You are elsewhere: the board is put in front of you."
	return "Waiting for the board..."


## One person of the roster, in a word: where they are.
static func place_word(p: Dictionary, is_owner: bool) -> String:
	if is_owner:
		return "owner"
	if str(p.get("place", "apart")) == "apart":
		return "elsewhere"
	return "in the room" if str(p.get("align", "none")) == "points" else "aligning"
