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

	# lasso select and delete
	App.put("tool", "select")
	await draw(path_of(PackedVector2Array([Vector2(-0.6, -0.15), Vector2(0.8, -0.15), Vector2(0.8, 0.3), Vector2(-0.6, 0.3), Vector2(-0.6, -0.14)])))
	t.check(board.selection.size() >= 3, "the lasso selected the boxes and the arrow: %d" % board.selection.size())
	board.delete_selection()
	t.eq(items_of_kind(Item.SHAPE).size(), 0, "delete removed the selection")
	board.undo()
	t.check(items_of_kind(Item.SHAPE).size() >= 3, "undo restores the deletion")

	# hands: pinch the canvas and carry it
	var hand := HandInput.new("right")
	hand.tracked = true
	hands = [hand]
	hand.tip = world(0.0, -0.3)
	hand.pinch_point = world(0.0, -0.3)
	hand.pinching = true
	hand.pinch_down = true
	pen.tracked = false
	await tick(1)
	hand.pinch_down = false
	var old_anchor := str(board.doc.frames[g.id].anchor)
	for i in 20:
		hand.pinch_point = world(0.0, -0.3) + Vector3(0.02 * i, 0.0, -0.01 * i)
		await tick(1)
	hand.pinching = false
	hand.pinch_up = true
	await tick(2)
	hand.pinch_up = false
	var fr: FrameData = board.doc.frames[g.id]
	t.near(fr.xf.origin.x, 0.38, 0.05, "the pinch carried the canvas 38 cm to the right: %f" % fr.xf.origin.x)
	await tick(80)
	var fr2: FrameData = board.doc.frames[g.id]
	t.check(str(fr2.anchor) != "" and str(fr2.anchor) != old_anchor, "the moved canvas got a new anchor at its new place")
	t.check(not fr2.anchor_stale(), "the new anchor matches the pose")
	hands = []

	# rooms: walk into another (simulated) room
	var room_a: String = board.current_room
	App.put("sim_room", "B")
	await tick(10)
	t.eq(board.room_state, "searching", "in an unknown room the app searches")
	t.check(not board.frame_nodes[g.id].visible, "room A's canvas is hidden in room B")
	await tick(int(Board.ROOM_SEARCH_S / 0.016) + 20)
	t.eq(board.room_state, "needs_room", "after a while it offers to create a room")
	board.create_room_here("Room B")
	await tick(5)
	t.eq(board.room_state, "found", "the new room is current")
	t.eq(board.doc.rooms.size(), 2, "two rooms now")
	var fb := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(1, 1.3, -2)))
	await tick(60)
	t.check(board.frame_nodes[fb.id].visible and not board.frame_nodes[g.id].visible, "only room B's canvas is shown in room B")
	App.put("sim_room", "A")
	await tick(10)
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
