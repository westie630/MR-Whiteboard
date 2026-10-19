extends SceneTree
## Shape recogniser on noisy synthetic strokes.

func _init() -> void:
	var t := TestCase.new("recognizer")
	Synth.rng.seed = 7
	var trials := 12
	var counts := {}

	for k in trials:
		var rot := Synth.rng.randf_range(-0.1, 0.1)
		_tally(counts, "rect", ShapeRecognizer.recognize(Synth.rect(0.30, 0.18, Vector2(0.5, 0.2), rot)).get("shape", "none"))
		_tally(counts, "square", ShapeRecognizer.recognize(Synth.rect(0.2, 0.2, Vector2.ZERO, rot)).get("shape", "none"))
		_tally(counts, "ellipse", ShapeRecognizer.recognize(Synth.ellipse(0.16, 0.09, Vector2(0.1, 0.1), Synth.rng.randf_range(-0.2, 0.2))).get("shape", "none"))
		_tally(counts, "circle", ShapeRecognizer.recognize(Synth.ellipse(0.1, 0.1)).get("shape", "none"))
		var tri := PackedVector2Array([Vector2(0, 0.12), Vector2(0.11, -0.08), Vector2(-0.11, -0.08)])
		_tally(counts, "triangle", ShapeRecognizer.recognize(Synth.polygon(tri, Vector2.ZERO, Synth.rng.randf_range(-0.2, 0.2))).get("shape", "none"))
		var dia := PackedVector2Array([Vector2(0, 0.1), Vector2(0.14, 0), Vector2(0, -0.1), Vector2(-0.14, 0)])
		_tally(counts, "diamond", ShapeRecognizer.recognize(Synth.polygon(dia)).get("shape", "none"))
		_tally(counts, "hex", ShapeRecognizer.recognize(Synth.polygon(Synth.regular(6, 0.1, 0.0))).get("shape", "none"))
		_tally(counts, "pent", ShapeRecognizer.recognize(Synth.polygon(Synth.regular(5, 0.1, PI * 0.5))).get("shape", "none"))
		_tally(counts, "line", ShapeRecognizer.recognize(Synth.line(Vector2(0, 0), Vector2(0.4, 0.07))).get("shape", "none"))

	print(counts)
	var expect := {"rect": "rect", "square": "rect", "ellipse": "ellipse", "circle": "ellipse", "triangle": "triangle", "diamond": "diamond", "hex": "hex", "pent": "pent", "line": "line"}
	for key in expect.keys():
		var good: int = counts.get(key, {}).get(expect[key], 0)
		t.check(good >= trials - 2, "%s recognised as %s in %d of %d trials" % [key, expect[key], good, trials])

	var r := ShapeRecognizer.recognize(Synth.rect(0.3, 0.2, Vector2(1, 1), 0.03))
	t.eq(r.get("shape"), "rect", "rect shape")
	if r.has("size"):
		t.near((r.size as Vector2).x, 0.3, 0.02, "rect width")
		t.near((r.size as Vector2).y, 0.2, 0.02, "rect height")
		t.near(r.rot, 0.0, 0.001, "small rotation snaps to zero")
	var sq := ShapeRecognizer.recognize(Synth.rect(0.2, 0.205))
	if sq.has("size"):
		t.near((sq.size as Vector2).x, (sq.size as Vector2).y, 1e-6, "square sides equalised")
	var ci := ShapeRecognizer.recognize(Synth.ellipse(0.1, 0.104))
	if ci.has("size"):
		t.near((ci.size as Vector2).x, (ci.size as Vector2).y, 1e-6, "circle axes equalised")
	var hl := ShapeRecognizer.recognize(Synth.line(Vector2(0, 0), Vector2(0.4, 0.012)))
	t.eq(hl.get("shape"), "line", "near-horizontal line recognised")
	if hl.has("a"):
		t.near((hl.b as Vector2).y, (hl.a as Vector2).y, 1e-6, "near-horizontal line snapped")
	var dl := ShapeRecognizer.recognize(Synth.line(Vector2(0, 0), Vector2(0.3, 0.17)))
	if dl.has("a"):
		t.check(absf((dl.b - dl.a).angle() - deg_to_rad(30.0)) < deg_to_rad(4.0), "30 degree line keeps its angle")
	var rd := ShapeRecognizer.recognize(Synth.rect(0.2, 0.2, Vector2.ZERO, PI * 0.25))
	t.eq(rd.get("shape"), "diamond", "square turned 45 degrees is a diamond")

	# things that must stay freehand
	var s_curve := PackedVector2Array()
	for i in 60:
		var x := float(i) / 59.0 * 0.3
		s_curve.append(Vector2(x, sin(x / 0.3 * TAU) * 0.05))
	t.check(ShapeRecognizer.recognize(s_curve).is_empty(), "an S curve is not a line")
	var u := PackedVector2Array()
	for i in 40:
		var a := PI + PI * float(i) / 39.0
		u.append(Vector2(cos(a), sin(a)) * 0.08)
	t.check(ShapeRecognizer.recognize(u).get("shape", "") != "line", "a U is not a line")
	t.check(ShapeRecognizer.recognize(PackedVector2Array([Vector2(0, 0), Vector2(0.004, 0.002), Vector2(0.006, 0.0)])).is_empty(), "a dot is nothing")
	var zig := PackedVector2Array()
	for i in 40:
		zig.append(Vector2(float(i) * 0.008, 0.04 if i % 2 == 0 else -0.04))
	t.check(ShapeRecognizer.recognize(zig).is_empty(), "a zigzag scribble stays freehand")

	# arrow: shaft then head wings
	var tip := Vector2(0.3, 0.0)
	var arrow := Synth.along(PackedVector2Array([Vector2(0, 0), tip, tip + Vector2(-0.05, 0.035), tip, tip + Vector2(-0.05, -0.035)]), false)
	var ar := ShapeRecognizer.recognize(arrow)
	t.eq(ar.get("shape"), "arrow", "arrow with head recognised")
	if ar.has("b"):
		t.near((ar.b as Vector2).x, 0.3, 0.02, "arrow tip position")

	quit(t.done())


func _tally(counts: Dictionary, key: String, got: String) -> void:
	if not counts.has(key):
		counts[key] = {}
	counts[key][got] = counts[key].get(got, 0) + 1
