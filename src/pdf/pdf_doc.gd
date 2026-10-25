class_name PdfDoc
extends RefCounted
## A PDF file read into objects: the cross-reference chain (tables, streams, object streams, incremental updates; rebuilt by scanning when
## it is damaged), decryption of documents that open without a password, and the page tree.
##
## Objects are plain values (see PdfLex). Use res() to follow a reference, and the d_* helpers to read a field with a default.

const MAX_PAGES := 20000

var data := PackedByteArray()
var trailer: Dictionary = {}
var error := ""
var crypt: PdfCrypt = null
var rebuilt := false

var _xref: Dictionary = {}                 # object number -> {t: 1, off, gen} | {t: 2, stm, idx}
var _cache: Dictionary = {}                # object number -> value
var _objstm: Dictionary = {}               # stream number -> {pos: Array of [num, offset], first, lex}
var _loading: Dictionary = {}              # object numbers being read (a reference loop must end)
var _pages: Array = []                     # leaf page dictionaries, in order, with inherited fields (built once)
var _pages_built := false


## Reads a file. `error` is set when it is not a PDF this engine can open (check ok()).
static func open(bytes: PackedByteArray) -> PdfDoc:
	var d := PdfDoc.new()
	d._open(bytes)
	return d


func ok() -> bool:
	return error == ""


func _open(bytes: PackedByteArray) -> void:
	var head_at := _find(bytes, "%PDF-", 0, mini(bytes.size(), 4096))
	if head_at < 0:
		error = "That file is not a PDF."
		return
	data = bytes.slice(head_at) if head_at > 0 else bytes
	var good := _read_xref_chain()
	if good:
		good = _check_root()
	if not good:
		_rebuild()
		if not _check_root():
			if error == "":
				error = "This PDF is damaged and cannot be read."
			return
	var enc: Variant = trailer.get("Encrypt")
	if enc != null:
		_setup_crypt(enc)
		if error != "":
			return
	if page_count() <= 0:
		error = "This PDF has no pages."


func _check_root() -> bool:
	var root: Variant = res(trailer.get("Root"))
	if not (root is Dictionary):
		return false
	var pages: Variant = res((root as Dictionary).get("Pages"))
	return pages is Dictionary


func _setup_crypt(enc_ref: Variant) -> void:
	var enc: Variant = res(enc_ref)
	if not (enc is Dictionary):
		return
	var id0 := PackedByteArray()
	var ids: Variant = res(trailer.get("ID"))
	if ids is Array and (ids as Array).size() > 0:
		var s: Variant = res((ids as Array)[0])
		if s is PackedByteArray:
			id0 = s
	# the Encrypt dictionary's own strings are never encrypted: they were read before the key existed
	var c := PdfCrypt.create(enc, id0)
	if not c.ok:
		error = c.error if c.error != "" else "This PDF is encrypted in a way the viewer cannot open."
		return
	crypt = c
	_cache.clear()                           # everything read so far had undecrypted strings
	_objstm.clear()
	_pages_built = false
	_pages.clear()
	if enc_ref is Vector2i:
		_cache[(enc_ref as Vector2i).x] = enc


# ------------------------------------------------------------------------------------------------ cross-reference

func _read_xref_chain() -> bool:
	var tail_from := maxi(data.size() - 2048, 0)
	var sx := _rfind(data, "startxref", data.size(), tail_from)
	if sx < 0:
		sx = _rfind(data, "startxref", data.size(), 0)
	if sx < 0:
		return false
	var lex := PdfLex.new(data, sx + 9)
	var first: Variant = lex.next()
	if typeof(first) != TYPE_INT:
		return false
	var seen := {}
	var queue: Array = [int(first)]
	var got_trailer := false
	while not queue.is_empty():
		var at: int = queue.pop_front()
		if at <= 0 or at >= data.size() or seen.has(at):
			continue
		seen[at] = true
		var t: Variant = _read_xref_section(at)
		if t == null:
			return false
		var td: Dictionary = t
		if not got_trailer:
			trailer = td.duplicate()
			got_trailer = true
		else:
			for k in td:                      # an older trailer only fills in what the newer one lacks
				if not trailer.has(k):
					trailer[k] = td[k]
		if td.has("XRefStm") and typeof(td["XRefStm"]) == TYPE_INT:
			queue.append(int(td["XRefStm"]))
		if td.has("Prev") and typeof(td["Prev"]) in [TYPE_INT, TYPE_FLOAT]:
			queue.append(int(td["Prev"]))
	return got_trailer and trailer.has("Root")


