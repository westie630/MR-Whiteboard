class_name ShapeRecognizer
extends RefCounted
## Turns a hand-drawn stroke into an ideal vector shape, or says it is not one.
##
## Open strokes: a straight line (with snap to horizontal / vertical / 45 degrees) or an arrow (a line whose end was drawn
## back on itself as a head). Closed strokes: every candidate shape (ellipse, rectangle, diamond, triangle, pentagon,
## hexagon, parallelogram, general polygon) is fitted to the stroke and the one whose outline lies closest to the ink wins
## if it is close enough. Distances are measured as a fraction of the stroke's bounding-box diagonal, so it works the same
## for a 5 cm doodle and a 1 m diagram box.
##
## The result is a Dictionary: {shape, ...} with center / size / rot for stencil shapes, a / b (+ head_b) for lines and
## poly for irregular polygons; {} when the stroke stays freehand.

const MIN_LENGTH := 0.03                  # shorter strokes are dots / ticks
const MIN_DIAGONAL := 0.03
const MAX_ERR := 0.06                     # candidate accepted when its mean distance to the ink is below this fraction of the diagonal
const MAX_LOOP_RATIO := 6.0               # stroke length / box diagonal above which a stroke is a scribble, not an outline
const CLOSE_RATIO := 0.2                  # start-to-end gap (fraction of the stroke length) below which a stroke counts as closed
const SQUARE_TOL := 0.13                  # |w - h| / max(w, h) below this snaps to a square / circle
const AXIS_SNAP := deg_to_rad(7.0)
const LINE_SNAP := deg_to_rad(6.0)

# preference when two candidates fit about equally well (lower = preferred)
const PRIOR := {"rect": 1.0, "diamond": 1.0, "triangle": 1.0, "para": 1.0, "ellipse": 1.05, "pent": 1.1, "hex": 1.1, "poly": 2.6}


static func recognize(points: PackedVector2Array, snap_axes: bool = true) -> Dictionary:
	var pts := _dedupe(points)
	if pts.size() < 3:
		return {}
	var length := Geom2D.path_length(pts)
	var bb := Geom2D.bbox(pts)
	var diag := bb.size.length()
	if length < MIN_LENGTH or diag < MIN_DIAGONAL:
		return {}
	var rs := Geom2D.resample(pts, 96)
	var gap := rs[0].distance_to(rs[rs.size() - 1])
	# a closed shape's outline is a few times the box diagonal; a long scribble that happens to end near its start is not one
	if gap > CLOSE_RATIO * length or length > MAX_LOOP_RATIO * diag:
		var line := _try_line(rs, length, diag, snap_axes)
		if not line.is_empty():
			return line
		return _try_arrow(rs, length, diag, snap_axes)
	return _try_closed(rs, diag, snap_axes)


# ------------------------------------------------------------------------------------------------ open strokes

static func _try_line(rs: PackedVector2Array, length: float, diag: float, snap_axes: bool) -> Dictionary:
	var fit := Geom2D.pca(rs)
	var m: Vector2 = fit.mean
	var u: Vector2 = fit.axis
	var chord := rs[0].distance_to(rs[rs.size() - 1])
	if chord / length < 0.88:
		return {}
	var sum_sq := 0.0
	var worst := 0.0
	for p in rs:
		var d := absf((p - m).cross(u))
		sum_sq += d * d
		worst = maxf(worst, d)
	var rms := sqrt(sum_sq / rs.size())
	if rms > 0.03 * length or worst > 0.075 * length:
		return {}
	var a := m + u * (rs[0] - m).dot(u)
	var b := m + u * (rs[rs.size() - 1] - m).dot(u)
	if snap_axes:
		var snapped := _snap_line(a, b)
		a = snapped[0]
		b = snapped[1]
	return {"shape": "line", "a": a, "b": b, "err": rms / maxf(diag, 1e-6)}


