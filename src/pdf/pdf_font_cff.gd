class_name PdfFontCff
extends PdfFontProgram
## Compact Font Format: what PDF calls Type1C, CIDFontType0C and the CFF table inside an OpenType font. Outlines are Type 2 charstrings
## (cubic curves, subroutines, hints that are only skipped), names and encodings from the font's own tables.

const MAX_SUBR_DEPTH := 12
const MAX_OPS := 200000

var b := PackedByteArray()
var ok := false
var is_cid := false
var top: Dictionary = {}

var _charstrings: Array = []               # [offset, length] per glyph (offsets into b)
var _gsubrs: Array = []
var _strings: Array = []
var _charset := PackedInt32Array()         # gid -> SID (or CID in a CID font)
var _privates: Array = []                  # per font dict: {subrs: Array, default_w, nominal_w}
var _fd_fix: Array = []                    # per font dict of a CID font: what takes its glyphs to the units of `matrix` (identity when they already are)
var _fdselect := PackedByteArray()
var _fd_ranges: Array = []                 # FDSelect format 3: [first gid, fd]
var _fd_format := 0
var _names: Dictionary = {}                # glyph name -> gid
var _cids: Dictionary = {}                 # CID -> gid
var _enc: Dictionary = {}                  # code -> gid (built-in encoding)
var _widths: Dictionary = {}


static func parse(bytes: PackedByteArray) -> PdfFontCff:
	var f := PdfFontCff.new()
	f.b = bytes
	f.ok = f._read()
	return f


func _read() -> bool:
	if b.size() < 8 or b[0] != 1:
		return false
	var hdr := b[2]
	var p := hdr
	var name_idx := _index(p)
	p = name_idx.end
	var top_idx := _index(p)
	p = top_idx.end
	var str_idx := _index(p)
	p = str_idx.end
	var gs_idx := _index(p)
	if top_idx.items.is_empty():
		return false
	for it in str_idx.items:
		_strings.append(b.slice(it[0], it[0] + it[1]).get_string_from_ascii())
	_gsubrs = gs_idx.items
	var td: Array = top_idx.items[0]
	top = _dict(td[0], td[0] + td[1])
	if not top.has(17):
		return false
	var cs := _index(int(top[17][0]))
	_charstrings = cs.items
	num_glyphs = _charstrings.size()
	is_cid = top.has(1230)                                   # 12 30: ROS
	var fm: Variant = top.get(1207)                          # 12 7: FontMatrix
	if fm is Array and (fm as Array).size() >= 6:
		matrix = Transform2D(Vector2(fm[0], fm[1]), Vector2(fm[2], fm[3]), Vector2(fm[4], fm[5]))
		units_per_em = 1.0 / maxf(absf(float(fm[0])), 1e-9)
	else:
		matrix = Transform2D(Vector2(0.001, 0.0), Vector2(0.0, 0.001), Vector2.ZERO)
		units_per_em = 1000.0
	_read_charset()
	if is_cid:
		_read_fd_array()
	else:
		_privates.append(_private(top))
		_read_encoding()
	return true


## An INDEX at `at`: {items: [[offset, length], ...], end: the position after it}.
func _index(at: int) -> Dictionary:
	var out := {"items": [], "end": at + 2}
	if at + 2 > b.size():
		return out
	var count := u16(b, at)
	if count == 0:
		return out
	var osz := b[at + 2]
	if osz < 1 or osz > 4:
		return out
	var offs_at := at + 3
	var data_at := offs_at + (count + 1) * osz - 1
	if data_at > b.size():
		return out
	var items: Array = []
	var prev := _off(offs_at, osz)
	for i in count:
		var nx := _off(offs_at + (i + 1) * osz, osz)
		if nx < prev or data_at + nx > b.size() + 1:
			break
		items.append([data_at + prev, nx - prev])
		prev = nx
	out.items = items
	out.end = data_at + _off(offs_at + count * osz, osz)
	return out


func _off(at: int, size: int) -> int:
	var v := 0
	for i in size:
		v = (v << 8) | b[at + i]
	return v


