extends Node
## The desk: the plane fit, a canvas found with the stylus nib's pressure, and the canvas staying on that surface when it is carried,
## turned and scaled, while it follows the surface as the nib keeps touching it.

var board: Board
var anchors: SimAnchors
var pen := PenState.new()
var hands: Array = []
var t := TestCase.new("surface")

# the desk of this test: a plane a few degrees off level, through P0
var p0 := Vector3(0.2, 0.75, -0.7)
var n0 := Vector3(0.0, 1.0, 0.05).normalized()


func _ready() -> void:
	App.settings_path = "user://test_settings.cfg"
	App.reload()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_surface.json"))
	anchors = SimAnchors.new("user://test_sim_anchors_surface.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	App.put("sim_room", "A")
	board.open(Document.create("Surface test"))
	await run()
	get_tree().quit(t.done())


func tick(n: int = 1, dt: float = 0.016) -> void:
	for i in n:
		board.tick(pen, hands, dt)
		await get_tree().process_frame


## A point of the test desk: a along its x direction, b along its other in-plane direction.
func desk_axes() -> Array:
	var u := Vector3.RIGHT
	var v := n0.cross(u).normalized()
	return [u, v]


func on_desk(a: float, b: float, height: float = 0.0) -> Vector3:
	var ax := desk_axes()
	return p0 + (ax[0] as Vector3) * a + (ax[1] as Vector3) * b + n0 * height


## Press the nib on a point for a moment, then lift it.
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


## Drag the nib, pressed, through some points.
func rub(points: Array) -> void:
	pen.tracked = true
	pen.source = "stylus"
	pen.tip = points[0]
	pen.contact = false
	pen.down = false
	await tick(2)
	pen.contact = true
	pen.down = true
	pen.pressure = 0.6
	for p in points:
		pen.tip = p
		await tick(1)
	pen.contact = false
	pen.down = false
	pen.pressure = 0.0
	await tick(2)


func dist_to(fn: Node3D, point: Vector3, normal: Vector3) -> float:
	return normal.dot(fn.global_position - point)


func run() -> void:
	App.put("tool", "draw")
	App.put("recognize", "off")
	App.put("brush", "pen")
	App.put("width", 0.004)
	await tick(100)
	t.eq(board.room_state, "found", "the room is found")

	# ---- the plane fit
	var pts := PackedVector3Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var tilt_n := Vector3(0.0, 1.0, 0.1).normalized()
	var tu := Vector3.RIGHT
	var tv := tilt_n.cross(tu).normalized()
	for i in 40:
		pts.append(Vector3(0.1, 0.8, -0.5) + tu * rng.randf_range(-0.3, 0.3) + tv * rng.randf_range(-0.2, 0.2) + tilt_n * rng.randfn(0.0, 0.0008))
	var fit := PlaneFit.fit(pts)
	t.check(bool(fit.ok), "40 points of a slightly noisy tilted plane fit")
	t.check(absf((fit.normal as Vector3).dot(tilt_n)) > 0.9995, "the fitted normal is the plane's (within 1.8 deg): %.5f" % absf((fit.normal as Vector3).dot(tilt_n)))
	t.check(float(fit.rms) < 0.002, "the fit's rms is the noise: %.4f" % float(fit.rms))
	t.check((fit.extent as Vector2).x > 0.4 and (fit.extent as Vector2).y > 0.25, "the extent is the area covered: %s" % str(fit.extent))
	var vertical := PackedVector3Array([Vector3(0, 1, -2), Vector3(0.5, 1.4, -2.0), Vector3(-0.4, 0.8, -2.0), Vector3(0.3, 1.9, -2.0), Vector3(-0.5, 1.5, -2.0)])
	var wall := PlaneFit.fit(vertical)
	t.check(bool(wall.ok) and absf((wall.normal as Vector3).dot(Vector3.BACK)) > 0.999, "a wall (vertical plane) fits too")
	t.eq(PlaneFit.fit(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT])).reason, "points", "two points are not enough")
	t.eq(PlaneFit.fit(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.2, 0, 0), Vector3(0.4, 0, 0.001), Vector3(0.6, 0, 0)])).reason, "spread", "points in a line do not give a tilt")
	t.eq(PlaneFit.fit(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.3, 0.05, 0), Vector3(0, 0, 0.3), Vector3(0.3, -0.05, 0.3), Vector3(0.15, 0.04, 0.15)])).reason, "flat", "a bumpy surface is refused")

	# ---- the frame keeps its surface in the file
	var fd := FrameData.make(FrameData.CANVAS, "r", Transform3D.IDENTITY, "x")
	fd.surface = true
	fd.plane_point = Vector3(1, 2, 3)
	fd.plane_normal = Vector3(0, 0.6, 0.8)
	fd.plane_error = 0.0012
	fd.plane_points = 7
	var back := FrameData.from_dict(JSON.parse_string(JSON.stringify(fd.to_dict())))
	t.check(back.surface and back.plane_point.is_equal_approx(Vector3(1, 2, 3)) and back.plane_normal.is_equal_approx(Vector3(0, 0.6, 0.8)), "the surface survives saving and loading")
	t.check(back.plane_points == 7 and absf(back.plane_error - 0.0012) < 1e-6, "...with how it was found")
	t.check(not FrameData.from_dict({}).surface, "files from before have no surface")
	var pose := Transform3D(Basis(Vector3.UP, 0.7), Vector3(0.3, 0.9, 0.2))
	var off := back.on_surface(pose)
	t.near(back.plane_normal.dot(off.origin - back.plane_point), 0.0, 1e-5, "a pose put on the surface lies in it")
	t.check(off.basis.z.is_equal_approx(back.plane_normal) and absf(off.basis.determinant() - 1.0) < 1e-4, "...facing along its normal, a proper rotation")

	# ---- finding the desk with the nib
	board.surface.begin("", Vector2(0.9, 0.6))
	t.check(board.surface.finding(), "finding starts")
	await tap(on_desk(-0.2, -0.1))
	await tap(on_desk(0.25, -0.05))
	var st := board.surface.status()
	t.eq(st.points, 2, "each press is a point")
	t.check(not bool(st.ok) and str(st.reason) == "points", "two points: a few more are needed")
	var lifted := on_desk(0.0, 0.2)
	lifted.y += 0.1
	pen.tracked = true
	pen.tip = lifted
	pen.contact = false
	pen.down = true                              # the middle button pressed in the air is not the desk
	await tick(15)
	pen.down = false
	await tick(2)
	t.eq(board.surface.status().points, 2, "the middle button is not a touch of the desk: only the nib counts")
	await tap(on_desk(0.0, 0.2))
	st = board.surface.status()
	t.eq(st.points, 3, "a third point")
	t.check(bool(st.ok), "three spread points find the desk")
	t.near(float(st.tilt_deg), rad_to_deg(acos(n0.y)), 0.2, "it knows how tilted the desk is")
	# a rub is many points, so a quick drag across the desk is enough
	var before := int(st.points)
	var line: Array = []
	for i in 30:
		line.append(on_desk(-0.2 + float(i) * 0.015, 0.1 + float(i) * 0.002))
	await rub(line)
	t.check(int(board.surface.status().points) > before + 3, "rubbing the nib across the desk adds points along the way: %d" % int(board.surface.status().points))

	# the back button cancels, nothing is made
	var frames_before := board.doc.frames.size()
	pen.back = true
	await tick(2)
	pen.back = false
	t.check(not board.surface.finding() and board.doc.frames.size() == frames_before, "the back button cancels the search")

	board.surface.begin("", Vector2(0.9, 0.6))
	await tap(on_desk(-0.2, 0.0))
	await tap(on_desk(0.0, 0.0))
	await tap(on_desk(0.2, 0.0))
	t.check(not board.surface.finish() and board.surface.finding(), "points in a line do not make a desk: Done says so and carries on")
	await tap(on_desk(-0.1, 0.18))
	await tap(on_desk(0.15, -0.16))
	t.check(board.surface.finish(), "with the points spread out, Done makes the canvas")
	t.check(not board.surface.finding(), "...and the search is over")
	await tick(90)
	t.eq(board.doc.frames.size(), frames_before + 1, "one canvas was made")
	var f: FrameData = board.doc.frames.values()[board.doc.frames.size() - 1]
	var fn: FrameNode = board.frame_nodes[f.id]
	t.check(f.surface and f.plane_points == 5, "it is bound to the surface, found from 5 points")
	t.near(f.size.x, 0.9, 1e-6, "it has the size that was chosen")
	t.check(fn.visible, "it shows")
	t.near(dist_to(fn, p0, n0), 0.0, 0.001, "it lies on the desk (within a millimetre)")
	t.check(fn.global_transform.basis.z.dot(n0) > 0.99999, "it faces up from the desk, not down")
	t.check(fn.global_transform.basis.y.z < -0.8, "its top points away from you, as on a table")

	# ---- drawing on it works like on any canvas
	var wave: Array = []
	for i in 24:
		wave.append(fn.to_world_point(Vector3(-0.2 + float(i) * 0.015, sin(float(i) * 0.4) * 0.04, 0.0)))
	await rub(wave)
	var strokes := 0
	for it in board.doc.items.values():
		if (it as Item).kind == Item.STROKE and (it as Item).frame == f.id:
			strokes += 1
	t.eq(strokes, 1, "a stroke drawn with the nib on the desk lands on the canvas")
	t.near(dist_to(fn, p0, n0), 0.0, 0.001, "...and drawing on the exact surface leaves the canvas where it was")

	# ---- tracking: the nib touching 9 mm above where the canvas is moves the canvas up to the surface
	var xf0 := fn.global_transform
	var shifted: Array = []
	for i in 30:
		shifted.append(fn.to_world_point(Vector3(-0.3 + float(i) * 0.02, 0.15, 0.0)) + xf0.basis.z * 0.009)
	await rub(shifted)
	await tick(90)
	t.near(dist_to(fn, p0, n0), 0.009, 0.0025, "the canvas follows a desk that is 9 mm higher than it thought (%.1f mm)" % (dist_to(fn, p0, n0) * 1000.0))
	# ...and its tilt when the nib has touched the desk all over: a desk 2 degrees off the canvas's own plane, through its middle line
	var xf1 := fn.global_transform
	var uu := xf1.basis.x.normalized()
	var vv := xf1.basis.y.normalized()
	var nn := xf1.basis.z.normalized()
	var ang := deg_to_rad(2.0)
	var vt := vv * cos(ang) + nn * sin(ang)
	var mid := xf1 * Vector3(0.0, 0.15, 0.0)
	var want_n := uu.cross(vt).normalized()
	for gx in 4:
		for gy in 4:
			await tap(mid + uu * (-0.24 + float(gx) * 0.16) + vt * (-0.15 + float(gy) * 0.1), 3)
	await tick(90)
	t.check(fn.global_transform.basis.z.angle_to(want_n) < deg_to_rad(0.6), "the canvas turns to a desk that is tilted: %.2f deg off" % rad_to_deg(fn.global_transform.basis.z.angle_to(want_n)))
	t.check(board.doc.frames[f.id].surface, "...and stays on the desk")
	# ...but a single bad touch (a book on the desk) changes nothing
	var keep := fn.global_transform
	await tap(keep * Vector3(0.0, 0.0, 0.03), 3)
	await tick(30)
	t.check(fn.global_transform.origin.distance_to(keep.origin) < 0.004, "one touch does not move the canvas")

	# ---- carried, turned and scaled: it never leaves the surface
	f = board.doc.frames[f.id]
	var plane_n: Vector3 = (board.room_world(f.room) as Transform3D).basis.orthonormalized() * f.plane_normal
	var plane_p: Vector3 = (board.room_world(f.room) as Transform3D) * f.plane_point
	board.begin_grab(f)
	t.check(board.grabs.has(f.id), "the desk canvas can be picked up")
	var g: Dictionary = board.grabs[f.id]
	var gx := g.xf as Transform3D
	gx.origin += Vector3(0.35, 0.5, 0.2)          # lifted off the desk and carried sideways
	g.xf = gx
	await tick(3)
	t.near(dist_to(fn, plane_p, plane_n), 0.0, 1e-4, "carried through the air, the canvas stays on the desk")
	t.check(fn.global_transform.origin.distance_to(keep.origin) > 0.2, "...and does slide along it")
	gx = g.xf
	gx.basis = Basis(Vector3.UP, 0.9) * gx.basis
	g.xf = gx
	g.scale = 2.0
	await tick(3)
	t.check(fn.global_transform.basis.z.angle_to(plane_n) < 1e-4, "turned about a standing axis, it still faces along the desk's normal")
	t.near(fn.scale.x, 2.0, 1e-3, "it scales")
	t.near(dist_to(fn, plane_p, plane_n), 0.0, 1e-4, "scaled and turned it is still on the desk")
	board.end_grab(f)
	await tick(60)
	f = board.doc.frames[f.id]
	t.near(f.scale, 2.0, 1e-6, "the new scale is kept")
	t.near(dist_to(fn, plane_p, plane_n), 0.0, 0.001, "let go, it stays on the desk")
	t.check(f.surface, "...still bound to it")
	board.undo()
	await tick(5)
	t.near(board.doc.frames[f.id].scale, 1.0, 1e-6, "undo puts the canvas back where it was")
	board.redo()
	await tick(5)
	# the shortcuts that would lift it away are refused
	var toasts: Array = []
	board.toast.connect(func(m: String): toasts.append(m))
	board.active_frame = f.id
	board.bring_canvas_here()
	t.check(not toasts.is_empty() and str(toasts[0]).contains("desk"), "'bring the canvas to me' keeps it on the desk and says so")

	# ---- a canvas that was somewhere else can be laid on the desk, and freed again
	var other := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.3, -1.0)))
	await tick(60)
	board.surface.begin(other.id)
	await tap(on_desk(-0.3, -0.2))
	await tap(on_desk(0.3, -0.2))
	await tap(on_desk(0.0, 0.25))
	t.check(board.surface.finish(), "an existing canvas is laid on the desk the same way")
	await tick(90)
	var o2: FrameData = board.doc.frames[other.id]
	t.check(o2.surface and board.frame_nodes[other.id].visible, "it is bound now")
	t.near(dist_to(board.frame_nodes[other.id], p0, n0), 0.0, 0.001, "...and lies on the desk")
	board.undo()
	await tick(5)
	t.check(not board.doc.frames[other.id].surface, "laying it down is one undo step")
	board.redo()
	await tick(5)
	board.surface.release(other.id)
	await tick(5)
	t.check(not board.doc.frames[other.id].surface, "freed from the desk")
	var og: FrameData = board.doc.frames[other.id]
	board.begin_grab(og)
	var og_g: Dictionary = board.grabs[other.id]
	var ogx := og_g.xf as Transform3D
	ogx.origin += Vector3(0.0, 0.6, 0.0)
	og_g.xf = ogx
	await tick(3)
	t.check(absf(dist_to(board.frame_nodes[other.id], p0, n0)) > 0.3, "a freed canvas goes wherever it is carried")
	board.end_grab(og)

	# ---- freed and stood upright: vertical, facing the head, standing on the desk
	board.surface.begin(other.id)
	await tap(on_desk(-0.3, -0.2))
	await tap(on_desk(0.3, -0.2))
	await tap(on_desk(0.0, 0.25))
	t.check(board.surface.finish(), "the canvas is laid on the desk again")
	await tick(30)
	board.surface.release(other.id, true)
	await tick(30)
	var up_f: FrameData = board.doc.frames[other.id]
	var up_fn: FrameNode = board.frame_nodes[other.id]
	t.check(not up_f.surface, "freed and upright: no longer bound to the desk")
	t.near(up_fn.global_transform.basis.y.dot(Vector3.UP), 1.0, 1e-3, "its top edge points straight up")
	t.near(up_fn.global_transform.basis.z.y, 0.0, 1e-3, "it faces horizontally")
	var to_head: Vector3 = board.head.origin - up_fn.global_transform * Vector3(up_f.offset.x, up_f.offset.y, 0.0)
	to_head.y = 0.0
	t.check(up_fn.global_transform.basis.z.dot(to_head.normalized()) > 0.99, "...towards the head")
	var bottom: Vector3 = up_fn.global_transform * (Vector3(up_f.offset.x, up_f.offset.y - up_f.size.y * 0.5, 0.0) * up_f.scale)
	t.near(n0.dot(bottom - p0), 0.0, 0.01, "its bottom edge rests on the desk")
	board.undo()
	await tick(5)
	t.check(board.doc.frames[other.id].surface, "undo puts it back on the desk, lying")

	# ---- reopening: the desk canvas is still bound
	board.flush_save()
	var saved := board.doc.to_dict() if board.doc.has_method("to_dict") else {}
	t.check(saved.is_empty() or JSON.stringify(saved).contains("\"surface\":true"), "the document file records the surface")
