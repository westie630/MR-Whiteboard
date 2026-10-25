extends Node
## A session, end to end: an owner's board and two guests' boards in one process, talking over real local connections. Joining (the
## code, the snapshot), editing both ways, what a guest may and may not do, two people editing at once, alignment (two touched points,
## and "here"), presence, leaving, being removed, a dropped connection, and the end of the session.

var t := TestCase.new("session")
var heads: Array = []                      # every headset made, so that one loop advances them all
var toasts: Dictionary = {}                # headset name -> lines


func _ready() -> void:
	App.settings_path = "user://test_settings_session.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_session"
	if DirAccess.dir_exists_absolute(App.docs_dir):
		for f in DirAccess.get_files_at(App.docs_dir):
			DirAccess.remove_absolute(App.docs_dir + "/" + f)
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	App.put("sim_room", "A")
	await run()
	for h in heads:
		(h.board as Board).session.net.close()
	get_tree().quit(t.done())


## A headset: a board with its own simulated anchors, a stylus, and a head, showing a document.
func headset(who: String, doc: Document, tracking: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	var anchors := SimAnchors.new("user://test_sim_anchors_session_%s.json" % who)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_session_%s.json" % who))
	anchors = SimAnchors.new("user://test_sim_anchors_session_%s.json" % who)
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	var head := [Transform3D(Basis.IDENTITY, tracking * Vector3(0, 1.6, 0))]
	board.head_provider = func(): return head[0]
	var h := {"name": who, "board": board, "pen": PenState.new(), "hands": [], "head": head, "anchors": anchors, "space": tracking}
	toasts[who] = []
	board.toast.connect(func(line: String): (toasts[who] as Array).append(line))
	board.open(doc)
	heads.append(h)
	return h


func tick(n: int = 1) -> void:
	for i in n:
		for h in heads:
			(h.board as Board).tick(h.pen, h.hands, 0.016)
		await get_tree().process_frame


func until(cond: Callable, seconds: float = 6.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await tick()
		if cond.call():
			return true
	return false


func settle(seconds: float = 0.5) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await tick()


func sess(h: Dictionary) -> Session:
	return (h.board as Board).session


func doc_of(h: Dictionary) -> Document:
	return (h.board as Board).doc


## Do two documents hold the same shared room? Only the frames of the studio and their items count, and a frame's anchor
## (which belongs to the headset that made it) does not.
func same_content(a: Document, b: Document) -> bool:
	return diff(a, b) == ""


func diff(a: Document, b: Document) -> String:
	var fa := shared_part(a)
	var fb := shared_part(b)
	for kind in ["frames", "items"]:
		var ma: Dictionary = fa[kind]
		var mb: Dictionary = fb[kind]
		if ma.size() != mb.size():
			return "%s: %d against %d" % [kind, ma.size(), mb.size()]
		for id in ma:
			if not mb.has(id):
				return "%s %s missing" % [kind, id]
			if ma[id] != mb[id]:
				return "%s %s differs: %s | %s" % [kind, id, str(ma[id]), str(mb[id])]
	return ""


func shared_part(d: Document) -> Dictionary:
	var frames := {}
	var items := {}
	for id in d.frames:
		var f := d.frames[id] as FrameData
		if f.room != "r_studio" and f.room != "r_geo":
			continue
		var fd := f.to_dict()
		fd.erase("anchor")
		fd.erase("anchor_xf")
		frames[id] = fd
	for id in d.items:
		var it := d.items[id] as Item
		if frames.has(it.frame):
			items[id] = it.to_dict()
	return {"frames": frames, "items": items}


func owner_document() -> Document:
	var doc := Document.create("Floor plan")
	var room := doc.add_room("Studio", "", Transform3D.IDENTITY)
	room.id = "r_studio"
	doc.last_room = "r_studio"
	var other := doc.add_room("Home", "", Transform3D.IDENTITY)
	other.id = "r_home"
	for spec in [["f1", "r_studio", Vector3(0, 1.5, -1.5)], ["f2", "r_studio", Vector3(1.6, 1.5, -1.2)], ["f_home", "r_home", Vector3(0, 1.5, -1)]]:
		var f := FrameData.make(FrameData.CANVAS, spec[1], Transform3D(Basis.IDENTITY, spec[2]))
		f.id = spec[0]
		doc.add_frame(f)
	var stroke := Item.make_stroke("f1", PackedFloat32Array([0, 0, 0, 0.5, 0.1, 0.05, 0, 0.6, 0.2, 0.0, 0, 0.7]), Color("#ffd166"), 0.004, "pen")
	stroke.id = "i_stroke"
	doc.add_item(stroke)
	var rect := Item.make_shape("f1", "rect", Color.WHITE, 0.004)
	rect.id = "i_rect"
	rect.center = Vector2(0.4, 0.3)
	doc.add_item(rect)
	var text := Item.make_text("f1", "Floor plan", Color.WHITE, 0.06)
	text.id = "i_text"
	text.center = Vector2(0.2, 0.6)
	doc.add_item(text)
	var on2 := Item.make_shape("f2", "ellipse", Color.WHITE, 0.004)
	on2.id = "i_on_f2"
	doc.add_item(on2)
	var secret := Item.make_text("f_home", "private", Color.WHITE, 0.05)
	secret.id = "i_private"
	doc.add_item(secret)
	return doc


func own_document(title: String) -> Document:
	var d := DocStore.create_new(title)
	d.add_room("Mine", "", Transform3D.IDENTITY)
	d.save()
	return d


func run() -> void:
	var host_doc := owner_document()
	host_doc.save()
	var H := headset("owner", host_doc)
	var ana_own := own_document("Ana's own")
	var ben_own := own_document("Ben's own")
	var S1 := Transform3D(Basis(Vector3.UP, deg_to_rad(40.0)), Vector3(2.0, 0.0, -1.0))       # physical -> Ana's tracking
	var S2 := Transform3D(Basis(Vector3.UP, deg_to_rad(-75.0)), Vector3(-3.0, 0.0, 2.5))      # physical -> Ben's tracking
	var A := headset("ana", ana_own, S1)
	var B := headset("ben", ben_own, S2)
	await until(func(): return (H.board as Board).current_room != "" and (H.board as Board).room_state == "found")
	t.eq((H.board as Board).current_room, "r_studio", "the owner's board is in its studio")

	# ---- the owner starts a session
	t.eq(sess(H).start_hosting("Lee", "Sprint review", true), OK, "a session starts")
	t.check(sess(H).role == Session.Role.HOST and sess(H).phase == "live", "the owner hosts")
	t.eq(sess(H).code.length(), 4, "with a four-digit code")
	t.check(sess(H).net.port >= Session.PORT, "on a port (%d)" % sess(H).net.port)
	t.check(sess(H).disco.announcing(), "and announces itself on the network")
	t.eq(sess(H).room_id, "r_studio", "the room being shared is the one the owner is in")
	var port: int = sess(H).net.port
	var code: String = sess(H).code

	# ---- a wrong code is turned away
	var bad := "0000" if code != "0000" else "1111"
	t.eq(sess(A).join("127.0.0.1", port, bad, "Ana"), OK, "a guest tries")
	t.check(await until(func(): return sess(A).role == Session.Role.NONE), "the wrong code is refused")
	t.check(sess(A).last_error.contains("code"), "and the guest is told why (%s)" % sess(A).last_error)
	t.eq(doc_of(A).name, "Ana's own", "the guest still has their own document")
	t.eq(sess(H).guest_count(), 0, "nobody joined")

	# ---- the right code
	t.eq(sess(A).join("127.0.0.1", port, code, "Ana"), OK, "joining with the code")
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).doc == sess(A).client_doc and sess(A).client_doc != null), "the guest gets the document")
	await settle(0.4)
	t.eq(sess(H).guest_count(), 1, "the owner sees one guest")
	t.check(sess(A).peers.size() == 2, "and the guest sees who is in the session")
	var ad := doc_of(A)
	t.check(ad.transient, "the guest's copy is a session copy, not one of their documents")
	t.eq(ad.frames.size(), 2, "the studio's two canvases arrive")
	t.check(not ad.frames.has("f_home") and not ad.items.has("i_private"), "the owner's other room stays at home")
	t.eq(ad.items.size(), 4, "with their items")
	for id in ad.items:
		t.eq((ad.items[id] as Item).to_dict(), (doc_of(H).items[id] as Item).to_dict(), "item %s is the owner's" % id)
	t.eq(sess(A).session_title, "Sprint review", "the session has its name")
	t.eq(sess(A).host_name, "Lee", "and its owner")
	t.check((A.board as Board).current_room == "r_studio", "the guest's board is in the session's room")
	await settle(0.3)
	t.eq((A.board as Board).room_state, "found", "and knows where it is (the board is put in front of the guest)")
	t.check(((A.board as Board).frame_nodes["f1"] as FrameNode).visible, "the canvases are shown")
	t.eq(sess(A).align_mode, "here", "a guest starts with the board put in front of them")
	# the board is in front of Ana: the main canvas's middle is HERE_DIST ahead of her head and faces her
	var a_board := A.board as Board
	var main := a_board.main_canvas("r_studio")
	t.check(main != null, "there is a main canvas")
	var middle: Vector3 = (a_board.room_world("r_studio") as Transform3D) * main.xf * Vector3(main.offset.x, main.offset.y, 0.0)
	var ahead := middle - (A.head[0] as Transform3D).origin
	var gaze := SharedSpace.gaze(A.head[0])
	t.near(Vector3(ahead.x, 0, ahead.z).length(), SharedSpace.HERE_DIST, 0.02, "the board is %.1f m in front of the guest" % SharedSpace.HERE_DIST)
	t.check(Vector3(ahead.x, 0, ahead.z).normalized().dot(gaze) > 0.99, "straight ahead")
	var facing := ((a_board.room_world("r_studio") as Transform3D) * main.xf).basis.z
	t.check(Vector3(facing.x, 0, facing.z).normalized().dot(-gaze) > 0.99, "turned towards the guest")

	# ---- a second guest; the roster follows
	t.eq(sess(B).join("127.0.0.1", port, code, "Ana"), OK, "a second guest, with the same name")
	t.check(await until(func(): return sess(B).phase == "live" and (B.board as Board).doc == sess(B).client_doc and sess(B).client_doc != null), "joins")
	await settle(0.3)
	t.eq(sess(H).guest_count(), 2, "two guests")
	var names: Array = []
	for p in sess(H).peers.values():
		names.append(p.name)
	t.check(names.has("Ana") and names.has("Ana (2)"), "two of the same name are told apart (%s)" % str(names))
	var colors := {}
	for p in sess(H).peers.values():
		colors[p.color] = true
	t.eq(colors.size(), 3, "each has a colour of their own")
	t.check(sess(A).peers.size() == 3 and sess(B).peers.size() == 3, "everybody has the same roster")
	var ana_id := sess(A).my_id
	var ben_id := sess(B).my_id
	t.check(ana_id > 1 and ben_id > 1 and ana_id != ben_id, "own ids are known (%d, %d)" % [ana_id, ben_id])
	sess(B).my_name = "Ben"

	# ---- a guest draws: the owner and the other guest get it
	var line := Item.make_stroke("f1", PackedFloat32Array([0.3, 0.3, 0, 0.5, 0.5, 0.35, 0, 0.8]), Color("#ef476f"), 0.004, "pen")
	(A.board as Board).history.do(History.op_add([line]))
	t.check(await until(func(): return doc_of(H).items.has(line.id) and doc_of(B).items.has(line.id)), "a stroke drawn by a guest reaches the owner and the other guest")
	var drawn: Dictionary = (doc_of(A).items[line.id] as Item).to_dict()
	t.eq((doc_of(H).items[line.id] as Item).to_dict(), drawn, "the owner has it as the guest has it (same height in the stack too)")
	t.check(same_content(doc_of(H), doc_of(A)) and same_content(doc_of(A), doc_of(B)), "all three documents agree: %s" % diff(doc_of(H), doc_of(A)))
	t.check(sess(A)._pending.is_empty(), "the guest has no unanswered edits left")
	t.eq(doc_of(H).save(), OK, "the owner's own document is saved as usual")
	t.check(FileAccess.file_exists(App.docs_dir + "/" + doc_of(H).id + ".mrw"), "...in the documents folder")
	t.check(not FileAccess.file_exists(App.docs_dir + "/" + doc_of(A).id + ".mrw"), "and the guest's session copy is not")

	# ---- the owner edits: both guests follow
	var rect: Item = (H.board as Board).doc.items["i_rect"]
	var red := rect.duplicate_item(false)
	red.color = Color("#06d6a0")
	red.center = Vector2(0.6, 0.4)
	(H.board as Board).history.do(History.op_modify([rect], [red]))
	t.check(await until(func(): return (doc_of(A).items["i_rect"] as Item).center.is_equal_approx(Vector2(0.6, 0.4)) and (doc_of(B).items["i_rect"] as Item).center.is_equal_approx(Vector2(0.6, 0.4))), "a change by the owner reaches both guests")
	(H.board as Board).history.do(History.op_remove([doc_of(H).items["i_text"]]))
	t.check(await until(func(): return not doc_of(A).items.has("i_text") and not doc_of(B).items.has("i_text")), "a removal too")
	(H.board as Board).history.undo()
	t.check(await until(func(): return doc_of(A).items.has("i_text") and doc_of(B).items.has("i_text")), "and the owner's undo brings it back for them")

	# ---- canvases belong to the owner unless the owner says otherwise
	var f1: FrameData = doc_of(A).frames["f1"]
	var f1_home := f1.xf
	(A.board as Board).begin_grab(f1)
	t.check(not (A.board as Board).grabs.has("f1"), "a guest cannot pick a canvas up")
	t.check(((toasts["ana"] as Array).any(func(l): return str(l).contains("owner"))), "and is told why")
	var moved := f1.copy()
	moved.xf = Transform3D(Basis(Vector3.UP, 0.7), Vector3(3, 1, -3))
	(A.board as Board).history.do(History.op_frame(f1, moved))                    # a guest's app that does not ask first
	t.check(await until(func(): return (doc_of(A).frames["f1"] as FrameData).xf.origin.is_equal_approx(f1_home.origin)), "a move that gets through is undone when the owner answers")
	t.check((doc_of(H).frames["f1"] as FrameData).xf.origin.is_equal_approx(f1_home.origin), "the owner's canvas never moved")
	sess(H).set_canvas_edit(true)
	await settle(0.4)
	t.check(sess(A).can_edit_canvases(), "the owner allows it")
	(A.board as Board).history.do(History.op_frame(doc_of(A).frames["f1"], moved))
	t.check(await until(func(): return (doc_of(H).frames["f1"] as FrameData).xf.origin.is_equal_approx(Vector3(3, 1, -3)) and (doc_of(B).frames["f1"] as FrameData).xf.origin.is_equal_approx(Vector3(3, 1, -3))), "now a guest's move reaches everybody")
	var back := (doc_of(H).frames["f1"] as FrameData).copy()
	back.xf = f1_home
	(H.board as Board).history.do(History.op_frame(doc_of(H).frames["f1"], back))
	await until(func(): return (doc_of(A).frames["f1"] as FrameData).xf.origin.is_equal_approx(f1_home.origin))
	sess(H).set_canvas_edit(false)

	# ---- two people change the same thing at once: everybody ends with the owner's order
	var shared: Item = doc_of(A).items["i_rect"]
	var ra := shared.duplicate_item(false)
	ra.color = Color("#ff0000")
	var rb := (doc_of(B).items["i_rect"] as Item).duplicate_item(false)
	rb.color = Color("#0000ff")
	(A.board as Board).history.do(History.op_modify([shared], [ra]))
	(B.board as Board).history.do(History.op_modify([doc_of(B).items["i_rect"]], [rb]))
	await settle(1.0)
	var ca := (doc_of(A).items["i_rect"] as Item).color.to_html()
	t.eq((doc_of(H).items["i_rect"] as Item).color.to_html(), ca, "after a clash the owner and the first guest agree...")
	t.eq((doc_of(B).items["i_rect"] as Item).color.to_html(), ca, "...and so does the second")
	t.check(ca == Color("#ff0000").to_html() or ca == Color("#0000ff").to_html(), "one of the two wins, whole")
	t.check(sess(A)._pending.is_empty() and sess(B)._pending.is_empty(), "nothing is left waiting")

	# ---- the owner switches one guest's editing off
	sess(H).set_peer_edit(ana_id, false)
	t.check(await until(func(): return (A.board as Board).history.read_only), "the guest is told: view only")
	t.check(not sess(A).can_edit() and sess(B).can_edit(), "only that guest")
	var before_items := doc_of(H).items.size()
	var nope := Item.make_shape("f1", "rect", Color.WHITE, 0.004)
	(A.board as Board).history.do(History.op_add([nope]))
	await settle(0.4)
	t.check(not doc_of(A).items.has(nope.id) and not doc_of(H).items.has(nope.id), "a view-only guest's edit is not even made")
	# a guest whose app tries anyway
	sess(A).net.send(SessionNet.SERVER, {"t": "ops", "seq": 50, "items": [nope.to_dict()]}, SessionNet.CH_DATA)
	await settle(0.5)
	t.eq(doc_of(H).items.size(), before_items, "and one that is sent anyway is refused by the owner")
	var stylus: PenState = A.pen
	stylus.tracked = true
	stylus.source = "stylus"
	stylus.tip = Vector3(0, 1.4, -0.5)
	stylus.down = false
	await tick(3)
	stylus.down = true
	await tick(3)
	stylus.down = false
	await tick(2)
	t.eq((A.board as Board).pen_ctl.state, PenController.S.IDLE, "the stylus does not start a stroke")
	stylus.tracked = false
	sess(H).set_peer_edit(ana_id, true)
	t.check(await until(func(): return not (A.board as Board).history.read_only), "and it works again when the owner allows it")

	# ---- a canvas the owner locked is the owner's
	(H.board as Board).set_frame_prop("f2", "locked", true)
	t.check(await until(func(): return (doc_of(B).frames["f2"] as FrameData).locked), "the lock reaches the guests")
	var on2: Item = doc_of(B).items["i_on_f2"]
	var on2c := on2.duplicate_item(false)
	on2c.color = Color("#ff00ff")
	(B.board as Board).history.do(History.op_modify([on2], [on2c]))
	t.check(await until(func(): return (doc_of(B).items["i_on_f2"] as Item).color.to_html() == (doc_of(H).items["i_on_f2"] as Item).color.to_html()), "an edit on a locked canvas is taken back")
	t.check((doc_of(H).items["i_on_f2"] as Item).color.to_html() != Color("#ff00ff").to_html(), "and never reached the owner")
	sess(H).set_canvas_edit(true)
	await settle(0.3)
	var unlock := (doc_of(B).frames["f2"] as FrameData).copy()
	unlock.locked = false
	(B.board as Board).history.do(History.op_frame(doc_of(B).frames["f2"], unlock))
	await settle(0.6)
	t.check((doc_of(H).frames["f2"] as FrameData).locked and (doc_of(B).frames["f2"] as FrameData).locked, "a guest cannot unlock it, even with canvases open")
	sess(H).set_canvas_edit(false)
	(H.board as Board).set_frame_prop("f2", "locked", false)
	await settle(0.4)

	# ---- where everybody is
	var ap: PenState = A.pen
	ap.tracked = true
	ap.source = "stylus"
	ap.tip = (A.space as Transform3D) * Vector3(0.5, 1.3, -1.2)
	ap.dir = ((A.space as Transform3D).basis * Vector3(0, 0, -1)).normalized()
	ap.down = true
	ap.pressure = 0.4
	await settle(0.5)
	ap.down = false
	t.check(sess(H).presence.has(ana_id), "the owner knows where the first guest's stylus is")
	t.check(sess(B).presence.has(ana_id) and sess(B).presence.has(1), "so does the other guest, and where the owner is")
	var others_b := sess(B).others()
	var names_b: Array = []
	for o in others_b:
		names_b.append(o.name)
	t.check(names_b.has("Lee") and names_b.has("Ana"), "the others are named (%s)" % str(names_b))
	var seen_tip: Vector3 = (sess(H).presence[ana_id].tip as Vector3)
	# Ana's stylus is at physical (0.5,1.3,-1.2) only if all three share the physical room; here (not aligned) the owner sees it in the shared space
	var inv_a := sess(A).align_world().affine_inverse()
	t.check(seen_tip.distance_to(inv_a * ap.tip) < 0.002, "the tip arrives where Ana's own alignment puts it in the shared space")
	t.check(bool(sess(H).presence[ana_id].tracked), "tracked")
	await settle(0.3)
	var av: PeerAvatars = sess(B).avatars
	t.check(av != null and av.get_child_count() >= 3, "avatars are drawn for the others")
	ap.tracked = false

	# ---- two touched points line the headsets up on the real room
	# the real room: the owner's tracking space IS the physical frame; Ana's and Ben's are S1 and S2 of it
	var pa := Vector3(1.0, 0.75, -1.0)
	var pb := Vector3(2.6, 0.75, -1.3)
	sess(H).align_begin()
	t.check(sess(H).aligning(), "the owner starts aligning")
	await touch(H, pa)
	t.check(sess(H).aligning() and sess(H).align_status().step == 1, "the first point is in")
	await touch(H, pa + Vector3(0.1, 0, 0.1))
	t.check(sess(H).aligning(), "a second point too close to the first is not taken")
	t.check(str(sess(H).align_status().note).contains("further"), "and the owner is told")
	await touch(H, pb)
	t.check(not sess(H).aligning() and sess(H).align_mode == "points", "two points: the owner is aligned")
	t.eq(sess(H).space_epoch, 2, "a new shared space for the session")
	await settle(0.8)
	t.check(sess(A).space_epoch == 2 and sess(B).space_epoch == 2, "the guests are told")
	t.eq(sess(A).align_mode, "here", "a guest who was not aligned stays put, with the board still in front of them")
	sess(A).align_begin()
	await touch(A, S1 * pa)
	await touch(A, S1 * pb)
	t.check(sess(A).align_mode == "points", "Ana aligned")
	t.eq(sess(A).align_epoch, 2, "to the owner's space")
	sess(B).align_begin()
	await pinch(B, S2 * pa)
	t.check(sess(B).aligning() and sess(B).align_status().step == 1, "Ben, who has no stylus, marks the first point with a pinch")
	await pinch(B, S2 * pb)
	t.check(sess(B).align_mode == "points", "Ben aligned with two pinches")
	t.check(not (B.board as Board).pen_ctl.state != PenController.S.IDLE, "(and drew nothing while aligning)")
	await settle(0.8)
	t.check(sess(H).peers[ana_id].align == "points" and sess(H).peers[ben_id].align == "points" and sess(H).peers[1].align == "points", "the roster says who is aligned")
	# every canvas is where it really is, for everybody
	for fid in ["f1", "f2"]:
		var in_h: Transform3D = ((H.board as Board).frame_nodes[fid] as FrameNode).global_transform
		var in_a: Transform3D = ((A.board as Board).frame_nodes[fid] as FrameNode).global_transform
		var in_b: Transform3D = ((B.board as Board).frame_nodes[fid] as FrameNode).global_transform
		var want_a: Transform3D = S1 * in_h
		var want_b: Transform3D = S2 * in_h
		t.check(in_a.origin.distance_to(want_a.origin) < 0.002 and in_a.basis.get_rotation_quaternion().angle_to(want_a.basis.get_rotation_quaternion()) < 0.002, "canvas %s stands on the same real place for Ana (off by %.4f m)" % [fid, in_a.origin.distance_to(want_a.origin)])
		t.check(in_b.origin.distance_to(want_b.origin) < 0.002 and in_b.basis.get_rotation_quaternion().angle_to(want_b.basis.get_rotation_quaternion()) < 0.002, "...and for Ben (off by %.4f m)" % in_b.origin.distance_to(want_b.origin))
	# somebody with no stylus points with a finger: the others see the fingertip, and a pinch as a press
	var ben_hand := HandInput.new()
	ben_hand.side = "right"
	ben_hand.tracked = true
	ben_hand.tip = S2 * Vector3(0.0, 1.2, -1.6)
	ben_hand.knuckle = ben_hand.tip + (S2.basis * Vector3(0.0, 0.0, 0.05))
	ben_hand.aiming = true
	ben_hand.aim_o = ben_hand.knuckle
	ben_hand.aim_d = (S2.basis * Vector3(0.0, 0.0, -1.0)).normalized()
	ben_hand.pinching = false
	B.hands = [ben_hand]
	await settle(0.6)
	var finger: Dictionary = sess(H).presence.get(ben_id, {})
	t.check(not finger.is_empty() and bool(finger.tracked), "the owner sees a guest's fingertip when there is no stylus")
	t.check(not bool(finger.get("down", true)), "open fingers: not pressing")
	var finger_for_owner: Vector3 = sess(H).align_world() * (finger.tip as Vector3)
	t.check(finger_for_owner.distance_to(Vector3(0.0, 1.2, -1.6)) < 0.003, "on the real spot (off by %.4f m)" % finger_for_owner.distance_to(Vector3(0.0, 1.2, -1.6)))
	ben_hand.pinching = true
	await settle(0.5)
	t.check(bool(sess(H).presence[ben_id].down), "a pinch shows as pressed")
	B.hands = []
	# somebody points at a real thing: everybody else sees the stylus there
	var real_spot := Vector3(0.2, 1.1, -2.0)
	ap.tracked = true
	ap.source = "stylus"
	ap.tip = S1 * real_spot
	ap.dir = (S1.basis * Vector3(0, 0, -1)).normalized()
	await settle(0.6)
	var tip_for_owner: Vector3 = sess(H).align_world() * (sess(H).presence[ana_id].tip as Vector3)
	var tip_for_ben: Vector3 = sess(B).align_world() * (sess(B).presence[ana_id].tip as Vector3)
	t.check(tip_for_owner.distance_to(real_spot) < 0.003, "the owner sees Ana's stylus on the real spot (off by %.4f m)" % tip_for_owner.distance_to(real_spot))
	t.check(tip_for_ben.distance_to(S2 * real_spot) < 0.003, "and Ben sees it on the same real spot (off by %.4f m)" % tip_for_ben.distance_to(S2 * real_spot))
	ap.tracked = false
	# a draw in one headset lands on the same real place in the other (the canvas coordinates are shared)
	var stroke_a := Item.make_stroke("f2", PackedFloat32Array([0.0, 0.0, 0, 0.5, 0.2, 0.0, 0, 0.5]), Color.WHITE, 0.004, "pen")
	(A.board as Board).history.do(History.op_add([stroke_a]))
	await until(func(): return doc_of(B).items.has(stroke_a.id))
	t.check(doc_of(B).items.has(stroke_a.id), "and what Ana draws is on Ben's canvas")
	# the owner aligns again: those who aligned by points are warned
	sess(H).align_begin()
	await touch(H, pa)
	await touch(H, pb)
	await settle(0.8)
	t.eq(sess(H).space_epoch, 3, "a third shared space")
	t.check(sess(A).realign_hint and sess(B).realign_hint, "guests aligned on the old one are asked to check")
	await touch_pair(A, S1 * pa, S1 * pb)
	t.check(not sess(A).realign_hint and sess(A).align_epoch == 3, "aligning again clears the hint")
	sess(H).align_reset()
	await settle(0.6)
	t.eq(sess(H).align_mode, "none", "the owner can go back to showing the room where it is")
	t.check(sess(H).space_epoch == 4, "(which is another shared space)")
	await settle(0.4)
	sess(A).use_here()
	sess(B).use_here()

	# ---- the owner opens another document: the session follows
	var second := Document.create("Geometry")
	var room2 := second.add_room("Studio", "", Transform3D.IDENTITY)
	room2.id = "r_geo"
	var gf := FrameData.make(FrameData.CANVAS, "r_geo", Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -1.5)))
	gf.id = "g1"
	second.add_frame(gf)
	var gi := Item.make_text("g1", "Triangles", Color.WHITE, 0.07)
	gi.id = "g_text"
	second.add_item(gi)
	second.save()
	(H.board as Board).open(second)
	t.check(await until(func(): return doc_of(A).items.has("g_text") and doc_of(B).items.has("g_text"), 8.0), "the guests get the owner's new document")
	t.check(not doc_of(A).items.has("i_rect") and sess(A).doc_name == "Geometry", "and not the old one")
	t.eq(sess(A).phase, "live", "still in the session")
	(H.board as Board).open(host_doc)
	t.check(await until(func(): return doc_of(A).items.has("i_rect") and not doc_of(A).items.has("g_text"), 8.0), "and back")
	await settle(0.5)

	# ---- leaving
	sess(B).leave()
	t.eq(sess(B).role, Session.Role.NONE, "a guest leaves")
	t.eq(doc_of(B).name, "Ben's own", "and has their own document back")
	t.check(not doc_of(B).transient, "which is not a session copy")
	t.check(await until(func(): return sess(H).guest_count() == 1), "the owner sees them go")
	t.check(not sess(H).presence.has(ben_id), "and their pose is forgotten")
	t.check(sess(A).peers.size() == 2, "the other guest sees the roster shrink")
	t.eq((B.board as Board).history.read_only, false, "and can edit their own document")

	# ---- removed by the owner
	sess(H).kick(ana_id)
	t.check(await until(func(): return sess(A).role == Session.Role.NONE), "a guest the owner removes is out")
	t.eq(doc_of(A).name, "Ana's own", "with their own document")
	t.check(sess(H).guest_count() == 0, "and off the roster")

	# ---- a closed session
	sess(H).set_locked(true)
	await settle(0.4)
	sess(B).join("127.0.0.1", port, code, "Ben")
	t.check(await until(func(): return sess(B).role == Session.Role.NONE and sess(B).last_error != ""), "nobody can join a closed session")
	t.check(sess(B).last_error.contains("closed"), "(%s)" % sess(B).last_error)
	sess(H).set_locked(false)
	await settle(0.3)

	# ---- a connection that drops comes back
	sess(B).retry_s = 0.3
	sess(B).join("127.0.0.1", port, code, "Ben")
	t.check(await until(func(): return sess(B).phase == "live" and sess(B).client_doc != null), "joins again")
	var ben_id2 := sess(B).my_id
	await settle(0.4)
	sess(H).net.kick(ben_id2)                                # the network, not the owner, ends it
	t.check(await until(func(): return sess(B).phase == "reconnecting", 3.0), "a dropped guest knows the link is gone")
	t.check(doc_of(B) == sess(B).client_doc, "and keeps what they see meanwhile")
	t.check(await until(func(): return sess(B).phase == "live" and sess(B).my_id != ben_id2, 10.0), "and is back in the session on its own")
	await settle(0.5)
	t.check(same_content(doc_of(H), doc_of(B)), "with everything the owner has: %s" % diff(doc_of(H), doc_of(B)))
	t.eq(sess(H).guest_count(), 1, "(once, not twice)")

	# ---- the end of the session
	sess(H).end()
	t.check(await until(func(): return sess(B).role == Session.Role.NONE and sess(H).role == Session.Role.NONE, 6.0), "the owner ends the session: everybody is out")
	t.eq(doc_of(B).name, "Ben's own", "guests are back on their own documents")
	t.eq(doc_of(H).name, "Floor plan", "the owner on theirs")
	t.check(doc_of(H).items.has(line.id), "with what the guests drew in it")
	t.check(not sess(H).net.is_open(), "the connection is closed")
	var listed: Array = []
	for d in DocStore.list():
		listed.append(str(d.name))
	t.check(not (listed.any(func(n): return str(n).begins_with("session-"))), "no guest's documents folder gained a session copy (%s)" % str(listed))


## Press the stylus on a point for a moment, then lift it.
func touch(h: Dictionary, p: Vector3) -> void:
	var pen: PenState = h.pen
	pen.tracked = true
	pen.source = "stylus"
	pen.tip = p
	pen.down = true
	pen.contact = true
	pen.pressure = 0.5
	await tick(14)
	pen.down = false
	pen.contact = false
	pen.pressure = 0.0
	await tick(3)
	pen.tracked = false


## The same with no stylus: the fingers pinch on a point for a moment.
func pinch(h: Dictionary, p: Vector3) -> void:
	var hand := HandInput.new()
	hand.side = "right"
	hand.tracked = true
	hand.pinching = true
	hand.pinch_point = p
	hand.tip = p
	h.hands = [hand]
	await tick(40)
	hand.pinching = false
	await tick(3)
	h.hands = []


func touch_pair(h: Dictionary, a: Vector3, b: Vector3) -> void:
	sess(h).align_begin()
	await touch(h, a)
	await touch(h, b)
	await settle(0.5)
