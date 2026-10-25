class_name PdfRaster
extends RefCounted
## A tiny software rasteriser for the one place where the page has to be drawn into a picture: the group of a soft mask. A luminosity mask
## says "this much of what is drawn under it shows" by the brightness of its own little drawing, so the drawing (a gradient, a blurred picture,
## a shape) is made here, on the CPU, at a modest size, and then travels with the page as a grey picture that the graphics chip multiplies in.
##
## Flat or smooth-coloured triangles and textured triangles, composited over a backdrop; two channels: the luminosity of the result and how much
## was covered (an "alpha" mask uses the second).

var width := 0
var height := 0
var rect := Rect2()                        # the area of the page this picture covers
var lum := PackedFloat32Array()
var cov := PackedFloat32Array()

var _sx := 1.0
var _sy := 1.0


func _init(w: int, h: int, area: Rect2, backdrop: float) -> void:
	width = maxi(w, 1)
	height = maxi(h, 1)
	rect = area
	lum.resize(width * height)
	lum.fill(backdrop)
	cov.resize(width * height)
	_sx = float(width) / maxf(area.size.x, 1e-6)
	_sy = float(height) / maxf(area.size.y, 1e-6)


## Page space -> pixel space (y down, so the picture reads from the top like any other).
func _px(p: Vector2) -> Vector2:
	return Vector2((p.x - rect.position.x) * _sx, (rect.end.y - p.y) * _sy)


func luminance(c: Color) -> float:
	return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b


## Triangles with a colour at each corner (a soup of 3 points per triangle, one colour per point).
func tris(verts: PackedVector2Array, cols: PackedColorArray) -> void:
	var i := 0
	while i + 2 < verts.size():
		_tri(_px(verts[i]), _px(verts[i + 1]), _px(verts[i + 2]), cols[i], cols[i + 1], cols[i + 2], null, null, null, null, 1.0)
		i += 3


## Textured triangles: `color` supplies the colour (RGB or grey), `alpha` the coverage (null: opaque).
func image_tris(verts: PackedVector2Array, uvs: PackedVector2Array, color: Image, alpha: Image, opacity: float, fill: Color) -> void:
	var i := 0
	while i + 2 < verts.size():
		_tri(_px(verts[i]), _px(verts[i + 1]), _px(verts[i + 2]), fill, fill, fill, uvs[i], uvs[i + 1], uvs[i + 2], color, opacity, alpha)
		i += 3


func _tri(a: Vector2, b: Vector2, c: Vector2, ca: Color, cb: Color, cc: Color, ua: Variant, ub: Variant, uc: Variant, img: Variant, opacity: float, alpha_img: Variant = null) -> void:
	var area := (b - a).cross(c - a)
	if absf(area) < 1e-9:
		return
	var x0 := maxi(int(floor(minf(minf(a.x, b.x), c.x))), 0)
	var x1 := mini(int(ceil(maxf(maxf(a.x, b.x), c.x))), width - 1)
	var y0 := maxi(int(floor(minf(minf(a.y, b.y), c.y))), 0)
	var y1 := mini(int(ceil(maxf(maxf(a.y, b.y), c.y))), height - 1)
	if x1 < x0 or y1 < y0:
		return
	var inv := 1.0 / area
	var textured := img is Image or alpha_img is Image
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			var w0 := (b - p).cross(c - p) * inv
			var w1 := (c - p).cross(a - p) * inv
			var w2 := 1.0 - w0 - w1
			if w0 < -1e-6 or w1 < -1e-6 or w2 < -1e-6:
				continue
			var col := Color(ca.r * w0 + cb.r * w1 + cc.r * w2, ca.g * w0 + cb.g * w1 + cc.g * w2, ca.b * w0 + cb.b * w1 + cc.b * w2, ca.a * w0 + cb.a * w1 + cc.a * w2)
			if textured:
				var uv := (ua as Vector2) * w0 + (ub as Vector2) * w1 + (uc as Vector2) * w2
				if img is Image:
					col = _sample(img, uv)
					col.a = 1.0
				if alpha_img is Image:
					col.a *= _sample(alpha_img, uv).r
			var a_in := clampf(col.a * opacity, 0.0, 1.0)
			var at := y * width + x
			lum[at] = lum[at] * (1.0 - a_in) + luminance(col) * a_in
			cov[at] = cov[at] + a_in * (1.0 - cov[at])


