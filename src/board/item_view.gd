class_name ItemView
extends Node3D
## The 3D representation of one Item inside a frame: ink meshes (ribbons on canvases, tubes in 3D sketches), shape outlines, fills,
## arrowheads and text labels. Rebuilt from the item whenever it changes. `set_preview` moves it while it is being dragged,
## before the move is committed to the item's own data.

const TEXT_CURVE_STEP := 3.0              # how finely the outlines of the letters are followed on a curved desk (in pixels of a 64 px em)

var item: Item
var volume := false
var _layers: Array = []                   # MeshInstance3D / Label3D children

var _bend: DeskBend                       # the curved desk this view is on (found at every rebuild), or null


func setup(it: Item, in_volume: bool) -> void:
	item = it
	volume = in_volume
	name = it.id
	rebuild()


func rebuild() -> void:
	for n in _layers:
		if is_instance_valid(n):
			n.queue_free()
	_layers.clear()
	transform = Transform3D.IDENTITY
	_bend = null if volume else _find_bend()
	match item.kind:
		Item.STROKE:
			if volume:
				_build_tube()
			else:
				_build_ribbon()
		Item.SHAPE:
			_build_shape()
		Item.TEXT:
			_build_text(item.text, item.center, item.rot, item.font_size, item.color, Brushes.priority("pen", item.z) + 1, item.weight, item.italic)


## Move the view while it is dragged. `t` is a transform of the canvas (a move, a turn, a resize); on a curved desk the view follows it as a
## whole along the bent surface: the same move seen from where the item stands, without bending the item again until it is let go.
func set_preview(t: Transform3D) -> void:
	if _bend == null:
		transform = t
		return
	var c0 := item.bounds().get_center()
	var p1 := t * Vector3(c0.x, c0.y, 0.0)
	var f0 := _bend.frame_at(c0)
	var f1 := _bend.frame_at(Vector2(p1.x, p1.y), p1.z)
	transform = f1 * Transform3D(t.basis, Vector3.ZERO) * f0.affine_inverse()


## The curved desk of the frame this view is in.
func _find_bend() -> DeskBend:
	var n: Node = get_parent()
	while n != null:
		if n is FrameNode:
			return (n as FrameNode).bend
		n = n.get_parent()
	return null


# ------------------------------------------------------------------------------------------------ strokes

func _stroke_points() -> Array:
	var p := PackedVector3Array()
	var w := PackedFloat32Array()
	for i in item.point_count():
		p.append(item.pt(i))
		w.append(Brushes.width_at(item.brush, item.width, item.pressure(i)))
	return [p, w]


func _build_ribbon() -> void:
	var pw := _stroke_points()
	if _bend != null:
		pw = DeskBend.subdivide(pw[0], pw[1], false, _bend.cut_pitch())
	var def := Brushes.get_def(item.brush)
	var col := Brushes.color_for(item.brush, item.color)
	var arrays := StrokeMesher.ribbon_arrays(pw[0], pw[1], col, false, bool(def.get("caps", true)), float(def.get("nib", -1.0)))
	_add_mesh(arrays, Brushes.canvas_material(item.brush, Brushes.priority(item.brush, item.z)))


func _build_tube() -> void:
	var pw := _stroke_points()
	var col := Brushes.color_for(item.brush, item.color)
	var arrays := StrokeMesher.tube_arrays(pw[0], pw[1], col, 6)
	_add_mesh(arrays, Brushes.tube_material(item.brush))


# ------------------------------------------------------------------------------------------------ shapes

func _build_shape() -> void:
	var col := Color(item.color.r, item.color.g, item.color.b, item.color.a)
	var brush := item.brush if item.brush != "highlighter" else "pen"
	var prio := Brushes.priority(brush, item.z)
	var mat := Brushes.canvas_material(brush, prio)
	var is_line := item.is_line()
	# fill first (under the outline)
	if item.fill.a > 0.01 and not is_line:
		var poly := item.poly if item.shape == "poly" else Shapes.world_fill_poly(item)
		_add_mesh(StrokeMesher.fill_arrays(poly, item.fill), Brushes.canvas_material("pen", Brushes.priority("pen", item.z, "fill")), true)
	if is_line:
		var path := Shapes.line_points(item)
		var n := path.size()
		if n >= 2:
			var head_len := maxf(0.022, item.width * 5.0)
			var ends_b := item.shape == "arrow" or item.shape == "darrow" or item.head_b or item.shape == "elbow"
			var ends_a := item.shape == "darrow" or item.head_a
			var shaft := PackedVector2Array(path)
			if ends_b:
				var d: Vector2 = (path[n - 1] - path[n - 2]).normalized()
				shaft[n - 1] = path[n - 1] - d * head_len * 0.6
				_add_mesh(StrokeMesher.fill_arrays(Shapes.arrow_head(path[n - 1], d, item.width), col), Brushes.canvas_material("pen", prio), true)
			if ends_a:
				var d2: Vector2 = (path[0] - path[1]).normalized()
				shaft[0] = path[0] - d2 * head_len * 0.6
				_add_mesh(StrokeMesher.fill_arrays(Shapes.arrow_head(path[0], d2, item.width), col), Brushes.canvas_material("pen", prio), true)
			_add_ribbon(shaft, false, col, mat)
	elif item.shape == "poly":
		_add_ribbon(item.poly, true, col, mat)
	else:
		for o in Shapes.world_outlines(item):
			_add_ribbon(o.pts, o.closed, col, mat)
	if item.label != "" and not is_line:
		var box := Shapes.label_box(item.shape, item.size)
		var unit := TextLayout.measure(item.label, 1.0)
		var lines := maxi(item.label.count("\n") + 1, 1)
		var em := minf(minf(box.x / maxf(unit.x, 0.01), box.y / (1.25 * lines)), 0.06)
		_build_text(item.label, item.center, item.rot, em, item.color, prio + 1)


