extends Node
## The curved desk: the bend's maths (a sheet curved round a cylinder: lengths kept, inverse and ray hits agree), cutting geometry into
## strips, a curved canvas made with the stylus nib on a level desk, drawing on its flat part, bend and wall, carrying its contents along the
## surface, the two markers (distance and radius), curving and flattening a canvas that is already on the desk, and the file. The hands:
## a ray or a touch slides the contents (up the wall, back down it, pushed on through the bend, traced along it), the bar carries the desk,
## two hands turn it.

var board: Board
var anchors: SimAnchors
var pen := PenState.new()
var hands: Array = []
var t := TestCase.new("bend")

var p0 := Vector3(0.2, 0.75, -0.7)             # a level desk


func _ready() -> void:
	App.settings_path = "user://test_settings.cfg"
	App.reload()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_bend.json"))
	anchors = SimAnchors.new("user://test_sim_anchors_bend.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	App.put("sim_room", "A")
	board.open(Document.create("Bend test"))
	await run()
	get_tree().quit(t.done())


func tick(n: int = 1, dt: float = 0.016) -> void:
	for i in n:
		board.tick(pen, hands, dt)
		await get_tree().process_frame


func on_desk(x: float, z: float) -> Vector3:
	return Vector3(p0.x + x, p0.y, p0.z + z)


func tap(p: Vector3, frames: int = 10) -> void:
	pen.tracked = true
	pen.source = "stylus"
	pen.tip = p
	pen.contact = true
	pen.down = true
	pen.pressure = 0.5
	await tick(frames)
	pen.contact = false
	pen.down = false
	pen.pressure = 0.0
	await tick(2)


## Move the nib along some world points, pressed (`down`) or not, and lift it.
func drag(points: Array, down: bool = true, front: bool = false) -> void:
	pen.tracked = true
	pen.source = "stylus"
	pen.tip = points[0]
	pen.down = false
	pen.front = false
	await tick(2)
	pen.down = down
	pen.front = front
	pen.pressure = 0.6
	for p in points:
		pen.tip = p
		await tick(1)
	await tick(2)
	pen.down = false
	pen.front = false
	pen.pressure = 0.0
	await tick(3)


func line(a: Vector3, b: Vector3, n: int) -> Array:
	var out: Array = []
	for i in n + 1:
		out.append(a.lerp(b, float(i) / n))
	return out


func strokes_of(frame_id: String) -> Array:
	var out: Array = []
	for it in board.doc.items.values():
		if (it as Item).kind == Item.STROKE and (it as Item).frame == frame_id:
			out.append(it)
	return out


func run() -> void:
	App.put("tool", "draw")
	App.put("recognize", "off")
	App.put("brush", "pen")
	App.put("width", 0.004)
	await tick(100)
	t.eq(board.room_state, "found", "the room is found")

	# ---- the mapping: a sheet round a cylinder
	var b := DeskBend.new(0.4, 0.15, Vector2.ZERO, Rect2(Vector2(-0.5, 0.0), Vector2(1.0, 1.5)))
	var s_wall := 0.4 + 0.15 * PI / 2.0
	t.check(b.to_node(Vector3(0.1, 0.2, 0.0)).is_equal_approx(Vector3(0.1, 0.2, 0.0)), "the near part is flat on the desk")
	t.check(b.to_node(Vector3(0.0, 0.4, 0.0)).is_equal_approx(Vector3(0.0, 0.4, 0.0)), "...up to the distance the bend starts at")
	t.check(b.to_node(Vector3(0.0, s_wall, 0.0)).is_equal_approx(Vector3(0.0, 0.55, 0.15)), "the bend ends a radius up and a radius on: %s" % str(b.to_node(Vector3(0.0, s_wall, 0.0))))
	t.check(b.to_node(Vector3(0.0, s_wall + 0.3, 0.0)).is_equal_approx(Vector3(0.0, 0.55, 0.45)), "then the wall runs straight up")
	t.check(b.to_node(Vector3(0.0, s_wall + 0.3, 0.02)).is_equal_approx(Vector3(0.0, 0.53, 0.45)), "...and height off the surface is towards you")
	var arc45 := b.to_node(Vector3(0.0, 0.4 + 0.15 * PI / 4.0, 0.0))
	t.near(arc45.y, 0.4 + 0.15 * sin(PI / 4.0), 1e-6, "halfway round the bend (y)")
	t.near(arc45.z, 0.15 * (1.0 - cos(PI / 4.0)), 1e-6, "...(z)")
	# lengths along the surface are kept (it is not stretched): walk along it in small steps
	var walked := 0.0
	var prev := b.to_node(Vector3(0.0, -0.1, 0.0))
	var s := -0.1
	while s < 1.3:
		s += 0.0005
		var cur := b.to_node(Vector3(0.0, s, 0.0))
		walked += cur.distance_to(prev)
		prev = cur
	t.near(walked, 1.4, 0.0005, "a line along the surface keeps its length through the bend and up the wall")
	# the inverse
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 400:
		var c := Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.3, 1.4), rng.randf_range(-0.05, 0.05))
		var back := b.from_node(b.to_node(c))
		worst = maxf(worst, back.distance_to(c))
	t.check(worst < 1e-5, "node space and canvas space convert back and forth exactly: worst %f" % worst)
	var pan := DeskBend.new(0.4, 0.15, Vector2(0.1, 0.3), Rect2(Vector2(-0.5, 0.0), Vector2(1.0, 1.5)))
	t.check(pan.to_node(Vector3(0.0, 0.0, 0.0)).is_equal_approx(Vector3(0.1, 0.3, 0.0)), "the pan is how far the contents have slid along the surface")
	t.check(pan.canvas_window().position.is_equal_approx(Vector2(-0.6, -0.3)), "...so the shown part is the other way in canvas coordinates")
	# the zoom: the contents shown bigger on the same surface
	var zb := DeskBend.new(0.4, 0.15, Vector2(0.1, 0.3), Rect2(Vector2(-0.5, 0.0), Vector2(1.0, 1.5)), 2.0)
	t.check(zb.to_node(Vector3(0.05, 0.4, 0.0)).is_equal_approx(b.to_node(Vector3(0.2, 1.1, 0.0))), "zoomed twice: a canvas point lies twice as far along the surface (plus the pan)")
	t.check(zb.canvas_window().is_equal_approx(Rect2(Vector2(-0.3, -0.15), Vector2(0.5, 0.75))), "...and half as much of the canvas is shown: %s" % str(zb.canvas_window()))
	var zworst := 0.0
	for i in 200:
		var zc := Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(-0.2, 0.6), rng.randf_range(-0.02, 0.02))
		zworst = maxf(zworst, zb.from_node(zb.to_node(zc)).distance_to(zc))
	t.check(zworst < 1e-5, "...and converts back exactly: worst %f" % zworst)
	var zp := zb.to_node(Vector3(0.1, 0.35, 0.0))
	var zhit := zb.ray(zp + Vector3(0, -0.3, 0.3), (zp - (zp + Vector3(0, -0.3, 0.3))).normalized(), 0.0)
	t.check(not zhit.is_empty() and (zhit.canvas as Vector3).is_equal_approx(Vector3(0.1, 0.35, 0.0)), "...a ray lands on the canvas point it is aimed at")
	t.near(zb.cut_pitch(), DeskBend.PITCH, 1e-9, "twice its size, the strips stay 8 mm of canvas (16 mm of surface)")
	zb.set_params(0.4, 0.15, Vector2.ZERO, zb.window, 3.0)
	t.near(zb.cut_pitch(), DeskBend.PITCH * 0.5, 1e-9, "...three times: halved")
	zb.set_params(0.4, 0.15, Vector2.ZERO, zb.window, 50.0)
	t.near(zb.zoom, DeskBend.MAX_ZOOM, 1e-9, "the zoom has its limits")
	# a ray from in front of each part of the surface meets it where it is aimed
	var miss := 0
	for sv in [-0.1, 0.1, 0.39, 0.45, 0.5, 0.54, 0.6, 0.8, 1.2]:
		var c2 := Vector3(0.05, sv, 0.0)
		var pn := b.to_node(c2)
		var nrm := b.normal_at(sv)
		var o := pn + nrm * 0.5 + Vector3(0.0, 0.0, 0.0)
		var hit := b.ray(o, (pn - o).normalized(), 0.0)
		if hit.is_empty() or not (hit.canvas as Vector3).is_equal_approx(Vector3(0.05, sv, 0.0)):
			miss += 1
			print("  ray at s=%.2f: %s" % [sv, str(hit)])
	t.eq(miss, 0, "a ray aimed at the flat part, the bend and the wall lands on the point aimed at")
	t.check(b.ray(Vector3(0, 0.1, 0.3), Vector3(0, 1, 0), 0.0).is_empty() == false, "a ray along the desk runs into the wall")

	# ---- cutting geometry into strips
	var verts := PackedVector3Array([Vector3(0, 0, 0), Vector3(0.05, 0.1, 0), Vector3(-0.05, 0.1, 0)])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 1), Vector2(2, 1)])
	var cols := PackedColorArray([Color(0, 0, 0, 1), Color(1, 0, 0, 1), Color(1, 0, 0, 1)])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var cut := DeskBend.slice(arrays)
	var cv: PackedVector3Array = cut[Mesh.ARRAY_VERTEX]
	var ci: PackedInt32Array = cut[Mesh.ARRAY_INDEX]
	var area := 0.0
	var tall := 0.0
	var winding := true
	for k in ci.size() / 3:
		var a := cv[ci[k * 3]]
		var bb := cv[ci[k * 3 + 1]]
		var cc := cv[ci[k * 3 + 2]]
		var cross := (bb - a).cross(cc - a).z * 0.5
		area += absf(cross)
		if cross * ((verts[1] - verts[0]).cross(verts[2] - verts[0]).z) < -1e-12:
			winding = false
		tall = maxf(tall, maxf(a.y, maxf(bb.y, cc.y)) - minf(a.y, minf(bb.y, cc.y)))
	t.near(area, 0.005, 1e-7, "cutting a triangle into strips keeps its area")
	t.check(tall <= DeskBend.PITCH + 1e-6, "...no piece is taller than a strip: %.4f" % tall)
	t.check(winding, "...and every piece faces the way the triangle did")
	t.check(ci.size() / 3 >= 12, "...a 10 cm tall triangle is %d pieces" % (ci.size() / 3))
	var cu: PackedVector2Array = cut[Mesh.ARRAY_TEX_UV]
	var cc2: PackedColorArray = cut[Mesh.ARRAY_COLOR]
	var attr_ok := true
	for k in cv.size():
		if absf(cu[k].y - cv[k].y * 10.0) > 1e-4 or absf(cc2[k].r - cv[k].y * 10.0) > 1e-4:
			attr_ok = false
	t.check(attr_ok, "uv and colour are interpolated to the new corners")
	t.eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 3, "the arrays that were given are left as they were")
	# corners level with each other, at the bottom and on a cutting line: still the whole triangle
	var level_ok := true
	for tri in [[Vector3(0, 0, 0), Vector3(0.05, 0, 0), Vector3(0.01, 0.1, 0)], [Vector3(0, DeskBend.PITCH * 3.0, 0), Vector3(0.04, 0.05, 0), Vector3(-0.02, 0.05, 0)],
			[Vector3(0.2, 0.3, 0), Vector3(0.1, 0.1, 0), Vector3(0.0, 0.2, 0)]]:
		var arr2 := arrays.duplicate()
		arr2[Mesh.ARRAY_VERTEX] = PackedVector3Array(tri)
		var want := absf(((tri[1] as Vector3) - (tri[0] as Vector3)).cross((tri[2] as Vector3) - (tri[0] as Vector3)).z) * 0.5
		var cut2 := DeskBend.slice(arr2)
		var cv2: PackedVector3Array = cut2[Mesh.ARRAY_VERTEX]
		var ci2: PackedInt32Array = cut2[Mesh.ARRAY_INDEX]
		var got := 0.0
		for k in ci2.size() / 3:
			got += absf((cv2[ci2[k * 3 + 1]] - cv2[ci2[k * 3]]).cross(cv2[ci2[k * 3 + 2]] - cv2[ci2[k * 3]]).z) * 0.5
		if absf(got - want) > 1e-8:
			level_ok = false
			print("  area %.6f of %.6f for %s" % [got, want, str(tri)])
	t.check(level_ok, "triangles with level corners, or a corner on a cutting line, keep all their area")
	var small := arrays.duplicate()
	small[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0.001, 0), Vector3(0.002, 0.002, 0), Vector3(0, 0.004, 0)])
	t.check(DeskBend.slice(small) == small, "a triangle inside one strip is not touched")

	# ---- the file and the wire
	var fd := FrameData.make(FrameData.CANVAS, "r", Transform3D.IDENTITY, "x")
	t.check(not FrameData.from_dict(fd.to_dict()).bend, "a canvas is flat unless it was made a curved desk")
	fd.bend = true
	fd.bend_at = 0.52
	fd.bend_radius = 0.2
	fd.bend_pan = Vector2(0.1, -0.25)
	var fb := FrameData.from_dict(JSON.parse_string(JSON.stringify(DocSync.frame_to_wire(fd))))
	t.check(fb.bend and is_equal_approx(fb.bend_at, 0.52) and is_equal_approx(fb.bend_radius, 0.2) and fb.bend_pan.is_equal_approx(Vector2(0.1, -0.25)),
		"the bend is saved, and goes to the others of a session")
	fd.place_locked = true
	t.check(FrameData.from_dict(JSON.parse_string(JSON.stringify(DocSync.frame_to_wire(fd)))).place_locked and not FrameData.from_dict({"id": "y"}).place_locked,
		"a locked place is saved and goes to the others of a session (and is off unless set)")
	var hostile := FrameData.from_dict({"id": "x", "bend": [99.0, -5.0, 1e30, "a"]})
	t.check(hostile.bend_at <= DeskBend.MAX_AT and hostile.bend_radius >= DeskBend.MIN_RADIUS and absf(hostile.bend_pan.x) <= 1e4, "numbers from outside are kept in range")

	# ---- making a curved desk with the nib
	var frames_before := board.doc.frames.size()
	board.surface.begin("", Vector2(1.2, 0.8), true)
	await tap(on_desk(-0.3, -0.1))
	await tap(on_desk(0.3, -0.1))
	await tap(on_desk(0.0, 0.2))
	await tap(on_desk(-0.2, -0.3))
	await tap(on_desk(0.25, 0.1))
	t.check(board.surface.finish(), "Done on a level desk makes the canvas")
	t.check(board.surface.aligning(), "...and asks for the desk's front edge and the wall, to line it up")
	board.surface.cancel_align()                       # Not now: it stays lined up with the head
	t.check(not board.surface.aligning(), "Not now leaves it as it is")
	await tick(90)
	t.eq(board.doc.frames.size(), frames_before + 1, "one canvas")
	var f: FrameData = board.doc.frames.values()[board.doc.frames.size() - 1]
	var fn: FrameNode = board.frame_nodes[f.id]
	t.check(f.bend and f.surface and fn.bend != null, "it is a curved desk, bound to the desk")
	t.check(fn.global_transform.basis.z.is_equal_approx(Vector3.UP), "it lies level on the desk")
	t.check(fn.global_transform.basis.y.is_equal_approx(Vector3(0, 0, -1)), "its far end is away from the head")
	t.near(fn.global_position.x, 0.0, 1e-4, "it is straight in front of the head")
	t.near(fn.global_position.z, -Board.CHEST, 1e-4, "...with its edge in front of the chest")
	t.near(fn.global_position.y, p0.y, 1e-4, "...on the desk")
	t.check(f.size.is_equal_approx(DeskBend.DEFAULT_SIZE) and is_equal_approx(f.bend_at, DeskBend.DEFAULT_AT), "it starts with the default window and bend")

	# ---- drawing on all of it
	var win := fn.bounds()
	t.check(win.is_equal_approx(Rect2(Vector2(-0.5, 0.0) - f.bend_pan, DeskBend.DEFAULT_SIZE)), "the shown part is the window, shifted by the pan")
	var rad := DeskBend.DEFAULT_RADIUS
	var spots := {"flat": 0.2, "bend": 0.4 + rad * 0.8, "wall": 0.4 + rad * PI / 2.0 + 0.3}
	var made := {}
	for key in spots:
		var cy: float = float(spots[key]) - f.bend_pan.y
		var pts: Array = []
		for i in 12:
			pts.append(fn.to_world_point(Vector3(-0.1 + float(i) * 0.01, cy + sin(float(i) * 0.6) * 0.02, 0.0)))
		var n0 := strokes_of(f.id).size()
		await drag(pts)
		var all := strokes_of(f.id)
		t.eq(all.size(), n0 + 1, "a stroke on the %s part" % key)
		if all.size() > n0:
			made[key] = all[all.size() - 1]
	for key in made:
		var it: Item = made[key]
		var cy2: float = float(spots[key]) - f.bend_pan.y
		var mid := it.bounds().get_center()
		t.near(mid.x, -0.1 + 0.055, 0.004, "the %s stroke's x is the canvas's" % key)
		var lo_y := INF
		var hi_y := -INF
		for i in 12:
			lo_y = minf(lo_y, sin(float(i) * 0.6) * 0.02)
			hi_y = maxf(hi_y, sin(float(i) * 0.6) * 0.02)
		t.near(mid.y, cy2 + (lo_y + hi_y) * 0.5, 0.004, "the %s stroke's y is the canvas's, not the room's" % key)
	t.check(fn.view_of((made["wall"] as Item).id) != null, "the stroke has its view")
	var mi := fn.view_of((made["wall"] as Item).id).get_child(0) as MeshInstance3D
	var mat := mi.material_override as ShaderMaterial
	t.check(mat != null and (mat.get_shader_parameter("bend_a") as Vector4).x == 1.0, "its material bends")
	t.near((mat.get_shader_parameter("bend_a") as Vector4).y, DeskBend.DEFAULT_AT, 1e-6, "...at the distance of the bend")
	t.check(mi.custom_aabb.size.x > 1.0, "...and is not culled by its flat bounds")
	var wall_point := fn.to_world_point(Vector3(0.0, spots["wall"] - f.bend_pan.y, 0.0))
	t.near(wall_point.y - p0.y, rad + 0.3, 0.001, "a point 30 cm up the wall is %s above the desk" % str(wall_point.y - p0.y))
	t.near(wall_point.z, -Board.CHEST - 0.4 - rad, 0.001, "...at the foot of the wall: the bend's distance plus its radius from the edge")
	var tail := board.doc.items.size()
	await drag(line(on_desk(0.0, 0.0), on_desk(0.2, 0.0), 6), false)
	t.eq(board.doc.items.size(), tail, "a nib that is not pressed draws nothing")

	# ---- carrying the contents: they slide along the surface, round the bend and up the wall
	var pan0: Vector2 = f.bend_pan
	var start := fn.to_world_point(Vector3(0.1, 0.2 - pan0.y, 0.0))
	var stop := fn.to_world_point(Vector3(0.1, spots["bend"] - pan0.y, 0.0))      # the nib moves 0.5 - 0.2 along the surface, onto the bend
	var way: Array = []
	for i in 21:
		way.append(start.lerp(stop, float(i) / 20.0))
	var hold_pts: Array = []
	for i in 21:
		var sv2: float = lerpf(0.2, spots["bend"], float(i) / 20.0)
		hold_pts.append(fn.to_world_point(Vector3(0.1, sv2 - pan0.y, 0.0)))
	var n_items := board.doc.items.size()
	await drag(hold_pts, false, true)
	await tick(4)
	var f2: FrameData = board.doc.frames[f.id]
	t.near(f2.bend_pan.y - pan0.y, float(spots["bend"]) - 0.2, 0.01, "the contents slid as far along the surface as the nib did, round the bend: %.3f" % (f2.bend_pan.y - pan0.y))
	t.near(f2.bend_pan.x, pan0.x, 0.005, "...and not sideways")
	t.check(f2.xf.is_equal_approx(f.xf) and board.doc.items.size() == n_items, "the desk did not move, nothing was drawn")
	board.undo()
	await tick(2)
	t.check((board.doc.frames[f.id] as FrameData).bend_pan.is_equal_approx(pan0), "undo slides the contents back")
	board.redo()
	await tick(2)
	t.near((board.doc.frames[f.id] as FrameData).bend_pan.y - pan0.y, float(spots["bend"]) - 0.2, 0.01, "redo again")
	board.undo()
	await tick(2)
	f = board.doc.frames[f.id]

	# ---- the markers
	var md := fn.marker_pos("d")
	var mr := fn.marker_pos("r")
	t.near(md.y, f.bend_at - f.bend_pan.y, 1e-5, "the distance marker stands at the start of the bend")
	t.near(mr.y, f.bend_at + 0.5 * PI * f.bend_radius - f.bend_pan.y, 1e-5, "the radius marker stands at the start of the wall")
	t.check(md.x < fn.bounds().position.x, "...outside the left edge")
	var hot_before := f.bend_at
	var d_from := fn.to_world_point(Vector3(md.x, md.y, 0.0))
	var d_to := fn.global_transform * Vector3(0.0, f.bend_at + 0.15, 0.0)
	await drag(line(d_from, d_to, 10))
	f = board.doc.frames[f.id]
	t.near(f.bend_at, hot_before + 0.15, 0.01, "dragging the distance marker moves where the bend starts: %.3f" % f.bend_at)
	t.eq(strokes_of(f.id).size(), 3, "...and draws nothing")
	t.near(f.bend_radius, DeskBend.DEFAULT_RADIUS, 1e-6, "...and leaves the radius")
	board.undo()
	await tick(2)
	t.near((board.doc.frames[f.id] as FrameData).bend_at, hot_before, 1e-6, "undo puts the distance back")
	f = board.doc.frames[f.id]
	mr = fn.marker_pos("r")
	var r_from := fn.to_world_point(Vector3(mr.x, mr.y, 0.0))
	var r_to := fn.global_transform * Vector3(0.0, f.bend_at + 0.25, 0.25)       # on the diagonal: a radius of 25 cm
	await drag(line(r_from, r_to, 10))
	f = board.doc.frames[f.id]
	t.near(f.bend_radius, 0.25, 0.01, "dragging the radius marker rounds the bend: %.3f" % f.bend_radius)
	t.near(f.bend_at, hot_before, 1e-6, "...without moving where it starts")
	var far := fn.global_transform * Vector3(0.0, 5.0, 5.0)
	var mr2 := fn.marker_pos("r")
	await drag(line(fn.to_world_point(Vector3(mr2.x, mr2.y, 0.0)), far, 10))
	t.near((board.doc.frames[f.id] as FrameData).bend_radius, DeskBend.MAX_RADIUS, 1e-6, "the radius stops at its largest")
	board.undo()
	board.undo()
	await tick(2)
	f = board.doc.frames[f.id]
	t.near(f.bend_radius, DeskBend.DEFAULT_RADIUS, 1e-6, "undo puts the radius back")

	# ---- the curved desk is a canvas: the rest of the board works on it
	t.check(board.pen_target(fn.to_world_point(Vector3(0.0, 0.1 - f.bend_pan.y, 0.01)), Board.CAPTURE).has("fn"), "the nib near the flat part is on the canvas")
	t.check(board.pen_target(wall_point + Vector3(0, 0, 0.05), Board.CAPTURE).has("fn"), "...and near the wall (5 cm from the surface)")
	t.check(board.pen_target(wall_point + Vector3(0, 0, 0.4), Board.CAPTURE).is_empty(), "...but not 40 cm from it")
	var gaze := board.ray_canvas(Vector3(0, 1.6, 0), Vector3(0, -0.6, -1).normalized())
	t.check(not gaze.is_empty(), "a ray from the head down at the desk meets the canvas")
	var up := board.ray_canvas(Vector3(0, 1.6, 0), (fn.to_world_point(Vector3(0, spots["wall"] - f.bend_pan.y, 0)) - Vector3(0, 1.6, 0)).normalized())
	t.check(not up.is_empty() and absf((up.local as Vector2).y - (spots["wall"] - f.bend_pan.y)) < 0.01, "...and one at the wall lands on the wall's part of the canvas")

	# ---- flat again, curved again
	var content_world := fn.to_world_point(Vector3(0.0, 0.2 - f.bend_pan.y, 0.0))
	t.check(board.curve_frame(f.id, false), "a curved desk can be flattened")
	await tick(30)
	var flat: FrameData = board.doc.frames[f.id]
	var flat_fn: FrameNode = board.frame_nodes[f.id]
	t.check(not flat.bend and flat_fn.bend == null, "it is flat")
	t.check(flat_fn.to_world_point(Vector3(0.0, 0.2, 0.0)).distance_to(content_world) < 0.01, "...with its contents where they were on the desk")
	var mi2 := flat_fn.view_of((made["flat"] as Item).id).get_child(0) as MeshInstance3D
	t.check(not (mi2.material_override as ShaderMaterial).get_shader_parameter("bend_a") is Vector4 or (mi2.material_override as ShaderMaterial).get_shader_parameter("bend_a") == null \
		or ((mi2.material_override as ShaderMaterial).get_shader_parameter("bend_a") as Vector4).x == 0.0, "...drawn flat again")
	t.check(board.curve_frame(f.id, true), "a canvas on a level desk can be curved")
	t.check(board.surface.aligning(), "...and then asks to be lined up")
	board.surface.cancel_align()
	await tick(30)
	var again: FrameData = board.doc.frames[f.id]
	t.check(again.bend and (board.frame_nodes[f.id] as FrameNode).bend != null, "it is curved again")
	var cen := (board.frame_nodes[f.id] as FrameNode).to_world_point(Vector3(0.0, 0.0, 0.0))
	t.check(cen.distance_to(Vector3(0, p0.y, -Board.CHEST)) < 0.6, "its contents are in front of you")
	board.undo()
	await tick(2)
	t.check(not (board.doc.frames[f.id] as FrameData).bend, "undo flattens it")

	# ---- lining it up with the real desk: the front edge, then the wall
	var fa: FrameData = board.doc.frames[f.id]
	if not fa.bend:
		board.curve_frame(f.id, true)
		board.surface.cancel_align()
		await tick(5)
	fa = board.doc.frames[f.id]
	var pan_before: Vector2 = fa.bend_pan
	var r_before := fa.bend_radius
	var edge := Vector3(0.1, p0.y + 0.002, -0.45)
	var wall_at := Vector3(0.1 + 0.8 * sin(0.3), p0.y + 0.2, -0.45 - 0.8 * cos(0.3))     # a wall 80 cm away, the desk turned 17 degrees
	board.surface.begin_align(f.id)
	t.check(board.surface.aligning() and int(board.surface.align_status().step) == 0, "lining up starts with the front edge")
	await tap(edge)
	t.eq(int(board.surface.align_status().step), 1, "one touch: now the wall")
	await tap(Vector3(0.1, p0.y + 0.1, -0.5))
	t.check(board.surface.aligning() and str(board.surface.align_status().note) != "", "a wall 5 cm from the edge is refused, and the edge asked for again")
	t.eq(int(board.surface.align_status().step), 0, "...from the start")
	await tap(edge)
	await tap(wall_at)
	await tick(5)
	t.check(not board.surface.aligning(), "two good touches line it up")
	var fl: FrameData = board.doc.frames[f.id]
	var fnl: FrameNode = board.frame_nodes[f.id]
	t.check(fnl.global_position.distance_to(Vector3(edge.x, p0.y, edge.z)) < 0.002, "it starts at the front edge, on the desk: %s" % str(fnl.global_position))
	var run := Vector3(sin(0.3), 0.0, -cos(0.3))
	t.check(fnl.global_transform.basis.y.normalized().dot(run) > 0.9999, "it runs from the edge towards the wall")
	t.check(fnl.global_transform.basis.z.normalized().is_equal_approx(Vector3.UP), "...level with the desk")
	t.near(fl.bend_at + fl.bend_radius, 0.8, 0.002, "the bend ends at the wall: distance + radius = 80 cm")
	t.near(fl.bend_radius, r_before, 1e-6, "...keeping its radius")
	var up_wall := fnl.to_world_point(Vector3(0.0, fl.bend_at + PI * 0.5 * fl.bend_radius + 0.25 - fl.bend_pan.y, 0.0))
	t.near((up_wall - edge).dot(run), 0.8, 0.002, "25 cm up its upright part it is on the wall")
	t.near(up_wall.y - p0.y, fl.bend_radius + 0.25, 0.002, "...that high above the desk")
	t.check(fl.bend_pan.is_equal_approx(pan_before), "what is drawn stays on the canvas where it was")
	t.check(fl.size.y >= fl.bend_at + PI * 0.5 * fl.bend_radius + Board.WALL_ABOVE - 1e-6, "the shown part reaches up the wall")
	board.undo()
	await tick(3)
	t.check((board.doc.frames[f.id] as FrameData).xf.is_equal_approx(fa.xf), "undo puts it back where it was")
	var near_wall := board.doc.frames[f.id].copy() as FrameData
	t.eq(board.align_curved(f.id, edge, edge + Vector3(0.0, 0.3, -0.25)) == "", true, "a wall 25 cm away still makes a bend (the radius gives way)")
	var tight: FrameData = board.doc.frames[f.id]
	t.check(tight.bend_at >= DeskBend.MIN_AT - 1e-6 and absf(tight.bend_at + tight.bend_radius - 0.25) < 0.002, "...distance + radius = 25 cm: %.3f + %.3f" % [tight.bend_at, tight.bend_radius])
	board.undo()
	await tick(2)
	t.check((board.doc.frames[f.id] as FrameData).xf.is_equal_approx(near_wall.xf), "undo")
	board.surface.begin_align(f.id)
	pen.back = true
	await tick(2)
	pen.back = false
	await tick(2)
	t.check(not board.surface.aligning(), "the back button leaves it as it was")

	await hands_on_the_desk(f.id)

	# a canvas that is not on a desk, or on a tilted one, cannot be curved
	var wall_f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.5)))
	await tick(3)
	t.check(not board.curve_frame(wall_f.id, true), "a canvas on a wall does not curve")
	var steep := board.doc.frames[f.id].copy() as FrameData
	steep.plane_normal = Vector3(0, 0.6, 0.8)
	t.check(not board.can_curve(steep), "...nor one on a steep surface")


