extends Node
## The curved desk: the bend's maths (a sheet curved round a cylinder: lengths kept, inverse and ray hits agree), cutting geometry into
## strips, a curved canvas made with the stylus nib on a level desk, drawing on its flat part, bend and wall, carrying its contents along the
## surface, the two markers (distance and radius), curving and flattening a canvas that is already on the desk, and the file.

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

	# a canvas that is not on a desk, or on a tilted one, cannot be curved
	var wall_f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.5)))
	await tick(3)
	t.check(not board.curve_frame(wall_f.id, true), "a canvas on a wall does not curve")
	var steep := board.doc.frames[f.id].copy() as FrameData
	steep.plane_normal = Vector3(0, 0.6, 0.8)
	t.check(not board.can_curve(steep), "...nor one on a steep surface")