## Rotate the line about its midpoint onto the horizontal, vertical or a 45 degree angle when it is within a few degrees of one.
static func _snap_line(a: Vector2, b: Vector2) -> Array:
	var d := b - a
	var len := d.length()
	if len < 1e-6:
		return [a, b]
	var ang := d.angle()
	var step := PI * 0.25
	var near := roundf(ang / step) * step
	var tol := LINE_SNAP if int(roundf(ang / step)) % 2 == 0 else LINE_SNAP * 0.6
	if absf(angle_difference(ang, near)) <= tol:
		var mid := (a + b) * 0.5
		var h := Vector2.from_angle(near) * len * 0.5
		return [mid - h, mid + h]
	return [a, b]


## Arrow drawn in one stroke: shaft, then the head's two wings back from the tip.
static func _try_arrow(rs: PackedVector2Array, length: float, diag: float, snap_axes: bool) -> Dictionary:
	var v := Geom2D.rdp(rs, 0.05 * diag)
	if v.size() < 4 or v.size() > 5:
		return {}
	var tail := v[0]
	var tip := v[1]
	var shaft := tip - tail
	var sl := shaft.length()
	if sl < 0.55 * length or sl < 0.06:
		return {}
	var dir := shaft / sl
	var back := -dir
	var w1 := v[2]
	# the head wings must point back along the shaft, one to each side
	if not _is_wing(tip, w1, back, sl):
		return {}
	if v.size() == 5:
		var w2 := v[4]
		if v[3].distance_to(tip) > 0.3 * sl:
			return {}
		if not _is_wing(tip, w2, back, sl):
			return {}
		if (w1 - tip).cross(back) * (w2 - tip).cross(back) >= 0.0:
			return {}                                              # both wings on the same side: not a head
	var a := tail
	var b := tip
	if snap_axes:
		var snapped := _snap_line(a, b)
		a = snapped[0]
		b = snapped[1]
	return {"shape": "arrow", "a": a, "b": b, "head_b": true, "err": 0.0}


static func _is_wing(tip: Vector2, w: Vector2, back: Vector2, shaft_len: float) -> bool:
	var d := w - tip
	var l := d.length()
	if l < 0.08 * shaft_len or l > 0.5 * shaft_len:
		return false
	var ang := absf(d.angle_to(back))
	return ang > deg_to_rad(10.0) and ang < deg_to_rad(70.0)


# ------------------------------------------------------------------------------------------------ closed strokes

static func _try_closed(rs: PackedVector2Array, diag: float, snap_axes: bool) -> Dictionary:
	# the loop without the repeated closing point
	var ring := PackedVector2Array()
	for i in rs.size() - 1:
		ring.append(rs[i])
	var cands: Array = []
	_add(cands, _fit_ellipse(ring, diag, snap_axes))
	_add(cands, _fit_rect(ring, diag, snap_axes))
	_add(cands, _fit_diamond(ring, diag))
	var tri := _fit_triangle(ring, diag)
	_add(cands, tri)
	_add(cands, _fit_regular(ring, diag, 5))
	_add(cands, _fit_regular(ring, diag, 6))
	_add(cands, _fit_para(ring, diag, snap_axes))
	_add(cands, _fit_poly(ring, diag))
	var best := {}
	var best_score := INF
	for c in cands:
		var score: float = float(c.err) * float(PRIOR.get(c.shape, 1.2))
		if float(c.err) <= MAX_ERR and score < best_score:
			best_score = score
			best = c
	return best


static func _add(list: Array, c: Dictionary) -> void:
	if not c.is_empty():
		list.append(c)


static func _err(ring: PackedVector2Array, outline: PackedVector2Array, diag: float) -> float:
	# mean distance of the ink to the outline, plus a penalty for outline stretches the ink never visits
	var mean := Geom2D.mean_dist_to_polyline(ring, outline, true)
	var gap := Geom2D.coverage_gap(ring, outline, true)
	return (mean + 0.35 * gap) / maxf(diag, 1e-6)


