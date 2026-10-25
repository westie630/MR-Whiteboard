extends Node
## In a session, the board stays where each person has it: the owner recentring moves nobody's board; a guest recentring or taking the
## headset off keeps theirs in their room; a dropped connection keeps the alignment; a guest's app restarted joins again with the
## same alignment; the owner's app restarted starts the session again (same code, same space) and the guests come back to it with
## nothing moved, also after the owner aligned to two points; a guest's saved copy opens where the session was. Two headsets in one
## process over real local connections, their anchors simulated; "restarting" a headset is a new board with the same files.

const DT := 0.016

var t := TestCase.new("session_places")
var heads: Array = []


func _ready() -> void:
	App.settings_path = "user://test_settings_session_places.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_session_places"
	if DirAccess.dir_exists_absolute(App.docs_dir):
		for f in DirAccess.get_files_at(App.docs_dir):
			DirAccess.remove_absolute(App.docs_dir + "/" + f)
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	App.put("sim_room", "A")
	App.put("session_resume", {})
	for who in ["owner", "ana"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sim_path(who)))
	await run()
	for h in heads:
		if is_instance_valid(h.board):
			(h.board as Board).session.net.close()
	get_tree().quit(t.done())


func sim_path(who: String) -> String:
	return "user://test_sim_anchors_class_%s.json" % who


## A headset (started, or started again): a board with its own simulated anchors (`shift`: where the real room is in its tracking
## space), showing `doc`.
func headset(who: String, doc: Document, shift: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	var anchors := SimAnchors.new(sim_path(who))
	anchors.shift = shift
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	var head := [shift * Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))]
	board.head_provider = func(): return head[0]
	board.open(doc)
	var h := {"name": who, "board": board, "pen": PenState.new(), "hands": [], "head": head, "anchors": anchors}
	heads.append(h)
	return h


## The app is closed (or killed): nothing is ended or left on purpose.
func kill(h: Dictionary) -> void:
	heads.erase(h)
	(h.board as Board).flush_save()
	(h.board as Board).session.net.close()
	(h.board as Node).free()
	(h.anchors as Node).free()
	await get_tree().process_frame


func tick(n: int = 1) -> void:
	for i in n:
		for h in heads:
			(h.board as Board).tick(h.pen, h.hands, DT)
		await get_tree().process_frame


func until(cond: Callable, seconds: float = 8.0) -> bool:
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


func poses(h: Dictionary) -> Dictionary:
	var out := {}
	var b := h.board as Board
	for id in b.frame_nodes:
		if (b.frame_nodes[id] as FrameNode).visible:
			out[id] = (b.frame_nodes[id] as FrameNode).global_transform
	return out


func all_at(h: Dictionary, want: Dictionary, shift: Transform3D, what: String, tol: float = 0.003) -> void:
	var now := poses(h)
	t.check(not want.is_empty(), "%s: (there is something to compare)" % what)
	for id in want:
		var w: Transform3D = shift * (want[id] as Transform3D)
		var ok: bool = now.has(id) and (now[id] as Transform3D).origin.distance_to(w.origin) < tol and ((now[id] as Transform3D).basis.z - w.basis.z).length() < tol * 2.0
		t.check(ok, "%s: canvas %s is where it was%s" % [what, id, "" if ok else " (now %s, want %s)" % [str((now.get(id, Transform3D()) as Transform3D).origin) if now.has(id) else "hidden", str(w.origin)]])


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


func owner_document() -> Document:
	var doc := Document.create("Places")
	var room := doc.add_room("Studio", "", Transform3D.IDENTITY)
	room.id = "r_studio"
	doc.last_room = "r_studio"
	for spec in [["f1", Vector3(0, 1.5, -1.5)], ["f2", Vector3(1.6, 1.5, -1.2)]]:
		var f := FrameData.make(FrameData.CANVAS, "r_studio", Transform3D(Basis(Vector3.UP, 0.2), spec[1]))
		f.id = spec[0]
		doc.add_frame(f)
	doc.save(DocStore.path_for(doc.id))
	return doc


