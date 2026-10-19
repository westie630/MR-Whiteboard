class_name Geom2D
extends RefCounted
## 2D geometry helpers used by the shape recogniser, the shape library and the editing tools. All lengths are metres.


static func path_length(pts: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i].distance_to(pts[i - 1])
	return l


static func bbox(pts: PackedVector2Array) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	return Rect2(lo, hi - lo)


static func centroid(pts: PackedVector2Array) -> Vector2:
	if pts.is_empty():
		return Vector2.ZERO
	var c := Vector2.ZERO
	for p in pts:
		c += p
	return c / pts.size()


## Points spaced evenly along the path (n points including both ends).
static func resample(pts: PackedVector2Array, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if pts.size() < 2 or n < 2:
		return pts.duplicate()
	var total := path_length(pts)
	if total < 1e-9:
		for i in n:
			out.append(pts[0])
		return out
	var step := total / float(n - 1)
	out.append(pts[0])
	var acc := 0.0
	var prev := pts[0]
	var i := 1
	while i < pts.size() and out.size() < n:
		var cur := pts[i]
		var d := prev.distance_to(cur)
		if d < 1e-12:
			i += 1
			continue
		if acc + d >= step:
			var t := (step - acc) / d
			var q := prev.lerp(cur, t)
			out.append(q)
			prev = q
			acc = 0.0
		else:
			acc += d
			prev = cur
			i += 1
	while out.size() < n:
		out.append(pts[pts.size() - 1])
	out[n - 1] = pts[pts.size() - 1]
	return out


static func dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))


## Distance from a point to a polyline (closed adds the last->first edge).
static func dist_to_polyline(p: Vector2, poly: PackedVector2Array, closed: bool = false) -> float:
	var best := INF
	var n := poly.size()
	if n == 0:
		return best
	if n == 1:
		return p.distance_to(poly[0])
	for i in range(n - 1):
		best = minf(best, dist_to_segment(p, poly[i], poly[i + 1]))
	if closed:
		best = minf(best, dist_to_segment(p, poly[n - 1], poly[0]))
	return best


