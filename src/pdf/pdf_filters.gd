class_name PdfFilters
extends RefCounted
## The stream filters that are plain data coding: Flate (with its predictors), LZW, ASCII85, ASCIIHex and RunLength. The image codecs
## (DCT, CCITT, JBIG2, JPX) are in PdfImage.

const MAX_OUT := 128 * 1024 * 1024         # a stream that unpacks to more than this is not read (and a Quest 2 has 6 GB in all)


## `size_hint` is how big the result is expected to be (an image knows), 0 when not known.
static func flate(data: PackedByteArray, parms: Dictionary = {}, size_hint: int = 0) -> PackedByteArray:
	if data.size() < 2:
		return PackedByteArray()
	return predict(inflate(data, size_hint), parms)


## zlib data -> bytes. The engine's decompress_dynamic() takes the whole process down on a stream with stray bytes after its end (a
## newline inside /Length is common), so the fixed-size decompress() is used, with a bigger buffer each time one proves too small.
static func inflate(data: PackedByteArray, size_hint: int = 0) -> PackedByteArray:
	var guess := size_hint if size_hint > 0 else maxi(data.size() * 8, 16384)
	for attempt in 7:
		if guess > MAX_OUT:
			break
		var out := data.decompress(guess, FileAccess.COMPRESSION_DEFLATE)
		if not out.is_empty():
			return out
		guess *= 4
	return PdfInflate.inflate(data, true)                       # damaged or cut short: whatever can be read


## Undo a PNG / TIFF predictor (the /Predictor, /Colors, /BitsPerComponent and /Columns of the filter's parameters).
static func predict(data: PackedByteArray, parms: Dictionary) -> PackedByteArray:
	var pred := int(parms.get("Predictor", 1))
	if pred <= 1 or data.is_empty():
		return data
	var colors := maxi(int(parms.get("Colors", 1)), 1)
	var bpc := int(parms.get("BitsPerComponent", 8))
	var cols := maxi(int(parms.get("Columns", 1)), 1)
	var bpp := maxi((colors * bpc + 7) / 8, 1)                 # bytes per pixel (at least 1)
	var row := (colors * bpc * cols + 7) / 8                   # bytes per row
	if pred == 2:
		return _tiff(data, row, colors, bpc, cols)
	if pred < 10:
		return data
	return _png(data, row, bpp)


static func _png(data: PackedByteArray, row: int, bpp: int) -> PackedByteArray:
	var stride := row + 1
	var rows := (data.size() + stride - 1) / stride
	var out := PackedByteArray()
	out.resize(rows * row)
	var prev_at := -1                                          # where the previous output row starts
	for r in rows:
		var src := r * stride
		var ft := data[src]
		var dst := r * row
		var n := mini(row, data.size() - src - 1)
		if n <= 0:
			out.resize(r * row)
			break
		match ft:
			1:                                                 # Sub
				for i in n:
					var left := out[dst + i - bpp] if i >= bpp else 0
					out[dst + i] = (data[src + 1 + i] + left) & 255
			2:                                                 # Up
				if prev_at < 0:
					for i in n:
						out[dst + i] = data[src + 1 + i]
				else:
					_add_rows(out, dst, data, src + 1, prev_at, n)
			3:                                                 # Average
				for i in n:
					var left := out[dst + i - bpp] if i >= bpp else 0
					var up := out[prev_at + i] if prev_at >= 0 else 0
					out[dst + i] = (data[src + 1 + i] + ((left + up) >> 1)) & 255
			4:                                                 # Paeth
				for i in n:
					var a := out[dst + i - bpp] if i >= bpp else 0
					var b := out[prev_at + i] if prev_at >= 0 else 0
					var c := out[prev_at + i - bpp] if (prev_at >= 0 and i >= bpp) else 0
					var pa := absi(b - c)
					var pb := absi(a - c)
					var pc := absi(a + b - c - c)
					var pr := a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
					out[dst + i] = (data[src + 1 + i] + pr) & 255
			_:                                                 # None (and anything unknown)
				for i in n:
					out[dst + i] = data[src + 1 + i]
		prev_at = dst
	return out


## out[dst..dst+n] = (a[a_at..] + out[prev..]) per byte, eight bytes at a time.
static func _add_rows(out: PackedByteArray, dst: int, a: PackedByteArray, a_at: int, prev: int, n: int) -> void:
	var i := 0
	var lo := 0x7F7F7F7F7F7F7F7F
	var hi := ~lo
	while i + 8 <= n:
		var x := a.decode_s64(a_at + i)
		var y := out.decode_s64(prev + i)
		out.encode_s64(dst + i, ((x & lo) + (y & lo)) ^ ((x ^ y) & hi))
		i += 8
	while i < n:
		out[dst + i] = (a[a_at + i] + out[prev + i]) & 255
		i += 1


