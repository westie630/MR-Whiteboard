class_name PdfShading
extends RefCounted
## Smooth colour fills (PDF shadings of type 1, function-based, 2, axial, 3, radial, and 4 to 7, meshes: see PdfMesh) as coloured triangles or pictures. The region to fill comes in as triangles; an
## axial gradient is cut into narrow bands across the axis (so a band is one linear ramp, which a triangle's corner colours reproduce
## exactly), a radial one is cut into smaller and smaller triangles until the colour changes little across each.

const BANDS := 32
const MAX_DEPTH := 6
const TEXELS := 24000                       # a function-based shading is sampled this many times

var _space: PdfColor
var _fn: PdfFunction
var _type := 2
var _coords := PackedFloat64Array()
var _t0 := 0.0
var _t1 := 1.0
var _ext0 := false
var _ext1 := false
var _inv := Transform2D.IDENTITY
var _cache: Dictionary = {}
var _domain := PackedFloat64Array([0.0, 1.0, 0.0, 1.0])     # type 1: the area of its function
var _fwd := Transform2D.IDENTITY


## The coloured triangles that fill `region` (a soup, page space) with the shading `sh`, whose own space is mapped to the page by `m`.
## Returns [soup, colours], or ["tex", soup, uvs, colour picture, alpha picture] (a function-based or mesh shading), or [] when this kind of shading is not drawn.
## A mesh shading (types 4 to 7) is a stream: `stream` is it, and `texels` is about how many texels its picture may have.
static func mesh(doc: PdfDoc, sh: Dictionary, region: PackedVector2Array, m: Transform2D, stream: PdfStream = null, texels: int = 160000) -> Array:
	var s := PdfShading.new()
	if not s._setup(doc, sh, m):
		return []
	if s._type >= 4:
		return PdfMesh.make(doc, sh, stream, s._space, s._fn, m, region, texels)
	if s._type == 1:
		return s._function_based(region)
	if s._type == 2:
		return s._axial(region)
	return s._radial(region)


func _setup(doc: PdfDoc, sh: Dictionary, m: Transform2D) -> bool:
	_type = doc.d_int(sh.get("ShadingType"), 0)
	if _type < 1 or _type > 7:
		return false
	_space = PdfColor.make(doc, sh.get("ColorSpace"))
	var fv: Variant = sh.get("Function")
	_fn = PdfFunction.make(doc, fv) if fv != null else null
	if _type >= 4:
		return fv == null or (_fn != null and _fn.n_in == 1)           # a mesh may carry its colours directly
	if _fn == null or _fn.n_in != (2 if _type == 1 else 1):
		return false                                        # a gradient's function takes t (a function-based shading's takes x and y), nothing else
	if _type == 1:
		_domain = doc.d_nums(sh.get("Domain"), PackedFloat64Array([0.0, 1.0, 0.0, 1.0]))
		var fm := doc.d_nums(sh.get("Matrix"))
		var own := Transform2D.IDENTITY
		if fm.size() >= 6:
			own = Transform2D(Vector2(fm[0], fm[1]), Vector2(fm[2], fm[3]), Vector2(fm[4], fm[5]))
		_fwd = m * own                                  # the function's own space -> the page
		_inv = _fwd.affine_inverse()
		return _domain.size() >= 4
	_coords = doc.d_nums(sh.get("Coords"))
	if _coords.size() < (4 if _type == 2 else 6):
		return false
	var dom := doc.d_nums(sh.get("Domain"), PackedFloat64Array([0.0, 1.0]))
	_t0 = dom[0]
	_t1 = dom[1]
	var ext := doc.d_array(sh.get("Extend"))
	_ext0 = ext.size() > 0 and doc.d_bool(ext[0])
	_ext1 = ext.size() > 1 and doc.d_bool(ext[1])
	_inv = m.affine_inverse()
	return true


func _color_at(t01: float) -> Color:
	var key := int(clampf(t01, 0.0, 1.0) * 4096.0)
	if _cache.has(key):
		return _cache[key]
	var t := _t0 + clampf(t01, 0.0, 1.0) * (_t1 - _t0)
	var c := _space.to_rgb(_fn.evaluate([t]))
	_cache[key] = c
	return c


# ------------------------------------------------------------------------------------------------ function-based (type 1)

