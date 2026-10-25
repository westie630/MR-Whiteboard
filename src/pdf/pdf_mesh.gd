class_name PdfMesh
extends RefCounted
## Mesh shadings (types 4 to 7): triangles with a colour at each corner (free-form and lattice) and Coons / tensor-product patches, whose four sides
## are Bezier curves. The mesh is read, cut into small triangles with smoothly changing colours and drawn into a picture (a little software
## rasteriser: a gradient mesh has no hard edges inside, so a few hundred thousand texels show it as well as any resolution), which then fills the
## region the way a picture does. Returns what PdfShading.mesh returns for a function-based shading: ["tex", region, uvs, colour picture, alpha picture].

var _doc: PdfDoc
var _space: PdfColor
var _fn: PdfFunction
var _fwd := Transform2D.IDENTITY
var _type := 4
var _cbits := 8
var _kbits := 8
var _fbits := 8
var _ncomp := 3
var _dec := PackedFloat64Array()
var _rd := _Bits.new()
var _tp := PackedVector2Array()                # the triangles: corners (page space) and colours
var _tc := PackedColorArray()


## Reads bits most significant first.
class _Bits:
	var data := PackedByteArray()
	var bit := 0
	var over := false

	func has_data() -> bool:
		return bit < data.size() * 8

	func read(n: int) -> int:
		var v := 0
		var need := n
		while need > 0:
			var at := bit >> 3
			if at >= data.size():
				over = true
				return v << need
			var off := bit & 7
			var take := mini(8 - off, need)
			v = (v << take) | ((data[at] >> (8 - off - take)) & ((1 << take) - 1))
			bit += take
			need -= take
		return v

	func align() -> void:
		bit = (bit + 7) & ~7


## `sh` is the shading's dictionary, `st` its stream, `fn` its function (null when the colours are given directly), `m` maps its space to the page and
## `texels` is about how many texels the picture may have.
static func make(doc: PdfDoc, sh: Dictionary, st: PdfStream, space: PdfColor, fn: PdfFunction, m: Transform2D, region: PackedVector2Array, texels: int) -> Array:
	if st == null or region.is_empty():
		return []
	var me := PdfMesh.new()
	me._doc = doc
	me._space = space
	me._fn = fn
	me._fwd = m
	me._type = doc.d_int(sh.get("ShadingType"), 4)
	me._cbits = doc.d_int(sh.get("BitsPerCoordinate"), 0)
	me._kbits = doc.d_int(sh.get("BitsPerComponent"), 0)
	me._fbits = doc.d_int(sh.get("BitsPerFlag"), 0)
	me._ncomp = 1 if fn != null else space.n
	me._dec = doc.d_nums(sh.get("Decode"))
	if not me._cbits in [1, 2, 4, 8, 12, 16, 24, 32] or not me._kbits in [1, 2, 4, 8, 12, 16] or me._dec.size() < 4 + 2 * me._ncomp:
		return []
	if me._type != 5 and not me._fbits in [2, 4, 8]:
		return []
	me._rd.data = st.decode()
	if me._rd.data.is_empty():
		return []
	return me._run(doc.d_int(sh.get("VerticesPerRow"), 0), region, texels)