func _sample(img: Image, uv: Vector2) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var fx := clampf(uv.x * w - 0.5, 0.0, w - 1.0)
	var fy := clampf(uv.y * h - 0.5, 0.0, h - 1.0)
	var ix := int(fx)
	var iy := int(fy)
	var jx := mini(ix + 1, w - 1)
	var jy := mini(iy + 1, h - 1)
	var tx := fx - ix
	var ty := fy - iy
	var top := img.get_pixel(ix, iy).lerp(img.get_pixel(jx, iy), tx)
	var bot := img.get_pixel(ix, jy).lerp(img.get_pixel(jx, jy), tx)
	return top.lerp(bot, ty)


## Which texels triangles cover, as a grey picture (white where covered). `verts` is a soup in page space and `area` the page rectangle the picture shows.
## Scanline by scanline with whole spans, so that a big shape costs little (the clip of a headline is a few thousand triangles and a million texels). A shape
## is made a third of a texel fatter on each side, so that thin strokes do not vanish.
static func coverage(verts: PackedVector2Array, w: int, h: int, area: Rect2) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_L8)
	var sx := float(w) / maxf(area.size.x, 1e-6)
	var sy := float(h) / maxf(area.size.y, 1e-6)
	var i := 0
	while i + 2 < verts.size():
		var a := Vector2((verts[i].x - area.position.x) * sx, (area.end.y - verts[i].y) * sy)
		var b := Vector2((verts[i + 1].x - area.position.x) * sx, (area.end.y - verts[i + 1].y) * sy)
		var c := Vector2((verts[i + 2].x - area.position.x) * sx, (area.end.y - verts[i + 2].y) * sy)
		i += 3
		var y0 := maxi(ceili(minf(minf(a.y, b.y), c.y) - 0.5 - 0.35), 0)
		var y1 := mini(floori(maxf(maxf(a.y, b.y), c.y) - 0.5 + 0.35), h - 1)
		for y in range(y0, y1 + 1):
			var yc := clampf(y + 0.5, minf(minf(a.y, b.y), c.y), maxf(maxf(a.y, b.y), c.y))      # (a row that only the fattening reaches: its edge)
			var xl := INF
			var xr := -INF
			if (a.y <= yc) != (b.y <= yc):
				var x := a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y)
				xl = minf(xl, x)
				xr = maxf(xr, x)
			if (b.y <= yc) != (c.y <= yc):
				var x := b.x + (yc - b.y) * (c.x - b.x) / (c.y - b.y)
				xl = minf(xl, x)
				xr = maxf(xr, x)
			if (c.y <= yc) != (a.y <= yc):
				var x := c.x + (yc - c.y) * (a.x - c.x) / (a.y - c.y)
				xl = minf(xl, x)
				xr = maxf(xr, x)
			if xr < xl:
				continue
			var xs := maxi(ceili(xl - 0.5 - 0.35), 0)
			var xe := mini(floori(xr - 0.5 + 0.35), w - 1)
			if xe >= xs:
				img.fill_rect(Rect2i(xs, y, xe - xs + 1, 1), Color.WHITE)
	return img


## The mask as a grey picture: luminosity (`use_alpha` false) or coverage.
func to_image(use_alpha: bool) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(width * height)
	var src := cov if use_alpha else lum
	for i in bytes.size():
		bytes[i] = clampi(int(src[i] * 255.0 + 0.5), 0, 255)
	return Image.create_from_data(width, height, false, Image.FORMAT_L8, bytes)
