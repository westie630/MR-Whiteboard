class_name PdfGeom
extends RefCounted
## The plane geometry the PDF renderer is built on: cutting curves into short straight pieces, turning filled outlines into triangles
## (a fast way for outlines that do not cross themselves, and a slower sweep that handles anything with either fill rule), and
## cutting triangles off at a clip. Triangles are returned as a "soup": three consecutive points per triangle, no index list, so
## placing a glyph on a page is one transform of an array.

const EPS := 1e-9


# ------------------------------------------------------------------------------------------------ curves

static func flatten_quad(p0: Vector2, p1: Vector2, p2: Vector2, tol: float, out: PackedVector2Array) -> void:
	var d := (p0 - 2.0 * p1 + p2).length()
	var n := clampi(ceili(sqrt(0.25 * d / tol)), 1, 200)
	for i in range(1, n):
		var t := float(i) / n
		var mt := 1.0 - t
		out.append(mt * mt * p0 + 2.0 * mt * t * p1 + t * t * p2)
	out.append(p2)


static func flatten_cubic(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, tol: float, out: PackedVector2Array) -> void:
	var d1 := (p0 - 2.0 * p1 + p2).length()
	var d2 := (p1 - 2.0 * p2 + p3).length()
	var n := clampi(ceili(sqrt(0.75 * maxf(d1, d2) / tol)), 1, 200)
	for i in range(1, n):
		var t := float(i) / n
		var mt := 1.0 - t
		out.append(mt * mt * mt * p0 + 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t * p3)
	out.append(p3)


# ------------------------------------------------------------------------------------------------ small helpers

static func area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func bounds(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	return Rect2(lo, hi - lo)


static func inside(poly: PackedVector2Array, pt: Vector2) -> bool:
	var c := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var a := poly[i]
		var b := poly[j]
		if (a.y > pt.y) != (b.y > pt.y) and pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x:
			c = not c
		j = i
	return c


## The polygon with consecutive duplicate points (and a repeated closing point) taken out.
static func clean(poly: PackedVector2Array, min_gap: float = 1e-7) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > min_gap * min_gap:
			out.append(p)
	while out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) <= min_gap * min_gap:
		out.remove_at(out.size() - 1)
	return out


# ------------------------------------------------------------------------------------------------ filling outlines

## Triangles for the area the contours enclose. `even_odd` picks the fill rule (false: non-zero winding). Contours are implicitly closed.
static func fill(contours: Array, even_odd: bool) -> PackedVector2Array:
	var polys: Array = []
	for c in contours:
		var cp := clean(c)
		if cp.size() >= 3 and absf(area(cp)) > 1e-10:
			polys.append(cp)
	if polys.is_empty():
		return PackedVector2Array()
	if polys.size() == 1:
		var only: PackedVector2Array = polys[0]
		if only.size() == 3 or _is_convex(only):
			return _fan(only)
		if only.size() <= 3000 and not _crossings(polys):
			return _earcut(only, [])
		return _slab(polys, even_odd)
	if _crossings(polys):
		return _slab(polys, even_odd)
	return _nested(polys, even_odd)


