extends Node
## Seeing what the others are doing while they do it: the real pen controller of one headset drives a stroke, a snap, a drag, a resize, a
## stencil, the eraser and a carried canvas, and the other headsets of the session show each of them before it is finished, then hand over to
## the real edit without a flicker. Also: a guest who may not edit is not shown, damaged messages are dropped, somebody who leaves
## in the middle takes their preview with them, and a preview that stops being updated goes by itself.

var t := TestCase.new("live_preview")
var heads: Array = []


func _ready() -> void:
	App.settings_path = "user://test_settings_live.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_live"
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	App.put("sim_room", "A")
	App.put("recognize", "hold")
	App.put("hold_seconds", 0.55)
	await run()
	for h in heads:
		(h.board as Board).session.net.close()
	get_tree().quit(t.done())


func headset(who: String, doc: Document, tracking: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	var path := "user://test_sim_anchors_live_%s.json" % who
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var anchors := SimAnchors.new(path)
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	var head := [Transform3D(Basis.IDENTITY, tracking * Vector3(0, 1.6, 0))]
	board.head_provider = func(): return head[0]
	var h := {"name": who, "board": board, "pen": PenState.new(), "hands": [], "head": head}
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


func settle(frames: int = 40) -> void:
	await tick(frames)


func sess(h: Dictionary) -> Session:
	return (h.board as Board).session


func doc_of(h: Dictionary) -> Document:
	return (h.board as Board).doc


func node(h: Dictionary, fid: String = "f1") -> FrameNode:
	return (h.board as Board).frame_nodes[fid]


## A point of the canvas f1 as this headset sees it, in its world.
func at(h: Dictionary, p: Vector2, fid: String = "f1") -> Vector3:
	return node(h, fid).to_world_point(Vector3(p.x, p.y, 0.0))


func pv(h: Dictionary) -> LivePreview:
	return sess(h).previews


func hover(h: Dictionary, p: Vector2) -> void:
	var pen: PenState = h.pen
	pen.tracked = true
	pen.source = "mouse"
	pen.tip = at(h, p)
	pen.down = false
	pen.pressure = 0.0
	await tick(2)


## Press and move along some canvas points; stop pressed (release = false) to look at what the others see meanwhile.
func stroke(h: Dictionary, pts: Array, hold: int = 0, release: bool = true) -> void:
	await hover(h, pts[0])
	var pen: PenState = h.pen
	pen.down = true
	pen.pressure = 0.7
	for p in pts:
		pen.tip = at(h, p)
		await tick(1)
	if hold > 0:
		await tick(hold)
	if release:
		await lift(h)


func lift(h: Dictionary) -> void:
	var pen: PenState = h.pen
	pen.down = false
	pen.pressure = 0.0
	await tick(3)


func line_pts(a: Vector2, b: Vector2, n: int) -> Array:
	var out: Array = []
	for i in n + 1:
		out.append(a.lerp(b, float(i) / float(n)))
	return out


func wavy(x0: float, y: float, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(Vector2(x0 + 0.012 * i, y + 0.05 * sin(float(i) * 0.4)))
	return out


func owner_document() -> Document:
	var doc := Document.create("Live")
	var room := doc.add_room("Studio", "", Transform3D.IDENTITY)
	room.id = "r_studio"
	doc.last_room = "r_studio"
	var f := FrameData.make(FrameData.CANVAS, "r_studio", Transform3D(Basis.IDENTITY, Vector3(0, 1.3, -1.0)))
	f.id = "f1"
	doc.add_frame(f)
	var rect := Item.make_shape("f1", "rect", Color.WHITE, 0.004)
	rect.id = "i_rect"
	rect.center = Vector2(0.3, 0.1)
	rect.size = Vector2(0.3, 0.2)
	rect.fill = Color(1, 1, 1, 0.25)
	doc.add_item(rect)
	var old := Item.make_stroke("f1", PackedFloat32Array([-0.3, -0.2, 0, 0.5, -0.2, -0.2, 0, 0.5, -0.1, -0.2, 0, 0.5]), Color("#ffd166"), 0.004, "pen")
	old.id = "i_old"
	doc.add_item(old)
	return doc


func run() -> void:
	var H := headset("owner", owner_document())
	var A := headset("ana", Document.create("Ana's own"))
	var B := headset("ben", Document.create("Ben's own"))
	await until(func(): return (H.board as Board).room_state == "found")
	t.eq(sess(H).start_hosting("Lee", "Live", false), OK, "a session starts")
	var port: int = sess(H).net.port
	sess(A).join("127.0.0.1", port, "", "Ana")
	sess(B).join("127.0.0.1", port, "", "Ben")
	t.check(await until(func(): return sess(A).phase == "live" and sess(B).phase == "live" and sess(A).client_doc != null and sess(B).client_doc != null and sess(A).have_space and sess(B).have_space), "two guests are in")
	await until(func(): return (A.board as Board).room_state == "found" and (B.board as Board).room_state == "found")
	App.put("tool", "draw")

	# ---- a stroke is seen while it is drawn
	var pts := wavy(-0.35, 0.2, 60)
	await stroke(H, pts.slice(0, 35), 0, false)
	await settle(8)
	var id_h: String = (H.board as Board).pen_ctl.live_id
	t.check(id_h != "", "the stroke has the id its item will have")
	t.eq(pv(A).stroke_count(), 1, "a guest sees the owner's stroke while it is being drawn")
	t.eq(pv(B).stroke_count(), 1, "and so does the other")
	var host_n := (H.board as Board).pen_ctl._live.point_count()
	var a_n := pv(A).stroke_points()
	t.check(a_n > 5 and a_n <= host_n and a_n >= host_n - 12, "with nearly all of its points so far (%d of %d)" % [a_n, host_n])
	t.check(not doc_of(A).items.has(id_h) and doc_of(A).items.size() == 2, "it is not in the document yet")
	await stroke(H, pts.slice(35), 0, false)
	await settle(8)
	t.check(pv(A).stroke_points() >= (H.board as Board).pen_ctl._live.point_count() - 12, "it keeps growing")
	await lift(H)
	t.check(await until(func(): return doc_of(A).items.has(id_h) and doc_of(B).items.has(id_h)), "when it is finished the real item arrives with the id the preview had")
	await settle(10)
	t.eq(pv(A).stroke_count() + pv(B).stroke_count(), 0, "and the preview is gone")
	t.eq((doc_of(A).items[id_h] as Item).kind, Item.STROKE, "a stroke")

	# ---- a guest's stroke is seen by the owner and the other guest
	await stroke(A, wavy(-0.3, -0.05, 30), 0, false)
	await settle(8)
	var id_a: String = (A.board as Board).pen_ctl.live_id
	t.eq(pv(H).stroke_count(), 1, "the owner sees a guest's stroke being drawn")
	t.eq(pv(B).stroke_count(), 1, "so does another guest (the host passes it on)")
	t.eq(pv(A).stroke_count(), 0, "and a guest does not see their own as a copy")
	await lift(A)
	t.check(await until(func(): return doc_of(H).items.has(id_a) and doc_of(B).items.has(id_a)), "it ends as a real item everywhere")
	await settle(10)
	t.eq(pv(H).stroke_count() + pv(B).stroke_count(), 0, "with no preview left")

	# ---- hold the pen still and the stroke snaps to a line: the others see the line, not the stroke
	await stroke(H, line_pts(Vector2(-0.3, -0.3), Vector2(0.2, -0.3), 30), 45, false)
	await settle(8)
	var id_s: String = (H.board as Board).pen_ctl.live_id
	t.eq((H.board as Board).pen_ctl.snapped_shape, "line", "the owner's stroke snapped to a line")
	var ghosts := 0
	for w in pv(A)._works.values():
		if (w as Dictionary).ghost and (w as Dictionary).id == id_s:
			ghosts += 1
	t.eq(ghosts, 1, "the guest sees the line it has become")
	var hidden := 0
	for s in pv(A)._strokes.values():
		if not (s.ls as LiveStroke).visible:
			hidden += 1
	t.eq(hidden, 1, "and not the wobbly stroke under it")
	await lift(H)
	t.check(await until(func(): return doc_of(A).items.has(id_s)), "the line arrives with the same id")
	t.eq((doc_of(A).items[id_s] as Item).kind, Item.SHAPE, "as a shape")
	await settle(10)
	t.eq(pv(A).count(), 0, "nothing is left of the previews")

	# ---- dragging an item: it follows the hand on the other headsets
	App.put("tool", "select")
	var rect := doc_of(H).items["i_rect"] as Item
	var edge := Vector2(rect.center.x + rect.size.x * 0.5, rect.center.y)
	await hover(H, edge)
	var pen: PenState = H.pen
	pen.down = true
	pen.pressure = 0.7
	await tick(2)
	for i in 14:
		pen.tip = at(H, edge + Vector2(0.01, 0.006) * float(i + 1))
		await tick(1)
	await settle(8)
	var view_a := node(A).view_of("i_rect")
	t.check(view_a.transform.origin.length() > 0.08, "a guest sees the box move (%.3f m so far)" % view_a.transform.origin.length())
	t.check((doc_of(A).items["i_rect"] as Item).center.is_equal_approx(Vector2(0.3, 0.1)), "though the document still has it where it was")
	var seen_by_b := node(B).view_of("i_rect").transform.origin
	var seen_by_a := view_a.transform.origin
	t.check(seen_by_a.distance_to(seen_by_b) < 0.01, "both guests see it in the same place")
	t.check(Vector2(seen_by_a.x, seen_by_a.y).distance_to(Vector2(0.14, 0.084)) < 0.03, "which is where the owner's hand has taken it (%s)" % str(Vector2(seen_by_a.x, seen_by_a.y)))
	await lift(H)
	t.check(await until(func(): return not (doc_of(A).items["i_rect"] as Item).center.is_equal_approx(Vector2(0.3, 0.1))), "when it is let go the real move arrives")
	await settle(10)
	var settled_a := doc_of(A).items["i_rect"] as Item
	var settled_h := doc_of(H).items["i_rect"] as Item
	t.check(settled_a.center.is_equal_approx(settled_h.center), "and agrees with the owner's")
	t.check(node(A).view_of("i_rect").transform.is_equal_approx(Transform3D.IDENTITY), "with the preview offset gone (it is not applied twice)")
	t.eq(pv(A).count(), 0, "no preview is left")

	# ---- resizing a shape by a corner
	(H.board as Board).select_items(["i_rect"], "f1")
	await tick(2)
	var corner := Vector2.ZERO
	for hd in (H.board as Board).pen_ctl.handles(node(H)):
		if str(hd.id) == "corner2":
			corner = hd.pos
	t.check(corner != Vector2.ZERO, "the box has a corner handle")
	var size_before: Vector2 = settled_h.size
	await hover(H, corner)
	pen.down = true
	pen.pressure = 0.7
	await tick(2)
	for i in 12:
		pen.tip = at(H, corner + Vector2(0.012, 0.008) * float(i + 1))
		await tick(1)
	await settle(8)
	var shown := node(A).view_of("i_rect").item as Item
	t.check(shown.size.x > size_before.x + 0.05, "a guest sees the box getting bigger (%.2f from %.2f)" % [shown.size.x, size_before.x])
	t.check((doc_of(A).items["i_rect"] as Item).size.is_equal_approx(size_before), "while the document still has the old size")
	await lift(H)
	t.check(await until(func(): return (doc_of(A).items["i_rect"] as Item).size.x > size_before.x + 0.05), "the real size arrives")
	await settle(10)
	t.check((node(A).view_of("i_rect").item as Item).size.is_equal_approx((doc_of(H).items["i_rect"] as Item).size), "and is what the owner has")
	t.eq(pv(A).count(), 0, "no preview is left")
	(H.board as Board).clear_selection()

	# ---- a stencil being dragged out
	App.put("tool", "shape")
	(H.board as Board).stencil = "ellipse"
	await hover(H, Vector2(-0.3, 0.3))
	pen.down = true
	pen.pressure = 0.7
	await tick(2)
	for i in 10:
		pen.tip = at(H, Vector2(-0.3, 0.3) + Vector2(0.015, 0.01) * float(i + 1))
		await tick(1)
	await settle(8)
	var id_e := ""
	for w in pv(A)._works.values():
		if (w as Dictionary).ghost:
			id_e = str((w as Dictionary).id)
	t.check(id_e != "", "a guest sees the ellipse being dragged out")
	t.check(not doc_of(A).items.has(id_e), "before it exists")
	await lift(H)
	t.check(await until(func(): return doc_of(A).items.has(id_e)), "then it is a real shape, with the id the ghost had")
	await settle(10)
	t.eq(pv(A).count(), 0, "and the ghost is gone")

	# ---- the eraser: what it touches disappears for the others at once
	App.put("tool", "erase")
	await hover(H, Vector2(-0.3, -0.2))
	pen.down = true
	pen.pressure = 0.7
	await tick(2)
	for i in 6:
		pen.tip = at(H, Vector2(-0.3 + 0.04 * float(i), -0.2))
		await tick(1)
	await settle(8)
	t.check(not node(A).view_of("i_old").visible, "a guest sees the old stroke go as the eraser passes")
	t.check(doc_of(A).items.has("i_old"), "(it is not deleted yet)")
	await lift(H)
	t.check(await until(func(): return not doc_of(A).items.has("i_old") and not doc_of(B).items.has("i_old")), "then it is deleted for real")
	await settle(10)
	t.eq(pv(A).count(), 0, "with nothing left of the preview")

	# ---- a canvas carried by the owner moves on the guests' headsets
	var hb := H.board as Board
	var f1h := doc_of(H).frames["f1"] as FrameData
	hb.begin_grab(f1h)
	t.check(hb.grabs.has("f1"), "the owner picks the canvas up")
	var start_xf: Transform3D = (hb.grabs["f1"] as Dictionary).xf
	var carried := Transform3D(Basis(Vector3.UP, 0.4), start_xf.origin + Vector3(0.5, 0.2, 0.3))
	for i in 12:
		(hb.grabs["f1"] as Dictionary).xf = start_xf.interpolate_with(carried, float(i + 1) / 12.0)
		(hb.grabs["f1"] as Dictionary).scale = 1.0 + 0.02 * float(i)
		await tick(1)
	await settle(8)
	var rw_h: Transform3D = hb.room_world("r_studio")
	var rel_h := rw_h.affine_inverse() * node(H).transform
	var rw_a: Transform3D = (A.board as Board).room_world("r_studio")
	var rel_a := rw_a.affine_inverse() * node(A).transform
	t.check(rel_a.origin.distance_to(rel_h.origin) < 0.01, "a guest sees the canvas carried to the same place in the room (off by %.4f m)" % rel_a.origin.distance_to(rel_h.origin))
	t.check(node(A).scale.x > 1.1, "and as big as the owner has made it (%.2f)" % node(A).scale.x)
	t.check((doc_of(A).frames["f1"] as FrameData).xf.origin.is_equal_approx(f1h.xf.origin), "though the document still has the old place")
	hb.end_grab(f1h)
	t.check(await until(func(): return not (doc_of(A).frames["f1"] as FrameData).xf.origin.is_equal_approx(start_xf.origin - Vector3.ZERO) or (doc_of(A).frames["f1"] as FrameData).scale > 1.1), "the real move arrives")
	await settle(30)
	var rel_a2 := ((A.board as Board).room_world("r_studio") as Transform3D).affine_inverse() * node(A).transform
	var rel_h2 := (hb.room_world("r_studio") as Transform3D).affine_inverse() * node(H).transform
	t.check(rel_a2.origin.distance_to(rel_h2.origin) < 0.003, "and puts it where the owner put it down (off by %.4f m)" % rel_a2.origin.distance_to(rel_h2.origin))
	t.check((A.board as Board).remote_grabs.is_empty() and pv(A).count() == 0, "with nothing held back")

	# ---- a guest who may not edit is not shown, and cannot slip something in
	sess(H).set_peer_edit(sess(A).my_id, false)
	t.check(await until(func(): return (A.board as Board).history.read_only), "a guest is switched to view only")
	sess(A)._send_live_edit({"k": "s", "key": "c0", "id": "i_sneak", "f": "f1", "b": "pen", "c": "#ff0000ff", "w": 0.004, "i": 0, "p": PackedFloat32Array([0, 0, 0, 1, 0.1, 0.1, 0, 1]), "vis": true})
	await settle(15)
	t.eq(pv(H).stroke_count() + pv(B).stroke_count(), 0, "what a view-only guest sends as a preview is shown to nobody")
	sess(H).set_peer_edit(sess(A).my_id, true)
	await until(func(): return not (A.board as Board).history.read_only)

	# ---- damaged and hostile messages
	var junk: Array = [
		{"k": "s", "key": "x", "id": "i_j1", "f": "f1", "b": "pen", "c": "#fff", "w": 0.004, "i": 0, "p": PackedFloat32Array([0, 0, 0]), "vis": true},
		{"k": "s", "key": "x", "id": "i_j2", "f": "f_nowhere", "b": "pen", "c": "#fff", "w": 0.004, "i": 0, "p": PackedFloat32Array([0, 0, 0, 1]), "vis": true},
		{"k": "s", "key": "x", "id": "i_j3", "f": "f1", "b": "pen", "c": "#fff", "w": 0.004, "i": 0, "p": "not points", "vis": true},
		{"k": "s", "key": "x", "id": "i_j4", "f": "f1", "b": "pen", "c": "#fff", "w": 0.004, "i": 5, "p": PackedFloat32Array([0, 0, 0, 1]), "vis": true},
		{"k": "d", "key": "x", "f": "f1", "ids": "all", "t": Transform3D.IDENTITY},
		{"k": "d", "key": "x", "f": "f1", "ids": ["i_rect"], "t": Transform3D(Basis.IDENTITY, Vector3(INF, 0, 0))},
		{"k": "d", "key": "x", "f": "f1", "ids": ["i_rect"], "t": "moved"},
		{"k": "w", "key": "x", "f": "f1", "item": {"id": "", "kind": "shape"}, "ghost": true},
		{"k": "w", "key": "x", "f": "f1", "item": 5, "ghost": true},
		{"k": "w", "key": "x", "f": "f1", "item": {"id": "i_t", "kind": "text", "text": "x"}, "ghost": true},
		{"k": "g", "f": "f1", "xf": "here"},
		{"k": "g", "f": "f_nowhere", "xf": Transform3D.IDENTITY, "s": 1.0},
		{"k": "q"}, {}, {"k": 5}, {"k": "x", "key": "x", "ids": 7}]
	var many: Array = []
	for i in LivePreview.MAX_IDS + 5:
		many.append("i%d" % i)
	junk.append({"k": "d", "key": "x", "f": "f1", "ids": many, "t": Transform3D.IDENTITY})
	junk.append({"k": "s", "key": "x", "id": "i_j5", "f": "f1", "b": "pen", "c": "#fff", "w": 0.004, "i": 0, "p": PackedFloat32Array(range((LivePreview.MAX_POINTS + 1) * 4)), "vis": true})
	for m in junk:
		pv(B).apply(sess(A).my_id, m)
	await settle(5)
	t.eq(pv(B).count(), 0, "none of sixteen kinds of rubbish leaves anything behind")
	var tough := {"k": "g", "f": "f1", "xf": Transform3D(Basis.IDENTITY, Vector3(1, 1, 1)), "s": 1000.0}
	pv(B).apply(sess(A).my_id, tough)
	t.check(float((B.board as Board).remote_grabs["f1"].scale) <= 8.0, "an absurd scale is brought back to a sane one")
	pv(B).apply(sess(A).my_id, {"k": "g", "f": "f1", "end": true})
	await settle(5)
	pv(B).clear_all()
	t.check((B.board as Board).remote_grabs.is_empty(), "a canvas held by a message that never ends is let go when everything is cleared")

	# ---- a preview that is not kept up goes away by itself
	pv(B).apply(sess(A).my_id, {"k": "d", "key": "stuck", "f": "f1", "ids": ["i_rect"], "t": Transform3D(Basis.IDENTITY, Vector3(0.2, 0.2, 0.0))})
	await tick(2)
	t.check(node(B).view_of("i_rect").transform.origin.length() > 0.2, "a drag preview is shown")
	var end := Time.get_ticks_msec() + int((LivePreview.IDLE_S + 0.6) * 1000.0)
	while Time.get_ticks_msec() < end:
		await tick(1)
	t.check(node(B).view_of("i_rect").transform.is_equal_approx(Transform3D.IDENTITY) and pv(B).count() == 0, "but not for ever if nothing keeps it up")

	# ---- somebody who leaves in the middle of a stroke takes it with them
	App.put("tool", "draw")
	await stroke(A, wavy(-0.3, 0.3, 20), 0, false)
	await settle(8)
	t.eq(pv(H).stroke_count(), 1, "a guest is part way through a stroke")
	sess(A).leave()
	t.check(await until(func(): return pv(H).stroke_count() == 0 and pv(B).stroke_count() == 0), "when they leave, the half-drawn stroke is gone")
	(A.pen as PenState).down = false
