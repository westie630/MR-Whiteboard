extends Node
## Two copies of the real PC app in one session, to look at what the others see while somebody draws: the owner draws a stroke slowly
## with synthetic mouse events and holds the pen down part way; the guest takes a picture while it is still being drawn, and another
## when it is finished. Start both (the owner first), each in its own window with its own folders:
##   godot --path . res://tools/dev/sim_session.tscn -- --owner --demo --docs-dir=A --settings=A.cfg --host=Owner --code=1234 --out=shots/owner.png
##   godot --path . res://tools/dev/sim_session.tscn -- --guest --new --docs-dir=B --settings=B.cfg --join=127.0.0.1 --code=1234 --out=shots/guest.png
## (the arguments after -- are also the main scene's: see main.gd). The guest writes <out> and <out>_after.png.

var main: Node
var rig: DesktopRig
var board: Board
var out := "build/shots/session.png"


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := String(a).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("out"):
		out = str(args.out)
	if args.has("docs-dir"):
		App.docs_dir = str(args["docs-dir"])
	if args.has("settings"):
		App.settings_path = str(args["settings"])
		App.reload()
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)
	get_window().size = Vector2i(1200, 800)
	for i in 5:
		await get_tree().process_frame
	rig = main.rig as DesktopRig
	board = main.board
	if args.has("owner"):
		await owner()
	else:
		await guest()
	get_tree().quit()


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout


func main_canvas() -> FrameNode:
	for fn in board.visible_frames(FrameData.CANVAS):
		return fn
	return null


func px(fn: FrameNode, p: Vector2) -> Vector2:
	return rig.view_to_window(rig.camera.unproject_position(fn.to_world_point(Vector3(p.x, p.y, 0.0))))


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


func shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var full := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(full.get_base_dir())
	img.save_png(full)
	print("[sim_session] saved ", full)


func owner() -> void:
	var waited := 0.0
	while board.session.guest_count() < 1 and waited < 60.0:
		await seconds(0.2)
		waited += 0.2
	print("[sim_session] owner: %d guest(s) in after %.1f s" % [board.session.guest_count(), waited])
	await seconds(2.0)
	var fn := main_canvas()
	if fn == null:
		print("[sim_session] no canvas")
		return
	App.put("tool", "draw")
	App.put("brush", "marker")
	App.put("color", Color("#ff5d8f"))
	App.put("width", 0.012)
	var pts: Array = []
	for i in 70:
		var t := float(i) / 69.0
		pts.append(px(fn, Vector2(-0.45 + t * 0.9, 0.0 + 0.12 * sin(t * TAU * 1.5))))
	move_mouse(pts[0])
	await frames(3)
	button(pts[0], true)
	await frames(2)
	for i in 46:                                         # two thirds of the way, then the hand stays on the canvas
		move_mouse(pts[i])
		await seconds(0.05)
	print("[sim_session] owner: holding the pen down part way")
	await seconds(9.0)
	for i in range(46, pts.size()):
		move_mouse(pts[i])
		await seconds(0.04)
	button(pts[pts.size() - 1], false)
	print("[sim_session] owner: stroke finished")
	await seconds(5.0)


func guest() -> void:
	var waited := 0.0
	var seen := false
	while waited < 80.0:
		await seconds(0.2)
		waited += 0.2
		if board.session.previews != null and board.session.previews.stroke_count() >= 1 and board.session.previews.stroke_points() > 25:
			seen = true
			break
	print("[sim_session] guest: live stroke seen = %s (%d points) after %.1f s, items in document: %d" % [seen, board.session.previews.stroke_points(), waited, board.doc.items.size()])
	await seconds(1.0)
	print("[sim_session] guest: now %d points, items in document: %d" % [board.session.previews.stroke_points(), board.doc.items.size()])
	shot(out)
	var before := board.doc.items.size()
	waited = 0.0
	while board.doc.items.size() == before and waited < 40.0:
		await seconds(0.2)
		waited += 0.2
	await seconds(1.5)
	print("[sim_session] guest: finished stroke arrived = %s, previews left: %d" % [board.doc.items.size() > before, board.session.previews.count()])
	shot(out.replace(".png", "_after.png"))
