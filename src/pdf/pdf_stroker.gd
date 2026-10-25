class_name PdfStroker
extends RefCounted
## Turns stroked paths into triangles: a rectangle for every segment of the line, wedges for the joins, a cap at each end of an open line,
## cut into dashes when the pattern asks. The pieces overlap where lines bend, which is invisible for an opaque colour; a translucent
## stroke is first made into one outline by the engine's polygon offsetting (outline()) so nothing is painted twice.

const BUTT := 0
const ROUND := 1
const SQUARE := 2
const MITER := 0
const BEVEL := 2
const MAX_DASHES := 30000


## Triangles (a soup) for the strokes of `contours` (polylines in the space the width is in). `closed` has one flag per contour.
static func stroke(contours: Array, closed: PackedByteArray, width: float, cap: int, join: int, miter_limit: float,
		dash: PackedFloat64Array, phase: float, tol: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var hw := width * 0.5
	if hw <= 0.0:
		return out
	var step := _arc_step(hw, tol)
	for ci in contours.size():
		var poly := _dedupe(contours[ci], hw * 1e-4)
		var is_closed := closed[ci] == 1
		if is_closed and poly.size() > 1 and poly[0].distance_squared_to(poly[poly.size() - 1]) < (hw * 1e-4) * (hw * 1e-4):
			poly.remove_at(poly.size() - 1)
		if poly.size() == 1:
			_dot(out, poly[0], hw, cap, step)
			continue
		if poly.size() < 2:
			continue
		var pieces: Array = []
		if not dash.is_empty() and _dash_total(dash) > 0.0:
			pieces = _dashes(poly, is_closed, dash, phase)
			for pc in pieces:
				_polyline(out, pc, false, hw, cap, join, miter_limit, step)
		else:
			_polyline(out, poly, is_closed, hw, cap, join, miter_limit, step)
	return out


## The same strokes as filled outlines (contours to fill with the non-zero rule), merged so that no area is covered twice.
static func outline(contours: Array, closed: PackedByteArray, width: float, cap: int, join: int, miter_limit: float,
		dash: PackedFloat64Array, phase: float) -> Array:
	var out: Array = []
	var hw := width * 0.5
	if hw <= 0.0:
		return out
	var jt := Geometry2D.JOIN_MITER if join == MITER else (Geometry2D.JOIN_ROUND if join == ROUND else Geometry2D.JOIN_SQUARE)
	for ci in contours.size():
		var poly := _dedupe(contours[ci], hw * 1e-4)
		var is_closed := closed[ci] == 1
		if poly.size() < 2:
			continue
		var lines: Array = []
		if not dash.is_empty() and _dash_total(dash) > 0.0:
			lines = _dashes(poly, is_closed, dash, phase)
			is_closed = false
		else:
			lines = [poly]
		for ln in lines:
			var et := Geometry2D.END_JOINED if is_closed else (Geometry2D.END_BUTT if cap == BUTT else (Geometry2D.END_ROUND if cap == ROUND else Geometry2D.END_SQUARE))
			var res := Geometry2D.offset_polyline(ln, hw, jt, et)
			for r in res:
				out.append(r)
	return out


static func _arc_step(r: float, tol: float) -> float:
	var t := minf(tol, r * 0.5)
	return clampf(2.0 * acos(1.0 - t / r), 0.12, 1.2)


static func _dedupe(poly: PackedVector2Array, gap: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var g2 := gap * gap
	for p in poly:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > g2:
			out.append(p)
	return out


static func _dash_total(dash: PackedFloat64Array) -> float:
	var s := 0.0
	for d in dash:
		s += absf(d)
	return s


static func _dot(out: PackedVector2Array, c: Vector2, hw: float, cap: int, step: float) -> void:
	if cap == ROUND:
		_fan(out, c, 0.0, TAU, hw, step)
	elif cap == SQUARE:
		_quad(out, c + Vector2(-hw, -hw), c + Vector2(hw, -hw), c + Vector2(hw, hw), c + Vector2(-hw, hw))


static func _quad(out: PackedVector2Array, a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> void:
	out.append(a)
	out.append(b)
	out.append(c)
	out.append(a)
	out.append(c)
	out.append(d)


## A fan of triangles around `c` from angle a0 to a1 (radius r).
static func _fan(out: PackedVector2Array, c: Vector2, a0: float, a1: float, r: float, step: float) -> void:
	var n := maxi(ceili(absf(a1 - a0) / step), 1)
	var prev := c + Vector2(cos(a0), sin(a0)) * r
	for i in range(1, n + 1):
		var a := a0 + (a1 - a0) * float(i) / n
		var q := c + Vector2(cos(a), sin(a)) * r
		out.append(c)
		out.append(prev)
		out.append(q)
		prev = q


static func _polyline(out: PackedVector2Array, pts: PackedVector2Array, is_closed: bool, hw: float, cap: int, join: int, miter_limit: float, step: float) -> void:
	var n := pts.size()
	if n < 2:
		return
	var segs := n if is_closed else n - 1
	var dirs := PackedVector2Array()
	for i in segs:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var d := (b - a)
		var l := d.length()
		dirs.append(d / l if l > 0.0 else Vector2.RIGHT)
	for i in segs:
		var a2 := pts[i]
		var b2 := pts[(i + 1) % n]
		var nrm := Vector2(-dirs[i].y, dirs[i].x) * hw
		_quad(out, a2 + nrm, a2 - nrm, b2 - nrm, b2 + nrm)
	# joins
	var first_join := 0 if is_closed else 1
	var last_join := n if is_closed else n - 1
	for v in range(first_join, last_join):
		var d0 := dirs[(v - 1 + segs) % segs] if is_closed else dirs[v - 1]
		var d1 := dirs[v % segs]
		_join(out, pts[v % n], d0, d1, hw, join, miter_limit, step)
	if not is_closed:
		_cap(out, pts[0], -dirs[0], hw, cap, step)
		_cap(out, pts[n - 1], dirs[segs - 1], hw, cap, step)


static func _join(out: PackedVector2Array, p: Vector2, d0: Vector2, d1: Vector2, hw: float, join: int, miter_limit: float, step: float) -> void:
	var cr := d0.cross(d1)
	var dt := d0.dot(d1)
	if absf(cr) < 1e-7 and dt > 0.0:
		return
	# the outer side is the side the line turns away from
	var s := -1.0 if cr > 0.0 else 1.0
	var o0 := Vector2(-d0.y, d0.x) * hw * s
	var o1 := Vector2(-d1.y, d1.x) * hw * s
	if join == ROUND:
		var a0 := o0.angle()
		var a1 := o1.angle()
		var da := a1 - a0
		while da > PI:
			da -= TAU
		while da < -PI:
			da += TAU
		_fan(out, p, a0, a0 + da, hw, step)
		return
	if join == MITER and dt > -0.9999:
		var ratio := 1.0 / sqrt(maxf((1.0 + dt) * 0.5, 1e-9))
		if ratio <= miter_limit:
			var tip := p + (o0 + o1) / (1.0 + dt)
			_quad(out, p, p + o0, tip, p + o1)
			return
	out.append(p)
	out.append(p + o0)
	out.append(p + o1)


static func _cap(out: PackedVector2Array, p: Vector2, outward: Vector2, hw: float, cap: int, step: float) -> void:
	var nrm := Vector2(-outward.y, outward.x) * hw
	if cap == SQUARE:
		var ext := outward * hw
		_quad(out, p + nrm, p + nrm + ext, p - nrm + ext, p - nrm)
	elif cap == ROUND:
		var a0 := nrm.angle()
		_fan(out, p, a0 - PI, a0, hw, step)


## Cuts a polyline into the dashes of the pattern (lengths of marks and gaps, starting `phase` into it).
static func _dashes(pts: PackedVector2Array, is_closed: bool, dash: PackedFloat64Array, phase: float) -> Array:
	var pattern := PackedFloat64Array()
	for d in dash:
		pattern.append(maxf(d, 0.0))
	if pattern.size() % 2 == 1:
		pattern.append_array(pattern.duplicate())
	var total := _dash_total(pattern)
	var out: Array = []
	if total <= 0.0:
		return [pts]
	var idx := 0
	var ph := fposmod(phase, total)
	var guard := 0
	while ph >= pattern[idx] and guard < pattern.size() * 2:
		ph -= pattern[idx]
		idx = (idx + 1) % pattern.size()
		guard += 1
	var remain := pattern[idx] - ph
	var on := idx % 2 == 0
	var cur := PackedVector2Array()
	var path := pts.duplicate()
	if is_closed:
		path.append(pts[0])
	if on:
		cur.append(path[0])
	var count := 0
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var seg := a.distance_to(b)
		var pos := 0.0
		while seg - pos > remain:
			pos += remain
			var q := a.lerp(b, pos / seg)
			if on:
				cur.append(q)
				out.append(cur)
				cur = PackedVector2Array()
			else:
				cur = PackedVector2Array([q])
			on = not on
			idx = (idx + 1) % pattern.size()
			remain = pattern[idx]
			count += 1
			if count > MAX_DASHES:
				return out
			if remain <= 0.0:
				# a zero-length mark (a dot with round caps) or gap: toggle straight away
				if on:
					out.append(PackedVector2Array([q, q + (b - a).normalized() * 1e-6]))
					cur = PackedVector2Array()
				on = not on
				idx = (idx + 1) % pattern.size()
				remain = pattern[idx]
				if on:
					cur = PackedVector2Array([q])
		remain -= seg - pos
		if on:
			cur.append(b)
	if on and cur.size() >= 2:
		out.append(cur)
	return out