## A DICT in b[start, end): operator (12 x as 1200 + x) -> array of operands.
func _dict(start: int, end: int) -> Dictionary:
	var d := {}
	var ops: Array = []
	var p := start
	while p < end:
		var c := b[p]
		if c <= 21:
			var op := c
			p += 1
			if c == 12 and p < end:
				op = 1200 + b[p]
				p += 1
			d[op] = ops
			ops = []
		elif c == 28:
			ops.append(s16(b, p + 1))
			p += 3
		elif c == 29:
			var v := u32(b, p + 1)
			ops.append(v - 4294967296 if v >= 2147483648 else v)
			p += 5
		elif c == 30:
			p += 1
			var s := ""
			var done := false
			while p < end and not done:
				var byte := b[p]
				p += 1
				for nib in [byte >> 4, byte & 15]:
					if nib <= 9:
						s += str(nib)
					elif nib == 10:
						s += "."
					elif nib == 11:
						s += "E"
					elif nib == 12:
						s += "E-"
					elif nib == 14:
						s += "-"
					elif nib == 15:
						done = true
						break
			ops.append(s.to_float())
		elif c >= 32 and c <= 246:
			ops.append(c - 139)
			p += 1
		elif c >= 247 and c <= 250:
			ops.append((c - 247) * 256 + b[p + 1] + 108)
			p += 2
		elif c >= 251 and c <= 254:
			ops.append(-(c - 251) * 256 - b[p + 1] - 108)
			p += 2
		else:
			p += 1
	return d


func _private(dict: Dictionary) -> Dictionary:
	var out := {"subrs": [], "default_w": 0.0, "nominal_w": 0.0}
	var pv: Variant = dict.get(18)
	if pv is Array and (pv as Array).size() >= 2:
		var size := int(pv[0])
		var off := int(pv[1])
		if off + size <= b.size() and size > 0:
			var pd := _dict(off, off + size)
			if pd.has(20) and (pd[20] as Array).size() > 0:
				out.default_w = float(pd[20][0])
			if pd.has(21) and (pd[21] as Array).size() > 0:
				out.nominal_w = float(pd[21][0])
			if pd.has(19) and (pd[19] as Array).size() > 0:
				out.subrs = _index(off + int(pd[19][0])).items
	return out


func _read_fd_array() -> void:
	var fa: Variant = top.get(1236)
	if fa is Array and (fa as Array).size() > 0:
		var idx := _index(int(fa[0]))
		var effective: Array = []
		var top_has := top.get(1207) is Array and (top.get(1207) as Array).size() >= 6
		for it in idx.items:
			var fd := _dict(it[0], it[0] + it[1])
			_privates.append(_private(fd))
			# the font dict's own FontMatrix is joined with the top dict's (and is the only one when the top dict has none)
			var fm: Variant = fd.get(1207)
			var fd_has := fm is Array and (fm as Array).size() >= 6
			var own := Transform2D(Vector2(fm[0], fm[1]), Vector2(fm[2], fm[3]), Vector2(fm[4], fm[5])) if fd_has else Transform2D.IDENTITY
			if fd_has and top_has:
				effective.append(matrix * own)
			elif fd_has:
				effective.append(own)
			else:
				effective.append(matrix)
		if not effective.is_empty():
			var first: Transform2D = effective[0]
			if absf(first.x.x) > 1e-12:
				matrix = first
				units_per_em = 1.0 / absf(first.x.x)
				var back := first.affine_inverse()
				for e in effective:
					_fd_fix.append((e as Transform2D) * back)
	if _privates.is_empty():
		_privates.append(_private(top))
	var fs: Variant = top.get(1237)
	if fs is Array and (fs as Array).size() > 0:
		var p := int(fs[0])
		_fd_format = b[p]
		if _fd_format == 0:
			_fdselect = b.slice(p + 1, p + 1 + num_glyphs)
		elif _fd_format == 3:
			var nr := u16(b, p + 1)
			for i in nr:
				_fd_ranges.append([u16(b, p + 3 + i * 3), b[p + 5 + i * 3]])
			_fd_ranges.append([u16(b, p + 3 + nr * 3), 0])


func _fd_of(gid: int) -> int:
	if not is_cid:
		return 0
	if _fd_format == 0:
		return 0 if _fdselect.size() <= gid else _fdselect[gid]
	if _fd_format == 3:
		for i in _fd_ranges.size() - 1:
			if gid >= int(_fd_ranges[i][0]) and gid < int(_fd_ranges[i + 1][0]):
				return int(_fd_ranges[i][1])
	return 0