static func _fit_ellipse(ring: PackedVector2Array, diag: float, snap_axes: bool) -> Dictionary:
	var fit := Geom2D.pca(ring)
	var u: Vector2 = fit.axis
	var v := Vector2(-u.y, u.x)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in ring:
		var q := Vector2(p.dot(u), p.dot(v))
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var c_local := (lo + hi) * 0.5
	var center := u * c_local.x + v * c_local.y
	var half := (hi - lo) * 0.5
	var rot := u.angle()
	if snap_axes:
		rot = Geom2D.fold_half_pi(rot)
		if absf(rot) < AXIS_SNAP:
			rot = 0.0
		elif absf(absf(rot) - PI * 0.5) < AXIS_SNAP:
			rot = 0.0
			half = Vector2(half.y, half.x)
	if absf(half.x - half.y) / maxf(half.x, half.y) < SQUARE_TOL:
		var r := (half.x + half.y) * 0.5
		half = Vector2(r, r)
	# the ellipse's own bounding centre is only exact for unsnapped axes; recompute the centre from the ring
	var outline := PackedVector2Array()
	for p in Geom2D.ellipse_points(half.x, half.y, 48):
		outline.append(center + Geom2D.rot(p, rot))
	return {"shape": "ellipse", "center": center, "size": half * 2.0, "rot": rot, "err": _err(ring, outline, diag)}


static func _fit_rect(ring: PackedVector2Array, diag: float, snap_axes: bool) -> Dictionary:
	var best := {}
	var from_corners := _rect_from_corners(ring, diag)
	var from_hull := Geom2D.min_area_rect(ring)
	var options: Array = []
	if not from_corners.is_empty():
		options.append(from_corners)
	if not from_hull.is_empty():
		options.append(from_hull)
	var best_err := INF
	for o in options:
		var r := _finish_rect(ring, diag, o.center, o.size, o.rot, snap_axes)
		if not r.is_empty() and float(r.err) < best_err:
			best_err = float(r.err)
			best = r
	return best


## Rectangle through the four corners found by simplifying the loop: average direction and side lengths.
static func _rect_from_corners(ring: PackedVector2Array, diag: float) -> Dictionary:
	var v := _simplify_to(ring, 4, diag)
	if v.size() != 4:
		return {}
	var sgn := 1.0 if (v[1] - v[0]).cross(v[2] - v[1]) > 0.0 else -1.0
	var dir := Vector2.ZERO
	var lens: Array = []
	for i in 4:
		var e := v[(i + 1) % 4] - v[i]
		lens.append(e.length())
		if e.length_squared() > 1e-12:
			dir += Geom2D.rot(e.normalized(), -sgn * float(i) * PI * 0.5)
	if dir.length_squared() < 1e-9:
		return {}
	var w := (float(lens[0]) + float(lens[2])) * 0.5
	var h := (float(lens[1]) + float(lens[3])) * 0.5
	return {"center": Geom2D.centroid(v), "size": Vector2(w, h), "rot": dir.angle()}


static func _finish_rect(ring: PackedVector2Array, diag: float, center: Vector2, size: Vector2, rot: float, snap_axes: bool) -> Dictionary:
	# rotation in (-45, 45] degrees; swap the sides when the turn is bigger
	rot = wrapf(rot, -PI, PI)
	while rot > PI * 0.25:
		rot -= PI * 0.5
		size = Vector2(size.y, size.x)
	while rot <= -PI * 0.25:
		rot += PI * 0.5
		size = Vector2(size.y, size.x)
	if snap_axes and absf(rot) < AXIS_SNAP:
		rot = 0.0
	if size.x < 0.012 or size.y < 0.012:
		return {}
	if absf(size.x - size.y) / maxf(size.x, size.y) < SQUARE_TOL:
		var s := (size.x + size.y) * 0.5
		size = Vector2(s, s)
	var outline := PackedVector2Array()
	for p in Shapes.fill_poly("rect", size):
		outline.append(center + Geom2D.rot(p, rot))
	var e := _err(ring, outline, diag)
	# a square turned about 45 degrees is a decision diamond
	if absf(size.x - size.y) / maxf(size.x, size.y) < 0.02 and absf(absf(rot) - PI * 0.25) < deg_to_rad(9.0):
		return {"shape": "diamond", "center": center, "size": Vector2(size.x * sqrt(2.0), size.y * sqrt(2.0)), "rot": 0.0, "err": e}
	return {"shape": "rect", "center": center, "size": size, "rot": rot, "err": e}


