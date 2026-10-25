class_name PdfFontTtf
extends PdfFontProgram
## TrueType and OpenType fonts (sfnt files): outlines from `glyf` (including composite glyphs) or from a `CFF ` table, advances from `hmtx`,
## characters from `cmap`. Fonts inside a PDF are often subsets with half the tables cut away, so only what is really needed is required:
## head, maxp, loca and glyf (or CFF), and hmtx when the PDF does not give widths.

const MAX_DEPTH := 8
const MAX_POINTS := 20000

var b := PackedByteArray()
var ok := false
var cff: PdfFontCff = null

var _tables: Dictionary = {}               # tag -> [offset, length]
var _long_loca := false
var _loca_at := 0
var _glyf_at := 0
var _glyf_len := 0
var _loca_n := 0
var _hmtx_at := -1
var _n_hmetrics := 0
var _cmaps: Array = []                     # {pid, eid, off, fmt}
var _unicode_cmap := -1                    # index into _cmaps of the best Unicode table, -1 none
var _symbol_cmap := -1
var _mac_cmap := -1
var _names: Dictionary = {}                # glyph name -> gid (from `post`, built on demand)
var _names_built := false
var _gid_names: Dictionary = {}


static func parse(bytes: PackedByteArray) -> PdfFontTtf:
	var f := PdfFontTtf.new()
	f.b = bytes
	f.ok = f._read()
	return f


func _read() -> bool:
	if b.size() < 12:
		return false
	var base := 0
	var tag := b.slice(0, 4).get_string_from_ascii()
	if tag == "ttcf" and b.size() >= 16:
		base = u32(b, 12)
		if base + 12 > b.size():
			return false
		tag = b.slice(base, base + 4).get_string_from_ascii()
	if tag != "true" and tag != "OTTO" and u32(b, base) != 0x00010000 and tag != "typ1":
		return false
	var n := u16(b, base + 4)
	for i in n:
		var rec := base + 12 + i * 16
		if rec + 16 > b.size():
			break
		var tg := b.slice(rec, rec + 4).get_string_from_ascii()
		var off := u32(b, rec + 8)
		var len := u32(b, rec + 12)
		if off > b.size():
			continue
		_tables[tg] = [off, mini(len, b.size() - off)]
	var head: Variant = _tables.get("head")
	if head != null and (head as Array)[1] >= 54:
		var h: int = head[0]
		units_per_em = float(u16(b, h + 18))
		_long_loca = s16(b, h + 50) != 0
	if units_per_em < 16.0:
		units_per_em = 1000.0
	var inv := 1.0 / units_per_em
	matrix = Transform2D(Vector2(inv, 0.0), Vector2(0.0, inv), Vector2.ZERO)
	var maxp: Variant = _tables.get("maxp")
	if maxp != null and (maxp as Array)[1] >= 6:
		num_glyphs = u16(b, int(maxp[0]) + 4)
	var hhea: Variant = _tables.get("hhea")
	var hmtx: Variant = _tables.get("hmtx")
	if hhea != null and hmtx != null and (hhea as Array)[1] >= 36:
		_n_hmetrics = u16(b, int(hhea[0]) + 34)
		_hmtx_at = int(hmtx[0])
		if _hmtx_at + _n_hmetrics * 4 > b.size():
			_n_hmetrics = maxi((b.size() - _hmtx_at) / 4, 0)
	var cff_t: Variant = _tables.get("CFF ")
	if cff_t != null:
		cff = PdfFontCff.parse(b.slice(int(cff_t[0]), int(cff_t[0]) + int(cff_t[1])))
		if cff.ok:
			if num_glyphs == 0:
				num_glyphs = cff.num_glyphs
		else:
			cff = null
	var loca: Variant = _tables.get("loca")
	var glyf: Variant = _tables.get("glyf")
	if loca != null and glyf != null:
		_loca_at = int(loca[0])
		_glyf_at = int(glyf[0])
		_glyf_len = int(glyf[1])
		_loca_n = int(loca[1]) / (4 if _long_loca else 2)
		if num_glyphs == 0:
			num_glyphs = maxi(_loca_n - 1, 0)
	elif cff == null:
		return false
	_read_cmap()
	return true


