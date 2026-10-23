extends Node
## Puts the PC app into states that are hard to reach by hand, for screenshots of the interface (no network: a stand-in handwriting
## reader and a stand-in language model answer):
##   godot --path . res://tools/dev/ui_showcase.tscn -- --demo --docs-dir=DIR --settings=FILE --show=ink|readings|ai --out=PATH
##   ink       words written with the pen: the chip offers to turn them into text
##   readings  ...converted: the other readings beside the new text
##   ai        the assistant answered with a drawing: the suggestion bar on the canvas, the assistant panel open

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
