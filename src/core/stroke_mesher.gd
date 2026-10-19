class_name StrokeMesher
extends RefCounted
## Builds mesh data for ink: flat ribbons for canvas strokes and shape outlines (anti-aliased by the shader through UV.y),
## round tubes for 3D strokes, and filled polygons. Stroke points are packed as x, y, z, pressure.

const CAP_SEGMENTS := 6
const MITER_LIMIT := 2.4
const MIN_STEP := 0.0003


# ------------------------------------------------------------------------------------------------ point processing

## Drop points closer together than min_dist (keeps the first and last). Input and output are x, y, z, pressure.
static func decimate(pts: PackedFloat32Array, min_dist: float) -> PackedFloat32Array:
	var n := pts.size() / 4
	var out := PackedFloat32Array()
	if n == 0:
		return out
	out.append_array(PackedFloat32Array([pts[0], pts[1], pts[2], pts[3]]))
	var last := Vector3(pts[0], pts[1], pts[2])
	for i in range(1, n):
		var p := Vector3(pts[i * 4], pts[i * 4 + 1], pts[i * 4 + 2])
		if i == n - 1 or p.distance_to(last) >= min_dist:
			out.append_array(PackedFloat32Array([p.x, p.y, p.z, pts[i * 4 + 3]]))
			last = p
	return out


## One round of corner cutting; end points stay. Pressure is interpolated along.
static func smooth(pts: PackedFloat32Array, passes: int = 1) -> PackedFloat32Array:
	var cur := pts
	for _k in passes:
		var n := cur.size() / 4
		if n < 3:
			return cur
		var out := PackedFloat32Array()
		out.append_array(PackedFloat32Array([cur[0], cur[1], cur[2], cur[3]]))
		for i in range(0, n - 1):
			var a := i * 4
			var b := (i + 1) * 4
			for t in [0.25, 0.75]:
				out.append(lerpf(cur[a], cur[b], t))
				out.append(lerpf(cur[a + 1], cur[b + 1], t))
				out.append(lerpf(cur[a + 2], cur[b + 2], t))
				out.append(lerpf(cur[a + 3], cur[b + 3], t))
		var e := (n - 1) * 4
		out.append_array(PackedFloat32Array([cur[e], cur[e + 1], cur[e + 2], cur[e + 3]]))
		cur = out
	return cur


# ------------------------------------------------------------------------------------------------ ribbon (canvas)

## Flat ribbon along a polyline in the plane with normal `up` (default +Z). `widths` is the full width at each point.
## Returns arrays ready for ArrayMesh.add_surface_from_arrays (empty when there is nothing to draw).
static func ribbon_arrays(pts: PackedVector3Array, widths: PackedFloat32Array, col: Color, closed: bool = false, round_caps: bool = true, nib: float = -1.0, up: Vector3 = Vector3.BACK) -> Array:
	var p := PackedVector3Array()
	var w := PackedFloat32Array()
	for i in pts.size():
		if p.is_empty() or p[p.size() - 1].distance_to(pts[i]) > MIN_STEP:
			p.append(pts[i])
			w.append(widths[mini(i, widths.size() - 1)])
	var n := p.size()
	if n == 0:
		return []
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	if n == 1:
		_disc(verts, uvs, cols, idx, p[0], w[0] * 0.5, col, up)
		return _pack(verts, uvs, cols, idx)
	var dirs: Array = []
	for i in n - 1:
		dirs.append((p[i + 1] - p[i]).normalized())
	if closed:
		dirs.append((p[0] - p[n - 1]).normalized())
	var u := 0.0
	for i in n:
		var dn: Vector3
		var dp: Vector3
		if closed:
			dp = dirs[(i + n - 1) % n]
			dn = dirs[i]
		else:
			dp = dirs[maxi(i - 1, 0)]
			dn = dirs[mini(i, n - 2)]
		var lp := up.cross(dp)
		var ln := up.cross(dn)
		var bis := lp + ln
		var miter := 1.0
		if bis.length_squared() < 1e-8:
			bis = ln
		else:
			bis = bis.normalized()
			miter = minf(1.0 / maxf(bis.dot(ln), 0.05), MITER_LIMIT)
		var wi := w[i]
		if nib >= 0.0:
			var t := (dp + dn).normalized()
			var nd := Vector3(cos(nib), sin(nib), 0.0)
			wi *= maxf(absf(t.cross(nd).dot(up)), 0.16)
		if i > 0:
			u += p[i].distance_to(p[i - 1])
		var off := bis * (wi * 0.5 * miter)
		verts.append(p[i] + off)
		uvs.append(Vector2(u, 1.0))
		cols.append(col)
		verts.append(p[i] - off)
		uvs.append(Vector2(u, -1.0))
		cols.append(col)
	var segs := n if closed else n - 1
	for i in segs:
		var a := i * 2
		var b := ((i + 1) % n) * 2
		idx.append_array(PackedInt32Array([a, a + 1, b, a + 1, b + 1, b]))
	if round_caps and not closed:
		var r0 := w[0] * 0.5
		var r1 := w[n - 1] * 0.5
		_cap(verts, uvs, cols, idx, p[0], up.cross(dirs[0]), -dirs[0], r0, col, up, true)
		_cap(verts, uvs, cols, idx, p[n - 1], up.cross(dirs[n - 2]), dirs[n - 2], r1, col, up, false)
	return _pack(verts, uvs, cols, idx)