## A function of two variables can change as sharply as it likes (stripes, checks), which corners with colours cannot show: it is sampled into a small
## picture and the region is drawn with that. Returns ["tex", region, uvs, colour picture, alpha picture].
func _function_based(region: PackedVector2Array) -> Array:
	var box := PackedVector2Array([_fwd * Vector2(_domain[0], _domain[2]), _fwd * Vector2(_domain[1], _domain[2]), _fwd * Vector2(_domain[1], _domain[3]), _fwd * Vector2(_domain[0], _domain[3])])
	if PdfGeom.area(box) < 0.0:
		box.reverse()
	region = PdfGeom.clip_convex(region, box)                   # only the function's own rectangle is painted
	if region.is_empty():
		return []
	var bb := PdfGeom.bounds(region)
	var k := sqrt(float(TEXELS) / maxf(bb.size.x * bb.size.y, 1e-6))
	var w := clampi(ceili(bb.size.x * k), 4, 512)
	var h := clampi(ceili(bb.size.y * k), 4, 512)
	var rgb := PackedByteArray()
	rgb.resize(w * h * 3)
	var alpha := PackedByteArray()
	alpha.resize(w * h)
	for j in h:
		for i in w:
			var p := Vector2(bb.position.x + (i + 0.5) / w * bb.size.x, bb.position.y + (1.0 - (j + 0.5) / h) * bb.size.y)
			var q := _inv * p
			var at := j * w + i
			if q.x < _domain[0] or q.x > _domain[1] or q.y < _domain[2] or q.y > _domain[3]:
				continue
			var c := _space.to_rgb(_fn.evaluate([q.x, q.y]))
			rgb[at * 3] = int(c.r * 255.0 + 0.5)
			rgb[at * 3 + 1] = int(c.g * 255.0 + 0.5)
			rgb[at * 3 + 2] = int(c.b * 255.0 + 0.5)
			alpha[at] = 255
	var uvs := PackedVector2Array()
	for v in region:
		uvs.append(Vector2((v.x - bb.position.x) / bb.size.x, 1.0 - (v.y - bb.position.y) / bb.size.y))
	return ["tex", region, uvs, Image.create_from_data(w, h, false, Image.FORMAT_RGB8, rgb), Image.create_from_data(w, h, false, Image.FORMAT_L8, alpha)]


# ------------------------------------------------------------------------------------------------ axial

func _axial(region: PackedVector2Array) -> Array:
	var p0 := Vector2(_coords[0], _coords[1])
	var d := Vector2(_coords[2], _coords[3]) - p0
	var len2 := d.length_squared()
	if len2 < 1e-12:
		return []
	var out_p := PackedVector2Array()
	var out_c := PackedColorArray()
	var i := 0
	while i + 2 < region.size():
		var tri: Array = []
		for k in 3:
			var pg := region[i + k]
			var tl := (_inv * pg - p0).dot(d) / len2
			tri.append([pg, tl])
		i += 3
		var tmin := minf(minf(tri[0][1], tri[1][1]), tri[2][1])
		var tmax := maxf(maxf(tri[0][1], tri[1][1]), tri[2][1])
		# before the start
		if tmin < 0.0 and _ext0:
			_band(out_p, out_c, tri, -INF, 0.0)
		var k0 := maxi(int(floor(maxf(tmin, 0.0) * BANDS)), 0)
		var k1 := mini(int(floor(minf(tmax, 1.0) * BANDS)), BANDS - 1)
		for k in range(k0, k1 + 1):
			_band(out_p, out_c, tri, float(k) / BANDS, float(k + 1) / BANDS)
		if tmax > 1.0 and _ext1:
			_band(out_p, out_c, tri, 1.0, INF)
	return [out_p, out_c]


## The part of a triangle with t between lo and hi, as coloured triangles (the colour at each corner is the gradient's colour at its t).
func _band(out_p: PackedVector2Array, out_c: PackedColorArray, tri: Array, lo: float, hi: float) -> void:
	var poly: Array = tri
	poly = _cut_t(poly, lo, true)
	poly = _cut_t(poly, hi, false)
	if poly.size() < 3:
		return
	for k in range(1, poly.size() - 1):
		for q in [0, k, k + 1]:
			var v: Array = poly[q]
			out_p.append(v[0])
			out_c.append(_color_at(clampf(v[1], 0.0, 1.0)))


static func _cut_t(poly: Array, at: float, keep_above: bool) -> Array:
	if is_inf(at):
		return poly
	var out: Array = []
	var n := poly.size()
	for i in n:
		var p: Array = poly[i]
		var q: Array = poly[(i + 1) % n]
		var pv: float = p[1]
		var qv: float = q[1]
		var p_in := pv >= at if keep_above else pv <= at
		var q_in := qv >= at if keep_above else qv <= at
		if p_in:
			out.append(p)
		if p_in != q_in:
			var t := (at - pv) / (qv - pv)
			out.append([(p[0] as Vector2).lerp(q[0], t), at])
	return out


