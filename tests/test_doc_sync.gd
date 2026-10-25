extends Node
## Replication of a document: what changed is remembered from the document's own signals, sent as state, applied on the other side
## without echoing, and only the shared room goes over.

var t := TestCase.new("doc_sync")


func _ready() -> void:
	var host := make_host()
	var a: Document = host.doc
	var sa := DocSync.new()
	sa.attach(a, "r1")
	# ---- a joining headset gets the shared room as a document of its own
	var wire := DocSync.pack(sa.snapshot())
	t.check(wire.size() > 0, "the snapshot packs")
	var snap := DocSync.unpack(wire)
	t.check(not snap.is_empty(), "...and unpacks")
	var b := Document.from_dict(snap)
	b.transient = true
	var sb := DocSync.new()
	sb.attach(b, "r1")
	t.eq(b.frames.size(), 2, "both frames of the shared room arrive (not the other room's)")
	t.check(not b.frames.has("f_other"), "the other room stays at home")
	t.eq(b.rooms.size(), 1, "one room")
	t.eq(b.items.size(), 5, "the items of the shared frames arrive, the other room's do not")
	t.eq((b.frames["f1"] as FrameData).anchor, "", "a spatial anchor never leaves the device that made it")
	t.eq((a.frames["f1"] as FrameData).anchor, "meta-anchor-1", "...and the host keeps its own")
	for id in b.items:
		t.eq((b.items[id] as Item).to_dict(), (a.items[id] as Item).to_dict(), "item %s arrives as it is" % id)
	t.eq((b.frames["f1"] as FrameData).xf, (a.frames["f1"] as FrameData).xf, "a frame keeps its pose")
	t.check(not sa.is_dirty() and not sb.is_dirty(), "nothing is pending after a snapshot")
	t.check(b.save() == OK and not FileAccess.file_exists("%s/%s.mrw" % [App.docs_dir, b.id]), "a joined copy is never written to the documents folder")

	# ---- the host changes things: a recolour, a new item, a removal
	var stroke: Item = a.items["i_stroke"]
	var recolored := stroke.duplicate_item(false)
	recolored.color = Color("#ef476f")
	a.replace_item(recolored)
	var added := Item.make_shape("f1", "ellipse", Color.WHITE, 0.004)
	added.center = Vector2(0.4, 0.2)
	a.add_item(added)
	a.remove_item("i_text")
	t.check(sa.is_dirty(), "edits are noticed")
	var batch := sa.take_batch()
	t.check(not sa.is_dirty(), "taking the batch clears it")
	t.eq((batch.items as Array).size(), 2, "two items changed")
	t.eq((batch.gone_items as Array), ["i_text"], "one is gone")
	t.check(not batch.has("frames") and not batch.has("gone_frames"), "no frame changed")
	var res := sb.apply(batch)
	t.eq(res.items, 2, "both arrive")
	t.eq(res.gone, 1, "the removal arrives")
	t.check(not sb.is_dirty(), "what was only told is not sent back")
	t.eq((b.items["i_stroke"] as Item).color.to_html(), Color("#ef476f").to_html(), "the recolour shows")
	t.check(b.items.has(added.id) and not b.items.has("i_text"), "added and removed")
	t.eq(b.items.size(), a.items.size() - 1, "same number of items (the other room's is only on the host)")

	# ---- a guest draws: the host applies it and passes it on
	var line := Item.make_shape("f1", "line", Color.WHITE, 0.004)
	line.a = Vector2(0, 0)
	line.b = Vector2(0.3, 0.1)
	line.glue_a = {"item": "i_rect", "port": 1}
	b.add_item(line)
	var sbatch := sb.take_batch()
	t.eq((sbatch.items as Array).size(), 1, "the guest's stroke is the one change")
	var hres := sa.apply(sbatch, true)
	t.eq(hres.items, 1, "the host takes it")
	t.check(a.items.has(line.id), "it is in the host's document")
	t.check(sa.is_dirty(), "and, being new to the host, it is passed on to the others")
	t.eq((a.items[line.id] as Item).glue_a, {"item": "i_rect", "port": 1}, "a connector keeps what it is glued to")
	t.eq(sa.take_batch().items.size(), 1, "exactly that one")

	# ---- a frame moves; the host's anchor stays the host's
	var moved := (b.frames["f1"] as FrameData).copy()
	moved.xf = Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 1.5, -2))
	b.replace_frame(moved)
	var fb := sb.take_batch()
	t.eq((fb.frames as Array).size(), 1, "the frame is in the batch")
	t.eq((fb.frames[0] as Dictionary).anchor, "", "...without an anchor")
	sa.apply(fb, true)
	var af: FrameData = a.frames["f1"]
	t.check(af.xf.origin.is_equal_approx(Vector3(1, 1.5, -2)), "the frame moved on the host")
	t.eq(af.anchor, "meta-anchor-1", "the host's anchor is still the host's, so it is re-made at the new place by its own board")
	sa.take_batch()

	# ---- the other room is not shared
	var other: Item = a.items["i_other"]
	var o2 := other.duplicate_item(false)
	o2.color = Color.RED
	a.replace_item(o2)
	t.check(not sa.is_dirty(), "an edit in another room is not passed on")
	a.add_item(Item.make_stroke("f_other", PackedFloat32Array([0, 0, 0, 0.5, 0.1, 0.1, 0, 0.5]), Color.WHITE, 0.004, "pen"))
	t.check(not sa.is_dirty(), "nor is a new item there")

	# ---- a frame is deleted with everything on it
	a.remove_frame("f2")
	var rb := sa.take_batch()
	t.eq(rb.gone_frames, ["f2"], "the frame is gone")
	t.check((rb.gone_items as Array).size() >= 1, "so are its items")
	sb.apply(rb)
	t.check(not b.frames.has("f2"), "the other headset's frame goes too")
	t.check(not b.items.has("i_on_f2"), "...with its items")
	t.check(not sb.is_dirty(), "and nothing is echoed")

	# ---- the truth about some ids
	var truth := sa.state_of(["i_stroke", "i_nowhere", "f1", "f2"])
	t.eq((truth.items as Array).size(), 1, "an item that exists is described")
	t.eq((truth.frames as Array).size(), 1, "a frame that exists is described")
	t.check((truth.gone_items as Array).has("i_nowhere") and (truth.gone_items as Array).has("f2"), "what does not exist is declared gone")

	# ---- rubbish is skipped, not trusted
	var junk := {"items": [5, "x", {}, {"id": ""}, {"id": "i_ghost", "kind": "stroke", "frame": "f_nowhere"}, {"id": "i_ok", "kind": "stroke", "frame": "f1", "pts": ""}],
		"frames": [7, {"id": "f_wrong_room", "room": "r_elsewhere"}], "gone_items": [1, null, "i_nothing"], "gone_frames": ["f_nothing"]}
	var jr := sb.apply(junk)
	t.eq(jr.items, 1, "only the one well-formed item with a real frame is taken")
	t.check(jr.skipped >= 5, "the rest is skipped (%d)" % jr.skipped)
	t.check(not b.frames.has("f_wrong_room"), "a frame of another room is not taken")
	t.eq(sb.apply({"items": "x", "frames": 3}).items, 0, "a list that is not a list is ignored")
	var many: Array = []
	for i in DocSync.MAX_BATCH_ITEMS + 10:
		many.append({"id": "i_m%d" % i, "kind": "stroke", "frame": "f1", "pts": ""})
	var mr := sb.apply({"items": many})
	t.eq(mr.items, DocSync.MAX_BATCH_ITEMS, "a batch is only taken up to a limit")
	for i in DocSync.MAX_BATCH_ITEMS + 10:
		b.remove_item("i_m%d" % i)
	t.check(DocSync.unpack(PackedByteArray([1, 2, 3, 4, 5])).is_empty(), "garbage does not unpack")
	t.check(DocSync.unpack(PackedByteArray()).is_empty(), "nor does nothing")
	t.check(DocSync.unpack("{\"format\":\"other\"}".to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)).is_empty(), "nor another kind of file")

	# ---- the same order on every headset, also for equal z
	var d := Document.create("order")
	var fr := FrameData.make(FrameData.CANVAS, "r1", Transform3D.IDENTITY)
	d.add_frame(fr)
	for id in ["i_c", "i_a", "i_b"]:
		var it := Item.make_stroke(fr.id, PackedFloat32Array([0, 0, 0, 0.5]), Color.WHITE, 0.004, "pen")
		it.id = id
		it.z = 7
		d.add_item(it)
	var order: Array = []
	for it in d.items_of(fr.id):
		order.append((it as Item).id)
	t.eq(order, ["i_a", "i_b", "i_c"], "items of equal height stack in the same order everywhere (by id)")
	sa.detach()
	sb.detach()
	t.check(not sa.is_dirty(), "detached: nothing is watched")
	get_tree().quit(t.done())