static func _cap(verts: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, c: Vector3, ln: Vector3, fwd: Vector3, r: float, col: Color, up: Vector3, start: bool) -> void:
	var base := verts.size()
	verts.append(c)
	uvs.append(Vector2(0.0, 0.0))
	cols.append(col)
	for k in range(0, CAP_SEGMENTS + 1):
		var th := PI * float(k) / float(CAP_SEGMENTS)
		var dir := ln * cos(th) + fwd * sin(th) if not start else ln * cos(th) + fwd * sin(th)
		verts.append(c + dir * r)
		uvs.append(Vector2(0.0, 1.0))
		cols.append(col)
	for k in range(0, CAP_SEGMENTS):
		if start:
			idx.append_array(PackedInt32Array([base, base + 2 + k, base + 1 + k]))
		else:
			idx.append_array(PackedInt32Array([base, base + 1 + k, base + 2 + k]))


static func _disc(verts: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, c: Vector3, r: float, col: Color, up: Vector3) -> void:
	var base := verts.size()
	var ax := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.UP).normalized()
	var ay := up.cross(ax)
	verts.append(c)
	uvs.append(Vector2.ZERO)
	cols.append(col)
	var n := CAP_SEGMENTS * 2
	for k in n:
		var th := TAU * float(k) / n
		verts.append(c + (ax * cos(th) + ay * sin(th)) * r)
		uvs.append(Vector2(0.0, 1.0))
		cols.append(col)
	for k in n:
		idx.append_array(PackedInt32Array([base, base + 1 + k, base + 1 + (k + 1) % n]))


static func _pack(verts: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


# ------------------------------------------------------------------------------------------------ tube (3D strokes)

static func tube_arrays(pts: PackedVector3Array, widths: PackedFloat32Array, col: Color, sides: int = 6) -> Array:
	var p := PackedVector3Array()
	var w := PackedFloat32Array()
	for i in pts.size():
		if p.is_empty() or p[p.size() - 1].distance_to(pts[i]) > MIN_STEP:
			p.append(pts[i])
			w.append(widths[mini(i, widths.size() - 1)])
	var n := p.size()
	if n == 0:
		return []
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	if n == 1:
		p.append(p[0] + Vector3(0.0003, 0, 0))
		w.append(w[0])
		n = 2
	var nrm := Vector3.ZERO
	var u := 0.0
	for i in n:
		var t: Vector3
		if i == 0:
			t = (p[1] - p[0]).normalized()
		elif i == n - 1:
			t = (p[n - 1] - p[n - 2]).normalized()
		else:
			t = (p[i + 1] - p[i - 1]).normalized()
		if i == 0:
			nrm = t.cross(Vector3.UP if absf(t.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT).normalized()
		else:
			nrm = (nrm - t * nrm.dot(t))
			if nrm.length_squared() < 1e-9:
				nrm = t.cross(Vector3.UP).normalized()
			nrm = nrm.normalized()
		var bn := t.cross(nrm)
		if i > 0:
			u += p[i].distance_to(p[i - 1])
		var r := w[i] * 0.5
		for k in sides:
			var th := TAU * float(k) / sides
			var dir := nrm * cos(th) + bn * sin(th)
			verts.append(p[i] + dir * r)
			norms.append(dir)
			uvs.append(Vector2(u, float(k) / sides * 2.0 - 1.0))
			cols.append(col)
	for i in n - 1:
		for k in sides:
			var a := i * sides + k
			var b := i * sides + (k + 1) % sides
			var c2 := (i + 1) * sides + k
			var d := (i + 1) * sides + (k + 1) % sides
			idx.append_array(PackedInt32Array([a, c2, b, b, c2, d]))
	# domed end caps
	for end in 2:
		var i := 0 if end == 0 else n - 1
		var t2 := (p[0] - p[1]).normalized() if end == 0 else (p[n - 1] - p[n - 2]).normalized()
		var tip := verts.size()
		verts.append(p[i] + t2 * w[i] * 0.5)
		norms.append(t2)
		uvs.append(Vector2(u if end == 1 else 0.0, 0.0))
		cols.append(col)
		for k in sides:
			var a2 := i * sides + k
			var b2 := i * sides + (k + 1) % sides
			if end == 0:
				idx.append_array(PackedInt32Array([tip, a2, b2]))
			else:
				idx.append_array(PackedInt32Array([tip, b2, a2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


# ------------------------------------------------------------------------------------------------ fills

## Triangulated polygon in the xy plane (UV zero, so the ink shader paints it solid).
static func fill_arrays(poly: PackedVector2Array, col: Color, z: float = 0.0) -> Array:
	if poly.size() < 3:
		return []
	var tri := Geometry2D.triangulate_polygon(poly)
	if tri.is_empty():
		tri = Geometry2D.triangulate_polygon(_reversed(poly))
		if tri.is_empty():
			return []
		poly = _reversed(poly)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for q in poly:
		verts.append(Vector3(q.x, q.y, z))
		uvs.append(Vector2.ZERO)
		cols.append(col)
	return _pack(verts, uvs, cols, tri)


static func _reversed(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(poly.size() - 1, -1, -1):
		out.append(poly[i])
	return out


static func to_mesh(arrays: Array, mesh: ArrayMesh = null) -> ArrayMesh:
	var m := mesh if mesh != null else ArrayMesh.new()
	if not arrays.is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
