class_name PdfInflate
extends RefCounted
## A plain-script inflate (after zlib's puff). The engine's own decoder is used first; this one runs only when that gives up on a
## damaged or cut-short stream, because it hands back whatever could be read before the damage.

const LBASE := [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
const LEXT := [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
const DBASE := [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
const DEXT := [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
const ORDER := [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

var _in: PackedByteArray
var _pos := 0
var _bitbuf := 0
var _bitcnt := 0
var _out := PackedByteArray()
var _failed := false


static func inflate(data: PackedByteArray, zlib_header: bool = true) -> PackedByteArray:
	var z := PdfInflate.new()
	z._in = data
	if zlib_header and data.size() >= 2 and (data[0] & 0x0F) == 8 and ((data[0] << 8) | data[1]) % 31 == 0:
		z._pos = 2
		if data[1] & 0x20:
			z._pos += 4
	z._run()
	return z._out


func _run() -> void:
	var last := false
	while not last and not _failed:
		last = _bits(1) == 1
		var type := _bits(2)
		match type:
			0:
				_stored()
			1:
				_block(_fixed_lit(), _fixed_dist())
			2:
				_dynamic()
			_:
				_failed = true


func _bits(n: int) -> int:
	while _bitcnt < n:
		if _pos >= _in.size():
			_failed = true
			return 0
		_bitbuf |= _in[_pos] << _bitcnt
		_pos += 1
		_bitcnt += 8
	var v := _bitbuf & ((1 << n) - 1)
	_bitbuf >>= n
	_bitcnt -= n
	return v


func _stored() -> void:
	_bitbuf = 0
	_bitcnt = 0
	if _pos + 4 > _in.size():
		_failed = true
		return
	var n := _in[_pos] | (_in[_pos + 1] << 8)
	var nn := _in[_pos + 2] | (_in[_pos + 3] << 8)
	if (n ^ nn) != 0xFFFF:
		_failed = true                                # the length and its complement do not match: this is not a stored block
		return
	_pos += 4
	var take := mini(n, _in.size() - _pos)
	_out.append_array(_in.slice(_pos, _pos + take))
	_pos += take
	if take < n:
		_failed = true


## A canonical Huffman code as [counts per length, symbols in code order].
func _build(lengths: PackedInt32Array) -> Array:
	var count := PackedInt32Array()
	count.resize(16)
	for l in lengths:
		count[l] += 1
	count[0] = 0
	var offs := PackedInt32Array()
	offs.resize(16)
	for i in range(1, 15):
		offs[i + 1] = offs[i] + count[i]
	var syms := PackedInt32Array()
	syms.resize(lengths.size())
	for s in lengths.size():
		if lengths[s] != 0:
			syms[offs[lengths[s]]] = s
			offs[lengths[s]] += 1
	return [count, syms]


func _decode(h: Array) -> int:
	var count: PackedInt32Array = h[0]
	var syms: PackedInt32Array = h[1]
	var code := 0
	var first := 0
	var index := 0
	for l in range(1, 16):
		code |= _bits(1)
		if _failed:
			return -1
		var c := count[l]
		if code - c < first:
			return syms[index + (code - first)]
		index += c
		first += c
		first <<= 1
		code <<= 1
	_failed = true
	return -1


func _fixed_lit() -> Array:
	var l := PackedInt32Array()
	l.resize(288)
	for i in 288:
		l[i] = 8 if i < 144 else (9 if i < 256 else (7 if i < 280 else 8))
	return _build(l)


func _fixed_dist() -> Array:
	var l := PackedInt32Array()
	l.resize(30)
	l.fill(5)
	return _build(l)


func _dynamic() -> void:
	var nlen := _bits(5) + 257
	var ndist := _bits(5) + 1
	var ncode := _bits(4) + 4
	if _failed or nlen > 286 or ndist > 30:
		_failed = true
		return
	var lengths := PackedInt32Array()
	lengths.resize(19)
	for i in ncode:
		lengths[ORDER[i]] = _bits(3)
	var lencode := _build(lengths)
	var all := PackedInt32Array()
	all.resize(nlen + ndist)
	var i := 0
	while i < nlen + ndist and not _failed:
		var sym := _decode(lencode)
		if sym < 0:
			return
		if sym < 16:
			all[i] = sym
			i += 1
		else:
			var prev := 0
			var rep := 0
			if sym == 16:
				if i == 0:
					_failed = true
					return
				prev = all[i - 1]
				rep = 3 + _bits(2)
			elif sym == 17:
				rep = 3 + _bits(3)
			else:
				rep = 11 + _bits(7)
			if i + rep > nlen + ndist:
				_failed = true
				return
			for k in rep:
				all[i] = prev
				i += 1
	if _failed:
		return
	_block(_build(all.slice(0, nlen)), _build(all.slice(nlen)))


func _block(lit: Array, dist: Array) -> void:
	while not _failed:
		var sym := _decode(lit)
		if sym < 0:
			return
		if sym < 256:
			_out.append(sym)
		elif sym == 256:
			return
		else:
			sym -= 257
			if sym >= 29:
				_failed = true
				return
			var len: int = LBASE[sym] + _bits(LEXT[sym])
			var ds := _decode(dist)
			if _failed or ds < 0 or ds >= 30:
				_failed = true
				return
			var d: int = DBASE[ds] + _bits(DEXT[ds])
			if _failed or d > _out.size():
				_failed = true
				return
			var at := _out.size() - d
			if d >= len:
				_out.append_array(_out.slice(at, at + len))
			else:
				for k in len:
					_out.append(_out[at + k])
