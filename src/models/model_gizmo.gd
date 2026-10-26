class_name ModelGizmo
extends Node3D
## The handles round the selected 3D model, in one of three modes (ModelController decides what holding one does):
##   move    an arrow along each axis (slide along it), a square between each two axes (slide in that plane: the floor's is the yellow-green
##           one with the room's axes), and the ball in the middle (move freely)
##   rotate  a ring round each axis (turn about it)
##   scale   a cube on each corner of the model's box (make it bigger or smaller, about its middle) and a cube at the end of each of its own
##           axes (stretch it along that axis only)
## Move and rotate use the model's own axes or the room's (`space`); stretching is always along the model's own. Handles are drawn over
## everything (no depth test) and keep the same size on the eye at any distance (`s` grows with the distance from the head), so they can be
## pointed at from across the room and touched up close. X is red, Y green, Z blue; the handle a pointer is on is lit, the one held is amber.

const COLORS := [Color(0.96, 0.36, 0.38), Color(0.5, 0.88, 0.36), Color(0.34, 0.58, 1.0)]
const FREE := Color(0.96, 0.97, 1.0)
const HELD := Color(1.0, 0.8, 0.3)
const AXIS_IDS := ["x", "y", "z"]
const PLANE_AXES := {"pyz": [1, 2, 0], "pxz": [0, 2, 1], "pxy": [0, 1, 2]}   # the two axes of the plane, and its normal

var mode := "move"
var space := "local"
var center := Vector3.ZERO                 # the model's middle (world)
var axes := Basis.IDENTITY                 # the gizmo's axes (orthonormal): the model's or the room's
var own := Basis.IDENTITY                  # the model's own axes (orthonormal)
var half := Vector3.ONE * 0.1              # the model's half sizes along its own axes (m)
var extent := Vector3.ONE * 0.1            # how far the model reaches along each gizmo axis (m)
var s := 0.015                             # handle size (m), from the distance to the head
var ring_r := 0.2
var hot := ""                              # the handle a pointer is on
var held := ""                             # the handle being held
var target: ModelNode

var _parts: Dictionary = {}                # handle id -> Array of MeshInstance3D
var _mats: Dictionary = {}                 # handle id -> StandardMaterial3D
var _base: Dictionary = {}                 # handle id -> its colour
var _rings: Dictionary = {}                # "rx".. -> TorusMesh
var _label: Label3D
var readout := ""


func _init() -> void:
	name = "ModelGizmo"
	visible = false
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 12
	cyl.rings = 1
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.0
	cone.height = 1.0
	cone.radial_segments = 16
	cone.rings = 1
	var ball := SphereMesh.new()
	ball.radius = 1.0
	ball.height = 2.0
	ball.radial_segments = 16
	ball.rings = 8
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * 2.0
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * 2.0
	for i in 3:
		_handle("m" + AXIS_IDS[i], COLORS[i], [cyl, cone])
		_handle("s" + AXIS_IDS[i], COLORS[i], [cyl, cube])
		var t := TorusMesh.new()
		t.rings = 64
		t.ring_segments = 8
		_rings["r" + AXIS_IDS[i]] = t
		_handle("r" + AXIS_IDS[i], COLORS[i], [t])
	for id in PLANE_AXES:
		_handle(id, COLORS[int(PLANE_AXES[id][2])], [quad], 0.55)
	_handle("mc", FREE, [ball], 0.9)
	for k in 8:
		_handle("c%d" % k, FREE, [cube], 0.95)
	_label = Label3D.new()
	_label.font = TextLayout.font(600)
	_label.font_size = 64
	_label.pixel_size = 0.02 / 64.0
	_label.shaded = false
	_label.no_depth_test = true
	_label.render_priority = 127
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.outline_size = 12
	_label.outline_modulate = Color(0, 0, 0, 0.6)
	_label.modulate = HELD
	_label.visible = false
	add_child(_label)


func _handle(id: String, col: Color, meshes: Array, alpha: float = 0.95) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 120
	mat.albedo_color = Color(col.r, col.g, col.b, alpha)
	_mats[id] = mat
	_base[id] = Color(col.r, col.g, col.b, alpha)
	var list: Array = []
	for m in meshes:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		list.append(mi)
	_parts[id] = list


## The handles of a mode.
static func handles_of(m: String) -> Array:
	match m:
		"move":
			return ["mx", "my", "mz", "pyz", "pxz", "pxy", "mc"]
		"rotate":
			return ["rx", "ry", "rz"]
		"scale":
			return ["sx", "sy", "sz", "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7"]
	return []