# ------------------------------------------------------------------------------------------------ radial

## The gradient parameter at a point of a radial shading: the largest s whose circle passes through the point, or NAN outside it.
func _radial_t(pl: Vector2) -> float:
	var c0 := Vector2(_coords[0], _coords[1])
	var r0 := _coords[2]
	var c1 := Vector2(_coords[3], _coords[4])
	var r1 := _coords[5]
	var dc := c1 - c0
	var dr := r1 - r0
	var pd := pl - c0
	var a := dc.dot(dc) - dr * dr
	var b := pd.dot(dc) + r0 * dr
	var c := pd.dot(pd) - r0 * r0
	var best := NAN
	if absf(a) < 1e-9:
		if absf(b) < 1e-12:
			return NAN
		var s := c / (2.0 * b)
		if r0 + s * dr >= 0.0 and _in_range(s):
			best = s
		return best
	var disc := b * b - a * c
	if disc < 0.0:
		return NAN
	var sq := sqrt(disc)
	var s1 := (b + sq) / a
	var s2 := (b - sq) / a
	for s in [maxf(s1, s2), minf(s1, s2)]:
		if r0 + s * dr >= 0.0 and _in_range(s):
			return s
	return NAN


func _in_range(s: float) -> bool:
	if s < 0.0:
		return _ext0
	if s > 1.0:
		return _ext1
	return true


func _radial(region: PackedVector2Array) -> Array:
	var out_p := PackedVector2Array()
	var out_c := PackedColorArray()
	if not _ext0 and not _ext1:
		# only what the two circles sweep is painted: the region is cut to their hull, so the edge is a clean curve (not a blend with "nothing")
		var fwd := _inv.affine_inverse()
		var pts := PackedVector2Array()
		for k in 96:
			var a := TAU * float(k) / 96.0
			var dir := Vector2(cos(a), sin(a))
			pts.append(fwd * (Vector2(_coords[0], _coords[1]) + dir * _coords[2]))
			pts.append(fwd * (Vector2(_coords[3], _coords[4]) + dir * _coords[5]))
		var hull := Geometry2D.convex_hull(pts)
		if hull.size() > 3:
			hull.remove_at(hull.size() - 1)              # the hull comes back closed
			if PdfGeom.area(hull) < 0.0:
				hull.reverse()
			region = PdfGeom.clip_convex(region, hull)
	var i := 0
	while i + 2 < region.size():
		_subdivide(region[i], region[i + 1], region[i + 2], 0, out_p, out_c)
		i += 3
	return [out_p, out_c]


func _vertex_color(p: Vector2) -> Color:
	var s := _radial_t(_inv * p)
	if is_nan(s):
		return Color(0, 0, 0, 0)
	return _color_at(clampf(s, 0.0, 1.0))


func _subdivide(a: Vector2, b: Vector2, c: Vector2, depth: int, out_p: PackedVector2Array, out_c: PackedColorArray) -> void:
	var ca := _vertex_color(a)
	var cb := _vertex_color(b)
	var cc := _vertex_color(c)
	var spread := maxf(maxf(_diff(ca, cb), _diff(cb, cc)), _diff(ca, cc))
	var edge := maxf(maxf(a.distance_to(b), b.distance_to(c)), c.distance_to(a))
	if depth >= MAX_DEPTH or edge < 0.6 or (spread < 0.012 and ca.a == cb.a and cb.a == cc.a and (ca.a > 0.0 or depth >= 3)):
		if ca.a <= 0.0 and cb.a <= 0.0 and cc.a <= 0.0:
			return
		out_p.append(a)
		out_p.append(b)
		out_p.append(c)
		out_c.append(ca)
		out_c.append(cb)
		out_c.append(cc)
		return
	var ab := (a + b) * 0.5
	var bc := (b + c) * 0.5
	var ca2 := (c + a) * 0.5
	_subdivide(a, ab, ca2, depth + 1, out_p, out_c)
	_subdivide(ab, b, bc, depth + 1, out_p, out_c)
	_subdivide(ca2, bc, c, depth + 1, out_p, out_c)
	_subdivide(ab, bc, ca2, depth + 1, out_p, out_c)


static func _diff(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a)))
