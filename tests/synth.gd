class_name Synth
extends RefCounted
## Synthetic hand-drawn strokes for the tests: shapes sampled along their outline with low-frequency wobble and jitter.

static var rng := RandomNumberGenerator.new()


static func _wobble(points: PackedVector2Array, amp: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var ph1 := rng.randf() * TAU
	var ph2 := rng.randf() * TAU
	for i in points.size():
		var t := float(i) / maxf(points.size() - 1, 1)
		var w := Vector2(sin(t * 11.0 + ph1), cos(t * 7.0 + ph2)) * amp
		out.append(points[i] + w + Vector2(rng.randfn(0.0, amp * 0.25), rng.randfn(0.0, amp * 0.25)))
	return out


## Walk along a polyline (closed adds the closing edge) taking a point every `step` metres.
static func along(poly: PackedVector2Array, closed: bool, step: float = 0.004) -> PackedVector2Array:
	var path := PackedVector2Array(poly)
	if closed:
		path.append(poly[0])
	var out := PackedVector2Array()
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var n := maxi(int(a.distance_to(b) / step), 1)
		for k in n:
			out.append(a.lerp(b, float(k) / n))
	out.append(path[path.size() - 1])
	return out


static func shifted(points: PackedVector2Array, k: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in points.size():
		out.append(points[(i + k) % points.size()])
	return out


static func xf(points: PackedVector2Array, center: Vector2, rot: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(center + Geom2D.rot(p, rot))
	return out


static func rect(w: float, h: float, center: Vector2 = Vector2.ZERO, rot: float = 0.0, amp: float = 0.002, overshoot: float = 0.02) -> PackedVector2Array:
	var poly := PackedVector2Array([Vector2(-w, h) * 0.5, Vector2(w, h) * 0.5, Vector2(w, -h) * 0.5, Vector2(-w, -h) * 0.5])
	var s := along(poly, true)
	s = shifted(s, rng.randi() % s.size())
	var closed := PackedVector2Array(s)
	closed.append(s[0])
	for i in range(1, int(overshoot / 0.004)):           # overshoot: continue along the first edge a little
		closed.append(s[i % s.size()])
	return _wobble(xf(closed, center, rot), amp)


static func ellipse(rx: float, ry: float, center: Vector2 = Vector2.ZERO, rot: float = 0.0, amp: float = 0.002) -> PackedVector2Array:
	var n := 120
	var pts := PackedVector2Array()
	var start := rng.randf() * TAU
	for i in n + 6:
		var t := start + TAU * float(i) / n
		pts.append(Vector2(cos(t) * rx, sin(t) * ry))
	return _wobble(xf(pts, center, rot), amp)


static func polygon(verts: PackedVector2Array, center: Vector2 = Vector2.ZERO, rot: float = 0.0, amp: float = 0.002) -> PackedVector2Array:
	var s := along(verts, true)
	s = shifted(s, rng.randi() % s.size())
	var closed := PackedVector2Array(s)
	closed.append(s[0])
	return _wobble(xf(closed, center, rot), amp)


static func line(a: Vector2, b: Vector2, amp: float = 0.0015) -> PackedVector2Array:
	return _wobble(along(PackedVector2Array([a, b]), false), amp)


static func regular(n: int, r: float, start: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := start + TAU * float(i) / n
		out.append(Vector2(cos(a), sin(a)) * r)
	return out
