class_name OverlayDraw
extends RefCounted
## Collects thick lines, discs and filled polygons in a frame's plane and turns them into one mesh: selection boxes, handles,
## cursors, lasso. (GL lines are one pixel wide and vanish in the headset, so everything is a ribbon.)

var _verts := PackedVector3Array()
var _uvs := PackedVector2Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()
var z := 0.0


func clear() -> void:
	_verts.clear()
	_uvs.clear()
	_cols.clear()
	_idx.clear()


func line(pts: PackedVector2Array, width: float, col: Color, closed: bool = false) -> void:
	var p3 := PackedVector3Array()
	var w := PackedFloat32Array()
	for p in pts:
		p3.append(Vector3(p.x, p.y, z))
		w.append(width)
	_append(StrokeMesher.ribbon_arrays(p3, w, col, closed, true))


func segment(a: Vector2, b: Vector2, width: float, col: Color) -> void:
	line(PackedVector2Array([a, b]), width, col, false)


func rect(r: Rect2, width: float, col: Color) -> void:
	line(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]), width, col, true)


func disc(c: Vector2, radius: float, col: Color) -> void:
	_append(StrokeMesher.ribbon_arrays(PackedVector3Array([Vector3(c.x, c.y, z)]), PackedFloat32Array([radius * 2.0]), col, false, true))


func ring(c: Vector2, radius: float, width: float, col: Color, n: int = 28) -> void:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / n
		pts.append(c + Vector2(cos(a), sin(a)) * radius)
	line(pts, width, col, true)


func polygon(poly: PackedVector2Array, col: Color) -> void:
	_append(StrokeMesher.fill_arrays(poly, col, z))


func _append(arrays: Array) -> void:
	if arrays.is_empty():
		return
	var base := _verts.size()
	_verts.append_array(arrays[Mesh.ARRAY_VERTEX])
	_uvs.append_array(arrays[Mesh.ARRAY_TEX_UV])
	_cols.append_array(arrays[Mesh.ARRAY_COLOR])
	for i in arrays[Mesh.ARRAY_INDEX]:
		_idx.append(i + base)


func build(mesh: ArrayMesh) -> void:
	mesh.clear_surfaces()
	if _verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_INDEX] = _idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


static func material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.render_priority = 120
	return m