func _add_ribbon(pts: PackedVector2Array, closed: bool, col: Color, mat: Material) -> void:
	var p3 := PackedVector3Array()
	var w := PackedFloat32Array()
	for p in pts:
		p3.append(Vector3(p.x, p.y, 0.0))
		w.append(item.width)
	if _bend != null:
		var sub := DeskBend.subdivide(p3, w, closed, _bend.cut_pitch())
		p3 = sub[0]
		w = sub[1]
	_add_mesh(StrokeMesher.ribbon_arrays(p3, w, col, closed, not closed), mat)


# ------------------------------------------------------------------------------------------------ text

func _build_text(txt: String, center: Vector2, rot: float, em: float, col: Color, prio: int, weight: int = TextLayout.REGULAR, italic: bool = false) -> void:
	if _bend != null:
		_build_text_mesh(txt, center, rot, em, col, prio, weight, italic)
		return
	var l := Label3D.new()
	l.text = txt
	l.font = TextLayout.font(weight, italic)
	l.font_size = 64
	l.pixel_size = em / 64.0
	l.modulate = col
	l.outline_size = 0
	l.shaded = false
	l.double_sided = true
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	l.render_priority = clampi(prio, -128, 126)
	l.position = Vector3(center.x, center.y, 0.0003)
	l.rotation = Vector3(0, 0, rot)
	add_child(l)
	_layers.append(l)


## On a curved desk text is geometry, like ink: a Label3D is a flat quad that cannot bend. The letters are the font's outlines, so they stay
## sharp at any size; the strips make them bend with the surface.
func _build_text_mesh(txt: String, center: Vector2, rot: float, em: float, col: Color, prio: int, weight: int, italic: bool) -> void:
	var tm := TextMesh.new()
	tm.text = txt
	tm.font = TextLayout.font(weight, italic)
	tm.font_size = 64
	tm.pixel_size = em / 64.0
	tm.depth = 0.0
	tm.curve_step = TEXT_CURVE_STEP
	tm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if tm.get_surface_count() == 0:
		return
	var src := tm.surface_get_arrays(0)
	var sv: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	var n := sv.size()
	var verts := PackedVector3Array()
	verts.resize(n)
	var cs := cos(rot)
	var sn := sin(rot)
	for i in n:
		var p := sv[i]
		verts[i] = Vector3(center.x + p.x * cs - p.y * sn, center.y + p.x * sn + p.y * cs, 0.0003)
	var uvs := PackedVector2Array()
	uvs.resize(n)
	var cols := PackedColorArray()
	cols.resize(n)
	cols.fill(col)
	var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX] if src[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(n)
		for i in n:
			idx[i] = i
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	_add_mesh(arrays, Brushes.canvas_material("pen", clampi(prio, -128, 126)), true)


# ------------------------------------------------------------------------------------------------ helpers

## `cut`: on a curved desk, the triangles are cut into strips (fills and letters; lines are already made of short pieces, see DeskBend.subdivide).
func _add_mesh(arrays: Array, mat: Material, cut: bool = false) -> void:
	if arrays.is_empty():
		return
	var mi := MeshInstance3D.new()
	if _bend != null:
		if cut:
			arrays = DeskBend.slice(arrays, _bend.cut_pitch())
		mat = _bend.material(mat)
		mi.custom_aabb = AABB(Vector3.ONE * -DeskBend.FAR, Vector3.ONE * (2.0 * DeskBend.FAR))
	mi.mesh = StrokeMesher.to_mesh(arrays)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_layers.append(mi)
