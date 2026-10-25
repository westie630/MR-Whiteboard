class_name PdfImage
extends RefCounted
## Reads an image XObject into pictures a texture can be made of: the colour picture (RGB or grey) and, when the image has transparency (a soft
## mask, an explicit mask, colour-key masking, or it is a stencil), a grey alpha picture. The two are kept apart and combined when drawn, so
## nothing needs to be merged pixel by pixel here. Pictures larger than the device's limit are reduced.
##
## Codecs: JPEG (DCTDecode) through the engine; CCITT fax Group 3 and 4 (PdfCcitt); Flate / LZW / run-length raw samples in any colour space and
## 1, 2, 4, 8 or 16 bits. Not read: JPEG 2000 and JBIG2.

const MAX_FALLBACK_PIXELS := 6000000

var color: Image = null
var alpha: Image = null
var is_mask := false
var width := 0
var height := 0
var reason := ""

static var _bit_lut: Array = _make_bit_luts()


static func _make_bit_luts() -> Array:
	# for 1, 2 and 4 bits per sample: byte -> the samples in it, one per byte of the result
	var out: Array = []
	for bits: int in [1, 2, 4]:
		var per: int = 8 / bits
		var table: Array = []
		for v in 256:
			var a := PackedByteArray()
			for k in per:
				a.append((v >> (8 - bits * (k + 1))) & ((1 << bits) - 1))
			table.append(a)
		out.append(table)
	return out


## Decodes the image `st`. `cs_res` is the page's ColorSpace resources (for named colour spaces), `fill` the colour a stencil is painted in,
## `max_dim` the longest side kept, `pixel_budget` how many pixels the slow conversions may touch.
static func decode(doc: PdfDoc, st: PdfStream, cs_res: Dictionary, max_dim: int, pixel_budget: int) -> PdfImage:
	var im := PdfImage.new()
	im._decode(doc, st, cs_res, max_dim, pixel_budget, true)
	return im


func ok() -> bool:
	return color != null or alpha != null


func _decode(doc: PdfDoc, st: PdfStream, cs_res: Dictionary, max_dim: int, pixel_budget: int, with_masks: bool) -> void:
	var d := st.dict
	var w := doc.d_int(d.get("Width"), 0)
	var h := doc.d_int(d.get("Height"), 0)
	if w <= 0 or h <= 0 or w > 65535 or h > 65535:
		reason = "bad size"
		return
	width = w
	height = h
	is_mask = doc.d_bool(d.get("ImageMask"), false)
	var bpc := 1 if is_mask else doc.d_int(d.get("BitsPerComponent"), 8)
	var space := PdfColor.GRAY
	if not is_mask and d.has("ColorSpace"):
		space = PdfColor.make(doc, d.get("ColorSpace"), cs_res)
	var dec := doc.d_nums(d.get("Decode"))
	var filt := st.image_filter()
	var data := st.decode()
	match filt:
		"DCTDecode":
			_read_jpeg(data, space, w, h, max_dim)
		"JPXDecode":
			reason = "JPEG 2000 images are not drawn"
		"CCITTFaxDecode":
			var bits := PdfCcitt.decode(data, st.image_parms(), w, h)
			if bits.is_empty():
				reason = "fax image could not be read"
			else:
				_read_samples(doc, bits, w, h, 1, space, dec, max_dim, pixel_budget)
		"JBIG2Decode":
			reason = "JBIG2 images are not drawn"
		_:
			if not st.ok():
				reason = "stream unreadable"
			else:
				_read_samples(doc, data, w, h, bpc, space, dec, max_dim, pixel_budget)
	if not with_masks or (color == null and alpha == null):
		return
	# transparency: a soft mask, an explicit mask, or colour-key ranges
	var sm := doc.d_stream(d.get("SMask"))
	if sm != null and not is_mask:
		var m := PdfImage.new()
		m._decode(doc, sm, cs_res, max_dim, pixel_budget, false)
		if m.color != null:
			alpha = m.color if m.color.get_format() == Image.FORMAT_L8 else _to_gray(m.color)
	else:
		var mk: Variant = doc.res(d.get("Mask"))
		if mk is PdfStream and not is_mask:
			var m2 := PdfImage.new()
			m2._decode(doc, mk, cs_res, max_dim, pixel_budget, false)
			if m2.alpha != null:
				alpha = m2.alpha
		elif mk is Array and not is_mask and color != null:
			_color_key(doc, mk, data, w, h, bpc, space)


func _to_gray(img: Image) -> Image:
	var g := img.duplicate() as Image
	g.convert(Image.FORMAT_L8)
	return g


# ------------------------------------------------------------------------------------------------ JPEG

func _read_jpeg(data: PackedByteArray, space: PdfColor, w: int, h: int, max_dim: int) -> void:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(data)
	if err != OK or img.is_empty():
		reason = "JPEG could not be read"
		return
	if img.get_format() != Image.FORMAT_L8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	if space.kind == "Indexed" or space.kind == "Separation" or space.kind == "DeviceN":
		pass
	_finish(img, max_dim)