static func _tiff(data: PackedByteArray, row: int, colors: int, bpc: int, cols: int) -> PackedByteArray:
	if bpc != 8 and bpc != 16:
		return data
	var out := data.duplicate()
	var rows := data.size() / row
	var step := colors * (bpc / 8)
	for r in rows:
		var base := r * row
		if bpc == 8:
			for i in range(step, row):
				out[base + i] = (out[base + i] + out[base + i - step]) & 255
		else:
			var i := step
			while i + 1 < row:
				var v := (out[base + i] << 8 | out[base + i + 1]) + (out[base + i - step] << 8 | out[base + i - step + 1])
				out[base + i] = (v >> 8) & 255
				out[base + i + 1] = v & 255
				i += 2
	return out


static func lzw(data: PackedByteArray, parms: Dictionary = {}) -> PackedByteArray:
	var early := int(parms.get("EarlyChange", 1))
	var out := PackedByteArray()
	# the table: each entry is [prefix code, byte, length]; the strings are rebuilt backwards
	var prefix := PackedInt32Array()
	var last := PackedByteArray()
	var length := PackedInt32Array()
	prefix.resize(4096)
	last.resize(4096)
	length.resize(4096)
	for i in 256:
		prefix[i] = -1
		last[i] = i
		length[i] = 1
	var next_code := 258
	var bits := 9
	var buf := 0
	var nbuf := 0
	var pos := 0
	var prev := -1
	var tmp := PackedByteArray()
	while true:
		while nbuf < bits and pos < data.size():
			buf = (buf << 8) | data[pos]
			pos += 1
			nbuf += 8
		if nbuf < bits:
			break
		var code := (buf >> (nbuf - bits)) & ((1 << bits) - 1)
		nbuf -= bits
		buf &= (1 << nbuf) - 1
		if code == 256:
			next_code = 258
			bits = 9
			prev = -1
			continue
		if code == 257:
			break
		var start := out.size()
		if code < next_code and (code < 256 or code >= 258):
			var n := length[code]
			out.resize(start + n)
			var c := code
			var k := n - 1
			while c >= 0 and k >= 0:
				out[start + k] = last[c]
				c = prefix[c]
				k -= 1
		elif code == next_code and prev >= 0:
			var n2 := length[prev] + 1
			out.resize(start + n2)
			var c2 := prev
			var k2 := n2 - 2
			while c2 >= 0 and k2 >= 0:
				out[start + k2] = last[c2]
				c2 = prefix[c2]
				k2 -= 1
			out[start + n2 - 1] = out[start]
		else:
			break
		if prev >= 0 and next_code < 4096:
			prefix[next_code] = prev
			last[next_code] = out[start]
			length[next_code] = length[prev] + 1
			next_code += 1
		prev = code
		if next_code + early >= 4096:
			bits = 12
		elif next_code + early >= 2048:
			bits = 12
		elif next_code + early >= 1024:
			bits = 11
		elif next_code + early >= 512:
			bits = 10
		else:
			bits = 9
	return predict(out, parms)


static func ascii85(data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var group := PackedInt32Array([0, 0, 0, 0, 0])
	var n := 0
	var i := 0
	if data.size() >= 2 and data[0] == 60 and data[1] == 126:     # <~
		i = 2
	while i < data.size():
		var c := data[i]
		i += 1
		if c == 126:                                          # ~> ends the data
			break
		if c <= 32:
			continue
		if c == 122 and n == 0:                               # z = four zero bytes
			out.append_array(PackedByteArray([0, 0, 0, 0]))
			continue
		if c < 33 or c > 117:
			continue
		group[n] = c - 33
		n += 1
		if n == 5:
			var v := ((group[0] * 85 + group[1]) * 85 + group[2]) * 85 + group[3]
			v = v * 85 + group[4]
			out.append((v >> 24) & 255)
			out.append((v >> 16) & 255)
			out.append((v >> 8) & 255)
			out.append(v & 255)
			n = 0
	if n > 1:
		for k in range(n, 5):
			group[k] = 84
		var v2 := ((group[0] * 85 + group[1]) * 85 + group[2]) * 85 + group[3]
		v2 = v2 * 85 + group[4]
		var bytes := [(v2 >> 24) & 255, (v2 >> 16) & 255, (v2 >> 8) & 255, v2 & 255]
		for k in n - 1:
			out.append(bytes[k])
	return out


static func ascii_hex(data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var hi := -1
	for c in data:
		if c == 62:
			break
		var v := -1
		if c >= 48 and c <= 57:
			v = c - 48
		elif c >= 65 and c <= 70:
			v = c - 55
		elif c >= 97 and c <= 102:
			v = c - 87
		if v < 0:
			continue
		if hi < 0:
			hi = v
		else:
			out.append(hi * 16 + v)
			hi = -1
	if hi >= 0:
		out.append(hi * 16)
	return out


static func run_length(data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var i := 0
	while i < data.size():
		var n := data[i]
		i += 1
		if n == 128:
			break
		if n < 128:
			var k := mini(n + 1, data.size() - i)
			out.append_array(data.slice(i, i + k))
			i += n + 1
		else:
			if i >= data.size():
				break
			var rep := 257 - n
			var v := data[i]
			i += 1
			var chunk := PackedByteArray()
			chunk.resize(rep)
			chunk.fill(v)
			out.append_array(chunk)
	return out
