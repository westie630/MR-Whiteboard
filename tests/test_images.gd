extends Node
## Pictures on canvases: the library (PNG, JPEG, WebP, what is refused, a phone photo turned upright from its EXIF orientation, the texture fitted to
## a Quest 2's or a Quest 3's budget), the picture item (save, load, bounds, picking, move / turn / scale), the placement tool on a real board
## (the ghost follows the pen over a canvas, a tap drops it, undo), the view (a textured quad; a box while it is missing), the SVG export (the
## file embedded), the web page (upload into the headset's hand, dropped straight on a canvas at a spot, the list, open, rename, delete) and a
## session: an owner and two guests (one on a Quest 2's budget) as real boards over real connections, the owner's picture going to both guests and a
## guest's own picture going to the owner first and from there to the other guest.

const HEAD := {"x-requested-with": "mrw"}

var t := TestCase.new("images")
var heads: Array = []


func _ready() -> void:
	App.settings_path = "user://test_settings_images.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(App.settings_path))
	App.reload()
	App.docs_dir = "user://test_docs_images"
	App.image_dir = "user://test_images_lib"
	_clean(App.docs_dir)
	_clean(App.image_dir)
	_library()
	_item()
	await _board()
	await _session()
	for h in heads:
		(h.board as Board).session.net.close()
	for d in [App.docs_dir, App.image_dir, "user://test_images_owner", "user://test_images_ana", "user://test_images_ben"]:
		_clean(d)
	get_tree().quit(t.done())


func _clean(dir: String) -> void:
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


## A w x h picture, red in its top left corner, blue elsewhere.
static func picture(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 1))
	img.fill_rect(Rect2i(0, 0, maxi(w / 4, 1), maxi(h / 4, 1)), Color(1, 0, 0))
	return img


static func png(w: int, h: int) -> PackedByteArray:
	return picture(w, h).save_png_to_buffer()


## A JPEG with an EXIF block that says "turn it a quarter clockwise to show it" (orientation 6), as a phone stores a photo taken upright.
static func jpeg_on_its_side(w: int, h: int, orientation: int = 6) -> PackedByteArray:
	var jpg := picture(w, h).save_jpg_to_buffer(0.95)
	var tiff := PackedByteArray([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0, 0, 0, 0, 0])
	var body := "Exif".to_ascii_buffer()
	body.append_array(PackedByteArray([0, 0]))
	body.append_array(tiff)
	var seg := PackedByteArray([0xFF, 0xE1, (body.size() + 2) >> 8, (body.size() + 2) & 0xFF])
	seg.append_array(body)
	var out := jpg.slice(0, 2)
	out.append_array(seg)
	out.append_array(jpg.slice(2))
	return out


# ------------------------------------------------------------------------------------------------ library