func _read_cmap() -> void:
	var t: Variant = _tables.get("cmap")
	if t == null or int((t as Array)[1]) < 4:
		return
	var at: int = t[0]
	var n := u16(b, at + 2)
	for i in n:
		var rec := at + 4 + i * 8
		if rec + 8 > b.size():
			break
		var pid := u16(b, rec)
		var eid := u16(b, rec + 2)
		var off := at + u32(b, rec + 4)
		if off + 6 > b.size():
			continue
		var fmt := u16(b, off)
		if fmt not in [0, 4, 6, 12]:
			continue
		var idx := _cmaps.size()
		_cmaps.append({"pid": pid, "eid": eid, "off": off, "fmt": fmt})
		if (pid == 3 and (eid == 10 or (eid == 1 and _unicode_cmap < 0))) or (pid == 0 and _unicode_cmap < 0):
			_unicode_cmap = idx
		elif pid == 3 and eid == 0:
			_symbol_cmap = idx
		elif pid == 1 and eid == 0:
			_mac_cmap = idx
	if _unicode_cmap < 0 and _symbol_cmap >= 0:
		pass


func has_unicode_cmap() -> bool:
	return _unicode_cmap >= 0


func has_symbol_cmap() -> bool:
	return _symbol_cmap >= 0


func has_mac_cmap() -> bool:
	return _mac_cmap >= 0


## The glyph for a code in one of the cmap tables ("unicode", "symbol", "mac"), 0 when it has none.
func lookup(kind: String, code: int) -> int:
	var idx := _unicode_cmap if kind == "unicode" else (_symbol_cmap if kind == "symbol" else _mac_cmap)
	if idx < 0:
		return 0
	return _cmap_lookup(_cmaps[idx], code)


## Any cmap at all (the first), for fonts whose tables are not the usual ones.
func lookup_any(code: int) -> int:
	for c in _cmaps:
		var g := _cmap_lookup(c, code)
		if g != 0:
			return g
	return 0


func _cmap_lookup(c: Dictionary, code: int) -> int:
	var off: int = c.off
	match int(c.fmt):
		0:
			if code < 0 or code > 255 or off + 6 + code >= b.size():
				return 0
			return b[off + 6 + code]
		4:
			var seg2 := u16(b, off + 6)
			var segs := seg2 / 2
			var end_at := off + 14
			var start_at := end_at + seg2 + 2
			var delta_at := start_at + seg2
			var range_at := delta_at + seg2
			if range_at + seg2 > b.size():
				return 0
			var lo := 0
			var hi := segs - 1
			while lo <= hi:
				var mid := (lo + hi) >> 1
				var end_code := u16(b, end_at + mid * 2)
				if code > end_code:
					lo = mid + 1
				else:
					var start_code := u16(b, start_at + mid * 2)
					if code < start_code:
						hi = mid - 1
					else:
						var ro := u16(b, range_at + mid * 2)
						var delta := u16(b, delta_at + mid * 2)
						if ro == 0:
							return (code + delta) & 0xFFFF
						var gi := range_at + mid * 2 + ro + (code - start_code) * 2
						if gi + 2 > b.size():
							return 0
						var g := u16(b, gi)
						return 0 if g == 0 else (g + delta) & 0xFFFF
			return 0
		6:
			var first := u16(b, off + 6)
			var cnt := u16(b, off + 8)
			if code < first or code >= first + cnt or off + 10 + (code - first) * 2 + 2 > b.size():
				return 0
			return u16(b, off + 10 + (code - first) * 2)
		12:
			var ng := u32(b, off + 12)
			var lo2 := 0
			var hi2 := ng - 1
			while lo2 <= hi2:
				var mid2 := (lo2 + hi2) >> 1
				var rec := off + 16 + mid2 * 12
				if rec + 12 > b.size():
					return 0
				var s := u32(b, rec)
				var e := u32(b, rec + 4)
				if code < s:
					hi2 = mid2 - 1
				elif code > e:
					lo2 = mid2 + 1
				else:
					return u32(b, rec + 8) + (code - s)
			return 0
	return 0


