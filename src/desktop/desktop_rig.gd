class_name DesktopRig
extends Node3D
## The PC build, for trying everything without a headset. The mouse (or a graphics tablet with pressure) is the stylus; the camera is
## your head. A simulated room (floor, wall, table) stands in for the real one, and spatial anchors are simulated too (Rooms tab).
## The 3D world fills the window; the interface (UiShell) floats over it: the dock at the bottom, popovers above their button, Home on
## the left, the assistant on the right, the bars that belong to a selection or to handwriting pinned to their spot on the canvas.
##
##   Left mouse      draw / use the current tool on the canvas under the pointer
##   Shift + left    the stylus front button: grab what is under the pointer (an item, the canvas bar, a corner, empty canvas to carry it)
##   Middle mouse    pinch: carry a canvas (mouse wheel scales it, Q / E turn it)
##   Right mouse     look around;  W A S D  walk,  Shift  faster,  wheel  dolly
##   Ctrl+Z / Ctrl+Y undo / redo,  Delete,  Ctrl+D duplicate,  Ctrl+S save,  1-5 tools,  B brush,  T type,  C new canvas,  Tab hide the interface,  Esc close / let go

const MOVE_SPEED := 1.6
const LOOK_SENS := 0.0032

var board: Board
var ui: UiShell
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
var _ui_root: Control
var _offsets := {}                         # panel id -> where it was dragged to (from its home position)
const MARGIN := 18.0


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
	_ui_root = Control.new()
	_ui_root.name = "Interface"
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.theme = UITheme.theme()
	_layer.add_child(_ui_root)
	ui = UiShell.new()
	ui.name = "UiShell"
	add_child(ui)
	ui.setup(board)
	for p in ui.panels:
		_ui_root.add_child(p)
	var saved: Variant = App.val("panel_pos")
	if saved is Dictionary:
		for k in saved:
			if saved[k] is Array and (saved[k] as Array).size() == 2:
				_offsets[k] = Vector2(float(saved[k][0]), float(saved[k][1]))
	ui.dock.grip.dragged.connect(_drag.bind("dock"))
	ui.home.grip.dragged.connect(_drag.bind("home"))
	ui.assistant.grip.dragged.connect(_drag.bind("assistant"))
	get_window().size_changed.connect(_layout)
	_layout()
	ui.show_toast("Mouse = stylus.  Right mouse: look, WASD: walk.  Middle mouse: carry a canvas.  Tab hides the interface.")
	hands = [_hand]
	board.hand_ctl.grab_anywhere = true            # the mouse has no bar to point at: the middle button picks a canvas up wherever it is


func _layout() -> void:
	var win := Vector2(get_window().size)
	view_container.position = Vector2.ZERO
	view_container.size = win
	_ui_root.size = win


## The interface scale: the setting, made smaller when the window is too small for the dock.
func ui_scale() -> float:
	var win := Vector2(get_window().size)
	var fit := minf((win.x - 2.0 * MARGIN) / maxf(ui.dock.size.x, 1.0), (win.y - 40.0) / 560.0)
	return clampf(minf(float(App.val("ui_scale")), fit), 0.5, 1.8)


