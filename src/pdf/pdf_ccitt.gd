class_name PdfCcitt
extends RefCounted
## CCITT Group 3 and Group 4 fax decoding (ITU-T T.4 / T.6): scanned pages are very often stored this way, one bit per pixel. decode() returns the rows
## as packed 1-bit samples the way a PDF image wants them (0 = black unless the filter says BlackIs1), or an empty array when nothing could be read.
##
## A row is kept as the list of positions where the colour changes (white to black at even places, black to white at odd ones), which is what the
## two-dimensional codes talk about: each is a move relative to the changes of the row above.

const PASS := 1
const HORIZ := 2
const V0 := 3
const VR1 := 4
const VR2 := 5
const VR3 := 6
const VL1 := 7
const VL2 := 8
const VL3 := 9

static var _white := PackedInt32Array()         # indexed by the next 12 bits: (code length << 16) | run, 0 where no code starts
static var _black := PackedInt32Array()         # the next 13 bits
static var _modes := PackedInt32Array()         # the next 7 bits: (code length << 8) | mode, 0 where there is none (end of block, errors)

var _data := PackedByteArray()
var _size := 0
var _pos := 0
var _acc := 0
var _nbits := 0
var _columns := 1728


static func _build() -> void:
	if not _white.is_empty():
		return
	_white = _table(PdfCcittData.WHITE, 12)
	_black = _table(PdfCcittData.BLACK, 13)
	var modes := PackedInt32Array()
	modes.resize(128)
	for x in 128:
		var e := 0
		if x >> 6 == 1:
			e = (1 << 8) | V0
		elif x >> 4 == 0b011:
			e = (3 << 8) | VR1
		elif x >> 4 == 0b010:
			e = (3 << 8) | VL1
		elif x >> 4 == 0b001:
			e = (3 << 8) | HORIZ
		elif x >> 3 == 0b0001:
			e = (4 << 8) | PASS
		elif x >> 1 == 0b000011:
			e = (6 << 8) | VR2
		elif x >> 1 == 0b000010:
			e = (6 << 8) | VL2
		elif x == 0b0000011:
			e = (7 << 8) | VR3
		elif x == 0b0000010:
			e = (7 << 8) | VL3
		modes[x] = e
	_modes = modes


static func _table(codes: Array, bits: int) -> PackedInt32Array:
	var t := PackedInt32Array()
	t.resize(1 << bits)
	for c in codes:
		var len: int = c[0]
		var base: int = int(c[1]) << (bits - len)
		var entry: int = (len << 16) | int(c[2])
		for i in 1 << (bits - len):
			t[base + i] = entry
	return t


## `parms` are the filter's /DecodeParms (K, Columns, Rows, BlackIs1, EncodedByteAlign, EndOfLine, EndOfBlock); the picture is `w` x `h`.
static func decode(data: PackedByteArray, parms: Dictionary, w: int, h: int) -> PackedByteArray:
	if data.is_empty() or w <= 0 or h <= 0:
		return PackedByteArray()
	_build()
	var d := PdfCcitt.new()
	return d._decode(data, parms, w, h)


func _decode(data: PackedByteArray, parms: Dictionary, w: int, h: int) -> PackedByteArray:
	_data = data
	_size = data.size()
	var k := int(parms.get("K", 0))
	_columns = int(parms.get("Columns", 1728))
	if _columns <= 0 or _columns > 1 << 20:
		return PackedByteArray()
	var black_is_1 := _flag(parms, "BlackIs1", false)
	var byte_align := _flag(parms, "EncodedByteAlign", false)
	var end_of_line := _flag(parms, "EndOfLine", false)
	var stride := (w + 7) / 8
	var out := PackedByteArray()
	out.resize(stride * h)
	out.fill(0x00 if black_is_1 else 0xFF)
	var ref := _blank(PackedInt32Array())
	var cur := PackedInt32Array()
	var next_2d := k < 0
	if k >= 0:
		_eol()                                               # a line may start with the end-of-line code (and zero fill before it)
		if k > 0:
			next_2d = _peek(1) == 0
			_nbits -= 1
	var rows_done := 0
	for row in h:
		if _at_end():
			break
		var ok := _row_2d(ref, cur) if next_2d else _row_1d(cur)
		if not ok:
			if k < 0:
				break                                        # group 4 has no way back to a known place
			cur.clear()
			if not _find_eol():
				break
			if k > 0:
				next_2d = _peek(1) == 0
				_nbits -= 1
			ref = _blank(cur)
			rows_done += 1
			continue
		_paint(out, row * stride, cur, w, black_is_1)
		rows_done += 1
		ref = _blank(cur)
		if k >= 0:
			var got := false
			if byte_align and not end_of_line:
				_nbits -= _nbits & 7                         # (an end-of-line code is not looked for in the fill: it could be the next row's first bits)
				got = _eol()
			else:
				got = _eol()
				if byte_align and not got:
					_nbits -= _nbits & 7
			if got and _peek(12) == 1:
				break                                        # more than one end-of-line in a row: the end of the page
			if k > 0:
				next_2d = _peek(1) == 0
				_nbits -= 1
		elif byte_align:
			_nbits -= _nbits & 7
	return out if rows_done > 0 else PackedByteArray()


