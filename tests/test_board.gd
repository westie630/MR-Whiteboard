extends Node
## Board integration: a simulated pen draws, snaps, erases, selects and moves things; rooms and anchors behave; hands move canvases.

var board: Board
var anchors: SimAnchors
var pen := PenState.new()
var hands: Array = []
var t := TestCase.new("board")
const CANVAS_Z := -1.0
const CANVAS_Y := 1.3


func _ready() -> void:
	App.settings_path = "user://test_settings.cfg"
	App.reload()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors.json"))
	anchors = SimAnchors.new("user://test_sim_anchors.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	App.put("sim_room", "A")
	var doc := Document.create("Board test")
	board.open(doc)
	await run()
	get_tree().quit(t.done())


func tick(n: int = 1, dt: float = 0.016) -> void:
	for i in n:
		board.tick(pen, hands, dt)
		await get_tree().process_frame


func world(x: float, y: float) -> Vector3:
	return Vector3(x, CANVAS_Y + y, CANVAS_Z)


func hover(p: Vector3) -> void:
	pen.tracked = true
	pen.source = "mouse"
	pen.tip = p
	pen.down = false
	pen.pressure = 0.0
	await tick(2)


## Point a hand at a place on the canvas from 90 cm in front of it; the fingers are at the canvas (so a carried canvas follows the
## hand 1:1: a far one would move further than the hand, see HandController.MAX_GAIN).
func aim(hand: HandInput, p: Vector3) -> void:
	hand.aim_o = p + Vector3(0, 0, 0.9)
	hand.aim_d = Vector3(0, 0, -1)
	hand.press_o = hand.aim_o
	hand.press_d = hand.aim_d
	hand.pinch_point = p + Vector3(0, 0, 0.05)
	hand.tip = hand.pinch_point


## The same, from a hand held back near the face: its pinch point is far from the canvas, so the ray chooses and the movement is geared up.
func aim_far(hand: HandInput, p: Vector3) -> void:
	var o := Vector3(0.0, 1.5, -0.4)
	hand.pinch_point = o
	hand.tip = o
	hand.aim_o = o
	hand.aim_d = (p - o).normalized()
	hand.press_o = hand.aim_o
	hand.press_d = hand.aim_d


func on_canvas(fn: FrameNode, p: Vector2) -> Vector3:
	return fn.to_world_point(Vector3(p.x, p.y, 0.0))


## Carrying turns a canvas towards the head; the sections after a carry measure along the canvas's axes, so they square it up again first.
func square_up(id: String) -> void:
	var f := board.doc.frames[id] as FrameData
	f.xf = Transform3D(Basis.IDENTITY, f.xf.origin)


func hover_kind(side: String) -> String:
	return str(board.hand_ctl.hover.get(side, {}).get("kind", ""))


func hover_direct(side: String) -> bool:
	return bool(board.hand_ctl.hover.get(side, {}).get("direct", false))


func pinch_down(hand: HandInput) -> void:
	hand.pinching = true
	hand.pinch_down = true
	await tick(1)
	hand.pinch_down = false


func pinch_up(hand: HandInput) -> void:
	hand.pinching = false
	hand.pinch_up = true
	await tick(2)
	hand.pinch_up = false


func draw(points: Array, hold_frames: int = 0, release: bool = true) -> void:
	await hover(points[0])
	pen.down = true
	pen.pressure = 0.8
	for p in points:
		pen.tip = p
		await tick(1)
	if hold_frames > 0:
		await tick(hold_frames)
	if release:
		pen.down = false
		pen.pressure = 0.0
		await tick(2)


func path_of(poly: PackedVector2Array) -> Array:
	var out: Array = []
	for p in poly:
		out.append(world(p.x, p.y))
	return out


## The width and height of the box around some items.
func _span_of(ids: Array) -> Vector2:
	var r := Rect2()
	var first := true
	for id in ids:
		var b: Rect2 = (board.doc.items[id] as Item).bounds()
		r = b if first else r.merge(b)
		first = false
	return r.size


## Tap one of the buttons beside the selection ("undo", "redo", "delete") with the pen.
func _press_button(id: String, fn: FrameNode) -> void:
	var pos := Vector2.ZERO
	for b in board.pen_ctl.bar_buttons(fn):
		if b.id == id:
			pos = b.pos
	t.check(pos != Vector2.ZERO, "the %s button is there" % id)
	await hover(world(pos.x, pos.y))
	pen.down = true
	pen.pressure = 0.8
	await tick(2)
	pen.down = false
	await tick(3)


func items_of_kind(kind: String, shape: String = "") -> Array:
	var out: Array = []
	for it in board.doc.items.values():
		if (it as Item).kind == kind and (shape == "" or (it as Item).shape == shape):
			out.append(it)
	return out


func run() -> void:
	App.put("tool", "draw")
	App.put("recognize", "off")
	App.put("brush", "pen")
	App.put("width", 0.004)

	# a new document gets its first room by itself
	await tick(100)
	t.eq(board.room_state, "found", "the room is found / created")
	t.eq(board.doc.rooms.size(), 1, "one room created")
	await tick(3)
	var room: Dictionary = board.doc.rooms[0]
	t.check(str(room.anchor) != "", "the room has an anchor: %s" % str(room.anchor))

	# place a canvas
	var f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, CANVAS_Y, CANVAS_Z)))
	t.check(f != null, "canvas created")
	await tick(60)
	t.check(board.frame_nodes[f.id].visible, "the canvas is visible in its room")
	t.check(str(board.doc.frames[f.id].anchor) != "", "the canvas got its own anchor")

	# freehand stroke
	var wave := PackedVector2Array()
	for i in 50:
		wave.append(Vector2(-0.4 + float(i) * 0.016, sin(float(i) * 0.3) * 0.05))
	await draw(path_of(wave))
	var strokes := items_of_kind(Item.STROKE)
	t.eq(strokes.size(), 1, "freehand stroke committed")
	if not strokes.is_empty():
		var st: Item = strokes[0]
		t.check(st.point_count() > 10, "stroke has points: %d" % st.point_count())
		t.near(st.pt(0).x, -0.4, 0.02, "stroke starts where the pen went down")
		t.near(st.pt(0).z, 0.0, 1e-6, "canvas strokes are flat")

	# auto recognition: a rectangle becomes a rectangle
	App.put("recognize", "auto")
	Synth.rng.seed = 3
	await draw(path_of(Synth.rect(0.3, 0.18, Vector2(0.0, 0.3), 0.02)))
	var rects := items_of_kind(Item.SHAPE, "rect")
	t.eq(rects.size(), 1, "a drawn rectangle is recognised")
	if not rects.is_empty():
		t.near((rects[0] as Item).size.x, 0.3, 0.03, "recognised rectangle width")

	# hold to snap: a circle held still at the end
	App.put("recognize", "hold")
	await draw(path_of(Synth.ellipse(0.1, 0.1, Vector2(0.55, 0.3))), 60)
	t.eq(items_of_kind(Item.SHAPE, "ellipse").size(), 1, "a circle held at the end snaps to a vector ellipse")
	var before_strokes := items_of_kind(Item.STROKE).size()
	await draw(path_of(Synth.ellipse(0.1, 0.1, Vector2(-0.55, 0.3))))
	t.eq(items_of_kind(Item.STROKE).size(), before_strokes + 1, "without holding, the same circle stays freehand")

	# a straight line snaps to horizontal
	await draw(path_of(Synth.line(Vector2(-0.4, -0.2), Vector2(0.2, -0.19))), 60)
	var lines := items_of_kind(Item.SHAPE, "line")
	t.eq(lines.size(), 1, "a held line snaps to a vector line")
	if not lines.is_empty():
		t.near((lines[0] as Item).a.y, (lines[0] as Item).b.y, 1e-6, "the line is perfectly horizontal")

	# undo / redo
	var n_before := board.doc.items.size()
	board.undo()
	t.eq(board.doc.items.size(), n_before - 1, "undo removes the last shape")
	board.redo()
	t.eq(board.doc.items.size(), n_before, "redo brings it back")

	# erase
	App.put("tool", "erase")
	var count_before := items_of_kind(Item.STROKE).size()
	var sweep: Array = []
	for i in 30:
		sweep.append(world(-0.45 + float(i) * 0.03, sin((-0.45 + float(i) * 0.03 + 0.4) / 0.016 * 0.3) * 0.05))
	await draw(sweep)
	t.check(items_of_kind(Item.STROKE).size() < count_before, "the eraser removes touched strokes")
	board.undo()
	t.eq(items_of_kind(Item.STROKE).size(), count_before, "undo restores erased strokes")

	# flow diagram: stencils, glued connector, moving a box drags its connector
	board.doc.remove_frame(f.id)
	await tick(3)
	var g := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, CANVAS_Y, CANVAS_Z)))
	await tick(5)
	App.put("tool", "shape")
	App.put("recognize", "off")
	board.stencil = "rect"
	await draw([world(-0.4, 0.0), world(-0.15, 0.1)])             # drag out a box
	await draw([world(0.4, 0.0), world(0.65, 0.1)])
	var boxes := items_of_kind(Item.SHAPE, "rect")
	t.eq(boxes.size(), 2, "two boxes drawn with the stencil tool")
	boxes.sort_custom(func(a, b): return a.center.x < b.center.x)
	board.stencil = "arrow"
	var a_port := Shapes.port_world(boxes[0], 1)
	var b_port := Shapes.port_world(boxes[1], 3)
	await draw([world(a_port.pos.x + 0.01, a_port.pos.y), world(b_port.pos.x - 0.01, b_port.pos.y)])
	var arrows := items_of_kind(Item.SHAPE, "arrow")
	t.eq(arrows.size(), 1, "an arrow was drawn")
	if not arrows.is_empty():
		var ar: Item = arrows[0]
		t.eq(ar.glue_a.get("item", ""), (boxes[0] as Item).id, "the arrow start is glued to box 1")
		t.eq(ar.glue_b.get("item", ""), (boxes[1] as Item).id, "the arrow end is glued to box 2")
		t.near(ar.a.distance_to(a_port.pos), 0.0, 1e-4, "the arrow start snapped to the port")
		# move box 2 with the select tool
		App.put("tool", "select")
		var c2: Vector2 = (boxes[1] as Item).center
		await hover(world(c2.x, c2.y + 0.04))
		pen.down = true
		pen.pressure = 0.8
		await tick(2)
		for i in 10:
			pen.tip = world(c2.x + float(i) * 0.02, c2.y + 0.04 - float(i) * 0.01)
			await tick(1)
		pen.down = false
		await tick(3)
		var moved: Item = board.doc.items[(boxes[1] as Item).id]
		t.check(moved.center.distance_to(c2) > 0.1, "dragging with the select tool moved the box")
		var ar2: Item = board.doc.items[ar.id]
		var new_port := Shapes.port_world(moved, 3)
		t.near(ar2.b.distance_to(new_port.pos), 0.0, 1e-4, "the glued arrow followed the moved box")
		board.undo()
		var ar3: Item = board.doc.items[ar.id]
		t.near(ar3.b.distance_to(b_port.pos), 0.0, 1e-4, "undo puts the arrow back with the box")

	# selection handles with the stylus: the outline follows a drag, a corner scales the box, the top handle turns it
	App.put("tool", "select")
	var hb: Item = board.doc.items[(boxes[0] as Item).id]
	var fnode := board.frame_nodes[g.id] as FrameNode
	var hc := hb.center
	await hover(world(hc.x, hc.y + 0.01))
	pen.down = true
	pen.pressure = 0.8
	await tick(2)
	pen.down = false
	await tick(2)
	t.check(board.selection.has(hb.id), "a tap with the select tool selects the box")
	# dragging the box: the outline and its handles move with it
	var top0: Vector2 = Vector2.ZERO
	for h in board.pen_ctl.handles(fnode):
		if h.id == "rot":
			top0 = h.pos
	await hover(world(hc.x, hc.y + 0.01))
	pen.down = true
	await tick(2)
	for i in 6:
		pen.tip = world(hc.x + 0.02 * float(i + 1), hc.y + 0.01)
		await tick(1)
	var shown: Dictionary = board.selection_view(fnode)
	t.near(float(shown.offset.x), 0.12, 0.01, "while dragging, the selection outline is shown moved with the box: %s" % str(shown.offset))
	t.near((shown.handles[0] as Dictionary).pos.x - (board.pen_ctl.handles(fnode)[0] as Dictionary).pos.x, 0.12, 0.01, "...and so are its handles")
	pen.down = false
	await tick(3)
	hb = board.doc.items[hb.id]
	hc = hb.center
	# moving and reshaping do not fight: the handles stand on the box's own corners, so a press inside the box moves it; only dead on a corner
	# or just outside it reshapes
	var c1: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "corner1":
			c1 = h
	var cp: Vector2 = c1.pos
	t.eq(str(board.pen_ctl.hit_handle(fnode, cp).get("id", "")), "corner1", "a press dead on a corner handle reshapes")
	t.eq(str(board.pen_ctl.hit_handle(fnode, cp + Vector2(0.02, 0.02)).get("id", "")), "corner1", "...and so does one just outside the box")
	t.check(board.pen_ctl.hit_handle(fnode, cp + Vector2(-0.018, -0.018)).is_empty(), "...but a nib 25 mm inside the box from the corner does not")
	board.pen_ctl.reach = InputTuning.REACH
	t.check(board.pen_ctl.hit_handle(fnode, cp + Vector2(-0.03, -0.03)).is_empty(), "pointing from afar, 42 mm inside the box does not reshape it either")
	t.eq(str(board.pen_ctl.hit_handle(fnode, cp + Vector2(0.04, 0.04)).get("id", "")), "corner1", "...while 57 mm outside it still does (a ray is not a nib)")
	board.pen_ctl.reach = 1.0
	var size_in := hb.size
	var center_in := hb.center
	await hover(world(cp.x - 0.018, cp.y - 0.018))
	pen.down = true
	await tick(2)
	for i in 6:
		pen.tip = world(cp.x - 0.018 + 0.02 * float(i + 1), cp.y - 0.018)
		await tick(1)
	pen.down = false
	await tick(3)
	var moved_in: Item = board.doc.items[hb.id]
	t.near(moved_in.center.x - center_in.x, 0.12, 0.01, "dragging from just inside a corner moves the box")
	t.check(moved_in.size.is_equal_approx(size_in), "...and does not scale it")
	board.undo()
	await tick(3)
	hb = board.doc.items[hb.id]
	hc = hb.center
	# the corner handle scales
	var box_size0 := hb.size
	var corner: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "corner1":
			corner = h
	t.check(not corner.is_empty(), "the selected box has corner handles")
	await hover(world(corner.pos.x, corner.pos.y))
	pen.down = true
	await tick(2)
	for i in 8:
		pen.tip = world(corner.pos.x + 0.015 * float(i + 1), corner.pos.y + 0.01 * float(i + 1))
		await tick(1)
	var live: Dictionary = board.selection_view(fnode)
	t.check(not live.handles.is_empty() and float((live.handles[0] as Dictionary).pos.distance_to((board.pen_ctl.handles(fnode)[0] as Dictionary).pos)) > 0.02, "while scaling, the handles are drawn on the box as it is being scaled")
	pen.down = false
	await tick(3)
	var hs: Item = board.doc.items[hb.id]
	t.check(hs.size.x > box_size0.x + 0.08 and hs.size.y > box_size0.y + 0.04, "dragging a corner handle scaled the box: %s -> %s" % [str(box_size0), str(hs.size)])
	# the top handle turns it
	var rot_h: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "rot":
			rot_h = h
	t.check(not rot_h.is_empty(), "the box has a rotation handle")
	await hover(world(rot_h.pos.x, rot_h.pos.y))
	pen.down = true
	await tick(2)
	for i in 8:
		var a := deg_to_rad(8.0 * float(i + 1))
		var rel: Vector2 = (rot_h.pos as Vector2) - hs.center
		pen.tip = world(hs.center.x + rel.rotated(-a).x, hs.center.y + rel.rotated(-a).y)
		await tick(1)
	pen.down = false
	await tick(3)
	var hr: Item = board.doc.items[hb.id]
	t.check(absf(rad_to_deg(hr.rot)) > 30.0, "dragging the rotation handle turned the box: %f deg" % rad_to_deg(hr.rot))
	# the handles work with any tool: with Draw, a drag from one reshapes the box instead of drawing
	App.put("tool", "draw")
	var n_items := board.doc.items.size()
	var corner2: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "corner2":
			corner2 = h
	var out_dir: Vector2 = ((corner2.pos as Vector2) - hr.center).normalized()
	var size_draw0 := hr.size
	await hover(world(corner2.pos.x, corner2.pos.y))
	pen.down = true
	await tick(2)
	for i in 8:
		pen.tip = world(corner2.pos.x + out_dir.x * 0.012 * float(i + 1), corner2.pos.y + out_dir.y * 0.012 * float(i + 1))
		await tick(1)
	pen.down = false
	await tick(3)
	t.eq(board.doc.items.size(), n_items, "with the Draw tool, a drag from a handle draws nothing")
	t.check((board.doc.items[hb.id] as Item).size.x > size_draw0.x + 0.03, "...it reshapes the selected box: %s -> %s" % [str(size_draw0), str((board.doc.items[hb.id] as Item).size)])
	App.put("tool", "select")
	board.undo()
	board.undo()
	board.undo()
	board.undo()
	await tick(3)
	board.clear_selection()
	# the same with a hand: pinch the box to select it, pinch a corner handle to scale it, the top handle to turn it
	var hh := HandInput.new("right")
	hh.tracked = true
	hh.aiming = true
	hands = [hh]
	pen.tracked = false
	pen.down = false
	var hbox: Item = board.doc.items[(boxes[0] as Item).id]
	aim(hh, world(hbox.center.x, hbox.center.y))
	await tick(2)
	await pinch_down(hh)
	await pinch_up(hh)
	t.check(board.selection.has(hbox.id), "a pinch on the box selects it")
	var hsize0 := hbox.size
	var hcorner: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "corner1":
			hcorner = h
	aim(hh, world(hcorner.pos.x, hcorner.pos.y))
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "item", "the ray on a corner handle of the selection says so")
	await pinch_down(hh)
	for i in 8:
		aim(hh, world(hcorner.pos.x + 0.015 * float(i + 1), hcorner.pos.y + 0.01 * float(i + 1)))
		await tick(1)
	var hlive: Dictionary = board.selection_view(fnode)
	t.check(not hlive.handles.is_empty() and ((hlive.handles[0] as Dictionary).pos as Vector2).distance_to((board.pen_ctl.handles(fnode)[0] as Dictionary).pos) > 0.02, "while a hand scales, the handles follow the box")
	await pinch_up(hh)
	var hscaled: Item = board.doc.items[hbox.id]
	t.check(hscaled.size.x > hsize0.x + 0.08, "a pinch on a corner handle scaled the box: %s -> %s" % [str(hsize0), str(hscaled.size)])
	var hrot: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "rot":
			hrot = h
	aim(hh, world(hrot.pos.x, hrot.pos.y))
	await tick(2)
	await pinch_down(hh)
	for i in 8:
		var ang := deg_to_rad(8.0 * float(i + 1))
		var rrel: Vector2 = (hrot.pos as Vector2) - hscaled.center
		aim(hh, world(hscaled.center.x + rrel.rotated(-ang).x, hscaled.center.y + rrel.rotated(-ang).y))
		await tick(1)
	await pinch_up(hh)
	t.check(absf(rad_to_deg((board.doc.items[hbox.id] as Item).rot)) > 30.0, "a pinch on the top handle turned the box: %f deg" % rad_to_deg((board.doc.items[hbox.id] as Item).rot))
	board.undo()
	board.undo()
	await tick(3)
	board.clear_selection()
	hands = []

	# lasso select and delete
	App.put("tool", "select")
	await draw(path_of(PackedVector2Array([Vector2(-0.6, -0.15), Vector2(0.8, -0.15), Vector2(0.8, 0.3), Vector2(-0.6, 0.3), Vector2(-0.6, -0.14)])))
	t.check(board.selection.size() >= 3, "the lasso selected the boxes and the arrow: %d" % board.selection.size())
	board.delete_selection()
	t.eq(items_of_kind(Item.SHAPE).size(), 0, "delete removed the selection")
	board.undo()
	t.check(items_of_kind(Item.SHAPE).size() >= 3, "undo restores the deletion")

	# the undo / redo / delete buttons beside the selection box
	t.check(History.LIMIT >= 20, "the history keeps at least 20 levels")
	await draw(path_of(PackedVector2Array([Vector2(-0.6, -0.15), Vector2(0.8, -0.15), Vector2(0.8, 0.3), Vector2(-0.6, 0.3), Vector2(-0.6, -0.14)])))
	var n_shapes := items_of_kind(Item.SHAPE).size()
	var sel_box := board.pen_ctl.group_bounds(board.selected_items())
	var btns: Array = board.pen_ctl.bar_buttons(fnode)
	t.eq(btns.size(), 3, "a selection has undo, redo and delete buttons")
	t.check(btns.size() == 3 and (btns[0].pos as Vector2).x > sel_box.end.x, "the buttons sit beside the box")
	await _press_button("delete", fnode)
	t.eq(items_of_kind(Item.SHAPE).size(), 0, "the delete button removed the selection")
	t.check(board.selection.is_empty(), "...and let go of it")
	t.eq(board.pen_ctl.bar_buttons(fnode).size(), 2, "...leaving undo and redo where the box was")
	await _press_button("undo", fnode)
	t.eq(items_of_kind(Item.SHAPE).size(), n_shapes, "the undo button brought the deleted items back")
	t.eq(board.pen_ctl.bar_buttons(fnode).size(), 3, "...selected again, with all three buttons")
	await _press_button("redo", fnode)
	t.eq(items_of_kind(Item.SHAPE).size(), 0, "the redo button deleted them again")
	await _press_button("undo", fnode)
	board.clear_selection()
	t.eq(board.pen_ctl.bar_buttons(fnode).size(), 0, "no buttons without a selection")

	# the buttons undo and redo only what happened to the selected object
	var two: Array = items_of_kind(Item.SHAPE).filter(func(i): return not (i as Item).is_line())
	t.check(two.size() >= 2, "two boxes to test with")
	if two.size() >= 2:
		var ia: String = (two[0] as Item).id
		var ib: String = (two[1] as Item).id
		var ax0: float = (board.doc.items[ia] as Item).center.x
		var bx0: float = (board.doc.items[ib] as Item).center.x
		board.history.do(History.op_xform2([ia], Transform2D(0.0, Vector2(0.1, 0))))
		board.history.do(History.op_xform2([ib], Transform2D(0.0, Vector2(0.2, 0))))     # the latest operation belongs to the other box
		board.select_items([ia], g.id)
		await _press_button("undo", fnode)
		t.near((board.doc.items[ia] as Item).center.x, ax0, 1e-4, "undo on the selected box took back its own move")
		t.near((board.doc.items[ib] as Item).center.x, bx0 + 0.2, 1e-4, "...and left the other box's later move alone")
		await _press_button("redo", fnode)
		t.near((board.doc.items[ia] as Item).center.x, ax0 + 0.1, 1e-4, "redo on the selected box put its move back")
		t.near((board.doc.items[ib] as Item).center.x, bx0 + 0.2, 1e-4, "...without touching the other box")
		board.history.undo()
		board.history.undo()
		board.clear_selection()

	# several things selected: a corner of the group box scales them all, the top handle turns them all
	await draw(path_of(PackedVector2Array([Vector2(-0.6, -0.15), Vector2(0.8, -0.15), Vector2(0.8, 0.3), Vector2(-0.6, 0.3), Vector2(-0.6, -0.14)])))
	t.check(board.selection.size() >= 3, "the lasso selected the group again")
	var gids: Array = board.selection.duplicate()
	var span0 := _span_of(gids)
	var gcorner: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "gcorner1":
			gcorner = h
	t.check(not gcorner.is_empty(), "a group has corner handles")
	await hover(world(gcorner.pos.x, gcorner.pos.y))
	pen.down = true
	await tick(2)
	for i in 8:
		pen.tip = world(gcorner.pos.x + 0.02 * float(i + 1), gcorner.pos.y + 0.012 * float(i + 1))
		await tick(1)
	var gview: Dictionary = board.selection_view(fnode)
	t.check(not (gview.xf as Transform2D).is_equal_approx(Transform2D.IDENTITY), "while scaling the group, its box and handles are drawn on the group as it is being scaled")
	pen.down = false
	await tick(3)
	var span1 := _span_of(gids)
	t.check(span1.x > span0.x * 1.15, "dragging the group corner scaled everything: %f -> %f wide" % [span0.x, span1.x])
	var grot: Dictionary = {}
	for h in board.pen_ctl.handles(fnode):
		if h.id == "grot":
			grot = h
	var gc := board.pen_ctl.group_bounds(board.selected_items()).get_center()
	var first_before: Vector2 = (board.doc.items[gids[0]] as Item).bounds().get_center()
	await hover(world(grot.pos.x, grot.pos.y))
	pen.down = true
	await tick(2)
	for i in 8:
		var ga := deg_to_rad(10.0 * float(i + 1))
		var grel: Vector2 = (grot.pos as Vector2) - gc
		pen.tip = world(gc.x + grel.rotated(-ga).x, gc.y + grel.rotated(-ga).y)
		await tick(1)
	pen.down = false
	await tick(3)
	var first_after: Vector2 = (board.doc.items[gids[0]] as Item).bounds().get_center()
	t.check(first_after.distance_to(first_before) > 0.05, "dragging the group's top handle turned everything around the group")
	board.undo()
	board.undo()
	await tick(3)
	board.clear_selection()

	# hands point with a ray and pinch: a box is picked and dragged, empty canvas lets go, the bar carries the canvas, a corner resizes it
	var hand := HandInput.new("right")
	hand.tracked = true
	hand.aiming = true
	hands = [hand]
	pen.tracked = false
	pen.down = false
	App.put("tool", "draw")                                  # the hands do not care which tool the stylus has
	var cv: FrameNode = board.frame_nodes[g.id]
	var box: Item = board.doc.items[(boxes[0] as Item).id]
	var c0 := box.center
	aim(hand, world(c0.x, c0.y))
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "item", "the ray on a box says so")
	await pinch_down(hand)
	for i in 10:
		aim(hand, world(c0.x + 0.02 * float(i + 1), c0.y))
		await tick(1)
	await pinch_up(hand)
	t.check(board.selection.has(box.id), "a pinch on a box selects it")
	t.near((board.doc.items[box.id] as Item).center.x - c0.x, 0.2, 0.03, "dragging the box with the hand moved it 20 cm")
	t.check(not board.hand_ctl.is_holding() and not board.grabs.has(g.id), "picking a box up does not pick the canvas up")
	aim(hand, world(0.1, -0.15))
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "canvas", "the ray on empty canvas says so")
	await pinch_down(hand)
	await pinch_up(hand)
	t.check(board.selection.is_empty(), "a pinch on empty canvas lets go of the selection")
	t.check(not board.grabs.has(g.id), "...and does not move the canvas")
	# the bar under the canvas carries it
	var bc := HandController.bar_center(cv)
	var bar_w := cv.global_transform * Vector3(bc.x, bc.y, 0.0)
	aim(hand, bar_w)
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "bar", "the ray on the bar says so")
	await pinch_down(hand)
	t.check(board.grabs.has(g.id), "pinching the bar picks the canvas up")
	var old_anchor := str(board.doc.frames[g.id].anchor)
	for i in 20:
		aim(hand, bar_w + Vector3(0.02 * float(i + 1), 0.0, -0.01 * float(i + 1)))
		await tick(1)
	await pinch_up(hand)
	var fr: FrameData = board.doc.frames[g.id]
	t.near(fr.xf.origin.x, 0.4, 0.05, "the pinch carried the canvas 40 cm to the right: %f" % fr.xf.origin.x)
	await tick(80)
	var fr2: FrameData = board.doc.frames[g.id]
	t.check(str(fr2.anchor) != "" and str(fr2.anchor) != old_anchor, "the moved canvas got a new anchor at its new place")
	t.check(not fr2.anchor_stale(), "the new anchor matches the pose")
	# a corner changes the extent
	var corner_w := cv.global_transform * Vector3((HandController.corner_points(cv)[2] as Vector2).x, (HandController.corner_points(cv)[2] as Vector2).y, 0.0)
	var size0 := cv.bounds().size
	aim(hand, corner_w)
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "corner", "the ray on a corner says so")
	await pinch_down(hand)
	for i in 10:
		aim(hand, corner_w + Vector3(0.03 * float(i + 1), 0.015 * float(i + 1), 0.0))
		await tick(1)
	await pinch_up(hand)
	t.check(cv.bounds().size.x > size0.x + 0.2, "pulling a corner made the canvas wider: %f -> %f" % [size0.x, cv.bounds().size.x])
	# a pinch on empty canvas that moves carries the canvas
	await tick(80)
	var x0: float = (board.doc.frames[g.id] as FrameData).xf.origin.x
	var empty_w := cv.global_transform * Vector3(cv.bounds().get_center().x + 0.3, cv.bounds().get_center().y - 0.3, 0.0)
	aim(hand, empty_w)
	await tick(2)
	t.eq(str(board.hand_ctl.hover.get("right", {}).get("kind", "")), "canvas", "the ray is on empty canvas")
	await pinch_down(hand)
	for i in 10:
		aim(hand, empty_w + Vector3(0.02 * float(i + 1), 0.0, 0.0))
		await tick(1)
	await pinch_up(hand)
	t.near((board.doc.frames[g.id] as FrameData).xf.origin.x - x0, 0.2, 0.03, "dragging empty canvas moved it 20 cm")
	# both hands: the right carries by the bar, the left pinches anywhere (its ray on no canvas) and joins; spreading them scales up
	await tick(80)
	var left := HandInput.new("left")
	left.tracked = true
	left.aiming = true
	hands = [hand, left]
	var scale0: float = (board.doc.frames[g.id] as FrameData).scale
	var bcw := cv.global_transform * Vector3(HandController.bar_center(cv).x, HandController.bar_center(cv).y, 0.0)
	aim(hand, bcw)
	await tick(2)
	await pinch_down(hand)
	left.aim_o = bcw + Vector3(-0.3, 0.0, 0.6)
	left.aim_d = Vector3(-1, 0, 0)                     # pointing away from every canvas
	left.press_o = left.aim_o
	left.press_d = left.aim_d
	left.pinch_point = bcw + Vector3(-0.3, 0.0, 0.05)
	await pinch_down(left)
	t.check(board.hand_ctl.is_holding() and board.grabs.has(g.id), "the second hand joins the carried canvas")
	for i in 10:
		left.pinch_point += Vector3(-0.02, 0.0, 0.0)
		hand.pinch_point += Vector3(0.02, 0.0, 0.0)
		await tick(1)
	t.check(float((board.grabs[g.id] as Dictionary).scale) > scale0 * 1.5, "spreading both hands scales the canvas up: %f" % float((board.grabs[g.id] as Dictionary).scale))
	await pinch_up(left)
	await pinch_up(hand)
	board.undo()
	await tick(3)
	# its place locked: the bar does not carry it, and two hands only resize it, about its middle: it neither turns nor moves
	await tick(80)
	board.set_frame_prop(g.id, "place_locked", true)
	await tick(2)
	var p_xf := (board.doc.frames[g.id] as FrameData).xf
	var p_scale := (board.doc.frames[g.id] as FrameData).scale
	var p_steps := board.history.undo_stack.size()
	var p_mid := cv.to_world_point(Vector3(cv.bounds().get_center().x, cv.bounds().get_center().y, 0.0))
	var pbar := cv.global_transform * Vector3(HandController.bar_center(cv).x, HandController.bar_center(cv).y, 0.0)
	hands = [hand]
	aim(hand, pbar)
	await tick(2)
	await pinch_down(hand)
	for i in 10:
		aim(hand, pbar + Vector3(0.03 * float(i + 1), 0.02 * float(i + 1), 0.0))
		await tick(1)
	await pinch_up(hand)
	t.check((board.doc.frames[g.id] as FrameData).xf.is_equal_approx(p_xf), "its place locked, the bar does not carry the canvas")
	t.eq(board.history.undo_stack.size(), p_steps, "...and holding it leaves nothing to undo")
	hands = [hand, left]
	aim(hand, pbar)
	left.aim_o = pbar + Vector3(-0.3, 0.0, 0.6)
	left.aim_d = Vector3(-1, 0, 0)
	left.press_o = left.aim_o
	left.press_d = left.aim_d
	left.pinch_point = pbar + Vector3(-0.3, 0.0, 0.05)
	await tick(2)
	await pinch_down(hand)
	await pinch_down(left)
	for i in 10:
		var pm := (hand.pinch_point + left.pinch_point) * 0.5
		var turn := Basis(Vector3.UP, deg_to_rad(3.0))
		hand.pinch_point = pm + turn * (hand.pinch_point - pm) * 1.05
		left.pinch_point = pm + turn * (left.pinch_point - pm) * 1.05
		await tick(1)
	await pinch_up(left)
	await pinch_up(hand)
	await tick(2)
	var pl: FrameData = board.doc.frames[g.id]
	t.check(pl.scale > p_scale * 1.4, "two hands still resize it: %.2f -> %.2f" % [p_scale, pl.scale])
	t.check(pl.xf.basis.orthonormalized().is_equal_approx(p_xf.basis.orthonormalized()), "...but do not turn it (the hands turned 30 degrees)")
	var p_mid2 := cv.to_world_point(Vector3(cv.bounds().get_center().x, cv.bounds().get_center().y, 0.0))
	t.check(p_mid2.distance_to(p_mid) < 0.003, "...nor move it: it grew about its middle (%.1f mm off)" % (p_mid2.distance_to(p_mid) * 1000.0))
	board.undo()
	board.undo()
	await tick(3)
	t.check(not (board.doc.frames[g.id] as FrameData).place_locked and is_equal_approx((board.doc.frames[g.id] as FrameData).scale, p_scale), "undo: its size, then the lock")
	hands = []
	# carried by one hand, a canvas turns to face the head (about the vertical); two hands set which way it faces
	await tick(80)
	square_up(g.id)
	await tick(2)
	var face_xf := (board.doc.frames[g.id] as FrameData).xf
	var face_mid := cv.to_world_point(Vector3(cv.bounds().get_center().x, cv.bounds().get_center().y, 0.0))
	var face_bar := cv.global_transform * Vector3(HandController.bar_center(cv).x, HandController.bar_center(cv).y, 0.0)
	hands = [hand]
	aim(hand, face_bar)
	await tick(2)
	await pinch_down(hand)
	for i in 30:
		hand.pinch_point += Vector3(0.04, 0.0, 0.0)
		hand.tip = hand.pinch_point
		await tick(1)
	var carried := (board.grabs[g.id] as Dictionary).xf as Transform3D
	var cmid := carried * (Vector3(cv.bounds().get_center().x, cv.bounds().get_center().y, 0.0) * float((board.grabs[g.id] as Dictionary).scale))
	var to_head := Vector3(-cmid.x, 0.0, -cmid.z).normalized()
	t.check(Vector3(carried.basis.z.x, 0.0, carried.basis.z.z).normalized().angle_to(to_head) < 0.15, "carried sideways, the canvas turned to face the head")
	t.check(absf(carried.basis.z.y) < 0.01 and carried.basis.y.y > 0.99, "...about the vertical only: it stays upright")
	await pinch_up(hand)
	hands = []
	board.undo()
	await tick(3)
	var fs: FrameData = board.doc.frames[g.id]
	t.check(board.hand_ctl._turns_to_face(fs, {}), "a wall canvas turns to face the head when carried")
	t.check(not board.hand_ctl._turns_to_face(fs, {"turned": true}), "...but not once two hands have set its way")
	fs.surface = true
	t.check(not board.hand_ctl._turns_to_face(fs, {}), "a canvas on a physical surface keeps its way")
	fs.surface = false
	fs.bend = true
	t.check(not board.hand_ctl._turns_to_face(fs, {}), "so does a curved desk")
	fs.bend = false
	var turned := HandController.turned_to_face(face_xf, face_mid, Vector3(5.0, 1.6, 0.0), 1.0)
	t.check(not turned.basis.is_equal_approx(face_xf.basis) and turned.origin.distance_to(face_xf.origin) > 0.01, "an upright canvas is turned about its middle towards a head at its side")
	t.check((turned * (face_xf.affine_inverse() * face_mid)).distance_to(face_mid) < 0.001, "...its middle staying where it was")
	var lying := Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 0.7, -1.0))
	t.check(HandController.turned_to_face(lying, lying.origin, Vector3(5.0, 1.6, 0.0), 1.0).is_equal_approx(lying), "a canvas lying flat is left as it is")
	# touching and pointing: a hand held back from the canvas points, the ray chooses and the canvas moves further than the hand
	await tick(80)
	square_up(g.id)
	await tick(2)
	var far := HandInput.new("right")
	far.tracked = true
	far.aiming = true
	hands = [far]
	var fbar := on_canvas(cv, HandController.bar_center(cv))
	aim_far(far, fbar)
	await tick(2)
	t.eq(hover_kind("right"), "bar", "a hand held back, pointing at the bar, says so")
	t.check(not hover_direct("right"), "...by its ray, not by touching")
	var fx0: float = (board.doc.frames[g.id] as FrameData).xf.origin.x
	await pinch_down(far)
	for i in 10:
		far.pinch_point += Vector3(0.01, 0.0, 0.0)
		await tick(1)
	await pinch_up(far)
	var fmoved: float = (board.doc.frames[g.id] as FrameData).xf.origin.x - fx0
	t.check(fmoved > 0.2 and fmoved < 0.1 * InputTuning.MAX_GAIN + 0.01, "pointing from afar: a 10 cm hand movement carried the canvas further: %f" % fmoved)
	await tick(80)
	square_up(g.id)
	await tick(2)
	# an item by ray: the ray moves it
	var fbox := board.doc.items[box.id] as Item
	var fc0 := fbox.center
	aim_far(far, on_canvas(cv, fc0))
	await tick(2)
	t.eq(hover_kind("right"), "item", "pointing at a box says so")
	await pinch_down(far)
	for i in 10:
		aim_far(far, on_canvas(cv, fc0) + Vector3(0.01 * float(i + 1), 0.0, 0.0))
		await tick(1)
	await pinch_up(far)
	t.near((board.doc.items[box.id] as Item).center.x - fc0.x, 0.1 / cv.data.scale, 0.03, "a box dragged by ray follows the ray")
	board.undo()
	board.clear_selection()
	await tick(80)
	# with the Select tool, a pinch on empty canvas from a distance draws a loop: what it goes round is selected, the canvas stays put
	App.put("tool", "select")
	var lb := (board.doc.items[box.id] as Item).bounds()
	var lc := lb.get_center()
	var lr := lb.size.length() * 0.75
	var lxf := (board.doc.frames[g.id] as FrameData).xf
	aim_far(far, on_canvas(cv, lc + Vector2(0.0, lr)))      # (above the box: the line joining it to the next box leaves on its right)
	await tick(2)
	t.eq(hover_kind("right"), "canvas", "pointing at empty canvas beside the box")
	await pinch_down(far)
	var looping := false
	for i in 24:
		var la := PI * 0.5 + TAU * float(i + 1) / 24.0
		aim_far(far, on_canvas(cv, lc + Vector2(cos(la), sin(la)) * lr))
		await tick(1)
		for c in board.hand_ctl.controllers():
			looping = looping or ((c as PenController).state == PenController.S.LASSO and (c as PenController).lasso.size() > 10)
	t.check(looping, "pointing from afar with the Select tool, a pinch on empty canvas draws a loop where the ray runs")
	await pinch_up(far)
	t.check(board.selection.has(box.id), "...that selects the box it went round")
	t.check((board.doc.frames[g.id] as FrameData).xf.is_equal_approx(lxf) and not board.grabs.has(g.id), "...and does not move the canvas")
	board.clear_selection()
	App.put("tool", "draw")
	hands = []
	await tick(80)

	# the stylus's front button grabs with the same rules as a pinch
	square_up(g.id)
	await tick(2)
	var items_total_before_stylus := board.doc.items.size()
	pen.dir = Vector3(0, 0, -1)
	var sbox := board.doc.items[box.id] as Item
	var sc0 := sbox.center
	await hover(on_canvas(cv, sc0))
	await tick(2)
	t.eq(hover_kind("pen"), "item", "the stylus on a box says so")
	t.check(hover_direct("pen"), "...by touching it")
	pen.front = true
	await tick(2)
	for i in 10:
		pen.tip = on_canvas(cv, sc0) + Vector3(0.02 * float(i + 1), 0.0, 0.0)
		await tick(1)
	pen.front = false
	await tick(3)
	t.check(board.selection.has(box.id) and not board.grabs.has(g.id), "the front button on a box selects it, not the canvas")
	t.near((board.doc.items[box.id] as Item).center.x - sc0.x, 0.2 / cv.data.scale, 0.03, "...and drags it with the nib")
	board.undo()
	board.clear_selection()
	await tick(80)
	# the bar under the canvas
	var sbar := on_canvas(cv, HandController.bar_center(cv))
	var sx0: float = (board.doc.frames[g.id] as FrameData).xf.origin.x
	await hover(sbar)
	await tick(2)
	t.eq(hover_kind("pen"), "bar", "the stylus on the bar says so")
	pen.front = true
	await tick(2)
	t.check(board.grabs.has(g.id), "the front button on the bar picks the canvas up")
	pen.down = true
	pen.pressure = 0.8
	var strokes0 := items_of_kind(Item.STROKE).size()
	await tick(3)
	pen.down = false
	t.eq(items_of_kind(Item.STROKE).size(), strokes0, "while the front button holds something the nib draws nothing")
	for i in 10:
		pen.tip = sbar + Vector3(0.02 * float(i + 1), 0.0, 0.0)
		await tick(1)
	pen.front = false
	await tick(3)
	t.near((board.doc.frames[g.id] as FrameData).xf.origin.x - sx0, 0.2, 0.03, "the nib carried the canvas 1:1")
	await tick(80)
	# the stylus's front button and a bare hand turn and resize a canvas together, like two hands
	var tbar := on_canvas(cv, HandController.bar_center(cv))
	await hover(tbar)
	pen.front = true
	await tick(2)
	t.check(board.grabs.has(g.id), "the front button on the bar picks the canvas up (to be joined by a hand)")
	var other := HandInput.new("right")
	other.tracked = true
	other.aiming = true
	other.aim_o = tbar + Vector3(0.3, 0.0, 0.6)
	other.aim_d = Vector3(1, 0, 0)                      # pointing away from every canvas
	other.press_o = other.aim_o
	other.press_d = other.aim_d
	other.pinch_point = tbar + Vector3(0.3, 0.0, 0.05)
	other.tip = other.pinch_point
	hands = [other]
	var tscale0: float = (board.doc.frames[g.id] as FrameData).scale
	await pinch_down(other)
	for i in 10:
		other.pinch_point += Vector3(0.02, 0.0, 0.0)
		await tick(1)
	t.check(float((board.grabs[g.id] as Dictionary).scale) > tscale0 * 1.4, "spreading hand and stylus scales the canvas up: %f" % float((board.grabs[g.id] as Dictionary).scale))
	pen.front = false
	await pinch_up(other)
	await tick(3)
	hands = []
	t.check(not board.hand_ctl.is_holding() and board.grabs.is_empty(), "letting go of both ends the grab")
	board.undo()
	await tick(80)
	# empty canvas: a tap lets go of the selection, a drag carries the canvas
	board.select_items([box.id], g.id)
	var sempty := on_canvas(cv, cv.bounds().get_center() + Vector2(0.3, -0.3))
	await hover(sempty)
	await tick(2)
	t.eq(hover_kind("pen"), "canvas", "the stylus on empty canvas says so")
	pen.front = true
	await tick(2)
	pen.front = false
	await tick(3)
	t.check(board.selection.is_empty() and not board.grabs.has(g.id), "a front-button tap on empty canvas lets go of the selection")
	var ey0: float = (board.doc.frames[g.id] as FrameData).xf.origin.y
	await hover(sempty)
	pen.front = true
	await tick(2)
	for i in 10:
		pen.tip = sempty + Vector3(0.0, 0.02 * float(i + 1), 0.0)
		await tick(1)
	pen.front = false
	await tick(3)
	t.near((board.doc.frames[g.id] as FrameData).xf.origin.y - ey0, 0.2, 0.03, "a front-button drag on empty canvas carried it")
	await tick(80)
	# a corner: the stylus resizes like a hand
	square_up(g.id)
	await tick(2)
	var scs := HandController.corner_points(cv)
	var scorner := on_canvas(cv, scs[2])
	var ssize0 := cv.bounds().size
	await hover(scorner)
	await tick(2)
	t.eq(hover_kind("pen"), "corner", "the stylus on a corner says so")
	pen.front = true
	await tick(2)
	for i in 10:
		pen.tip = scorner + Vector3(0.03 * float(i + 1), 0.015 * float(i + 1), 0.0)
		await tick(1)
	pen.front = false
	await tick(3)
	t.check(cv.bounds().size.x > ssize0.x + 0.2, "the front button on a corner made the canvas wider: %f -> %f" % [ssize0.x, cv.bounds().size.x])
	await tick(80)
	# from a distance: the stylus points along its body, the ray chooses, the nib's movement is geared up
	var abar := on_canvas(cv, HandController.bar_center(cv))
	pen.tracked = true
	pen.source = "mouse"
	pen.tip = Vector3(0.0, 1.5, -0.4)
	pen.dir = (abar - pen.tip).normalized()
	await tick(2)
	t.eq(hover_kind("pen"), "bar", "the stylus pointing at the bar from afar says so")
	t.check(not hover_direct("pen"), "...by its ray")
	var ax0: float = (board.doc.frames[g.id] as FrameData).xf.origin.x
	pen.front = true
	await tick(2)
	for i in 10:
		pen.tip += Vector3(0.01, 0.0, 0.0)
		await tick(1)
	pen.front = false
	await tick(3)
	var amoved: float = (board.doc.frames[g.id] as FrameData).xf.origin.x - ax0
	t.check(amoved > 0.2 and amoved < 0.1 * InputTuning.MAX_GAIN + 0.01, "pointing the stylus from afar carried the canvas further than the nib moved: %f" % amoved)
	await tick(80)
	# a press that starts on the board belongs to the tool: the front button then does not grab
	var near_pt := on_canvas(cv, cv.bounds().get_center() + Vector2(0.3, -0.3))
	await hover(near_pt)
	App.put("tool", "draw")
	pen.down = true
	pen.pressure = 0.8
	await tick(3)
	pen.front = true
	await tick(3)
	t.check(not board.hand_ctl.is_holding() and board.grabs.is_empty(), "the front button pressed while drawing does not grab")
	pen.down = false
	pen.front = false
	await tick(3)
	if board.doc.items.size() > items_total_before_stylus:
		board.undo()
	# the back button: undo at once; with the front button held: redo
	pen.tracked = false
	pen.down = false
	var n_back := board.doc.items.size()
	board.history.do(History.op_add([board.make_shape(g.id, {"shape": "rect", "center": Vector2(0, 0), "size": Vector2(0.1, 0.1)})]))
	t.eq(board.doc.items.size(), n_back + 1, "(a shape to undo)")
	pen.back = true
	await tick(1)
	t.eq(board.doc.items.size(), n_back, "the back button undoes at once")
	pen.back = false
	await tick(2)
	pen.front = true
	pen.back = true
	await tick(1)
	t.eq(board.doc.items.size(), n_back + 1, "the back button with the front button held redoes")
	pen.front = false
	pen.back = false
	await tick(2)
	board.undo()
	await tick(2)
	# Bring canvas here: its middle within reach in front of the eyes
	board.bring_canvas_here()
	await tick(3)
	var mid := cv.bounds().get_center()
	var mid_w := cv.global_transform * Vector3(mid.x, mid.y, 0.0)
	t.near(mid_w.distance_to(Vector3(0, 1.4, -Board.REACH_DIST)), 0.0, 0.03, "the canvas is brought within reach: %s" % str(mid_w))
	board.undo()
	await tick(3)

	# drawing in the air is switched off: a stroke far from every canvas makes nothing
	App.put("tool", "draw")
	var frames_before := board.doc.frames.size()
	var items_before := board.doc.items.size()
	await draw([Vector3(3.0, 1.5, 2.0), Vector3(3.1, 1.52, 2.0), Vector3(3.2, 1.6, 2.0), Vector3(3.3, 1.55, 2.0)])
	t.eq(board.doc.frames.size(), frames_before, "no 3D sketch is started in the air")
	t.eq(board.doc.items.size(), items_before, "and nothing is drawn there")

	# rooms: walk into another (simulated) room
	var room_a: String = board.current_room
	App.put("sim_room", "B")
	await tick(10)
	t.eq(board.room_state, "found", "a room whose anchors drop out for a moment stays where it was (the headset re-localising)")
	await tick(int(Board.ROOM_HOLD_S / 0.016) + 5)
	t.eq(board.room_state, "searching", "in an unknown room the app searches")
	t.check(not board.frame_nodes[g.id].visible, "room A's canvas is hidden in room B")
	await tick(int(Board.ROOM_SEARCH_S / 0.016) + 20)
	t.eq(board.room_state, "assumed", "after a while the last room is shown anyway, in front of the user")
	t.check(board.frame_nodes[g.id].visible, "its canvas is visible again")
	var shown_at := (board.frame_nodes[g.id] as FrameNode).global_position
	t.near(shown_at.distance_to(Vector3(0, 1.4, -Board.REACH_DIST)), 0.0, 0.05, "within reach in front of the head: %s" % str(shown_at))
	board.create_room_here("Room B")
	await tick(5)
	t.eq(board.room_state, "found", "the new room is current")
	t.eq(board.doc.rooms.size(), 2, "two rooms now")
	var fb := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(1, 1.3, -2)))
	await tick(60)
	t.check(board.frame_nodes[fb.id].visible and not board.frame_nodes[g.id].visible, "only room B's canvas is shown in room B")
	App.put("sim_room", "A")
	await tick(int(Board.ROOM_HOLD_S / 0.016) + 10)
	t.eq(board.current_room, room_a, "back in room A the app recognises it by its anchors")
	t.check(board.frame_nodes[g.id].visible and not board.frame_nodes[fb.id].visible, "room A's canvas is back, room B's is hidden")

	# save and reload
	board.flush_save()
	board.doc.save()
	var reloaded := Document.load_file(board.doc.path)
	t.check(reloaded != null and reloaded.items.size() == board.doc.items.size(), "document round trip keeps every item")
	t.eq(reloaded.frames.size(), board.doc.frames.size(), "frames round trip")

	# export
	var svgs := SvgExport.export_document(board.doc, "user://test_export_board")
	t.check(svgs.size() >= 1, "svg export wrote files")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(board.doc.path))
