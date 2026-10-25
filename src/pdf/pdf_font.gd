class_name PdfFont
extends RefCounted
## A font as a page uses it: what its dictionary says (encoding, widths) joined to the glyphs of its font file, or of a stand-in font when
## the file is not carried. decode() cuts a string shown with the font into glyphs: which glyph, how far to advance.
##
## Three kinds: "simple" (one byte per character: Type 1, TrueType), "cid" (Type 0: codes of one to four bytes through a CMap to a CID, then to
## a glyph) and "type3" (every glyph is a little content stream of its own).

var doc: PdfDoc
var dict: Dictionary = {}
var kind := "simple"
var subtype := ""
var base_font := ""
var program: PdfFontProgram = null
var sfnt: PdfFontTtf = null                # when the program is a TrueType / OpenType file (its cmap tables decide how codes find glyphs)
var substituted := false
var vertical := false
var flags := 0
var id := ""

# simple fonts
var _first := 0
var _widths := PackedFloat64Array()
var _has_widths := false
var _missing := 0.0
var _enc: Array = []                       # code -> glyph name ("" none); empty = the font's own encoding
var _has_encoding := false
var _builtin_ok := false
var _gids: Dictionary = {}                 # code -> gid

# composite fonts
var _cmap: PdfCMap = null
var _dw := 1000.0
var _cw: Dictionary = {}                   # cid -> width
var _dw2 := Vector2(880.0, -1000.0)
var _cid_to_gid := PackedByteArray()
var _cid_identity := true

# Type 3
var t3_matrix := Transform2D(Vector2(0.001, 0.0), Vector2(0.0, 0.001), Vector2.ZERO)
var t3_procs: Dictionary = {}              # glyph name -> PdfStream
var t3_resources: Dictionary = {}


## Loads the font a page's /Font entry names. `cache` keeps one PdfFont per font object for the whole document.
static func load_font(d: PdfDoc, entry: Variant, cache: Dictionary) -> PdfFont:
	var key := ""
	if typeof(entry) == TYPE_VECTOR2I:
		key = "r%d" % (entry as Vector2i).x
		if cache.has(key):
			return cache[key]
	var fd := d.d_dict(entry)
	var f := PdfFont.new()
	f.doc = d
	f.dict = fd
	f.id = key if key != "" else "d%d" % cache.size()
	f._setup()
	cache[f.id] = f
	return f


func _setup() -> void:
	subtype = doc.d_name(dict.get("Subtype"))
	base_font = doc.d_name(dict.get("BaseFont"))
	if subtype == "Type0":
		kind = "cid"
		_setup_cid()
	elif subtype == "Type3":
		kind = "type3"
		_setup_type3()
	else:
		_setup_simple()


# ------------------------------------------------------------------------------------------------ font files

func _descriptor(d: Dictionary) -> Dictionary:
	return doc.d_dict(d.get("FontDescriptor"))


## The font program of a descriptor, whatever the file is: Type 1, TrueType, CFF or OpenType.
func _load_program(desc: Dictionary) -> PdfFontProgram:
	for key in ["FontFile2", "FontFile3", "FontFile"]:
		var st := doc.d_stream(desc.get(key))
		if st == null:
			continue
		var bytes := st.decode()
		if bytes.size() < 12:
			continue
		var p := _sniff(bytes)
		if p != null:
			return p
	return null


func _sniff(bytes: PackedByteArray) -> PdfFontProgram:
	var b0 := bytes[0]
	if b0 == 0x80 or (b0 == 0x25 and bytes[1] == 0x21):                 # PFB / "%!"
		var t1 := PdfFontT1.parse(bytes)
		return t1 if t1.ok else null
	if b0 == 1 and bytes[1] == 0:                                        # bare CFF
		var cff := PdfFontCff.parse(bytes)
		return cff if cff.ok else null
	var ttf := PdfFontTtf.parse(bytes)
	if ttf.ok:
		sfnt = ttf
		if ttf.cff != null and ttf._glyf_len == 0:
			return ttf.cff
		return ttf
	return null


