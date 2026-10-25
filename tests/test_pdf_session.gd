extends Node
## PDFs in a session, the other headsets included: an owner and three guests (a Quest 3-class one, a Quest 2-class one that takes in smaller
## files, and one who joins late) as real boards over real local connections. The owner puts a PDF down: the file goes to each guest once,
## checked against its content id, and every headset makes its own pages from it at its own quality. Pages turned by the owner are everybody's,
## a guest who may not move canvases looks at other pages for themselves, drawings belong to pages for everybody, and a guest can only
## ever be given a file that a canvas of the session shows.

const FIX := "res://tests/fixtures/pdf/"

var t := TestCase.new("pdf_session")
var heads: Array = []


func _ready() -> void:
	App.settings_path = "user://test_settings_pdf_session.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_pdf_session"
	if DirAccess.dir_exists_absolute(App.docs_dir):
		for f in DirAccess.get_files_at(App.docs_dir):
			DirAccess.remove_absolute(App.docs_dir + "/" + f)
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	await run()
	for h in heads:
		(h.board as Board).session.net.close()
	for h in heads:
		_clean("user://test_pdfs_session_%s" % h.name)
	get_tree().quit(t.done())


func _clean(dir: String) -> void:
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


func headset(who: String, doc: Document, tier: String = "high") -> Dictionary:
	_clean("user://test_pdfs_session_%s" % who)
	App.pdf_dir = "user://test_pdfs_session_%s" % who
	var path := "user://test_sim_anchors_pdf_session_%s.json" % who
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var anchors := SimAnchors.new(path)
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	board.pdfs.threaded = false
	board.pdfs.budget = PdfBudget.for_tier(tier)
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
	var doc := Document.create("Reading group")
	var room := doc.add_room("Studio", "", Transform3D.IDENTITY)
	room.id = "r_studio"
	doc.last_room = "r_studio"
	var f := FrameData.make(FrameData.CANVAS, "r_studio", Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -1.5)))
	f.id = "f_plain"
	doc.add_frame(f)
	return doc


func own_doc(title: String) -> Document:
	var d := DocStore.create_new(title)
	d.add_room("Mine", "", Transform3D.IDENTITY)
	d.save()
	return d


func pdf_frame(h: Dictionary) -> FrameData:
	for f in bd(h).doc.frames.values():
		if (f as FrameData).is_pdf():
			return f
	return null