## One cross-reference section (a table or a stream) at `at`; its trailer dictionary, or null when it cannot be read.
func _read_xref_section(at: int) -> Variant:
	var lex := PdfLex.new(data, at)
	lex.skip_ws()
	if lex.spells(lex.p, "xref"):
		lex.p += 4
		return _read_table(lex)
	var n: Variant = lex.next()
	var g: Variant = lex.next()
	var o: Variant = lex.next()
	if typeof(n) != TYPE_INT or typeof(g) != TYPE_INT or typeof(o) != TYPE_STRING or o != "obj":
		return null
	var obj: Variant = _read_body(lex, int(n), int(g), false)
	if not (obj is PdfStream):
		return null
	var st: PdfStream = obj
	if str(st.dict.get("Type", "")) != "XRef":
		return null
	var bytes := st.decode()
	var w: Array = st.dict.get("W", [])
	if w.size() < 3 or bytes.is_empty():
		return null
	var w0 := int(w[0])
	var w1 := int(w[1])
	var w2 := int(w[2])
	var rec := w0 + w1 + w2
	if rec <= 0:
		return null
	var size := int(st.dict.get("Size", 0))
	var index: Array = st.dict.get("Index", [0, size])
	var pos := 0
	var i := 0
	while i + 1 < index.size():
		var start := int(index[i])
		var count := int(index[i + 1])
		for k in count:
			if pos + rec > bytes.size():
				break
			var f0 := _be(bytes, pos, w0) if w0 > 0 else 1
			var f1 := _be(bytes, pos + w0, w1)
			var f2 := _be(bytes, pos + w0 + w1, w2)
			pos += rec
			var num := start + k
			if _xref.has(num):
				continue                                 # a newer section already said what this object is
			match f0:
				1:
					_xref[num] = {"t": 1, "off": f1, "gen": f2}
				2:
					_xref[num] = {"t": 2, "stm": f1, "idx": f2}
				0:
					_xref[num] = {"t": 0}
		i += 2
	return st.dict


func _read_table(lex: PdfLex) -> Variant:
	while true:
		lex.skip_ws()
		if lex.spells(lex.p, "trailer"):
			lex.p += 7
			var t: Variant = lex.object()
			return t if t is Dictionary else null
		var a: Variant = lex.next()
		var b: Variant = lex.next()
		if typeof(a) != TYPE_INT or typeof(b) != TYPE_INT:
			return null
		var start := int(a)
		var count := int(b)
		for k in count:
			var off: Variant = lex.next()
			var gen: Variant = lex.next()
			var kind: Variant = lex.next()
			if typeof(off) != TYPE_INT or typeof(gen) != TYPE_INT or typeof(kind) != TYPE_STRING:
				return null
			var num := start + k
			if _xref.has(num):
				continue
			if kind == "n":
				_xref[num] = {"t": 1, "off": int(off), "gen": int(gen)}
			else:
				_xref[num] = {"t": 0}
	return null


static func _be(bytes: PackedByteArray, at: int, n: int) -> int:
	var v := 0
	for i in n:
		v = (v << 8) | bytes[at + i]
	return v