func gid_for_unicode(u: int) -> int:
	var g := lookup("unicode", u)
	if g == 0 and _symbol_cmap >= 0:
		g = lookup("symbol", 0xF000 + u) if u < 256 else 0
	return g


func gid_for_name(glyph_name: String) -> int:
	if cff != null:
		return cff.gid_for_name(glyph_name)
	_build_names()
	return int(_names.get(glyph_name, -1))


func glyph_name(gid: int) -> String:
	if cff != null:
		return cff.glyph_name(gid)
	_build_names()
	return str(_gid_names.get(gid, ""))


## `post` format 2 glyph names beyond the 258 standard Macintosh ones (subset fonts that keep names use these).
func _build_names() -> void:
	if _names_built:
		return
	_names_built = true
	var t: Variant = _tables.get("post")
	if t == null or int((t as Array)[1]) < 34:
		return
	var at: int = t[0]
	if u32(b, at) != 0x00020000:
		return
	var n := u16(b, at + 32)
	var idx_at := at + 34
	var str_at := idx_at + n * 2
	var strings: Array = []
	var p := str_at
	var end := at + int(t[1])
	while p < end and p < b.size():
		var l := b[p]
		strings.append(b.slice(p + 1, p + 1 + l).get_string_from_ascii())
		p += 1 + l
	for g in n:
		if idx_at + g * 2 + 2 > b.size():
			break
		var ix := u16(b, idx_at + g * 2)
		if ix >= 258 and ix - 258 < strings.size():
			var nm: String = strings[ix - 258]
			_names[nm] = g
			_gid_names[g] = nm


func advance(gid: int) -> float:
	if _hmtx_at < 0 or _n_hmetrics <= 0 or gid < 0:
		return cff.advance(gid) if cff != null else -1.0
	var i := mini(gid, _n_hmetrics - 1)
	return float(u16(b, _hmtx_at + i * 4)) / units_per_em


# ------------------------------------------------------------------------------------------------ outlines

func _build_path(gid: int) -> PdfPath:
	var path := PdfPath.new()
	if cff != null and _glyf_len == 0:
		return cff.glyph_path(gid)
	_glyph(gid, Transform2D.IDENTITY, path, 0)
	return path


func _loca(gid: int) -> Vector2i:
	if gid < 0 or gid + 1 >= _loca_n:
		return Vector2i(0, 0)
	var a: int
	var e: int
	if _long_loca:
		a = u32(b, _loca_at + gid * 4)
		e = u32(b, _loca_at + gid * 4 + 4)
	else:
		a = u16(b, _loca_at + gid * 2) * 2
		e = u16(b, _loca_at + gid * 2 + 2) * 2
	return Vector2i(a, e)


func _glyph(gid: int, xf: Transform2D, path: PdfPath, depth: int) -> void:
	if depth > MAX_DEPTH:
		return
	var r := _loca(gid)
	if r.y <= r.x or r.y > _glyf_len or r.y - r.x < 10:
		return
	var at := _glyf_at + r.x
	var nc := s16(b, at)
	if nc >= 0:
		_simple(at, nc, xf, path)
		return
	# composite
	var p := at + 10
	var more := true
	var guard := 0
	while more and guard < 64 and p + 4 <= b.size():
		guard += 1
		var flags := u16(b, p)
		var gi := u16(b, p + 2)
		p += 4
		var a1: int
		var a2: int
		if flags & 1:
			if flags & 2:
				a1 = s16(b, p)
				a2 = s16(b, p + 2)
			else:
				a1 = u16(b, p)
				a2 = u16(b, p + 2)
			p += 4
		else:
			if flags & 2:
				a1 = b[p] - 256 if b[p] >= 128 else b[p]
				a2 = b[p + 1] - 256 if b[p + 1] >= 128 else b[p + 1]
			else:
				a1 = b[p]
				a2 = b[p + 1]
			p += 2
		var sx := 1.0
		var sy := 1.0
		var s01 := 0.0
		var s10 := 0.0
		if flags & 8:
			sx = s16(b, p) / 16384.0
			sy = sx
			p += 2
		elif flags & 0x40:
			sx = s16(b, p) / 16384.0
			sy = s16(b, p + 2) / 16384.0
			p += 4
		elif flags & 0x80:
			sx = s16(b, p) / 16384.0
			s01 = s16(b, p + 2) / 16384.0
			s10 = s16(b, p + 4) / 16384.0
			sy = s16(b, p + 6) / 16384.0
			p += 8
		var dx := 0.0
		var dy := 0.0
		if flags & 2:                                   # the arguments are an offset (point matching is not supported: offset 0)
			dx = a1
			dy = a2
			if flags & 0x800:                            # SCALED_COMPONENT_OFFSET
				dx *= sx
				dy *= sy
		var comp := Transform2D(Vector2(sx, s01), Vector2(s10, sy), Vector2(dx, dy))
		_glyph(gi, xf * comp, path, depth + 1)
		more = (flags & 0x20) != 0


