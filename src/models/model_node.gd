class_name ModelNode
extends Node3D
## A 3D model standing in the room: the view of a FrameData of kind "model". The Board places this node like a canvas (its pose in the room,
## its scale); inside it the model is stretched along its own axes (`stretch`) and moved so that the middle of its bounds is this node's origin,
## so it turns and grows about its middle. While the file is loading (or on its way from the owner of a session, or too much for this device)
## a box of the model's size stands in for it with a line that says why. Its soft shadow lies on the real surface under it (place_shadow).

signal measured(frame_id: String, box: AABB)     # the file was loaded and the frame has no bounds yet: the Board fits it to the room

const BOX_COLOR := Color(0.55, 0.85, 1.0)
const PLACEHOLDER := 0.3                         # metres: the stand-in box of a model nobody has measured yet

var data: FrameData
var lib: ModelLibrary
var state := ""                                  # "" | loading | ready | missing | failed
var note := ""                                   # what the stand-in box says
var hover := 0.0                                 # 0..1: a pointer is on it (its outline shows)
var selected := false
var triangles := 0
var animations := PackedStringArray()

var _pivot: Node3D                               # scaled by the stretch
var _content: Node3D                             # moved by minus the middle of the bounds
var _model: Node3D
var _outline: MeshInstance3D
var _outline_mat: StandardMaterial3D
var _label: Label3D
var shadow: MeshInstance3D                       # not a child: it lies on the surface, the Board places it
var _shadow_mat: ShaderMaterial
var _live_stretch: Variant = null                # while a scale handle is held: the stretch shown


func setup(f: FrameData, library: ModelLibrary) -> void:
	data = f
	lib = library
	name = "Model_" + f.id
	_pivot = Node3D.new()
	_pivot.name = "Stretch"
	add_child(_pivot)
	_content = Node3D.new()
	_content.name = "Content"
	_pivot.add_child(_content)
	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_outline_mat.no_depth_test = true
	_outline_mat.render_priority = 100
	_outline_mat.vertex_color_use_as_albedo = true
	_outline = MeshInstance3D.new()
	_outline.name = "Outline"
	_outline.material_override = _outline_mat
	_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pivot.add_child(_outline)
	_label = Label3D.new()
	_label.font = TextLayout.font(500)
	_label.font_size = 64
	_label.pixel_size = 0.022 / 64.0
	_label.shaded = false
	_label.no_depth_test = true
	_label.render_priority = 110
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = false
	_label.outline_size = 10
	_label.outline_modulate = Color(0, 0, 0, 0.55)
	_label.modulate = Color(0.92, 0.97, 1.0)
	_label.width = 900.0
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.visible = false
	add_child(_label)
	shadow = MeshInstance3D.new()
	shadow.name = "Shadow_" + f.id
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	q.orientation = PlaneMesh.FACE_Y
	shadow.mesh = q
	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = load("res://shaders/model_shadow.gdshader")
	_shadow_mat.render_priority = -100
	shadow.material_override = _shadow_mat
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shadow.top_level = true
	shadow.visible = false
	add_child(shadow)
	refresh()


## The frame changed (or the library did): show what it says.
func refresh() -> void:
	_pivot.scale = (_live_stretch if _live_stretch != null else data.stretch) as Vector3
	_content.position = -_box().get_center()
	if data.model == "":
		_set_state("failed", "This frame names no model.")
	elif lib == null or not lib.has(data.model):
		if _model != null:
			_model.queue_free()                            # (it was removed from this headset)
			_model = null
		if lib != null:
			lib.want(data.model)
		_set_state("missing", lib.state_text(data.model) if lib != null else "")
	elif _model != null and str(_model.get_meta("model_id", "")) == data.model:
		_set_state("ready", "")
	elif lib.failure(data.model) != "":
		_set_state("failed", lib.failure(data.model))
	else:
		_set_state("loading", "Loading the model...")
		lib.request(data.model)
	_draw_outline()


func on_ready(model_id: String) -> void:
	if model_id != data.model or (_model != null and str(_model.get_meta("model_id", "")) == model_id):
		return
	var inst := lib.instance(model_id)
	if inst == null:
		return
	if _model != null:
		_model.queue_free()
	_model = inst
	_model.set_meta("model_id", model_id)
	ModelLighting.use_layer(_model)
	_content.add_child(_model)
	var st := lib.stats(model_id)
	triangles = int(st.get("triangles", 0))
	animations = st.get("animations", PackedStringArray())
	for ap in _model.find_children("*", "AnimationPlayer", true, false):
		var p := ap as AnimationPlayer
		var list := p.get_animation_list()
		if not list.is_empty():
			var anim := p.get_animation(list[0])
			if anim != null:
				anim.loop_mode = Animation.LOOP_LINEAR
			p.play(list[0])                                 # a model that moves moves: its first animation, over and over
			break
	if not data.model_measured():
		measured.emit(data.id, st.get("box", AABB()))
	_set_state("ready", "")
	refresh()


func on_failed(model_id: String, message: String) -> void:
	if model_id == data.model and _model == null:
		_set_state("failed", message)


func _set_state(s: String, text: String) -> void:
	state = s
	note = text
	_label.text = "" if s == "ready" else ("%s\n%s" % [data.name, text] if text != "" else data.name)
	_label.visible = s != "ready"
	_draw_outline()


## The bounds in the file's units (a stand-in cube before anybody measured it).
func _box() -> AABB:
	if data.model_measured():
		return data.model_box
	return AABB(Vector3.ONE * -PLACEHOLDER * 0.5, Vector3.ONE * PLACEHOLDER)


