class_name PdfPath
extends RefCounted
## An outline made of moves, lines, quadratic and cubic curves: the shape of a glyph or of a path in a page. Kept as it was drawn (curves
## stay curves), and cut into straight pieces fine enough for the size it is shown at only when it is needed (flatten).

const M := 0
const L := 1
const Q := 2
const C := 3
const Z := 4

var ops := PackedByteArray()
var pts := PackedVector2Array()
var cur := Vector2.ZERO
var start := Vector2.ZERO
var open_sub := false


func is_empty() -> bool:
	return ops.is_empty()


func move_to(p: Vector2) -> void:
	if not ops.is_empty() and ops[ops.size() - 1] == M:           # a move after a move replaces it
		pts[pts.size() - 1] = p
	else:
		ops.append(M)
		pts.append(p)
	cur = p
	start = p
	open_sub = true


func line_to(p: Vector2) -> void:
	if not open_sub:
		move_to(cur)
	ops.append(L)
	pts.append(p)
	cur = p


func quad_to(c: Vector2, p: Vector2) -> void:
	if not open_sub:
		move_to(cur)
	ops.append(Q)
	pts.append(c)
	pts.append(p)
	cur = p


func cubic_to(c1: Vector2, c2: Vector2, p: Vector2) -> void:
	if not open_sub:
		move_to(cur)
	ops.append(C)
	pts.append(c1)
	pts.append(c2)
	pts.append(p)
	cur = p


func close() -> void:
	if open_sub:
		ops.append(Z)
		cur = start
		open_sub = false


func rect(x: float, y: float, w: float, h: float) -> void:
	move_to(Vector2(x, y))
	line_to(Vector2(x + w, y))
	line_to(Vector2(x + w, y + h))
	line_to(Vector2(x, y + h))
	close()


func copy() -> PdfPath:
	var c := PdfPath.new()
	c.ops = ops.duplicate()
	c.pts = pts.duplicate()
	c.cur = cur
	c.start = start
	c.open_sub = open_sub
	return c


func append_path(other: PdfPath, m: Transform2D = Transform2D.IDENTITY) -> void:
	ops.append_array(other.ops)
	pts.append_array(m * other.pts)
	cur = m * other.cur
	start = m * other.start
	open_sub = other.open_sub


## All of it transformed.
func transformed(m: Transform2D) -> PdfPath:
	var c := PdfPath.new()
	c.ops = ops
	c.pts = m * pts
	c.cur = m * cur
	c.start = m * start
	c.open_sub = open_sub
	return c


func bounds() -> Rect2:
	return PdfGeom.bounds(pts)


## If the path is one axis-aligned rectangle (the commonest thing in a PDF), that rectangle, else an empty Rect2 with size zero.
func as_rect() -> Rect2:
	var n := ops.size()
	if n < 4 or n > 6 or ops[0] != M:
		return Rect2()
	var i := 1
	var count := 1
	while i < n and ops[i] == L:
		i += 1
		count += 1
	if i < n and ops[i] == Z:
		i += 1
	if i != n or (count != 4 and count != 5):
		return Rect2()
	if count == 5 and pts[4].distance_squared_to(pts[0]) > 1e-12:
		return Rect2()
	var a := pts[0]
	var b := pts[1]
	var c := pts[2]
	var d := pts[3]
	var horizontal_first := is_equal_approx(a.y, b.y) and is_equal_approx(b.x, c.x) and is_equal_approx(c.y, d.y) and is_equal_approx(d.x, a.x)
	var vertical_first := is_equal_approx(a.x, b.x) and is_equal_approx(b.y, c.y) and is_equal_approx(c.x, d.x) and is_equal_approx(d.y, a.y)
	if not (horizontal_first or vertical_first):
		return Rect2()
	var lo := a.min(c)
	var hi := a.max(c)
	return Rect2(lo, hi - lo)


## Cuts the path (after `m`) into polylines no further than `tol` from the curves. Returns [contours: Array of PackedVector2Array,
## closed: PackedByteArray] (one flag per contour).
func flatten(m: Transform2D, tol: float) -> Array:
	var contours: Array = []
	var closed := PackedByteArray()
	var cur_poly := PackedVector2Array()
	var pi := 0
	var last := Vector2.ZERO
	for op in ops:
		match op:
			M:
				if cur_poly.size() > 1:
					contours.append(cur_poly)
					closed.append(0)
				cur_poly = PackedVector2Array()
				last = m * pts[pi]
				pi += 1
				cur_poly.append(last)
			L:
				last = m * pts[pi]
				pi += 1
				cur_poly.append(last)
			Q:
				var c := m * pts[pi]
				var p := m * pts[pi + 1]
				pi += 2
				PdfGeom.flatten_quad(last, c, p, tol, cur_poly)
				last = p
			C:
				var c1 := m * pts[pi]
				var c2 := m * pts[pi + 1]
				var p3 := m * pts[pi + 2]
				pi += 3
				PdfGeom.flatten_cubic(last, c1, c2, p3, tol, cur_poly)
				last = p3
			Z:
				if cur_poly.size() > 1:
					contours.append(cur_poly)
					closed.append(1)
				if cur_poly.size() > 0:
					var first := cur_poly[0]
					cur_poly = PackedVector2Array()
					cur_poly.append(first)                 # a new subpath may continue from the start point
					last = first                           # (a lone start point is dropped at the next move or at the end)
	if cur_poly.size() > 1:
		contours.append(cur_poly)
		closed.append(0)
	return [contours, closed]
