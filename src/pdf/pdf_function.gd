class_name PdfFunction
extends RefCounted
## PDF functions (ISO 32000 7.10): sampled (type 0), exponential (2), stitching (3) and PostScript calculator (4). Colour spaces use them for
## tints and shadings for their colour ramps. A function maps m inputs to n outputs; evaluate() takes and returns plain arrays.

var type := -1
var domain := PackedFloat64Array()
var range_ := PackedFloat64Array()
var n_out := 1
var n_in := 1

# type 0
var _size := PackedInt32Array()
var _bps := 8
var _encode := PackedFloat64Array()
var _decode := PackedFloat64Array()
var _samples := PackedFloat32Array()       # all samples as 0..1, n_out per grid point
# type 2
var _c0 := PackedFloat64Array()
var _c1 := PackedFloat64Array()
var _exp := 1.0
# type 3
var _fns: Array = []
var _bounds := PackedFloat64Array()
var _enc3 := PackedFloat64Array()
# type 4
var _prog: Array = []                      # flat list of tokens: numbers (float) and operator strings; blocks as nested arrays


## A function from a function dictionary / stream, or an array of one-output functions (what shadings may carry). null when unreadable.
static func make(doc: PdfDoc, v: Variant) -> PdfFunction:
	v = doc.res(v)
	if v is Array:
		var parts: Array = []
		for x in v:
			var f := make(doc, x)
			if f == null:
				return null
			parts.append(f)
		var f2 := PdfFunction.new()
		f2.type = 100                                       # a bundle: one function per output
		f2._fns = parts
		f2.n_out = parts.size()
		f2.n_in = (parts[0] as PdfFunction).n_in if not parts.is_empty() else 1
		return f2
	var d := doc.d_dict(v)
	if d.is_empty():
		return null
	var f3 := PdfFunction.new()
	f3.type = doc.d_int(d.get("FunctionType"), -1)
	f3.domain = doc.d_nums(d.get("Domain"))
	f3.range_ = doc.d_nums(d.get("Range"))
	f3.n_in = maxi(f3.domain.size() / 2, 1)
	if f3.domain.size() < 2:
		f3.domain = PackedFloat64Array([0.0, 1.0])
	match f3.type:
		0:
			if not f3._init0(doc, d, v):
				return null
		2:
			f3._c0 = doc.d_nums(d.get("C0"), PackedFloat64Array([0.0]))
			f3._c1 = doc.d_nums(d.get("C1"), PackedFloat64Array([1.0]))
			f3._exp = doc.d_num(d.get("N"), 1.0)
			f3.n_out = maxi(f3._c0.size(), f3._c1.size())
		3:
			for x in doc.d_array(d.get("Functions")):
				var sub := make(doc, x)
				if sub == null:
					return null
				f3._fns.append(sub)
			f3._bounds = doc.d_nums(d.get("Bounds"))
			f3._enc3 = doc.d_nums(d.get("Encode"))
			if f3._fns.is_empty():
				return null
			f3.n_out = (f3._fns[0] as PdfFunction).n_out
		4:
			if not (v is PdfStream):
				return null
			f3.n_out = maxi(f3.range_.size() / 2, 1)
			var lex := PdfLex.new((v as PdfStream).decode())
			var tok: Variant = lex.next()
			if not (typeof(tok) == TYPE_STRING and tok == "{"):
				return null
			f3._prog = f3._read_block(lex)
		_:
			return null
	return f3


func _init0(doc: PdfDoc, d: Dictionary, v: Variant) -> bool:
	if not (v is PdfStream):
		return false
	var sz := doc.d_nums(d.get("Size"))
	if sz.is_empty():
		return false
	for x in sz:
		_size.append(maxi(int(x), 1))
	n_out = maxi(range_.size() / 2, 1)
	_bps = doc.d_int(d.get("BitsPerSample"), 8)
	_encode = doc.d_nums(d.get("Encode"))
	if _encode.is_empty():
		for i in n_in:
			_encode.append(0.0)
			_encode.append(float(_size[i] - 1))
	_decode = doc.d_nums(d.get("Decode"), range_)
	var data := (v as PdfStream).decode()
	var total := n_out
	for s in _size:
		total *= s
	if total > 4000000 or total <= 0:
		return false
	var maxv := float((1 << _bps) - 1)
	_samples.resize(total)
	var bitpos := 0
	for i in total:
		var val := 0
		var need := _bps
		while need > 0:
			var byte_i := bitpos >> 3
			if byte_i >= data.size():
				break
			var off := bitpos & 7
			var take := mini(8 - off, need)
			val = (val << take) | ((data[byte_i] >> (8 - off - take)) & ((1 << take) - 1))
			bitpos += take
			need -= take
		_samples[i] = float(val) / maxv
	return true