## The cross-reference is gone or wrong: read the whole file for "n g obj" and for trailers.
func _rebuild() -> void:
	rebuilt = true
	_xref.clear()
	_cache.clear()
	_objstm.clear()
	trailer = {}
	var found_root := Vector2i(-1, 0)
	var i := 0
	var n := data.size()
	var lex := PdfLex.new(data)
	while i < n:
		i = data.find(106, i)                          # 'j' of "obj" / "endobj" (the first letter of "obj" is 'o'; searching 'j' skips most text)
		if i < 0:
			break
		# "obj": 'o','b','j' -> i is at 'j', so "ob" precede it
		if i >= 2 and data[i - 1] == 98 and data[i - 2] == 111 and (i + 1 >= n or PdfLex._cls[data[i + 1]] & (PdfLex.WS | PdfLex.DELIM)):
			if i >= 6 and data[i - 3] == 100 and data[i - 4] == 110 and data[i - 5] == 101:
				i += 1                                 # "endobj"
				continue
			var j := i - 3
			while j >= 0 and (PdfLex._cls[data[j]] & PdfLex.WS):
				j -= 1
			var gend := j
			while j >= 0 and (PdfLex._cls[data[j]] & PdfLex.NUM):
				j -= 1
			var gstart := j + 1
			while j >= 0 and (PdfLex._cls[data[j]] & PdfLex.WS):
				j -= 1
			var nend := j
			while j >= 0 and (PdfLex._cls[data[j]] & PdfLex.NUM):
				j -= 1
			var nstart := j + 1
			if gstart <= gend and nstart <= nend and (nstart == 0 or PdfLex._cls[data[nstart - 1]] & (PdfLex.WS | PdfLex.DELIM)):
				var num := data.slice(nstart, nend + 1).get_string_from_ascii().to_int()
				var gen := data.slice(gstart, gend + 1).get_string_from_ascii().to_int()
				_xref[num] = {"t": 1, "off": nstart, "gen": gen}      # later definitions win: they are the newer ones
		i += 1
	# trailers
	var at := 0
	while true:
		at = lex.find_word("trailer", at)
		if at < 0:
			break
		lex.p = at + 7
		var t: Variant = lex.object()
		if t is Dictionary:
			var td: Dictionary = t
			for k in td:
				trailer[k] = td[k]
		at += 7
	# object streams and cross-reference streams carry more objects and sometimes the trailer
	for num in _xref.keys():
		var e: Dictionary = _xref[num]
		if int(e.t) != 1:
			continue
		var l2 := PdfLex.new(data, int(e.off))
		l2.next()
		l2.next()
		l2.next()
		l2.skip_ws()
		if l2.at_end() or data[l2.p] != 60:
			continue
		var d: Variant = l2.object()
		if not (d is Dictionary):
			continue
		var typ := str((d as Dictionary).get("Type", ""))
		if typ == "XRef":
			for k in (d as Dictionary):
				if not trailer.has(k):
					trailer[k] = (d as Dictionary)[k]
		elif typ == "ObjStm":
			var o: Variant = get_obj(int(num))
			if o is PdfStream:
				_index_objstm(int(num), o)
		elif typ == "Catalog" and found_root.x < 0:
			found_root = Vector2i(int(num), int(e.gen))
	if not trailer.has("Root") and found_root.x >= 0:
		trailer["Root"] = found_root


func _index_objstm(stm_num: int, st: PdfStream) -> void:
	var info := _objstm_info(stm_num, st)
	if info.is_empty():
		return
	var k := 0
	for pair in info.pos:
		var num: int = pair[0]
		if not _xref.has(num) or int((_xref[num] as Dictionary).t) != 1:
			_xref[num] = {"t": 2, "stm": stm_num, "idx": k}
		k += 1


# ------------------------------------------------------------------------------------------------ objects

## The object with this number (null when there is none).
func get_obj(num: int) -> Variant:
	if _cache.has(num):
		return _cache[num]
	var e: Variant = _xref.get(num)
	if e == null or int((e as Dictionary).t) == 0:
		return null
	if _loading.has(num):
		return null
	_loading[num] = true
	var v: Variant = null
	if int(e.t) == 1:
		v = _read_at(int(e.off), num)
	else:
		v = _read_from_stream(int(e.stm), int(e.idx), num)
	_loading.erase(num)
	_cache[num] = v
	return v


## Follows references until a real value turns up.
func res(v: Variant) -> Variant:
	var guard := 0
	while typeof(v) == TYPE_VECTOR2I and guard < 32:
		v = get_obj((v as Vector2i).x)
		guard += 1
	return v


func _read_at(off: int, num: int) -> Variant:
	if off < 0 or off >= data.size():
		return null
	var lex := PdfLex.new(data, off)
	var n: Variant = lex.next()
	var g: Variant = lex.next()
	var o: Variant = lex.next()
	if typeof(n) != TYPE_INT or typeof(g) != TYPE_INT or typeof(o) != TYPE_STRING or o != "obj" or int(n) != num:
		if not rebuilt:
			# the table pointed at the wrong place: look the object up by scanning once
			_rebuild()
			var e: Variant = _xref.get(num)
			if e != null and int((e as Dictionary).t) == 1 and int((e as Dictionary).off) != off:
				return _read_at(int((e as Dictionary).off), num)
		return null
	return _read_body(lex, int(n), int(g), true)