# ------------------------------------------------------------------------------------------------ simple fonts

func _setup_simple() -> void:
	var desc := _descriptor(dict)
	flags = doc.d_int(desc.get("Flags"), 0)
	_first = doc.d_int(dict.get("FirstChar"), 0)
	_missing = doc.d_num(desc.get("MissingWidth"), 0.0)
	var w := doc.d_nums(dict.get("Widths"))
	_widths = w
	_has_widths = not w.is_empty()
	program = _load_program(desc)
	if program == null:
		substituted = true
		var std := PdfStdFonts.pick(base_font, flags, desc)
		program = std
		sfnt = std
	_build_encoding(desc)


func _is_symbolic() -> bool:
	return (flags & 4) != 0 and (flags & 32) == 0


func _build_encoding(desc: Dictionary) -> void:
	var enc_v: Variant = doc.res(dict.get("Encoding"))
	var base_name := ""
	var diffs: Array = []
	if typeof(enc_v) == TYPE_STRING_NAME:
		base_name = String(enc_v)
		_has_encoding = true
	elif enc_v is Dictionary:
		_has_encoding = true
		base_name = doc.d_name((enc_v as Dictionary).get("BaseEncoding"))
		diffs = doc.d_array((enc_v as Dictionary).get("Differences"))
	var table := PdfEncodings.named(base_name)
	if table.is_empty():
		if substituted:
			table = PdfEncodings.SYMBOL if str(base_font).to_lower().contains("symbol") else (PdfEncodings.ZAPF if str(base_font).to_lower().contains("zapf") else PdfEncodings.STANDARD)
		elif program is PdfFontT1 or program is PdfFontCff:
			table = []                                                  # the font's own encoding
		elif sfnt != null and not _is_symbolic():
			table = PdfEncodings.STANDARD
	if table.is_empty() and diffs.is_empty():
		_enc = []
		return
	_enc = []
	if table.is_empty():
		_enc.resize(256)
		_enc.fill("")
	else:
		_enc = table.duplicate()
	var code := 0
	for item in diffs:
		var v: Variant = doc.res(item)
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			code = int(v)
		elif typeof(v) == TYPE_STRING_NAME:
			if code >= 0 and code < 256:
				_enc[code] = String(v)
			code += 1


## The glyph a character code shows in a simple font, -1 for none.
func _gid_simple(code: int) -> int:
	if _gids.has(code):
		return _gids[code]
	var g := _find_simple(code)
	_gids[code] = g
	return g


func _find_simple(code: int) -> int:
	var nm: String = _enc[code] if _enc.size() == 256 else ""
	if sfnt != null and program == sfnt:
		return _find_ttf(code, nm)
	var g := -1
	if nm != "":
		g = program.gid_for_name(nm)
		if g < 0:
			var u := PdfGlyphList.unicode_of(nm)
			if u != 0:
				g = program.gid_for_unicode(u)
				if g == 0:
					g = -1
	if g < 0:
		g = program.gid_for_builtin_code(code)
	if g < 0 and nm == "" and _enc.size() == 256 and (program is PdfFontT1 or program is PdfFontCff):
		g = program.gid_for_builtin_code(code)
	return g


func _find_ttf(code: int, nm: String) -> int:
	var t := sfnt
	var g := 0
	if substituted:
		# a stand-in font: by the character the glyph name stands for
		var u := PdfGlyphList.unicode_of(nm) if nm != "" else code
		if u == 0:
			u = code if code >= 32 else 0
		g = t.gid_for_unicode(u)
		if g == 0 and nm == "space":
			g = t.gid_for_unicode(32)
		return g if g > 0 else -1
	if nm != "" and not _is_symbolic_cmap_only(t):
		var u2 := PdfGlyphList.unicode_of(nm)
		if u2 != 0:
			g = t.lookup("unicode", u2)
			if g == 0 and t.has_mac_cmap():
				var mc := PdfEncodings.MAC_ROMAN.find(nm)
				if mc >= 0:
					g = t.lookup("mac", mc)
		if g == 0:
			var byname := t.gid_for_name(nm)
			if byname > 0:
				g = byname
		if g > 0:
			return g
	# symbolic or unnamed: the code itself in the (3,0) table, shifted into the private area, or in the Macintosh table
	if t.has_symbol_cmap():
		for base in [0, 0xF000, 0xF100, 0xF200]:
			g = t.lookup("symbol", base + code)
			if g > 0:
				return g
	if t.has_mac_cmap():
		g = t.lookup("mac", code)
		if g > 0:
			return g
	g = t.lookup("unicode", code)
	if g > 0:
		return g
	g = t.lookup_any(code)
	if g > 0:
		return g
	# a subset font with no usable table at all: the glyph with the same number as the code is the best guess
	if not t.has_unicode_cmap() and not t.has_symbol_cmap() and not t.has_mac_cmap():
		return code if code < t.num_glyphs else -1
	return -1