static func _fan(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var a := area(poly)
	for i in range(1, poly.size() - 1):
		if a >= 0.0:
			out.append(poly[0])
			out.append(poly[i])
			out.append(poly[i + 1])
		else:
			out.append(poly[0])
			out.append(poly[i + 1])
			out.append(poly[i])
	return out


## Convex: every turn the same way, and a single turn round (a pentagram turns the same way at every corner but goes round twice).
static func _is_convex(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	var sign_ := 0
	var total := 0.0
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var c := poly[(i + 2) % n]
		var cr := (b - a).cross(c - b)
		total += atan2(cr, (b - a).dot(c - b))
		if absf(cr) < 1e-12:
			continue
		var s := 1 if cr > 0.0 else -1
		if sign_ == 0:
			sign_ = s
		elif s != sign_:
			return false
	return absf(absf(total) - TAU) < 0.01


## Contours that do not cross: which area is filled follows from how they nest. Every contour bounds a region of its own (itself minus its
## direct children), filled when the fill rule says so, and is triangulated with its children as holes.
static func _nested(polys: Array, even_odd: bool) -> PackedVector2Array:
	var n := polys.size()
	var areas := PackedFloat64Array()
	var boxes: Array = []
	for p in polys:
		areas.append(area(p))
		boxes.append(bounds(p))
	# parent = the smallest contour that contains a point of this one
	var parent := PackedInt32Array()
	parent.resize(n)
	for i in n:
		parent[i] = -1
		var probe := _probe(polys[i])
		var best_area := INF
		for j in n:
			if j == i or absf(areas[j]) <= absf(areas[i]) or not (boxes[j] as Rect2).has_point(probe):
				continue
			if inside(polys[j], probe) and absf(areas[j]) < best_area:
				best_area = absf(areas[j])
				parent[i] = j
	var winding := PackedInt32Array()
	winding.resize(n)
	var depth := PackedInt32Array()
	depth.resize(n)
	var order := range(n)
	order.sort_custom(func(a, b): return absf(areas[a]) > absf(areas[b]))
	for i in order:
		var o := 1 if areas[i] > 0.0 else -1
		if parent[i] >= 0:
			winding[i] = winding[parent[i]] + o
			depth[i] = depth[parent[i]] + 1
		else:
			winding[i] = o
	var out := PackedVector2Array()
	for i in n:
		var filled := (depth[i] % 2 == 0) if even_odd else (winding[i] != 0)
		if not filled:
			continue
		var holes: Array = []
		for j in n:
			if parent[j] == i:
				holes.append(polys[j])
		if holes.is_empty() and _is_convex(polys[i]):
			out.append_array(_fan(polys[i]))
		else:
			out.append_array(_earcut(polys[i], holes))
	return out


static func _probe(poly: PackedVector2Array) -> Vector2:
	# a vertex nudged towards the polygon's own inside is not reliable for odd shapes: the vertex itself is enough for nesting, as the
	# contours do not cross (a shared vertex is the only trouble, and a tie goes to "outside")
	return poly[0]


# ------------------------------------------------------------------------------------------------ crossings

## Do any two edges of the contours cross (or touch other than at the ends of neighbouring edges)?
static func _crossings(polys: Array) -> bool:
	var ax := PackedFloat64Array()
	var ay := PackedFloat64Array()
	var bx := PackedFloat64Array()
	var by := PackedFloat64Array()
	var cid := PackedInt32Array()
	var eid := PackedInt32Array()
	var ec := 0
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for ci in polys.size():
		var p: PackedVector2Array = polys[ci]
		var n := p.size()
		for i in n:
			var a := p[i]
			var b := p[(i + 1) % n]
			ax.append(a.x)
			ay.append(a.y)
			bx.append(b.x)
			by.append(b.y)
			cid.append(ci)
			eid.append(i)
			lo = lo.min(a)
			hi = hi.max(a)
			ec += 1
	if ec < 140:
		for i in ec:
			for j in range(i + 1, ec):
				if _edges_cross(ax, ay, bx, by, cid, eid, polys, i, j):
					return true
		return false
	# many edges: only edges that share a grid cell are compared
	var size := (hi - lo)
	var cells := maxi(int(sqrt(ec)), 4)
	var cw := maxf(size.x / cells, 1e-9)
	var ch := maxf(size.y / cells, 1e-9)
	var grid := {}
	for i in ec:
		var x0 := clampi(int((minf(ax[i], bx[i]) - lo.x) / cw), 0, cells)
		var x1 := clampi(int((maxf(ax[i], bx[i]) - lo.x) / cw), 0, cells)
		var y0 := clampi(int((minf(ay[i], by[i]) - lo.y) / ch), 0, cells)
		var y1 := clampi(int((maxf(ay[i], by[i]) - lo.y) / ch), 0, cells)
		for gx in range(x0, x1 + 1):
			for gy in range(y0, y1 + 1):
				var key := gx * 4099 + gy
				if not grid.has(key):
					grid[key] = []
				(grid[key] as Array).append(i)
	var tested := {}
	for key in grid:
		var list: Array = grid[key]
		if list.size() > 400:
			return true                               # a cell this crowded is a tangle: use the robust way
		for u in list.size():
			for v in range(u + 1, list.size()):
				var i: int = list[u]
				var j: int = list[v]
				var pk: int = i * 1000003 + j
				if tested.has(pk):
					continue
				tested[pk] = true
				if _edges_cross(ax, ay, bx, by, cid, eid, polys, i, j):
					return true
	return false


static func _edges_cross(ax: PackedFloat64Array, ay: PackedFloat64Array, bx: PackedFloat64Array, by: PackedFloat64Array, cid: PackedInt32Array,
		eid: PackedInt32Array, polys: Array, i: int, j: int) -> bool:
	# neighbours in one contour meet at a shared end: not a crossing
	if cid[i] == cid[j]:
		var n: int = (polys[cid[i]] as PackedVector2Array).size()
		var d := absi(eid[i] - eid[j])
		if d == 1 or d == n - 1:
			return _overlap_collinear(ax, ay, bx, by, i, j)
	if maxf(ax[i], bx[i]) < minf(ax[j], bx[j]) or maxf(ax[j], bx[j]) < minf(ax[i], bx[i]):
		return false
	if maxf(ay[i], by[i]) < minf(ay[j], by[j]) or maxf(ay[j], by[j]) < minf(ay[i], by[i]):
		return false
	var d1 := _side(ax[i], ay[i], bx[i], by[i], ax[j], ay[j])
	var d2 := _side(ax[i], ay[i], bx[i], by[i], bx[j], by[j])
	var d3 := _side(ax[j], ay[j], bx[j], by[j], ax[i], ay[i])
	var d4 := _side(ax[j], ay[j], bx[j], by[j], bx[i], by[i])
	if ((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0)) and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0)):
		return true
	# touching: a shared point of two different edges is a crossing for our purposes unless it is a shared end of different contours' neighbours
	if absf(d1) < 1e-12 and absf(d2) < 1e-12:
		return _overlap_collinear(ax, ay, bx, by, i, j)
	return false


