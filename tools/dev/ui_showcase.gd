extends Node
## Puts the PC app into states that are hard to reach by hand, for screenshots of the interface (no network: a stand-in handwriting
## reader and a stand-in language model answer):
##   godot --path . res://tools/dev/ui_showcase.tscn -- --demo --docs-dir=DIR --settings=FILE --show=ink|readings|ai --out=PATH
##   ink       words written with the pen: the chip offers to turn them into text
##   readings  ...converted: the other readings beside the new text
##   ai        the assistant answered with a drawing: the suggestion bar on the canvas, the assistant panel open
##   desk      feeling for the desk: the mouse presses on the simulated table, the card shows the points and the fitted desk
##   deskcanvas ...and Done: the canvas lies on the table with a stroke drawn on it
##   curved    ...as a curved desk: the canvas lies on the table, bends up and climbs the wall, with drawings across all of it
##   curvedside ...seen from the side, with the markers lit

class FakeInk extends InkRecognizer:
	func name_of() -> String:
		return "google"

	func recognize(_strokes: Array, _area: Vector2, _lang: String, done: Callable) -> void:
		done.call({"ok": true, "candidates": PackedStringArray(["hello", "hallo", "hell o", "bello"]), "error": ""})


class FakeClient extends RefCounted:
	var n := 0

	func list_models(_provider: String, _key: String, done: Callable) -> void:
		done.call({"ok": true, "error": "", "models": [{"id": "claude-opus-5-5", "name": "Claude Opus 5.5", "vision": true, "modes": [["default", "Model default"], ["high", "High"]]}]})

	func chat(_p: String, _k: String, _m: String, _mode: String, _s: String, _h: Array, _prompt: String, _png: PackedByteArray, done: Callable) -> void:
		n += 1
		if n == 1:
			done.call({"ok": true, "text": JSON.stringify({"say": "The flow reads well left to right. What is unclear is what happens after Fix: the arrow back to Load data suggests a retry, but nothing says when to stop. A Review step and a note on what OK? checks would close that gap.", "add": [], "change": [], "remove": []}), "error": "", "left_out": PackedStringArray()})
			return
		var answer := {"say": "Added a review step after Fix and a note on what OK? checks.", "add": [
			{"type": "shape", "shape": "rect", "id": "n1", "x": 118, "y": 60, "w": 22, "h": 10, "label": "Review"},
			{"type": "text", "text": "OK? = all rows valid", "x": 70, "y": 28}], "change": [], "remove": []}
		done.call({"ok": true, "text": JSON.stringify(answer), "error": "", "left_out": PackedStringArray()})


var main: Node
var rig: DesktopRig
var board: Board


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := String(a).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	add_child(main)
	get_window().size = Vector2i(1500, 900)
	await _frames(5)
	rig = main.rig as DesktopRig
	board = main.board
	await _frames(100)
	var fid := ""
	for f in board.doc.frames.values():
		if (f as FrameData).kind == FrameData.CANVAS:
			fid = (f as FrameData).id
			break
	var show := str(args.get("show", "ink"))
	match show:
		"ink", "readings":
			App.put("tool", "draw")
			board.ink._provider = FakeInk.new()
			var k := 0.0
			for s in _word(Vector2(0.12, -0.3), 0.035):
				var pts := PackedFloat32Array()
				for p in s:
					pts.append_array(PackedFloat32Array([p.x, p.y, 0.0, 0.8]))
				var it := Item.make_stroke(fid, pts, Color("#ffd166"), 0.003, "pen")
				board.history.do(History.op_add([it]))
				board.ink.observe(board.doc.items[it.id], PackedFloat32Array([k, k + 0.3]))
				k += 0.4
			await _frames(90)
			if show == "readings":
				board.ink.accept_suggestion()
				await _frames(60)
		"desk", "deskcanvas":
			await _desk(show == "deskcanvas")
		"curved", "curvedside":
			await _curved(show == "curvedside", float(args.get("pan", 0.0)), str(args.get("hot", "")))
		"ai":
			board.ai.client = FakeClient.new()
			board.ai.set_key("anthropic", "sk-showcase-0000")
			rig.ui.open_side("assistant")
			await _frames(10)
			App.put("ai_note", false)
			board.ai.ask("ask", "What would make this flow clearer?", fid)
			await _frames(20)
			board.ai.ask("continue", "", fid)
			await _frames(90)
	var img := get_viewport().get_texture().get_image()
	var out := str(args.get("out", "user://showcase.png"))
	img.save_png(out)
	print("saved ", out)
	get_tree().quit()


## The PC build's way of finding the desk: the mouse ray meets the simulated table, a held left button is the nib pressed on it.
func _desk(finish: bool, curved: bool = false) -> void:
	rig.camera.position = Vector3(1.4, 1.3, -0.4)
	rig._yaw = -0.4636
	rig._pitch = -0.62
	rig._apply_look()
	rig.ui.close_side("home")
	rig.ui.close_side("assistant")
	rig.ui.close_popover()
	board.surface.begin("", Vector2(0.9, 0.6), curved)
	await _frames(10)
	var c := rig.view_container.size * 0.5
	for off in [Vector2(-250, -30), Vector2(160, -70), Vector2(-60, 10), Vector2(80, -130), Vector2(-330, -110)]:
		_mouse(c + off)
		await _frames(2)
		_button(c + off, true)
		await _frames(14)
		_button(c + off, false)
		await _frames(3)
	var st := board.surface.status()
	print("points: ", board.surface.calib.get("points"))
	print("points felt: ", st.points, "  ok: ", st.ok, "  rms mm: ", st.rms_mm, "  tilt deg: ", st.tilt_deg)
	await _frames(20)
	if finish:
		board.surface.finish()
		await _frames(30)
		if curved:
			return
		var f: FrameNode = board.frame_nodes[board.active_frame]
		_mouse(c + Vector2(-120, 0))
		await _frames(2)
		_button(c + Vector2(-120, 0), true)
		for i in 40:
			_mouse(c + Vector2(-120 + i * 6, sin(i * 0.35) * 30))
			await _frames(1)
		_button(c + Vector2(240, 0), false)
		await _frames(60)
		print("desk canvas: ", f.data.name, " surface=", f.data.surface, " items=", board.doc.items_of(f.data.id).size())