## A host document: two rooms. Room r1 (shared) has frames f1 (with a spatial anchor) and f2; room r2 has frame f_other.
func make_host() -> Dictionary:
	App.docs_dir = "user://test_docs_sync"
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	var doc := Document.create("Host document")
	doc.add_room("Studio")
	doc.rooms[0].id = "r1"
	doc.rooms[0].anchor = "meta-room-anchor"
	doc.add_room("Home")
	doc.rooms[1].id = "r2"
	for spec in [["f1", "r1"], ["f2", "r1"], ["f_other", "r2"]]:
		var f := FrameData.make(FrameData.CANVAS, spec[1], Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1)))
		f.id = spec[0]
		if spec[0] == "f1":
			f.anchor = "meta-anchor-1"
			f.anchor_xf = f.xf
		doc.add_frame(f)
	var stroke := Item.make_stroke("f1", PackedFloat32Array([0, 0, 0, 0.5, 0.1, 0.05, 0, 0.6, 0.2, 0.0, 0, 0.7]), Color("#ffd166"), 0.004, "pen")
	stroke.id = "i_stroke"
	doc.add_item(stroke)
	var rect := Item.make_shape("f1", "rect", Color.WHITE, 0.004)
	rect.id = "i_rect"
	rect.center = Vector2(0.5, 0.3)
	doc.add_item(rect)
	var text := Item.make_text("f1", "Floor plan", Color.WHITE, 0.06)
	text.id = "i_text"
	text.center = Vector2(0.2, 0.6)
	doc.add_item(text)
	var on2 := Item.make_shape("f2", "ellipse", Color.WHITE, 0.004)
	on2.id = "i_on_f2"
	doc.add_item(on2)
	var on2b := Item.make_text("f2", "second", Color.WHITE, 0.05)
	on2b.id = "i_on_f2b"
	doc.add_item(on2b)
	var other := Item.make_shape("f_other", "rect", Color.WHITE, 0.004)
	other.id = "i_other"
	doc.add_item(other)
	return {"doc": doc}
