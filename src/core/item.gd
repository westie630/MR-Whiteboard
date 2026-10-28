class_name Item
extends RefCounted
## One thing on a frame: a freehand stroke, a parametric shape (box, line, arrow, ...), a piece of text or a picture.
## Canvas items live in the frame's xy plane (x right, y up, metres); strokes in a 3D volume also use z.
## Everything an item is lives in plain fields so it can be copied, saved and diffed for undo.

const STROKE := "stroke"
const SHAPE := "shape"
const TEXT := "text"
const IMAGE := "image"                    # a picture: `image` names the file (ImageLibrary), `center` / `size` / `rot` place it, colour alpha = opacity

var id := ""
var kind := STROKE
var frame := ""
var z := 0                                # drawing order, higher is on top
var page := 0                             # on a canvas that shows a PDF: the page this was drawn on (0 = not on a PDF page)

# style
var color := Color.WHITE
var width := 0.004                        # metres (stroke at full pressure / outline of shapes)
var brush := "pen"
var fill := Color(0, 0, 0, 0)             # shapes: alpha 0 = not filled

# stroke: x, y, z, pressure per point
var pts := PackedFloat32Array()

# shape / text placement
var shape := ""                           # Shapes id (rect, ellipse, line, arrow, poly, ...)
var center := Vector2.ZERO
var size := Vector2(0.2, 0.2)
var rot := 0.0
var poly := PackedVector2Array()          # shape == "poly": the vertices in the frame
# line-type shapes
var a := Vector2.ZERO
var b := Vector2.ZERO
var na := Vector2.ZERO                    # direction the line leaves each end (zero = free end), used by elbow routing
var nb := Vector2.ZERO
var glue_a := {}                          # {item: id, port: idx} while the end is stuck to a shape
var glue_b := {}
var head_a := false
var head_b := false
# label inside a shape, and the text item itself
var label := ""
var text := ""
var font_size := 0.05                     # em height in metres
var weight := TextLayout.REGULAR          # Open Sans weight, 300 Light .. 800 ExtraBold
var italic := false
var alternatives: PackedStringArray = []  # other readings of the handwriting, for correcting a text item
var ink: Array = []                       # the handwriting strokes (item dictionaries) this text was converted from: "back to ink"
# picture
var image := ""                           # the picture's content id in the ImageLibrary


static func make_stroke(frame_id: String, points: PackedFloat32Array, col: Color, w: float, brush_id: String) -> Item:
	var it := Item.new()
	it.id = U.uid("i")
	it.kind = STROKE
	it.frame = frame_id
	it.pts = points
	it.color = col
	it.width = w
	it.brush = brush_id
	return it


static func make_shape(frame_id: String, shape_id: String, col: Color, w: float, brush_id: String = "pen") -> Item:
	var it := Item.new()
	it.id = U.uid("i")
	it.kind = SHAPE
	it.frame = frame_id
	it.shape = shape_id
	it.color = col
	it.width = w
	it.brush = brush_id
	it.size = Shapes.default_size(shape_id)
	return it


static func make_text(frame_id: String, txt: String, col: Color, em: float, weight_: int = TextLayout.REGULAR) -> Item:
	var it := Item.new()
	it.id = U.uid("i")
	it.kind = TEXT
	it.frame = frame_id
	it.text = txt
	it.color = col
	it.font_size = em
	it.weight = weight_
	it.refit_text()
	return it


## A picture `size` metres big (its own aspect ratio), centred at the origin.
static func make_image(frame_id: String, image_id: String, size_m: Vector2) -> Item:
	var it := Item.new()
	it.id = U.uid("i")
	it.kind = IMAGE
	it.frame = frame_id
	it.image = image_id
	it.size = size_m
	it.color = Color.WHITE
	it.width = 0.0
	return it


func is_line() -> bool:
	return kind == SHAPE and Shapes.is_line(shape)


func point_count() -> int:
	return pts.size() / 4


func pt(i: int) -> Vector3:
	return Vector3(pts[i * 4], pts[i * 4 + 1], pts[i * 4 + 2])


func pressure(i: int) -> float:
	return pts[i * 4 + 3]


func pts_2d() -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in point_count():
		out.append(Vector2(pts[i * 4], pts[i * 4 + 1]))
	return out


