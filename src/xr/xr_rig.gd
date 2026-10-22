class_name XrRig
extends Node3D
## The Quest 3 rig: mixed reality only (passthrough is always on), hands only, the MX Ink stylus for drawing.
##  - OpenXR start-up, passthrough, render quality (sharp: no foveation, 4x MSAA, supersampled)
##  - hand tracking -> HandInput (pinch, pointing ray) for moving canvases and for the menu
##  - the stylus -> PenState (see StylusInput); a pinch draws instead when no stylus is present (setting)
##  - the menu floats in the room: poke it with the stylus tip or a fingertip, point and pinch (stylus: front button) from a distance,
##    grab its bar to move it (touching it, or pointing at it), open your palm facing up to bring it to you
##  - spatial anchors (MetaAnchors) and the room scan (MetaScene)

const HAND_JOINTS := 26
const J_PALM := 0
const J_WRIST := 1
const J_THUMB_TIP := 5
const J_INDEX_PROX := 7
const J_INDEX_TIP := 10
const J_LITTLE_PROX := 22
const QUALITY := {"performance": 1.0, "sharp": 1.4, "ultra": 1.8}
const POKE_PRESS := InputTuning.POKE_PRESS     # a fingertip or nib this close in front of the menu presses (the tracked tip sits inside the finger)...
const POKE_RELEASE := InputTuning.POKE_RELEASE # ...and lets go this far out
const GLOVES_OFF_NEAR := InputTuning.GLOVES_OFF_NEAR   # the gloves hide while the stylus nib is this close to a canvas
## Ghost hands: grey, faint in the middle and denser at the silhouette (fresnel), like the Quest's own hand gloves.
const GHOST_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_prepass_alpha, cull_back, shadows_disabled;
uniform vec3 tint : source_color = vec3(0.2, 0.21, 0.24);
void fragment() {
	float rim = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	ALBEDO = mix(tint, vec3(0.42, 0.44, 0.48), rim);
	ALPHA = mix(0.3, 0.6, pow(rim, 1.5));
}
"""
const MENU_MAX_DIST := InputTuning.MENU_MAX_DIST   # a menu further away than this (another room, or placed before the headset was on) comes back

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
var cursor: HandCursor
var feedback: Feedback                     # click sounds for the hands
var _prev_stylus := ""
var _front_t := 0.0
var _pinch_peak := {}                      # side -> the strongest pinch since the last status line (for the log)
var _gloves := {}                          # side -> the Node3D holding that ghost glove
var _hand_ctrls := {}                      # side -> {aim, poke}: XRController3D nodes reading the hand interaction profile
var _profiles := {}                        # side -> the interaction profile last reported (logged when it changes)
var _menu_hits := {}                       # side -> {point, poke}: where each hand's ray (or fingertip) is on the menu this frame
var _ui_src := ""                          # which source currently holds the menu pointer: "pen" | "left" | "right" | ""
var _ui_pressed := false
var _grab_src := ""                        # which source holds the menu's handle...
var _grab_origin := Vector3.ZERO           # ...where the menu was, where that source's point was, and how much further the menu moves
var _grab_p0 := Vector3.ZERO
var _grab_gain := 1.0
var _pen_front := false                    # the stylus's front button last frame (for its press edge)
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
	_build_hand_controllers()
	_build_ghost_hands()
	cursor = HandCursor.new()
	origin.add_child(cursor)
	feedback = Feedback.new()
	add_child(feedback)
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


## Track hands and the stylus at the same time (XR_META_simultaneous_hands_and_controllers): without it Horizon OS switches hand
## tracking off while the stylus is held, so the free hand cannot point or pinch. The runtime resets this with every session, and
## refuses it unless the manifest declares hand tracking optional (export preset: Meta hand tracking = optional).
func _enable_multimodal() -> void:
	var ext_name := "OpenXRMetaSimultaneousHandsAndControllersExtension"
	if not Engine.has_singleton(ext_name):
		print("[xr] hands + stylus together: the extension is not present")
		return
	var ext: Object = Engine.get_singleton(ext_name)
	if not bool(ext.call("is_simultaneous_hands_and_controllers_supported")):
		print("[xr] hands + stylus together: not supported by this runtime")
		return
	ext.call("resume_simultaneous_hands_and_controllers_tracking")
	print("[xr] hands + stylus together: requested")


func _on_session(which: String) -> void:
	print("[xr] session ", which)
	if which == "session_begun" or which == "session_focussed":
		_enable_multimodal()
	if which == "session_focussed" and camera != null and panel != null:
		_panel_placed = false                      # the headset was (re)put on: the menu comes in front again
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
	# drawn in the 3D scene (not on a compositor layer, which the headset always puts over everything): the gloves and the stylus can
	# then be in front of the menu
	panel.setup(menu, MenuPanel.DESIGN_SIZE, 1450.0, false)
	panel.set_ui_scale(float(App.val("ui_scale")))
	panel.visible = false
	menu.hide_requested.connect(func():
		panel.visible = false
		board.toast.emit("Menu hidden. Open your palm facing up to bring it back."))


func _place_panel_front() -> void:
	var h := camera.global_transform
	var fwd := Vector3(-h.basis.z.x, 0.0, -h.basis.z.z).normalized()
	var right := fwd.cross(Vector3.UP)
	var pos := h.origin + fwd * InputTuning.SUMMON_AHEAD + right * InputTuning.SUMMON_RIGHT + Vector3(0, InputTuning.SUMMON_UP, 0)
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
	var out := {
		"valid": true,
		"tip": xf * tr.get_hand_joint_transform(J_INDEX_TIP).origin,
		"thumb": xf * tr.get_hand_joint_transform(J_THUMB_TIP).origin,
		"knuckle": idx,
		"palm": xf * tr.get_hand_joint_transform(J_PALM).origin,
		"palm_normal": n,
	}
	out.merge(_read_actions(side))
	return out


## The hands drawn as grey "ghost" gloves, like the Quest's own: the runtime's hand mesh (XR_FB_hand_tracking_mesh, from the vendors
## plugin, since Godot has no hand mesh of its own) posed by Godot's XRHandModifier3D on the hand tracker. Shown only while the hand is
## tracked; the real hands stay visible through passthrough underneath.
func _build_ghost_hands() -> void:
	if not ClassDB.class_exists("OpenXRFbHandTrackingMesh"):
		print("[xr] ghost hands: the hand mesh extension is not available")
		return
	var shader := Shader.new()
	shader.code = GHOST_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	for side in ["left", "right"]:
		var node := XRNode3D.new()
		node.name = "GhostHand_" + side
		node.tracker = StringName("/user/hand_tracker/" + side)
		node.pose = &"default"
		node.show_when_tracked = true
		origin.add_child(node)
		var offset := Node3D.new()                  # moves the glove back when a fingertip would go through the menu, hides it
		node.add_child(offset)
		var mesh: Node3D = ClassDB.instantiate("OpenXRFbHandTrackingMesh")
		mesh.set("hand", 0 if side == "left" else 1)
		mesh.set("material", mat)
		offset.add_child(mesh)
		_gloves[side] = offset
		var mod := XRHandModifier3D.new()
		mod.hand_tracker = StringName("/user/hand_tracker/" + side)
		mesh.add_child(mod)
	print("[xr] ghost hands ready")


## The gloves stop at the menu instead of passing through it when a fingertip pokes it, and hide while the stylus is at a canvas.
func _update_gloves(pen: PenState, stylus_here: bool) -> void:
	var drawing := stylus_here and not board.pen_target(pen.tip, GLOVES_OFF_NEAR, 0.3).is_empty()
	for side in _gloves:
		var g: Node3D = _gloves[side]
		g.visible = not drawing
		var push := Vector3.ZERO
		var m: Dictionary = _menu_hits.get(side, {})
		if bool(m.get("poke", false)) and float(m.get("depth", 1.0)) < 0.0:
			push = panel.global_transform.basis.z.normalized() * -float(m.depth)
		g.global_position = (g.get_parent() as Node3D).global_position + push


## One XRController3D per hand and pose action, on the standard "left_hand" / "right_hand" trackers: this is how the Godot
## documentation reads the OpenXR hand interaction profile (the same trackers carry the stylus when it is in that hand).
func _build_hand_controllers() -> void:
	for side in ["left", "right"]:
		var pair := {}
		for key in ["aim", "poke"]:
			var c := XRController3D.new()
			c.name = "Hand_%s_%s" % [side, key]
			c.tracker = StringName(side + "_hand")
			c.pose = StringName("hand_" + key)
			origin.add_child(c)
			pair[key] = c
		_hand_ctrls[side] = pair


## The runtime's pointing ray, pinch strength and fingertip for a hand: {aim_valid, aim_o, aim_d, pinch_value, poke}. {} while the
## hand's tracker is not on a hand interaction profile (the stylus is in that hand, or the runtime does not offer the profile).
func _read_actions(side: String) -> Dictionary:
	var profile := _profile(side)
	var pair: Dictionary = _hand_ctrls[side]
	var aim: XRController3D = pair.aim
	if not profile.contains("hand_interaction") or not aim.get_has_tracking_data():
		return {}
	var out := {"aim_valid": true, "aim_o": aim.global_position, "aim_d": -aim.global_transform.basis.z, "pinch_value": aim.get_float(&"hand_pinch")}
	var poke: XRController3D = pair.poke
	if poke.get_has_tracking_data():
		out.poke = poke.global_position
	return out


## The interaction profile a hand's tracker is on (hand interaction, the MX Ink stylus, ...), logged whenever it changes.
func _profile(side: String) -> String:
	var tr := XRServer.get_tracker(StringName(side + "_hand")) as XRPositionalTracker
	var profile := str(tr.profile) if tr != null else ""
	if profile != str(_profiles.get(side, "")):
		_profiles[side] = profile
		print("[xr] %s hand: interaction profile %s" % [side, profile if profile != "" else "(none)"])
	return profile


func _aim_note(h: HandInput) -> String:
	if not h.tracked:
		return "-"
	return "profile" if h.system_aim else "joints"


# ------------------------------------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	if board == null or board.doc == null or xr == null:
		return
	_keep_passthrough(delta)
	var head := camera.global_transform
	if not _panel_placed and head.origin.y > 0.3:
		_panel_placed = true
		_place_panel_front()
	elif panel.visible and panel.global_position.distance_to(head.origin) > MENU_MAX_DIST and _grab_src == "":
		print("[xr] the menu was %.1f m away: brought back in front" % panel.global_position.distance_to(head.origin))
		_place_panel_front()
	stylus.update()
	if stylus.active != _prev_stylus:
		_prev_stylus = stylus.active
		if stylus.active != "":
			_enable_multimodal()                       # picking the stylus up may switch the headset to controllers only: ask again
	for side in ["left", "right"]:
		_profile(side)
		(hands[side] as HandInput).feed(delta, head, _read_hand(side))
	var pen := stylus.pen
	var stylus_here := pen.tracked and stylus.active != ""
	var captured := _update_menu(pen)
	_summon_gesture(delta, stylus_here)
	_stylus_summon(delta, pen, stylus_here)
	_hand_feedback(stylus_here)
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
	board.tick(bp, board_hands, delta)
	cursor.update(hands, _menu_hits, board.hand_ctl.hover, head.origin, stylus.active if stylus_here else "", pen)
	_update_gloves(pen, stylus_here)
	for side in ["left", "right"]:
		_pinch_peak[side] = maxf(float(_pinch_peak.get(side, 0.0)), (hands[side] as HandInput).pinch_strength)
	_diag_t += delta
	if _diag_t > 5.0:
		_diag_t = 0.0
		var l := hands["left"] as HandInput
		var r := hands["right"] as HandInput
		print("[xr] stylus=%s pen=%s down=%s hands=%d panel=%s aim L=%s R=%s pinch peak L=%.2f R=%.2f anchors: %s" % [stylus.active, str(pen.tracked), str(pen.down), board_hands.size(), str(panel.visible), _aim_note(l), _aim_note(r), float(_pinch_peak.get("left", 0.0)), float(_pinch_peak.get("right", 0.0)), anchors.status()])
		_pinch_peak.clear()


# ------------------------------------------------------------------------------------------------ menu interaction

## For the log: the button (or other control) under a point of the menu.
func _control_at(_uv: Vector2) -> String:
	var c := panel.viewport.gui_get_hovered_control()
	if c == null:
		return "nothing"
	if c is Btn:
		return "button \"%s\"" % ((c as Btn).text if (c as Btn).text != "" else (c as Btn).icon)
	return c.get_class()


## Pokes, rays and the grab bar. Returns which sources are busy with the menu ({pen, left, right}: true) so the board ignores them.
## One model for hands and stylus: TOUCH a button (fingertip or nib within the poke zone), or POINT at it and press (hand: pinch, stylus:
## front button). At a canvas the stylus draws and grabs instead, so it is not offered the menu there. A source is busy only while it
## touches the menu or is pressing it: a ray that merely crosses the menu, or a pinch that began on a canvas, is still the board's.
func _update_menu(pen: PenState) -> Dictionary:
	var busy := {}
	_menu_hits = {}
	var front_edge := pen.front and not _pen_front
	_pen_front = pen.front
	if panel == null or not panel.visible:
		return busy
	var sources: Array = []
	if pen.tracked and stylus.active != "":
		var at_canvas := not board.pen_target(pen.tip, Board.CAPTURE).is_empty()
		sources.append({"id": "pen", "tip": pen.tip, "point": pen.tip, "ray_o": pen.tip, "ray_d": pen.dir, "ray_press": pen.front, "ray_down": front_edge,
			"holding": pen.front, "touch": not at_canvas, "aiming": not at_canvas})
	for side in ["left", "right"]:
		var h := hands[side] as HandInput
		if h.tracked and not (pen.tracked and side == stylus.active):
			sources.append({"id": side, "tip": h.tip, "point": h.pinch_point, "ray_o": h.aim_o, "ray_d": h.aim_d, "ray_press": h.pinching, "ray_down": h.pinch_down,
				"holding": h.pinching, "touch": true, "aiming": h.aiming})
	# the grab bar below the panel
	_update_handle(sources, busy)
	var best_uv := Vector2(-1, -1)
	var best_src := ""
	var best_rank := -1
	var press := false
	for s in sources:
		var id: String = s.id
		if _grab_src == id:
			busy[id] = true
			continue
		var holds_ui := _ui_src == id and _ui_pressed
		var info := panel.touch_info(s.tip, InputTuning.POKE_MARGIN)
		var uv := Vector2(-1, -1)
		var pressed := false
		var near := false
		var engaged := false                       # touching or pressing: the board does not get this source
		if bool(s.touch) and info.inside and info.depth > -InputTuning.POKE_BEHIND and info.depth < InputTuning.POKE_FRONT:
			near = true
			engaged = true
			uv = info.uv
			_menu_hits[id] = {"point": panel.global_transform * Vector3((uv.x - 0.5) * panel.size_m.x, (0.5 - uv.y) * panel.size_m.y, 0.0), "poke": true, "depth": float(info.depth)}
			var limit := POKE_RELEASE if holds_ui else POKE_PRESS
			pressed = info.depth < limit
		elif bool(s.aiming) or holds_ui:
			# pointing: hovering shows where the ray is (ring and highlight); a press that begins here clicks
			var rc := panel.raycast(s.ray_o, s.ray_d)
			if rc.hit and rc.t < InputTuning.MENU_RAY_REACH and (holds_ui or not _canvas_in_front(s, rc.t)):
				near = true
				uv = rc.uv
				pressed = bool(s.ray_press) and (bool(s.ray_down) or holds_ui)
				engaged = pressed or holds_ui
				_menu_hits[id] = {"point": rc.point, "poke": false}
		if not near:
			continue
		if engaged:
			busy[id] = true
		var rank := 3 if holds_ui else 2 if pressed else 1 if id == _ui_src else 0
		if rank > best_rank:
			best_rank = rank
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
			print("[menu] press by %s at %s on %s" % [best_src, str(best_uv), _control_at(best_uv)])
			if best_src == "pen":
				pen.tick(0.25, 0.015)
		elif not press and _ui_pressed:
			panel.pointer_release(best_uv)
			_ui_pressed = false
			print("[menu] release by %s at %s on %s" % [best_src, str(best_uv), _control_at(best_uv)])
	elif _ui_src != "":
		if _ui_pressed:
			panel.pointer_release(Vector2(-1, -1))
		panel.pointer_leave()
		_ui_pressed = false
		_ui_src = ""
	return busy


## A canvas nearer along this ray than the menu hides it: the pinch belongs to the canvas.
func _canvas_in_front(s: Dictionary, menu_t: float) -> bool:
	var t := board.hand_ctl.ray_target(s.ray_o, s.ray_d)
	return not t.is_empty() and float(t.t) < menu_t - 0.05


## How far a ray passes from a point (INF when the point is behind it or out of the menu's reach).
static func _ray_miss(o: Vector3, d: Vector3, p: Vector3) -> float:
	var t := (p - o).dot(d)
	if t < 0.02 or t > InputTuning.MENU_RAY_REACH:
		return INF
	return (o + d * t).distance_to(p)


## The menu's handle moves it like a canvas bar: within reach of the pinch point (nib) it follows 1:1; pointing at it from a distance, the
## menu moves further than the hand by the ratio of their distances from the head. Pinch (stylus: front button) starts, letting go drops.
func _update_handle(sources: Array, busy: Dictionary) -> void:
	var hp := panel.handle_world()
	if _grab_src != "":
		for s in sources:
			if s.id != _grab_src or not bool(s.holding):
				continue
			_face_head(_grab_origin + ((s.point as Vector3) - _grab_p0) * _grab_gain)
			busy[s.id] = true
			panel.set_handle_state(true, true)
			return
		_grab_src = ""
		panel.set_handle_state(false, false)
		return
	var hover := false
	for s in sources:
		var pt: Vector3 = s.point
		var touching := pt.distance_to(hp) < InputTuning.HANDLE_NEAR
		var pointing := not touching and bool(s.aiming) and _ray_miss(s.ray_o, s.ray_d, hp) < InputTuning.HANDLE_RAY_R
		if not (touching or pointing):
			continue
		hover = true
		if bool(s.ray_down):
			busy[s.id] = true
			_grab_src = s.id
			_grab_origin = panel.global_position
			_grab_p0 = pt
			_grab_gain = 1.0 if touching else InputTuning.carry_gain(camera.global_position, panel.global_position, pt)
			break
	panel.set_handle_state(hover, _grab_src != "")


## Holding the stylus's front button with nothing to grab (the nib away from every canvas, and not pointing at one): the menu comes.
func _stylus_summon(delta: float, pen: PenState, stylus_here: bool) -> void:
	if not stylus_here or not pen.front or board.hand_ctl.is_holding() or not board.grabs.is_empty() or _ui_src == "pen" or _grab_src == "pen" \
			or not board.pen_target(pen.tip, InputTuning.SUMMON_STYLUS_CANVAS, 0.2).is_empty() \
			or not board.hand_ctl.ray_target(pen.tip, pen.dir).is_empty():
		_front_t = 0.0
		return
	_front_t += delta
	if _front_t > InputTuning.SUMMON_HOLD_S:
		_front_t = -10.0                           # once per press
		_place_panel_front()
		panel.request_update()
		pen.tick(0.4, 0.03)
		print("[xr] menu brought in front by the stylus")


## Open palm facing up for a moment: the menu comes in front of you, the same place the stylus brings it to.
func _summon_gesture(delta: float, stylus_here: bool) -> void:
	if panel == null:
		return
	for side in ["left", "right"]:
		var h := hands[side] as HandInput
		if stylus_here and side == stylus.active:
			continue
		if h.tracked and h.palm_up and not h.pinching and h.palm.distance_to(camera.global_position) < InputTuning.PALM_SUMMON_DIST:
			_palm_t[side] += delta
			if _palm_t[side] > InputTuning.SUMMON_HOLD_S:
				_palm_t[side] = -InputTuning.PALM_REARM_S
				_place_panel_front()
				panel.request_update()
		else:
			_palm_t[side] = minf(_palm_t[side] + delta, 0.0) if _palm_t[side] < 0.0 else 0.0


## A tick for each pinch that closes or opens (the hands have no haptics).
func _hand_feedback(stylus_here: bool) -> void:
	for side in ["left", "right"]:
		var h := hands[side] as HandInput
		if not h.tracked or (stylus_here and side == stylus.active):
			continue
		if h.pinch_down:
			feedback.play("press")
		elif h.pinch_up:
			feedback.play("release")