## A hand at a point given in the curved desk's own space (x right, y away from you along the desk, z up), pointing at another.
func hand_at(hand: HandInput, fn: FrameNode, node_p: Vector3, node_aim: Vector3) -> void:
	var p := fn.global_transform * node_p
	hand.pinch_point = p
	hand.tip = p
	hand.aim_o = p
	hand.aim_d = ((fn.global_transform * node_aim) - p).normalized()
	hand.press_o = hand.aim_o
	hand.press_d = hand.aim_d


## Move a pinching hand by `step` (desk space) a frame, `n` times; returns the largest change of the contents' pan in one frame.
func hand_steps(hand: HandInput, fn: FrameNode, step: Vector3, n: int) -> float:
	var worst := 0.0
	var prev := _live_pan(fn)
	for i in n:
		var d := fn.global_transform.basis * step
		hand.pinch_point += d
		hand.tip = hand.pinch_point
		hand.aim_o += d
		await tick(1)
		var now := _live_pan(fn)
		worst = maxf(worst, now.distance_to(prev))
		prev = now
	return worst


func _live_pan(fn: FrameNode) -> Vector2:
	return fn.bend.pan if fn.bend != null else Vector2.ZERO


## Undo the last drag, if it changed the desk (a drag that did nothing left no step to undo).
func undo_if_moved(fid: String, pan0: Vector2, xf0: Transform3D) -> void:
	var f: FrameData = board.doc.frames[fid]
	if not f.bend_pan.is_equal_approx(pan0) or not f.xf.is_equal_approx(xf0):
		board.undo()
	await tick(2)


