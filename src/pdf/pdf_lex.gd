class_name PdfLex
extends RefCounted
## Reads PDF objects and content-stream tokens out of bytes.
##
## Objects become plain GDScript values: null, bool, int, float, a Name as a StringName, a string as PackedByteArray, an array as Array,
## a dictionary as Dictionary (keys are the names as String), an indirect reference as Vector2i(number, generation). A stream is a
## PdfStream. In a content stream an operator comes back as a plain String (a Name is a StringName, so the two never mix).

const WS := 1
const DELIM := 2
const NUM := 4
const END := &"<<end>>"                   # what next() returns at the end of the data

static var _cls: PackedByteArray = _make_classes()
static var _pow10: PackedFloat64Array = _make_pow10()

var b: PackedByteArray
var p := 0
var end := 0


static func _make_classes() -> PackedByteArray:
	var c := PackedByteArray()
	c.resize(256)
	for i in [0, 9, 10, 12, 13, 32]:
		c[i] = WS
	for ch in "()<>[]{}/%":
		c[ch.unicode_at(0)] = DELIM
	for i in range(48, 58):
		c[i] |= NUM
	return c


static func _make_pow10() -> PackedFloat64Array:
	var t := PackedFloat64Array()
	var v := 1.0
	for i in 24:
		t.append(v)
		v *= 10.0
	return t


func _init(bytes: PackedByteArray = PackedByteArray(), start: int = 0, stop: int = -1) -> void:
	b = bytes
	p = start
	end = bytes.size() if stop < 0 else mini(stop, bytes.size())


func at_end() -> bool:
	skip_ws()
	return p >= end


func skip_ws() -> void:
	while p < end:
		var c := b[p]
		if _cls[c] & WS:
			p += 1
		elif c == 37:                                  # % comment to the end of the line
			while p < end and b[p] != 10 and b[p] != 13:
				p += 1
		else:
			return


## The next object or (in content streams) operator. END at the end. Names are StringName, operators String.
func next() -> Variant:
	skip_ws()
	if p >= end:
		return END
	var c := b[p]
	match c:
		47:                                            # /
			return _name()
		40:                                            # (
			return _lit_string()
		60:                                            # <
			if p + 1 < end and b[p + 1] == 60:
				p += 2
				return _dict()
			return _hex_string()
		91:                                            # [
			p += 1
			return _array()
		93, 62, 41, 123, 125:                          # ] > ) { }  (a stray closer is returned as an operator so callers can stop)
			if c == 62 and p + 1 < end and b[p + 1] == 62:
				p += 2
				return ">>"
			p += 1
			return char(c)
	if c == 43 or c == 45 or c == 46 or (_cls[c] & NUM):
		var n: Variant = _number()
		if n != null:
			return n
	return _keyword()


## An object as found in a file body: like next(), but "n g R" is a reference and true / false / null are values.
func object() -> Variant:
	var v: Variant = next()
	var t := typeof(v)
	if t == TYPE_INT:
		var save := p
		skip_ws()
		if p < end and (_cls[b[p]] & NUM):
			var g: Variant = _number()
			if typeof(g) == TYPE_INT:
				skip_ws()
				if p < end and b[p] == 82 and (p + 1 >= end or _cls[b[p + 1]] & (WS | DELIM)):
					p += 1
					return Vector2i(v, g)
		p = save
		return v
	if t == TYPE_STRING:
		match v:
			"true":
				return true
			"false":
				return false
			"null":
				return null
	return v


func _number() -> Variant:
	var start := p
	var neg := false
	var c := b[p]
	while p < end and (c == 43 or c == 45):
		if c == 45:
			neg = true
		p += 1
		c = b[p] if p < end else 0
	var ip := 0
	var digits := 0
	while p < end:
		c = b[p]
		if _cls[c] & NUM:
			if digits < 18:
				ip = ip * 10 + (c - 48)
			digits += 1
			p += 1
		else:
			break
	var is_real := false
	var frac := 0.0
	var fd := 0
	if p < end and b[p] == 46:
		is_real = true
		p += 1
		while p < end:
			c = b[p]
			if _cls[c] & NUM:
				if fd < 17:
					frac = frac * 10.0 + (c - 48)
					fd += 1
				p += 1
			elif c == 46:                                  # "1.2.3": the stray dot is junk the real readers also skip
				p += 1
			else:
				break
	if digits == 0 and fd == 0:
		if p == start:
			return null
		# a lone sign or dot: not a number (an operator such as "-" never occurs in PDF, so call it zero)
		return 0.0 if is_real else 0
	if is_real:
		var v := float(ip) + frac / _pow10[fd]
		return -v if neg else v
	if digits > 18:
		return -9.2e18 if neg else 9.2e18
	return -ip if neg else ip