static func _fit_diamond(ring: PackedVector2Array, diag: float) -> Dictionary:
	var bb := Geom2D.bbox(ring)
	if bb.size.x < 0.012 or bb.size.y < 0.012:
		return {}
	var c := bb.get_center()
	var outline := PackedVector2Array()
	for p in Shapes.fill_poly("diamond", bb.size):
		outline.append(c + p)
	return {"shape": "diamond", "center": c, "size": bb.size, "rot": 0.0, "err": _err(ring, outline, diag)}


## Simplify a closed loop to exactly n corners (or fail with an empty array): Douglas-Peucker at a small tolerance to drop the
## hand's wobble, then repeatedly remove the vertex that changes the outline least (smallest triangle with its neighbours).
static func _simplify_to(ring: PackedVector2Array, n: int, diag: float) -> PackedVector2Array:
	var v := Geom2D.rdp_closed(ring, 0.012 * diag)
	if v.size() < n:
		return PackedVector2Array()
	while v.size() > n:
		var worst := INF
		var wi := 0
		var m := v.size()
		for i in m:
			var p := v[(i + m - 1) % m]
			var q := v[i]
			var r := v[(i + 1) % m]
			var area := absf((q - p).cross(r - p)) * 0.5
			if area < worst:
				worst = area
				wi = i
		v.remove_at(wi)
	return v


static func _merge_close(v: PackedVector2Array, min_dist: float) -> PackedVector2Array:
	var out := PackedVector2Array(v)
	var i := 0
	while i < out.size() and out.size() > 3:
		var j := (i + 1) % out.size()
		if out[i].distance_to(out[j]) < min_dist:
			out[i] = (out[i] + out[j]) * 0.5
			out.remove_at(j)
			if j < i:
				i -= 1
		else:
			i += 1
	return out


static func _fit_triangle(ring: PackedVector2Array, diag: float) -> Dictionary:
	var v := _simplify_to(ring, 3, diag)
	if v.size() != 3:
		return {}
	for i in 3:
		if Geom2D.angle_at(v[(i + 2) % 3], v[i], v[(i + 1) % 3]) < deg_to_rad(18.0):
			return {}
	# apex: the vertex whose two sides are most alike
	var apex := 0
	var best := INF
	for i in 3:
		var d := absf(v[i].distance_to(v[(i + 1) % 3]) - v[i].distance_to(v[(i + 2) % 3]))
		if d < best:
			best = d
			apex = i
	var ap := v[apex]
	var b1 := v[(apex + 1) % 3]
	var b2 := v[(apex + 2) % 3]
	var base_mid := (b1 + b2) * 0.5
	var up := ap - base_mid
	var h := up.length()
	var w := b1.distance_to(b2)
	if h < 0.012 or w < 0.012:
		return {}
	var rot := up.angle() - PI * 0.5
	if absf(Geom2D.fold_half_pi(rot)) < AXIS_SNAP and absf(rot) < PI * 0.5:
		rot = 0.0
	elif absf(absf(rot) - PI) < AXIS_SNAP:
		rot = PI
	var center := base_mid + up * 0.5
	var ideal := PackedVector2Array()
	for p in Shapes.fill_poly("triangle", Vector2(w, h)):
		ideal.append(center + Geom2D.rot(p, rot))
	var e_ideal := _err(ring, ideal, diag)
	var e_raw := _err(ring, v, diag)
	if e_ideal > e_raw + 0.025:                      # a lopsided triangle: keep what was drawn
		return {"shape": "poly", "poly": v, "err": e_raw}
	return {"shape": "triangle", "center": center, "size": Vector2(w, h), "rot": rot, "err": e_ideal}


