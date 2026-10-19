class_name DesktopRig
extends Node3D
## The PC build, for trying everything without a headset. The mouse (or a graphics tablet with pressure) is the stylus; the camera is
## your head. A simulated room (floor, wall, table) stands in for the real one, and spatial anchors are simulated too (Rooms tab).
## The 3D world is shown in its own viewport beside the menu, so the menu never covers the scene.
##
##   Left mouse      draw / use the current tool (hover a canvas to draw on it, otherwise it draws in the air in front of you)
##   Ctrl + left     draw in the air even over a canvas
##   Shift + left    the stylus front button: grab and move the thing under the pointer
##   Middle mouse    pinch: carry a canvas or 3D sketch (mouse wheel scales it, Q / E turn it)
##   Right mouse     look around;  W A S D  walk,  Shift  faster,  wheel  dolly / air depth with Ctrl
##   Ctrl+Z / Ctrl+Y undo / redo,  Delete,  Ctrl+D duplicate,  Ctrl+S save,  1-5 tools,  C new canvas,  Tab menu on/off,  Esc cancel

const MOVE_SPEED := 1.6
const LOOK_SENS := 0.0032

var board: Board
var menu: MenuPanel
var camera: Camera3D
var view: SubViewport                      # the 3D world
var view_container: SubViewportContainer
var pen := PenState.new()
var hands: Array = []

var _hand := HandInput.new("right")
var _yaw := 0.0
var _pitch := -0.08
var _looking := false
var _lmb := false
var _mmb := false
var _tablet := false
var _pressure := 0.75
var _air_depth := 0.85
var _hand_depth := 1.0
var _mouse_window := Vector2.ZERO          # last mouse position in the window
var _layer: CanvasLayer
var _hint: Label


func setup(b: Board) -> void:
	board = b
	_layer = CanvasLayer.new()
	add_child(_layer)
	view_container = SubViewportContainer.new()
	view_container.stretch = true
	view_container.mouse_filter = Control.MOUSE_FILTER_PASS
	_layer.add_child(view_container)
	view = SubViewport.new()
	view.msaa_3d = Viewport.MSAA_4X
	view.handle_input_locally = false
	view.own_world_3d = false
	view_container.add_child(view)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.near = 0.03
	camera.far = 60.0
	camera.position = Vector3(0.0, 1.55, 0.35)
	view.add_child(camera)
	_apply_look()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.115, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.65)
	var we := WorldEnvironment.new()
	we.environment = env
	view.add_child(we)
	_build_sim_room()
	# the board lives in the 3D viewport
	if board.get_parent() != null:
		board.get_parent().remove_child(board)
	view.add_child(board)
	board.head_provider = func(): return camera.global_transform
	board.surface_hit = _surface_hit
	menu = MenuPanel.new()
	_layer.add_child(menu)
	menu.setup(board)
	menu.hide_requested.connect(func():
		menu.visible = false
		_layout())
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	_hint.text = "Mouse = stylus  |  right mouse: look, WASD: walk  |  middle mouse: carry a canvas  |  Shift+click: grab  |  Tab: menu"
	_layer.add_child(_hint)
	get_window().size_changed.connect(_layout)
	App.setting_changed.connect(func(k):
		if k == "ui_scale":
			_layout())
	_layout()
	hands = [_hand]


func _layout() -> void:
	var win := Vector2(get_window().size)
	var fit := minf((win.y - 24.0) / MenuPanel.DESIGN_SIZE.y, 1.6)
	var sc := minf(float(App.val("ui_scale")), maxf(fit, 0.55))
	menu.scale = Vector2(sc, sc)
	menu.position = Vector2(12, 12)
	var left := 0.0
	if menu.visible:
		left = MenuPanel.DESIGN_SIZE.x * sc + 24.0
	view_container.position = Vector2(left, 0)
	view_container.size = Vector2(maxf(win.x - left, 64.0), win.y)
	_hint.position = Vector2(left + 14.0, win.y - 28.0)


func _in_view(window_pos: Vector2) -> bool:
	return view_container.get_global_rect().has_point(window_pos)


## Where the mouse is in the 3D viewport.
func view_mouse() -> Vector2:
	return _mouse_window - view_container.position


## Window position of a point of the 3D viewport (for scripted input).
func view_to_window(p: Vector2) -> Vector2:
	return p + view_container.position


# ------------------------------------------------------------------------------------------------ simulated room

