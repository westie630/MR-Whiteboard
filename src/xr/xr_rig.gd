class_name XrRig
extends Node3D
## The Quest 3 rig: mixed reality only (passthrough is always on), hands only, the MX Ink stylus for drawing.
##  - OpenXR start-up, passthrough, render quality (sharp: no foveation, 4x MSAA, supersampled)
##  - hand tracking -> HandInput (pinch, pointing ray) for moving canvases and for the menu
##  - the stylus -> PenState (see StylusInput); a pinch draws instead when no stylus is present (setting)
##  - the menu floats in the room: poke it with the stylus tip or a fingertip, point and pinch from a distance, grab its bar to move
##    it, open your palm facing up to bring it to you
##  - spatial anchors (MetaAnchors) and the room scan (MetaScene)

const HAND_JOINTS := 26
const J_PALM := 0
const J_WRIST := 1
const J_THUMB_TIP := 5
const J_INDEX_PROX := 7
const J_INDEX_TIP := 10
const J_LITTLE_PROX := 22
const QUALITY := {"performance": 1.0, "sharp": 1.4, "ultra": 1.8}
const POKE_PRESS := 0.006
const POKE_RELEASE := 0.015

var board: Board
var xr: XRInterface
var origin: XROrigin3D
var camera: XRCamera3D
var stylus: StylusInput
var anchors: MetaAnchors
var scene: MetaScene
var menu: MenuPanel
var panel: XrPanel
var hands := {"left": HandInput.new("left"), "right": HandInput.new("right")}
var passthrough_on := false

var _pt_check := 0.0
var _panel_placed := false
var _markers := {}
var _ui_src := ""                          # which source currently holds the menu pointer: "pen" | "left" | "right" | ""
var _ui_pressed := false
var _grab_src := ""
var _grab_offset := Vector3.ZERO
var _palm_t := {"left": 0.0, "right": 0.0}
var _board_pen := PenState.new()
var _no_hands_t := 0.0
var _diag_t := 0.0


# ------------------------------------------------------------------------------------------------ start-up

## Starts the rig and returns the anchor service for the board.
func start(b: Board) -> AnchorService:
	board = b
	# The engine starts OpenXR itself on Android (project setting). We never call initialize() here.
	xr = XRServer.find_interface("OpenXR")
	var vp := get_viewport()
	vp.use_xr = true
	vp.msaa_3d = Viewport.MSAA_4X
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if xr.has_method("get_available_display_refresh_rates"):
		var rates: Array = xr.call("get_available_display_refresh_rates")
		for want in [90.0, 80.0, 72.0]:
			if rates.has(want):
				xr.call("set_display_refresh_rate", want)
				Engine.physics_ticks_per_second = int(want)
				break
	_apply_quality()
	xr.set("foveation_level", 0)
	xr.set("foveation_dynamic", false)
	if xr.has_method("set_cpu_level"):
		xr.call("set_cpu_level", 2)
		xr.call("set_gpu_level", 2)
	for sig in ["session_focussed", "session_begun", "session_visible"]:
		if xr.has_signal(sig):
			xr.connect(sig, _on_session.bind(sig))
	origin = XROrigin3D.new()
	origin.name = "XROrigin"
	add_child(origin)
	camera = XRCamera3D.new()
	camera.near = 0.04
	camera.far = 40.0
	origin.add_child(camera)
	stylus = StylusInput.new()
	origin.add_child(stylus)
	anchors = MetaAnchors.new()
	add_child(anchors)
	anchors.setup(origin)
	scene = MetaScene.new()
	add_child(scene)
	scene.setup(origin)
	_request_permissions()
	_build_markers()
	_build_menu()
	board.head_provider = func(): return camera.global_transform
	board.surface_hit = func(o: Vector3, d: Vector3) -> Dictionary: return scene.hit(o, d)
	App.setting_changed.connect(_on_setting)
	set_passthrough()
	return anchors


func _request_permissions() -> void:
	if OS.get_name() != "Android":
		return
	OS.request_permissions()
	for p in ["com.oculus.permission.USE_ANCHOR_API", "com.oculus.permission.USE_SCENE"]:
		if not OS.get_granted_permissions().has(p):
			OS.request_permission(p)


func _apply_quality() -> void:
	var q := str(App.val("xr_quality"))
	xr.set("render_target_size_multiplier", float(QUALITY.get(q, 1.4)))


