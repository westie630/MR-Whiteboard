extends Node
## End-to-end check of the PC app with synthetic mouse events: it starts the real main scene, places a canvas, and draws on it the
## way a person would (strokes, hold to snap, stencils, handwriting) through the desktop rig, then saves a screenshot.
##   godot --path . res://tools/dev/sim_draw.tscn -- build/shots/sim.png
## Needs internet for the handwriting step (skipped when offline).

var main: Node
var rig: DesktopRig
var board: Board
var out := "res://build/shots/sim.png"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	_wipe("user://sim_docs")
	for f in ["user://sim_settings.cfg", "user://sim_anchors.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	App.settings_path = "user://sim_settings.cfg"
	App.docs_dir = "user://sim_docs"
	App.reload()
	App.put("sim_room", "A")
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)
	get_window().size = Vector2i(1500, 900)
	for i in 5:
		await get_tree().process_frame
	rig = main.rig as DesktopRig
	board = main.board
	rig.camera.position = Vector3(0.35, 1.45, 0.55)
	rig._yaw = 0.0
	rig._pitch = -0.02
	rig._apply_look()
	await frames(100)                                    # the first room appears by itself
	var f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.45, -1.2)), Vector2(1.7, 1.0))
	await frames(40)
	print("[sim] room=%s state=%s frame=%s" % [board.current_room, board.room_state, f.name])

	# 1. freehand with the pen, a flow box with a held snap
	App.put("tool", "draw")
	App.put("recognize", "hold")
	App.put("brush", "pen")
	App.put("color", Color("#ffd166"))
	var wave: Array = []
	for i in 40:
		wave.append(canvas_px(-0.75 + float(i) * 0.012, 0.38 + sin(float(i) * 0.4) * 0.04))
	await stroke(wave, 0.0)
	var rect := PackedVector2Array()
	for p in Synth.rect(0.3, 0.17, Vector2(-0.45, 0.1), 0.02):
		rect.append(p)
	await stroke(_to_px(rect), 0.8)
	var circle := Synth.ellipse(0.1, 0.1, Vector2(0.05, 0.1))
	await stroke(_to_px(circle), 0.8)
	var line := Synth.line(Vector2(-0.75, -0.12), Vector2(-0.1, -0.1))
	await stroke(_to_px(line), 0.8)
	print("[sim] after drawing: %d items %s" % [board.doc.items.size(), _kinds()])

	# 2. stencils: a diamond and an arrow glued to the first box
	App.put("tool", "shape")
	board.stencil = "diamond"
	App.put("color", Color("#ef476f"))
	await stroke([canvas_px(0.35, 0.0), canvas_px(0.65, 0.2)], 0.0)
	board.stencil = "arrow"
	App.put("color", Color("#3fe0c8"))
	var boxes := []
	for it in board.doc.items.values():
		if (it as Item).kind == Item.SHAPE and (it as Item).shape == "rect":
			boxes.append(it)
	if not boxes.is_empty():
		var bx: Item = boxes[0]
		var port := Shapes.port_world(bx, 1)
		await stroke([canvas_px(port.pos.x + 0.01, port.pos.y), canvas_px(0.34, 0.1)], 0.0)

	# 3. handwriting: block letters through the Write tool, read by the online recogniser
	App.put("tool", "write")
	App.put("color", Color.WHITE)
	var letters := _block_word(Vector2(-0.2, -0.38), 0.07, "HELLO")
	for s in letters:
		await stroke(s, 0.0)
	await frames(10)
	print("[sim] writing: %d pending strokes" % board.ink.pending.size())
	board.ink.convert_ink()
	var waited := 0.0
	while board.ink.busy and waited < 15.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	await frames(10)
	var texts := []
	for it in board.doc.items.values():
		if (it as Item).kind == Item.TEXT:
			texts.append((it as Item).text)
	print("[sim] text items: ", texts, "  (error: %s)" % board.ink.last_error)

	# 4. hover the pen over the canvas so the grid lights up around it, then screenshot
	App.put("tool", "draw")
	var hover := canvas_px(0.45, -0.25)
	move_mouse(hover)
	await frames(30)
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("[sim] saved ", path, "  items: ", _kinds())
	board.flush_save()
	get_tree().quit()


func _wipe(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/" + f))


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func canvas_px(x: float, y: float) -> Vector2:
	return rig.view_to_window(rig.camera.unproject_position(Vector3(x, 1.45 + y, -1.2)))


func _to_px(poly: PackedVector2Array) -> Array:
	var out_pts: Array = []
	for p in poly:
		out_pts.append(canvas_px(p.x, p.y))
	return out_pts


func move_mouse(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	Input.parse_input_event(e)


func button(p: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = p
	e.global_position = p
	Input.parse_input_event(e)


## Press at the first point, drag through the rest, hold still for `hold` seconds, release.
func stroke(points: Array, hold: float) -> void:
	move_mouse(points[0])
	await frames(3)
	button(points[0], true)
	await frames(2)
	for p in points:
		move_mouse(p)
		await get_tree().process_frame
	if hold > 0.0:
		await get_tree().create_timer(hold).timeout
	button(points[points.size() - 1], false)
	await frames(4)


## Block capital letters as strokes in canvas coordinates (as arrays of pixel points).
func _block_word(origin: Vector2, h: float, word: String) -> Array:
	var shapes := {
		"H": [[Vector2(0, 0), Vector2(0, 1)], [Vector2(0.6, 0), Vector2(0.6, 1)], [Vector2(0, 0.5), Vector2(0.6, 0.5)]],
		"E": [[Vector2(0.5, 0), Vector2(0, 0), Vector2(0, 1), Vector2(0.5, 1)], [Vector2(0, 0.5), Vector2(0.4, 0.5)]],
		"L": [[Vector2(0, 0), Vector2(0, 1), Vector2(0.5, 1)]],
		"O": [],
	}
	var out_strokes: Array = []
	var x := origin.x
	for ch in word:
		if ch == "O":
			var pts: Array = []
			for i in 33:
				var a := TAU * float(i) / 32.0 - PI * 0.5
				pts.append(canvas_px(x + 0.3 * h + cos(a) * 0.32 * h, origin.y + h * 0.5 - sin(a) * 0.5 * h))
			out_strokes.append(pts)
			x += h * 0.95
			continue
		for s in shapes[ch]:
			var pts2: Array = []
			for k in range((s as Array).size() - 1):
				var a2: Vector2 = s[k]
				var b2: Vector2 = s[k + 1]
				var n := maxi(int(a2.distance_to(b2) * h / 0.006), 2)
				for j in n:
					var p: Vector2 = a2.lerp(b2, float(j) / n)
					pts2.append(canvas_px(x + p.x * h, origin.y + h - p.y * h))
			var last: Vector2 = s[(s as Array).size() - 1]
			pts2.append(canvas_px(x + last.x * h, origin.y + h - last.y * h))
			out_strokes.append(pts2)
		x += h * 0.95
	return out_strokes


func _kinds() -> String:
	var c := {}
	for it in board.doc.items.values():
		var k := "%s:%s" % [(it as Item).kind, (it as Item).shape] if (it as Item).kind == Item.SHAPE else (it as Item).kind
		c[k] = int(c.get(k, 0)) + 1
	return str(c)