## A curved desk with drawings that run over its flat part, its bend and its wall. `side`: seen from the side. `pan`: the contents slid this far.
func _curved(side: bool, pan: float, hot: String) -> void:
	await _desk(true, true)
	var f: FrameNode = board.frame_nodes[board.active_frame]
	var fid := f.data.id
	var upd := f.data.copy()
	upd.bend_pan = Vector2(0.0, pan)
	board.history.do(History.op_frame(f.data, upd))
	await _frames(5)
	var items: Array = []
	items.append(board.texts.make("Roadmap", fid))
	(items[0] as Item).center = Vector2(-0.25, 0.22)
	for spec in [["Across the bend", "rect", Vector2(0.0, 0.62), Vector2(0.5, 0.22)], ["On the wall", "rect", Vector2(-0.2, 1.0), Vector2(0.4, 0.2)], ["Done", "ellipse", Vector2(0.25, 1.05), Vector2(0.3, 0.2)]]:
		var sh := board.make_shape(fid, {"shape": spec[1], "center": spec[2], "size": spec[3]})
		sh.label = spec[0]
		items.append(sh)
	items.append(board.make_shape(fid, {"shape": "arrow", "a": Vector2(0.3, 0.1), "b": Vector2(0.3, 1.3)}))
	var pts := PackedFloat32Array()
	for i in 41:
		pts.append_array(PackedFloat32Array([-0.38 + sin(float(i) * 0.5) * 0.04, 0.05 + float(i) * 0.03, 0.0, 0.8]))
	items.append(Item.make_stroke(fid, pts, Color("#ffd166"), 0.004, "pen"))
	var t2 := board.texts.make("Draw here, push it away", fid)
	t2.center = Vector2(-0.1, 0.4)
	items.append(t2)
	for it in items:
		if it != null:
			board.history.do(History.op_add([it]))
	await _frames(20)
	if hot != "":
		f.set_marker_hot(hot)
	print("DBG pan data ", f.data.bend_pan, " live ", f.bend.pan, " views ", f.views.size(), " frames ", board.frame_nodes.size())
	for fn2 in board.frame_nodes.values():
		print("DBG frame ", (fn2 as FrameNode).data.id, " ", (fn2 as FrameNode).data.name, " bent=", (fn2 as FrameNode).bend != null, " visible=", (fn2 as FrameNode).visible)
	if side:
		var o := f.global_transform
		var target := o * Vector3(-0.45, 0.45, 0.1)
		rig.camera.position = o * Vector3(0.1, -0.35, 0.75)
		var dir := (target - rig.camera.position).normalized()
		rig._yaw = atan2(-dir.x, -dir.z)
		rig._pitch = asin(dir.y)
	else:
		var o2 := f.global_transform
		rig.camera.position = o2 * Vector3(0.0, -0.35, 0.65)
		var tgt := o2 * Vector3(0.0, 0.65, 0.2)
		var d2 := (tgt - rig.camera.position).normalized()
		rig._yaw = atan2(-d2.x, -d2.z)
		rig._pitch = asin(d2.y)
	rig._apply_look()
	await _frames(30)


func _mouse(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	Input.parse_input_event(e)


func _button(p: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = p
	e.global_position = p
	Input.parse_input_event(e)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## "hello" in a simple print hand, x-height h, y up, starting at `at` (canvas metres).
func _word(at: Vector2, h: float) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var arc := func(c: Vector2, r: Vector2, a0: float, a1: float) -> Array:
		var o: Array = []
		for i in 21:
			var a := lerpf(a0, a1, float(i) / 20.0)
			o.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
		return o
	var letters := [
		[[Vector2(0, 2), Vector2(0, 0), Vector2(0, 0.7)] + arc.call(Vector2(0.35, 0.65), Vector2(0.35, 0.35), PI, 0.0) + [Vector2(0.7, 0)], 0.95],
		[[Vector2(0, 0.5), Vector2(0.8, 0.5)] + arc.call(Vector2(0.4, 0.5), Vector2(0.4, 0.5), 0.0, PI * 1.75), 1.05],
		[[Vector2(0.1, 2), Vector2(0.1, 0)], 0.45],
		[[Vector2(0.1, 2), Vector2(0.1, 0)], 0.45],
		[arc.call(Vector2(0.45, 0.5), Vector2(0.45, 0.5), PI * 0.5, PI * 2.5), 1.1]]
	var out: Array = []
	var x := 0.0
	for l in letters:
		var pts: Array = l[0]
		var s := PackedVector2Array()
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var n := maxi(int(a.distance_to(b) / 0.06), 1)
			for q in n:
				s.append(at + Vector2(x, 0) + a.lerp(b, float(q) / n) * h + Vector2(rng.randfn(0, h * 0.01), rng.randfn(0, h * 0.01)))
		s.append(at + Vector2(x, 0) + (pts[pts.size() - 1] as Vector2) * h)
		out.append(s)
		x += float(l[1]) * h
	return out
