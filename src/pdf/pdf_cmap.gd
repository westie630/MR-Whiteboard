class_name PdfCMap
extends RefCounted
## A character map of a composite (Type 0) font: how the bytes of a string are cut into character codes, and which CID each code is.
## Reads CMap files embedded in a PDF (codespace ranges, cidrange, cidchar) and knows Identity-H / Identity-V. The big predefined CJK maps
## are not carried: a font that names one is read as two-byte codes with CID = code, which is right for the usual Identity-encoded fonts and
## wrong for the legacy ones (their glyphs would need the map).

var identity := true
var vertical := false
var _spaces: Array = []                    # [length, lo, hi]
var _chars: Dictionary = {}                # code -> cid
var _ranges: Array = []                    # [lo, hi, cid] sorted by lo
var _sorted := true


static func identity_map(vert: bool = false) -> PdfCMap:
	var m := PdfCMap.new()
	m.vertical = vert
	m._spaces = [[2, 0, 0xFFFF]]
	return m


static func parse(bytes: PackedByteArray) -> PdfCMap:
	var m := PdfCMap.new()
	m.identity = false
	var lex := PdfLex.new(bytes)
	var prev: Array = []
	while true:
		var t: Variant = lex.next()
		if typeof(t) == TYPE_STRING_NAME and t == PdfLex.END:
			break
		if typeof(t) == TYPE_STRING:
			match t:
				"begincodespacerange":
					m._read_spaces(lex)
				"begincidrange":
					m._read_ranges(lex)
				"begincidchar":
					m._read_chars(lex)
				"usecmap":
					pass
				"def":
					if prev.size() >= 2 and typeof(prev[prev.size() - 2]) == TYPE_STRING_NAME and prev[prev.size() - 2] == &"WMode":
						m.vertical = int(prev[prev.size() - 1]) == 1
			prev.clear()
		else:
			prev.append(t)
			if prev.size() > 4:
				prev.pop_front()
	if m._spaces.is_empty():
		m._spaces = [[2, 0, 0xFFFF]]
	m._ranges.sort_custom(func(a, b): return a[0] < b[0])
	return m


static func _num(s: PackedByteArray) -> int:
	var v := 0
	for c in s:
		v = (v << 8) | c
	return v


func _read_spaces(lex: PdfLex) -> void:
	while true:
		var lo: Variant = lex.next()
		if typeof(lo) != TYPE_PACKED_BYTE_ARRAY:
			return
		var hi: Variant = lex.next()
		if typeof(hi) != TYPE_PACKED_BYTE_ARRAY:
			return
		_spaces.append([(lo as PackedByteArray).size(), _num(lo), _num(hi)])


func _read_ranges(lex: PdfLex) -> void:
	while true:
		var lo: Variant = lex.next()
		if typeof(lo) != TYPE_PACKED_BYTE_ARRAY:
			return
		var hi: Variant = lex.next()
		var cid: Variant = lex.next()
		if typeof(hi) != TYPE_PACKED_BYTE_ARRAY or typeof(cid) != TYPE_INT:
			return
		_ranges.append([_num(lo), _num(hi), int(cid)])


func _read_chars(lex: PdfLex) -> void:
	while true:
		var code: Variant = lex.next()
		if typeof(code) != TYPE_PACKED_BYTE_ARRAY:
			return
		var cid: Variant = lex.next()
		if typeof(cid) != TYPE_INT:
			return
		_chars[_num(code)] = int(cid)


## The character code at `at` in `s` as Vector2i(code, bytes used). Bytes that fit no codespace range are taken one at a time.
func next_code(s: PackedByteArray, at: int) -> Vector2i:
	var left := s.size() - at
	var code := 0
	for n in range(1, mini(4, left) + 1):
		code = (code << 8) | s[at + n - 1]
		for sp in _spaces:
			if int(sp[0]) == n and code >= int(sp[1]) and code <= int(sp[2]):
				return Vector2i(code, n)
	return Vector2i(s[at], 1)


func cid_of(code: int) -> int:
	if identity:
		return code
	var c: Variant = _chars.get(code)
	if c != null:
		return int(c)
	var lo := 0
	var hi := _ranges.size() - 1
	while lo <= hi:
		var mid := (lo + hi) >> 1
		var r: Array = _ranges[mid]
		if code < int(r[0]):
			hi = mid - 1
		elif code > int(r[1]):
			lo = mid + 1
		else:
			return int(r[2]) + code - int(r[0])
	return 0
