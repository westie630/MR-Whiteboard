class_name Shapes
extends RefCounted
## The shape library: outlines of the stencil shapes (flow-diagram boxes, diamonds, ...), their connection ports and the
## helpers for the line-type shapes (line, arrow, double arrow, elbow connector).
##
## Shapes are parametric: a centre, a size (w, h) and a rotation. `outlines()` gives the polylines in the shape's own frame
## (centred on the origin, before rotation, y up). Line-type shapes are defined by their two end points instead.

const STENCILS := [
	{"id": "rect", "name": "Process", "group": "flow"},
	{"id": "rrect", "name": "Start / End", "group": "flow"},
	{"id": "diamond", "name": "Decision", "group": "flow"},
	{"id": "para", "name": "Data", "group": "flow"},
	{"id": "doc", "name": "Document", "group": "flow"},
	{"id": "cyl", "name": "Database", "group": "flow"},
	{"id": "ellipse", "name": "Circle", "group": "basic"},
	{"id": "triangle", "name": "Triangle", "group": "basic"},
	{"id": "hex", "name": "Hexagon", "group": "basic"},
	{"id": "pent", "name": "Pentagon", "group": "basic"},
	{"id": "star", "name": "Star", "group": "basic"},
	{"id": "rarrow", "name": "Block arrow", "group": "basic"},
	{"id": "line", "name": "Line", "group": "line"},
	{"id": "arrow", "name": "Arrow", "group": "line"},
	{"id": "darrow", "name": "Double arrow", "group": "line"},
	{"id": "elbow", "name": "Elbow arrow", "group": "line"},
]

const LINE_IDS := ["line", "arrow", "darrow", "elbow"]
const DEFAULT_SIZE := {
	"rect": Vector2(0.24, 0.14), "rrect": Vector2(0.24, 0.12), "diamond": Vector2(0.24, 0.16), "para": Vector2(0.26, 0.14),
	"doc": Vector2(0.24, 0.16), "cyl": Vector2(0.16, 0.2), "ellipse": Vector2(0.18, 0.18), "triangle": Vector2(0.2, 0.18),
	"hex": Vector2(0.22, 0.18), "pent": Vector2(0.2, 0.2), "star": Vector2(0.22, 0.22), "rarrow": Vector2(0.26, 0.14),
}
const SEGMENT_LENGTH := 0.010              # curves are cut into pieces this long at most: no visible facets however big the shape is


static func is_line(id: String) -> bool:
	return LINE_IDS.has(id)


static func name_of(id: String) -> String:
	for s in STENCILS:
		if s.id == id:
			return s.name
	return id


static func default_size(id: String) -> Vector2:
	return DEFAULT_SIZE.get(id, Vector2(0.2, 0.2))


## Closed polygon of the shape (used for the fill and for hit tests).
static func fill_poly(id: String, size: Vector2) -> PackedVector2Array:
	var w := maxf(size.x, 1e-4) * 0.5
	var h := maxf(size.y, 1e-4) * 0.5
	match id:
		"rect":
			return PackedVector2Array([Vector2(-w, h), Vector2(w, h), Vector2(w, -h), Vector2(-w, -h)])
		"rrect":
			return _rounded_rect(w, h, minf(w, h) * 0.9)
		"ellipse":
			return Geom2D.ellipse_points(w, h, _curve_segments(w, h))
		"diamond":
			return PackedVector2Array([Vector2(0, h), Vector2(w, 0), Vector2(0, -h), Vector2(-w, 0)])
		"triangle":
			return PackedVector2Array([Vector2(0, h), Vector2(w, -h), Vector2(-w, -h)])
		"para":
			var s := w * 0.44
			return PackedVector2Array([Vector2(-w + s, h), Vector2(w, h), Vector2(w - s, -h), Vector2(-w, -h)])
		"hex":
			return PackedVector2Array([Vector2(w, 0), Vector2(w * 0.5, h), Vector2(-w * 0.5, h), Vector2(-w, 0), Vector2(-w * 0.5, -h), Vector2(w * 0.5, -h)])
		"pent":
			return _fit_box(_regular(5, PI * 0.5), w, h)
		"star":
			return _fit_box(_star(5, 0.42), w, h)
		"doc":
			var pts := PackedVector2Array([Vector2(-w, h), Vector2(w, h)])
			var amp := h * 0.15
			for i in range(0, 17):                   # wavy bottom edge, right to left
				var t := float(i) / 16.0
				pts.append(Vector2(w - 2.0 * w * t, -h + amp + sin(t * TAU) * amp))
			return pts
		"cyl":
			var ry := minf(h * 0.28, w * 0.45)
			var pts2 := PackedVector2Array()
			for i in range(0, 25):                   # back half of the top ellipse, left to right over the top
				var a := PI - PI * float(i) / 24.0
				pts2.append(Vector2(cos(a) * w, h - ry + sin(a) * ry))
			for i in range(0, 25):                   # front half of the bottom ellipse, right to left under the bottom
				var a2 := -PI * float(i) / 24.0
				pts2.append(Vector2(cos(a2) * w, -h + ry + sin(a2) * ry))
			return pts2
		"rarrow":
			var hd := w * 0.42
			var sh := h * 0.5
			return PackedVector2Array([Vector2(-w, sh), Vector2(w - hd, sh), Vector2(w - hd, h), Vector2(w, 0), Vector2(w - hd, -h), Vector2(w - hd, -sh), Vector2(-w, -sh)])
	return PackedVector2Array([Vector2(-w, h), Vector2(w, h), Vector2(w, -h), Vector2(-w, -h)])