func _on_setting(key: String) -> void:
	if key == "xr_quality":
		_apply_quality()
	elif key == "ui_scale" and panel != null:
		panel.set_ui_scale(float(App.val("ui_scale")))


func _on_session(which: String) -> void:
	print("[xr] session ", which)
	set_passthrough()
	if which == "session_focussed" or which == "session_begun":
		anchors.reload()


# ------------------------------------------------------------------------------------------------ passthrough

## Passthrough is never optional: the app is mixed reality only. Re-asserted whenever the session comes back.
func set_passthrough() -> void:
	var vp := get_viewport()
	var ok := false
	if xr.is_passthrough_supported():
		ok = xr.is_passthrough_enabled() or xr.start_passthrough()
	var modes: Array = xr.get_supported_environment_blend_modes()
	if modes.has(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND):
		xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		ok = true
	passthrough_on = ok
	vp.transparent_bg = ok
	var w3 := get_viewport().world_3d
	if w3.environment == null:
		w3.environment = Environment.new()
	var env := w3.environment
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)


func _keep_passthrough(delta: float) -> void:
	_pt_check += delta
	if _pt_check < 0.5:
		return
	_pt_check = 0.0
	var layer_off: bool = xr.is_passthrough_supported() and not xr.is_passthrough_enabled()
	if layer_off or xr.environment_blend_mode != XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND or not passthrough_on:
		print("[xr] passthrough was off: switched back on")
		set_passthrough()


# ------------------------------------------------------------------------------------------------ menu

func _build_menu() -> void:
	menu = MenuPanel.new()
	menu.setup(board)
	panel = XrPanel.new()
	add_child(panel)
	panel.setup(menu, MenuPanel.DESIGN_SIZE, 1450.0, true)
	panel.set_ui_scale(float(App.val("ui_scale")))
	panel.visible = false
	menu.hide_requested.connect(func():
		panel.visible = false
		board.toast.emit("Menu hidden. Open your palm facing up to bring it back."))


func _place_panel_front() -> void:
	var h := camera.global_transform
	var fwd := Vector3(-h.basis.z.x, 0.0, -h.basis.z.z).normalized()
	var right := fwd.cross(Vector3.UP)
	var pos := h.origin + fwd * 0.62 - right * 0.14 + Vector3(0, -0.2, 0)
	_face_head(pos)
	panel.visible = true


func _face_head(pos: Vector3) -> void:
	var h := camera.global_transform.origin
	var yaw := atan2(h.x - pos.x, h.z - pos.z)
	panel.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)


# ------------------------------------------------------------------------------------------------ physical keyboard

## A Bluetooth keyboard: the headset delivers its keys to the app window, but the menu lives in its own viewport, so keys are passed on
## to the field being edited there. With no field open, editing shortcuts work (Ctrl+Z, Delete ...), Enter edits the selected text or
## shape, and any character starts a new text.
func _input(e: InputEvent) -> void:
	if not (e is InputEventKey) or menu == null or panel == null or board == null or board.doc == null:
		return
	var k := e as InputEventKey
	if menu.is_typing():
		panel.viewport.push_input(k, false)
		get_viewport().set_input_as_handled()
		return
	if not k.pressed:
		return
	if Shortcuts.edit_key(board, k):
		get_viewport().set_input_as_handled()
		return
	var enter := k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER
	if enter and not (board.texts.selected_text() != null or board.texts.selected_shape() != null):
		if not k.echo:
			board.ink.convert_ink()
		get_viewport().set_input_as_handled()
		return
	if enter or Shortcuts.is_printable(k):
		_show_menu()
		if menu.open_text_entry() and not enter:
			panel.viewport.push_input(k, false)            # the character that started the typing is the first one typed
		get_viewport().set_input_as_handled()


func _show_menu() -> void:
	if panel.visible:
		return
	_place_panel_front()
	panel.request_update()


# ------------------------------------------------------------------------------------------------ hands

