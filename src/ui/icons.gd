class_name Icons
extends RefCounted
## Vector icons drawn in code onto any CanvasItem: resolution independent, so they are sharp on the PC and in the headset.
## Everything is laid out in a unit square (0..1, y down) scaled into the target rectangle.


static func draw(ci: CanvasItem, id: String, r: Rect2, col: Color) -> void:
	var s := minf(r.size.x, r.size.y)
	var o := r.get_center() - Vector2(s, s) * 0.5
	var w := maxf(s * 0.075, 1.6)
	var P := func(x: float, y: float) -> Vector2: return o + Vector2(x, y) * s
	match id:
		"draw", "pen":
			ci.draw_polyline(PackedVector2Array([P.call(0.22, 0.8), P.call(0.74, 0.28)]), col, w * 2.2, true)
			ci.draw_colored_polygon(PackedVector2Array([P.call(0.12, 0.9), P.call(0.18, 0.7), P.call(0.3, 0.82)]), col)
			ci.draw_polyline(PackedVector2Array([P.call(0.72, 0.2), P.call(0.8, 0.28)]), col, w * 2.4, true)
		"marker":
			ci.draw_polyline(PackedVector2Array([P.call(0.16, 0.8), P.call(0.82, 0.2)]), col, w * 4.0, true)
		"highlighter":
			ci.draw_polyline(PackedVector2Array([P.call(0.14, 0.78), P.call(0.84, 0.22)]), Color(col.r, col.g, col.b, 0.5), w * 6.5, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.14, 0.78), P.call(0.84, 0.22)]), col, w * 0.9, true)
		"pencil":
			for k in 3:
				var j := float(k) * 0.035
				ci.draw_polyline(PackedVector2Array([P.call(0.16 + j, 0.82), P.call(0.26 + j, 0.62), P.call(0.5 + j, 0.52), P.call(0.8, 0.2 + j * 0.5)]), Color(col.r, col.g, col.b, 0.75), w * 0.55, true)
		"calligraphy":
			var prev: Vector2 = P.call(0.14, 0.72)
			for k in range(1, 25):
				var t := float(k) / 24.0
				var cur: Vector2 = P.call(0.14 + t * 0.72, 0.72 - sin(t * PI) * 0.42)
				ci.draw_line(prev, cur, col, w * (0.6 + 3.4 * maxf(0.0, cos(t * PI))), true)
				prev = cur
		"neon":
			var wave := PackedVector2Array()
			for k in range(0, 21):
				var t3 := float(k) / 20.0
				wave.append(P.call(0.12 + t3 * 0.76, 0.5 + sin(t3 * TAU) * 0.22))
			ci.draw_polyline(wave, Color(col.r, col.g, col.b, 0.18), w * 4.5, true)
			ci.draw_polyline(wave, Color(col.r, col.g, col.b, 0.4), w * 2.8, true)
			ci.draw_polyline(wave, Color.WHITE, w * 1.0, true)
		"spray":
			var rng := RandomNumberGenerator.new()
			rng.seed = 5
			for k in 38:
				var a := rng.randf()
				var ang := rng.randf() * TAU
				var d := pow(rng.randf(), 0.7) * 0.2
				ci.draw_circle(P.call(0.2 + a * 0.6 + cos(ang) * d * 0.5, 0.8 - a * 0.6 + sin(ang) * d), s * 0.026, Color(col.r, col.g, col.b, 0.85))
		"dashed":
			for k in 4:
				var t4 := float(k) / 4.0
				ci.draw_polyline(PackedVector2Array([P.call(0.12 + t4 * 0.78, 0.82 - t4 * 0.6), P.call(0.12 + t4 * 0.78 + 0.1, 0.82 - t4 * 0.6 - 0.08)]), col, w * 1.6, true)
		"shapes":
			ci.draw_rect(Rect2(P.call(0.14, 0.34), Vector2(0.42, 0.42) * s), col, false, w)
			ci.draw_arc(P.call(0.6, 0.4), s * 0.22, 0.0, TAU, 32, col, w, true)
		"write":
			ci.draw_polyline(PackedVector2Array([P.call(0.14, 0.8), P.call(0.34, 0.2), P.call(0.54, 0.8)]), col, w, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.21, 0.58), P.call(0.47, 0.58)]), col, w, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.7, 0.3), P.call(0.7, 0.8)]), col, w, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.62, 0.3), P.call(0.78, 0.3)]), col, w * 0.8, true)
		"select":
			var pts2 := PackedVector2Array()
			for k in range(0, 17):
				var a2 := TAU * float(k) / 16.0
				pts2.append(P.call(0.46 + cos(a2) * 0.34, 0.44 + sin(a2) * 0.26))
			for k in 8:
				ci.draw_line(pts2[k * 2], pts2[k * 2 + 1], col, w, true)
			ci.draw_colored_polygon(PackedVector2Array([P.call(0.56, 0.5), P.call(0.9, 0.62), P.call(0.74, 0.7), P.call(0.8, 0.9)]), col)
		"erase":
			var pts3 := PackedVector2Array([P.call(0.18, 0.62), P.call(0.5, 0.2), P.call(0.86, 0.46), P.call(0.54, 0.88)])
			ci.draw_polyline(pts3 + PackedVector2Array([pts3[0]]), col, w, true)
			ci.draw_line(P.call(0.34, 0.41), P.call(0.7, 0.67), col, w, true)
			ci.draw_line(P.call(0.45, 0.9), P.call(0.9, 0.9), col, w * 0.8, true)
		"undo", "redo":
			var flip := id == "redo"
			var pts4 := PackedVector2Array()
			for k in range(0, 13):
				var a3 := PI * (1.05 + 0.95 * float(k) / 12.0)
				var px := 0.52 + cos(a3) * 0.3
				pts4.append(P.call(1.0 - px if flip else px, 0.56 + sin(a3) * 0.3))
			ci.draw_polyline(pts4, col, w * 1.2, true)
			var tip: Vector2 = P.call(0.82 if flip else 0.18, 0.56)
			var dir := -1.0 if flip else 1.0
			ci.draw_colored_polygon(PackedVector2Array([tip + Vector2(0, -s * 0.2), tip + Vector2(dir * s * 0.2, s * 0.02), tip + Vector2(-dir * s * 0.08, s * 0.1)]), col)
		"plus":
			ci.draw_line(P.call(0.5, 0.2), P.call(0.5, 0.8), col, w * 1.3, true)
			ci.draw_line(P.call(0.2, 0.5), P.call(0.8, 0.5), col, w * 1.3, true)
		"trash":
			ci.draw_polyline(PackedVector2Array([P.call(0.26, 0.3), P.call(0.32, 0.86), P.call(0.68, 0.86), P.call(0.74, 0.3)]), col, w, true)
			ci.draw_line(P.call(0.18, 0.3), P.call(0.82, 0.3), col, w, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.4, 0.3), P.call(0.42, 0.16), P.call(0.58, 0.16), P.call(0.6, 0.3)]), col, w, true)
		"copy":
			ci.draw_rect(Rect2(P.call(0.3, 0.3), Vector2(0.48, 0.52) * s), col, false, w)
			ci.draw_polyline(PackedVector2Array([P.call(0.22, 0.62), P.call(0.22, 0.18), P.call(0.58, 0.18)]), col, w, true)
		"front", "back":
			var top_y := 0.16 if id == "front" else 0.4
			var back_y := 0.4 if id == "front" else 0.16
			ci.draw_rect(Rect2(P.call(0.2, back_y + 0.06), Vector2(0.44, 0.34) * s), Color(col.r, col.g, col.b, 0.5), false, w)
			ci.draw_rect(Rect2(P.call(0.36, top_y + 0.2), Vector2(0.44, 0.34) * s), col, false, w)
		"check":
			ci.draw_polyline(PackedVector2Array([P.call(0.2, 0.52), P.call(0.42, 0.72), P.call(0.8, 0.28)]), col, w * 1.5, true)
		"close":
			ci.draw_line(P.call(0.24, 0.24), P.call(0.76, 0.76), col, w * 1.3, true)
			ci.draw_line(P.call(0.76, 0.24), P.call(0.24, 0.76), col, w * 1.3, true)
		"doc":
			ci.draw_polyline(PackedVector2Array([P.call(0.26, 0.14), P.call(0.58, 0.14), P.call(0.76, 0.32), P.call(0.76, 0.86), P.call(0.26, 0.86), P.call(0.26, 0.14)]), col, w, true)
			for k in 3:
				ci.draw_line(P.call(0.36, 0.5 + float(k) * 0.12), P.call(0.66, 0.5 + float(k) * 0.12), col, w * 0.7, true)
		"folder":
			ci.draw_polyline(PackedVector2Array([P.call(0.14, 0.78), P.call(0.14, 0.24), P.call(0.4, 0.24), P.call(0.48, 0.34), P.call(0.86, 0.34), P.call(0.86, 0.78), P.call(0.14, 0.78)]), col, w, true)
		"export":
			ci.draw_polyline(PackedVector2Array([P.call(0.3, 0.46), P.call(0.18, 0.46), P.call(0.18, 0.86), P.call(0.82, 0.86), P.call(0.82, 0.46), P.call(0.7, 0.46)]), col, w, true)
			ci.draw_line(P.call(0.5, 0.64), P.call(0.5, 0.12), col, w, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.34, 0.28), P.call(0.5, 0.12), P.call(0.66, 0.28)]), col, w, true)
		"room":
			ci.draw_polyline(PackedVector2Array([P.call(0.14, 0.5), P.call(0.5, 0.16), P.call(0.86, 0.5)]), col, w * 1.1, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.24, 0.44), P.call(0.24, 0.84), P.call(0.76, 0.84), P.call(0.76, 0.44)]), col, w, true)
			ci.draw_rect(Rect2(P.call(0.43, 0.6), Vector2(0.14, 0.24) * s), col, false, w * 0.8)
		"canvas":
			ci.draw_rect(Rect2(P.call(0.14, 0.2), Vector2(0.72, 0.6) * s), col, false, w)
			for k in range(1, 3):
				ci.draw_line(P.call(0.14 + 0.24 * k, 0.2), P.call(0.14 + 0.24 * k, 0.8), Color(col.r, col.g, col.b, 0.45), w * 0.55, true)
				ci.draw_line(P.call(0.14, 0.2 + 0.2 * k), P.call(0.86, 0.2 + 0.2 * k), Color(col.r, col.g, col.b, 0.45), w * 0.55, true)
		"volume":
			var f := PackedVector2Array([P.call(0.18, 0.4), P.call(0.58, 0.4), P.call(0.58, 0.82), P.call(0.18, 0.82), P.call(0.18, 0.4)])
			ci.draw_polyline(f, col, w, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.18, 0.4), P.call(0.4, 0.18), P.call(0.8, 0.18), P.call(0.8, 0.6), P.call(0.58, 0.82)]), col, w, true)
			ci.draw_line(P.call(0.58, 0.4), P.call(0.8, 0.18), col, w, true)
		"lock":
			ci.draw_rect(Rect2(P.call(0.24, 0.48), Vector2(0.52, 0.38) * s), col, false, w)
			ci.draw_arc(P.call(0.5, 0.48), s * 0.17, PI, TAU, 16, col, w, true)
		"grid":
			ci.draw_rect(Rect2(P.call(0.18, 0.18), Vector2(0.64, 0.64) * s), col, false, w)
			ci.draw_line(P.call(0.5, 0.18), P.call(0.5, 0.82), col, w * 0.7, true)
			ci.draw_line(P.call(0.18, 0.5), P.call(0.82, 0.5), col, w * 0.7, true)
		"settings":
			for k in 3:
				var y := 0.26 + float(k) * 0.24
				ci.draw_line(P.call(0.14, y), P.call(0.86, y), col, w * 0.8, true)
				ci.draw_circle(P.call(0.3 + float(k % 2) * 0.35 + float(k) * 0.05, y), s * 0.075, col)
		"text":
			ci.draw_line(P.call(0.22, 0.24), P.call(0.78, 0.24), col, w * 1.1, true)
			ci.draw_line(P.call(0.5, 0.24), P.call(0.5, 0.82), col, w * 1.1, true)
		"convert":
			ci.draw_polyline(PackedVector2Array([P.call(0.1, 0.7), P.call(0.18, 0.3), P.call(0.28, 0.6), P.call(0.36, 0.3)]), col, w * 0.9, true)
			ci.draw_line(P.call(0.46, 0.5), P.call(0.62, 0.5), col, w, true)
			ci.draw_polyline(PackedVector2Array([P.call(0.56, 0.42), P.call(0.64, 0.5), P.call(0.56, 0.58)]), col, w, true)
			ci.draw_line(P.call(0.72, 0.28), P.call(0.92, 0.28), col, w, true)
			ci.draw_line(P.call(0.82, 0.28), P.call(0.82, 0.74), col, w, true)
		"mic":
			ci.draw_line(P.call(0.5, 0.24), P.call(0.5, 0.44), col, s * 0.26, true)
			ci.draw_circle(P.call(0.5, 0.24), s * 0.13, col)
			ci.draw_circle(P.call(0.5, 0.44), s * 0.13, col)
			ci.draw_arc(P.call(0.5, 0.44), s * 0.25, 0.0, PI, 20, col, w, true)
			ci.draw_line(P.call(0.5, 0.69), P.call(0.5, 0.86), col, w, true)
			ci.draw_line(P.call(0.36, 0.86), P.call(0.64, 0.86), col, w, true)
		"anchor":
			ci.draw_circle(P.call(0.5, 0.26), s * 0.09, col)
			ci.draw_line(P.call(0.5, 0.35), P.call(0.5, 0.82), col, w, true)
			ci.draw_arc(P.call(0.5, 0.6), s * 0.3, 0.1 * PI, 0.9 * PI, 16, col, w, true)
			ci.draw_line(P.call(0.36, 0.46), P.call(0.64, 0.46), col, w, true)
		"pin":
			ci.draw_circle(P.call(0.5, 0.36), s * 0.2, col)
			ci.draw_colored_polygon(PackedVector2Array([P.call(0.4, 0.5), P.call(0.6, 0.5), P.call(0.5, 0.88)]), col)
		_:
			if Shapes.STENCILS.any(func(st): return st.id == id):
				_stencil(ci, id, o, s, col, w)
			else:
				ci.draw_rect(r.grow(-s * 0.2), col, false, w)