func _read_block(lex: PdfLex) -> Array:
	var out: Array = []
	while true:
		var t: Variant = lex.next()
		if typeof(t) == TYPE_STRING_NAME and t == PdfLex.END:
			break
		if typeof(t) == TYPE_STRING:
			if t == "{":
				out.append(_read_block(lex))
				continue
			if t == "}":
				break
			out.append(t)
		elif typeof(t) == TYPE_INT or typeof(t) == TYPE_FLOAT:
			out.append(float(t))
	return out


## The outputs for the inputs (arrays of floats), clipped to Domain and Range.
func evaluate(inputs: Array) -> Array:
	var x: Array = []
	for i in n_in:
		var v := float(inputs[i]) if i < inputs.size() else 0.0
		if domain.size() >= 2 * i + 2:
			v = clampf(v, domain[2 * i], domain[2 * i + 1])
		x.append(v)
	var out: Array = []
	match type:
		0:
			out = _eval0(x)
		2:
			out = _eval2(float(x[0]))
		3:
			out = _eval3(float(x[0]))
		4:
			out = _eval4(x)
		100:
			for f in _fns:
				var r: Array = (f as PdfFunction).evaluate(inputs)
				out.append(r[0] if not r.is_empty() else 0.0)
	if range_.size() >= 2:
		for i in out.size():
			if range_.size() >= 2 * i + 2:
				out[i] = clampf(float(out[i]), range_[2 * i], range_[2 * i + 1])
	return out


func _eval2(x: float) -> Array:
	var out: Array = []
	var xe := pow(x, _exp) if _exp != 1.0 else x
	for i in n_out:
		var a := _c0[i] if i < _c0.size() else 0.0
		var b := _c1[i] if i < _c1.size() else 1.0
		out.append(a + xe * (b - a))
	return out


func _eval3(x: float) -> Array:
	var k := _fns.size()
	var i := 0
	while i < k - 1 and i < _bounds.size() and x >= _bounds[i]:
		i += 1
	var lo := domain[0] if i == 0 else _bounds[i - 1]
	var hi := domain[1] if i >= _bounds.size() else _bounds[i]
	var e0 := _enc3[2 * i] if _enc3.size() > 2 * i + 1 else 0.0
	var e1 := _enc3[2 * i + 1] if _enc3.size() > 2 * i + 1 else 1.0
	var t := e0 if hi == lo else e0 + (x - lo) * (e1 - e0) / (hi - lo)
	return (_fns[i] as PdfFunction).evaluate([t])


func _eval0(x: Array) -> Array:
	# multilinear interpolation in the sample grid (for one or two inputs; more inputs use the nearest sample)
	var m := n_in
	var idx0 := PackedInt32Array()
	var frac := PackedFloat64Array()
	for i in m:
		var d0 := domain[2 * i]
		var d1 := domain[2 * i + 1]
		var e := _encode[2 * i] + (float(x[i]) - d0) * (_encode[2 * i + 1] - _encode[2 * i]) / (d1 - d0) if d1 != d0 else _encode[2 * i]
		e = clampf(e, 0.0, float(_size[i] - 1))
		var f := floorf(e)
		idx0.append(int(f))
		frac.append(e - f)
	var out: Array = []
	var corners := 1 << mini(m, 4)
	for o in n_out:
		var acc := 0.0
		for c in corners:
			var wgt := 1.0
			var off := 0
			var stride := 1
			for i in m:
				var bit := (c >> i) & 1 if i < 4 else 0
				var ii := mini(idx0[i] + bit, _size[i] - 1)
				wgt *= frac[i] if bit == 1 else 1.0 - frac[i]
				off += ii * stride
				stride *= _size[i]
			if wgt > 0.0:
				acc += wgt * _samples[off * n_out + o]
		var dec0 := _decode[2 * o] if _decode.size() > 2 * o + 1 else 0.0
		var dec1 := _decode[2 * o + 1] if _decode.size() > 2 * o + 1 else 1.0
		out.append(dec0 + acc * (dec1 - dec0))
	return out


func _eval4(x: Array) -> Array:
	var st: Array = x.duplicate()
	_run(_prog, st, 0)
	var out: Array = []
	var n := n_out
	var start := maxi(st.size() - n, 0)
	for i in range(start, st.size()):
		out.append(float(st[i]))
	while out.size() < n:
		out.push_front(0.0)
	return out