func run() -> void:
	var H := headset("owner", shared_doc())
	var A := headset("ana", own_doc("Ana's own"))
	var B := headset("ben", own_doc("Ben's own"), "low")
	await until(func(): return bd(H).current_room != "" and bd(H).room_state == "found")
	sess(H).pdf_share.rate = 1e9
	t.eq(sess(H).start_hosting("Lee", "Reading", true), OK, "a session starts")
	var port: int = sess(H).net.port
	var code: String = sess(H).code
	sess(A).join("127.0.0.1", port, code, "Ana")
	sess(B).join("127.0.0.1", port, code, "Ben")
	t.check(await until(func(): return sess(A).phase == "live" and sess(B).phase == "live" and bd(A).doc == sess(A).client_doc and bd(B).doc == sess(B).client_doc), "two guests are in (one on a Quest 3's budget, one on a Quest 2's)")
	await settle(0.3)
	t.eq(bd(B).pdfs.budget.tier, "low", "Ben's headset works on the Quest 2 budget")

	# ---- the owner puts a PDF down: the file follows
	var pdf_bytes := FileAccess.get_file_as_bytes(FIX + "base14.pdf")
	var added := bd(H).pdfs.add(pdf_bytes, "Reading list.pdf")
	var placed := bd(H).place_pdf(str(added.id))
	t.check(bool(placed.ok), "the owner puts a PDF down")
	var pdf_id := str(added.id)
	t.check(await until(func(): return pdf_frame(A) != null and pdf_frame(B) != null), "the canvas reaches both guests")
	t.check(await until(func(): return bd(A).pdfs.has(pdf_id) and bd(B).pdfs.has(pdf_id)), "and so does the file, once each")
	t.check(bd(A).pdfs.file_bytes(pdf_id) == pdf_bytes and bd(B).pdfs.file_bytes(pdf_id) == pdf_bytes, "byte for byte")
	t.check(bool(bd(A).pdfs.entry(pdf_id).get("cached", false)), "kept as a copy that came from a session (cleaned up later)")
	var fa: FrameNode = bd(A).frame_nodes[pdf_frame(A).id]
	var fb: FrameNode = bd(B).frame_nodes[pdf_frame(B).id]
	t.check(await until(func(): return fa.pdf_state == "ready" and fb.pdf_state == "ready"), "every headset makes the page itself")
	t.check(fa.pdf_note == "" or not fa._pdf_label.visible, "and the note that it was on its way is gone")
	var pa: PdfPageData = bd(A).pdfs.cached_page(pdf_id, 1)
	var pb: PdfPageData = bd(B).pdfs.cached_page(pdf_id, 1)
	t.check(pa != null and pb != null and pa.size == pb.size, "the same page on both")
	t.check(pb.stats.triangles >= 0 and pa.triangles() > 0 and pb.triangles() > 0, "with triangles of its own (%d on the Quest 3's, %d on the Quest 2's)" % [pa.triangles(), pb.triangles()])
	t.check(pb.triangles() <= pa.triangles(), "the Quest 2's page is not heavier than the Quest 3's")
	t.eq(sess(A).pdf_share._out.size(), 0, "nothing is left in flight")

	# ---- pages: the owner's turn is everybody's
	var fid: String = pdf_frame(H).id
	bd(H).pdf_turn(fid, 2)
	t.check(await until(func(): return bd(A).doc.page_of(fid) == 2 and bd(B).doc.page_of(fid) == 2), "the owner turns the page: both guests are on page 2")
	t.check(await until(func(): return fa._pdf_key.ends_with(":2") and fb._pdf_key.ends_with(":2") and fa.pdf_state == "ready" and fb.pdf_state == "ready"), "and show it")
	# a guest who may not move canvases turns for themselves only
	t.check(not bd(A).can_edit_pdf_pages(), "a guest may not turn pages for everybody")
	bd(A).pdf_turn(fid, 1)
	await settle(0.3)
	t.check(bd(A).doc.page_of(fid) == 1 and bd(H).doc.page_of(fid) == 2 and bd(B).doc.page_of(fid) == 2, "she looks at page 1 while the others stay on page 2")
	t.check(not bd(A).pdf_is_following(fid), "and knows she is no longer following")
	bd(H).pdf_turn(fid, 1)
	bd(H).pdf_turn(fid, 2)
	await settle(0.3)
	t.eq(bd(A).doc.page_of(fid), 1, "when the owner turns again she stays where she is")
	bd(A).pdf_follow(fid)
	t.check(bd(A).doc.page_of(fid) == 2 and bd(A).pdf_is_following(fid), "and is brought back to the owner's page on request")

	# ---- drawings belong to the page they were drawn on
	var pts := PackedFloat32Array([0.0, 0.0, 0.0, 1.0, 0.1, 0.1, 0.0, 1.0])
	bd(A).pdf_turn(fid, 1)                                      # Ana looks at page 1 and draws there
	var stroke := Item.make_stroke(fid, pts, Color.RED, 0.004, "pen")
	bd(A).history.do(History.op_add([stroke]))
	t.check(await until(func(): return bd(H).doc.items.has(stroke.id) and bd(B).doc.items.has(stroke.id)), "a guest's drawing reaches the owner and the other guest")
	t.eq((bd(H).doc.items[stroke.id] as Item).page, 1, "with the page it was drawn on (the one she looked at, not the owner's)")
	t.eq(bd(H).doc.items_of(fid).size(), 0, "the owner is on page 2: it is not there")
	t.eq(bd(A).doc.items_of(fid).size(), 1, "she sees it on page 1")
	bd(H).pdf_turn(fid, 1)
	await settle(0.3)
	t.check(bd(H).doc.items_of(fid).size() == 1 and bd(B).doc.items_of(fid).size() == 1, "when the owner and Ben turn to page 1 they see it")
	bd(A).pdf_follow(fid)
	bd(H).pdf_turn(fid, 2)

	# ---- a late joiner
	var C := headset("cai", own_doc("Cai's own"))
	sess(C).join("127.0.0.1", port, code, "Cai")
	t.check(await until(func(): return sess(C).phase == "live" and bd(C).doc == sess(C).client_doc), "a guest joins late")
	t.check(await until(func(): return bd(C).pdfs.has(pdf_id) and pdf_frame(C) != null), "and is given the PDF as well")
	var fc: FrameNode = bd(C).frame_nodes[pdf_frame(C).id]
	t.check(await until(func(): return fc.pdf_state == "ready"), "and sees it (page %d)" % bd(C).doc.page_of(fid))
	t.eq(bd(C).doc.page_of(fid), 2, "on the owner's page")

	# ---- a Quest 2 that cannot take a big file says so, the others get it
	bd(B).pdfs.budget.max_file_mb = 0                           # (a tiny allowance, so that a small test file is "too big")
	var big_bytes := FileAccess.get_file_as_bytes(FIX + "embedded.pdf")
	var big := bd(H).pdfs.add(big_bytes, "Pictures.pdf")
	bd(H).place_pdf(str(big.id))
	t.check(await until(func(): return bd(A).pdfs.has(str(big.id)) and bd(C).pdfs.has(str(big.id))), "a second PDF goes to the guests who can take it")
	await settle(0.4)
	t.check(not bd(B).pdfs.has(str(big.id)), "the headset that cannot take it does not")
	var note: String = bd(B).pdfs.state_text(str(big.id))
	t.check(note.contains("too big"), "and says why: \"%s\"" % note)
	var fb2: FrameNode = null
	for f in bd(B).doc.frames.values():
		if (f as FrameData).pdf == str(big.id):
			fb2 = bd(B).frame_nodes[(f as FrameData).id]
	t.check(fb2 != null and fb2.pdf_state == "missing" and fb2.pdf_note.contains("too big"), "the canvas on that headset says so too")
	t.check(not (sess(B).pdf_share._in.has(str(big.id))), "nothing of it was kept")

	# ---- only what a canvas shows can be fetched
	var secret := bd(H).pdfs.add(FileAccess.get_file_as_bytes(FIX + "many.pdf"), "Private.pdf")
	var sid := str(secret.id)
	sess(A).net.send(SessionNet.SERVER, {"t": "pdf?", "id": sid}, SessionNet.CH_FILE)
	sess(A).pdf_share._asked[sid] = true
	await settle(0.5)
	t.check(not bd(A).pdfs.has(sid), "a PDF no canvas of the session shows cannot be asked for")
	t.check(bd(A).pdfs.state_text(sid).contains("not part of the session"), "the guest is told so: \"%s\"" % bd(A).pdfs.state_text(sid))

	# ---- a damaged file is not kept
	var share: PdfShare = sess(A).pdf_share
	var fake_id := PdfLibrary.id_of(FileAccess.get_file_as_bytes(FIX + "stray_byte.pdf"))
	share._asked[fake_id] = true
	share.client_msg({"t": "pdf", "id": fake_id, "n": 1, "size": 100, "name": "Fake"})
	share.client_msg({"t": "pdfc", "id": fake_id, "i": 0, "d": PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9])})
	t.check(not bd(A).pdfs.has(fake_id), "bytes that are not the file whose id was asked for are not taken in")
	t.check(bd(A).pdfs.state_text(fake_id).contains("damaged"), "and the guest is told: \"%s\"" % bd(A).pdfs.state_text(fake_id))

	# ---- leaving: the copies from the session stay while there is room
	sess(C).leave()
	await settle(0.3)
	t.check(bd(C).pdfs.has(pdf_id), "a guest who leaves keeps the PDF copies (up to a few) until they are needed no more")
	t.eq(sess(H).guest_count(), 2, "the owner sees two guests left")