## Outline polylines: Array of {pts: PackedVector2Array, closed: bool}. The cylinder has an extra inner line for the top rim.
static func outlines(id: String, size: Vector2) -> Array:
	var out: Array = [{"pts": fill_poly(id, size), "closed": true}]
	if id == "cyl":
		var w := size.x * 0.5
		var h := size.y * 0.5
		var ry := minf(h * 0.28, w * 0.45)
		var rim := PackedVector2Array()
		for i in range(0, 25):                       # front half of the top ellipse (the visible rim)
			var a := PI + PI * float(i) / 24.0
			rim.append(Vector2(cos(a) * w, h - ry + sin(a) * ry))
		out.append({"pts": rim, "closed": false})
	return out


## Connection ports: [{pos: Vector2, n: Vector2}] in the shape's own frame (top, right, bottom, left).
static func ports(id: String, size: Vector2) -> Array:
	var poly := fill_poly(id, size)
	var out: Array = []
	for d in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
		out.append({"pos": _ray_hit(poly, d), "n": d})
	return out


## Port position in the canvas frame.
static func port_world(item: Item, idx: int) -> Dictionary:
	var pl := ports(item.shape, item.size)
	idx = clampi(idx, 0, pl.size() - 1)
	var p: Vector2 = pl[idx].pos
	var n: Vector2 = pl[idx].n
	return {"pos": item.center + Geom2D.rot(p, item.rot), "n": Geom2D.rot(n, item.rot)}


## Nearest port of a shape to a point in the canvas frame: {idx, pos, n, dist}.
static func nearest_port(item: Item, p: Vector2) -> Dictionary:
	var best := {"idx": -1, "dist": INF}
	for i in 4:
		var pw := port_world(item, i)
		var d: float = p.distance_to(pw.pos)
		if d < float(best.dist):
			best = {"idx": i, "pos": pw.pos, "n": pw.n, "dist": d}
	return best


## Outline of a shape item in the canvas frame, as a list of {pts, closed}.
static func world_outlines(item: Item) -> Array:
	var out: Array = []
	if is_line(item.shape):
		out.append({"pts": line_points(item), "closed": false})
		return out
	for o in outlines(item.shape, item.size):
		var pts := PackedVector2Array()
		for p in o.pts:
			pts.append(item.center + Geom2D.rot(p, item.rot))
		out.append({"pts": pts, "closed": o.closed})
	return out


static func world_fill_poly(item: Item) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in fill_poly(item.shape, item.size):
		pts.append(item.center + Geom2D.rot(p, item.rot))
	return pts


## Path of a line-type shape, including the elbow routing.
static func line_points(item: Item) -> PackedVector2Array:
	if item.shape == "elbow":
		return route_elbow(item.a, item.b, item.na, item.nb)
	return PackedVector2Array([item.a, item.b])


## Orthogonal route between two points leaving along the (unit) normals na and nb (Vector2.ZERO = free end).
static func route_elbow(a: Vector2, b: Vector2, na: Vector2, nb: Vector2) -> PackedVector2Array:
	var stub := 0.035
	var ha := absf(na.x) > absf(na.y)
	var hb := absf(nb.x) > absf(nb.y)
	if na == Vector2.ZERO:
		ha = absf(b.x - a.x) >= absf(b.y - a.y)
		na = Vector2(signf(b.x - a.x), 0) if ha else Vector2(0, signf(b.y - a.y))
	if nb == Vector2.ZERO:
		hb = not ha if absf(b.x - a.x) > 0.01 and absf(b.y - a.y) > 0.01 else ha
		nb = Vector2(signf(a.x - b.x), 0) if hb else Vector2(0, signf(a.y - b.y))
	var a2 := a + na * stub
	var b2 := b + nb * stub
	var pts := PackedVector2Array([a, a2])
	if ha and hb:
		var mx := (a2.x + b2.x) * 0.5
		pts.append(Vector2(mx, a2.y))
		pts.append(Vector2(mx, b2.y))
	elif (not ha) and (not hb):
		var my := (a2.y + b2.y) * 0.5
		pts.append(Vector2(a2.x, my))
		pts.append(Vector2(b2.x, my))
	elif ha and not hb:
		pts.append(Vector2(b2.x, a2.y))
	else:
		pts.append(Vector2(a2.x, b2.y))
	pts.append(b2)
	pts.append(b)
	return _simplify_colinear(pts)