func _read_charset() -> void:
	_charset.resize(num_glyphs)
	var off := int((top.get(15, [0]) as Array)[0]) if top.has(15) else 0
	if off <= 2 and not is_cid:                              # predefined: ISOAdobe (and expert sets, approximated by it)
		for g in num_glyphs:
			_charset[g] = g
		return
	if off <= 2:
		for g in num_glyphs:
			_charset[g] = g
		return
	var fmt := b[off]
	var p := off + 1
	var g := 1
	if fmt == 0:
		while g < num_glyphs and p + 2 <= b.size():
			_charset[g] = u16(b, p)
			p += 2
			g += 1
	else:
		while g < num_glyphs and p + 3 <= b.size():
			var first := u16(b, p)
			var left: int
			if fmt == 1:
				left = b[p + 2]
				p += 3
			else:
				left = u16(b, p + 2)
				p += 4
			for k in left + 1:
				if g >= num_glyphs:
					break
				_charset[g] = first + k
				g += 1


func _sid_name(sid: int) -> String:
	if sid < PdfCffData.STRINGS.size():
		return PdfCffData.STRINGS[sid]
	var i := sid - PdfCffData.STRINGS.size()
	return _strings[i] if i < _strings.size() else ""


func _read_encoding() -> void:
	var off := int((top.get(16, [0]) as Array)[0]) if top.has(16) else 0
	if off <= 1:
		# the standard encoding: code -> name -> glyph
		_build_names()
		for code in 256:
			var nm: String = PdfEncodings.STANDARD[code]
			if nm != "" and _names.has(nm):
				_enc[code] = _names[nm]
		return
	var fmt := b[off]
	var p := off + 1
	var g := 1
	if (fmt & 127) == 0:
		var n := b[p]
		p += 1
		for i in n:
			_enc[b[p + i]] = g
			g += 1
		p += n
	else:
		var nr := b[p]
		p += 1
		for i in nr:
			var first := b[p]
			var left := b[p + 1]
			p += 2
			for k in left + 1:
				_enc[first + k] = g
				g += 1
	if fmt & 128:
		_build_names()
		var ns := b[p]
		p += 1
		for i in ns:
			var code := b[p]
			var sid := u16(b, p + 1)
			p += 3
			var nm2 := _sid_name(sid)
			if _names.has(nm2):
				_enc[code] = _names[nm2]


func _build_names() -> void:
	if not _names.is_empty() or is_cid:
		return
	for g in num_glyphs:
		var nm := _sid_name(_charset[g])
		if nm != "" and not _names.has(nm):
			_names[nm] = g


func gid_for_name(glyph_name: String) -> int:
	_build_names()
	return int(_names.get(glyph_name, -1))


func glyph_name(gid: int) -> String:
	if is_cid or gid < 0 or gid >= num_glyphs:
		return ""
	return _sid_name(_charset[gid])


func gid_for_builtin_code(code: int) -> int:
	return int(_enc.get(code, -1))


func gid_for_cid(cid: int) -> int:
	if not is_cid:
		return cid
	if _cids.is_empty():
		for g in num_glyphs:
			if not _cids.has(_charset[g]):
				_cids[_charset[g]] = g
	return int(_cids.get(cid, 0))


func gid_for_unicode(u: int) -> int:
	_build_names()
	var nm := PdfGlyphList.name_of(u)
	return int(_names.get(nm, 0)) if nm != "" else 0


func advance(gid: int) -> float:
	if not _widths.has(gid):
		glyph_path(gid)
	return float(_widths.get(gid, -1.0)) * matrix.x.x if _widths.has(gid) else -1.0


# ------------------------------------------------------------------------------------------------ charstrings

func _build_path(gid: int) -> PdfPath:
	var path := PdfPath.new()
	if gid < 0 or gid >= num_glyphs:
		return path
	var fd := mini(_fd_of(gid), _privates.size() - 1)
	var st := _CS.new()
	st.font = self
	st.priv = _privates[fd]
	st.path = path
	st.width = float(st.priv.default_w)
	var cs: Array = _charstrings[gid]
	st.run(cs[0], cs[0] + cs[1], 0)
	st.finish()
	if fd < _fd_fix.size() and not (_fd_fix[fd] as Transform2D).is_equal_approx(Transform2D.IDENTITY):
		var fix: Transform2D = _fd_fix[fd]
		path = path.transformed(fix)
		st.width *= fix.x.x
	_widths[gid] = st.width
	return path