func _run(prog: Array, st: Array, depth: int) -> void:
	if depth > 16:
		return
	var i := 0
	while i < prog.size():
		var t: Variant = prog[i]
		i += 1
		if typeof(t) == TYPE_FLOAT:
			st.append(t)
			continue
		if typeof(t) == TYPE_ARRAY:
			# a block: "if" or "ifelse" follows
			var next: Variant = prog[i] if i < prog.size() else null
			if typeof(next) == TYPE_ARRAY and i + 1 < prog.size() and prog[i + 1] == "ifelse":
				var cond := _pop(st)
				_run(t if cond != 0.0 else next, st, depth + 1)
				i += 2
			elif typeof(next) == TYPE_STRING and next == "if":
				var cond2 := _pop(st)
				if cond2 != 0.0:
					_run(t, st, depth + 1)
				i += 1
			continue
		_op(String(t), st)


static func _pop(st: Array) -> float:
	return float(st.pop_back()) if not st.is_empty() else 0.0


func _op(op: String, st: Array) -> void:
	match op:
		"add":
			var b := _pop(st)
			st.append(_pop(st) + b)
		"sub":
			var b2 := _pop(st)
			st.append(_pop(st) - b2)
		"mul":
			var b3 := _pop(st)
			st.append(_pop(st) * b3)
		"div":
			var b4 := _pop(st)
			var a4 := _pop(st)
			st.append(a4 / b4 if b4 != 0.0 else 0.0)
		"idiv":
			var b5 := int(_pop(st))
			var a5 := int(_pop(st))
			st.append(float(a5 / b5) if b5 != 0 else 0.0)
		"mod":
			var b6 := int(_pop(st))
			var a6 := int(_pop(st))
			st.append(float(a6 % b6) if b6 != 0 else 0.0)
		"neg":
			st.append(-_pop(st))
		"abs":
			st.append(absf(_pop(st)))
		"ceiling":
			st.append(ceilf(_pop(st)))
		"floor":
			st.append(floorf(_pop(st)))
		"round":
			st.append(floorf(_pop(st) + 0.5))
		"truncate":
			st.append(float(int(_pop(st))))
		"sqrt":
			st.append(sqrt(maxf(_pop(st), 0.0)))
		"sin":
			st.append(sin(deg_to_rad(_pop(st))))
		"cos":
			st.append(cos(deg_to_rad(_pop(st))))
		"atan":
			var den := _pop(st)
			var num := _pop(st)
			var a := rad_to_deg(atan2(num, den))
			st.append(a + 360.0 if a < 0.0 else a)
		"exp":
			var e := _pop(st)
			st.append(pow(_pop(st), e))
		"ln":
			st.append(log(maxf(_pop(st), 1e-300)))
		"log":
			st.append(log(maxf(_pop(st), 1e-300)) / log(10.0))
		"cvi":
			st.append(float(int(_pop(st))))
		"cvr":
			pass
		"eq":
			var b7 := _pop(st)
			st.append(1.0 if _pop(st) == b7 else 0.0)
		"ne":
			var b8 := _pop(st)
			st.append(1.0 if _pop(st) != b8 else 0.0)
		"gt":
			var b9 := _pop(st)
			st.append(1.0 if _pop(st) > b9 else 0.0)
		"ge":
			var b10 := _pop(st)
			st.append(1.0 if _pop(st) >= b10 else 0.0)
		"lt":
			var b11 := _pop(st)
			st.append(1.0 if _pop(st) < b11 else 0.0)
		"le":
			var b12 := _pop(st)
			st.append(1.0 if _pop(st) <= b12 else 0.0)
		"and":
			var b13 := int(_pop(st))
			st.append(float(int(_pop(st)) & b13))
		"or":
			var b14 := int(_pop(st))
			st.append(float(int(_pop(st)) | b14))
		"xor":
			var b15 := int(_pop(st))
			st.append(float(int(_pop(st)) ^ b15))
		"not":
			var v := _pop(st)
			st.append(1.0 if v == 0.0 else 0.0)
		"bitshift":
			var sh := int(_pop(st))
			var val := int(_pop(st))
			st.append(float(val << sh) if sh >= 0 else float(val >> -sh))
		"true":
			st.append(1.0)
		"false":
			st.append(0.0)
		"pop":
			_pop(st)
		"exch":
			if st.size() >= 2:
				var t: Variant = st[st.size() - 1]
				st[st.size() - 1] = st[st.size() - 2]
				st[st.size() - 2] = t
		"dup":
			if not st.is_empty():
				st.append(st[st.size() - 1])
		"copy":
			var n := int(_pop(st))
			if n > 0 and n <= st.size():
				st.append_array(st.slice(st.size() - n))
		"index":
			var ix := int(_pop(st))
			if ix >= 0 and ix < st.size():
				st.append(st[st.size() - 1 - ix])
		"roll":
			var j := int(_pop(st))
			var nn := int(_pop(st))
			if nn > 0 and nn <= st.size():
				var part: Array = st.slice(st.size() - nn)
				st.resize(st.size() - nn)
				j = ((j % nn) + nn) % nn
				for k in nn:
					st.append(part[(k - j + nn) % nn])