## Douglas-Peucker on an open polyline.
static func rdp(pts: PackedVector2Array, eps: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts.duplicate()
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array = [[0, n - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var i0: int = seg[0]
		var i1: int = seg[1]
		var best := -1.0
		var bi := -1
		for i in range(i0 + 1, i1):
			var d := dist_to_segment(pts[i], pts[i0], pts[i1])
			if d > best:
				best = d
				bi = i
		if best > eps and bi >= 0:
			keep[bi] = 1
			stack.append([i0, bi])
			stack.append([bi, i1])
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(pts[i])
	return out


## Douglas-Peucker for a closed loop (the points are NOT repeated at the end). Splits at the point farthest from the first.
static func rdp_closed(pts: PackedVector2Array, eps: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 4:
		return pts.duplicate()
	var far := 0
	var fd := -1.0
	for i in n:
		var d := pts[i].distance_squared_to(pts[0])
		if d > fd:
			fd = d
			far = i
	var first := PackedVector2Array()
	for i in range(0, far + 1):
		first.append(pts[i])
	var second := PackedVector2Array()
	for i in range(far, n):
		second.append(pts[i])
	second.append(pts[0])
	var a := rdp(first, eps)
	var b := rdp(second, eps)
	var out := PackedVector2Array()
	for p in a:
		out.append(p)
	for i in range(1, b.size() - 1):
		out.append(b[i])
	return out


static func polygon_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


static func polygon_perimeter(poly: PackedVector2Array) -> float:
	var l := 0.0
	var n := poly.size()
	for i in n:
		l += poly[i].distance_to(poly[(i + 1) % n])
	return l


static func convex_hull(pts: PackedVector2Array) -> PackedVector2Array:
	return Geometry2D.convex_hull(pts)


## Principal axes of a point set. Returns {mean, axis (unit, major), var_major, var_minor}.
static func pca(pts: PackedVector2Array) -> Dictionary:
	var m := centroid(pts)
	var sxx := 0.0
	var syy := 0.0
	var sxy := 0.0
	for p in pts:
		var d := p - m
		sxx += d.x * d.x
		syy += d.y * d.y
		sxy += d.x * d.y
	var n := maxf(float(pts.size()), 1.0)
	sxx /= n
	syy /= n
	sxy /= n
	var tr := sxx + syy
	var det := sxx * syy - sxy * sxy
	var disc := sqrt(maxf(tr * tr * 0.25 - det, 0.0))
	var l1 := tr * 0.5 + disc
	var l2 := tr * 0.5 - disc
	var axis := Vector2.RIGHT
	if absf(sxy) > 1e-14:
		axis = Vector2(l1 - syy, sxy).normalized()
	elif sxx < syy:
		axis = Vector2.DOWN
	return {"mean": m, "axis": axis, "var_major": l1, "var_minor": maxf(l2, 0.0)}


## Smallest-area rectangle around a point set. Returns {center, size (w >= 0, h >= 0), rot (radians, direction of the w axis)}.
static func min_area_rect(pts: PackedVector2Array) -> Dictionary:
	var hull := convex_hull(pts)
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)
	if hull.size() < 3:
		var bb := bbox(pts)
		return {"center": bb.get_center(), "size": bb.size, "rot": 0.0}
	var best_area := INF
	var best := {}
	var n := hull.size()
	for i in n:
		var e := hull[(i + 1) % n] - hull[i]
		if e.length_squared() < 1e-14:
			continue
		var ang := e.angle()
		var cs := cos(-ang)
		var sn := sin(-ang)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in hull:
			var q := Vector2(p.x * cs - p.y * sn, p.x * sn + p.y * cs)
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
		var area := (hi.x - lo.x) * (hi.y - lo.y)
		if area < best_area:
			best_area = area
			var cl := (lo + hi) * 0.5
			var cw := Vector2(cl.x * cos(ang) - cl.y * sin(ang), cl.x * sin(ang) + cl.y * cos(ang))
			best = {"center": cw, "size": hi - lo, "rot": ang}
	return best


## Normalise an angle to (-PI/2, PI/2].
static func fold_half_pi(a: float) -> float:
	a = wrapf(a, -PI, PI)
	if a > PI * 0.5:
		a -= PI
	elif a <= -PI * 0.5:
		a += PI
	return a


## Rotate a vector by an angle.
static func rot(v: Vector2, a: float) -> Vector2:
	var c := cos(a)
	var s := sin(a)
	return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)


## Points of an ellipse outline (centered at the origin, semi-axes rx, ry).
static func ellipse_points(rx: float, ry: float, n: int = 48) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var t := TAU * float(i) / float(n)
		out.append(Vector2(cos(t) * rx, sin(t) * ry))
	return out


## Chaikin corner cutting, one pass (open polyline keeps its end points).
static func chaikin(pts: PackedVector2Array, closed: bool = false) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts.duplicate()
	var out := PackedVector2Array()
	if not closed:
		out.append(pts[0])
	var last := n if closed else n - 1
	for i in last:
		var p := pts[i]
		var q := pts[(i + 1) % n]
		out.append(p.lerp(q, 0.25))
		out.append(p.lerp(q, 0.75))
	if not closed:
		out.append(pts[n - 1])
	return out


## Interior angle (radians) at b of the path a-b-c.
static func angle_at(a: Vector2, b: Vector2, c: Vector2) -> float:
	var u := a - b
	var v := c - b
	if u.length_squared() < 1e-14 or v.length_squared() < 1e-14:
		return PI
	return absf(u.angle_to(v))


## Distance from a point to the outline of a polygon, for a point set: mean over the points.
static func mean_dist_to_polyline(pts: PackedVector2Array, poly: PackedVector2Array, closed: bool) -> float:
	if pts.is_empty():
		return INF
	var s := 0.0
	for p in pts:
		s += dist_to_polyline(p, poly, closed)
	return s / pts.size()


## Largest gap (as a fraction of the outline length) left uncovered by the point set: how much of the outline the stroke really traces.
static func coverage_gap(pts: PackedVector2Array, poly: PackedVector2Array, closed: bool) -> float:
	var dense := PackedVector2Array(poly)
	if closed and poly.size() > 0:
		dense.append(poly[0])
	dense = resample(dense, 96)
	var worst := 0.0
	for q in dense:
		var d := INF
		for p in pts:
			d = minf(d, p.distance_squared_to(q))
		worst = maxf(worst, d)
	return sqrt(worst)