func _bias(n: int) -> int:
	return 107 if n < 1240 else (1131 if n < 33900 else 32768)


## One charstring being run.
class _CS:
	extends RefCounted
	var font: PdfFontCff
	var priv: Dictionary
	var path: PdfPath
	var stack: Array = []
	var x := 0.0
	var y := 0.0
	var nstems := 0
	var have_width := false
	var width := 0.0
	var is_open := false
	var ended := false
	var ops_left := PdfFontCff.MAX_OPS
	var trans: Array = []

	func finish() -> void:
		if is_open:
			path.close()
			is_open = false

	func _take_width(expected_even: bool, count: int) -> void:
		# the first operator of a charstring carries the width as an extra first argument
		if have_width:
			return
		have_width = true
		var extra := false
		if expected_even:
			extra = stack.size() % 2 == 1
		else:
			extra = stack.size() > count
		if extra:
			width = float(priv.nominal_w) + float(stack[0])
			stack.remove_at(0)

	func _move(dx: float, dy: float) -> void:
		finish()
		x += dx
		y += dy
		path.move_to(Vector2(x, y))
		is_open = true

	func _line(dx: float, dy: float) -> void:
		if not is_open:
			path.move_to(Vector2(x, y))
			is_open = true
		x += dx
		y += dy
		path.line_to(Vector2(x, y))

	func _curve(dx1: float, dy1: float, dx2: float, dy2: float, dx3: float, dy3: float) -> void:
		if not is_open:
			path.move_to(Vector2(x, y))
			is_open = true
		var c1 := Vector2(x + dx1, y + dy1)
		var c2 := c1 + Vector2(dx2, dy2)
		var p := c2 + Vector2(dx3, dy3)
		path.cubic_to(c1, c2, p)
		x = p.x
		y = p.y

	func run(start: int, end: int, depth: int) -> void:
		var b := font.b
		var p := start
		while p < end and not ended:
			ops_left -= 1
			if ops_left < 0:
				ended = true
				return
			var c := b[p]
			p += 1
			if c >= 32 or c == 28:
				if c == 28:
					stack.append(float(PdfFontProgram.s16(b, p)))
					p += 2
				elif c <= 246:
					stack.append(float(c - 139))
				elif c <= 250:
					stack.append(float((c - 247) * 256 + b[p] + 108))
					p += 1
				elif c <= 254:
					stack.append(float(-(c - 251) * 256 - b[p] - 108))
					p += 1
				else:
					var v := PdfFontProgram.u32(b, p)
					stack.append((v - 4294967296 if v >= 2147483648 else v) / 65536.0)
					p += 4
				continue
			match c:
				1, 3, 18, 23:                                  # stems
					_take_width(true, 0)
					nstems += stack.size() / 2
					stack.clear()
				19, 20:                                        # hintmask, cntrmask
					_take_width(true, 0)
					nstems += stack.size() / 2
					stack.clear()
					p += (nstems + 7) / 8
				21:
					_take_width(false, 2)
					if stack.size() >= 2:
						_move(stack[stack.size() - 2], stack[stack.size() - 1])
					stack.clear()
				22:
					_take_width(false, 1)
					if stack.size() >= 1:
						_move(stack[stack.size() - 1], 0.0)
					stack.clear()
				4:
					_take_width(false, 1)
					if stack.size() >= 1:
						_move(0.0, stack[stack.size() - 1])
					stack.clear()
				5:
					var i := 0
					while i + 1 < stack.size():
						_line(stack[i], stack[i + 1])
						i += 2
					stack.clear()
				6, 7:
					var horiz := c == 6
					for v2 in stack:
						if horiz:
							_line(v2, 0.0)
						else:
							_line(0.0, v2)
						horiz = not horiz
					stack.clear()
				8:
					var i2 := 0
					while i2 + 5 < stack.size():
						_curve(stack[i2], stack[i2 + 1], stack[i2 + 2], stack[i2 + 3], stack[i2 + 4], stack[i2 + 5])
						i2 += 6
					stack.clear()
				24:                                            # rcurveline
					var i3 := 0
					while i3 + 7 < stack.size():
						_curve(stack[i3], stack[i3 + 1], stack[i3 + 2], stack[i3 + 3], stack[i3 + 4], stack[i3 + 5])
						i3 += 6
					if i3 + 1 < stack.size():
						_line(stack[i3], stack[i3 + 1])
					stack.clear()
				25:                                            # rlinecurve
					var i4 := 0
					while i4 + 7 < stack.size():
						_line(stack[i4], stack[i4 + 1])
						i4 += 2
					if i4 + 5 < stack.size():
						_curve(stack[i4], stack[i4 + 1], stack[i4 + 2], stack[i4 + 3], stack[i4 + 4], stack[i4 + 5])
					stack.clear()
				26:                                            # vvcurveto
					var i5 := 0
					var dx1 := 0.0
					if stack.size() % 4 == 1:
						dx1 = stack[0]
						i5 = 1
					while i5 + 3 < stack.size():
						_curve(dx1, stack[i5], stack[i5 + 1], stack[i5 + 2], 0.0, stack[i5 + 3])
						dx1 = 0.0
						i5 += 4
					stack.clear()
				27:                                            # hhcurveto
					var i6 := 0
					var dy1 := 0.0
					if stack.size() % 4 == 1:
						dy1 = stack[0]
						i6 = 1
					while i6 + 3 < stack.size():
						_curve(stack[i6], dy1, stack[i6 + 1], stack[i6 + 2], stack[i6 + 3], 0.0)
						dy1 = 0.0
						i6 += 4
					stack.clear()
				30, 31:                                        # vhcurveto / hvcurveto
					var horiz2 := c == 31
					var i7 := 0
					var n := stack.size()
					while i7 + 3 < n:
						var last := 0.0
						if n - i7 == 5:
							last = stack[i7 + 4]
						if horiz2:
							_curve(stack[i7], 0.0, stack[i7 + 1], stack[i7 + 2], last, stack[i7 + 3])
						else:
							_curve(0.0, stack[i7], stack[i7 + 1], stack[i7 + 2], stack[i7 + 3], last)
						horiz2 = not horiz2
						i7 += 4
					stack.clear()
				10, 29:
					if stack.is_empty() or depth >= PdfFontCff.MAX_SUBR_DEPTH:
						stack.clear()
						continue
					var idx := int(stack.pop_back())
					var subrs: Array = priv.subrs if c == 10 else font._gsubrs
					idx += font._bias(subrs.size())
					if idx >= 0 and idx < subrs.size():
						run(subrs[idx][0], subrs[idx][0] + subrs[idx][1], depth + 1)
				11:
					return
				14:
					_take_width(false, 4 if stack.size() >= 4 else 0)
					if stack.size() >= 4:
						_seac(stack[stack.size() - 4], stack[stack.size() - 3], int(stack[stack.size() - 2]), int(stack[stack.size() - 1]))
					ended = true
					stack.clear()
				12:
					var c2 := b[p]
					p += 1
					_escape(c2)
				_:
					stack.clear()

	func _escape(c2: int) -> void:
		match c2:
			34:                                                # hflex
				if stack.size() >= 7:
					_curve(stack[0], 0.0, stack[1], stack[2], stack[3], 0.0)
					_curve(stack[4], 0.0, stack[5], -stack[2], stack[6], 0.0)
				stack.clear()
			35:                                                # flex
				if stack.size() >= 12:
					_curve(stack[0], stack[1], stack[2], stack[3], stack[4], stack[5])
					_curve(stack[6], stack[7], stack[8], stack[9], stack[10], stack[11])
				stack.clear()
			36:                                                # hflex1
				if stack.size() >= 9:
					_curve(stack[0], stack[1], stack[2], stack[3], stack[4], 0.0)
					_curve(stack[5], 0.0, stack[6], stack[7], stack[8], -(stack[1] + stack[3] + stack[7]))
				stack.clear()
			37:                                                # flex1
				if stack.size() >= 11:
					var dx: float = stack[0] + stack[2] + stack[4] + stack[6] + stack[8]
					var dy: float = stack[1] + stack[3] + stack[5] + stack[7] + stack[9]
					_curve(stack[0], stack[1], stack[2], stack[3], stack[4], stack[5])
					if absf(dx) > absf(dy):
						_curve(stack[6], stack[7], stack[8], stack[9], stack[10], -dy)
					else:
						_curve(stack[6], stack[7], stack[8], stack[9], -dx, stack[10])
				stack.clear()
			3:
				var bb: Variant = stack.pop_back() if stack.size() > 0 else 0.0
				var aa: Variant = stack.pop_back() if stack.size() > 0 else 0.0
				stack.append(1.0 if (aa != 0.0 and bb != 0.0) else 0.0)
			4:
				var bb2: Variant = stack.pop_back() if stack.size() > 0 else 0.0
				var aa2: Variant = stack.pop_back() if stack.size() > 0 else 0.0
				stack.append(1.0 if (aa2 != 0.0 or bb2 != 0.0) else 0.0)
			5:
				var a5: Variant = stack.pop_back() if stack.size() > 0 else 0.0
				stack.append(1.0 if a5 == 0.0 else 0.0)
			9:
				if stack.size() > 0:
					stack[stack.size() - 1] = absf(stack[stack.size() - 1])
			10:
				if stack.size() > 1:
					var s1: float = stack.pop_back()
					stack[stack.size() - 1] += s1
			11:
				if stack.size() > 1:
					var s2: float = stack.pop_back()
					stack[stack.size() - 1] -= s2
			12:
				if stack.size() > 1:
					var s3: float = stack.pop_back()
					stack[stack.size() - 1] = stack[stack.size() - 1] / s3 if s3 != 0.0 else 0.0
			14:
				if stack.size() > 0:
					stack[stack.size() - 1] = -stack[stack.size() - 1]
			15:
				if stack.size() > 1:
					var e1: float = stack.pop_back()
					var e2: float = stack.pop_back()
					stack.append(1.0 if e1 == e2 else 0.0)
			18:
				if stack.size() > 0:
					stack.pop_back()
			20:
				if stack.size() > 1:
					var pi: int = int(stack.pop_back())
					var pv: float = stack.pop_back()
					while trans.size() <= pi and trans.size() < 32:
						trans.append(0.0)
					if pi >= 0 and pi < trans.size():
						trans[pi] = pv
			21:
				if stack.size() > 0:
					var gi: int = int(stack.pop_back())
					stack.append(float(trans[gi]) if gi >= 0 and gi < trans.size() else 0.0)
			22:
				if stack.size() > 3:
					var v2: float = stack.pop_back()
					var v1: float = stack.pop_back()
					var s22: float = stack.pop_back()
					var s11: float = stack.pop_back()
					stack.append(s11 if v1 <= v2 else s22)
			23:
				stack.append(0.5)
			24:
				if stack.size() > 1:
					var m1: float = stack.pop_back()
					stack[stack.size() - 1] *= m1
			26:
				if stack.size() > 0:
					stack[stack.size() - 1] = sqrt(maxf(stack[stack.size() - 1], 0.0))
			27:
				if stack.size() > 0:
					stack.append(stack[stack.size() - 1])
			28:
				if stack.size() > 1:
					var t1: float = stack.pop_back()
					var t2: float = stack.pop_back()
					stack.append(t1)
					stack.append(t2)
			29:
				if stack.size() > 0:
					var ix: int = int(stack.pop_back())
					ix = clampi(ix, 0, stack.size() - 1) if ix >= 0 else 0
					if stack.size() > 0:
						stack.append(stack[stack.size() - 1 - ix])
			30:
				if stack.size() > 1:
					var j: int = int(stack.pop_back())
					var nn: int = int(stack.pop_back())
					if nn > 0 and nn <= stack.size():
						var part: Array = stack.slice(stack.size() - nn)
						stack.resize(stack.size() - nn)
						j = ((j % nn) + nn) % nn
						for k in nn:
							stack.append(part[(k - j + nn) % nn])
			_:
				stack.clear()

	## endchar with four operands draws an accented letter: the base and the accent, both from the standard encoding.
	func _seac(adx: float, ady: float, bchar: int, achar: int) -> void:
		finish()
		var base_name: String = PdfEncodings.STANDARD[bchar] if bchar >= 0 and bchar < 256 else ""
		var acc_name: String = PdfEncodings.STANDARD[achar] if achar >= 0 and achar < 256 else ""
		var bg := font.gid_for_name(base_name)
		var ag := font.gid_for_name(acc_name)
		if bg >= 0:
			path.append_path(font.glyph_path(bg))
		if ag >= 0:
			path.append_path(font.glyph_path(ag), Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(adx, ady)))
