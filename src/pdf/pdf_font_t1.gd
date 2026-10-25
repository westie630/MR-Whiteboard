class_name PdfFontT1
extends PdfFontProgram
## Adobe Type 1 fonts (what PDF calls FontFile): a PostScript header with the encoding and the font matrix, then an eexec-encrypted part with
## the subroutines and the charstrings (also encrypted). Charstrings are run as Type 1 charstrings: cubic curves, flex through
## OtherSubrs, accented letters by seac.

const MAX_SUBR_DEPTH := 12
const MAX_OPS := 100000

var ok := false
var encoding: Array = []                   # code -> glyph name from the font itself ("" none)

var _subrs: Dictionary = {}                # index -> PackedByteArray (decrypted)
var _chars: Dictionary = {}                # glyph name -> PackedByteArray (decrypted)
var _gids: Dictionary = {}                 # glyph name -> gid
var _names: PackedStringArray = PackedStringArray()
var _len_iv := 4
var _widths: Dictionary = {}


static func parse(bytes: PackedByteArray) -> PdfFontT1:
	var f := PdfFontT1.new()
	f.ok = f._read(bytes)
	return f


func _read(raw: PackedByteArray) -> bool:
	var data := _strip_pfb(raw)
	var e := _find(data, "eexec", 0)
	if e < 0:
		return false
	var clear := data.slice(0, e).get_string_from_ascii()
	_read_header(clear)
	var p := e + 5
	while p < data.size() and (data[p] == 32 or data[p] == 10 or data[p] == 13 or data[p] == 9):
		p += 1
	var enc_part := data.slice(p)
	# hexadecimal or binary eexec: the first four bytes tell
	var hex := enc_part.size() >= 4
	for i in 4:
		if i < enc_part.size() and not PdfLex._is_hex(enc_part[i]):
			hex = false
	if hex:
		enc_part = PdfFilters.ascii_hex(enc_part)
	var priv := _decrypt(enc_part, 55665, 4)
	_parse_private(priv)
	if _chars.is_empty():
		return false
	# glyph numbering: .notdef first, then in the order the font lists them
	var names: Array = _chars.keys()
	var gid := 0
	if _chars.has(".notdef"):
		_names.append(".notdef")
		_gids[".notdef"] = 0
		gid = 1
	for nm in names:
		if nm == ".notdef":
			continue
		_names.append(nm)
		_gids[nm] = gid
		gid += 1
	num_glyphs = gid
	return true


static func _strip_pfb(raw: PackedByteArray) -> PackedByteArray:
	if raw.size() < 6 or raw[0] != 0x80:
		return raw
	var out := PackedByteArray()
	var p := 0
	while p + 6 <= raw.size() and raw[p] == 0x80:
		var kind := raw[p + 1]
		if kind == 3:
			break
		var n := raw[p + 2] | (raw[p + 3] << 8) | (raw[p + 4] << 16) | (raw[p + 5] << 24)
		out.append_array(raw.slice(p + 6, p + 6 + n))
		p += 6 + n
	return out


static func _find(data: PackedByteArray, word: String, from: int) -> int:
	var first := word.unicode_at(0)
	var i := from
	while true:
		i = data.find(first, i)
		if i < 0:
			return -1
		var hit := true
		for k in range(1, word.length()):
			if i + k >= data.size() or data[i + k] != word.unicode_at(k):
				hit = false
				break
		if hit:
			return i
		i += 1
	return -1


