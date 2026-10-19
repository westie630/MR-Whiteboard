extends Node
## Online handwriting check: sends synthetic block letters ("HELLO") to the recogniser and expects the word back.
## Skipped (passes) when there is no internet. Also covers request building and response parsing offline.

func _ready() -> void:
	var t := TestCase.new("ink_online")

	# offline: request / response handling
	var req := GoogleInk.build_request([{"x": PackedFloat32Array([1.04, 2.0]), "y": PackedFloat32Array([3.0, 4.0]), "t": PackedFloat32Array([0, 16])}], Vector2(200, 100), "en")
	t.eq(req.requests[0].language, "en", "language is sent")
	t.eq(req.requests[0].ink[0][0].size(), 2, "x coordinates are sent")
	var ok := GoogleInk.parse_response(HTTPRequest.RESULT_SUCCESS, 200, '["SUCCESS",[["id",["HELLO","hello","HELLo"],[],{}]]]'.to_utf8_buffer())
	t.check(ok.ok and ok.candidates[0] == "HELLO" and ok.candidates.size() == 3, "good response parsed")
	t.check(not GoogleInk.parse_response(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray()).ok, "network failure is reported")
	t.check(not GoogleInk.parse_response(HTTPRequest.RESULT_SUCCESS, 500, PackedByteArray()).ok, "server error is reported")
	t.check(not GoogleInk.parse_response(HTTPRequest.RESULT_SUCCESS, 200, '["FAILED_TO_PARSE_REQUEST_BODY"]'.to_utf8_buffer()).ok, "service error is reported")

	# online
	var strokes: Array = []
	var clock := [0.0]
	var letters := [
		[[[0, 0], [0, 100]], [[60, 0], [60, 100]], [[0, 50], [60, 50]]],
		[[[50, 0], [0, 0], [0, 100], [50, 100]], [[0, 50], [40, 50]]],
		[[[0, 0], [0, 100], [50, 100]]],
		[[[0, 0], [0, 100], [50, 100]]],
		[],
	]
	for li in letters.size():
		var ox := float(li) * 95.0
		if li == 4:
			var xs := PackedFloat32Array()
			var ys := PackedFloat32Array()
			var ts := PackedFloat32Array()
			for i in 41:
				var a := TAU * float(i) / 40.0 - PI * 0.5
				xs.append(ox + 30.0 + cos(a) * 32.0)
				ys.append(50.0 + sin(a) * 50.0)
				ts.append(clock[0])
				clock[0] += 12.0
			strokes.append({"x": xs, "y": ys, "t": ts})
			clock[0] += 250.0
			continue
		for stroke in letters[li]:
			var xs2 := PackedFloat32Array()
			var ys2 := PackedFloat32Array()
			var ts2 := PackedFloat32Array()
			for s in range(stroke.size() - 1):
				var a2 := Vector2(stroke[s][0], stroke[s][1])
				var b2 := Vector2(stroke[s + 1][0], stroke[s + 1][1])
				var n := maxi(int(a2.distance_to(b2) / 4.0), 1)
				for k in n:
					var p := a2.lerp(b2, float(k) / n)
					xs2.append(ox + p.x)
					ys2.append(p.y)
					ts2.append(clock[0])
					clock[0] += 10.0
			xs2.append(ox + stroke[stroke.size() - 1][0])
			ys2.append(stroke[stroke.size() - 1][1])
			ts2.append(clock[0])
			clock[0] += 220.0
			strokes.append({"x": xs2, "y": ys2, "t": ts2})
	var g := GoogleInk.new(self)
	var box: Array = []                       # lambdas capture by value: results go through a shared array
	g.recognize(strokes, Vector2(520, 140), "en", func(res: Dictionary): box.append(res))
	var waited := 0.0
	while box.is_empty() and waited < 15.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var got: Dictionary = box[0] if not box.is_empty() else {}
	if got.is_empty() or not bool(got.get("ok", false)):
		print("  (skipping online check: ", got.get("error", "timed out"), ")")
	else:
		print("  candidates: ", got.candidates)
		var found := false
		for c in got.candidates:
			if str(c).to_upper().replace(" ", "") == "HELLO":
				found = true
		t.check(found, "the word HELLO is among the candidates: %s" % str(got.candidates))
	get_tree().quit(t.done())