func _run(per_row: int, region: PackedVector2Array, texels: int) -> Array:
	var patches: Array = []                                   # [[16 points], [4 colours (component lists)]]
	match _type:
		4:
			_read_free_form()
		5:
			if per_row < 2:
				return []
			_read_lattice(per_row)
		_:
			patches = _read_patches()
	var bounds := Rect2()
	var first := true
	for p in _tp:
		bounds = Rect2(p, Vector2.ZERO) if first else bounds.expand(p)
		first = false
	for pa in patches:
		for p in (pa[0] as Array):
			bounds = Rect2(p, Vector2.ZERO) if first else bounds.expand(p)
			first = false
	if first:
		return []
	var area := bounds.intersection(PdfGeom.bounds(region))
	if area.size.x <= 1e-6 or area.size.y <= 1e-6:
		return []
	var k := sqrt(float(texels) / (area.size.x * area.size.y))
	var w := clampi(ceili(area.size.x * k), 4, 1024)
	var h := clampi(ceili(area.size.y * k), 4, 1024)
	for pa in patches:
		_tessellate(pa[0], pa[1], Vector2(w / area.size.x, h / area.size.y))
	if _tp.is_empty():
		return []
	var cut := PdfGeom.clip_rect(region, area)
	if cut.is_empty():
		return []
	var rgb := PackedByteArray()
	rgb.resize(w * h * 3)
	var alpha := PackedByteArray()
	alpha.resize(w * h)
	var i := 0
	while i + 2 < _tp.size():
		_gouraud(rgb, alpha, w, h, area, _tp[i], _tp[i + 1], _tp[i + 2], _tc[i], _tc[i + 1], _tc[i + 2])
		i += 3
	_bleed(rgb, alpha, w, h)
	var uvs := PackedVector2Array()
	for v in cut:
		uvs.append(Vector2((v.x - area.position.x) / area.size.x, 1.0 - (v.y - area.position.y) / area.size.y))
	return ["tex", cut, uvs, Image.create_from_data(w, h, false, Image.FORMAT_RGB8, rgb), Image.create_from_data(w, h, false, Image.FORMAT_L8, alpha)]


# ------------------------------------------------------------------------------------------------ reading

func _point() -> Vector2:
	var xi := _rd.read(_cbits)
	var yi := _rd.read(_cbits)
	var sc := 1.0 / float((1 << _cbits) - 1)
	return _fwd * Vector2(_dec[0] + xi * sc * (_dec[1] - _dec[0]), _dec[2] + yi * sc * (_dec[3] - _dec[2]))


func _comps() -> Array:
	var out: Array = []
	var sc := 1.0 / float((1 << _kbits) - 1)
	for i in _ncomp:
		var v := _rd.read(_kbits)
		out.append(_dec[4 + 2 * i] + v * sc * (_dec[5 + 2 * i] - _dec[4 + 2 * i]))
	return out


func _color(comps: Array) -> Color:
	if _fn != null:
		return _space.to_rgb(_fn.evaluate([comps[0]]))
	return _space.to_rgb(comps)


func _read_free_form() -> void:
	var pts: Array = []
	var cols: Array = []
	var ps: Array = []                                        # corners of the triangles, as indices into pts / cols
	var left := 0
	while _rd.has_data():
		var f := _rd.read(_fbits)
		var p := _point()
		var c := _color(_comps())
		if _rd.over:
			break
		_rd.align()
		if left == 0:
			if f == 1 and ps.size() >= 3:
				ps.append(ps[ps.size() - 2])
				ps.append(ps[ps.size() - 2])                  # (the one just added moved the end: this is the old last)
				left = 1
			elif f == 2 and ps.size() >= 3:
				ps.append(ps[ps.size() - 3])
				ps.append(ps[ps.size() - 2])
				left = 1
			else:
				left = 3
		ps.append(pts.size())
		pts.append(p)
		cols.append(c)
		left -= 1
	var i := 0
	while i + 2 < ps.size():
		for j in 3:
			_tp.append(pts[ps[i + j]])
			_tc.append(cols[ps[i + j]])
		i += 3


func _read_lattice(per_row: int) -> void:
	var pts: Array = []
	var cols: Array = []
	while _rd.has_data():
		var p := _point()
		var c := _color(_comps())
		if _rd.over:
			break
		_rd.align()
		pts.append(p)
		cols.append(c)
	var rows := pts.size() / per_row
	for r in rows - 1:
		for c in per_row - 1:
			var a := r * per_row + c
			var b := a + 1
			var d := a + per_row
			var e := d + 1
			for q in [a, b, d, b, e, d]:
				_tp.append(pts[q])
				_tc.append(cols[q])


