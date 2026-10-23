class_name XrPanel
extends Node3D
## A Control hosted floating in the room. The widget renders into a SubViewport at twice its logical size and is shown either
##  - on an OpenXR compositor layer (sharpest: the headset's compositor samples the texture directly at the display's resolution,
##    no double resampling), or
##  - when layers are not available, on a textured quad.
## Pokes and pinch rays arrive as pointer events and become mouse events, so every Control works unchanged. A press inside a scrolling
## list is held back until it is known whether it is a tap (click) or a drag (scroll).
## The texture is as big as the widget can get; the widget sits in it at its pivot (a popover grows upwards from the dock, a chip
## rightwards from the ink), the node's origin is that pivot, and only the widget itself catches rays and pokes: the empty rest of the
## texture lets them through to the canvas behind.

const SCROLL_DEADZONE := InputTuning.SCROLL_DEADZONE
const HANDLE_Y := InputTuning.HANDLE_Y

var widget: Control
var viewport: SubViewport
var design := Vector2(560, 800)
var ppm := 1450.0                          # logical pixels per metre
var render_scale := 2.0                    # texture pixels per logical pixel
var size_m := Vector2(0.4, 0.55)
var pivot := Vector2(0.5, 0.5)             # the point of the widget (0..1 of its size) at the node's origin
var hovered := false
var layer: Node3D
var using_layer := false
var handle: MeshInstance3D

var quad: MeshInstance3D
var _handle_mat: StandardMaterial3D
var _pressed := false
var _deferred := false
var _scrolling := false
var _press_uv := Vector2.ZERO
var _last_uv := Vector2(-1, -1)
var _scroll_sc: ScrollContainer
var _scroll_start := 0
var _boost := 0.0
var _accum := 0.0
var _ui_scale := 1.0
var _laid := Rect2()                       # the widget rect the quad and handle were last placed for


func setup(w: Control, design_px: Vector2, pixels_per_metre: float, want_layer: bool) -> void:
	widget = w
	design = design_px
	ppm = pixels_per_metre
	size_m = design / ppm
	viewport = SubViewport.new()
	viewport.size = Vector2i((design * render_scale).ceil())
	viewport.size_2d_override = Vector2i(design)
	viewport.size_2d_override_stretch = true
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.msaa_2d = Viewport.MSAA_4X
	viewport.handle_input_locally = true
	viewport.gui_embed_subwindows = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	viewport.add_child(w)
	quad = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = size_m
	quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = viewport.get_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.render_priority = 100
	quad.material_override = mat
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(quad)
	if want_layer and ClassDB.class_exists("OpenXRCompositionLayerQuad"):
		layer = ClassDB.instantiate("OpenXRCompositionLayerQuad")
		layer.set("layer_viewport", viewport)
		layer.set("quad_size", size_m)
		layer.set("alpha_blend", true)
		layer.set("sort_order", 1)
		add_child(layer)
		using_layer = bool(layer.call("is_natively_supported"))
		if using_layer:
			quad.visible = false
		else:
			layer.queue_free()
			layer = null
	_build_handle()
	_layout()
	print("[panel] %s %s, texture %dx%d" % [w.name, "compositor layer" if using_layer else "textured quad", viewport.size.x, viewport.size.y])


## Resize the panel (the user's menu size setting). The node itself is never scaled: compositor layers ignore node scale.
func set_ui_scale(s: float) -> void:
	_ui_scale = clampf(s, 0.4, 3.0)
	size_m = design / ppm * _ui_scale
	(quad.mesh as QuadMesh).size = size_m
	if layer != null:
		layer.set("quad_size", size_m)
	if handle != null:
		(handle.mesh as CapsuleMesh).height = 0.2 * _ui_scale
	_laid = Rect2()
	_layout()


## Metres per logical pixel.
func mpp() -> float:
	return _ui_scale / ppm


## The widget's rectangle in the texture's logical pixels.
func widget_rect() -> Rect2:
	return Rect2(widget.position, widget.size)


## Where the widget sits in the texture (its pivot on the texture's pivot), and the quad and handle around it.
func _layout() -> void:
	var r := Rect2(design * pivot - widget.size * pivot, widget.size)
	if r == _laid:
		return
	_laid = r
	widget.position = r.position
	var c := local_of(design * 0.5)
	quad.position = c
	if layer != null:
		layer.position = c
	if handle != null:
		var hb := local_of(Vector2(r.get_center().x, r.end.y))
		handle.position = Vector3(hb.x, hb.y - HANDLE_Y, 0.004)


func set_pivot(p: Vector2) -> void:
	if p != pivot:
		pivot = p
		_laid = Rect2()
		_layout()


## A point of the texture (logical px) in the node's space.
func local_of(px: Vector2) -> Vector3:
	var d := (px - design * pivot) * mpp()
	return Vector3(d.x, -d.y, 0.0)


## The texture pixel under a point of the node's space.
func px_of(l: Vector3) -> Vector2:
	return design * pivot + Vector2(l.x, -l.y) / mpp()


## The world point of a pointer position (uv over the whole texture).
func point_at(uv: Vector2) -> Vector3:
	return global_transform * local_of(uv * design)


## The middle of the widget in the world.
func widget_center() -> Vector3:
	return global_transform * local_of(widget_rect().get_center())


