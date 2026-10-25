extends Node
## The two ways to be in a session. TOGETHER (in the owner's real room): nothing is shown until the guest and the owner have touched the
## same two places, and then every canvas stands on the same real spot for both; people in the room are drawn as people (tag and pointer),
## not as orbs. APART (somewhere else): the board is put in front of the guest at once, whatever the owner does about the room, and what is
## on it is the same. Both in one session, switching between them, the owner aligning and going back, and what a guest can not fake.
## An owner and three guests as four real boards in one process over real local connections; their tracking spaces differ.

var t := TestCase.new("session_modes")
var heads: Array = []
var toasts: Dictionary = {}


func _ready() -> void:
	App.settings_path = "user://test_settings_session_modes.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_session_modes"
	if DirAccess.dir_exists_absolute(App.docs_dir):
		for f in DirAccess.get_files_at(App.docs_dir):
			DirAccess.remove_absolute(App.docs_dir + "/" + f)
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	App.put("sim_room", "A")
	App.put("session_resume", {})
	App.put("session_place", "apart")
	await run()
	for h in heads:
		(h.board as Board).session.net.close()
	get_tree().quit(t.done())


func headset(who: String, doc: Document, tracking: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	var path := "user://test_sim_anchors_modes_%s.json" % who
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var anchors := SimAnchors.new(path)
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


func owner_document() -> Document:
	var doc := Document.create("Floor plan")
	var room := doc.add_room("Studio", "", Transform3D.IDENTITY)
	room.id = "r_studio"
	doc.last_room = "r_studio"
	for spec in [["f1", Vector3(0, 1.5, -1.5)], ["f2", Vector3(1.6, 1.5, -1.2)]]:
		var f := FrameData.make(FrameData.CANVAS, "r_studio", Transform3D(Basis.IDENTITY, spec[1]))
		f.id = spec[0]
		doc.add_frame(f)
	var rect := Item.make_shape("f1", "rect", Color.WHITE, 0.004)
	rect.id = "i_rect"
	doc.add_item(rect)
	return doc


func own_document(title: String) -> Document:
	var d := DocStore.create_new(title)
	d.add_room("Mine", "", Transform3D.IDENTITY)
	d.save()
	return d


func shown(h: Dictionary, fid: String) -> bool:
	var fn: FrameNode = (h.board as Board).frame_nodes.get(fid)
	return fn != null and fn.visible


## Every canvas of `h` is where the owner's is in the real room (`space`: the real room as this headset's tracking space sees it).
func on_the_real_spot(h: Dictionary, owner: Dictionary, what: String) -> void:
	for fid in ["f1", "f2"]:
		var in_o: Transform3D = ((owner.board as Board).frame_nodes[fid] as FrameNode).global_transform
		var in_h: Transform3D = ((h.board as Board).frame_nodes[fid] as FrameNode).global_transform
		var want: Transform3D = (h.space as Transform3D) * in_o
		var off := in_h.origin.distance_to(want.origin)
		t.check(shown(h, fid) and off < 0.002 and in_h.basis.get_rotation_quaternion().angle_to(want.basis.get_rotation_quaternion()) < 0.002,
			"%s: canvas %s stands on the same real spot as the owner's (off by %.4f m)" % [what, fid, off])


## Is `who` drawn in `viewer`'s headset as an orb with a gaze (somebody elsewhere) and not as a person in the room?
func orb_of(viewer: Dictionary, who: Dictionary) -> bool:
	var av: PeerAvatars = sess(viewer).avatars
	var a: PeerAvatars.Avatar = av._avatars.get(sess(who).my_id)
	return a != null and a.visible and a.orb.visible


func person_of(viewer: Dictionary, who: Dictionary) -> bool:
	var av: PeerAvatars = sess(viewer).avatars
	var a: PeerAvatars.Avatar = av._avatars.get(sess(who).my_id)
	return a != null and a.visible and not a.orb.visible


func room_of(h: Dictionary) -> Transform3D:
	return (h.board as Board).room_world("r_studio") as Transform3D


func run() -> void:
	var host_doc := owner_document()
	host_doc.save()
	var S1 := Transform3D(Basis(Vector3.UP, deg_to_rad(40.0)), Vector3(2.0, 0.0, -1.0))       # the real room in Ana's tracking space
	var S2 := Transform3D(Basis(Vector3.UP, deg_to_rad(-75.0)), Vector3(-3.0, 0.0, 2.5))      # (Ben is elsewhere: his is just his own)
	var S3 := Transform3D(Basis(Vector3.UP, deg_to_rad(120.0)), Vector3(0.5, 0.0, 4.0))       # in Dee's
	var H := headset("owner", host_doc)
	var A := headset("ana", own_document("Ana's own"), S1)
	var B := headset("ben", own_document("Ben's own"), S2)
	var D := headset("dee", own_document("Dee's own"), S3)
	await until(func(): return (H.board as Board).current_room != "" and (H.board as Board).room_state == "found")
	t.eq(sess(H).start_hosting("Lee", "Review", false), OK, "a session starts")
	t.eq(sess(H).peers[1].place, "together", "the owner is the room the others are, or are not, in")
	var port: int = sess(H).net.port
	var pa := Vector3(1.0, 0.75, -1.0)                    # two real places, far apart (the real room is the owner's tracking space)
	var pb := Vector3(2.6, 0.75, -1.3)

	# ---- somebody elsewhere: the board is in front of them at once
	t.eq(sess(B).join("127.0.0.1", port, "", "Ben", "apart"), OK, "Ben joins from another room")
	t.check(await until(func(): return sess(B).phase == "live" and (B.board as Board).doc == sess(B).client_doc and sess(B).client_doc != null), "he gets the document")
	await settle(0.4)
	t.eq(sess(B).place, "apart", "Ben is elsewhere")
	t.eq(sess(B).align_mode, "here", "the board is put in front of him")
	t.check(not sess(B).aligning(), "with no lining up to do")
	t.check(shown(B, "f1") and shown(B, "f2") and (B.board as Board).room_state == "found", "and the canvases are there")
	t.eq(sess(H).peers[sess(B).my_id].place, "apart", "the owner's list says he is elsewhere")
	t.check(not sess(H).owner_should_align() and not sess(H).needs_attention(), "nobody is in the owner's room: nothing to do")
	t.check(not sess(B).needs_attention(), "and nothing for Ben either")
	var ben_room := room_of(B)

	# ---- somebody in the owner's room: nothing shows until they and the owner have lined up
	t.eq(sess(A).join("127.0.0.1", port, "", "Ana", "together"), OK, "Ana joins from the owner's room")
	t.check(await until(func(): return sess(A).phase == "live" and (A.board as Board).doc == sess(A).client_doc and sess(A).client_doc != null), "she gets the document")
	await settle(0.4)
	t.eq(sess(A).place, "together", "Ana is in the room")
	t.eq(sess(A).align_mode, "none", "she is not lined up yet")
	t.check(sess(A).aligning(), "and the card for touching the two places is already up")
	t.check(not shown(A, "f1") and not shown(A, "f2"), "no canvas is shown: it would not be on the real spot")
	t.eq((A.board as Board).room_state, "searching", "the room is not known to her board yet")
	t.check(sess(A).needs_attention() and not sess(A).in_shared_space(), "she is asked to line up, and has no place in the shared space")
	t.eq(sess(H).peers[sess(A).my_id].place, "together", "the owner's list says she is in the room")
	t.check(sess(H).owner_should_align() and sess(H).needs_attention(), "the owner is asked to line up too")
	t.check((toasts["owner"] as Array).any(func(l): return str(l).contains("Ana is in your room")), "and told so (%s)" % str(toasts["owner"].back()))
	t.check(sess(H).align_text().contains("Ana"), "the session page says who is waiting")
	t.check(not sess(H).presence.has(sess(A).my_id), "nothing of where she is reaches the owner: it would be in the wrong place")
	t.eq(Session.place_word(sess(H).peers[sess(A).my_id], false), "aligning", "she is 'aligning' in the list")
	t.eq(Session.place_word(sess(H).peers[sess(B).my_id], false), "elsewhere", "and Ben is 'elsewhere'")
	t.check(room_of(B).origin.distance_to(ben_room.origin) < 0.0005, "Ben's board has not moved")

	# ---- she lines up first: still nothing until the owner has touched the same places
	sess(A).align_begin()
	await touch(A, S1 * pa)
	await touch(A, S1 * pb)
	t.check(sess(A).align_mode == "points" and not sess(A).aligning(), "Ana touched the two places")
	await settle(0.4)
	t.check(sess(A).waiting_for_owner() and not shown(A, "f1"), "but her points mean nothing until the owner has touched them too")
	t.check(sess(A).needs_attention() and sess(A).align_text().contains("owner"), "and she is told she is waiting for the owner")
	t.check(not sess(H).presence.has(sess(A).my_id), "(still nothing of her reaches the owner)")

	# ---- the owner touches the same places: the canvases appear on the same real spot, and Ben's board stays put
	await touch_pair(H, pa, pb)
	t.eq(sess(H).align_mode, "points", "the owner is lined up")
	t.check(await until(func(): return sess(A).in_shared_space() and shown(A, "f1") and shown(A, "f2")), "Ana's canvases appear")
	await settle(0.5)
	on_the_real_spot(A, H, "Ana")
	t.check(not sess(A).needs_attention() and not sess(H).needs_attention(), "nobody has anything left to do")
	t.eq(Session.place_word(sess(H).peers[sess(A).my_id], false), "in the room", "she is 'in the room' in the list")
	var moved := room_of(B)
	t.check(moved.origin.distance_to(ben_room.origin) < 0.001 and moved.basis.get_rotation_quaternion().angle_to(ben_room.basis.get_rotation_quaternion()) < 0.002,
		"Ben's board stayed where it was while the owner lined up (off by %.4f m)" % moved.origin.distance_to(ben_room.origin))
	t.eq(sess(B).align_mode, "here", "and he is still elsewhere")

	# ---- they see each other the way they are: a person in the room, an orb elsewhere
	var ap: PenState = A.pen
	var real_spot := Vector3(0.2, 1.1, -2.0)
	ap.tracked = true
	ap.source = "stylus"
	ap.tip = S1 * real_spot
	ap.dir = (S1.basis * Vector3(0, 0, -1)).normalized()
	await settle(0.7)
	t.check(sess(H).presence.has(sess(A).my_id), "now the owner sees where Ana is")
	var tip_for_owner: Vector3 = sess(H).align_world() * (sess(H).presence[sess(A).my_id].tip as Vector3)
	t.check(tip_for_owner.distance_to(real_spot) < 0.003, "her stylus is on the real spot (off by %.4f m)" % tip_for_owner.distance_to(real_spot))
	ap.tracked = false
	t.check(person_of(H, A) and person_of(A, H), "the owner and Ana are people to each other: a tag and a pointer, no orb")
	t.check(orb_of(B, A) and orb_of(B, H), "Ben, elsewhere, sees both as orbs")
	t.check(orb_of(A, B) and orb_of(H, B), "and they see him as one")

	# ---- a third, in the room, lines up with pinches
	t.eq(sess(D).join("127.0.0.1", port, "", "Dee", "together"), OK, "Dee joins from the owner's room")
	t.check(await until(func(): return sess(D).phase == "live" and (D.board as Board).doc == sess(D).client_doc and sess(D).client_doc != null), "she gets the document")
	await settle(0.4)
	t.check(sess(D).aligning() and not shown(D, "f1") and not sess(D).waiting_for_owner(), "the card is up, nothing is shown, and the owner is already lined up")
	t.check(not sess(H).owner_should_align(), "the owner has nothing to do for her")
	await pinch(D, S3 * pa)
	await pinch(D, S3 * pb)
	t.check(await until(func(): return shown(D, "f1") and shown(D, "f2")), "her canvases appear once she has")
	await settle(0.5)
	on_the_real_spot(D, H, "Dee")
	t.check(person_of(A, D) and person_of(D, A), "Ana and Dee are people to each other")
	t.check(orb_of(B, D) and orb_of(D, B), "Ben and Dee are orbs to each other")

	# ---- changing one's mind
	sess(A).set_place("apart")
	await settle(0.6)
	t.eq(sess(A).align_mode, "here", "Ana goes elsewhere: the board is put in front of her")
	t.check(shown(A, "f1") and (A.board as Board).room_state == "found" and not sess(A).aligning(), "and shown")
	t.eq(sess(H).peers[sess(A).my_id].place, "apart", "the owner's list follows")
	t.check(orb_of(D, A) and orb_of(H, A), "Dee and the owner now see her as an orb")
	t.eq(str(App.val("session_place")), "apart", "and the choice is remembered")
	sess(A).set_place("together")
	await settle(0.4)
	t.check(sess(A).align_mode == "none" and sess(A).aligning() and not shown(A, "f1"), "back in the room: nothing is shown until she lines up again")
	sess(A).align_cancel()
	await settle(0.3)
	t.check(not shown(A, "f1") and sess(A).needs_attention(), "cancelling the card does not show the board in the wrong place")
	t.eq(Session.place_word(sess(H).peers[sess(A).my_id], false), "aligning", "and the list says she is still aligning")
	await touch_pair(A, S1 * pa, S1 * pb)
	t.check(await until(func(): return shown(A, "f1") and shown(A, "f2")), "lined up again: the canvases are back")
	await settle(0.4)
	on_the_real_spot(A, H, "Ana")
	t.check(person_of(H, A), "and she is a person in the room again")

	# ---- the owner goes back to the room's own space: those in the room wait, those elsewhere do not notice
	var ben_before := room_of(B)
	sess(H).align_reset()
	await settle(0.8)
	t.check(sess(A).waiting_for_owner() and not shown(A, "f1") and not shown(D, "f1"), "those in the room see nothing while the owner is not lined up")
	t.check(sess(H).owner_should_align(), "and the owner is asked to line up again")
	t.check(shown(B, "f1") and room_of(B).origin.distance_to(ben_before.origin) < 0.001, "Ben's board did not move (off by %.4f m)" % room_of(B).origin.distance_to(ben_before.origin))
	await touch_pair(H, pa, pb)
	t.check(await until(func(): return shown(A, "f1") and shown(D, "f1")), "the owner lines up: the canvases are back in the room")
	await settle(0.5)
	on_the_real_spot(A, H, "Ana")
	on_the_real_spot(D, H, "Dee")
	t.check(room_of(B).origin.distance_to(ben_before.origin) < 0.001, "and Ben's board has still not moved")

	# ---- what is remembered, and what a modified app can not fake
	t.eq(sess(A).resume_state().get("place"), "together", "a guest in the room is saved as such for a restart")
	t.eq(sess(B).resume_state().get("place"), "apart", "and one elsewhere")
	var before: String = str(sess(H).peers[sess(B).my_id].place)
	sess(B).net.send(SessionNet.SERVER, {"t": "status", "align": "here", "place": "anywhere"})
	await settle(0.4)
	t.eq(str(sess(H).peers[sess(B).my_id].place), before, "a place that is neither is not taken")

	# ---- joining without saying: what this headset chose last
	sess(D).leave(true)
	await settle(0.4)
	App.put("session_place", "together")
	t.eq(sess(D).join("127.0.0.1", port, "", "Dee"), OK, "joining again without saying where")
	t.eq(sess(D).place, "together", "takes the last choice")
	sess(D).leave(true)
	await settle(0.3)
	t.eq(sess(D).join("127.0.0.1", port, "", "Dee", "nowhere"), OK, "and a place that is neither")
	t.eq(sess(D).place, "together", "falls back on it as well")
	sess(D).leave(true)

	# ---- leaving
	for h in [A, B]:
		sess(h).leave(true)
	await settle(0.5)
	t.check(sess(A).role == Session.Role.NONE and not sess(A).needs_attention(), "after leaving nothing is asked of anybody")


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