## Put every surface where it belongs this frame.
func _place_ui() -> void:
	var win := Vector2(get_window().size)
	var sc := ui_scale()
	for p in ui.panels:
		(p as FloatPanel).scale = Vector2(sc, sc)
	# the dock: bottom centre
	var d := ui.dock
	var dpos := Vector2((win.x - d.size.x * sc) * 0.5, win.y - MARGIN - d.size.y * sc) + _offset("dock")
	d.position = _clamp(dpos, d.size * sc, win)
	var dock_top := d.position.y
	# a popover: above its button
	var pop := ui.popover
	if pop.visible:
		var bx := d.position.x + d.button_x(ui.popover_id) * sc
		var pw := pop.size.x * sc
		var px := clampf(bx - pw * 0.5, MARGIN, win.x - MARGIN - pw)
		pop.position = Vector2(px, maxf(dock_top - 14.0 - pop.size.y * sc, MARGIN))
		pop.source_x = (bx - px) / sc
		pop.queue_redraw()
	# the typing card: above the dock, in the middle
	var cp := ui.compose
	if cp.visible:
		cp.position = Vector2((win.x - cp.size.x * sc) * 0.5, maxf(dock_top - 14.0 - cp.size.y * sc, MARGIN))
	# the desk card keeps to the right, so the desk itself stays in view in the middle
	var sf := ui.surface_card
	if sf.visible:
		sf.position = Vector2(win.x - MARGIN - sf.size.x * sc, maxf(dock_top - 14.0 - sf.size.y * sc, MARGIN))
	var ac := ui.align_card
	if ac.visible:
		ac.position = Vector2(win.x - MARGIN - ac.size.x * sc, maxf(dock_top - 14.0 - ac.size.y * sc, MARGIN))
	# Home on the left, the assistant on the right, as tall as there is room above the dock
	var avail := (dock_top - 2.0 * MARGIN) / sc
	for sp in [ui.home, ui.assistant]:
		var side := sp as FloatPanel
		var h := clampf(avail, 380.0, 760.0)
		side.custom_minimum_size.y = h
		side.size = Vector2(side.custom_minimum_size.x, h)
		var x := MARGIN if side.side < 0 else win.x - MARGIN - side.size.x * sc
		side.position = _clamp(Vector2(x, MARGIN) + _offset(side.id), side.size * sc, win)
	# messages: top centre of the room left between the side panels
	var lo := 0.0
	var hi := win.x
	if ui.home.visible:
		lo = ui.home.position.x + ui.home.size.x * sc
	if ui.assistant.visible:
		hi = ui.assistant.position.x
	var t := ui.toast
	t.max_width = maxf((hi - lo - 2.0 * MARGIN) / sc, 260.0)
	t.position = Vector2(clampf((lo + hi - t.size.x * sc) * 0.5, MARGIN, maxf(win.x - MARGIN - t.size.x * sc, MARGIN)), MARGIN + 6.0)
	# bars pinned to the canvas: where their spot is on the screen
	for cp2 in [ui.context, ui.ink_chip, ui.suggestion, ui.pdf_bar]:
		var c := cp2 as FloatPanel
		if not c.visible or c.anchor.is_empty():
			continue
		var fn: FrameNode = board.frame_nodes.get(str(c.anchor.frame))
		if fn == null:
			continue
		var pos2: Vector2 = c.anchor.pos
		var world := fn.global_transform * Vector3(pos2.x, pos2.y, 0.0)
		if camera.is_position_behind(world):
			c.position = Vector2(-10000, -10000)
			continue
		var sp2 := camera.unproject_position(world) + view_container.position
		var off := Vector2(0, -10) if c.pivot.y > 0.9 else (Vector2(10, 0) if c.pivot.x < 0.1 else Vector2(0, 10))
		var cpos := _clamp(sp2 - c.size * sc * c.pivot + off, c.size * sc, Vector2(win.x, dock_top - 8.0))
		cpos.x = clampf(cpos.x, lo + MARGIN * 0.5, maxf(hi - MARGIN * 0.5 - c.size.x * sc, lo + MARGIN * 0.5))   # not under a side panel
		if t.visible:
			cpos.y = maxf(cpos.y, t.position.y + t.size.y * sc + 8.0)                                             # nor under a message
		c.position = cpos


func _offset(id: String) -> Vector2:
	return _offsets.get(id, Vector2.ZERO)


func _clamp(pos: Vector2, size: Vector2, win: Vector2) -> Vector2:
	return Vector2(clampf(pos.x, MARGIN * 0.5, maxf(win.x - size.x - MARGIN * 0.5, MARGIN * 0.5)), clampf(pos.y, MARGIN * 0.5, maxf(win.y - size.y - MARGIN * 0.5, MARGIN * 0.5)))