func _build_handle() -> void:
	handle = MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.007
	cm.height = 0.2
	cm.radial_segments = 12
	cm.rings = 3
	handle.mesh = cm
	handle.rotation.z = deg_to_rad(90.0)
	_handle_mat = StandardMaterial3D.new()
	_handle_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_handle_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_handle_mat.albedo_color = Color(0.25, 0.88, 0.78, 0.45)
	_handle_mat.render_priority = 101
	handle.material_override = _handle_mat
	handle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(handle)


func handle_world() -> Vector3:
	return global_transform * handle.position


func set_handle_state(hover: bool, grabbed: bool) -> void:
	_handle_mat.albedo_color = Color(1, 1, 1, 0.95) if grabbed else (Color(0.25, 0.88, 0.78, 0.9) if hover else Color(0.25, 0.88, 0.78, 0.45))


func request_update() -> void:
	_boost = 0.6


func _process(delta: float) -> void:
	if not visible:
		return
	_layout()
	_accum += delta
	var busy := hovered or _pressed or _boost > 0.0
	_boost = maxf(_boost - delta, 0.0)
	if busy:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	elif _accum >= 0.12:
		_accum = 0.0
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# ------------------------------------------------------------------------------------------------ geometry

func raycast(origin: Vector3, dir: Vector3) -> Dictionary:
	var n := global_transform.basis.z.normalized()
	var denom := dir.dot(n)
	if denom > -1e-4:
		return {"hit": false}
	var t := (global_position - origin).dot(n) / denom
	if t < 0.02:
		return {"hit": false}
	var p := origin + dir * t
	var px := px_of(global_transform.affine_inverse() * p)
	return {"hit": _catches(px, 0.0), "t": t, "point": p, "uv": px / design}


## A point near the panel: {depth (m in front of it, negative = through it), uv, inside}.
func touch_info(tip: Vector3, margin: float = 0.01) -> Dictionary:
	var l := global_transform.affine_inverse() * tip
	var px := px_of(l)
	return {"depth": l.z, "uv": px / design, "inside": _catches(px, margin / mpp())}


## Only the widget catches pointers, not the empty texture around it (nor a widget that lets the mouse through, like a message).
func _catches(px: Vector2, margin_px: float) -> bool:
	if widget == null or not widget.visible or widget.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		return false
	return widget_rect().grow(margin_px).has_point(px)


## Pointer position in the widget's logical pixels (the viewport renders at 2x but its input space is the logical size).
func uv_to_px(uv: Vector2) -> Vector2:
	return Vector2(uv.x * design.x, uv.y * design.y)


func _px(uv: Vector2) -> Vector2:
	return uv_to_px(uv)


# ------------------------------------------------------------------------------------------------ pointer -> mouse events

func _push_motion(uv: Vector2) -> void:
	var pos := _px(uv)
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.relative = pos - _px(_last_uv) if _last_uv.x >= 0.0 else Vector2.ZERO
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if (_pressed and not _deferred) else 0
	viewport.push_input(e, true)
	_last_uv = uv


func _push_button(uv: Vector2, down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.position = _px(uv)
	e.global_position = e.position
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	viewport.push_input(e, true)


func pointer_move(uv: Vector2) -> void:
	hovered = true
	if _pressed and _deferred:
		var d := _px(uv) - _px(_press_uv)
		if not _scrolling:
			if absf(d.y) > SCROLL_DEADZONE and absf(d.y) >= absf(d.x):
				_scrolling = true
			elif absf(d.x) > SCROLL_DEADZONE * InputTuning.SCROLL_SIDE:
				_flush_press()
				_push_motion(uv)
				return
		if _scrolling and is_instance_valid(_scroll_sc):
			_scroll_sc.scroll_vertical = _scroll_start - int(d.y)
		_last_uv = uv
		return
	_push_motion(uv)


func pointer_press(uv: Vector2) -> void:
	_push_motion(uv)
	hovered = true
	_pressed = true
	_press_uv = uv
	_scrolling = false
	_deferred = false
	var c := viewport.gui_get_hovered_control()
	var sc := _scroll_ancestor(c)
	if sc != null and not _is_drag_control(c):
		_deferred = true
		_scroll_sc = sc
		_scroll_start = sc.scroll_vertical
		return
	_push_button(uv, true)


func pointer_release(uv: Vector2) -> void:
	if not _pressed:
		return
	if _deferred:
		if not _scrolling:
			_push_motion(_press_uv)
			_push_button(_press_uv, true)
			_push_button(_press_uv, false)
		_deferred = false
		_scrolling = false
		_pressed = false
		return
	_push_button(uv, false)
	_pressed = false


func pointer_leave() -> void:
	if _last_uv.x < 0.0:
		return
	if _pressed:
		pointer_release(_last_uv)
	var e := InputEventMouseMotion.new()
	e.position = Vector2(-50, -50)
	e.global_position = e.position
	viewport.push_input(e, true)
	hovered = false
	_last_uv = Vector2(-1, -1)


func is_pressed() -> bool:
	return _pressed


func _flush_press() -> void:
	if _deferred:
		_deferred = false
		_push_motion(_press_uv)
		_push_button(_press_uv, true)


func _scroll_ancestor(c: Node) -> ScrollContainer:
	var n := c
	while n != null and n != viewport:
		if n is ScrollContainer:
			return n
		n = n.get_parent()
	return null


func _is_drag_control(c: Node) -> bool:
	var n := c
	while n != null and n != viewport:
		if n.has_meta("drag_ctrl"):
			return true
		n = n.get_parent()
	return false
