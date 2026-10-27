extends Node
## 3D models in a session, the other headsets included: an owner and two guests (one on a Quest 3's budget, one on a Quest 2's whose limit is
## set below this model, so it must refuse it) as real boards over real local connections. The owner puts a model down: the file goes to each
## guest once, byte for byte; each headset loads it itself (or says why it cannot); everybody gets the size the owner's headset measured. The
## owner moves it with a handle and the guests see it move while it happens and where it ends; a guest without the owner's say-so cannot move
## it, with it they can, and the owner sees that. A guest can only ever be given a file a frame of the session shows.

var t := TestCase.new("model_session")
var heads: Array = []
var _ball: PackedByteArray


func _ready() -> void:
	App.settings_path = "user://test_settings_model_session.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_model_session"
	if DirAccess.dir_exists_absolute(App.docs_dir):
		for f in DirAccess.get_files_at(App.docs_dir):
			DirAccess.remove_absolute(App.docs_dir + "/" + f)
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	await run()
	for h in heads:
		(h.board as Board).session.net.close()
	for h in heads:
		_clean("user://test_models_session_%s" % h.name)
	get_tree().quit(t.done())


func _clean(dir: String) -> void:
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


func headset(who: String, doc: Document, tier: String = "high") -> Dictionary:
	_clean("user://test_models_session_%s" % who)
	App.model_dir = "user://test_models_session_%s" % who
	var path := "user://test_sim_anchors_model_session_%s.json" % who
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var anchors := SimAnchors.new(path)
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	board.models.threaded = false
	board.models.budget = ModelBudget.for_tier(tier)
	var head := [Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))]
	board.head_provider = func(): return head[0]
	var h := {"name": who, "board": board, "pen": PenState.new(), "hands": [], "head": head}
	board.open(doc)
	heads.append(h)
	return h


func tick(n: int = 1) -> void:
	for i in n:
		for h in heads:
			(h.board as Board).tick(h.pen, h.hands, 0.016)
			for hd in h.hands:
				(hd as HandInput).pinch_down = false
				(hd as HandInput).pinch_up = false
		await get_tree().process_frame