## Lays the handles out round `node` (null hides them). `room` is the room's basis (for room axes), `head` the head's position.
func layout(node: ModelNode, m: String, axes_space: String, room: Basis, head: Vector3) -> void:
	target = node
	visible = node != null and node.visible
	if not visible:
		return
	mode = m
	space = axes_space
	var wb := node.world_box()
	center = (wb.xf as Transform3D).origin
	own = (wb.xf as Transform3D).basis
	half = (wb.half as Vector3).max(Vector3.ONE * 0.005)
	axes = own if space == "local" else room.orthonormalized()
	for i in 3:
		var e := 0.0
		for j in 3:
			e += absf(axes[i].dot(own[j])) * half[j]
		extent[i] = e
	s = clampf(head.distance_to(center) * InputTuning.GIZMO_SIZE, InputTuning.GIZMO_SIZE_MIN, InputTuning.GIZMO_SIZE_MAX)
	ring_r = half.length() + s * 3.0
	var shown := handles_of(mode)
	for id in _parts:
		var on := shown.has(id)
		for mi in _parts[id]:
			(mi as MeshInstance3D).visible = on
		if on:
			var lit: bool = id == held or (held == "" and id == hot)
			var c: Color = HELD if id == held else _base[id]
			(_mats[id] as StandardMaterial3D).albedo_color = c.lightened(0.35) if lit and id != held else c
	match mode:
		"move":
			_layout_move()
		"rotate":
			_layout_rotate()
		"scale":
			_layout_scale()
	_label.visible = readout != "" and held != ""
	if _label.visible:
		_label.text = readout
		_label.global_position = center + Vector3.UP * (extent.y + s * 6.0)


func _grow(id: String) -> float:
	return 1.3 if id == hot or id == held else 1.0


func _layout_move() -> void:
	for i in 3:
		var id: String = "m" + AXIS_IDS[i]
		var a := axes[i]
		var g := _grow(id)
		var len := extent[i] + s * 5.0
		var shaft := _parts[id][0] as MeshInstance3D
		shaft.global_transform = _along(a, center + a * len * 0.5, s * 0.22 * g, len)
		var tip := _parts[id][1] as MeshInstance3D
		tip.global_transform = _along(a, center + a * (len + s * 1.6 * g), s * 1.0 * g, s * 3.2 * g)
	for id in PLANE_AXES:
		var ax: Array = PLANE_AXES[id]
		var u := axes[int(ax[0])]
		var v := axes[int(ax[1])]
		var n := axes[int(ax[2])]
		var q := _parts[id][0] as MeshInstance3D
		var h := s * 1.6 * _grow(id)
		q.global_transform = Transform3D(Basis(u * h, v * h, n), plane_center(id))
	var b := _parts["mc"][0] as MeshInstance3D
	b.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * s * 1.3 * _grow("mc")), center)


func plane_center(id: String) -> Vector3:
	var ax: Array = PLANE_AXES[id]
	return center + (axes[int(ax[0])] + axes[int(ax[1])]) * s * 4.5


func _layout_rotate() -> void:
	for i in 3:
		var id: String = "r" + AXIS_IDS[i]
		var t: TorusMesh = _rings[id]
		var tube := s * 0.28 * _grow(id) / ring_r
		if absf(t.inner_radius - (1.0 - tube)) > 0.002:
			t.inner_radius = 1.0 - tube
			t.outer_radius = 1.0 + tube
		var a := axes[i]
		var u := axes[(i + 1) % 3]
		var w := axes[(i + 2) % 3]
		# a torus lies round its y axis ((w, a, u) is a right-handed turn of (x, y, z))
		(_parts[id][0] as MeshInstance3D).global_transform = Transform3D(Basis(w * ring_r, a * ring_r, u * ring_r), center)


func _layout_scale() -> void:
	for i in 3:
		var id: String = "s" + AXIS_IDS[i]
		var a := own[i]
		var g := _grow(id)
		var from := center + a * half[i]
		var to := axis_cube(i)
		var line := _parts[id][0] as MeshInstance3D
		line.global_transform = _along(a, (from + to) * 0.5, s * 0.18, from.distance_to(to))
		var cube := _parts[id][1] as MeshInstance3D
		cube.global_transform = Transform3D(own.scaled(Vector3.ONE * s * 1.1 * g), to)
	for k in 8:
		var id := "c%d" % k
		(_parts[id][0] as MeshInstance3D).global_transform = Transform3D(own.scaled(Vector3.ONE * s * 1.0 * _grow(id)), corner(k))