## Measure the text and keep `size` equal to its bounding box.
func refit_text() -> void:
	if kind == TEXT:
		size = TextLayout.measure(text, font_size, weight, italic)


# ------------------------------------------------------------------------------------------------ geometry

## Bounding box in the frame's xy plane.
func bounds() -> Rect2:
	match kind:
		STROKE:
			var bb := Geom2D.bbox(pts_2d())
			return bb.grow(width * 0.5)
		SHAPE:
			var all := PackedVector2Array()
			for o in Shapes.world_outlines(self):
				all.append_array(o.pts)
			if all.is_empty():
				return Rect2(center - size * 0.5, size)
			return Geom2D.bbox(all).grow(width * 0.5)
		TEXT, IMAGE:
			return Geom2D.bbox(text_corners())
	return Rect2()


## Corners of the (rotated) box of a text or a picture in the frame.
func text_corners() -> PackedVector2Array:
	var h := size * 0.5
	var out := PackedVector2Array()
	for c in [Vector2(-h.x, h.y), Vector2(h.x, h.y), Vector2(h.x, -h.y), Vector2(-h.x, -h.y)]:
		out.append(center + Geom2D.rot(c, rot))
	return out


## Is the point on this item? `tol` is the pick radius (metres) around lines.
func hit(p: Vector2, tol: float) -> bool:
	match kind:
		STROKE:
			if not bounds().grow(tol).has_point(p):
				return false
			var n := point_count()
			var r := tol + width * 0.5
			if n == 1:
				return pt(n - 1).distance_to(Vector3(p.x, p.y, 0)) <= r
			for i in range(n - 1):
				if Geom2D.dist_to_segment(p, Vector2(pts[i * 4], pts[i * 4 + 1]), Vector2(pts[i * 4 + 4], pts[i * 4 + 5])) <= r:
					return true
			return false
		SHAPE:
			if shape == "poly":
				if fill.a > 0.02 and Geometry2D.is_point_in_polygon(p, poly):
					return true
				return Geom2D.dist_to_polyline(p, poly, true) <= tol + width * 0.5
			return Shapes.hit(self, p, tol)
		TEXT, IMAGE:
			var local := Geom2D.rot(p - center, -rot)
			return absf(local.x) <= size.x * 0.5 + tol and absf(local.y) <= size.y * 0.5 + tol
	return false


## Move / rotate / scale a canvas item by a 2D transform in the frame's plane (uniform scale expected).
func apply_xform(t: Transform2D) -> void:
	var s := t.x.length()
	var ang := t.get_rotation()
	match kind:
		STROKE:
			for i in point_count():
				var q := t * Vector2(pts[i * 4], pts[i * 4 + 1])
				pts[i * 4] = q.x
				pts[i * 4 + 1] = q.y
			width *= s
		SHAPE:
			if shape == "poly":
				var np := PackedVector2Array()
				for p in poly:
					np.append(t * p)
				poly = np
			elif is_line():
				a = t * a
				b = t * b
				na = t.basis_xform(na).normalized() if na != Vector2.ZERO else na
				nb = t.basis_xform(nb).normalized() if nb != Vector2.ZERO else nb
			else:
				center = t * center
				rot += ang
				size *= s
			width *= s
		TEXT:
			center = t * center
			rot += ang
			font_size *= s
			refit_text()
		IMAGE:
			center = t * center
			rot += ang
			size *= s


## Move / rotate / scale a stroke inside a 3D volume.
func apply_xform3(t: Transform3D) -> void:
	if kind != STROKE:
		return
	var s := t.basis.x.length()
	for i in point_count():
		var q := t * Vector3(pts[i * 4], pts[i * 4 + 1], pts[i * 4 + 2])
		pts[i * 4] = q.x
		pts[i * 4 + 1] = q.y
		pts[i * 4 + 2] = q.z
	width *= s


# ------------------------------------------------------------------------------------------------ save / load