func _finish(img: Image, max_dim: int) -> void:
	var longest := maxi(img.get_width(), img.get_height())
	if longest > max_dim and max_dim > 0:
		var k := float(max_dim) / longest
		img.resize(maxi(int(img.get_width() * k), 1), maxi(int(img.get_height() * k), 1), Image.INTERPOLATE_LANCZOS)
	if is_mask:
		alpha = img
	else:
		color = img


# ------------------------------------------------------------------------------------------------ raw samples

func _read_samples(doc: PdfDoc, data: PackedByteArray, w: int, h: int, bpc: int, space: PdfColor, dec: PackedFloat64Array, max_dim: int, budget: int) -> void:
	var n := 1 if is_mask else space.n
	if n <= 0:
		reason = "no colour space"
		return
	var row := (w * n * bpc + 7) / 8
	if row <= 0 or bpc not in [1, 2, 4, 8, 16]:
		reason = "unusual sample size"
		return
	var need := row * h
	if data.size() < need:
		var padded := data.duplicate()
		padded.resize(need)                                      # a short stream: the missing samples are zero
		data = padded
	if is_mask:
		_read_stencil(data, w, h, row, dec, max_dim)
		return
	# how many rows / columns to skip when the conversion is slow
	var slow := space.kind in ["DeviceCMYK", "Indexed", "Separation", "DeviceN", "Lab"] or bpc != 8 or not dec.is_empty()
	var step := 1
	if slow and w * h > budget:
		step = ceili(sqrt(float(w * h) / budget))
	var ow := (w + step - 1) / step
	var oh := (h + step - 1) / step
	# samples of 1, 2, 4 bits unpacked to bytes (one row at a time, only the rows that are kept)
	var out := PackedByteArray()
	var fmt := Image.FORMAT_L8
	var gray := space.kind in ["DeviceGray", "CalGray"] or (space.kind == "ICCBased" and n == 1)
	if bpc == 8 and step == 1 and dec.is_empty() and n == 3 and space.kind in ["DeviceRGB", "CalRGB"]:
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGB8, data.slice(0, need))
		_finish(img, max_dim)
		return
	if bpc == 8 and step == 1 and dec.is_empty() and n == 1 and space.kind == "DeviceGray":
		var img2 := Image.create_from_data(w, h, false, Image.FORMAT_L8, data.slice(0, need))
		_finish(img2, max_dim)
		return
	var rows := range(0, h, step)
	var samples := PackedByteArray()                         # bytes, n per pixel, for the kept rows and columns
	for r in rows:
		var rowbytes := data.slice(r * row, r * row + row)
		var line := PackedByteArray()
		if bpc == 8:
			line = rowbytes
		elif bpc == 16:
			line.resize(w * n)
			for i in w * n:
				line[i] = rowbytes[i * 2]
		else:
			var lut: Array = _bit_lut[0 if bpc == 1 else (1 if bpc == 2 else 2)]
			for b in rowbytes:
				line.append_array(lut[b])
		if step == 1:
			samples.append_array(line.slice(0, w * n))
		else:
			for x in range(0, w, step):
				for k in n:
					samples.append(line[x * n + k])
	var maxv := 255.0 if bpc >= 8 else float((1 << bpc) - 1)
	var count := ow * oh
	var invert := dec.size() >= 2 and dec[0] > dec[1] and (n == 1)
	if gray and (bpc != 8 or invert):
		out.resize(count)
		var mul := 255.0 / maxv if bpc < 8 else 1.0
		for i in count:
			var v := int(samples[i] * mul + 0.5)
			out[i] = 255 - v if invert else v
		_finish(Image.create_from_data(ow, oh, false, Image.FORMAT_L8, out), max_dim)
		return
	if gray:
		_finish(Image.create_from_data(ow, oh, false, Image.FORMAT_L8, samples.slice(0, count)), max_dim)
		return
	out.resize(count * 3)
	match space.kind:
		"DeviceRGB", "CalRGB", "ICCBased":
			if n == 3:
				var mul3 := 255.0 / maxv if bpc < 8 else 1.0
				for i in count * 3:
					out[i] = int(samples[i] * mul3 + 0.5) if bpc < 8 else samples[i]
			elif n == 4:
				for i in count:
					var c := PdfColor.cmyk(samples[i * 4] / 255.0, samples[i * 4 + 1] / 255.0, samples[i * 4 + 2] / 255.0, samples[i * 4 + 3] / 255.0)
					out[i * 3] = int(c.r * 255.0)
					out[i * 3 + 1] = int(c.g * 255.0)
					out[i * 3 + 2] = int(c.b * 255.0)
		"DeviceCMYK":
			for i in count:
				var k := samples[i * 4 + 3] / 255.0 if bpc >= 8 else samples[i * 4 + 3] / maxv
				var s0 := samples[i * 4] / 255.0 if bpc >= 8 else samples[i * 4] / maxv
				var s1 := samples[i * 4 + 1] / 255.0 if bpc >= 8 else samples[i * 4 + 1] / maxv
				var s2 := samples[i * 4 + 2] / 255.0 if bpc >= 8 else samples[i * 4 + 2] / maxv
				var c2 := PdfColor.cmyk(s0, s1, s2, k)
				out[i * 3] = int(c2.r * 255.0)
				out[i * 3 + 1] = int(c2.g * 255.0)
				out[i * 3 + 2] = int(c2.b * 255.0)
		"Indexed":
			var lut_rgb := PackedByteArray()
			lut_rgb.resize(256 * 3)
			for i in space.hival + 1:
				var c3 := space.to_rgb([float(i)])
				lut_rgb[i * 3] = int(c3.r * 255.0)
				lut_rgb[i * 3 + 1] = int(c3.g * 255.0)
				lut_rgb[i * 3 + 2] = int(c3.b * 255.0)
			for i in count:
				var ix := mini(samples[i], space.hival)
				out[i * 3] = lut_rgb[ix * 3]
				out[i * 3 + 1] = lut_rgb[ix * 3 + 1]
				out[i * 3 + 2] = lut_rgb[ix * 3 + 2]
		_:
			# Separation, DeviceN, Lab: through the colour space, one pixel at a time (a one-colourant space through a 256-entry table)
			if n == 1:
				var tbl: Array = []
				for i in 256:
					var v2 := float(i) / maxv if bpc < 8 else float(i) / 255.0
					var c4 := space.to_rgb([v2])
					tbl.append([int(c4.r * 255.0), int(c4.g * 255.0), int(c4.b * 255.0)])
				for i in count:
					var t: Array = tbl[samples[i]]
					out[i * 3] = t[0]
					out[i * 3 + 1] = t[1]
					out[i * 3 + 2] = t[2]
			else:
				var small := mini(count, 40000)
				for i in count:
					var comps: Array = []
					for k in n:
						comps.append(float(samples[i * n + k]) / (255.0 if bpc >= 8 else maxv))
					if space.kind == "Lab":
						comps = [comps[0] * 100.0, space.range_[0] + comps[1] * (space.range_[1] - space.range_[0]), space.range_[2] + comps[2] * (space.range_[3] - space.range_[2])]
					var c5 := space.to_rgb(comps)
					out[i * 3] = int(c5.r * 255.0)
					out[i * 3 + 1] = int(c5.g * 255.0)
					out[i * 3 + 2] = int(c5.b * 255.0)
				if small < count:
					pass
	fmt = Image.FORMAT_RGB8
	_finish(Image.create_from_data(ow, oh, false, fmt, out), max_dim)