static func _overlap_collinear(ax: PackedFloat64Array, ay: PackedFloat64Array, bx: PackedFloat64Array, by: PackedFloat64Array, i: int, j: int) -> bool:
	# two edges on one line that overlap along a stretch (not just at a point)
	var dx := bx[i] - ax[i]
	var dy := by[i] - ay[i]
	var l2 := dx * dx + dy * dy
	if l2 < 1e-24:
		return false
	if absf(_side(ax[i], ay[i], bx[i], by[i], ax[j], ay[j])) > 1e-9 * sqrt(l2) or absf(_side(ax[i], ay[i], bx[i], by[i], bx[j], by[j])) > 1e-9 * sqrt(l2):
		return false
	var t0 := ((ax[j] - ax[i]) * dx + (ay[j] - ay[i]) * dy) / l2
	var t1 := ((bx[j] - ax[i]) * dx + (by[j] - ay[i]) * dy) / l2
	var lo := maxf(minf(t0, t1), 0.0)
	var hi := minf(maxf(t0, t1), 1.0)
	return hi - lo > 1e-6


static func _side(x0: float, y0: float, x1: float, y1: float, px: float, py: float) -> float:
	return (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)


# ------------------------------------------------------------------------------------------------ ear clipping

## Triangles of a simple polygon with holes (none of the contours cross). Orientation of the inputs does not matter.
static func _earcut(outer: PackedVector2Array, holes: Array) -> PackedVector2Array:
	var pts := outer.duplicate()
	if area(pts) < 0.0:
		pts.reverse()
	if not holes.is_empty():
		var hs: Array = []
		for h in holes:
			var hp: PackedVector2Array = (h as PackedVector2Array).duplicate()
			if area(hp) > 0.0:
				hp.reverse()
			hs.append(hp)
		# bridge the holes in, the one reaching furthest right first
		hs.sort_custom(func(a, b): return _max_x(a) > _max_x(b))
		for hp in hs:
			pts = _bridge(pts, hp)
	var n := pts.size()
	var out := PackedVector2Array()
	if n < 3:
		return out
	var prev := PackedInt32Array()
	var next := PackedInt32Array()
	prev.resize(n)
	next.resize(n)
	for i in n:
		prev[i] = (i - 1 + n) % n
		next[i] = (i + 1) % n
	var left := n
	var cur := 0
	var stall := 0
	while left > 3:
		var a := prev[cur]
		var c := next[cur]
		var pa := pts[a]
		var pb := pts[cur]
		var pc := pts[c]
		var ear := false
		var cr := (pb - pa).cross(pc - pb)
		if cr > 1e-14:
			ear = true
			# no other vertex strictly inside the triangle (vertices equal to its corners, or on its edges, do not block it)
			var k := next[c]
			var eps := 1e-9 * maxf(maxf((pb - pa).length_squared(), (pc - pb).length_squared()), (pa - pc).length_squared())
			while k != a:
				var q := pts[k]
				if q != pa and q != pb and q != pc and _strictly_in_tri(pa, pb, pc, q, eps):
					ear = false
					break
				k = next[k]
		elif absf(cr) <= 1e-14:
			# a flat or doubled-back vertex adds nothing: drop it
			next[a] = c
			prev[c] = a
			left -= 1
			cur = a
			stall = 0
			continue
		if ear:
			out.append(pa)
			out.append(pb)
			out.append(pc)
			next[a] = c
			prev[c] = a
			left -= 1
			cur = a
			stall = 0
		else:
			cur = next[cur]
			stall += 1
			if stall > left:
				# no ear anywhere (a nearly degenerate polygon): the sharpest corner is dropped without a triangle, so that the loop ends and nothing
				# is ever painted twice
				var best := cur
				var best_cr := -INF
				var k2 := cur
				for s2 in left:
					var cr2 := (pts[k2] - pts[prev[k2]]).cross(pts[next[k2]] - pts[k2])
					if cr2 > best_cr:
						best_cr = cr2
						best = k2
					k2 = next[k2]
				var a2 := prev[best]
				var c2 := next[best]
				next[a2] = c2
				prev[c2] = a2
				left -= 1
				cur = a2
				stall = 0
	if left == 3:
		var a3 := cur
		var b3 := next[a3]
		var c3 := next[b3]
		if (pts[b3] - pts[a3]).cross(pts[c3] - pts[b3]) > 1e-14:
			out.append(pts[a3])
			out.append(pts[b3])
			out.append(pts[c3])
	return out