func axis_cube(i: int) -> Vector3:
	return center + own[i] * (half[i] + s * 6.0)


## A corner of the model's box, pushed out a little along its diagonal so the cube sits on it.
func corner(k: int) -> Vector3:
	var l := Vector3(half.x * (1 if k & 1 else -1), half.y * (1 if k & 2 else -1), half.z * (1 if k & 4 else -1))
	var p := center + own * l
	return p + (p - center).normalized() * s * 1.2


## A transform that makes a unit cylinder (along y) of `radius` and `length` lie along `a` with its middle at `mid`.
func _along(a: Vector3, mid: Vector3, radius: float, length: float) -> Transform3D:
	var y := a.normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
	var z := x.cross(y).normalized()
	return Transform3D(Basis(x * radius, y * length, z * radius), mid)


## The handle a pointer is on: a ray from `o` along `d`, or (`direct`) the pinch point `p` touching it. {id, t, dist} or {}.
func pick(o: Vector3, d: Vector3, p: Vector3, direct: bool) -> Dictionary:
	if not visible:
		return {}
	d = d.normalized()
	var best := {}
	var best_score := INF
	for id in handles_of(mode):
		var r := _measure(id, o, d, p, direct)
		if r.is_empty():
			continue
		var tol := s * 2.6 + 0.012 if direct else s * 1.9
		var dist := float(r.dist)
		if dist > tol:
			continue
		var score := dist / tol + float(r.t) * 0.02
		if score < best_score:
			best_score = score
			best = {"id": id, "t": float(r.t), "dist": dist}
	return best


## How far the pointer is from a handle: {dist, t (along the ray; 0 when touching)}.
func _measure(id: String, o: Vector3, d: Vector3, p: Vector3, direct: bool) -> Dictionary:
	match id:
		"mx", "my", "mz":
			var a := axes[AXIS_IDS.find(id.substr(1))]
			var len := extent[AXIS_IDS.find(id.substr(1))] + s * 5.0
			return _to_segment(center + a * s * 2.0, center + a * (len + s * 3.2), o, d, p, direct)
		"pyz", "pxz", "pxy":
			return _to_point(plane_center(id), o, d, p, direct, s * 0.8)
		"mc":
			return _to_point(center, o, d, p, direct)
		"rx", "ry", "rz":
			return _to_ring(axes[AXIS_IDS.find(id.substr(1))], o, d, p, direct)
		"sx", "sy", "sz":
			return _to_point(axis_cube(AXIS_IDS.find(id.substr(1))), o, d, p, direct)
	if id.begins_with("c"):
		return _to_point(corner(int(id.substr(1))), o, d, p, direct)
	return {}


static func _to_point(q: Vector3, o: Vector3, d: Vector3, p: Vector3, direct: bool, slack: float = 0.0) -> Dictionary:
	if direct:
		return {"dist": maxf(p.distance_to(q) - slack, 0.0), "t": 0.0}
	var t := maxf((q - o).dot(d), 0.0)
	return {"dist": maxf((o + d * t).distance_to(q) - slack, 0.0), "t": t}


static func _to_segment(a: Vector3, b: Vector3, o: Vector3, d: Vector3, p: Vector3, direct: bool) -> Dictionary:
	if direct:
		var ab := b - a
		var k := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		return {"dist": p.distance_to(a + ab * k), "t": 0.0}
	var pts := Geometry3D.get_closest_points_between_segments(o, o + d * 100.0, a, b)
	return {"dist": (pts[0] as Vector3).distance_to(pts[1]), "t": o.distance_to(pts[0])}


func _to_ring(a: Vector3, o: Vector3, d: Vector3, p: Vector3, direct: bool) -> Dictionary:
	if direct:
		var r := p - center
		var h := r.dot(a)
		var flat := (r - a * h).length()
		return {"dist": Vector2(flat - ring_r, h).length(), "t": 0.0}
	var u := a.cross(Vector3.UP if absf(a.y) < 0.95 else Vector3.RIGHT).normalized()
	var w := a.cross(u).normalized()
	var best := INF
	var best_t := 0.0
	for k in 72:
		var ang := TAU * k / 72.0
		var q := center + (u * cos(ang) + w * sin(ang)) * ring_r
		var t := maxf((q - o).dot(d), 0.0)
		var dist := (o + d * t).distance_to(q)
		if dist < best:
			best = dist
			best_t = t
	return {"dist": best, "t": best_t}
