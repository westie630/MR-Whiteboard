class_name AnchorMarkers
extends Node3D
## The spatial anchors made visible (Settings > Display > Show spatial anchors): at every anchor that has a place in the room a small
## set of axes (red x, green y, blue z) with a label saying what it holds (a room, a canvas, the panels) and the start of its id.
## Anchors the headset has not placed yet are not drawn. Off by default; nothing is built until it is switched on.

const AXIS_LEN := 0.09
const AXIS_R := 0.0025
const LABEL_EM := 0.04
const COLORS := {"room": Color("#ffd166"), "canvas": Color("#4dd0c4"), "panels": Color("#b49bff"), "other": Color("#d0d6e0")}

var anchors: AnchorService
## Callables returning {uuid: "kind|name"} for the anchors their owner knows the use of (kind: room, canvas, panels).
var role_sources: Array[Callable] = []

var _marks: Dictionary = {}                # uuid -> Mark
var _on := false


func _ready() -> void:
	name = "AnchorMarkers"
	top_level = true                       # poses are world space
	_on = bool(App.val("show_anchors"))
	App.setting_changed.connect(func(k: String):
		if k == "show_anchors":
			_on = bool(App.val("show_anchors"))
			if not _on:
				_clear())


func is_on() -> bool:
	return _on


func _process(_dt: float) -> void:
	if not _on or anchors == null or not anchors.is_supported():
		return
	var roles := {}
	for src in role_sources:
		roles.merge(src.call(), true)
	var seen := {}
	for u in anchors.known():
		var id := str(u)
		if not anchors.has_pose(id):
			continue
		seen[id] = true
		var m: Mark = _marks.get(id)
		if m == null:
			m = Mark.new()
			m.build(self)
			_marks[id] = m
		var role := str(roles.get(id, "other|Anchor")).split("|")
		m.show_at(anchors.pose(id), role[0], role[1] if role.size() > 1 else "", id)
	for id in _marks.keys():
		if not seen.has(id):
			(_marks[id] as Mark).queue_free()
			_marks.erase(id)


func _clear() -> void:
	for m in _marks.values():
		(m as Mark).queue_free()
	_marks.clear()


## How many anchors are drawn now (tests, the debug panel).
func shown() -> int:
	return _marks.size()


static func _mat(c: Color, alpha: float, prio: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.render_priority = prio
	return m


## One anchor: axes, a dot at its origin and a label that always faces the viewer.
class Mark extends Node3D:
	var label: Label3D
	var _kind := ""
	var _dot_mat: StandardMaterial3D

	func build(parent: Node3D) -> void:
		parent.add_child(self)
		var dot := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.012
		s.height = 0.024
		s.radial_segments = 14
		s.rings = 7
		dot.mesh = s
		_dot_mat = AnchorMarkers._mat(Color.WHITE, 0.95, 120)
		dot.material_override = _dot_mat
		add_child(dot)
		for axis in [[Vector3.RIGHT, Color("#ff5a5a")], [Vector3.UP, Color("#5adf6a")], [Vector3.BACK, Color("#5a8cff")]]:
			var d: Vector3 = axis[0]
			var bar := MeshInstance3D.new()
			var c := CylinderMesh.new()
			c.top_radius = AnchorMarkers.AXIS_R
			c.bottom_radius = AnchorMarkers.AXIS_R
			c.height = AnchorMarkers.AXIS_LEN
			c.radial_segments = 6
			c.rings = 1
			bar.mesh = c
			bar.material_override = AnchorMarkers._mat(axis[1], 0.9, 119)
			bar.transform = Transform3D(Basis(Quaternion(Vector3.UP, d)), d * AnchorMarkers.AXIS_LEN * 0.5)
			add_child(bar)
		label = Label3D.new()
		label.font = TextLayout.font(600)
		label.font_size = 64
		label.pixel_size = AnchorMarkers.LABEL_EM / 64.0
		label.shaded = false
		label.no_depth_test = true
		label.render_priority = 121
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.outline_size = 16
		label.outline_modulate = Color(0.02, 0.03, 0.05, 0.85)
		label.position = Vector3(0, 0.05, 0)
		add_child(label)

	func show_at(xf: Transform3D, kind: String, what: String, uuid: String) -> void:
		global_transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		if kind != _kind:
			_kind = kind
			var c: Color = AnchorMarkers.COLORS.get(kind, AnchorMarkers.COLORS.other)
			_dot_mat.albedo_color = Color(c.r, c.g, c.b, 0.95)
			label.modulate = c.lightened(0.2)
		var t := "%s\n%s" % [what if what != "" else kind.capitalize(), uuid.substr(0, 8)]
		if label.text != t:
			label.text = t