func pinch(hand: HandInput, on: bool) -> void:
	hand.pinching = on
	hand.pinch_down = on
	hand.pinch_up = not on
	await tick(1)
	hand.pinch_down = false
	hand.pinch_up = false
	await tick(1)


## The hands on a curved desk: the contents follow a ray pointed at the wall, and a hand touching them through the bend and up the
## wall without jumping; the bar carries the desk itself along the real desk; two hands turn it.
func hands_on_the_desk(fid: String) -> void:
	pen.tracked = false
	pen.front = false
	var hand := HandInput.new("right")
	hand.tracked = true
	hand.aiming = true
	hands = [hand]
	if not (board.doc.frames[fid] as FrameData).bend:
		board.curve_frame(fid, true)
		board.surface.cancel_align()
	var fn: FrameNode = board.frame_nodes[fid]
	var f: FrameData = board.doc.frames[fid]
	var b := fn.bend
	var wall_s := b.wall_at()
	await tick(3)

	# pointing at the wall from a hand held up over the near edge: lifting the hand lifts what the ray holds
	var pan0: Vector2 = f.bend_pan
	var xf_a := f.xf
	hand_at(hand, fn, Vector3(0.3, 0.05, 0.45), b.surface_to_node(0.3, wall_s + 0.2))
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "canvas", "a ray at the wall of the curved desk is on empty canvas")
	t.check(not bool(board.hand_ctl.hover.get("right", {}).get("direct", true)), "...pointing, not touching")
	await pinch(hand, true)
	await hand_steps(hand, fn, Vector3(0, 0, 0.01), 12)
	await pinch(hand, false)
	await tick(3)
	f = board.doc.frames[fid]
	t.near(f.bend_pan.y - pan0.y, 0.12, 0.02, "lifting a hand that points at the wall slides the contents 12 cm up it: %.3f" % (f.bend_pan.y - pan0.y))
	t.check(f.xf.is_equal_approx(xf_a), "...and the desk stays put")
	await undo_if_moved(fid, pan0, xf_a)

	# touching the contents on the wall and pulling them back towards you: they come down the wall and round the bend, no jump
	hand_at(hand, fn, b.surface_to_node(0.3, wall_s + 0.15, 0.02), b.surface_to_node(0.3, wall_s + 0.15))
	await tick(2)
	t.check(bool(board.hand_ctl.hover.get("right", {}).get("direct", false)), "a hand at the wall touches it")
	await pinch(hand, true)
	var worst := await hand_steps(hand, fn, Vector3(0, -0.02, 0), 15)
	await pinch(hand, false)
	await tick(3)
	f = board.doc.frames[fid]
	t.near(f.bend_pan.y - pan0.y, -0.30, 0.04, "pulling 30 cm towards you brings the contents about 30 cm back down: %.3f" % (f.bend_pan.y - pan0.y))
	t.check(worst < 0.05, "...smoothly (largest step in one frame %.3f)" % worst)
	await undo_if_moved(fid, pan0, xf_a)

	# touching the contents on the desk and pushing forward, low down: they go round the bend and on up the wall
	hand_at(hand, fn, Vector3(0.3, 0.25, 0.03), Vector3(0.3, 0.25, 0.0))
	await tick(2)
	await pinch(hand, true)
	worst = await hand_steps(hand, fn, Vector3(0, 0.02, 0), 25)
	await pinch(hand, false)
	await tick(3)
	f = board.doc.frames[fid]
	t.near(f.bend_pan.y - pan0.y, 0.5, 0.04, "pushing 50 cm away sends the contents about 50 cm along the surface, up the wall: %.3f" % (f.bend_pan.y - pan0.y))
	t.check(worst < 0.05, "...smoothly (largest step %.3f)" % worst)
	await undo_if_moved(fid, pan0, xf_a)

	# a hand traced along the surface, through the bend, keeps the page under it
	var s_from := b.at - 0.05
	var s_to := b.wall_at() + 0.05
	hand_at(hand, fn, b.surface_to_node(0.3, s_from, 0.01), b.surface_to_node(0.3, s_from))
	await tick(2)
	await pinch(hand, true)
	for i in 30:
		var sv := lerpf(s_from, s_to, float(i + 1) / 30.0)
		var p := fn.global_transform * b.surface_to_node(0.3, sv, 0.01)
		hand.pinch_point = p
		hand.tip = p
		hand.aim_o = p
		await tick(1)
	await pinch(hand, false)
	await tick(3)
	f = board.doc.frames[fid]
	t.near(f.bend_pan.y - pan0.y, s_to - s_from, 0.006, "a hand traced %.0f cm along the surface through the bend moves the contents as far: %.3f" % [(s_to - s_from) * 100.0, f.bend_pan.y - pan0.y])
	await undo_if_moved(fid, pan0, xf_a)

	# the bar in front of the desk carries the desk itself, along the real desk
	f = board.doc.frames[fid]
	var xf0 := f.xf
	var bc := HandController.bar_center(fn)
	var bar_node := b.to_node(Vector3(bc.x, bc.y, 0.0))
	hand_at(hand, fn, bar_node + Vector3(0, 0, 0.03), bar_node)
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "bar", "the hand at the front of the curved desk is on its bar")
	var w0 := fn.global_position
	await pinch(hand, true)
	await hand_steps(hand, fn, Vector3(0.02, 0.0, 0.01), 10)
	await tick(1)                                      # (frames are placed before the hands move them: one frame behind)
	t.near(fn.global_position.distance_to(w0), 0.2, 0.02, "the desk follows the hand while carried: %.3f" % fn.global_position.distance_to(w0))
	await pinch(hand, false)
	await tick(3)
	f = board.doc.frames[fid]
	var moved := (f.xf.origin - xf0.origin)
	t.near(moved.length(), 0.2, 0.02, "the bar moved the desk 20 cm sideways: %.3f" % moved.length())
	t.near(fn.global_position.y, p0.y, 0.002, "...staying on the desk (not lifted with the hand)")
	t.check(f.bend_pan.is_equal_approx(pan0), "...with its contents where they were on it")
	t.check(f.bend and f.xf.basis.z.normalized().dot(Vector3.UP) > 0.999, "...still a level curved desk")
	await undo_if_moved(fid, pan0, xf_a)
	t.check((board.doc.frames[fid] as FrameData).xf.is_equal_approx(xf0), "undo puts the desk back")

	# two hands turn the desk (and move it), and do not stretch it
	var left := HandInput.new("left")
	left.tracked = true
	left.aiming = true
	hands = [hand, left]
	hand_at(hand, fn, Vector3(0.25, 0.25, 0.03), Vector3(0.25, 0.25, 0.0))
	hand_at(left, fn, Vector3(-0.25, 0.25, 0.03), Vector3(-0.25, 0.25, 0.0))
	await tick(2)
	var y0 := fn.global_transform.basis.y.normalized()
	await pinch(hand, true)
	await pinch(left, true)
	var mid := fn.global_transform * Vector3(0.0, 0.25, 0.03)
	for i in 10:
		var r := Basis(Vector3.UP, deg_to_rad(2.0))
		for hd in [hand, left]:
			var h := hd as HandInput
			h.pinch_point = mid + r * (h.pinch_point - mid)
			h.tip = h.pinch_point
			h.aim_o = h.pinch_point
		await tick(1)
	await tick(1)
	var turned := rad_to_deg(y0.signed_angle_to(fn.global_transform.basis.y.normalized(), Vector3.UP))
	t.near(turned, 20.0, 1.5, "turning both hands 20 degrees turns the desk with them: %.1f" % turned)
	await pinch(left, false)
	await pinch(hand, false)
	await tick(3)
	f = board.doc.frames[fid]
	t.check(f.bend and is_equal_approx(f.scale, 1.0) and f.xf.basis.z.normalized().dot(Vector3.UP) > 0.999, "...it stays a level curved desk, not scaled")
	t.near(f.bend_pan.distance_to(pan0), 0.0, 0.005, "...with its contents where they were on it")
	await undo_if_moved(fid, pan0, xf_a)

	# spreading two hands zooms the contents about the spot between them; the desk, its edge and its markers keep their size and place
	f = board.doc.frames[fid]
	var win0 := f.bend_window()
	var z0 := f.scale
	var spot := Vector2(0.0, 0.25)
	var spot_c := fn.bend.to_canvas(spot)                 # the canvas point between the hands
	var span0 := fn.to_world_point(Vector3(spot_c.x - 0.05, spot_c.y, 0.0)).distance_to(fn.to_world_point(Vector3(spot_c.x + 0.05, spot_c.y, 0.0)))
	var marker_w := fn.to_world_point(Vector3(fn.marker_pos("r").x, fn.marker_pos("r").y, 0.0))
	hand_at(hand, fn, Vector3(0.15, 0.25, 0.03), Vector3(0.15, 0.25, 0.0))
	hand_at(left, fn, Vector3(-0.15, 0.25, 0.03), Vector3(-0.15, 0.25, 0.0))
	await tick(2)
	await pinch(hand, true)
	await pinch(left, true)
	for i in 10:
		var out := fn.global_transform.basis.x.normalized() * 0.015
		hand.pinch_point += out
		left.pinch_point -= out
		for hd in [hand, left]:
			(hd as HandInput).tip = (hd as HandInput).pinch_point
			(hd as HandInput).aim_o = (hd as HandInput).pinch_point
		await tick(1)
	await tick(1)
	t.near(fn.bend.zoom, z0 * 2.0, 0.02, "hands spread to twice as far apart show the contents twice as big: %.2f" % fn.bend.zoom)
	await pinch(left, false)
	await pinch(hand, false)
	await tick(3)
	f = board.doc.frames[fid]
	t.near(f.scale, z0 * 2.0, 0.02, "...and it is kept: zoom %.2f" % f.scale)
	t.check(f.bend_window().is_equal_approx(win0), "the outline keeps its size and place on the desk")
	t.check(f.xf.origin.distance_to(xf_a.origin) < 0.003 and is_equal_approx(f.bend_at, (board.doc.frames[fid] as FrameData).bend_at), "...and so does the desk")
	t.check(fn.bend.to_surface(spot_c).distance_to(spot) < 0.003, "the spot between the hands stays where it was: %s" % str(fn.bend.to_surface(spot_c)))
	var span1 := fn.to_world_point(Vector3(spot_c.x - 0.05, spot_c.y, 0.0)).distance_to(fn.to_world_point(Vector3(spot_c.x + 0.05, spot_c.y, 0.0)))
	t.near(span1 / span0, 2.0, 0.03, "what is drawn there is twice as big in the room")
	t.check(fn.to_world_point(Vector3(fn.marker_pos("r").x, fn.marker_pos("r").y, 0.0)).distance_to(marker_w) < 0.001, "...and the markers have not moved")
	t.near(fn.bend.wall_at(), b.wall_at(), 1e-6, "...nor has the bend")
	# flattened while zoomed, what is drawn stays where it is (the zoom becomes the flat canvas's scale), and back
	var here := fn.to_world_point(Vector3(spot_c.x + 0.05, spot_c.y + 0.02, 0.0))
	board.curve_frame(fid, false)
	await tick(3)
	t.check(fn.to_world_point(Vector3(spot_c.x + 0.05, spot_c.y + 0.02, 0.0)).distance_to(here) < 0.002, "flattening a zoomed curved desk keeps its contents in place")
	t.near((board.doc.frames[fid] as FrameData).scale, z0 * 2.0, 0.02, "...at their size")
	board.undo()
	await tick(3)
	t.check(fn.bend != null and fn.to_world_point(Vector3(spot_c.x + 0.05, spot_c.y + 0.02, 0.0)).distance_to(here) < 0.002, "undo curves it again, the same")
	board.undo()
	await tick(3)
	t.near((board.doc.frames[fid] as FrameData).scale, z0, 1e-6, "undo puts the zoom back")

	# its place locked: the bar does not move the desk, and two hands that turn and spread only zoom the contents
	board.set_frame_prop(fid, "place_locked", true)
	await tick(2)
	var lk_xf := (board.doc.frames[fid] as FrameData).xf
	var lbc := HandController.bar_center(fn)
	var lbar := fn.bend.to_node(Vector3(lbc.x, lbc.y, 0.0))
	hands = [hand]
	hand_at(hand, fn, lbar + Vector3(0, 0, 0.03), lbar)
	await tick(2)
	await pinch(hand, true)
	await hand_steps(hand, fn, Vector3(0.02, 0.01, 0.0), 10)
	await pinch(hand, false)
	await tick(3)
	t.check((board.doc.frames[fid] as FrameData).xf.is_equal_approx(lk_xf), "its place locked, the bar does not move the curved desk")
	hands = [hand, left]
	hand_at(hand, fn, Vector3(0.15, 0.25, 0.03), Vector3(0.15, 0.25, 0.0))
	hand_at(left, fn, Vector3(-0.15, 0.25, 0.03), Vector3(-0.15, 0.25, 0.0))
	await tick(2)
	await pinch(hand, true)
	await pinch(left, true)
	for i in 10:
		var lm := (hand.pinch_point + left.pinch_point) * 0.5
		var lturn := Basis(Vector3.UP, deg_to_rad(3.0))
		for hd in [hand, left]:
			var hh := hd as HandInput
			hh.pinch_point = lm + lturn * (hh.pinch_point - lm) * 1.07
			hh.tip = hh.pinch_point
			hh.aim_o = hh.pinch_point
		await tick(1)
	await pinch(left, false)
	await pinch(hand, false)
	await tick(3)
	var lf: FrameData = board.doc.frames[fid]
	t.check(lf.xf.is_equal_approx(lk_xf), "...and two hands that turn 30 degrees do not turn or move it")
	t.check(lf.scale > z0 * 1.5, "...but still zoom what is drawn: %.2f" % lf.scale)
	t.check(board.align_curved(fid, Vector3(0.1, p0.y, -0.45), Vector3(0.1, p0.y + 0.2, -1.2)) != "" and (board.doc.frames[fid] as FrameData).xf.is_equal_approx(lk_xf),
		"...and lining it up with the desk is refused until its place is unlocked")
	board.undo()
	board.undo()
	await tick(3)
	t.check(not (board.doc.frames[fid] as FrameData).place_locked and is_equal_approx((board.doc.frames[fid] as FrameData).scale, z0), "undo: the zoom, then the lock")
	hands = []