func _build_sim_room() -> void:
	var room := Node3D.new()
	room.name = "SimRoom"
	view.add_child(room)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(8, 8)
	var fm := ShaderMaterial.new()
	fm.shader = _floor_shader()
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = fm
	room.add_child(floor_mi)
	var wall := MeshInstance3D.new()
	var wm := QuadMesh.new()
	wm.size = Vector2(8, 3)
	wall.mesh = wm
	wall.position = Vector3(0, 1.5, -2.6)
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.17, 0.19, 0.24)
	wmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wall.material_override = wmat
	room.add_child(wall)
	var table := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(1.6, 0.05, 0.8)
	table.mesh = tm
	table.position = Vector3(1.9, 0.725, -1.4)
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(0.28, 0.22, 0.17)
	tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	table.material_override = tmat
	room.add_child(table)


func _floor_shader() -> Shader:
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded;\nvarying vec2 p;\nvoid vertex(){ p = VERTEX.xz; }\nvoid fragment(){\n vec2 g = abs(fract(p * 1.0 - 0.5) - 0.5) / max(fwidth(p), vec2(1e-4));\n float l = 1.0 - min(min(g.x, g.y), 1.0);\n ALBEDO = mix(vec3(0.085, 0.1, 0.13), vec3(0.3, 0.45, 0.6), l * 0.55);\n ALPHA = 1.0; }\n"
	return sh


## Walls and tables of the simulated room, for placing canvases on them.
func _surface_hit(o: Vector3, d: Vector3) -> Dictionary:
	var best := {}
	var bt := INF
	if absf(d.z) > 1e-4:                         # back wall (z = -2.6, facing +z)
		var t := (-2.6 - o.z) / d.z
		if t > 0.05 and t < bt:
			var p := o + d * t
			if absf(p.x) < 4.0 and p.y > 0.0 and p.y < 3.0:
				bt = t
				best = {"point": p, "normal": Vector3(0, 0, 1)}
	if absf(d.y) > 1e-4:                         # table top (y = 0.75)
		var t2 := (0.75 - o.y) / d.y
		if t2 > 0.05 and t2 < bt:
			var p2 := o + d * t2
			if absf(p2.x - 1.9) < 0.8 and absf(p2.z + 1.4) < 0.4:
				bt = t2
				best = {"point": p2, "normal": Vector3.UP}
	return best


# ------------------------------------------------------------------------------------------------ input

func _input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and not _looking:
		_mouse_window = (e as InputEventMouseMotion).position
	elif e is InputEventMouseButton and not _looking:
		_mouse_window = (e as InputEventMouseButton).position
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if mm.pressure > 0.0 and mm.pressure < 1.0:
			_tablet = true
		if _tablet:
			_pressure = clampf(mm.pressure, 0.05, 1.0)
		if _looking:
			_yaw -= mm.relative.x * LOOK_SENS
			_pitch = clampf(_pitch - mm.relative.y * LOOK_SENS, -1.4, 1.4)
			_apply_look()
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		var inside := _in_view(mb.position)
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_lmb = mb.pressed and inside
				if mb.pressed and not _tablet:
					_pressure = 0.75
			MOUSE_BUTTON_RIGHT:
				if mb.pressed and not inside:
					return
				_looking = mb.pressed
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
			MOUSE_BUTTON_MIDDLE:
				_mmb = mb.pressed and inside
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed and inside:
					_wheel(1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0, mb)
	elif e is InputEventKey and (e as InputEventKey).pressed and not (e as InputEventKey).echo:
		_key(e as InputEventKey)


func _wheel(dir: float, mb: InputEventMouseButton) -> void:
	if board.hand_ctl.is_holding():
		for fid in board.grabs.keys():
			var g: Dictionary = board.grabs[fid]
			g.scale = clampf(float(g.scale) * pow(1.1, dir), 0.15, 8.0)
		return
	if mb.alt_pressed or mb.ctrl_pressed:
		_air_depth = clampf(_air_depth + dir * 0.08, 0.25, 3.0)
		return
	camera.position += -camera.global_transform.basis.z * dir * 0.25


func _key(k: InputEventKey) -> void:
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	match k.keycode:
		KEY_TAB:
			menu.visible = not menu.visible
			_layout()
			get_viewport().set_input_as_handled()
		KEY_Z:
			if k.ctrl_pressed:
				if k.shift_pressed:
					board.redo()
				else:
					board.undo()
		KEY_Y:
			if k.ctrl_pressed:
				board.redo()
		KEY_S:
			if k.ctrl_pressed and board.doc != null:
				board.flush_save()
				board.doc.save()
				board.toast.emit("Saved")
		KEY_D:
			if k.ctrl_pressed:
				board.duplicate_selection()
		KEY_DELETE, KEY_BACKSPACE:
			board.delete_selection()
		KEY_ESCAPE:
			if not board.placing.is_empty():
				board.cancel_place()
			else:
				board.clear_selection()
		KEY_C:
			if not k.ctrl_pressed:
				board.begin_place("wall", Vector2(1.2, 0.8))
		KEY_1:
			App.put("tool", "draw")
		KEY_2:
			App.put("tool", "shape")
		KEY_3:
			App.put("tool", "write")
		KEY_4:
			App.put("tool", "select")
		KEY_5:
			App.put("tool", "erase")
		KEY_ENTER, KEY_KP_ENTER:
			board.ink.convert_ink()
		KEY_Q, KEY_E:
			for fid in board.grabs.keys():
				var g: Dictionary = board.grabs[fid]
				var xf := g.xf as Transform3D
				xf.basis = Basis(Vector3.UP, deg_to_rad(6.0) * (1.0 if k.keycode == KEY_Q else -1.0)) * xf.basis
				g.xf = xf