## The patches, as [the 16 control points (a 4 x 4 grid, row i column j at i * 4 + j), the colours of the four corners (component lists)].
func _read_patches() -> Array:
	var out: Array = []
	var prev_pts: Array = []                                  # as stored in the stream: 12 (or 16) points
	var prev_cols: Array = []
	var total := 12 if _type == 6 else 16
	while _rd.has_data():
		var f := _rd.read(_fbits)
		if f > 3:
			break
		var pts: Array = []
		var cols: Array = []
		if f != 0:
			if prev_pts.is_empty():
				break
			var from: int = [3, 6, 9][f - 1]                    # the edge of the previous patch that this one shares
			for i in 4:
				pts.append(prev_pts[(from + i) % 12])
			cols = [prev_cols[f % 4], prev_cols[(f + 1) % 4]]
		for i in total - pts.size():
			pts.append(_point())
		for i in 4 - cols.size():
			cols.append(_comps())
		if _rd.over:
			break
		_rd.align()
		prev_pts = pts
		prev_cols = cols
		out.append([_grid(pts), cols])
	return out


## Stream order of the boundary: p00 p01 p02 p03 p13 p23 p33 p32 p31 p30 p20 p10 (then, in a tensor patch, p11 p12 p22 p21).
func _grid(s: Array) -> Array:
	var g: Array = []
	g.resize(16)
	g[0] = s[0]
	g[1] = s[1]
	g[2] = s[2]
	g[3] = s[3]
	g[7] = s[4]
	g[11] = s[5]
	g[15] = s[6]
	g[14] = s[7]
	g[13] = s[8]
	g[12] = s[9]
	g[8] = s[10]
	g[4] = s[11]
	if s.size() >= 16:
		g[5] = s[12]
		g[6] = s[13]
		g[10] = s[14]
		g[9] = s[15]
	else:
		# a Coons patch: the inner points that give the surface its smooth blend of the four sides
		g[5] = (-4.0 * g[0] + 6.0 * (g[1] + g[4]) - 2.0 * (g[3] + g[12]) + 3.0 * (g[13] + g[7]) - g[15]) / 9.0
		g[6] = (-4.0 * g[3] + 6.0 * (g[2] + g[7]) - 2.0 * (g[0] + g[15]) + 3.0 * (g[14] + g[4]) - g[12]) / 9.0
		g[9] = (-4.0 * g[12] + 6.0 * (g[13] + g[8]) - 2.0 * (g[15] + g[0]) + 3.0 * (g[1] + g[11]) - g[3]) / 9.0
		g[10] = (-4.0 * g[15] + 6.0 * (g[14] + g[11]) - 2.0 * (g[12] + g[3]) + 3.0 * (g[2] + g[8]) - g[0]) / 9.0
	return g


# ------------------------------------------------------------------------------------------------ patches to triangles

func _tessellate(g: Array, corners: Array, texels_per_pt: Vector2) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in g:
		lo = lo.min(p)
		hi = hi.max(p)
	var px := maxf((hi.x - lo.x) * texels_per_pt.x, (hi.y - lo.y) * texels_per_pt.y)
	var n := clampi(ceili(px / 6.0), 2, 24)
	var basis: Array = []
	for a in n + 1:
		var t := float(a) / n
		var s := 1.0 - t
		basis.append([s * s * s, 3.0 * t * s * s, 3.0 * t * t * s, t * t * t])
	var pos: Array = []
	var col: Array = []
	for a in n + 1:
		var bu: Array = basis[a]
		var u := float(a) / n
		for b in n + 1:
			var bv: Array = basis[b]
			var v := float(b) / n
			var p := Vector2.ZERO
			for i in 4:
				for j in 4:
					p += (g[i * 4 + j] as Vector2) * (bu[i] * bv[j])
			pos.append(p)
			# the corners: c0 at p00 (u 0, v 0), c1 at p03 (u 0, v 1), c2 at p33 (u 1, v 1), c3 at p30 (u 1, v 0)
			var comps: Array = []
			for q in _ncomp:
				comps.append((1.0 - u) * (1.0 - v) * float(corners[0][q]) + (1.0 - u) * v * float(corners[1][q]) + u * v * float(corners[2][q]) + u * (1.0 - v) * float(corners[3][q]))
			col.append(_color(comps))
	var stride := n + 1
	for a in n:
		for b in n:
			var i00 := a * stride + b
			var i01 := i00 + 1
			var i10 := i00 + stride
			var i11 := i10 + 1
			for q in [i00, i10, i11, i00, i11, i01]:
				_tp.append(pos[q])
				_tc.append(col[q])


