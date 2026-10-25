class_name PdfDisplay
extends RefCounted
## What a page draws, in painting order, as the interpreter found it: filled shapes already cut into triangles, glyphs (font, glyph number
## and where), images, and gradient meshes, each with the clip it is drawn inside. Everything is in page space (points, y up, origin at the
## lower left of the visible page).
##
## Clips are kept as a table so that every drawing refers to one by number: an axis-aligned rectangle (the usual case) and, when a clip
## path is not a rectangle, a list of convex pieces whose union is the clip.

const MAX_PIECES := 48

var size := Vector2.ZERO                   # the visible page
var ops: Array = []
var clips: Array = []
var stats := {"triangles": 0, "glyphs": 0, "images": 0, "meshes": 0, "unsupported": {}}
var fonts: Dictionary = {}
var masks: Array = []                      # soft masks, baked: {image: L8 picture, rect: the page area it covers, outside: its value beyond that}
var title := ""


func _init() -> void:
	clips.append({"rect": Rect2(-1e9, -1e9, 2e9, 2e9), "pieces": []})


func note_unsupported(what: String) -> void:
	var u: Dictionary = stats.unsupported
	u[what] = int(u.get(what, 0)) + 1


## A clip that is `parent` cut down to the rectangle.
func clip_with_rect(parent: int, r: Rect2) -> int:
	var p: Dictionary = clips[parent]
	var nr: Rect2 = (p.rect as Rect2).intersection(r)
	if nr.size.x <= 0.0 or nr.size.y <= 0.0:
		nr = Rect2(nr.position, Vector2.ZERO)
	var pieces: Array = []
	if not (p.pieces as Array).is_empty():
		var rp := _rect_poly(nr)
		for pc in p.pieces:
			for res in Geometry2D.intersect_polygons(pc, rp):
				if res.size() >= 3 and absf(PdfGeom.area(res)) > 1e-9:
					pieces.append(_ccw(res))
		if pieces.is_empty():
			nr = Rect2(nr.position, Vector2.ZERO)
	clips.append({"rect": nr, "pieces": pieces})
	return clips.size() - 1


## A clip that is `parent` cut down to a region given as triangles (a soup) or, for one outline, to its convex pieces.
func clip_with_region(parent: int, soup: PackedVector2Array, outline: PackedVector2Array) -> int:
	var p: Dictionary = clips[parent]
	var new_pieces: Array = []
	if outline.size() >= 3:
		var dec := Geometry2D.decompose_polygon_in_convex(outline)
		for d in dec:
			new_pieces.append(_ccw(d))
	if new_pieces.is_empty() or new_pieces.size() > MAX_PIECES:
		new_pieces.clear()
		var i := 0
		while i + 2 < soup.size():
			new_pieces.append(_ccw(PackedVector2Array([soup[i], soup[i + 1], soup[i + 2]])))
			i += 3
	if new_pieces.size() > MAX_PIECES * 4:
		# too fine to be worth cutting by: the bounding rectangle will have to do
		return clip_with_rect(parent, PdfGeom.bounds(soup))
	var bounds := PdfGeom.bounds(soup)
	var rect: Rect2 = (p.rect as Rect2).intersection(bounds)
	var out: Array = []
	var parent_pieces: Array = p.pieces
	if parent_pieces.is_empty():
		for np in new_pieces:
			out.append(np)
	else:
		for pp in parent_pieces:
			for np in new_pieces:
				for res in Geometry2D.intersect_polygons(pp, np):
					if res.size() >= 3 and absf(PdfGeom.area(res)) > 1e-9:
						out.append(_ccw(res))
	if out.is_empty():
		rect = Rect2(rect.position, Vector2.ZERO)
	clips.append({"rect": rect, "pieces": out})
	return clips.size() - 1


static func _rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


static func _ccw(poly: PackedVector2Array) -> PackedVector2Array:
	if PdfGeom.area(poly) < 0.0:
		var r := poly.duplicate()
		r.reverse()
		return r
	return poly


## The soup cut to a clip.
func clip_soup(soup: PackedVector2Array, clip_id: int) -> PackedVector2Array:
	if clip_id <= 0 or soup.is_empty():
		return soup
	var c: Dictionary = clips[clip_id]
	var out := PdfGeom.clip_rect(soup, c.rect)
	var pieces: Array = c.pieces
	if pieces.is_empty() or out.is_empty():
		return out
	var res := PackedVector2Array()
	for pc in pieces:
		res.append_array(PdfGeom.clip_convex(out, pc))
	return res


func clip_rect_of(clip_id: int) -> Rect2:
	return clips[clip_id].rect


func clip_has_pieces(clip_id: int) -> bool:
	return not (clips[clip_id].pieces as Array).is_empty()


## A soft mask baked into a picture: returns its number (1 and up; 0 stands for no mask).
func add_mask(image: Image, area: Rect2, outside: float) -> int:
	masks.append({"image": image, "rect": area, "outside": outside})
	return masks.size()


func add_fill(soup: PackedVector2Array, color: Color, clip_id: int, blend: String = "", mask: int = 0) -> void:
	soup = clip_soup(soup, clip_id)
	if soup.is_empty() or color.a <= 0.0:
		return
	stats.triangles = int(stats.triangles) + soup.size() / 3
	ops.append({"t": "fill", "soup": soup, "color": color, "bm": blend, "mask": mask})