func _library() -> void:
	var lib := ImageLibrary.new()
	lib.dir = "user://test_images_lib_unit"
	_clean(lib.dir)
	lib.threaded = false
	add_child(lib)
	var a := png(40, 20)
	var r := lib.add(a, "Plan.PNG")
	t.check(bool(r.ok) and str(r.name) == "Plan" and int(r.w) == 40 and int(r.h) == 20, "a PNG is taken in: %s" % r.message)
	t.eq(str(r.id), ImageLibrary.id_of(a), "named by its content")
	t.check(bool(lib.add(a, "again.png").dup), "the same picture twice is one file")
	t.near(lib.aspect(str(r.id)), 2.0, 1e-6, "its shape is known")
	t.check(lib.file_bytes(str(r.id)) == a, "kept as it was sent")
	var side := jpeg_on_its_side(40, 20)
	t.eq(ImageLibrary.jpeg_orientation(side), 6, "the EXIF orientation is read")
	var rj := lib.add(side, "photo.jpg")
	t.check(bool(rj.ok) and int(rj.w) == 20 and int(rj.h) == 40, "a phone photo stored on its side is turned upright (%dx%d)" % [int(rj.get("w", 0)), int(rj.get("h", 0))])
	var up := ImageLibrary.decode(side)
	t.check(up.get_pixel(up.get_width() - 1, 0).r > 0.7, "turned clockwise: the red corner is now top right")
	var webp := picture(16, 16).save_webp_to_buffer(true)
	t.check(bool(lib.add(webp, "w.webp").ok), "WebP is taken")
	var gif := "GIF89a".to_ascii_buffer()
	gif.resize(64)
	t.check(not bool(lib.add(gif, "a.gif").ok) and str(lib.add(gif, "a.gif").message).contains("GIF"), "a GIF is refused, saying what to do")
	var heic := PackedByteArray([0, 0, 0, 24])
	heic.append_array("ftypheic".to_ascii_buffer())
	heic.resize(64)
	t.check(str(lib.add(heic, "IMG_1.HEIC").message).contains("HEIC"), "an iPhone HEIC is refused, saying how to send it")
	t.check(str(lib.add('<svg xmlns="http://www.w3.org/2000/svg"></svg>'.to_utf8_buffer(), "x.svg").message).contains("canvas"), "an SVG is sent to the SVG import")
	t.check(not bool(lib.add("hello world, not a picture".to_utf8_buffer(), "x.png").ok), "a file that is not a picture is refused")
	# the texture: made when asked for, mipmapped, no bigger than the budget
	var ready := []
	lib.image_ready.connect(func(id: String): ready.append(id))
	t.eq(lib.texture(str(r.id)), null, "the first ask starts making the texture")
	t.check(ready.has(str(r.id)), "and says when it is ready")
	var tex := lib.texture(str(r.id))
	t.check(tex != null and tex.get_width() == 40, "then it is there")
	t.check(tex != null and (tex as ImageTexture).get_image().has_mipmaps(), "with mipmaps (smooth from far away)")
	lib.tier = "low"
	var wide := lib.add(png(3000, 30), "wide.png")
	lib.texture(str(wide.id))
	var wt := lib.texture(str(wide.id))
	t.check(wt != null and wt.get_width() == 2048, "a Quest 2 makes a picture's texture at most 2048 px (%d)" % (wt.get_width() if wt != null else 0))
	lib.tier = "high"
	t.eq(lib.texture("0123456789abcdef0123456789abcdef"), null, "a picture that is not here has no texture...")
	t.check(lib.state_text("0123456789abcdef0123456789abcdef").contains("not on this headset"), "...and says why")
	t.check(lib.remove(str(r.id)) and not lib.has(str(r.id)), "a picture can be removed")
	lib.queue_free()
	_clean("user://test_images_lib_unit")


# ------------------------------------------------------------------------------------------------ item

func _item() -> void:
	var it := Item.make_image("f1", "abc", Vector2(0.4, 0.2))
	it.center = Vector2(1.0, 0.5)
	it.rot = 0.3
	var back := Item.from_dict(JSON.parse_string(JSON.stringify(it.to_dict())))
	t.check(back.kind == Item.IMAGE and back.image == "abc" and back.size.is_equal_approx(Vector2(0.4, 0.2)) and back.center.is_equal_approx(Vector2(1.0, 0.5)) and absf(back.rot - 0.3) < 1e-4, "a picture item saves and loads")
	t.check(it.hit(Vector2(1.0, 0.5), 0.001) and not it.hit(Vector2(1.5, 0.5), 0.001), "it is picked inside its box only")
	t.check(it.bounds().has_point(Vector2(1.18, 0.55)), "its bounds cover the turned box")
	var s := it.duplicate_item()
	s.apply_xform(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO))
	t.check(s.size.is_equal_approx(Vector2(0.8, 0.4)) and s.center.is_equal_approx(Vector2(2.0, 1.0)), "resizing scales it about the corner dragged")


# ------------------------------------------------------------------------------------------------ board, view, export, web page