func _name() -> StringName:
	p += 1
	var start := p
	var hashes := false
	while p < end and not (_cls[b[p]] & (WS | DELIM)):
		if b[p] == 35:
			hashes = true
		p += 1
	if not hashes:
		return StringName(b.slice(start, p).get_string_from_utf8())
	var raw := PackedByteArray()
	var i := start
	while i < p:
		var ch := b[i]
		if ch == 35 and i + 2 < p and _is_hex(b[i + 1]) and _is_hex(b[i + 2]):
			raw.append(_hex_val(b[i + 1]) * 16 + _hex_val(b[i + 2]))
			i += 3
		else:
			raw.append(ch)
			i += 1
	return StringName(raw.get_string_from_utf8())


static func _is_hex(c: int) -> bool:
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)


static func _hex_val(c: int) -> int:
	if c <= 57:
		return c - 48
	if c <= 70:
		return c - 55
	return c - 87


func _lit_string() -> PackedByteArray:
	p += 1
	var out := PackedByteArray()
	var depth := 1
	while p < end:
		var c := b[p]
		p += 1
		if c == 92:                                    # backslash
			if p >= end:
				break
			var e := b[p]
			p += 1
			match e:
				110:
					out.append(10)
				114:
					out.append(13)
				116:
					out.append(9)
				98:
					out.append(8)
				102:
					out.append(12)
				13:
					if p < end and b[p] == 10:
						p += 1
				10:
					pass
				_:
					if e >= 48 and e <= 55:
						var v: int = e - 48
						for k in 2:
							if p < end and b[p] >= 48 and b[p] <= 55:
								v = v * 8 + (b[p] - 48)
								p += 1
							else:
								break
						out.append(v & 255)
					else:
						out.append(e)
		elif c == 40:
			depth += 1
			out.append(c)
		elif c == 41:
			depth -= 1
			if depth == 0:
				return out
			out.append(c)
		elif c == 13:                                  # an end of line inside a string reads as a line feed
			if p < end and b[p] == 10:
				p += 1
			out.append(10)
		else:
			out.append(c)
	return out


func _hex_string() -> PackedByteArray:
	p += 1
	var out := PackedByteArray()
	var hi := -1
	while p < end:
		var c := b[p]
		p += 1
		if c == 62:
			break
		if not _is_hex(c):
			continue
		var v := _hex_val(c)
		if hi < 0:
			hi = v
		else:
			out.append(hi * 16 + v)
			hi = -1
	if hi >= 0:
		out.append(hi * 16)
	return out


func _array() -> Array:
	var out: Array = []
	while true:
		skip_ws()
		if p >= end:
			break
		if b[p] == 93:
			p += 1
			break
		var v: Variant = object()
		if typeof(v) == TYPE_STRING_NAME and v == END:
			break
		if typeof(v) == TYPE_STRING and (v == ">>" or v == "endobj" or v == "stream"):
			p -= (v as String).length()
			break
		out.append(v)
	return out


func _dict() -> Dictionary:
	var out := {}
	while true:
		skip_ws()
		if p >= end:
			break
		if b[p] == 62:
			if p + 1 < end and b[p + 1] == 62:
				p += 2
			else:
				p += 1
			break
		var k: Variant = next()
		if typeof(k) == TYPE_STRING_NAME:
			if k == END:
				break
			var v: Variant = object()
			if typeof(v) == TYPE_STRING_NAME and v == END:
				break
			if typeof(v) == TYPE_STRING and (v == ">>" or v == "endobj" or v == "stream"):
				p -= (v as String).length()
				break
			out[String(k)] = v
		elif typeof(k) == TYPE_STRING and (k == "endobj" or k == "stream"):
			p -= (k as String).length()
			break
		# anything else where a key should be is junk: skip it
	return out


func _keyword() -> String:
	var start := p
	while p < end and not (_cls[b[p]] & (WS | DELIM)):
		p += 1
	if p == start:                                     # a delimiter we do not know: step over it
		p += 1
		return char(b[start])
	return b.slice(start, p).get_string_from_ascii()


## True when the bytes at `at` spell `word` (ASCII).
func spells(at: int, word: String) -> bool:
	var n := word.length()
	if at < 0 or at + n > b.size():
		return false
	for i in n:
		if b[at + i] != word.unicode_at(i):
			return false
	return true


## The first position at or after `from` where `word` starts, or -1.
func find_word(word: String, from: int, stop: int = -1) -> int:
	var first := word.unicode_at(0)
	var limit := (b.size() if stop < 0 else mini(stop, b.size())) - word.length()
	var i := from
	while i <= limit:
		i = b.find(first, i)
		if i < 0 or i > limit:
			return -1
		if spells(i, word):
			return i
		i += 1
	return -1