func _apply_look() -> void:
	camera.rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	if board == null or board.doc == null:
		return
	# buttons released outside the window never arrive as events
	if _lmb and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_lmb = false
	if _mmb and not Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		_mmb = false
	var v := Vector3.ZERO
	var b := camera.global_transform.basis
	var typing := get_viewport().gui_get_focus_owner() is LineEdit
	if not typing:
		if Input.is_key_pressed(KEY_W):
			v += -b.z
		if Input.is_key_pressed(KEY_S) and not Input.is_key_pressed(KEY_CTRL):
			v += b.z
		if Input.is_key_pressed(KEY_A):
			v -= b.x
		if Input.is_key_pressed(KEY_D) and not Input.is_key_pressed(KEY_CTRL):
			v += b.x
	if v.length() > 0.0:
		camera.position += v.normalized() * MOVE_SPEED * delta * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_update_pen()
	board.tick(pen, hands, delta)


## Turn the mouse into the stylus: the pointer ray meets a canvas (then the nib is on its plane) or floats at the air depth.
func _update_pen() -> void:
	var inside := _in_view(_mouse_window)
	var m := view_mouse()
	var o := camera.project_ray_origin(m)
	var d := camera.project_ray_normal(m)
	var air := Input.is_key_pressed(KEY_CTRL)
	pen.source = "mouse"
	pen.tracked = (inside and not _looking) or _lmb or _mmb
	var tip := o + d * _air_depth
	if not air:
		var best_t := INF
		for fn in board.visible_frames(FrameData.CANVAS):
			var n := fn as FrameNode
			var inv := n.global_transform.affine_inverse()
			var lo := inv * o
			var ld := inv.basis * d
			if absf(ld.z) < 1e-5:
				continue
			var t := -lo.z / ld.z
			if t > 0.05 and t < best_t:
				var lp := lo + ld * t
				if n.bounds().grow(0.6 / n.data.scale).has_point(Vector2(lp.x, lp.y)) and not n.data.locked:
					best_t = t
					tip = o + d * t
	pen.tip = tip
	pen.dir = d
	pen.down = _lmb and not Input.is_key_pressed(KEY_SHIFT)
	pen.front = _lmb and Input.is_key_pressed(KEY_SHIFT)
	pen.pressure = _pressure if (_lmb or _tablet) else 0.0
	# the middle mouse button is a pinch on whatever canvas or sketch is under the pointer
	_hand.side = "right"
	_hand.pinch_down = false
	_hand.pinch_up = false
	var was := _hand.pinching
	if _mmb and not was:
		var pick := _pick_for_hand(o, d)
		if not pick.is_empty():
			_hand.tracked = true
			_hand.pinch_point = pick.point
			_hand.tip = pick.point
			_hand.pinching = true
			_hand.pinch_down = true
			_hand_depth = o.distance_to(pick.point)
	elif _mmb and was:
		_hand.pinch_point = o + d * _hand_depth
		_hand.tip = _hand.pinch_point
	elif was and not _mmb:
		_hand.pinching = false
		_hand.pinch_up = true
	elif not _mmb:
		_hand.tracked = false


func _pick_for_hand(o: Vector3, d: Vector3) -> Dictionary:
	var best := {}
	var bt := INF
	for fn in board.visible_frames():
		var n := fn as FrameNode
		var inv := n.global_transform.affine_inverse()
		var lo := inv * o
		var ld := inv.basis * d
		if absf(ld.z) < 1e-5:
			continue
		var t := -lo.z / ld.z
		if t > 0.05 and t < bt:
			var lp := lo + ld * t
			var ok := false
			if n.is_canvas:
				ok = n.bounds().grow(0.05 / n.data.scale).has_point(Vector2(lp.x, lp.y))
			else:
				ok = n.content_bounds().grow(0.2).has_point(Vector2(lp.x, lp.y))
			if ok:
				bt = t
				best = {"point": o + d * t}
	return best
