class_name PdfColor
extends RefCounted
## A colour space of a PDF page and the conversion of its colours to RGB. Device spaces, the calibrated ones (read as their device
## space), Lab, ICC-based (by their component count: the profile itself is not applied), Indexed, Separation and DeviceN (through their
## tint function), and Pattern.

var kind := "DeviceGray"
var n := 1
var base: PdfColor = null                  # Indexed: the base space; Separation / DeviceN: the alternate; Pattern: the space of uncoloured patterns
var palette := PackedByteArray()
var hival := 0
var tint: PdfFunction = null
var names: Array = []                      # Separation / DeviceN colorant names
var range_ := PackedFloat64Array()         # Lab ranges
var white := Vector3(0.9642, 1.0, 0.8249)
var none_ink := false                      # Separation /None: paints nothing

static var GRAY := _device("DeviceGray", 1)
static var RGB := _device("DeviceRGB", 3)
static var CMYK := _device("DeviceCMYK", 4)


static func _device(k: String, count: int) -> PdfColor:
	var c := PdfColor.new()
	c.kind = k
	c.n = count
	return c


## The space a PDF colour space object stands for. `res` is the resource dictionary's ColorSpace entries (names used by cs / CS).
static func make(doc: PdfDoc, v: Variant, res: Dictionary = {}, depth: int = 0) -> PdfColor:
	if depth > 6:
		return GRAY
	v = doc.res(v)
	if typeof(v) == TYPE_STRING_NAME:
		match String(v):
			"DeviceGray", "G", "CalGray":
				return GRAY
			"DeviceRGB", "RGB", "CalRGB":
				return RGB
			"DeviceCMYK", "CMYK":
				return CMYK
			"Pattern":
				var p := PdfColor.new()
				p.kind = "Pattern"
				p.n = 0
				return p
		if res.has(String(v)):
			var r: Variant = res[String(v)]
			if typeof(r) == TYPE_STRING_NAME and String(r) == String(v):
				return GRAY
			return make(doc, r, res, depth + 1)
		return GRAY
	if not (v is Array) or (v as Array).is_empty():
		return GRAY
	var a: Array = v
	var head := doc.d_name(a[0])
	match head:
		"DeviceGray", "G", "CalGray":
			return GRAY
		"DeviceRGB", "RGB", "CalRGB":
			return RGB
		"DeviceCMYK", "CMYK":
			return CMYK
		"Lab":
			var c := PdfColor.new()
			c.kind = "Lab"
			c.n = 3
			var d := doc.d_dict(a[1]) if a.size() > 1 else {}
			var wp := doc.d_nums(d.get("WhitePoint"))
			if wp.size() >= 3:
				c.white = Vector3(wp[0], wp[1], wp[2])
			c.range_ = doc.d_nums(d.get("Range"), PackedFloat64Array([-100.0, 100.0, -100.0, 100.0]))
			return c
		"ICCBased":
			var st := doc.d_stream(a[1]) if a.size() > 1 else null
			var count := doc.d_int(st.dict.get("N"), 3) if st != null else 3
			if count == 1:
				return GRAY
			if count == 4:
				return CMYK
			return RGB
		"Indexed", "I":
			var c2 := PdfColor.new()
			c2.kind = "Indexed"
			c2.n = 1
			c2.base = make(doc, a[1] if a.size() > 1 else &"DeviceRGB", res, depth + 1)
			c2.hival = clampi(doc.d_int(a[2] if a.size() > 2 else 0, 0), 0, 255)
			var tbl: Variant = doc.res(a[3]) if a.size() > 3 else null
			if tbl is PdfStream:
				c2.palette = (tbl as PdfStream).decode()
			elif tbl is PackedByteArray:
				c2.palette = tbl
			return c2
		"Separation":
			var c3 := PdfColor.new()
			c3.kind = "Separation"
			c3.n = 1
			c3.names = [doc.d_name(a[1] if a.size() > 1 else null)]
			c3.none_ink = c3.names[0] == "None"
			c3.base = make(doc, a[2] if a.size() > 2 else &"DeviceGray", res, depth + 1)
			c3.tint = PdfFunction.make(doc, a[3] if a.size() > 3 else null)
			return c3
		"DeviceN":
			var c4 := PdfColor.new()
			c4.kind = "DeviceN"
			var nm := doc.d_array(a[1] if a.size() > 1 else null)
			c4.n = maxi(nm.size(), 1)
			for x in nm:
				c4.names.append(doc.d_name(x))
			c4.base = make(doc, a[2] if a.size() > 2 else &"DeviceGray", res, depth + 1)
			c4.tint = PdfFunction.make(doc, a[3] if a.size() > 3 else null)
			return c4
		"Pattern":
			var c5 := PdfColor.new()
			c5.kind = "Pattern"
			c5.n = 0
			if a.size() > 1:
				c5.base = make(doc, a[1], res, depth + 1)
				c5.n = c5.base.n
			return c5
	return GRAY


## The colour a space starts with when it is selected (cs / CS).
func initial() -> Array:
	match kind:
		"DeviceCMYK":
			return [0.0, 0.0, 0.0, 1.0]
		"Separation", "DeviceN":
			var out: Array = []
			for i in n:
				out.append(1.0)
			return out
		"Lab":
			return [0.0, 0.0, 0.0]
	var z: Array = []
	for i in n:
		z.append(0.0)
	return z