static func _flag(parms: Dictionary, key: String, fallback: bool) -> bool:
	var v: Variant = parms.get(key, fallback)
	if typeof(v) == TYPE_BOOL:
		return v
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return v != 0
	return fallback


## The row's changes, padded with places beyond the right edge so that looking past the last one is safe.
func _blank(changes: PackedInt32Array) -> PackedInt32Array:
	var r := changes.duplicate()
	for i in 4:
		r.append(_columns)
	return r


# ------------------------------------------------------------------------------------------------ bits

func _peek(n: int) -> int:
	while _nbits < n:
		_acc = ((_acc << 8) | (_data[_pos] if _pos < _size else 0)) & 0xFFFFFFFFFF
		_pos += 1
		_nbits += 8
	return (_acc >> (_nbits - n)) & ((1 << n) - 1)


func _at_end() -> bool:
	return _pos * 8 - _nbits >= _size * 8


## An end-of-line code (eleven zeros and a one, with any number of zeros of fill before it) at the current place: consumed, and true. Else nothing is.
func _eol() -> bool:
	while _peek(12) == 0 and not _at_end():
		_nbits -= 1
	if _peek(12) == 1:
		_nbits -= 12
		return true
	return false


## After a damaged row (group 3): on to the code that ends the line.
func _find_eol() -> bool:
	while not _at_end():
		if _peek(12) == 1:
			_nbits -= 12
			return true
		_nbits -= 1
	return false


# ------------------------------------------------------------------------------------------------ rows

## A run of the colour: make-up codes add up until a terminating code. -1 for something that is not a code.
func _run(black: bool) -> int:
	var total := 0
	while true:
		var e: int = _black[_peek(13)] if black else _white[_peek(12)]
		if e == 0:
			return -1
		_nbits -= e >> 16
		var r := e & 0xFFFF
		total += r
		if r < 64:
			return total
		if total > _columns + 2560:
			return -1
	return total


func _row_1d(cur: PackedInt32Array) -> bool:
	cur.clear()
	var x := 0
	var black := false
	while x < _columns:
		var r := _run(black)
		if r < 0:
			return false
		x = mini(x + r, _columns)
		cur.append(x)
		black = not black
	return true


func _row_2d(ref: PackedInt32Array, cur: PackedInt32Array) -> bool:
	cur.clear()
	var a0 := -1
	var color := 0                                           # 0 white, 1 black: the colour a0 is in
	var hint0 := 0                                           # where to look on the row above for a change to black / to white
	var hint1 := 1
	var cols := _columns
	while a0 < cols:
		var e := _modes[_peek(7)]
		var mode := e & 0xFF
		if mode == 0:
			return false                                     # end of block, an extension code, or nonsense
		_nbits -= e >> 8
		var k := hint1 if color == 1 else hint0
		while ref[k] <= a0 and ref[k] < cols:
			k += 2
		if color == 1:
			hint1 = k
		else:
			hint0 = k
		var b1 := ref[k]
		if mode == PASS:
			a0 = ref[k + 1]
		elif mode == HORIZ:
			var r1 := _run(color == 1)
			var r2 := _run(color == 0)
			if r1 < 0 or r2 < 0:
				return false
			var a1 := mini(maxi(a0, 0) + r1, cols)
			var a2 := mini(a1 + r2, cols)
			cur.append(a1)
			cur.append(a2)
			a0 = a2
		else:
			var d := 0
			match mode:
				VR1:
					d = 1
				VR2:
					d = 2
				VR3:
					d = 3
				VL1:
					d = -1
				VL2:
					d = -2
				VL3:
					d = -3
			var a1 := clampi(b1 + d, maxi(a0, 0), cols)
			cur.append(a1)
			a0 = a1
			color ^= 1
	return true


## Black runs of a row (cur[0] to cur[1], cur[2] to cur[3] ...) into the picture's bits.
func _paint(out: PackedByteArray, base: int, cur: PackedInt32Array, w: int, black_is_1: bool) -> void:
	var n := cur.size()
	var i := 0
	while i < n:
		var x0 := cur[i]
		var x1 := cur[i + 1] if i + 1 < n else _columns
		i += 2
		if x1 > w:
			x1 = w
		if x0 >= x1:
			continue
		var b0 := x0 >> 3
		var b1 := (x1 - 1) >> 3
		var first := 0xFF >> (x0 & 7)
		var last := (0xFF << (7 - ((x1 - 1) & 7))) & 0xFF
		if b0 == b1:
			var m := first & last
			out[base + b0] = (out[base + b0] | m) if black_is_1 else (out[base + b0] & ~m & 0xFF)
			continue
		if black_is_1:
			out[base + b0] = out[base + b0] | first
			for b in range(b0 + 1, b1):
				out[base + b] = 0xFF
			out[base + b1] = out[base + b1] | last
		else:
			out[base + b0] = out[base + b0] & ~first & 0xFF
			for b in range(b0 + 1, b1):
				out[base + b] = 0
			out[base + b1] = out[base + b1] & ~last & 0xFF