func add_mesh(soup: PackedVector2Array, cols: PackedColorArray, clip_id: int, blend: String = "", mask: int = 0) -> void:
	if soup.is_empty():
		return
	if clip_id > 0:
		# a coloured mesh cannot be cut cheaply triangle by triangle with its colours: it is kept whole when the clip is only a rectangle that
		# contains it, else cut with the colours carried along
		var c: Dictionary = clips[clip_id]
		var r: Rect2 = c.rect
		var b := PdfGeom.bounds(soup)
		if not r.encloses(b) or not (c.pieces as Array).is_empty():
			var cut := clip_mesh(soup, cols, clip_id)
			soup = cut[0]
			cols = cut[1]
	if soup.is_empty():
		return
	stats.triangles = int(stats.triangles) + soup.size() / 3
	stats.meshes = int(stats.meshes) + 1
	ops.append({"t": "mesh", "soup": soup, "cols": cols, "bm": blend, "mask": mask})


## Clips a coloured soup: each triangle is cut and the corner colours are interpolated at the new corners.
func clip_mesh(soup: PackedVector2Array, cols: PackedColorArray, clip_id: int) -> Array:
	var out_p := PackedVector2Array()
	var out_c := PackedColorArray()
	var c: Dictionary = clips[clip_id]
	var r: Rect2 = c.rect
	var pieces: Array = c.pieces
	var i := 0
	while i + 2 < soup.size():
		var poly: Array = [[soup[i], cols[i]], [soup[i + 1], cols[i + 1]], [soup[i + 2], cols[i + 2]]]
		i += 3
		poly = _cut_c(poly, 0, r.position.x, true)
		poly = _cut_c(poly, 0, r.end.x, false)
		poly = _cut_c(poly, 1, r.position.y, true)
		poly = _cut_c(poly, 1, r.end.y, false)
		if poly.size() < 3:
			continue
		# the clip is the union of its convex pieces: what is left of the triangle in each of them
		var parts: Array = [poly] if pieces.is_empty() else []
		for pc in pieces:
			var part: Array = poly
			var m := (pc as PackedVector2Array).size()
			for k in m:
				if part.is_empty():
					break
				part = _cut_edge(part, pc[k], pc[(k + 1) % m])
			if part.size() >= 3:
				parts.append(part)
		for part in parts:
			for k in range(1, part.size() - 1):
				for q in [0, k, k + 1]:
					out_p.append(part[q][0])
					out_c.append(part[q][1])
	return [out_p, out_c]


static func _cut_c(poly: Array, axis: int, at: float, keep_above: bool) -> Array:
	var out: Array = []
	var n := poly.size()
	for i in n:
		var p: Array = poly[i]
		var q: Array = poly[(i + 1) % n]
		var pv: float = (p[0] as Vector2)[axis]
		var qv: float = (q[0] as Vector2)[axis]
		var p_in := pv >= at if keep_above else pv <= at
		var q_in := qv >= at if keep_above else qv <= at
		if p_in:
			out.append(p)
		if p_in != q_in:
			var t := (at - pv) / (qv - pv)
			out.append([(p[0] as Vector2).lerp(q[0], t), (p[1] as Color).lerp(q[1], t)])
	return out


static func _cut_edge(poly: Array, a: Vector2, b: Vector2) -> Array:
	var out: Array = []
	var n := poly.size()
	for j in n:
		var p: Array = poly[j]
		var q: Array = poly[(j + 1) % n]
		var dp := (b - a).cross((p[0] as Vector2) - a)
		var dq := (b - a).cross((q[0] as Vector2) - a)
		if dp >= 0.0:
			out.append(p)
		if (dp >= 0.0) != (dq >= 0.0):
			var t := dp / (dp - dq)
			out.append([(p[0] as Vector2).lerp(q[0], t), (p[1] as Color).lerp(q[1], t)])
	return out


## A region drawn with a picture: `soup` (page space) with `uvs` into `color` (RGB) and `alpha` (grey).
func add_texture(soup: PackedVector2Array, uvs: PackedVector2Array, color: Image, alpha: Image, opacity: float, clip_id: int, blend: String = "", mask: int = 0) -> void:
	if clip_id > 0:
		var uvc := PackedColorArray()
		for uv in uvs:
			uvc.append(Color(uv.x, uv.y, 0, 1))
		var cut := clip_mesh(soup, uvc, clip_id)
		soup = cut[0]
		uvs = PackedVector2Array()
		for c in (cut[1] as PackedColorArray):
			uvs.append(Vector2(c.r, c.g))
	if soup.is_empty():
		return
	stats.triangles = int(stats.triangles) + soup.size() / 3
	ops.append({"t": "tex", "soup": soup, "uvs": uvs, "color": color, "alpha": alpha, "opacity": opacity, "bm": blend, "mask": mask})


func add_glyph(font: PdfFont, gid: int, m: Transform2D, color: Color, clip_id: int, blend: String = "", mask: int = 0) -> void:
	if color.a <= 0.0:
		return
	if clip_id > 0:
		var c: Dictionary = clips[clip_id]
		if (c.rect as Rect2).size == Vector2.ZERO:
			return
	stats.glyphs = int(stats.glyphs) + 1
	ops.append({"t": "glyph", "font": font, "gid": gid, "m": m, "color": color, "clip": clip_id, "bm": blend, "mask": mask})


## An image drawn on the unit square mapped by `m`. `fill` is the colour of an image mask (stencil).
func add_image(stream: PdfStream, m: Transform2D, alpha: float, clip_id: int, fill: Color, cs_res: Dictionary, blend: String = "", mask: int = 0) -> void:
	stats.images = int(stats.images) + 1
	ops.append({"t": "image", "stream": stream, "m": m, "alpha": alpha, "clip": clip_id, "fill": fill, "cs_res": cs_res, "bm": blend, "mask": mask})