func _simple(at: int, nc: int, xf: Transform2D, path: PdfPath) -> void:
	if nc == 0:
		return
	var p := at + 10
	var ends := PackedInt32Array()
	for i in nc:
		ends.append(u16(b, p + i * 2))
	p += nc * 2
	var npts := ends[nc - 1] + 1
	if npts <= 0 or npts > MAX_POINTS:
		return
	var instr := u16(b, p)
	p += 2 + instr
	var flags := PackedByteArray()
	flags.resize(npts)
	var i := 0
	while i < npts and p < b.size():
		var f := b[p]
		p += 1
		flags[i] = f
		i += 1
		if f & 8 and p < b.size():
			var rep := b[p]
			p += 1
			while rep > 0 and i < npts:
				flags[i] = f
				i += 1
				rep -= 1
	if i < npts:
		return
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	xs.resize(npts)
	ys.resize(npts)
	var v := 0
	for k in npts:
		var f2 := flags[k]
		if f2 & 2:
			var d := b[p]
			p += 1
			v += d if (f2 & 16) else -d
		elif not (f2 & 16):
			v += s16(b, p)
			p += 2
		xs[k] = v
	v = 0
	for k in npts:
		var f3 := flags[k]
		if f3 & 4:
			var d2 := b[p]
			p += 1
			v += d2 if (f3 & 32) else -d2
		elif not (f3 & 32):
			v += s16(b, p)
			p += 2
		ys[k] = v
	var start := 0
	for c in nc:
		var end := ends[c]
		if end >= start:
			_contour(xs, ys, flags, start, end, xf, path)
		start = end + 1


func _contour(xs: PackedFloat32Array, ys: PackedFloat32Array, flags: PackedByteArray, s: int, e: int, xf: Transform2D, path: PdfPath) -> void:
	var n := e - s + 1
	if n < 2:
		return
	var pts := PackedVector2Array()
	var on := PackedByteArray()
	for k in range(s, e + 1):
		pts.append(xf * Vector2(xs[k], ys[k]))
		on.append(flags[k] & 1)
	# a start on a curve point: the first on-curve point, or the middle of two off-curve points
	var first := -1
	for k in n:
		if on[k]:
			first = k
			break
	var origin: Vector2
	var order := PackedInt32Array()
	if first >= 0:
		origin = pts[first]
		for k in range(1, n + 1):
			order.append((first + k) % n)
	else:
		origin = (pts[0] + pts[n - 1]) * 0.5
		for k in n:
			order.append(k)
		order.append(-1)
	path.move_to(origin)
	var ctrl := Vector2.ZERO
	var have_ctrl := false
	for ix in order:
		if ix < 0:
			# closing back to a midpoint start with every point off-curve
			if have_ctrl:
				path.quad_to(ctrl, origin)
			break
		var pt := pts[ix]
		if on[ix]:
			if have_ctrl:
				path.quad_to(ctrl, pt)
				have_ctrl = false
			else:
				path.line_to(pt)
		else:
			if have_ctrl:
				path.quad_to(ctrl, (ctrl + pt) * 0.5)
			ctrl = pt
			have_ctrl = true
	if first >= 0 and have_ctrl:
		path.quad_to(ctrl, origin)
	path.close()