static func _fit_regular(ring: PackedVector2Array, diag: float, n: int) -> Dictionary:
	var v := _simplify_to(ring, n, diag)
	if v.size() != n:
		return {}
	var c := Geom2D.centroid(v)
	var rad := 0.0
	for p in v:
		rad += p.distance_to(c)
	rad /= n
	# the sides must be about equal for a regular polygon
	var lens: Array = []
	for i in n:
		lens.append(v[i].distance_to(v[(i + 1) % n]))
	var mean_l := 0.0
	for l in lens:
		mean_l += l
	mean_l /= n
	for l in lens:
		if absf(l - mean_l) > 0.3 * mean_l:
			return {}
	var id := "pent" if n == 5 else "hex"
	var ang0 := (v[0] - c).angle()
	var rot := 0.0
	var size := Vector2.ZERO
	if n == 5:
		rot = fposmod(ang0 - PI * 0.5 + PI / 5.0, TAU / 5.0) - PI / 5.0
		size = Vector2(1.9021 * rad, 1.809 * rad)
	else:
		rot = fposmod(ang0 + PI / 6.0, TAU / 6.0) - PI / 6.0
		size = Vector2(2.0 * rad, 1.7321 * rad)
	if absf(rot) < AXIS_SNAP:
		rot = 0.0
	# bounding-box centre of the regular polygon is not its centroid for the pentagon (apex up): shift
	var center := c
	if n == 5:
		center = c + Geom2D.rot(Vector2(0, rad - (1.0 + cos(PI / 5.0)) * rad * 0.5), rot)
	var outline := PackedVector2Array()
	for p in Shapes.fill_poly(id, size):
		outline.append(center + Geom2D.rot(p, rot))
	return {"shape": id, "center": center, "size": size, "rot": rot, "err": _err(ring, outline, diag)}


static func _fit_para(ring: PackedVector2Array, diag: float, snap_axes: bool) -> Dictionary:
	var v := _simplify_to(ring, 4, diag)
	if v.size() != 4:
		return {}
	# find the horizontal-ish pair of opposite sides
	var bb := Geom2D.bbox(v)
	var top: Array = []
	var bot: Array = []
	var ys: Array = []
	for i in 4:
		ys.append([v[i].y, i])
	ys.sort_custom(func(p, q): return p[0] > q[0])
	top = [v[ys[0][1]], v[ys[1][1]]]
	bot = [v[ys[2][1]], v[ys[3][1]]]
	var tl: Vector2 = top[0] if top[0].x < top[1].x else top[1]
	var tr: Vector2 = top[1] if top[0].x < top[1].x else top[0]
	var bl: Vector2 = bot[0] if bot[0].x < bot[1].x else bot[1]
	var br: Vector2 = bot[1] if bot[0].x < bot[1].x else bot[0]
	if absf((tr - tl).angle()) > deg_to_rad(9.0) or absf((br - bl).angle()) > deg_to_rad(9.0):
		return {}
	var skew := (tl.x - bl.x)
	var w := bb.size.x
	var s := absf(skew)
	if skew <= 0.0 or s < 0.12 * w or s > 0.34 * w:
		return {}
	var c := bb.get_center()
	var outline := PackedVector2Array()
	for p in Shapes.fill_poly("para", bb.size):
		outline.append(c + p)
	return {"shape": "para", "center": c, "size": bb.size, "rot": 0.0, "err": _err(ring, outline, diag)}


static func _fit_poly(ring: PackedVector2Array, diag: float) -> Dictionary:
	for n in range(4, 9):
		var v := _simplify_to(ring, n, diag)
		if v.size() != n:
			continue
		var ok := true
		for i in n:
			if Geom2D.angle_at(v[(i + n - 1) % n], v[i], v[(i + 1) % n]) > deg_to_rad(155.0):
				ok = false
		if not ok:
			continue
		return {"shape": "poly", "poly": v, "err": _err(ring, v, diag)}
	return {}


static func _dedupe(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > 1e-8:
			out.append(p)
	return out