func _read_hand(side: String) -> Dictionary:
	var tr := XRServer.get_tracker("/user/hand_tracker/" + side) as XRHandTracker
	if tr == null or not tr.has_tracking_data:
		return {"valid": false}
	if tr.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER:
		return {"valid": false}
	for j in [J_PALM, J_WRIST, J_THUMB_TIP, J_INDEX_PROX, J_INDEX_TIP, J_LITTLE_PROX]:
		if not (tr.get_hand_joint_flags(j) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID):
			return {"valid": false}
	var xf := origin.global_transform
	var wrist: Vector3 = xf * tr.get_hand_joint_transform(J_WRIST).origin
	var idx: Vector3 = xf * tr.get_hand_joint_transform(J_INDEX_PROX).origin
	var lit: Vector3 = xf * tr.get_hand_joint_transform(J_LITTLE_PROX).origin
	var n := (idx - wrist).cross(lit - wrist).normalized()      # out of the palm, from the joint positions
	if side == "left":
		n = -n
	return {
		"valid": true,
		"tip": xf * tr.get_hand_joint_transform(J_INDEX_TIP).origin,
		"thumb": xf * tr.get_hand_joint_transform(J_THUMB_TIP).origin,
		"knuckle": idx,
		"palm": xf * tr.get_hand_joint_transform(J_PALM).origin,
		"palm_normal": n,
	}


func _build_markers() -> void:
	for side in ["left", "right"]:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.006
		sm.height = 0.012
		sm.radial_segments = 12
		sm.rings = 6
		mi.mesh = sm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(1, 1, 1, 0.85)
		m.no_depth_test = true
		m.render_priority = 110
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		origin.add_child(mi)
		_markers[side] = mi


# ------------------------------------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	if board == null or board.doc == null or xr == null:
		return
	_keep_passthrough(delta)
	var head := camera.global_transform
	if not _panel_placed and head.origin.y > 0.3:
		_panel_placed = true
		_place_panel_front()
	stylus.update()
	for side in ["left", "right"]:
		(hands[side] as HandInput).feed(delta, head, _read_hand(side))
	var pen := stylus.pen
	var stylus_here := pen.tracked and stylus.active != ""
	var captured := _update_menu(pen)
	_summon_gesture(delta, stylus_here)
	# what the board sees: the pen (stylus, or a pinch when there is none), and the hands that are free
	var board_hands: Array = []
	for side in ["left", "right"]:
		var h := hands[side] as HandInput
		if not h.tracked or captured.get(side, false):
			continue
		if stylus_here and side == stylus.active:
			continue                                   # the hand holding the stylus does not pinch
		board_hands.append(h)
	var bp := _board_pen
	if stylus_here:
		if captured.get("pen", false):
			bp.tracked = false
			bp.down = false
			bp.front = false
			bp.back = pen.back
		else:
			bp = pen
	else:
		bp.tracked = false
		bp.down = false
		bp.front = false
		bp.back = false
		bp.source = "none"
		if bool(App.val("finger_draw")):
			# no stylus: the right hand draws with a pinch, the left hand moves canvases
			var draw_hand := hands["right"] as HandInput
			var grab_hand := hands["left"] as HandInput
			board_hands = [grab_hand] if (grab_hand.tracked and not captured.get("left", false)) else []
			bp.source = "pinch"
			bp.tracked = draw_hand.tracked and not captured.get("right", false)
			bp.tip = draw_hand.pinch_point
			bp.dir = draw_hand.aim_d
			bp.down = draw_hand.pinching
			bp.pressure = 0.7 if draw_hand.pinching else 0.0
			bp.haptic = Callable()
	_update_markers(board_hands, stylus_here)
	board.tick(bp, board_hands, delta)
	_diag_t += delta
	if _diag_t > 5.0:
		_diag_t = 0.0
		print("[xr] stylus=%s pen=%s down=%s hands=%d panel=%s anchors: %s" % [stylus.active, str(pen.tracked), str(pen.down), board_hands.size(), str(panel.visible), anchors.status()])


func _update_markers(board_hands: Array, stylus_here: bool) -> void:
	for side in ["left", "right"]:
		var mi: MeshInstance3D = _markers[side]
		var h := hands[side] as HandInput
		var show: bool = h.tracked and board_hands.has(h) and not (stylus_here and side == stylus.active)
		mi.visible = show
		if show:
			mi.global_position = h.pinch_point
			(mi.material_override as StandardMaterial3D).albedo_color = Color(0.4, 1.0, 0.7, 0.95) if h.pinching else Color(1, 1, 1, 0.8)


# ------------------------------------------------------------------------------------------------ menu interaction

