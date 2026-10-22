class_name HandCursor
extends Node3D
## What a hand (or the stylus) shows where it points or touches: a ring on the target, on the menu or on a canvas, and on a canvas the
## things it can pinch there, the four corners (change the extent) and the bar under it (carry it). Whichever it is on lights up. There is
## no line from the hand to the ring. The stylus shows this only while it points from a distance or holds something: touching a canvas it
## draws (the tool's own cursor is drawn into the canvas).

const CORNER_R := InputTuning.CORNER_R
const BAR_LEN := InputTuning.BAR_LEN
const BAR_R := InputTuning.BAR_R
const COL_GRAB := Color(1.0, 0.72, 0.2, 1.0)          # a corner or the bar the ray is on: pinch picks the canvas up
const COL_IDLE := Color(0.75, 0.78, 0.85)
const COL_RING := Color(1, 1, 1, 0.9)
const COL_UI := Color(0.25, 0.88, 0.78, 0.95)         # the menu
const COL_ITEM := Color(0.45, 0.95, 1.0, 0.95)        # a shape, line or stroke: pinch selects / drags it
const COL_DOWN := Color(0.4, 1.0, 0.7, 1.0)           # pressed

var _sides := {}


func _ready() -> void:
	for side in ["left", "right", "pen"]:
		var s := {}
		s.ring_mat = _mat(COL_RING)
		s.ring = _mesh(_ring_mesh(), s.ring_mat)
		s.dot = _mesh(_sphere(0.5), s.ring_mat)
		s.corners = []
		s.corner_mats = []
		for i in 4:
			var cm := _mat(COL_IDLE)
			s.corner_mats.append(cm)
			s.corners.append(_mesh(_sphere(CORNER_R), cm))
		s.bar_mat = _mat(COL_IDLE)
		s.bar = _mesh(_capsule(), s.bar_mat)
		_sides[side] = s


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 105
	return m


func _mesh(m: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return mi


func _ring_mesh() -> Mesh:
	var t := TorusMesh.new()
	t.inner_radius = 0.7
	t.outer_radius = 1.0
	t.rings = 24
	t.ring_segments = 8
	return t


func _sphere(r: float) -> Mesh:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 14
	sm.rings = 7
	return sm


func _capsule() -> Mesh:
	var cm := CapsuleMesh.new()
	cm.radius = BAR_R
	cm.height = BAR_LEN
	cm.radial_segments = 12
	cm.rings = 3
	return cm


func hide_all() -> void:
	for side in _sides:
		_hide_side(_sides[side])


func _hide_side(s: Dictionary) -> void:
	(s.ring as MeshInstance3D).visible = false
	(s.dot as MeshInstance3D).visible = false
	(s.bar as MeshInstance3D).visible = false
	for c in s.corners:
		(c as MeshInstance3D).visible = false


## hands: side -> HandInput; menu: source ("left" | "right" | "pen") -> {point, poke} for what is on the menu; hover: HandController.hover;
## head: the head position; stylus_side: the hand holding the stylus; pen: the stylus (its ring is shown while it points at the menu).
func update(hands: Dictionary, menu: Dictionary, hover: Dictionary, head: Vector3, stylus_side: String, pen: PenState = null) -> void:
	for side in ["left", "right"]:
		var s: Dictionary = _sides[side]
		var h: HandInput = hands[side]
		_hide_side(s)
		if not h.tracked or side == stylus_side:
			continue
		var hv: Dictionary = hover.get(side, {})
		if menu.has(side):
			var m: Dictionary = menu[side]
			_ring(s, m.point, "ui", h.pinching, bool(m.poke), head)
		elif not hv.is_empty() and is_instance_valid(hv.fn):
			_ring(s, hv.point, str(hv.kind), h.pinching, false, head)
			_chrome(s, hv)
	var ps: Dictionary = _sides["pen"]
	_hide_side(ps)
	if pen != null and pen.tracked:
		var pv: Dictionary = hover.get("pen", {})
		if menu.has("pen"):
			var pm: Dictionary = menu["pen"]
			_ring(ps, pm.point, "ui", pen.front or pen.down, bool(pm.poke), head)
		elif not pv.is_empty() and is_instance_valid(pv.fn) and (not bool(pv.get("direct", false)) or str(pv.kind) == "hold"):
			_ring(ps, pv.point, str(pv.kind), pen.front, false, head)
			_chrome(ps, pv)


## A ring on the target, facing the head and the same size on the eye at any distance; a dot in it while pressed or poking.
func _ring(s: Dictionary, target: Vector3, kind: String, pressed: bool, poke: bool, head: Vector3) -> void:
	var col := COL_RING
	match kind:
		"ui":
			col = COL_UI
		"item":
			col = COL_ITEM
		"bar", "corner", "hold":
			col = COL_GRAB
	if pressed:
		col = COL_DOWN
	(s.ring_mat as StandardMaterial3D).albedo_color = col
	var dist := head.distance_to(target)
	var r := clampf(InputTuning.RING_R * dist / 0.7, InputTuning.RING_MIN, InputTuning.RING_MAX)
	var n := (head - target).normalized()
	var up := Vector3.UP if absf(n.y) < 0.95 else Vector3.RIGHT
	var x := up.cross(n).normalized()
	var z := x.cross(n).normalized()
	var ring := s.ring as MeshInstance3D
	var scale_r := r * (0.65 if pressed else 1.0)
	ring.global_transform = Transform3D(Basis(x * scale_r, n * scale_r * 0.3, z * scale_r), target + n * 0.002)
	ring.visible = true
	var dot := s.dot as MeshInstance3D
	dot.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * r * 0.5), target + n * 0.002)
	dot.visible = pressed or poke


func _chrome(s: Dictionary, hv: Dictionary) -> void:
	var fn: FrameNode = hv.fn
	var kind := str(hv.kind)
	var held := str(hv.get("held", ""))
	var xf := fn.global_transform
	var cs := HandController.corner_points(fn)
	for i in 4:
		var c := s.corners[i] as MeshInstance3D
		var lit: bool = (kind == "corner" and int(hv.corner) == i) or (kind == "hold" and held == "corner" and int(hv.corner) == i)
		var a := 1.0 if lit else (0.28 if kind == "item" else 0.5)
		(s.corner_mats[i] as StandardMaterial3D).albedo_color = Color(COL_GRAB.r, COL_GRAB.g, COL_GRAB.b, a) if lit else Color(1, 1, 1, a)
		c.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * (1.35 if lit else 1.0)), xf * Vector3((cs[i] as Vector2).x, (cs[i] as Vector2).y, 0.0))
		c.visible = true
	var bc := HandController.bar_center(fn)
	var bar := s.bar as MeshInstance3D
	var bar_lit: bool = kind == "bar" or (kind == "hold" and held == "bar")
	var ba := 1.0 if bar_lit else (0.28 if kind == "item" else 0.5)
	(s.bar_mat as StandardMaterial3D).albedo_color = Color(COL_GRAB.r, COL_GRAB.g, COL_GRAB.b, ba) if bar_lit else Color(1, 1, 1, ba)
	var x_dir := xf.basis.x.normalized()
	bar.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, x_dir)), xf * Vector3(bc.x, bc.y, 0.0))
	bar.visible = true