static func _max_x(poly: PackedVector2Array) -> float:
	var m := -INF
	for p in poly:
		m = maxf(m, p.x)
	return m


## Would the point spoil the ear (a, b, c) (counter-clockwise)? It does when it is inside the triangle or on the new edge c-a (cutting the ear
## would then leave the outline touching itself there); a point on the two old edges a-b and b-c does not.
static func _strictly_in_tri(a: Vector2, b: Vector2, c: Vector2, p: Vector2, eps: float) -> bool:
	return (b - a).cross(p - a) > eps and (c - b).cross(p - b) > eps and (a - c).cross(p - c) >= -eps


static func _in_tri(a: Vector2, b: Vector2, c: Vector2, p: Vector2) -> bool:
	var d1 := (b - a).cross(p - a)
	var d2 := (c - b).cross(p - b)
	var d3 := (a - c).cross(p - c)
	return d1 >= -1e-14 and d2 >= -1e-14 and d3 >= -1e-14


## Joins a hole (clockwise) to the outline (counter-clockwise) with a cut from the hole's rightmost point to a visible vertex.
static func _bridge(outer: PackedVector2Array, hole: PackedVector2Array) -> PackedVector2Array:
	var hi := 0
	for i in hole.size():
		if hole[i].x > hole[hi].x:
			hi = i
	var m := hole[hi]
	# the nearest edge of the outline to the right of m along the horizontal ray
	var best_x := INF
	var edge := -1
	var n := outer.size()
	for i in n:
		var a := outer[i]
		var b := outer[(i + 1) % n]
		if (a.y <= m.y and b.y >= m.y) or (b.y <= m.y and a.y >= m.y):
			if a.y == b.y:
				continue
			var x := a.x + (m.y - a.y) * (b.x - a.x) / (b.y - a.y)
			if x >= m.x - 1e-12 and x < best_x:
				best_x = x
				edge = i
	if edge < 0:
		return outer                                      # the hole is not inside the outline: leave it out
	var e0 := outer[edge]
	var e1 := outer[(edge + 1) % n]
	var cand := edge if e0.x > e1.x else (edge + 1) % n
	var ip := Vector2(best_x, m.y)
	if absf(best_x - m.x) < 1e-12:
		cand = edge if e0.distance_squared_to(m) < e1.distance_squared_to(m) else (edge + 1) % n
	elif not Vector2(best_x, m.y).is_equal_approx(outer[cand]):
		# a reflex vertex of the outline inside the triangle (m, ip, candidate) hides the candidate: take the one with the smallest angle
		# (when the ray hits a vertex of the outline exactly, that vertex is the one)
		var pc := outer[cand]
		var best_ang := INF
		var best_i := cand
		for i in n:
			var q := outer[i]
			if i == cand or q == pc:
				continue
			if q.x >= m.x and _in_tri_oriented(m, ip, pc, q):
				var ang := absf(atan2(q.y - m.y, q.x - m.x))
				if ang < best_ang or (is_equal_approx(ang, best_ang) and q.x < outer[best_i].x):
					best_ang = ang
					best_i = i
		cand = best_i
	var out := PackedVector2Array()
	for i in range(cand + 1):
		out.append(outer[i])
	for k in range(hole.size() + 1):
		out.append(hole[(hi + k) % hole.size()])
	out.append(outer[cand])
	for i in range(cand + 1, n):
		out.append(outer[i])
	return out


