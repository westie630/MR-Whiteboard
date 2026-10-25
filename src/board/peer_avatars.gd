class_name PeerAvatars
extends Node3D
## The others in the session, drawn in the room where they are: a name tag over each head, the tip of each stylus with a short ray along it
## (brighter while it is pressed), and for somebody who is not in the same room a soft orb for the head with its gaze. Two headsets that
## are lined up on the same room (both aligned to points: both "together") see the real people, so there they get the tag and the stylus
## only. Nobody is drawn while this headset has no place in the shared space yet (it has not lined up, or the owner has not). The two
## points an alignment was made from stay marked for a while afterwards, to check them by eye. Poses arrive a dozen times a second and
## are smoothed here.

const TAG_EM := 0.05                       # height of a name tag's text (m)
const TAG_LIFT := 0.27                     # how far over the head it floats
const RAY_LEN := 0.14
const MARK := Color("#ffd166")

var session: Session

var _avatars: Dictionary = {}              # id -> Avatar
var _marks: Node3D
var _mark_nodes: Array = []


func _ready() -> void:
	name = "PeerAvatars"
	_marks = Node3D.new()
	_marks.name = "AlignMarks"
	_marks.visible = false
	add_child(_marks)
	for i in 2:
		var m := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.014
		s.height = 0.028
		s.radial_segments = 14
		s.rings = 7
		m.mesh = s
		m.material_override = _mat(MARK, 1.0, 126)
		var pole := MeshInstance3D.new()
		var c := CylinderMesh.new()
		c.top_radius = 0.0025
		c.bottom_radius = 0.0025
		c.height = 0.4
		c.radial_segments = 6
		c.rings = 1
		pole.mesh = c
		pole.position = Vector3(0, 0.2, 0)
		pole.material_override = _mat(Color(MARK.r, MARK.g, MARK.b, 0.5), 0.5, 125)
		m.add_child(pole)
		var l := Label3D.new()
		l.text = str(i + 1)
		l.font = TextLayout.font(700)
		l.font_size = 64
		l.pixel_size = 0.05 / 64.0
		l.shaded = false
		l.no_depth_test = true
		l.render_priority = 127
		l.modulate = MARK
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.position = Vector3(0, 0.46, 0)
		m.add_child(l)
		_marks.add_child(m)
		_mark_nodes.append(m)


## Drop whoever has left; names and colours are taken over on the next frame.
func refresh() -> void:
	for id in _avatars.keys():
		if session == null or not session.peers.has(id) or session.role == Session.Role.NONE:
			(_avatars[id] as Node).queue_free()
			_avatars.erase(id)