static func _decrypt(src: PackedByteArray, key: int, skip: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(maxi(src.size() - skip, 0))
	var r := key
	for i in src.size():
		var c := src[i]
		var pl := c ^ (r >> 8)
		r = ((c + r) * 52845 + 22719) & 0xFFFF
		if i >= skip:
			out[i - skip] = pl
	return out


func _read_header(text: String) -> void:
	var fm := text.find("/FontMatrix")
	if fm >= 0:
		var a := text.find("[", fm)
		var z := text.find("]", a)
		if a >= 0 and z > a:
			var parts := text.substr(a + 1, z - a - 1).strip_edges().split(" ", false)
			if parts.size() >= 6:
				matrix = Transform2D(Vector2(float(parts[0]), float(parts[1])), Vector2(float(parts[2]), float(parts[3])), Vector2(float(parts[4]), float(parts[5])))
				units_per_em = 1.0 / maxf(absf(float(parts[0])), 1e-9)
	encoding = []
	encoding.resize(256)
	encoding.fill("")
	var en := text.find("/Encoding")
	if en >= 0:
		if text.substr(en, 80).contains("StandardEncoding"):
			for i in 256:
				encoding[i] = PdfEncodings.STANDARD[i]
		else:
			var rx := RegEx.create_from_string("dup\\s+(\\d+)\\s*/([^\\s/\\[\\]{}()<>]+)\\s+put")
			var stop := text.find("readonly def", en)
			var seg := text.substr(en, (stop - en) if stop > en else text.length() - en)
			for m in rx.search_all(seg):
				var code := int(m.get_string(1))
				if code >= 0 and code < 256:
					encoding[code] = m.get_string(2)


## Reads /lenIV, /Subrs and /CharStrings out of the decrypted private part.
func _parse_private(d: PackedByteArray) -> void:
	var li := _find(d, "/lenIV", 0)
	if li >= 0:
		_len_iv = _int_after(d, li + 6)
	var sb := _find(d, "/Subrs", 0)
	var cs := _find(d, "/CharStrings", 0)
	if sb >= 0:
		var p := sb + 6
		var limit := cs if cs > sb else d.size()
		while true:
			var q := _find(d, "dup", p)
			if q < 0 or q >= limit:
				break
			var r := _read_binary_entry(d, q + 3, false)
			if r.is_empty():
				p = q + 3
				continue
			_subrs[int(r.index)] = _decrypt(r.data, 4330, maxi(_len_iv, 0))
			p = int(r.end)
	if cs >= 0:
		var p2 := cs + 12
		var guard := 0
		while p2 < d.size() and guard < 70000:
			guard += 1
			var slash := d.find(47, p2)                                 # '/'
			if slash < 0:
				break
			var r2 := _read_binary_entry(d, slash, true)
			if r2.is_empty():
				p2 = slash + 1
				continue
			_chars[str(r2.name)] = _decrypt(r2.data, 4330, maxi(_len_iv, 0))
			p2 = int(r2.end)


func _int_after(d: PackedByteArray, at: int) -> int:
	var p := at
	while p < d.size() and (d[p] == 32 or d[p] == 9):
		p += 1
	var v := 0
	var neg := false
	if p < d.size() and d[p] == 45:
		neg = true
		p += 1
	while p < d.size() and d[p] >= 48 and d[p] <= 57:
		v = v * 10 + d[p] - 48
		p += 1
	return -v if neg else v


## "<index> <length> RD <bytes>" (a subroutine) or "/<name> <length> RD <bytes>" (a charstring) starting at `at`.
func _read_binary_entry(d: PackedByteArray, at: int, named: bool) -> Dictionary:
	var p := at
	var out := {}
	if named:
		p += 1
		var s := p
		while p < d.size() and d[p] > 32 and d[p] != 47:
			p += 1
		out["name"] = d.slice(s, p).get_string_from_ascii()
	else:
		while p < d.size() and (d[p] == 32 or d[p] == 10 or d[p] == 13 or d[p] == 9):
			p += 1
		var si := p
		while p < d.size() and d[p] >= 48 and d[p] <= 57:
			p += 1
		if p == si:
			return {}
		out["index"] = int(d.slice(si, p).get_string_from_ascii())
	while p < d.size() and (d[p] == 32 or d[p] == 10 or d[p] == 13 or d[p] == 9):
		p += 1
	var sl := p
	while p < d.size() and d[p] >= 48 and d[p] <= 57:
		p += 1
	if p == sl:
		return {}
	var length := int(d.slice(sl, p).get_string_from_ascii())
	while p < d.size() and d[p] == 32:
		p += 1
	var ts := p
	while p < d.size() and d[p] > 32:                                    # the RD / -| token
		p += 1
	if p == ts or p - ts > 4:
		return {}
	p += 1                                                              # the single space after it
	if length < 0 or p + length > d.size():
		return {}
	out["data"] = d.slice(p, p + length)
	out["end"] = p + length
	return out


func gid_for_name(glyph_name: String) -> int:
	return int(_gids.get(glyph_name, -1))


func glyph_name(gid: int) -> String:
	return _names[gid] if gid >= 0 and gid < _names.size() else ""


func gid_for_builtin_code(code: int) -> int:
	if code < 0 or code >= encoding.size():
		return -1
	var nm: String = encoding[code]
	return int(_gids.get(nm, -1)) if nm != "" else -1


func gid_for_unicode(u: int) -> int:
	var nm := PdfGlyphList.name_of(u)
	return int(_gids.get(nm, 0)) if nm != "" else 0


func advance(gid: int) -> float:
	if not _widths.has(gid):
		glyph_path(gid)
	return float(_widths[gid]) * matrix.x.x if _widths.has(gid) else -1.0


func _build_path(gid: int) -> PdfPath:
	var path := PdfPath.new()
	if gid < 0 or gid >= _names.size():
		return path
	var st := _CS.new()
	st.font = self
	st.path = path
	st.run(_chars[_names[gid]], 0)
	st.finish()
	_widths[gid] = st.width
	return path


class _CS:
	extends RefCounted
	var font: PdfFontT1
	var path: PdfPath
	var stack: Array = []
	var ps: Array = []                                   # the PostScript stack OtherSubrs leave results on
	var x := 0.0
	var y := 0.0
	var sbx := 0.0
	var width := 0.0
	var is_open := false
	var ended := false
	var flex := false
	var flex_pts: Array = []
	var flex_start := Vector2.ZERO
	var ops_left := PdfFontT1.MAX_OPS

	func finish() -> void:
		if is_open:
			path.close()
			is_open = false

	func _move(dx: float, dy: float) -> void:
		x += dx
		y += dy
		if flex:
			flex_pts.append(Vector2(x, y))
			return
		finish()
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

	func run(code: PackedByteArray, depth: int) -> void:
		var p := 0
		var n := code.size()
		while p < n and not ended:
			ops_left -= 1
			if ops_left < 0:
				ended = true
				return
			var c := code[p]
			p += 1
			if c >= 32:
				if c <= 246:
					stack.append(float(c - 139))
				elif c <= 250:
					stack.append(float((c - 247) * 256 + code[p] + 108))
					p += 1
				elif c <= 254:
					stack.append(float(-(c - 251) * 256 - code[p] - 108))
					p += 1
				else:
					var v := (code[p] << 24) | (code[p + 1] << 16) | (code[p + 2] << 8) | code[p + 3]
					stack.append(float(v - 4294967296 if v >= 2147483648 else v))
					p += 4
				continue
			match c:
				13:                                                # hsbw
					if stack.size() >= 2:
						sbx = stack[0]
						width = stack[1]
						x = sbx
						y = 0.0
					stack.clear()
				1, 3:
					stack.clear()
				4:
					if stack.size() >= 1:
						_move(0.0, stack[stack.size() - 1])
					stack.clear()
				5:
					if stack.size() >= 2:
						_line(stack[0], stack[1])
					stack.clear()
				6:
					if stack.size() >= 1:
						_line(stack[0], 0.0)
					stack.clear()
				7:
					if stack.size() >= 1:
						_line(0.0, stack[0])
					stack.clear()
				8:
					if stack.size() >= 6:
						_curve(stack[0], stack[1], stack[2], stack[3], stack[4], stack[5])
					stack.clear()
				9:
					finish()
					stack.clear()
				10:
					if not stack.is_empty() and depth < PdfFontT1.MAX_SUBR_DEPTH:
						var idx := int(stack.pop_back())
						var sub: Variant = font._subrs.get(idx)
						if sub != null:
							run(sub, depth + 1)
				11:
					return
				14:
					finish()
					ended = true
				21:
					if stack.size() >= 2:
						_move(stack[stack.size() - 2], stack[stack.size() - 1])
					stack.clear()
				22:
					if stack.size() >= 1:
						_move(stack[stack.size() - 1], 0.0)
					stack.clear()
				30:
					if stack.size() >= 4:
						_curve(0.0, stack[0], stack[1], stack[2], stack[3], 0.0)
					stack.clear()
				31:
					if stack.size() >= 4:
						_curve(stack[0], 0.0, stack[1], stack[2], 0.0, stack[3])
					stack.clear()
				12:
					var c2 := code[p]
					p += 1
					match c2:
						0, 1, 2:                                   # dotsection, vstem3, hstem3
							stack.clear()
						6:                                         # seac
							if stack.size() >= 5:
								_seac(stack[0], stack[1], stack[2], int(stack[3]), int(stack[4]))
							ended = true
							stack.clear()
						7:                                         # sbw
							if stack.size() >= 4:
								sbx = stack[0]
								width = stack[2]
								x = sbx
								y = stack[1]
							stack.clear()
						12:                                        # div
							if stack.size() >= 2:
								var d: float = stack.pop_back()
								stack[stack.size() - 1] = stack[stack.size() - 1] / d if d != 0.0 else 0.0
						16:                                        # callothersubr
							_other_subr()
						17:                                        # pop
							stack.append(ps.pop_back() if not ps.is_empty() else 0.0)
						33:                                        # setcurrentpoint
							if stack.size() >= 2:
								x = stack[0]
								y = stack[1]
							stack.clear()
						_:
							stack.clear()
				_:
					stack.clear()

	func _other_subr() -> void:
		if stack.size() < 2:
			stack.clear()
			return
		var num := int(stack.pop_back())
		var n := int(stack.pop_back())
		var args: Array = []
		for i in n:
			if stack.is_empty():
				break
			args.append(stack.pop_back())                         # args[0] is the last one pushed
		match num:
			1:                                                     # start of flex
				flex = true
				flex_pts.clear()
				flex_start = Vector2(x, y)
			2:                                                     # a flex point has been added by the move
				pass
			0:                                                     # end of flex: args are (y, x, flex height) in pop order
				flex = false
				if flex_pts.size() >= 7:
					if not is_open:
						path.move_to(flex_start)
						is_open = true
					path.cubic_to(flex_pts[1], flex_pts[2], flex_pts[3])
					path.cubic_to(flex_pts[4], flex_pts[5], flex_pts[6])
					x = (flex_pts[6] as Vector2).x
					y = (flex_pts[6] as Vector2).y
				ps.append(y)
				ps.append(x)
			3:                                                     # hint replacement: hands back the subroutine number
				ps.append(args[0] if not args.is_empty() else 3.0)
			_:
				for i in range(args.size() - 1, -1, -1):
					ps.append(args[i])

	func _seac(asb: float, adx: float, ady: float, bchar: int, achar: int) -> void:
		finish()
		var base_name: String = PdfEncodings.STANDARD[bchar] if bchar >= 0 and bchar < 256 else ""
		var acc_name: String = PdfEncodings.STANDARD[achar] if achar >= 0 and achar < 256 else ""
		var main_sbx := sbx
		var bg := font.gid_for_name(base_name)
		var ag := font.gid_for_name(acc_name)
		if bg >= 0:
			path.append_path(font.glyph_path(bg))
		if ag >= 0:
			var ap := font.glyph_path(ag)
			path.append_path(ap, Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(main_sbx + adx - asb, ady)))