func until(cond: Callable, seconds: float = 8.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await tick()
		if cond.call():
			return true
	return false


func settle(seconds: float = 0.4) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await tick()


func sess(h: Dictionary) -> Session:
	return (h.board as Board).session


func bd(h: Dictionary) -> Board:
	return h.board


func shared_doc() -> Document:
	var doc := Document.create("Design review")
	var room := doc.add_room("Studio", "", Transform3D.IDENTITY)
	room.id = "r_studio"
	doc.last_room = "r_studio"
	return doc


func own_doc(title: String) -> Document:
	var d := DocStore.create_new(title)
	d.add_room("Mine", "", Transform3D.IDENTITY)
	d.save()
	return d


func model_frame(h: Dictionary) -> FrameData:
	for f in bd(h).doc.frames.values():
		if (f as FrameData).is_model():
			return f
	return null


func model_node(h: Dictionary) -> ModelNode:
	var f := model_frame(h)
	return bd(h).model_nodes.get(f.id) if f != null else null


## Where the model is in the shared room, as one headset shows it.
func in_room(h: Dictionary) -> Vector3:
	var rw: Variant = bd(h).room_world(bd(h).current_room)
	return (rw as Transform3D).affine_inverse() * model_node(h).global_position


## A drag with a hand pointing from `o` at `from`: pinch, move the hand by `to - from`, let go (the hand is `h`'s right hand).
func drag(h: Dictionary, o: Vector3, from: Vector3, to: Vector3, mid_check: Callable = Callable()) -> void:
	var hand := HandInput.new("right")
	h.hands = [hand]
	for k in range(0, 9):
		var at := from if k < 3 else from.lerp(to, (k - 2) / 5.0)
		var pinch := k >= 2 and k < 8
		if k == 8:
			at = to
		hand.tracked = true
		hand.aiming = true
		hand.aim_o = o + (at - from)                         # (the hand itself moves, its ray keeps its direction)
		hand.aim_d = (from - o).normalized()
		hand.press_o = hand.aim_o
		hand.press_d = hand.aim_d
		hand.pinch_point = hand.aim_o
		hand.pinch_down = pinch and not hand.pinching
		hand.pinch_up = hand.pinching and not pinch
		hand.pinching = pinch
		await tick()
		if k == 6 and mid_check.is_valid():
			for i in 10:
				await tick()                                  # (the live channel sends about 12 times a second)
			mid_check.call()
	h.hands = []
	await tick(2)


static func _box_glb() -> PackedByteArray:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	doc.append_from_scene(root, st)
	var out := doc.generate_buffer(st)
	root.free()
	return out


static func _ball_glb() -> PackedByteArray:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 0.15
	sp.height = 0.3
	sp.radial_segments = 32
	sp.rings = 16
	mi.mesh = sp
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	doc.append_from_scene(root, st)
	var out := doc.generate_buffer(st)
	root.free()
	return out


func run() -> void:
	_ball = _ball_glb()
	var H := headset("owner", shared_doc())
	var A := headset("ana", own_doc("Ana's own"))
	var B := headset("ben", own_doc("Ben's own"), "low")
	bd(B).models.budget.max_triangles = 500                 # (a Quest 2 whose limit this model is over)
	await until(func(): return bd(H).current_room != "" and bd(H).room_state == "found")
	sess(H).model_share.rate = 1e9
	t.eq(sess(H).start_hosting("Lee", "Review", true), OK, "a session starts")
	var port: int = sess(H).net.port
	var code: String = sess(H).code
	sess(A).join("127.0.0.1", port, code, "Ana")
	sess(B).join("127.0.0.1", port, code, "Ben")
	t.check(await until(func(): return sess(A).phase == "live" and sess(B).phase == "live" and bd(A).doc == sess(A).client_doc and bd(B).doc == sess(B).client_doc), "two guests are in (one on a Quest 3's budget, one on a Quest 2's)")
	await settle(0.3)

	# ---- the owner puts a model down: the file follows, each headset loads it itself
	var added := bd(H).models.add(_ball, "Globe.glb")
	var placed := bd(H).place_model(str(added.id))
	t.check(bool(placed.ok), "the owner puts a model down")
	var mid := str(added.id)
	t.check(await until(func(): return model_frame(A) != null and model_frame(B) != null), "the model's frame reaches both guests")
	t.check(await until(func(): return bd(A).models.has(mid) and bd(B).models.has(mid)), "and so does the file, once each")
	t.check(bd(A).models.file_bytes(mid) == _ball and bd(B).models.file_bytes(mid) == _ball, "byte for byte")
	t.check(bool(bd(A).models.entry(mid).get("cached", false)), "kept as a copy that came from a session")
	t.check(await until(func(): return model_node(H).state == "ready" and model_node(A).state == "ready"), "the owner and Ana show it")
	t.check(await until(func(): return model_node(B).state == "failed"), "Ben's headset cannot bear it")
	t.check(model_node(B).note.contains("too detailed"), "and says so where it stands: %s" % model_node(B).note)
	t.check(await until(func(): return model_frame(A).model_measured() and model_frame(B).model_measured()), "everybody gets the size the owner's headset measured")
	t.check(model_frame(B).model_box.size.is_equal_approx(model_frame(H).model_box.size), "the same size (Ben's stand-in box has the model's size too)")
	t.near(in_room(A).distance_to(in_room(H)), 0.0, 0.002, "it stands at the same place in the shared room for Ana")

	# ---- the owner moves it along an axis: the guests see it move, and where it ends
	var ctl := bd(H).model_ctl
	ctl.select(model_frame(H).id)
	ctl.set_mode("move")
	await tick(2)
	var c := model_node(H).global_position
	var g := ctl.gizmo
	var on_x := c + Vector3(g.extent.x + g.s * 4.0, 0, 0)
	var before := in_room(A)
	var live := [false]
	await drag(H, Vector3(0.25, 1.45, -0.2), on_x, on_x + Vector3(0.2, 0, 0), func():
		live[0] = bd(A).remote_grabs.has(model_frame(A).id) and in_room(A).distance_to(before) > 0.02)
	t.check(live[0], "while the owner holds the arrow, Ana sees it move")
	t.check(await until(func(): return absf(in_room(A).x - before.x - 0.2) < 0.005), "and where it is let go: %s" % str(in_room(A) - before))
	t.check(await until(func(): return bd(A).remote_grabs.is_empty()), "the live preview stands down")
	t.near(in_room(B).x, in_room(H).x, 0.005, "Ben's stand-in box moves too")

	# ---- a guest may not move it without the owner's say-so
	var fa := model_frame(A)
	var ca := model_node(A).global_position
	var start_a := in_room(A)
	await drag(A, ca + Vector3(0, 0, 0.8), ca, ca + Vector3(0.0, 0.2, 0.0))
	await settle(0.3)
	t.near(in_room(H).distance_to(start_a), 0.0, 0.002, "Ana cannot carry it while guests may not move things")
	t.near(in_room(A).distance_to(start_a), 0.0, 0.002, "(nor on her own headset)")
	sess(H).set_canvas_edit(true)
	t.check(await until(func(): return sess(A).can_edit_canvases()), "the owner lets guests move things")
	ca = model_node(A).global_position
	await drag(A, ca + Vector3(0, 0, 0.8), ca, ca + Vector3(0.0, 0.2, 0.0))
	t.check(await until(func(): return in_room(H).y - start_a.y > 0.1), "Ana carries it up and the owner sees it: %s" % str(in_room(H) - start_a))
	# her hand in the model, selected: she carries it 1:1, and sees no box or handles meanwhile
	var actl := bd(A).model_ctl
	actl.select(fa.id)
	await tick(2)
	var cb := model_node(A).global_position
	var start_b := in_room(H)
	var bare := [false]
	await drag(A, cb + Vector3(0, 0, 0.02), cb, cb + Vector3(0.1, 0.0, 0.0), func():
		bare[0] = not actl._holds.is_empty() and actl.selected == "" and not actl.gizmo.visible)
	t.check(bare[0], "Ana's hand in the selected model carries it with no box or handles showing")
	t.check(await until(func(): return absf(in_room(H).x - start_b.x - 0.1) < 0.005), "1:1, and the owner sees it: %s" % str(in_room(H) - start_b))
	t.check(actl.selected == "", "let go, it stays unselected for her")
	t.check(fa != null, "(Ana's frame was there)")

	# ---- only files a frame of the session shows are given out
	var secret := bd(H).models.add(_box_glb(), "Secret.glb")
	sess(A).model_share.client_want(str(secret.id))
	await settle(0.5)
	t.check(not bd(A).models.has(str(secret.id)), "a model no frame of the session shows is not given out")
	t.check(bd(A).models.state_text(str(secret.id)).contains("not part of the session"), "and the guest is told why")
	t.check(bool(secret.ok), "(the owner keeps other models of their own)")
	# ---- leaving keeps a few received copies
	sess(A).leave(true)
	await settle(0.3)
	t.check(bd(A).doc != sess(A).client_doc, "Ana leaves")
	t.check(bd(A).models.has(mid), "and keeps the received copy (one of the last few)")