func _board() -> void:
	var anchors := SimAnchors.new("user://test_sim_anchors_images.json")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_images.json"))
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	board.images.threaded = false
	var doc := Document.create("Pictures")
	doc.add_room("Studio")
	board.open(doc)
	for i in 6:
		await get_tree().process_frame
		board.tick(PenState.new(), [], 0.016)
	var fd := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.0)), Vector2(1.2, 0.8))
	t.check(fd != null, "a canvas to drop on")
	var added := board.add_image(png(400, 200), "Map.png")
	t.check(bool(added.ok) and board.placing_text.get("image", "") == str(added.id), "a new picture goes into the placement tool: %s" % added.message)
	var pid := str(added.id)
	for i in 4:
		await get_tree().process_frame
		board.tick(PenState.new(), [], 0.016)                # (the canvas takes its place in the room)
	# the pen points at the canvas: the ghost follows, a tap drops it there
	var pen := PenState.new()
	pen.tracked = true
	pen.source = "stylus"
	var fn: FrameNode = board.frame_nodes[fd.id]
	var aim := fn.to_world_point(Vector3(0.2, 0.1, 0.0))
	pen.tip = aim + Vector3(0, 0, 0.3)
	pen.dir = (aim - pen.tip).normalized()
	board.tick(pen, [], 0.016)
	t.eq(str(board.placing_text.frame), fd.id, "the ghost is over the canvas pointed at")
	t.check((board.placing_text.center as Vector2).distance_to(Vector2(0.2, 0.1)) < 0.01, "centred where the pen points")
	var ghost: Item = board.placing_text.item
	t.check(ghost != null and ghost.kind == Item.IMAGE and absf(ghost.size.x / ghost.size.y - 2.0) < 0.01 and absf(ghost.size.x - 0.4) < 0.01, "a ghost of the picture's own shape, 40 cm wide")
	pen.down = true
	board.tick(pen, [], 0.016)
	pen.down = false
	board.tick(pen, [], 0.016)
	var pics: Array = []
	for it in doc.items_of(fd.id):
		if (it as Item).kind == Item.IMAGE:
			pics.append(it)
	t.eq(pics.size(), 1, "a tap drops the picture on the canvas")
	t.check(board.placing_text.is_empty(), "and ends the tool")
	var pic: Item = pics[0] if not pics.is_empty() else Item.new()
	t.check(pic.image == pid and pic.center.distance_to(Vector2(0.2, 0.1)) < 0.01, "where the ghost was")
	t.eq(board.selection, [pic.id], "selected, to move and resize")
	# the view: a textured quad under the ink
	var view := fn.view_of(pic.id)
	var mat: ShaderMaterial = null
	if view != null:
		for c in view.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).material_override is ShaderMaterial:
				mat = (c as MeshInstance3D).material_override
	t.check(mat != null and str(mat.shader.resource_path).ends_with("image_canvas.gdshader") and mat.get_shader_parameter("tex") is Texture2D, "it is shown as a textured picture")
	t.check(mat != null and mat.render_priority < Brushes.priority("pen", pic.z), "under the ink (drawings on it stay on top)")
	board.recolor_selection(Color(1, 0, 0))
	t.check((doc.items[pic.id] as Item).color == Color.WHITE, "recolouring leaves a picture as it is")
	board.history.undo()
	t.check(not doc.items.has(pic.id), "undo takes it back")
	board.history.redo()
	t.check(doc.items.has(pic.id), "redo brings it back")
	# where I look; Back cancels
	board.begin_place_image(pid)
	board.cancel_place_text()
	t.check(board.placing_text.is_empty(), "the tool can be cancelled")
	# a picture whose file is not here: a box that says so
	var lost := Item.make_image(fd.id, "fedcba9876543210fedcba9876543210", Vector2(0.3, 0.2))
	board.history.do(History.op_add([lost]))
	var lv := fn.view_of(lost.id)
	var said := false
	for c in lv.get_children():
		if c is Label3D and (c as Label3D).text.contains("not on this headset"):
			said = true
	t.check(said, "a picture not on this headset is a box that says so")
	board.history.undo()
	# SVG export: the file embedded
	var svg := SvgExport.canvas(doc, fd.id, {"images": board.images})
	var at := svg.find("data:image/png;base64,")
	t.check(svg.contains("<image ") and at > 0, "the SVG has the picture in it")
	if at > 0:
		var b64 := svg.substr(at + 22, svg.find("\"", at) - at - 22)
		t.check(Marshalls.base64_to_raw(b64) == board.images.file_bytes(pid), "byte for byte")
	t.check(SvgExport.canvas(doc, fd.id).contains("data:image/png;base64,"), "also without being handed the library (the app's own folder)")
	# the web page
	var srv := board.share
	srv.require_pin = false
	var up := _post(srv, "/api/image?name=Sketch.jpg", picture(60, 30).save_jpg_to_buffer())
	t.check(bool(up.ok) and board.placing_text.has("image"), "an upload goes into the headset's hand: %s" % up.message)
	board.cancel_place_text()
	var before := doc.items_of(fd.id).size()
	var r := SvgExport.view_rect(doc, fd.id)
	var dropped := _post(srv, "/api/image?name=Logo.png&canvas=%s&fx=0.25&fy=0.75" % fd.id, png(50, 50))
	t.check(bool(dropped.ok) and doc.items_of(fd.id).size() == before + 1, "a picture dropped on a canvas's picture is put on that canvas: %s" % dropped.message)
	var newest: Item = null
	for it in doc.items_of(fd.id):
		if newest == null or (it as Item).z > newest.z:
			newest = it
	var want := Vector2(r.position.x + 0.25 * r.size.x, r.end.y - 0.75 * r.size.y)
	t.check(newest != null and newest.kind == Item.IMAGE and newest.center.distance_to(want) < 0.001, "at the spot it was dropped on")
	t.check(board.placing_text.is_empty(), "without the headset having to do anything")
	var page := (srv.route("/").body as PackedByteArray).get_string_from_utf8()
	t.check(page.contains("id=images") and page.contains("Logo") and page.contains("data-act=img-show"), "the dashboard lists the pictures")
	var got := srv.route("/image/%s" % ImageLibrary.id_of(png(50, 50)))
	t.check(int(got.status) == 200 and str(got.type) == "image/png" and got.body == png(50, 50), "a picture can be opened from the page")
	t.check(not bool(_post(srv, "/api/image?name=x.gif", "GIF89a__________".to_ascii_buffer()).ok), "the page is told when a file is refused")
	var lid := ImageLibrary.id_of(png(50, 50))
	t.check(bool(_post(srv, "/api/image/rename", JSON.stringify({"id": lid, "name": "Our logo"}).to_utf8_buffer()).ok) and str(board.images.entry(lid).name) == "Our logo", "renamed from the page")
	t.check(bool(_post(srv, "/api/image/show", JSON.stringify({"id": lid}).to_utf8_buffer()).ok) and board.placing_text.get("image", "") == lid, "Drop in headset starts the tool")
	board.cancel_place_text()
	t.check(bool(_post(srv, "/api/image/delete", JSON.stringify({"ids": [lid]}).to_utf8_buffer()).ok) and not board.images.has(lid), "deleted from the page")
	t.eq(srv._body_limit("POST /api/image?name=a.png HTTP/1.1"), 32 * 1048576, "pictures up to this headset's limit come through the page")
	t.check(srv.route("/svg/%s.svg" % fd.id).body.size() > 0, "the canvas with pictures is still served")