func _process(delta: float) -> void:
	if session == null or session.role == Session.Role.NONE or session.phase != "live" or not session.in_shared_space():
		for a in _avatars.values():
			(a as Avatar).visible = false
		_marks.visible = false
		return
	var f := session.align_world()
	var here_physical := session.align_mode == "points"
	var seen := {}
	for e in session.others():
		var id := int(e.id)
		seen[id] = true
		var a: Avatar = _avatars.get(id)
		if a == null:
			a = Avatar.new()
			a.build(self)
			_avatars[id] = a
		var head_w: Transform3D = f * (e.head as Transform3D)
		var physical := here_physical and str(e.align) == "points"
		a.show_pose(str(e.name), e.color as Color, head_w, bool(e.tracked), f * (e.tip as Vector3), (f.basis * (e.dir as Vector3)).normalized(), bool(e.down), physical, delta)
	for id in _avatars.keys():
		if not seen.has(id):
			(_avatars[id] as Avatar).visible = false
	# the two points of the alignment
	var show_marks := here_physical and session.now() < session.align_marks_until
	_marks.visible = show_marks
	if show_marks:
		var left := session.align_marks_until - session.now()
		var alpha := clampf(left / 3.0, 0.0, 1.0)
		(_mark_nodes[0] as Node3D).position = f.origin
		(_mark_nodes[1] as Node3D).position = f * Vector3(session.align_span, 0.0, 0.0)
		for m in _mark_nodes:
			((m as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.a = alpha


static func _mat(c: Color, alpha: float, prio: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.render_priority = prio
	return m


## One person: head (orb and gaze, when they are not in the same room), name tag, stylus tip and ray.
class Avatar extends Node3D:
	var orb: MeshInstance3D
	var gaze: MeshInstance3D
	var tag: Label3D
	var tip: MeshInstance3D
	var ray: MeshInstance3D
	var _orb_mat: StandardMaterial3D
	var _tip_mat: StandardMaterial3D
	var _ray_mat: StandardMaterial3D
	var _color := Color.WHITE
	var _seeded := false
	var _head := Vector3.ZERO
	var _tip := Vector3.ZERO

	func build(parent: Node3D) -> void:
		parent.add_child(self)
		_orb_mat = PeerAvatars._mat(Color.WHITE, 0.45, 100)
		_tip_mat = PeerAvatars._mat(Color.WHITE, 0.95, 123)
		_ray_mat = PeerAvatars._mat(Color.WHITE, 0.55, 122)
		orb = MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.085
		s.height = 0.17
		s.radial_segments = 20
		s.rings = 10
		orb.mesh = s
		orb.material_override = _orb_mat
		add_child(orb)
		gaze = MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.035
		cone.height = 0.1
		cone.radial_segments = 12
		cone.rings = 1
		gaze.mesh = cone
		gaze.material_override = _orb_mat
		add_child(gaze)
		tag = Label3D.new()
		tag.font = TextLayout.font(600)
		tag.font_size = 64
		tag.pixel_size = PeerAvatars.TAG_EM / 64.0
		tag.shaded = false
		tag.no_depth_test = true
		tag.render_priority = 124
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.outline_size = 16
		tag.outline_modulate = Color(0.02, 0.03, 0.05, 0.85)
		add_child(tag)
		tip = MeshInstance3D.new()
		var ts := SphereMesh.new()
		ts.radius = 0.006
		ts.height = 0.012
		ts.radial_segments = 12
		ts.rings = 6
		tip.mesh = ts
		tip.material_override = _tip_mat
		add_child(tip)
		ray = MeshInstance3D.new()
		var rc := CylinderMesh.new()
		rc.top_radius = 0.0009
		rc.bottom_radius = 0.0009
		rc.height = 1.0
		rc.radial_segments = 5
		rc.rings = 1
		ray.mesh = rc
		ray.material_override = _ray_mat
		add_child(ray)

	func show_pose(who: String, c: Color, head: Transform3D, tracked: bool, tip_pos: Vector3, dir: Vector3, down: bool, physical: bool, dt: float) -> void:
		visible = true
		if c != _color:
			_color = c
			for m in [_orb_mat, _tip_mat, _ray_mat]:
				var a: float = (m as StandardMaterial3D).albedo_color.a
				(m as StandardMaterial3D).albedo_color = Color(c.r, c.g, c.b, a)
			tag.modulate = c.lightened(0.25)
		if tag.text != who:
			tag.text = who
		var k := 1.0 if not _seeded else 1.0 - exp(-dt * 16.0)
		_head = head.origin if not _seeded else _head.lerp(head.origin, k)
		var target := tip_pos
		_tip = target if not _seeded else _tip.lerp(target, k)
		_seeded = true
		orb.visible = not physical
		gaze.visible = not physical
		orb.position = _head
		var fwd := -head.basis.z
		gaze.transform = Transform3D(Basis(Quaternion(Vector3.UP, fwd.normalized())), _head + fwd.normalized() * 0.1)
		tag.position = _head + Vector3(0, PeerAvatars.TAG_LIFT, 0)
		tip.visible = tracked
		ray.visible = tracked
		if tracked:
			var d := dir.normalized() if dir.length() > 0.001 else Vector3.FORWARD
			tip.position = _tip
			tip.scale = Vector3.ONE * (1.7 if down else 1.0)
			_ray_mat.albedo_color.a = 0.85 if down else 0.5
			ray.transform = Transform3D(Basis(Quaternion(Vector3.UP, d)).scaled(Vector3(1, PeerAvatars.RAY_LEN, 1)), _tip + d * PeerAvatars.RAY_LEN * 0.5)