## The object after "n g obj": a value, or a stream when "stream" follows a dictionary. Strings are decrypted when the file is.
func _read_body(lex: PdfLex, num: int, gen: int, decrypt: bool) -> Variant:
	var v: Variant = lex.object()
	if v is Dictionary:
		var save := lex.p
		lex.skip_ws()
		if lex.spells(lex.p, "stream"):
			var st := _read_stream(lex, v, num, gen)
			if decrypt and crypt != null:
				_decrypt_strings(st.dict, num, gen)
			return st
		lex.p = save
	if decrypt and crypt != null:
		v = _decrypt_strings(v, num, gen)
	return v


func _read_stream(lex: PdfLex, dict: Dictionary, num: int, gen: int) -> PdfStream:
	var st := PdfStream.new()
	st.dict = dict
	st.num = num
	st.gen = gen
	st.raw = data
	st.crypt = crypt
	var p := lex.p + 6
	if p < data.size() and data[p] == 13:
		p += 1
		if p < data.size() and data[p] == 10:
			p += 1
	elif p < data.size() and data[p] == 10:
		p += 1
	var length := -1
	var lv: Variant = dict.get("Length")
	if typeof(lv) == TYPE_VECTOR2I:
		lv = res(lv)
	if typeof(lv) == TYPE_INT:
		length = int(lv)
	var ok_len := false
	if length >= 0 and p + length <= data.size():
		var q := p + length
		while q < data.size() and (PdfLex._cls[data[q]] & PdfLex.WS):
			q += 1
		ok_len = lex.spells(q, "endstream")
	if not ok_len:
		var e := lex.find_word("endstream", p)
		if e < 0:
			e = lex.find_word("endobj", p)
		if e < 0:
			e = data.size()
		length = e - p
		# the end of line before "endstream" is not data
		if length > 0 and data[p + length - 1] == 10:
			length -= 1
		if length > 0 and data[p + length - 1] == 13:
			length -= 1
	st.off = p
	st.length = maxi(length, 0)
	# the filter entries may be references: settle them now so that the stream stands on its own
	for key in ["Filter", "F", "DecodeParms", "DP"]:
		if dict.has(key):
			dict[key] = _deep(dict[key])
	return st


## References inside a small value replaced by what they point to (one level of arrays and dictionaries).
func _deep(v: Variant) -> Variant:
	v = res(v)
	if v is Array:
		var out: Array = []
		for x in v:
			out.append(res(x))
		return out
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = res(v[k])
		return d
	return v


func _decrypt_strings(v: Variant, num: int, gen: int) -> Variant:
	match typeof(v):
		TYPE_PACKED_BYTE_ARRAY:
			return crypt.decrypt_string(v, num, gen)
		TYPE_ARRAY:
			var a: Array = v
			for i in a.size():
				a[i] = _decrypt_strings(a[i], num, gen)
			return a
		TYPE_DICTIONARY:
			var d: Dictionary = v
			for k in d.keys():
				d[k] = _decrypt_strings(d[k], num, gen)
			return d
	return v


func _objstm_info(stm_num: int, st: PdfStream) -> Dictionary:
	if _objstm.has(stm_num):
		return _objstm[stm_num]
	var bytes := st.decode()
	var n := int(st.dict.get("N", 0))
	var first := int(st.dict.get("First", 0))
	var info := {}
	if bytes.is_empty() or n <= 0:
		_objstm[stm_num] = info
		return info
	var lex := PdfLex.new(bytes)
	var pos: Array = []
	for i in n:
		var a: Variant = lex.next()
		var b: Variant = lex.next()
		if typeof(a) != TYPE_INT or typeof(b) != TYPE_INT:
			break
		pos.append([int(a), int(b)])
	info = {"pos": pos, "first": first, "bytes": bytes}
	_objstm[stm_num] = info
	return info


func _read_from_stream(stm_num: int, idx: int, num: int) -> Variant:
	var st: Variant = get_obj(stm_num)
	if not (st is PdfStream):
		return null
	var info := _objstm_info(stm_num, st)
	if info.is_empty():
		return null
	var pos: Array = info.pos
	if idx < 0 or idx >= pos.size() or int((pos[idx] as Array)[0]) != num:
		idx = -1
		for k in pos.size():
			if int((pos[k] as Array)[0]) == num:
				idx = k
				break
		if idx < 0:
			return null
	var lex := PdfLex.new(info.bytes, int(info.first) + int((pos[idx] as Array)[1]))
	return lex.object()


# ------------------------------------------------------------------------------------------------ helpers for reading fields