func _post(srv: ExportServer, path: String, body: PackedByteArray) -> Dictionary:
	var res := srv.handle("POST", path, HEAD, body, "x")
	var parsed: Variant = JSON.parse_string((res.body as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Dictionary else {"ok": false, "message": "not JSON"}


# ------------------------------------------------------------------------------------------------ session

func headset(who: String, doc: Document, tier: String = "high") -> Dictionary:
	_clean("user://test_images_%s" % who)
	App.image_dir = "user://test_images_%s" % who
	var path := "user://test_sim_anchors_images_%s.json" % who
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var anchors := SimAnchors.new(path)
	add_child(anchors)
	var board := Board.new()
	add_child(board)
	board.setup(anchors)
	board.images.threaded = false
	board.images.tier = tier
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


func bd(h: Dictionary) -> Board:
	return h.board


func sess(h: Dictionary) -> Session:
	return (h.board as Board).session


func view_tex(h: Dictionary, item_id: String) -> Texture2D:
	for fn in bd(h).frame_nodes.values():
		var v := (fn as FrameNode).view_of(item_id)
		if v != null:
			for c in v.get_children():
				if c is MeshInstance3D and (c as MeshInstance3D).material_override is ShaderMaterial:
					var tx: Variant = ((c as MeshInstance3D).material_override as ShaderMaterial).get_shader_parameter("tex")
					if tx is Texture2D:
						return tx
	return null


func _session() -> void:
	var shared := Document.create("Moodboard")
	var room := shared.add_room("Studio", "", Transform3D.IDENTITY)
	room.id = "r_studio"
	shared.last_room = "r_studio"
	var H := headset("owner", shared)
	var mine := DocStore.create_new("Ana's own")
	mine.add_room("Mine", "", Transform3D.IDENTITY)
	var A := headset("ana", mine)
	var mine2 := DocStore.create_new("Ben's own")
	mine2.add_room("Mine", "", Transform3D.IDENTITY)
	var B := headset("ben", mine2, "low")
	await until(func(): return bd(H).current_room != "" and bd(H).room_state == "found")
	for h in heads:
		sess(h).image_share.rate = 1e9
	t.eq(sess(H).start_hosting("Lee", "Moodboard", true), OK, "a session starts")
	sess(A).join("127.0.0.1", sess(H).net.port, sess(H).code, "Ana")
	sess(B).join("127.0.0.1", sess(H).net.port, sess(H).code, "Ben")
	t.check(await until(func(): return sess(A).phase == "live" and sess(B).phase == "live"), "two guests are in (one on a Quest 2's budget)")
	var fd := bd(H).add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.0)), Vector2(1.2, 0.8))
	t.check(fd != null and await until(func(): return bd(A).doc.frames.has(fd.id) and bd(B).doc.frames.has(fd.id)), "the owner's canvas reaches both guests")
	# the owner's picture: the file goes to each guest once
	var big := png(2600, 1300)
	var oid := str(bd(H).images.add(big, "Wide.png").id)
	var it := bd(H).place_image_at(oid, fd.id, Vector2(-0.2, 0.0))
	t.check(it != null, "the owner drops a picture")
	t.check(await until(func(): return bd(A).images.has(oid) and bd(B).images.has(oid)), "its file reaches both guests")
	t.check(bd(A).images.file_bytes(oid) == big, "byte for byte")
	t.check(await until(func(): return view_tex(A, it.id) != null and view_tex(B, it.id) != null), "both guests show it")
	t.eq(view_tex(A, it.id).get_width(), 2600, "a Quest 3 at full size")
	t.eq(view_tex(B, it.id).get_width(), 2048, "a Quest 2 at its own budget's size")
	# a guest's own picture: offered to the owner, then given to the other guest
	var mine_pic := png(120, 80)
	var gid := str(bd(A).images.add(mine_pic, "Ana's sketch.png").id)
	var gi := bd(A).place_image_at(gid, fd.id, Vector2(0.3, 0.1))
	t.check(gi != null, "a guest drops a picture of their own")
	t.check(await until(func(): return bd(H).images.has(gid)), "its file goes to the owner")
	t.check(await until(func(): return bd(B).images.has(gid) and view_tex(B, gi.id) != null), "and from there to the other guest, who shows it")
	t.check(await until(func(): return view_tex(H, gi.id) != null), "the owner shows it too")
	t.check(not bool(bd(H).images.entry(gid).get("cached", true)), "the owner keeps it as its own (its document shows it)")
	# a guest asks for a picture nothing shows: refused
	var stray := str(bd(H).images.add(png(10, 10), "secret.png").id)
	bd(B).images.want(stray)
	await until(func(): return false, 0.4)
	t.check(not bd(B).images.has(stray), "a guest is never given a picture the session does not show")
