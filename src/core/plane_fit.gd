class_name PlaneFit
extends RefCounted
## The flat surface a set of points lies on (least squares, so every point counts): where the stylus nib found pressure on a desk.
## fit() answers {ok, reason, point (the centroid), normal, rms (m, how far the points stray from the plane), u / v (the in-plane axes,
## u along the longer spread), extent (Vector2: the span of the points along u and v), count}. `reason` says what is missing when not ok.

const MIN_POINTS := 3
const MIN_SPAN := 0.05                     # the points must span this much (m) in both directions of the surface, else the tilt is a guess
const MAX_RMS := 0.008                     # a surface the points stray from by more than this (rms, m) is not flat: a book, the edge of a desk


static func fit(pts: PackedVector3Array) -> Dictionary:
	var n := pts.size()
	var out := {"ok": false, "reason": "points", "point": Vector3.ZERO, "normal": Vector3.UP, "rms": 0.0, "u": Vector3.RIGHT,
		"v": Vector3.FORWARD, "extent": Vector2.ZERO, "count": n}
	if n == 0:
		return out
	var c := Vector3.ZERO
	for p in pts:
		c += p
	c /= float(n)
	out.point = c
	if n < MIN_POINTS:
		return out
	var a := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for p in pts:
		var d := p - c
		var dv := [d.x, d.y, d.z]
		for i in 3:
			for j in 3:
				a[i][j] += dv[i] * dv[j]
	for i in 3:
		for j in 3:
			a[i][j] /= float(n)
	var e := _eigen(a)                        # [values (ascending), vectors]
	var vals: Array = e[0]
	var vecs: Array = e[1]
	var normal: Vector3 = vecs[0]
	var u: Vector3 = vecs[2]
	var v: Vector3 = vecs[1]
	out.normal = normal
	out.u = u
	out.v = v
	out.rms = sqrt(maxf(float(vals[0]), 0.0))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in pts:
		var d2 := p - c
		var q := Vector2(d2.dot(u), d2.dot(v))
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	out.extent = hi - lo
	if (out.extent as Vector2).y < MIN_SPAN:
		out.reason = "spread"
		return out
	if float(out.rms) > MAX_RMS:
		out.reason = "flat"
		return out
	out.ok = true
	out.reason = ""
	return out


## Distance of a point from a plane (positive on the side the normal points to).
static func signed_distance(p: Vector3, point: Vector3, normal: Vector3) -> float:
	return normal.dot(p - point)


## Eigen decomposition of a symmetric 3x3 matrix by Jacobi rotations: [values ascending, vectors (unit, in the same order)].
static func _eigen(m: Array) -> Array:
	var a: Array = [m[0].duplicate(), m[1].duplicate(), m[2].duplicate()]
	var v: Array = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	for _sweep in 32:
		if absf(a[0][1]) + absf(a[0][2]) + absf(a[1][2]) < 1e-16:
			break
		for pq in [[0, 1], [0, 2], [1, 2]]:
			var p: int = pq[0]
			var q: int = pq[1]
			if absf(a[p][q]) < 1e-20:
				continue
			var theta: float = (a[q][q] - a[p][p]) / (2.0 * a[p][q])
			var t: float = (1.0 if theta >= 0.0 else -1.0) / (absf(theta) + sqrt(theta * theta + 1.0))
			var c: float = 1.0 / sqrt(t * t + 1.0)
			var s: float = t * c
			for k in 3:
				var akp: float = a[k][p]
				var akq: float = a[k][q]
				a[k][p] = c * akp - s * akq
				a[k][q] = s * akp + c * akq
			for k in 3:
				var apk: float = a[p][k]
				var aqk: float = a[q][k]
				a[p][k] = c * apk - s * aqk
				a[q][k] = s * apk + c * aqk
			for k in 3:
				var vkp: float = v[k][p]
				var vkq: float = v[k][q]
				v[k][p] = c * vkp - s * vkq
				v[k][q] = s * vkp + c * vkq
	var order := [0, 1, 2]
	order.sort_custom(func(x: int, y: int) -> bool: return a[x][x] < a[y][y])
	var vals: Array = []
	var vecs: Array = []
	for i in order:
		vals.append(a[i][i])
		vecs.append(Vector3(v[0][i], v[1][i], v[2][i]).normalized())
	return [vals, vecs]