func to_dict() -> Dictionary:
	var d := {"id": id, "kind": kind, "frame": frame, "z": z, "color": U.color_to_str(color), "width": snappedf(width, 1e-5), "brush": brush}
	if page != 0:
		d["page"] = page
	match kind:
		STROKE:
			d["pts"] = U.pack_floats(pts)
		SHAPE:
			d["shape"] = shape
			if fill.a > 0.0:
				d["fill"] = U.color_to_str(fill)
			if label != "":
				d["label"] = label
			if shape == "poly":
				var arr: Array = []
				for p in poly:
					arr.append_array(U.v2_to_array(p))
				d["poly"] = arr
			elif is_line():
				d["a"] = U.v2_to_array(a)
				d["b"] = U.v2_to_array(b)
				if na != Vector2.ZERO:
					d["na"] = U.v2_to_array(na)
				if nb != Vector2.ZERO:
					d["nb"] = U.v2_to_array(nb)
				if not glue_a.is_empty():
					d["glue_a"] = glue_a.duplicate()
				if not glue_b.is_empty():
					d["glue_b"] = glue_b.duplicate()
				d["head_a"] = head_a
				d["head_b"] = head_b
			else:
				d["center"] = U.v2_to_array(center)
				d["size"] = U.v2_to_array(size)
				d["rot"] = snappedf(rot, 1e-5)
		TEXT:
			d["text"] = text
			d["font_size"] = snappedf(font_size, 1e-5)
			if weight != TextLayout.REGULAR:
				d["weight"] = weight
			if italic:
				d["italic"] = true
			d["center"] = U.v2_to_array(center)
			d["rot"] = snappedf(rot, 1e-5)
			if not alternatives.is_empty():
				d["alt"] = Array(alternatives)
			if not ink.is_empty():
				d["ink"] = ink
		IMAGE:
			d["image"] = image
			d["center"] = U.v2_to_array(center)
			d["size"] = U.v2_to_array(size)
			d["rot"] = snappedf(rot, 1e-5)
	return d


static func from_dict(d: Dictionary) -> Item:
	var it := Item.new()
	it.id = str(d.get("id", U.uid("i")))
	it.kind = str(d.get("kind", STROKE))
	it.frame = str(d.get("frame", ""))
	it.z = int(d.get("z", 0))
	it.page = int(d.get("page", 0))
	it.color = U.color_from(d.get("color"))
	it.width = float(d.get("width", 0.004))
	it.brush = str(d.get("brush", "pen"))
	match it.kind:
		STROKE:
			it.pts = U.unpack_floats(str(d.get("pts", "")))
		SHAPE:
			it.shape = str(d.get("shape", "rect"))
			it.fill = U.color_from(d.get("fill"), Color(0, 0, 0, 0))
			it.label = str(d.get("label", ""))
			if it.shape == "poly":
				var arr: Array = d.get("poly", [])
				for i in range(0, arr.size() - 1, 2):
					it.poly.append(Vector2(arr[i], arr[i + 1]))
			elif Shapes.is_line(it.shape):
				it.a = U.v2_from(d.get("a"))
				it.b = U.v2_from(d.get("b"))
				it.na = U.v2_from(d.get("na"))
				it.nb = U.v2_from(d.get("nb"))
				it.glue_a = (d.get("glue_a", {}) as Dictionary).duplicate()
				it.glue_b = (d.get("glue_b", {}) as Dictionary).duplicate()
				it.head_a = bool(d.get("head_a", false))
				it.head_b = bool(d.get("head_b", false))
			else:
				it.center = U.v2_from(d.get("center"))
				it.size = U.v2_from(d.get("size"), Shapes.default_size(it.shape))
				it.rot = float(d.get("rot", 0.0))
		TEXT:
			it.text = str(d.get("text", ""))
			it.font_size = float(d.get("font_size", 0.05))
			it.weight = clampi(int(d.get("weight", TextLayout.REGULAR)), TextLayout.MIN_WEIGHT, TextLayout.MAX_WEIGHT)
			it.italic = bool(d.get("italic", false))
			it.center = U.v2_from(d.get("center"))
			it.rot = float(d.get("rot", 0.0))
			it.alternatives = PackedStringArray(d.get("alt", []))
			it.ink = (d.get("ink", []) as Array).duplicate(true)
			it.refit_text()
		IMAGE:
			it.image = str(d.get("image", ""))
			it.center = U.v2_from(d.get("center"))
			it.size = U.v2_from(d.get("size"), Vector2(0.3, 0.2))
			it.rot = float(d.get("rot", 0.0))
	return it


func duplicate_item(new_id: bool = true) -> Item:
	var c := Item.from_dict(to_dict())
	if new_id:
		c.id = U.uid("i")
	return c