static func _in_tri_oriented(a: Vector2, b: Vector2, c: Vector2, p: Vector2) -> bool:
	var s := (b - a).cross(c - a)
	if s < 0.0:
		var t := b
		b = c
		c = t
	return _in_tri(a, b, c, p)


# ------------------------------------------------------------------------------------------------ the sweep: anything goes

## Triangles for the area covered by the contours under either fill rule, however they cross. The plane is cut into horizontal slabs
## at every vertex (and at every place two edges cross); inside a slab the edges do not cross, so the filled stretches are trapezoids.
static func _slab(polys: Array, even_odd: bool) -> PackedVector2Array:
	var ex0 := PackedFloat64Array()
	var ey0 := PackedFloat64Array()
	var ex1 := PackedFloat64Array()
	var ey1 := PackedFloat64Array()
	var edir := PackedInt32Array()
	var ys := PackedFloat64Array()
	for p in polys:
		var poly: PackedVector2Array = p
		var n := poly.size()
		for i in n:
			var a := poly[i]
			var b := poly[(i + 1) % n]
			ys.append(a.y)
			if a.y == b.y:
				continue
			if a.y < b.y:
				ex0.append(a.x)
				ey0.append(a.y)
				ex1.append(b.x)
				ey1.append(b.y)
				edir.append(1)
			else:
				ex0.append(b.x)
				ey0.append(b.y)
				ex1.append(a.x)
				ey1.append(a.y)
				edir.append(-1)
	var out := PackedVector2Array()
	var ne := edir.size()
	if ne == 0:
		return out
	ys.sort()
	var levels := PackedFloat64Array()
	for y in ys:
		if levels.is_empty() or y - levels[levels.size() - 1] > 1e-9:
			levels.append(y)
	# edges by their lower level, so that the active set can be kept as the sweep moves up
	var by_start: Array = []
	var order := range(ne)
	order.sort_custom(func(a, b): return ey0[a] < ey0[b])
	var active: Array = []
	var oi := 0
	var work: Array = []
	for li in levels.size() - 1:
		var ya := levels[li]
		var yb := levels[li + 1]
		while oi < ne and ey0[order[oi]] <= ya + 1e-9:
			active.append(order[oi])
			oi += 1
		var still: Array = []
		for e in active:
			if ey1[e] > ya + 1e-9:
				still.append(e)
		active = still
		if active.is_empty():
			continue
		work.append([ya, yb, active.duplicate()])
	# crossing edges split a slab: the pieces go back on the work list
	var guard := 0
	while not work.is_empty() and guard < 200000:
		guard += 1
		var job: Array = work.pop_back()
		var ya2: float = job[0]
		var yb2: float = job[1]
		var act: Array = job[2]
		var splits := _crossing_levels(act, ex0, ey0, ex1, ey1, ya2, yb2)
		if not splits.is_empty():
			var prev_y := ya2
			splits.sort()
			for sy in splits:
				if sy - prev_y > 1e-9 and yb2 - sy > 1e-9:
					work.append([prev_y, sy, act])
					prev_y = sy
			work.append([prev_y, yb2, act])
			continue
		_emit_slab(out, act, ex0, ey0, ex1, ey1, edir, ya2, yb2, even_odd)
	return out