## Arrow-head triangle at `tip` pointing along `dir` (unit), for a line of the given width.
static func arrow_head(tip: Vector2, dir: Vector2, width: float) -> PackedVector2Array:
	var len := maxf(0.022, width * 5.0)
	var half := len * 0.45
	var base := tip - dir * len
	var perp := Vector2(-dir.y, dir.x)
	return PackedVector2Array([tip, base + perp * half, base - perp * half])


## Is a point on (or inside, when filled) a shape item? `tol` is the pick tolerance in metres.
static func hit(item: Item, p: Vector2, tol: float) -> bool:
	if is_line(item.shape):
		return Geom2D.dist_to_polyline(p, line_points(item), false) <= tol + item.width * 0.5
	var local := Geom2D.rot(p - item.center, -item.rot)
	if item.fill.a > 0.02 and Geometry2D.is_point_in_polygon(local, fill_poly(item.shape, item.size)):
		return true
	for o in outlines(item.shape, item.size):
		if Geom2D.dist_to_polyline(local, o.pts, o.closed) <= tol + item.width * 0.5:
			return true
	return false


## Area (canvas frame) available for a label inside the shape.
static func label_box(id: String, size: Vector2) -> Vector2:
	match id:
		"ellipse":
			return size * 0.7
		"diamond":
			return size * 0.5
		"triangle":
			return Vector2(size.x * 0.5, size.y * 0.5)
		"star":
			return size * 0.42
		"hex", "pent":
			return size * 0.72
		"para":
			return Vector2(size.x * 0.7, size.y * 0.85)
	return size * 0.88


# ------------------------------------------------------------------------------------------------ internals

## Number of straight pieces for an ellipse with half axes w, h.
static func _curve_segments(w: float, h: float) -> int:
	var perimeter := TAU * sqrt((w * w + h * h) * 0.5)
	return clampi(int(ceil(perimeter / SEGMENT_LENGTH)), 48, 360)


static func _rounded_rect(w: float, h: float, rr: float) -> PackedVector2Array:
	var r := minf(rr, minf(w, h))
	var steps := clampi(int(ceil(r * PI * 0.5 / (SEGMENT_LENGTH * 0.7))), 8, 40)
	var out := PackedVector2Array()
	var corners := [Vector2(w - r, h - r), Vector2(-w + r, h - r), Vector2(-w + r, -h + r), Vector2(w - r, -h + r)]
	var start := [0.0, PI * 0.5, PI, PI * 1.5]
	for k in 4:
		for i in range(0, steps + 1):
			var a: float = start[k] + (PI * 0.5) * float(i) / float(steps)
			out.append(corners[k] + Vector2(cos(a), sin(a)) * r)
	return out


static func _regular(n: int, start_angle: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := start_angle + TAU * float(i) / float(n)
		out.append(Vector2(cos(a), sin(a)))
	return out


static func _star(n: int, inner: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n * 2:
		var a := PI * 0.5 + PI * float(i) / float(n)
		var r := 1.0 if i % 2 == 0 else inner
		out.append(Vector2(cos(a), sin(a)) * r)
	return out


## Scale a point set so its bounding box is exactly [-w, w] x [-h, h].
static func _fit_box(pts: PackedVector2Array, w: float, h: float) -> PackedVector2Array:
	var bb := Geom2D.bbox(pts)
	var out := PackedVector2Array()
	for p in pts:
		out.append(Vector2((p.x - bb.get_center().x) / maxf(bb.size.x, 1e-6) * 2.0 * w, (p.y - bb.get_center().y) / maxf(bb.size.y, 1e-6) * 2.0 * h))
	return out


static func _dedupe(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > 1e-10:
			out.append(p)
	if out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) < 1e-10:
		out.remove_at(out.size() - 1)
	return out


static func _ray_hit(poly: PackedVector2Array, dir: Vector2) -> Vector2:
	var best := INF
	var hit_p := Vector2.ZERO
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var r = Geometry2D.segment_intersects_segment(Vector2.ZERO, dir * 10.0, a, b)
		if r != null:
			var d: float = (r as Vector2).length()
			if d < best:
				best = d
				hit_p = r
	return hit_p


static func _simplify_colinear(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if not out.is_empty() and out[out.size() - 1].distance_squared_to(p) < 1e-9:
			continue
		out.append(p)
	var i := 1
	while i < out.size() - 1:
		var u := (out[i] - out[i - 1]).normalized()
		var v := (out[i + 1] - out[i]).normalized()
		if absf(u.cross(v)) < 1e-4 and u.dot(v) > 0.0:
			out.remove_at(i)
		else:
			i += 1
	return out