# ------------------------------------------------------------------------------------------------ drawing the picture

func _gouraud(rgb: PackedByteArray, alpha: PackedByteArray, w: int, h: int, area: Rect2, a: Vector2, b: Vector2, c: Vector2, ca: Color, cb: Color, cc: Color) -> void:
	var sx := w / area.size.x
	var sy := h / area.size.y
	var pa := Vector2((a.x - area.position.x) * sx, (area.end.y - a.y) * sy)
	var pb := Vector2((b.x - area.position.x) * sx, (area.end.y - b.y) * sy)
	var pc := Vector2((c.x - area.position.x) * sx, (area.end.y - c.y) * sy)
	var det := (pb - pa).cross(pc - pa)
	if absf(det) < 1e-9:
		return
	var x0 := maxi(int(floor(minf(minf(pa.x, pb.x), pc.x) - 0.5)), 0)
	var x1 := mini(int(ceil(maxf(maxf(pa.x, pb.x), pc.x) + 0.5)), w - 1)
	var y0 := maxi(int(floor(minf(minf(pa.y, pb.y), pc.y) - 0.5)), 0)
	var y1 := mini(int(ceil(maxf(maxf(pa.y, pb.y), pc.y) + 0.5)), h - 1)
	var inv := 1.0 / det
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			var w0 := (pb - p).cross(pc - p) * inv
			var w1 := (pc - p).cross(pa - p) * inv
			var w2 := 1.0 - w0 - w1
			if w0 < -0.002 or w1 < -0.002 or w2 < -0.002:
				continue                                      # (a little over the edge, so that neighbouring triangles leave no seam)
			w0 = clampf(w0, 0.0, 1.0)
			w1 = clampf(w1, 0.0, 1.0)
			w2 = clampf(w2, 0.0, 1.0)
			var s := w0 + w1 + w2
			w0 /= s
			w1 /= s
			w2 /= s
			var at := y * w + x
			rgb[at * 3] = int(clampf(ca.r * w0 + cb.r * w1 + cc.r * w2, 0.0, 1.0) * 255.0 + 0.5)
			rgb[at * 3 + 1] = int(clampf(ca.g * w0 + cb.g * w1 + cc.g * w2, 0.0, 1.0) * 255.0 + 0.5)
			rgb[at * 3 + 2] = int(clampf(ca.b * w0 + cb.b * w1 + cc.b * w2, 0.0, 1.0) * 255.0 + 0.5)
			alpha[at] = 255


## Texels next to the drawn ones take their colour (the picture is sampled smoothly, and a black rim would show at the edge).
func _bleed(rgb: PackedByteArray, alpha: PackedByteArray, w: int, h: int) -> void:
	var src_a := alpha.duplicate()
	for y in h:
		for x in w:
			var at := y * w + x
			if src_a[at] != 0:
				continue
			var from := -1
			if x > 0 and src_a[at - 1] != 0:
				from = at - 1
			elif x < w - 1 and src_a[at + 1] != 0:
				from = at + 1
			elif y > 0 and src_a[at - w] != 0:
				from = at - w
			elif y < h - 1 and src_a[at + w] != 0:
				from = at + w
			if from >= 0:
				rgb[at * 3] = rgb[from * 3]
				rgb[at * 3 + 1] = rgb[from * 3 + 1]
				rgb[at * 3 + 2] = rgb[from * 3 + 2]
