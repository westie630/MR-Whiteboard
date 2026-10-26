class_name LiveStroke
extends Node3D
## The stroke being drawn right now. Points arrive from the pen, the mesh is rebuilt once per frame. To keep that cheap on the
## headset a long stroke is frozen into chunks and only the tail is rebuilt (opaque brushes; translucent ones are rebuilt whole,
## otherwise the overlaps at chunk joints would show).

const CHUNK := 70

var volume := false
var brush := "pen"
var color := Color.WHITE
var width := 0.004
var prio := 0
var pts := PackedFloat32Array()           # x, y, z, pressure
var times := PackedFloat32Array()         # seconds (app clock) at each point

var _frozen := 0                          # points already frozen into chunk meshes
var _tail: MeshInstance3D
var _dirty := false
var _t0 := 0.0


func begin(in_volume: bool, brush_id: String, col: Color, w: float, priority: int) -> void:
	volume = in_volume
	brush = brush_id
	color = col
	width = w
	prio = priority
	_t0 = 0.0
	_tail = MeshInstance3D.new()
	_tail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tail.material_override = _material()
	_uncull(_tail)
	add_child(_tail)


func _material() -> Material:
	if volume:
		return Brushes.tube_material(brush)
	var m := Brushes.canvas_material(brush, prio)
	var bend := _bend()
	return bend.material(m) if bend != null else m


## The curved desk of the canvas this stroke is drawn on, or null.
func _bend() -> DeskBend:
	var n: Node = get_parent()
	while n != null:
		if n is FrameNode:
			return (n as FrameNode).bend
		n = n.get_parent()
	return null


func add_point(x: float, y: float, z: float, pressure: float) -> void:
	pts.append_array(PackedFloat32Array([x, y, z, pressure]))
	times.append(Time.get_ticks_msec() / 1000.0 - _t0)
	_dirty = true


func point_count() -> int:
	return pts.size() / 4


func last_point() -> Vector3:
	var n := point_count()
	return Vector3(pts[n * 4 - 4], pts[n * 4 - 3], pts[n * 4 - 2]) if n > 0 else Vector3.ZERO


func flush() -> void:
	if not _dirty:
		return
	_dirty = false
	var n := point_count()
	var def := Brushes.get_def(brush)
	var opaque: bool = float(def.alpha) >= 0.99 and not def.get("add", false)
	if opaque and n - _frozen > CHUNK * 2:
		_freeze(_frozen, _frozen + CHUNK)
		_frozen += CHUNK
	var start := maxi(_frozen - 2, 0)
	_tail.mesh = _mesh_for(start, n)


func _freeze(from: int, to: int) -> void:
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _material()
	_uncull(mi)
	mi.mesh = _mesh_for(maxi(from - 2, 0), to + 1)
	add_child(mi)


func _mesh_for(from: int, to: int) -> ArrayMesh:
	var p := PackedVector3Array()
	var w := PackedFloat32Array()
	for i in range(from, mini(to, point_count())):
		p.append(Vector3(pts[i * 4], pts[i * 4 + 1], pts[i * 4 + 2]))
		w.append(Brushes.width_at(brush, width, pts[i * 4 + 3]))
	var col := Brushes.color_for(brush, color)
	var arrays: Array
	if not volume and _bend() != null:
		var sub := DeskBend.subdivide(p, w, false, _bend().cut_pitch())
		p = sub[0]
		w = sub[1]
	if volume:
		arrays = StrokeMesher.tube_arrays(p, w, col, 6)
	else:
		var def := Brushes.get_def(brush)
		arrays = StrokeMesher.ribbon_arrays(p, w, col, false, bool(def.get("caps", true)), float(def.get("nib", -1.0)))
	return StrokeMesher.to_mesh(arrays)


## On a curved desk the mesh lies far from where its (flat) bounds say: it must not be culled by them.
func _uncull(mi: MeshInstance3D) -> void:
	if not volume and _bend() != null:
		mi.custom_aabb = AABB(Vector3.ONE * -DeskBend.FAR, Vector3.ONE * (2.0 * DeskBend.FAR))


func clear_meshes() -> void:
	for c in get_children():
		c.queue_free()