func _is_symbolic_cmap_only(t: PdfFontTtf) -> bool:
	return not t.has_unicode_cmap() and not t.has_mac_cmap() and t.has_symbol_cmap()


# ------------------------------------------------------------------------------------------------ composite fonts

func _setup_cid() -> void:
	var enc_v: Variant = doc.res(dict.get("Encoding"))
	if typeof(enc_v) == TYPE_STRING_NAME:
		var n := String(enc_v)
		_cmap = PdfCMap.identity_map(n.ends_with("-V"))
		vertical = n.ends_with("-V")
	elif enc_v is PdfStream:
		_cmap = PdfCMap.parse((enc_v as PdfStream).decode())
		vertical = _cmap.vertical or doc.d_int((enc_v as PdfStream).dict.get("WMode"), 0) == 1
	else:
		_cmap = PdfCMap.identity_map()
	var desc_fonts := doc.d_array(dict.get("DescendantFonts"))
	var df := doc.d_dict(desc_fonts[0]) if not desc_fonts.is_empty() else {}
	if base_font == "":
		base_font = doc.d_name(df.get("BaseFont"))
	var desc := _descriptor(df)
	flags = doc.d_int(desc.get("Flags"), 0)
	_dw = doc.d_num(df.get("DW"), 1000.0)
	var w := doc.d_array(df.get("W"))
	var i := 0
	while i < w.size():
		var c1 := doc.d_int(w[i], 0)
		var nxt: Variant = doc.res(w[i + 1]) if i + 1 < w.size() else null
		if nxt is Array:
			var k := 0
			for x in (nxt as Array):
				_cw[c1 + k] = doc.d_num(x, _dw)
				k += 1
			i += 2
		else:
			var c2 := doc.d_int(nxt, c1)
			var width := doc.d_num(w[i + 2], _dw) if i + 2 < w.size() else _dw
			if c2 - c1 <= 70000:
				for c in range(c1, c2 + 1):
					_cw[c] = width
			i += 3
	var d2 := doc.d_nums(df.get("DW2"))
	if d2.size() >= 2:
		_dw2 = Vector2(d2[0], d2[1])
	var c2g: Variant = doc.res(df.get("CIDToGIDMap"))
	if c2g is PdfStream:
		_cid_to_gid = (c2g as PdfStream).decode()
		_cid_identity = false
	program = _load_program(desc)
	if program == null:
		substituted = true
		var std := PdfStdFonts.pick(base_font, flags, desc)
		program = std
		sfnt = std


func _gid_cid(cid: int, code: int) -> int:
	if substituted:
		# no font file: the character is not known from a CID, only from the code when the CMap was Unicode-like
		var t := sfnt
		var u := code if code >= 32 else 0
		var g := t.gid_for_unicode(u) if u > 0 else 0
		return g if g > 0 else -1
	if not _cid_identity:
		var at := cid * 2
		if at + 1 < _cid_to_gid.size():
			return (_cid_to_gid[at] << 8) | _cid_to_gid[at + 1]
		return -1
	if program is PdfFontCff:
		return program.gid_for_cid(cid)
	return cid if cid < program.num_glyphs or program.num_glyphs == 0 else -1