func to_rgb(c: Array) -> Color:
	match kind:
		"DeviceGray":
			var g := clampf(float(c[0]) if c.size() > 0 else 0.0, 0.0, 1.0)
			return Color(g, g, g)
		"DeviceRGB":
			if c.size() < 3:
				return Color.BLACK
			return Color(clampf(c[0], 0.0, 1.0), clampf(c[1], 0.0, 1.0), clampf(c[2], 0.0, 1.0))
		"DeviceCMYK":
			if c.size() < 4:
				return Color.BLACK
			return cmyk(clampf(c[0], 0.0, 1.0), clampf(c[1], 0.0, 1.0), clampf(c[2], 0.0, 1.0), clampf(c[3], 0.0, 1.0))
		"Lab":
			return _lab(c)
		"Indexed":
			var i := clampi(int(c[0]) if c.size() > 0 else 0, 0, hival)
			var bn := base.n
			var comps: Array = []
			for k in bn:
				var at := i * bn + k
				var v := float(palette[at]) / 255.0 if at < palette.size() else 0.0
				comps.append(v)
			if base.kind == "Lab":
				comps = [comps[0] * 100.0, base.range_[0] + comps[1] * (base.range_[1] - base.range_[0]), base.range_[2] + comps[2] * (base.range_[3] - base.range_[2])]
			return base.to_rgb(comps)
		"Separation", "DeviceN":
			if tint == null:
				var gv := 1.0 - clampf(float(c[0]) if c.size() > 0 else 0.0, 0.0, 1.0)
				return Color(gv, gv, gv)
			return base.to_rgb(tint.evaluate(c))
		"Pattern":
			return base.to_rgb(c) if base != null else Color.BLACK
	return Color.BLACK


## A CMYK colour as RGB. A plain subtractive mix (1 - c) * (1 - k) is far more saturated than the print the colour stands for (100 % cyan is
## sky blue, black is dark grey with a hint of blue-grey): this is the polynomial fit to the SWOP press profile that pdf.js uses (Apache 2.0), which
## lands within a few steps of what Acrobat and Chrome show.
static func cmyk(c: float, m: float, y: float, k: float) -> Color:
	var r := 255.0 + c * (-4.387332384609988 * c + 54.48615194189176 * m + 18.82290502165302 * y + 212.25662451639585 * k - 285.2331026137004) 		+ m * (1.7149763477362134 * m - 5.6096736904047315 * y - 17.873870861415444 * k - 5.497006427196366) 		+ y * (-2.5217340131683033 * y - 21.248923337353073 * k + 17.5119270841813) 		+ k * (-21.86122147463605 * k - 189.48180835922747)
	var g := 255.0 + c * (8.841041422036149 * c + 60.118027045597366 * m + 6.871425592049007 * y + 31.159100130055922 * k - 79.2970844816548) 		+ m * (-15.310361306967817 * m + 17.575251261109482 * y + 131.35250912493976 * k - 190.9453302588951) 		+ y * (4.444339102852739 * y + 9.8632861493405 * k - 24.86741582555878) 		+ k * (-20.737325471181034 * k - 187.80453709719578)
	var b := 255.0 + c * (0.8842522430003296 * c + 8.078677503112928 * m + 30.89978309703729 * y - 0.23883238689178934 * k - 14.183576799673286) 		+ m * (10.49593273432072 * m + 63.02378494754052 * y + 50.606957656360734 * k - 112.23884253719248) 		+ y * (0.03296041114873217 * y + 115.60384449646641 * k - 193.58209356861505) 		+ k * (-22.33816807309886 * k - 180.12613974708367)
	return Color(clampf(r / 255.0, 0.0, 1.0), clampf(g / 255.0, 0.0, 1.0), clampf(b / 255.0, 0.0, 1.0))


func _lab(c: Array) -> Color:
	var l := clampf(float(c[0]) if c.size() > 0 else 0.0, 0.0, 100.0)
	var a := clampf(float(c[1]) if c.size() > 1 else 0.0, range_[0], range_[1])
	var b := clampf(float(c[2]) if c.size() > 2 else 0.0, range_[2], range_[3])
	var m := (l + 16.0) / 116.0
	var lx := m + a / 500.0
	var ly := m
	var lz := m - b / 200.0
	var x := white.x * (lx * lx * lx if lx >= 6.0 / 29.0 else (108.0 / 841.0) * (lx - 4.0 / 29.0))
	var y := white.y * (ly * ly * ly if ly >= 6.0 / 29.0 else (108.0 / 841.0) * (ly - 4.0 / 29.0))
	var z := white.z * (lz * lz * lz if lz >= 6.0 / 29.0 else (108.0 / 841.0) * (lz - 4.0 / 29.0))
	# D50 -> sRGB (Bradford-adapted matrix)
	var r := 3.1338561 * x - 1.6168667 * y - 0.4906146 * z
	var g := -0.9787684 * x + 1.9161415 * y + 0.0334540 * z
	var bb := 0.0719453 * x - 0.2289914 * y + 1.4052427 * z
	return Color(_gamma(r), _gamma(g), _gamma(bb))


static func _gamma(v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	return 12.92 * v if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055