## The heights inside the slab (ya, yb) where two of the active edges cross.
static func _crossing_levels(act: Array, ex0: PackedFloat64Array, ey0: PackedFloat64Array, ex1: PackedFloat64Array, ey1: PackedFloat64Array, ya: float, yb: float) -> Array:
	var n := act.size()
	if n < 2:
		return []
	var xa := PackedFloat64Array()
	var xb := PackedFloat64Array()
	for e in act:
		xa.append(_x_at(ex0, ey0, ex1, ey1, e, ya))
		xb.append(_x_at(ex0, ey0, ex1, ey1, e, yb))
	var out: Array = []
	for i in n:
		for j in range(i + 1, n):
			var d0 := xa[i] - xa[j]
			var d1 := xb[i] - xb[j]
			if (d0 > 1e-9 and d1 < -1e-9) or (d0 < -1e-9 and d1 > 1e-9):
				var t := d0 / (d0 - d1)
				var y := ya + (yb - ya) * t
				if y > ya + 1e-9 and y < yb - 1e-9:
					out.append(y)
	return out


static func _x_at(ex0: PackedFloat64Array, ey0: PackedFloat64Array, ex1: PackedFloat64Array, ey1: PackedFloat64Array, e: int, y: float) -> float:
	var dy := ey1[e] - ey0[e]
	return ex0[e] + (y - ey0[e]) * (ex1[e] - ex0[e]) / dy