## A stencil mask: 1 bit per sample, a sample of 0 paints (unless Decode says [1 0]). The result is a grey picture, 255 where it paints.
func _read_stencil(data: PackedByteArray, w: int, h: int, row: int, dec: PackedFloat64Array, max_dim: int) -> void:
	var paint_on_zero := not (dec.size() >= 2 and dec[0] > dec[1])
	var step := 1
	var longest := maxi(w, h)
	if longest > max_dim * 2 and max_dim > 0:
		step = longest / (max_dim * 2)
	var lut: Array = _bit_lut[0]
	var out := PackedByteArray()
	var rows := range(0, h, step)
	var padded_w := row * 8
	for r in rows:
		var rowbytes := data.slice(r * row, r * row + row)
		var line := PackedByteArray()
		for b in rowbytes:
			line.append_array(lut[b])
		out.append_array(line)
	# 0/1 -> 0/255, inverted when zero paints
	var n := out.size()
	if paint_on_zero:
		for i in n:
			out[i] = 0 if out[i] != 0 else 255
	else:
		for i in n:
			out[i] = 255 if out[i] != 0 else 0
	var img := Image.create_from_data(padded_w, rows.size(), false, Image.FORMAT_L8, out)
	if padded_w != w:
		img = img.get_region(Rect2i(0, 0, w, rows.size()))
	_finish(img, max_dim)


## /Mask [min max ...]: samples inside every range are transparent.
func _color_key(doc: PdfDoc, rng: Array, data: PackedByteArray, w: int, h: int, bpc: int, space: PdfColor) -> void:
	if bpc != 8 or w * h > 4000000:
		return
	var n := space.n
	if rng.size() < n * 2 or n > 4:
		return
	var out := PackedByteArray()
	out.resize(w * h)
	for i in w * h:
		var all_in := true
		for k in n:
			var v := data[i * n + k] if i * n + k < data.size() else 0
			if v < int(rng[k * 2]) or v > int(rng[k * 2 + 1]):
				all_in = false
				break
		out[i] = 0 if all_in else 255
	alpha = Image.create_from_data(w, h, false, Image.FORMAT_L8, out)