# ------------------------------------------------------------------------------------------------ Type 3

func _setup_type3() -> void:
	var fm := doc.d_nums(dict.get("FontMatrix"))
	if fm.size() >= 6:
		t3_matrix = Transform2D(Vector2(fm[0], fm[1]), Vector2(fm[2], fm[3]), Vector2(fm[4], fm[5]))
	var cp := doc.d_dict(dict.get("CharProcs"))
	for k in cp:
		var st := doc.d_stream(cp[k])
		if st != null:
			t3_procs[k] = st
	t3_resources = doc.d_dict(dict.get("Resources"))
	_first = doc.d_int(dict.get("FirstChar"), 0)
	_widths = doc.d_nums(dict.get("Widths"))
	_has_widths = not _widths.is_empty()
	var enc_v: Variant = doc.res(dict.get("Encoding"))
	_enc = []
	_enc.resize(256)
	_enc.fill("")
	if enc_v is Dictionary:
		var base := PdfEncodings.named(doc.d_name((enc_v as Dictionary).get("BaseEncoding")))
		if not base.is_empty():
			_enc = base.duplicate()
		var code := 0
		for item in doc.d_array((enc_v as Dictionary).get("Differences")):
			var v: Variant = doc.res(item)
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
				code = int(v)
			elif typeof(v) == TYPE_STRING_NAME:
				if code >= 0 and code < 256:
					_enc[code] = String(v)
				code += 1
	elif typeof(enc_v) == TYPE_STRING_NAME:
		var t := PdfEncodings.named(String(enc_v))
		if not t.is_empty():
			_enc = t.duplicate()


## The charproc stream of a Type 3 font's character code, or null.
func type3_proc(code: int) -> PdfStream:
	if code < 0 or code >= _enc.size():
		return null
	var nm: String = _enc[code]
	return t3_procs.get(nm)


# ------------------------------------------------------------------------------------------------ text

## The characters of a shown string: each {code, n (bytes), gid (-1 none), w (advance in em, before spacing), space (single byte 32), cid}.
func decode(s: PackedByteArray) -> Array:
	var out: Array = []
	var i := 0
	var n := s.size()
	if kind == "cid":
		while i < n:
			var cn := _cmap.next_code(s, i)
			var code := cn.x
			var cid := _cmap.cid_of(code)
			var w: float = float(_cw.get(cid, _dw)) / 1000.0
			out.append({"code": code, "n": cn.y, "gid": _gid_cid(cid, code), "w": w, "space": cn.y == 1 and code == 32, "cid": cid})
			i += cn.y
		return out
	for k in n:
		var code := s[k]
		var w := 0.0
		var idx := code - _first
		if _has_widths and idx >= 0 and idx < _widths.size():
			w = _widths[idx]
		elif _has_widths:
			w = _missing
		if kind == "type3":
			w *= t3_matrix.x.x if _has_widths else 0.0
			out.append({"code": code, "n": 1, "gid": code, "w": w, "space": code == 32, "cid": code})
			continue
		var gid := _gid_simple(code)
		if not _has_widths:
			var adv := program.advance(gid) if gid >= 0 else -1.0
			w = adv * 1000.0 if adv >= 0.0 else (_missing if _missing > 0.0 else 0.0)
		out.append({"code": code, "n": 1, "gid": gid, "w": w / 1000.0 if kind != "type3" else w, "space": code == 32, "cid": code})
	return out


## How much to stretch a stand-in glyph sideways so that it takes the room the original character had (1.0 for a real font).
func xscale(gid: int, width_em: float) -> float:
	if not substituted or gid < 0 or program == null or width_em <= 0.0:
		return 1.0
	var adv := program.advance(gid)
	if adv <= 0.01:
		return 1.0
	return clampf(width_em / adv, 0.75, 1.3)


## For vertical writing: the advance (em, negative = down) and the offset of the glyph origin from the writing origin.
func vertical_metrics(width_em: float) -> Dictionary:
	return {"advance": _dw2.y / 1000.0, "origin": Vector2(-width_em * 0.5, -_dw2.x / 1000.0)}