static func _emit_slab(out: PackedVector2Array, act: Array, ex0: PackedFloat64Array, ey0: PackedFloat64Array, ex1: PackedFloat64Array, ey1: PackedFloat64Array,
		edir: PackedInt32Array, ya: float, yb: float, even_odd: bool) -> void:
	var ym := (ya + yb) * 0.5
	var items: Array = []
	for e in act:
		items.append([_x_at(ex0, ey0, ex1, ey1, e, ym), e])
	items.sort_custom(func(a, b): return a[0] < b[0])
	var wind := 0
	var start := -1
	for it in items:
		var e: int = it[1]
		var was := wind != 0 if not even_odd else (wind % 2 != 0)
		wind += edir[e]
		var now := wind != 0 if not even_odd else (wind % 2 != 0)
		if not was and now:
			start = e
		elif was and not now and start >= 0:
			var xl_a := _x_at(ex0, ey0, ex1, ey1, start, ya)
			var xl_b := _x_at(ex0, ey0, ex1, ey1, start, yb)
			var xr_a := _x_at(ex0, ey0, ex1, ey1, e, ya)
			var xr_b := _x_at(ex0, ey0, ex1, ey1, e, yb)
			var p0 := Vector2(xl_a, ya)
			var p1 := Vector2(xr_a, ya)
			var p2 := Vector2(xr_b, yb)
			var p3 := Vector2(xl_b, yb)
			if absf(xr_a - xl_a) > 1e-12:
				out.append(p0)
				out.append(p1)
				out.append(p2)
			if absf(xr_b - xl_b) > 1e-12:
				out.append(p0)
				out.append(p2)
				out.append(p3)
			start = -1


# ------------------------------------------------------------------------------------------------ clipping triangles

## The triangles of `soup` cut off at the rectangle.
static func clip_rect(soup: PackedVector2Array, r: Rect2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var lo := r.position
	var hi := r.end
	var i := 0
	var n := soup.size()
	while i + 2 < n:
		var a := soup[i]
		var b := soup[i + 1]
		var c := soup[i + 2]
		i += 3
		var mn := a.min(b).min(c)
		var mx := a.max(b).max(c)
		if mx.x < lo.x or mn.x > hi.x or mx.y < lo.y or mn.y > hi.y:
			continue
		if mn.x >= lo.x and mx.x <= hi.x and mn.y >= lo.y and mx.y <= hi.y:
			out.append(a)
			out.append(b)
			out.append(c)
			continue
		var poly := PackedVector2Array([a, b, c])
		poly = _cut(poly, 0, lo.x, true)
		poly = _cut(poly, 0, hi.x, false)
		poly = _cut(poly, 1, lo.y, true)
		poly = _cut(poly, 1, hi.y, false)
		for k in range(1, poly.size() - 1):
			out.append(poly[0])
			out.append(poly[k])
			out.append(poly[k + 1])
	return out


## One side of Sutherland-Hodgman: keeps the part of the polygon on the `keep_above` side of the axis line.
static func _cut(poly: PackedVector2Array, axis: int, at: float, keep_above: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := poly.size()
	if n == 0:
		return out
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		var pv := p[axis]
		var qv := q[axis]
		var p_in := pv >= at if keep_above else pv <= at
		var q_in := qv >= at if keep_above else qv <= at
		if p_in:
			out.append(p)
		if p_in != q_in:
			var t := (at - pv) / (qv - pv)
			out.append(p + (q - p) * t)
	return out


## The triangles of `soup` cut off at a convex polygon (counter-clockwise).
static func clip_convex(soup: PackedVector2Array, clip: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var m := clip.size()
	var i := 0
	while i + 2 < soup.size():
		var poly := PackedVector2Array([soup[i], soup[i + 1], soup[i + 2]])
		i += 3
		for k in m:
			if poly.is_empty():
				break
			var a := clip[k]
			var b := clip[(k + 1) % m]
			var cut := PackedVector2Array()
			var np := poly.size()
			for j in np:
				var p := poly[j]
				var q := poly[(j + 1) % np]
				var dp := (b - a).cross(p - a)
				var dq := (b - a).cross(q - a)
				if dp >= 0.0:
					cut.append(p)
				if (dp >= 0.0) != (dq >= 0.0):
					cut.append(p + (q - p) * (dp / (dp - dq)))
			poly = cut
		for k in range(1, poly.size() - 1):
			out.append(poly[0])
			out.append(poly[k])
			out.append(poly[k + 1])
	return out