## A panel's grip was dragged: it stays where it is put (also next time).
func _drag(rel: Vector2, id: String) -> void:
	_offsets[id] = _offset(id) + rel
	var save := {}
	for k in _offsets:
		save[k] = [(_offsets[k] as Vector2).x, (_offsets[k] as Vector2).y]
	App.put("panel_pos", save)


## Inside the 3D view and not on a surface of the interface: the mouse is the stylus there.
func _in_view(window_pos: Vector2) -> bool:
	if not view_container.get_global_rect().has_point(window_pos):
		return false
	for p in ui.panels:
		var fp := p as FloatPanel
		if fp.visible and fp.modulate.a > 0.05 and fp.mouse_filter != Control.MOUSE_FILTER_IGNORE and fp.get_global_rect().has_point(window_pos):
			return false
	return true


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
	camera.position += -camera.global_transform.basis.z * dir * 0.25


func _key(k: InputEventKey) -> void:
	if ui.is_typing():
		return
	if k.keycode == KEY_ESCAPE:
		if ui.back():
			get_viewport().set_input_as_handled()
			return
	if Shortcuts.edit_key(board, k):
		return
	match k.keycode:
		KEY_TAB:
			ui.hidden = not ui.hidden
			get_viewport().set_input_as_handled()
		KEY_B:
			if not k.ctrl_pressed:
				ui.toggle_popover("brush")
		KEY_T:
			if not k.ctrl_pressed:
				_type_text()
				get_viewport().set_input_as_handled()
		KEY_C:
			if not k.ctrl_pressed:
				board.begin_place("wall", Vector2(1.2, 0.8))
		KEY_F:
			if not k.ctrl_pressed:
				board.surface.begin("", Popover.SIZES[ui.canvas_size_idx][2])
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
			if board.texts.selected_text() != null or board.texts.selected_shape() != null:
				_type_text()
			else:
				board.ink.convert_ink()
		KEY_Q, KEY_E:
			for fid in board.grabs.keys():
				var g: Dictionary = board.grabs[fid]
				var xf := g.xf as Transform3D
				xf.basis = Basis(Vector3.UP, deg_to_rad(6.0) * (1.0 if k.keycode == KEY_Q else -1.0)) * xf.basis
				g.xf = xf


## T (or Enter on selected text): the typing box, showing the interface if it was hidden.
func _type_text() -> void:
	ui.hidden = false
	ui.open_text_entry()


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
	var typing := ui.is_typing()
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
	_place_ui()


## Turn the mouse into the stylus: the pointer ray meets a canvas (then the nib is on its plane) or floats at a fixed depth (nothing to draw on there).
func _update_pen() -> void:
	var inside := _in_view(_mouse_window)
	var m := view_mouse()
	var o := camera.project_ray_origin(m)
	var d := camera.project_ray_normal(m)
	pen.source = "mouse"
	pen.tracked = (inside and not _looking) or _lmb or _mmb
	var tip := o + d * _air_depth
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
	var feels := true
	if board.surface.finding() or board.session.aligning():
		# feeling for the desk (or for the points a session lines up on): the nib lands on the simulated room's tables and walls, and feels nothing in the air
		var hit := _surface_hit(o, d)
		feels = not hit.is_empty()
		if feels:
			tip = hit.point
	pen.tip = tip
	pen.dir = d
	pen.down = _lmb and not Input.is_key_pressed(KEY_SHIFT)
	pen.contact = pen.down and feels
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
			_hand.press_o = o
			_hand.press_d = d
	elif _mmb and was:
		_hand.pinch_point = o + d * _hand_depth
		_hand.tip = _hand.pinch_point
	elif was and not _mmb:
		_hand.pinching = false
		_hand.pinch_up = true
	elif not _mmb:
		_hand.tracked = false
	# the mouse ray is the hand's ray
	_hand.aiming = _hand.tracked
	_hand.aim_o = o
	_hand.aim_d = d


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