## While a scale handle is held the stretch shown is the hand's, not yet the frame's (null: the frame's).
func set_live_stretch(v: Variant) -> void:
	_live_stretch = v
	_pivot.scale = (v if v != null else data.stretch) as Vector3


## The model's box in this node's coordinates (before the node's own scale): centred on the origin, stretched.
func local_box() -> AABB:
	var sz := _box().size * _pivot.scale
	return AABB(-sz * 0.5, sz)


## The oriented box in the world: {xf (rotation only, at the middle), half (half sizes in metres, along xf's axes)}.
func world_box() -> Dictionary:
	var g := global_transform
	var sc := g.basis.get_scale()
	var half := local_box().size * 0.5 * sc
	return {"xf": Transform3D(g.basis.orthonormalized(), g.origin), "half": half}


## Where a ray meets the model's box (grown by `grow` metres): {t, point} or {}.
func ray_hit(o: Vector3, d: Vector3, grow: float = 0.0) -> Dictionary:
	var wb := world_box()
	var xf: Transform3D = wb.xf
	var h: Vector3 = (wb.half as Vector3) + Vector3.ONE * grow
	var lo := xf.affine_inverse() * o
	var ld := xf.basis.inverse() * d.normalized()
	var t0 := -INF
	var t1 := INF
	for i in 3:
		if absf(ld[i]) < 1e-9:
			if absf(lo[i]) > h[i]:
				return {}
			continue
		var a := (-h[i] - lo[i]) / ld[i]
		var b := (h[i] - lo[i]) / ld[i]
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	if t1 < maxf(t0, 0.0):
		return {}
	var t := t0 if t0 >= 0.0 else 0.0
	return {"t": t, "point": o + d.normalized() * t}


## Is a point inside the box grown by `grow` metres?
func contains(p: Vector3, grow: float = 0.0) -> bool:
	var wb := world_box()
	var l := (wb.xf as Transform3D).affine_inverse() * p
	var h: Vector3 = wb.half
	return absf(l.x) <= h.x + grow and absf(l.y) <= h.y + grow and absf(l.z) <= h.z + grow


## The eight corners of the box in the world.
func corners() -> Array:
	var wb := world_box()
	var xf: Transform3D = wb.xf
	var h: Vector3 = wb.half
	var out: Array = []
	for i in 8:
		out.append(xf * Vector3(h.x * (1 if i & 1 else -1), h.y * (1 if i & 2 else -1), h.z * (1 if i & 4 else -1)))
	return out


func set_hover(v: float) -> void:
	if absf(v - hover) < 0.01:
		return
	hover = v
	_draw_outline()


func set_selected(on: bool) -> void:
	if on != selected:
		selected = on
		_draw_outline()


## The thin box round the model: always for a stand-in, while pointed at, and while selected.
func _draw_outline() -> void:
	if _outline == null:
		return
	var a := 0.0
	if state != "ready":
		a = 0.55
	a = maxf(a, hover * 0.55)
	if selected:
		a = maxf(a, 0.75)
	_outline.visible = a > 0.02
	if not _outline.visible:
		return
	var b := _box()
	var h := b.size * 0.5
	var col := Color(BOX_COLOR.r, BOX_COLOR.g, BOX_COLOR.b, a)
	if state == "failed":
		col = Color(1.0, 0.55, 0.45, a)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		for k in e:
			var i := int(k)
			im.surface_set_color(col)
			im.surface_add_vertex(Vector3(h.x * (1 if i & 1 else -1), h.y * (1 if i & 2 else -1), h.z * (1 if i & 4 else -1)))
	im.surface_end()
	_outline.mesh = im
	_label.position = Vector3(0.0, 0.0, 0.0)


## Lays the soft shadow on the surface under the model: `floor_y` is the height of that surface (world), null when there is none. It is
## darkest when the model stands on the surface and fades away as the model rises (gone at about its own size above it).
func place_shadow(floor_y: Variant, on: bool) -> void:
	if not on or floor_y == null or not visible or state != "ready":
		shadow.visible = false
		return
	var cs := corners()
	var low := INF
	for c in cs:
		low = minf(low, (c as Vector3).y)
	var wb := world_box()
	var xf: Transform3D = wb.xf
	var fy := float(floor_y)
	var lift := low - fy
	var h: Vector3 = wb.half
	var size := maxf(h.x, maxf(h.y, h.z)) * 2.0
	if lift < -0.05 or lift > size * 1.5 + 0.3:
		shadow.visible = false
		return
	# the footprint: the corners seen from above, along the model's own heading
	var x := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z)
	if x.length() < 0.2:
		x = Vector3(xf.basis.y.x, 0.0, xf.basis.y.z)
	if x.length() < 1e-3:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(Vector3.UP).normalized()
	var ex := 0.0
	var ez := 0.0
	for c in cs:
		var r := (c as Vector3) - xf.origin
		ex = maxf(ex, absf(r.dot(x)))
		ez = maxf(ez, absf(r.dot(z)))
	var spread := 1.25 + clampf(lift / maxf(size, 0.05), 0.0, 1.0) * 0.5
	shadow.global_transform = Transform3D(Basis(x * ex * 2.0 * spread, Vector3.UP, z * ez * 2.0 * spread), Vector3(xf.origin.x, fy + 0.002, xf.origin.z))
	_shadow_mat.set_shader_parameter("strength", 0.5 * (1.0 - clampf(maxf(lift, 0.0) / (size * 1.5 + 0.3), 0.0, 1.0)))
	shadow.visible = true
