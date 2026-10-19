extends Node
## Not a test: prints how often the recogniser gets each shape right on many random noisy strokes.
##   godot --headless --path . res://tests/runner.tscn -- stress_recognizer

func _ready() -> void:
	Synth.rng.seed = 99
	var n := 150
	var stats := {}
	var wrong := {}
	for k in n:
		var sc := Synth.rng.randf_range(0.5, 2.5)
		var amp := Synth.rng.randf_range(0.001, 0.0045) * sc
		var rot := Synth.rng.randf_range(-0.35, 0.35)
		var cases := {
			"rect": [Synth.rect(0.3 * sc, Synth.rng.randf_range(0.12, 0.25) * sc, Vector2.ZERO, rot, amp), ["rect"]],
			"square": [Synth.rect(0.2 * sc, 0.2 * sc, Vector2.ZERO, rot, amp), ["rect", "diamond"]],
			"ellipse": [Synth.ellipse(0.16 * sc, Synth.rng.randf_range(0.06, 0.12) * sc, Vector2.ZERO, rot * 3.0, amp), ["ellipse"]],
			"circle": [Synth.ellipse(0.1 * sc, 0.1 * sc, Vector2.ZERO, 0.0, amp), ["ellipse"]],
			"triangle": [Synth.polygon(_sc(PackedVector2Array([Vector2(0, 0.12), Vector2(0.11, -0.08), Vector2(-0.11, -0.08)]), sc), Vector2.ZERO, Synth.rng.randf_range(-PI, PI), amp), ["triangle", "poly"]],
			"diamond": [Synth.polygon(_sc(PackedVector2Array([Vector2(0, 0.1), Vector2(0.14, 0), Vector2(0, -0.1), Vector2(-0.14, 0)]), sc), Vector2.ZERO, rot * 0.3, amp), ["diamond"]],
			"hex": [Synth.polygon(Synth.regular(6, 0.1 * sc, Synth.rng.randf_range(0, 1.0)), Vector2.ZERO, 0.0, amp), ["hex"]],
			"pent": [Synth.polygon(Synth.regular(5, 0.1 * sc, PI * 0.5 + Synth.rng.randf_range(-0.5, 0.5)), Vector2.ZERO, 0.0, amp), ["pent"]],
			"line": [Synth.line(Vector2.ZERO, Vector2.from_angle(Synth.rng.randf_range(-PI, PI)) * 0.3 * sc, amp), ["line"]],
		}
		for key in cases.keys():
			var r := ShapeRecognizer.recognize(cases[key][0])
			var got: String = r.get("shape", "none")
			if not stats.has(key):
				stats[key] = 0
				wrong[key] = {}
			if (cases[key][1] as Array).has(got):
				stats[key] += 1
			else:
				wrong[key][got] = int(wrong[key].get(got, 0)) + 1
	for key in stats.keys():
		print("%-9s %3d/%d  wrong: %s" % [key, stats[key], n, str(wrong[key])])
	get_tree().quit()


func _sc(a: PackedVector2Array, k: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in a:
		out.append(p * k)
	return out