## Pokes, rays and the grab bar. Returns which sources are busy with the menu ({pen, left, right}: true) so the board ignores them.
func _update_menu(pen: PenState) -> Dictionary:
	var busy := {}
	if panel == null or not panel.visible:
		return busy
	var sources: Array = []
	if pen.tracked and stylus.active != "":
		sources.append({"id": "pen", "tip": pen.tip, "ray_o": pen.tip, "ray_d": pen.dir, "ray_press": pen.front, "pinch": false})
	for side in ["left", "right"]:
		var h := hands[side] as HandInput
		if h.tracked and not (pen.tracked and side == stylus.active):
			sources.append({"id": side, "tip": h.tip, "ray_o": h.aim_o, "ray_d": h.aim_d, "ray_press": h.pinching, "pinch": true, "aiming": h.aiming, "hand": h})
	# the grab bar below the panel
	_update_handle(sources, busy)
	var best_uv := Vector2(-1, -1)
	var best_src := ""
	var press := false
	for s in sources:
		var id: String = s.id
		if _grab_src == id:
			busy[id] = true
			continue
		var info := panel.touch_info(s.tip)
		var uv := Vector2(-1, -1)
		var pressed := false
		var near := false
		if info.inside and info.depth > -0.05 and info.depth < 0.08:
			near = true
			uv = info.uv
			var limit := POKE_RELEASE if (_ui_src == id and _ui_pressed) else POKE_PRESS
			pressed = info.depth < limit
		elif (not s.pinch or s.get("aiming", false)):
			var rc := panel.raycast(s.ray_o, s.ray_d)
			if rc.hit and rc.t < 1.4 and (s.ray_press or s.pinch or (not s.pinch and pen.front)):
				near = true
				uv = rc.uv
				pressed = s.ray_press
			elif rc.hit and rc.t < 1.4 and s.pinch:
				near = true
				uv = rc.uv
		if near:
			busy[id] = true
			if best_src == "" or id == _ui_src:
				best_src = id
				best_uv = uv
				press = pressed
	# one pointer drives the panel
	if best_src != "":
		_ui_src = best_src
		panel.pointer_move(best_uv)
		if press and not _ui_pressed:
			panel.pointer_press(best_uv)
			_ui_pressed = true
			if best_src == "pen":
				pen.tick(0.25, 0.015)
		elif not press and _ui_pressed:
			panel.pointer_release(best_uv)
			_ui_pressed = false
	elif _ui_src != "":
		if _ui_pressed:
			panel.pointer_release(Vector2(-1, -1))
		panel.pointer_leave()
		_ui_pressed = false
		_ui_src = ""
	return busy


func _update_handle(sources: Array, busy: Dictionary) -> void:
	var hp := panel.handle_world()
	if _grab_src != "":
		for s in sources:
			if s.id != _grab_src:
				continue
			var holding: bool = (s.hand as HandInput).pinching if s.pinch else stylus.pen.front
			var point: Vector3 = (s.hand as HandInput).pinch_point if s.pinch else s.tip
			if holding:
				_face_head(point + _grab_offset)
				busy[s.id] = true
				panel.set_handle_state(true, true)
				return
		_grab_src = ""
		panel.set_handle_state(false, false)
		return
	var hover := false
	for s in sources:
		var point2: Vector3 = (s.hand as HandInput).pinch_point if s.pinch else s.tip
		if point2.distance_to(hp) < 0.07:
			hover = true
			busy[s.id] = true
			var start: bool = (s.hand as HandInput).pinch_down if s.pinch else stylus.pen.front
			if start:
				_grab_src = s.id
				_grab_offset = panel.global_position - point2
	panel.set_handle_state(hover, false)


## Open palm facing up for a moment: the menu comes to hover above the hand.
func _summon_gesture(delta: float, stylus_here: bool) -> void:
	if panel == null:
		return
	for side in ["left", "right"]:
		var h := hands[side] as HandInput
		if stylus_here and side == stylus.active:
			continue
		if h.tracked and h.palm_up and not h.pinching and h.palm.distance_to(camera.global_position) < 0.7:
			_palm_t[side] += delta
			if _palm_t[side] > 0.8:
				_palm_t[side] = -2.0
				_face_head(h.palm + Vector3(0, 0.32, 0) + (camera.global_position - h.palm).normalized() * 0.05)
				panel.visible = true
				panel.request_update()
		else:
			_palm_t[side] = minf(_palm_t[side] + delta, 0.0) if _palm_t[side] < 0.0 else 0.0