func run() -> void:
	var host_doc := owner_document()
	var ana_own := DocStore.create_new("Ana's own")
	var T1 := Transform3D(Basis(Vector3.UP, deg_to_rad(20.0)), Vector3(0.5, 0.0, 0.3))
	var S1 := Transform3D(Basis(Vector3.UP, deg_to_rad(40.0)), Vector3(2.0, 0.0, -1.0))
	var H := headset("owner", host_doc, T1)
	var A := headset("ana", ana_own, S1)
	t.check(await until(func(): return (H.board as Board).room_state == "found" and (A.board as Board).room_state == "found"), "both boards are in their rooms")
	await settle(1.0)                                  # the owner's canvases get their anchors
	t.eq(sess(H).start_hosting("Ms Park", "Places", true), OK, "a session starts")
	var host_resume: Dictionary = sess(H).resume_state()
	t.eq(str(host_resume.get("role", "")), "host", "the owner's headset remembers the session")
	var code := sess(H).code
	var port := sess(H).net.port
	t.eq(sess(A).join("127.0.0.1", port, code, "Ana"), OK, "Ana joins")
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).room_state == "found"), "Ana sees the board")
	await settle(0.6)
	t.eq(sess(A).align_mode, "here", "the board is put in front of her")
	t.check(sess(A)._align_anchor != "", "and that place is held by an anchor in her room")
	var ana_resume: Dictionary = sess(A).resume_state()
	t.check(str(ana_resume.get("role", "")) == "client" and str(ana_resume.get("anchor", "")) != "", "Ana's headset remembers the session and her alignment")
	var pa0 := poses(A)
	t.eq(pa0.size(), 2, "both canvases are shown to Ana")

	# ---- the owner recentres: nothing moves for Ana
	var T2 := Transform3D(Basis(Vector3.UP, deg_to_rad(-55.0)), Vector3(-1.5, 0.0, 2.0))
	(H.anchors as SimAnchors).shift = T2
	(H.board as Board).tracking_reset()
	await settle(0.8)
	all_at(A, pa0, Transform3D.IDENTITY, "the owner recentred")

	# ---- Ana recentres (or takes the headset off and on): the board stays in her room
	var D := Transform3D(Basis(Vector3.UP, deg_to_rad(75.0)), Vector3(1.0, 0.0, 1.0))    # how her tracking space moved
	var S2 := D * S1
	(A.anchors as SimAnchors).shift = S2
	(A.board as Board).tracking_reset()
	await settle(0.3)
	all_at(A, pa0, D, "Ana recentred")

	# ---- the connection drops and comes back: her alignment is kept
	sess(A).retry_s = 0.3
	sess(A)._lost()
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).room_state == "found", 10.0), "Ana is back in the session")
	await settle(0.4)
	t.eq(sess(A).align_mode, "here", "still aligned")
	all_at(A, pa0, D, "reconnected")

	# ---- Ana's app is restarted: it joins again with the same alignment
	ana_resume = sess(A).resume_state()
	await kill(A)
	await settle(0.3)
	App.put("session_resume", ana_resume)
	A = headset("ana", DocStore.open(ana_own.id), S2)
	t.check(sess(A).resume_saved(), "Ana's restarted app goes back to the session")
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).room_state == "found", 10.0), "and is in it")
	await settle(0.4)
	t.eq(sess(A).align_mode, "here", "with her alignment")
	all_at(A, pa0, D, "Ana's app restarted")

	# ---- the owner's app is restarted: the session starts again, Ana comes back to it, nothing moved
	sess(A).retry_s = 0.3
	await kill(H)
	t.check(await until(func(): return sess(A).phase == "reconnecting", 4.0), "Ana notices the session is gone")
	App.put("session_resume", host_resume)
	var T3 := Transform3D(Basis(Vector3.UP, deg_to_rad(100.0)), Vector3(0.0, 0.0, -3.0))
	H = headset("owner", DocStore.open(host_doc.id), T3)
	t.check(sess(H).resume_saved(), "the owner's restarted app goes back to the session")
	t.check(await until(func(): return sess(H).role == Session.Role.HOST), "and starts it again once its room is found")
	t.eq(sess(H).code, code, "with the same code")
	t.eq(sess(H).session_id, str(host_resume.session), "as the same session")
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).room_state == "found", 12.0), "Ana is back in the session")
	await settle(0.5)
	t.eq(sess(A).align_mode, "here", "still aligned")
	all_at(A, pa0, D, "the owner's app restarted")

	# ---- the owner aligns to two points; restarted again, the session's space is the same
	var p1 := Vector3(-0.8, 0.9, -1.0)
	var p2 := Vector3(0.9, 0.9, -1.3)
	sess(H).align_begin()
	await touch(H, T3 * p1)
	await touch(H, T3 * p2)
	await settle(0.6)
	t.eq(sess(H).align_mode, "points", "the owner aligned to two points")
	await settle(0.6)
	var pa1 := poses(A)
	var room_p1 := sess(A).room_p
	host_resume = sess(H).resume_state()
	t.check(str(host_resume.get("anchor", "")) != "", "the owner's headset remembers the anchor of the two points")
	await kill(H)
	await until(func(): return sess(A).phase == "reconnecting", 4.0)
	App.put("session_resume", host_resume)
	var T4 := Transform3D(Basis(Vector3.UP, deg_to_rad(-140.0)), Vector3(2.0, 0.0, 1.0))
	H = headset("owner", DocStore.open(host_doc.id), T4)
	sess(H).resume_saved()
	t.check(await until(func(): return sess(H).role == Session.Role.HOST and sess(H).align_known(), 10.0), "the session starts again, aligned to the same two points")
	t.eq(sess(H).align_mode, "points", "(by points)")
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).room_state == "found", 12.0), "Ana is back")
	await settle(0.6)
	t.check(SharedSpace.close(sess(A).room_p, room_p1, 0.003, 0.3), "the session's space is unchanged")
	all_at(A, pa1, Transform3D.IDENTITY, "restarted after aligning to points")

	# ---- both apps restarted at once (a power cut): Ana's starts first and keeps trying until the session is back
	var ana_r := sess(A).resume_state()
	host_resume = sess(H).resume_state()
	var shift_a: Transform3D = (A.anchors as SimAnchors).shift
	await kill(A)
	await kill(H)
	App.put("session_resume", ana_r)
	A = headset("ana", DocStore.open(ana_own.id), shift_a)
	sess(A).retry_s = 0.3
	t.check(sess(A).resume_saved(), "Ana's app goes back to the session")
	await settle(1.5)
	t.check(sess(A).role == Session.Role.CLIENT, "the session is not there yet: Ana's headset keeps trying (%s)" % sess(A).phase)
	App.put("session_resume", host_resume)
	H = headset("owner", DocStore.open(host_doc.id), T4)
	sess(H).resume_saved()
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).room_state == "found", 15.0), "the owner's session comes back and Ana is in it")
	await settle(0.6)
	all_at(A, pa1, Transform3D.IDENTITY, "both apps restarted")

	# ---- Ana keeps a copy: it opens later where the session was
	var copy_name := sess(A).save_copy()
	await settle(0.3)
	var copy_id := ""
	for e in DocStore.list():
		if str(e.name) == copy_name:
			copy_id = str(e.id)
	var copy := DocStore.open(copy_id)
	t.check(copy != null, "Ana's copy is saved")
	if copy == null:
		return
	var ra := str(copy.rooms[0].anchor)
	t.check(ra != "" and (A.anchors as SimAnchors).is_stored(ra), "it has a room anchor of its own, made on her headset")
	t.check(copy.frames.values().all(func(f): return (f as FrameData).anchor == ""), "and none of the owner's anchors")
	var pa2 := poses(A)
	sess(A).leave(true, false)
	(A.board as Board).open(copy)
	t.check(await until(func(): return (A.board as Board).room_state == "found"), "the copy opens in its room")
	await settle(0.3)
	all_at(A, pa2, Transform3D.IDENTITY, "Ana's copy", 0.004)
	t.check((App.val("session_resume") as Dictionary).is_empty(), "having left on purpose, Ana's headset does not go back to the session")