func d_dict(v: Variant) -> Dictionary:
	v = res(v)
	if v is Dictionary:
		return v
	if v is PdfStream:
		return (v as PdfStream).dict
	return {}


func d_array(v: Variant) -> Array:
	v = res(v)
	return v if v is Array else []


func d_num(v: Variant, fallback: float = 0.0) -> float:
	v = res(v)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return float(v)
	return fallback


func d_int(v: Variant, fallback: int = 0) -> int:
	v = res(v)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v)
	return fallback


func d_name(v: Variant, fallback: String = "") -> String:
	v = res(v)
	if typeof(v) == TYPE_STRING_NAME:
		return String(v)
	return fallback


func d_bool(v: Variant, fallback: bool = false) -> bool:
	v = res(v)
	if typeof(v) == TYPE_BOOL:
		return v
	return fallback


func d_stream(v: Variant) -> PdfStream:
	v = res(v)
	return v if v is PdfStream else null


## An array of numbers (references followed), or `fallback`.
func d_nums(v: Variant, fallback: PackedFloat64Array = PackedFloat64Array()) -> PackedFloat64Array:
	var a: Variant = res(v)
	if not (a is Array):
		return fallback
	var out := PackedFloat64Array()
	for x in a:
		var r: Variant = res(x)
		if typeof(r) == TYPE_INT or typeof(r) == TYPE_FLOAT:
			out.append(float(r))
		else:
			out.append(0.0)
	return out


# ------------------------------------------------------------------------------------------------ pages

func page_count() -> int:
	_build_pages()
	return _pages.size()


## The page dictionary with the fields a page inherits (Resources, MediaBox, CropBox, Rotate) filled in. Index from 0. {} when out of range.
func page(i: int) -> Dictionary:
	_build_pages()
	if i < 0 or i >= _pages.size():
		return {}
	return _pages[i]


func _build_pages() -> void:
	if _pages_built:
		return
	_pages_built = true
	var root := d_dict(trailer.get("Root"))
	var top: Variant = root.get("Pages")
	var seen := {}
	_walk(top, {}, seen, 0)


func _walk(node_ref: Variant, inherited: Dictionary, seen: Dictionary, depth: int) -> void:
	if _pages.size() >= MAX_PAGES or depth > 64:
		return
	if typeof(node_ref) == TYPE_VECTOR2I:
		var k := (node_ref as Vector2i).x
		if seen.has(k):
			return
		seen[k] = true
	var node := d_dict(node_ref)
	if node.is_empty():
		return
	var inh := inherited.duplicate()
	for key in ["Resources", "MediaBox", "CropBox", "Rotate"]:
		if node.has(key):
			inh[key] = node[key]
	var kids: Variant = res(node.get("Kids"))
	var typ := d_name(node.get("Type"))
	if kids is Array and (typ == "Pages" or typ == "" or not node.has("Contents")):
		for kid in kids:
			_walk(kid, inh, seen, depth + 1)
		return
	var pg := node.duplicate()
	for key in inh:
		if not pg.has(key):
			pg[key] = inh[key]
	pg["__ref"] = node_ref if typeof(node_ref) == TYPE_VECTOR2I else Vector2i(-1, 0)
	_pages.append(pg)


# ------------------------------------------------------------------------------------------------ byte searching

## First index of `word` in bytes[from, stop), or -1.
static func _find(bytes: PackedByteArray, word: String, from: int, stop: int) -> int:
	var first := word.unicode_at(0)
	var i := from
	var limit := mini(stop, bytes.size()) - word.length()
	while i <= limit:
		i = bytes.find(first, i)
		if i < 0 or i > limit:
			return -1
		var hit := true
		for k in range(1, word.length()):
			if bytes[i + k] != word.unicode_at(k):
				hit = false
				break
		if hit:
			return i
		i += 1
	return -1


## Last index of `word` that starts before `before` and not before `floor_at`, or -1.
static func _rfind(bytes: PackedByteArray, word: String, before: int, floor_at: int) -> int:
	var first := word.unicode_at(0)
	var i := mini(before, bytes.size()) - word.length()
	while i >= floor_at:
		i = bytes.rfind(first, i)
		if i < floor_at:
			return -1
		var hit := true
		for k in range(1, word.length()):
			if bytes[i + k] != word.unicode_at(k):
				hit = false
				break
		if hit:
			return i
		i -= 1
	return -1