## A stencil shape's own outline as its icon.
static func _stencil(ci: CanvasItem, id: String, o: Vector2, s: float, col: Color, w: float) -> void:
	var c := o + Vector2(s, s) * 0.5
	if Shapes.is_line(id):
		var a := c + Vector2(-0.34, 0.24) * s
		var b := c + Vector2(0.34, -0.24) * s
		var pts := PackedVector2Array([a, b])
		if id == "elbow":
			pts = PackedVector2Array([c + Vector2(-0.36, 0.24) * s, c + Vector2(0.0, 0.24) * s, c + Vector2(0.0, -0.24) * s, c + Vector2(0.34, -0.24) * s])
			b = pts[3]
			a = pts[2]
		ci.draw_polyline(pts, col, w, true)
		var d := (b - a).normalized()
		var perp := Vector2(-d.y, d.x)
		if id != "line":
			ci.draw_colored_polygon(PackedVector2Array([b, b - d * s * 0.2 + perp * s * 0.09, b - d * s * 0.2 - perp * s * 0.09]), col)
		if id == "darrow":
			ci.draw_colored_polygon(PackedVector2Array([a, a + d * s * 0.2 + perp * s * 0.09, a + d * s * 0.2 - perp * s * 0.09]), col)
		return
	var size := Shapes.default_size(id)
	var k := 0.7 * s / maxf(size.x, size.y)
	for out in Shapes.outlines(id, size):
		var pts2 := PackedVector2Array()
		for p in out.pts:
			pts2.append(c + Vector2(p.x, -p.y) * k)
		if out.closed:
			pts2.append(pts2[0])
		ci.draw_polyline(pts2, col, w, true)
