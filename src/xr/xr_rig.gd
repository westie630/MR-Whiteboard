class_name XrRig
extends Node3D
## The Quest 3 rig: mixed reality only (passthrough is always on), hands only, the MX Ink stylus for drawing.
##  - OpenXR start-up, passthrough, render quality (sharp: no foveation, 4x MSAA, supersampled)
##  - hand tracking -> HandInput (pinch, pointing ray) for moving canvases and for the menu
##  - the stylus -> PenState (see StylusInput); a pinch draws instead when no stylus is present (setting)
##  - the interface floats in the room as small panels (UiShell): the dock low in front of you, popovers above it, Home and the
##    assistant beside it, the bars that belong to a selection or to handwriting pinned to the canvas. Poke them with the stylus tip or
##    a fingertip, point and pinch (stylus: front button) from a distance, grab the bar under the dock or a side panel to move it,
##    open your palm facing up to bring the dock to you
##  - spatial anchors (MetaAnchors) and the room scan (MetaScene)
##  - the panels stay where they were left, in the real room (PanelPlaces): after a restart, with the headset taken off and put back
##    on, after recentring. The board keeps its canvases there through their anchors; the rig tells it when tracking stops and restarts

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
## Ghost hands: a filled dark silhouette, no outline. Shown only while a hand is between the eye and a panel (the panel would hide the real
## hand behind it); `fade` brings it in and out.
const GHOST_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_back, shadows_disabled;
uniform vec3 tint : source_color = vec3(0.05, 0.055, 0.065);
uniform float fade = 0.0;
void fragment() {
	float lit = 0.75 + 0.25 * clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);   // a little form, never lighter at the edge
	ALBEDO = tint * lit;
	ALPHA = 0.9 * fade;
}
"""
const GLOVE_FADE_RATE := 12.0              # per second
const GLOVE_PANEL_MARGIN := 0.04           # m: a hand this close to a panel's edge (seen from the eye) counts as in front of it
const MENU_MAX_DIST := InputTuning.MENU_MAX_DIST   # a menu further away than this (another room, or placed before the headset was on) comes back
const PANEL_WAIT_S := 5.0                  # at start (and with the headset back on) the panels wait this long for their anchor before coming in front
const MOVABLE := ["dock", "home", "assistant"]

var board: Board
var xr: XRInterface
var origin: XROrigin3D
var camera: XRCamera3D
var stylus: StylusInput
var anchors: AnchorService                 # MetaAnchors on the headset (tests hand in SimAnchors)
var places: PanelPlaces                    # where the dock and the side panels were left
var scene: MetaScene
var ui: UiShell
var panel: XrPanel                         # the dock's panel (the one that is summoned)
var panels := {}                           # surface id -> XrPanel
var hands := {"left": HandInput.new("left"), "right": HandInput.new("right")}
var passthrough_on := false

var _pt_check := 0.0
var _panel_placed := false
var _panel_wait := 0.0                     # how long the dock has waited for its saved place
var cursor: HandCursor
var feedback: Feedback                     # click sounds for the hands
var _prev_stylus := ""
var _front_t := 0.0
var _pinch_peak := {}                      # side -> the strongest pinch since the last status line (for the log)
var _glove_mats := {}                       # side -> that glove's ShaderMaterial (its fade)
var _glove_fade := {"left": 0.0, "right": 0.0}
var _gloves := {}                          # side -> the Node3D holding that ghost glove
var _hand_ctrls := {}                      # side -> {aim, poke}: XRController3D nodes reading the hand interaction profile
var _profiles := {}                        # side -> the interaction profile last reported (logged when it changes)
var _menu_hits := {}                       # side -> {point, poke}: where each hand's ray (or fingertip) is on the menu this frame
var _ui_src := ""                          # which source currently holds the menu pointer: "pen" | "left" | "right" | ""
var _ui_pressed := false
var _ui_panel: XrPanel                     # ...and on which panel
var _grab_src := ""                        # which source holds a panel's handle...
var _grab_panel: XrPanel
var _toast_placed := false
var _grab_origin := Vector3.ZERO           # ...where the menu was, where that source's point was, and how much further the menu moves
var _grab_p0 := Vector3.ZERO
var _grab_gain := 1.0
var _grab_touch := false                   # ...and whether it took hold by touching (not pointing)
var _handle_hits := {}                     # source -> {point, touch}: the bar under a panel each source is on or carries this frame
var _pen_front := false                    # the stylus's front button last frame (for its press edge)
var _palm_t := {"left": 0.0, "right": 0.0}
var _board_pen := PenState.new()
var _no_hands_t := 0.0
var _diag_t := 0.0


# ------------------------------------------------------------------------------------------------ start-up

## Starts the rig and returns the anchor service for the board. `service` replaces the headset's anchors (tests on the PC).
func start(b: Board, service: AnchorService = null) -> AnchorService:
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
	if OS.get_model_name().to_lower().contains("quest 2") and not App.is_set("xr_quality"):
		App.put("xr_quality", "performance", false)       # a Quest 2 has about half a Quest 3's GPU: start light, unless the user chose
	_apply_quality()
	xr.set("foveation_level", 0)
	xr.set("foveation_dynamic", false)
	if xr.has_method("set_cpu_level"):
		xr.call("set_cpu_level", 2)
		xr.call("set_gpu_level", 2)
	for sig in ["session_focussed", "session_begun", "session_visible", "session_stopping", "session_loss_pending"]:
		if xr.has_signal(sig):
			xr.connect(sig, _on_session.bind(sig))
	if xr.has_signal("pose_recentered"):
		xr.connect("pose_recentered", _on_recentered)
	origin = XROrigin3D.new()
	origin.name = "XROrigin"
	add_child(origin)
	camera = XRCamera3D.new()
	camera.near = 0.04
	camera.far = 40.0
	origin.add_child(camera)
	stylus = StylusInput.new()
	origin.add_child(stylus)
	if service != null:
		anchors = service
	else:
		var meta := MetaAnchors.new()
		add_child(meta)
		meta.setup(origin)
		anchors = meta
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
	places = PanelPlaces.new()
	places.setup(anchors, App.panel_places_path)
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
	elif key == "ui_scale":
		for xp in panels.values():
			(xp as XrPanel).set_ui_scale(float(App.val("ui_scale")))


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
	if which == "session_visible" or which == "session_stopping" or which == "session_loss_pending":
		# the headset is being taken off (or the system menu is over the app): save now, and the room is not searched for meanwhile
		board.tracking_live = false
		board.flush_save()
		if which != "session_visible" and anchors.has_method("suspend"):
			anchors.call("suspend", which == "session_loss_pending")
		return
	if which == "session_begun" or which == "session_focussed":
		_enable_multimodal()
	if which == "session_focussed" and camera != null and panel != null:
		# the headset was (re)put on: the tracking space may have moved under the room. The canvases and panels are found again
		# through their anchors and come back exactly where they were; only what has no anchor comes in front
		board.tracking_live = true
		board.tracking_reset()
		places.tracking_reset()
		_panel_placed = false
		_panel_wait = 0.0
	set_passthrough()
	if (which == "session_focussed" or which == "session_begun") and anchors.has_method("reload"):
		anchors.call("reload")


## The view was recentred (long press of the Meta button): the tracking space moved under the room. What is anchored stays in the room;
## panels without an anchor come in front again.
func _on_recentered() -> void:
	print("[xr] view recentred")
	board.tracking_reset()
	places.tracking_reset()
	if not places.anchored() and panel != null and _panel_placed:
		_place_panel_front()


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
	ui = UiShell.new()
	ui.name = "UiShell"
	add_child(ui)
	ui.setup(board)
	# each surface on its own panel, drawn in the 3D scene (not on a compositor layer, which the headset always puts over everything):
	# the gloves and the stylus can then be in front of them
	for p in ui.panels:
		var fp := p as FloatPanel
		var xp := XrPanel.new()
		xp.name = "Panel_" + fp.id
		xp.pivot = fp.pivot
		add_child(xp)
		xp.setup(fp, fp.max_size, fp.ppm, false)
		xp.set_ui_scale(float(App.val("ui_scale")))
		xp.visible = false
		panels[fp.id] = xp
	panel = panels["dock"]
	ui.opened.connect(_on_ui_opened)


## The dock comes low in front of you, tilted towards your eyes; side panels that are open come along beside it.
func _place_panel_front() -> void:
	var h := camera.global_transform
	var fwd := Vector3(-h.basis.z.x, 0.0, -h.basis.z.z).normalized()
	var right := fwd.cross(Vector3.UP)
	var pos := h.origin + fwd * InputTuning.SUMMON_AHEAD + right * InputTuning.SUMMON_RIGHT + Vector3(0, InputTuning.SUMMON_UP, 0)
	panel.global_transform = _facing(pos)
	panel.visible = true
	var put := {"dock": panel.global_transform}
	for id in ["home", "assistant"]:
		if ui.is_side_open(id):
			_beside_dock(id)
			put[id] = (panels[id] as XrPanel).global_transform
	places.put(put)


## A pose at `pos` that faces the head.
func _facing(pos: Vector3) -> Transform3D:
	var to := pos - camera.global_transform.origin
	if to.length() < 0.05:
		return Transform3D(Basis.IDENTITY, pos)
	return Transform3D(Basis.looking_at(to, Vector3.UP), pos)


func _face_head(pos: Vector3) -> void:
	panel.global_transform = _facing(pos)


## A side panel opened: where it was left, if that is known and within reach; otherwise beside the dock (and that is remembered).
func _place_side(id: String) -> void:
	var xp: XrPanel = panels[id]
	var saved: Variant = places.place_of(id)
	if saved != null and (saved as Transform3D).origin.distance_to(camera.global_transform.origin) <= MENU_MAX_DIST:
		xp.global_transform = saved
		return
	_beside_dock(id)
	places.put({id: xp.global_transform})


## A side panel beside the dock: Home on the left, the assistant on the right, a little higher, turned towards you.
func _beside_dock(id: String) -> void:
	var xp: XrPanel = panels[id]
	var fp: FloatPanel = ui.home if id == "home" else ui.assistant
	var d := panel.global_transform
	var dock_w := ui.dock.size.x * panel.mpp()
	var w := fp.size.x * xp.mpp()
	var pos := d.origin + d.basis.x.normalized() * float(fp.side) * (dock_w * 0.5 + w * 0.5 + 0.03) + Vector3.UP * (fp.size.y * xp.mpp() * 0.5 + 0.06)
	xp.global_transform = _facing(pos)


func _on_ui_opened(id: String) -> void:
	if id == "home" or id == "assistant":
		_place_side(id)


## Every frame: which panels show, and where the ones that follow something go.
func _place_ui(delta: float) -> void:
	var head := camera.global_transform
	for id in panels:
		var xp: XrPanel = panels[id]
		var fp := xp.widget as FloatPanel
		var want: bool = fp.visible and (str(id) != "dock" or _panel_placed)
		if xp.visible != want:
			xp.visible = want
			if want:
				xp.request_update()
		xp.set_pivot(fp.pivot)
	var d := panel.global_transform
	var up := d.basis.y.normalized()
	var dock_top := ui.dock.size.y * panel.mpp()
	# a popover, the typing card and the desk card stand on the dock (a popover over the button it came from)
	for id in ["popover", "compose", "surface", "align", "place"]:
		var xp2: XrPanel = panels[id]
		if not xp2.visible:
			continue
		var x := 0.0
		if id == "popover":
			x = (ui.dock.button_x(ui.popover_id) - ui.dock.size.x * 0.5) * panel.mpp()
			ui.popover.source_x = ui.popover.size.x * 0.5
		var pos := d.origin + d.basis.x.normalized() * x + up * (dock_top + 0.03)
		xp2.global_transform = _facing(pos)
	# bars pinned to a canvas, just in front of it
	for id in ["context", "ink", "suggestion", "pdf"]:
		var xp3: XrPanel = panels[id]
		var fp3: FloatPanel = xp3.widget as FloatPanel
		if not xp3.visible or fp3.anchor.is_empty():
			continue
		var fn: FrameNode = board.frame_nodes.get(str(fp3.anchor.frame))
		if fn == null:
			xp3.visible = false
			continue
		var fxf := fn.global_transform
		var b := fxf.basis.orthonormalized()
		var a: Vector2 = fp3.anchor.pos
		xp3.global_transform = Transform3D(b, fxf * Vector3(a.x, a.y, 0.0) + b.z * float(fp3.anchor.get("lift", 0.012)))
	# messages: a little above the middle of the view, following the head lazily
	var tp: XrPanel = panels["toast"]
	if tp.visible:
		var fwd := -head.basis.z
		var goal := head.origin + fwd * 0.75 + head.basis.y * 0.16
		if not _toast_placed:
			tp.global_transform = _facing(goal)
			_toast_placed = true
		else:
			tp.global_transform = _facing(tp.global_position.lerp(goal, clampf(delta * 3.0, 0.0, 1.0)))
	else:
		_toast_placed = false
	# side panels left far behind come back, unless their place is kept in the room by an anchor (then they stay where they were left:
	# the palm or the stylus brings the menu)
	for id in ["home", "assistant"]:
		var xs: XrPanel = panels[id]
		if not places.anchored() and xs.visible and xs.global_position.distance_to(head.origin) > MENU_MAX_DIST and _grab_panel != xs:
			_beside_dock(id)
			places.put({id: xs.global_transform})


## The dock and the side panels hold their saved places in the room: when the headset moves its tracking space under the room
## (re-localising, recentring) the anchor moves and they move with it. One being carried by its handle is left alone.
func _follow_places() -> void:
	for id in MOVABLE:
		var xp: XrPanel = panels[id]
		if xp == _grab_panel or (id == "dock" and not _panel_placed):
			continue
		var at: Variant = places.place_of(id)
		if at != null:
			xp.global_transform = at


## At start and with the headset back on, the dock goes back to where it was left once its anchor is found; it comes in front instead
## when it never had a place, its place is out of reach (another room), or its anchor is not found in time. Side panels that were open
## open again, at their places.
func _restore_dock(delta: float) -> void:
	_panel_wait += delta
	var saved: Variant = places.place_of("dock")
	if saved != null and (saved as Transform3D).origin.distance_to(camera.global_transform.origin) <= MENU_MAX_DIST:
		_panel_placed = true
		panel.global_transform = saved
		panel.visible = true
		print("[xr] the menu is back where it was left")
	elif saved != null or not places.has("dock") or _panel_wait >= PANEL_WAIT_S:
		_panel_placed = true
		_place_panel_front()
	else:
		return
	for id in ["home", "assistant"]:
		if places.is_open(id) and not ui.is_side_open(id) and board.doc != null:
			ui.open_side(id)


## Which side panels are open is remembered too.
func _remember_open() -> void:
	for id in ["home", "assistant"]:
		places.set_open(id, ui.is_side_open(id))


# ------------------------------------------------------------------------------------------------ physical keyboard

## A Bluetooth keyboard: the headset delivers its keys to the app window, but the menu lives in its own viewport, so keys are passed on
## to the field being edited there. With no field open, editing shortcuts work (Ctrl+Z, Delete ...), Enter edits the selected text or
## shape, and any character starts a new text.
func _input(e: InputEvent) -> void:
	if not (e is InputEventKey) or ui == null or panel == null or board == null or board.doc == null:
		return
	var k := e as InputEventKey
	if ui.is_typing():
		(panels["compose"] as XrPanel).viewport.push_input(k, false)
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
	if k.keycode == KEY_ESCAPE:
		ui.back()
		get_viewport().set_input_as_handled()
		return
	if enter or Shortcuts.is_printable(k):
		_show_menu()
		if ui.open_text_entry() and not enter:
			ui.compose.snap_fade()
			(panels["compose"] as XrPanel).viewport.push_input(k, false)    # the character that started the typing is the first one typed
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
	for side in ["left", "right"]:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		_glove_mats[side] = mat
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


## The gloves stop at the menu instead of passing through it when a fingertip pokes it, hide while the stylus is at a canvas, and show
## only while the hand is in front of a panel.
func _update_gloves(pen: PenState, stylus_here: bool, delta: float) -> void:
	var drawing := stylus_here and not board.pen_target(pen.tip, GLOVES_OFF_NEAR, 0.3).is_empty()
	for side in _gloves:
		var g: Node3D = _gloves[side]
		var want := 0.0 if drawing else (1.0 if _hand_before_panel(hands[side] as HandInput) else 0.0)
		var f := move_toward(float(_glove_fade[side]), want, GLOVE_FADE_RATE * delta)
		_glove_fade[side] = f
		(_glove_mats[side] as ShaderMaterial).set_shader_parameter("fade", f)
		g.visible = f > 0.01
		var push := Vector3.ZERO
		var m: Dictionary = _menu_hits.get(side, {})
		if bool(m.get("poke", false)) and float(m.get("depth", 1.0)) < 0.0:
			push = (m.normal as Vector3) * -float(m.depth)
		g.global_position = (g.get_parent() as Node3D).global_position + push


## Is any part of the hand between the eye and a visible panel, seen over the panel's face (or just beside it)?
func _hand_before_panel(h: HandInput) -> bool:
	if not h.tracked:
		return false
	var eye := camera.global_position
	for id in panels:
		var xp: XrPanel = panels[id]
		if not xp.visible:
			continue
		for p in [h.tip, h.knuckle, h.palm, h.pinch_point]:
			if xp.covers(eye, p as Vector3, GLOVE_PANEL_MARGIN):
				return true
	return false


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
	places.update(delta)
	if not _panel_placed and head.origin.y > 0.3:
		_restore_dock(delta)
	elif not places.anchored() and panel.visible and panel.global_position.distance_to(head.origin) > MENU_MAX_DIST and _grab_src == "":
		print("[xr] the menu was %.1f m away: brought back in front" % panel.global_position.distance_to(head.origin))
		_place_panel_front()
	_follow_places()
	if _panel_placed:
		_remember_open()
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
	_place_ui(delta)
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
	cursor.update(hands, _menu_hits, board.hand_ctl.hover, head.origin, stylus.active if stylus_here else "", pen, _handle_hits)
	_update_gloves(pen, stylus_here, delta)
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

## For the log: the button (or other control) under a point of a panel.
func _control_at(xp: XrPanel) -> String:
	var c := xp.viewport.gui_get_hovered_control() if xp != null else null
	if c == null:
		return "nothing"
	if c is Btn:
		return "button \"%s\" on %s" % [(c as Btn).text if (c as Btn).text != "" else (c as Btn).icon, xp.name]
	return "%s on %s" % [c.get_class(), xp.name]


## The panels that are showing and can be pointed at.
func _live_panels() -> Array:
	var out: Array = []
	for xp in panels.values():
		var p := xp as XrPanel
		if p.visible and p.widget.visible and p.widget.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			out.append(p)
	return out


func _ray_on_panel(s: Dictionary) -> bool:
	for xp in _live_panels():
		if bool((xp as XrPanel).raycast(s.ray_o, s.ray_d).hit):
			return true
	return false


func _is_canvas_panel(xp: XrPanel) -> bool:
	return (xp.widget as FloatPanel).kind == "canvas"


func _release_ui() -> void:
	if _ui_panel != null and is_instance_valid(_ui_panel):
		if _ui_pressed:
			_ui_panel.pointer_release(Vector2(-1, -1))
		_ui_panel.pointer_leave()
	_ui_pressed = false
	_ui_src = ""
	_ui_panel = null


## Pokes, rays and the grab bars. Returns which sources are busy with the interface ({pen, left, right}: true) so the board ignores them.
## One model for hands and stylus: TOUCH a button (fingertip or nib within the poke zone), or POINT at it and press (hand: pinch, stylus:
## front button). At a canvas the stylus draws and grabs instead, so it is not offered the panels there, except the bars pinned to the
## canvas itself (touching one with the nib presses it, as long as the pen is not in the middle of a stroke). A source is busy only while
## it touches a panel or is pressing it: a ray that merely crosses a panel, or a pinch that began on a canvas, is still the board's.
## Of all the panels a source reaches, a touch beats a ray and the nearest wins; one source at a time drives one panel.
func _update_menu(pen: PenState) -> Dictionary:
	var busy := {}
	_menu_hits = {}
	_handle_hits = {}
	var front_edge := pen.front and not _pen_front
	_pen_front = pen.front
	var live := _live_panels()
	if live.is_empty():
		if _ui_src != "":
			_release_ui()
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
	# the grab bars below the dock and the side panels
	_update_handle(sources, busy)
	var pen_idle := board.pen_ctl.state == PenController.S.IDLE
	var best_uv := Vector2(-1, -1)
	var best_src := ""
	var best_rank := -1
	var best_panel: XrPanel = null
	var press := false
	for s in sources:
		var id: String = s.id
		if _grab_src == id:
			busy[id] = true
			continue
		var holds_ui := _ui_src == id and _ui_pressed and _ui_panel != null
		var cands: Array = [_ui_panel] if holds_ui else live
		var hit := {}
		# touching: the panel the tip is nearest to
		for c in cands:
			var xp := c as XrPanel
			var touch_ok := bool(s.touch) or (id == "pen" and pen_idle and _is_canvas_panel(xp))
			if not touch_ok:
				continue
			var info := xp.touch_info(s.tip, InputTuning.POKE_MARGIN)
			if info.inside and info.depth > -InputTuning.POKE_BEHIND and info.depth < InputTuning.POKE_FRONT:
				if hit.is_empty() or absf(float(info.depth)) < absf(float(hit.depth)):
					hit = {"panel": xp, "uv": info.uv, "poke": true, "depth": float(info.depth)}
		# pointing: hovering shows where the ray is (ring and highlight); a press that begins here clicks
		if hit.is_empty() and (bool(s.aiming) or holds_ui):
			var best_t := INF
			for c in cands:
				var xp2 := c as XrPanel
				var rc := xp2.raycast(s.ray_o, s.ray_d)
				if rc.hit and float(rc.t) < InputTuning.MENU_RAY_REACH and float(rc.t) < best_t and (holds_ui or not _canvas_in_front(s, rc.t)):
					best_t = float(rc.t)
					hit = {"panel": xp2, "uv": rc.uv, "poke": false, "point": rc.point}
		if hit.is_empty():
			continue
		var hp: XrPanel = hit.panel
		var uv: Vector2 = hit.uv
		var pressed := false
		var engaged := false                       # touching or pressing: the board does not get this source
		if bool(hit.poke):
			engaged = true
			pressed = float(hit.depth) < (POKE_RELEASE if holds_ui else POKE_PRESS)
			_menu_hits[id] = {"point": hp.point_at(uv), "poke": true, "depth": float(hit.depth), "normal": hp.global_transform.basis.z.normalized()}
		else:
			pressed = bool(s.ray_press) and (bool(s.ray_down) or holds_ui)
			engaged = pressed or holds_ui
			_menu_hits[id] = {"point": hit.point, "poke": false, "normal": hp.global_transform.basis.z.normalized()}
		if engaged:
			busy[id] = true
		var rank := 3 if holds_ui else 2 if pressed else 1 if id == _ui_src else 0
		if rank > best_rank:
			best_rank = rank
			best_src = id
			best_uv = uv
			best_panel = hp
			press = pressed
	# one pointer drives one panel
	if best_src != "":
		if best_panel != _ui_panel:
			if _ui_panel != null and is_instance_valid(_ui_panel):
				if _ui_pressed:
					_ui_panel.pointer_release(Vector2(-1, -1))
				_ui_panel.pointer_leave()
			_ui_pressed = false
			_ui_panel = best_panel
		_ui_src = best_src
		_ui_panel.pointer_move(best_uv)
		if press and not _ui_pressed:
			_ui_panel.pointer_press(best_uv)
			_ui_pressed = true
			print("[menu] press by %s at %s on %s" % [best_src, str(best_uv), _control_at(_ui_panel)])
			if best_src == "pen":
				pen.tick(0.25, 0.015)
		elif not press and _ui_pressed:
			_ui_panel.pointer_release(best_uv)
			_ui_pressed = false
			print("[menu] release by %s at %s on %s" % [best_src, str(best_uv), _control_at(_ui_panel)])
	elif _ui_src != "":
		_release_ui()
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


## A panel's handle (under the dock and the side panels) moves it like a canvas bar: within reach of the pinch point (nib) it follows
## 1:1; pointing at it from a distance, the panel moves further than the hand by the ratio of their distances from the head. Pinch
## (stylus: front button) starts, letting go drops. What stands on the dock (a popover, the typing card) goes with it.
func _update_handle(sources: Array, busy: Dictionary) -> void:
	if _grab_src != "":
		for s in sources:
			if s.id != _grab_src or not bool(s.holding) or _grab_panel == null:
				continue
			_grab_panel.global_transform = _facing(_grab_origin + ((s.point as Vector3) - _grab_p0) * _grab_gain)
			_handle_hits[s.id] = {"point": _grab_panel.handle_world(), "touch": _grab_touch}
			busy[s.id] = true
			_grab_panel.set_handle_state(true, true)
			return
		_grab_src = ""
		if _grab_panel != null:
			_grab_panel.set_handle_state(false, false)
			places.put({(_grab_panel.widget as FloatPanel).id: _grab_panel.global_transform})     # left here: remembered in the room
		_grab_panel = null
		return
	for xp in panels.values():
		var p := xp as XrPanel
		if not (p.widget as FloatPanel).movable:
			p.handle.visible = false
			continue
		p.handle.visible = p.visible
		if not p.visible:
			continue
		var hp := p.handle_world()
		var hover := false
		for s in sources:
			var pt: Vector3 = s.point
			var touching := pt.distance_to(hp) < InputTuning.HANDLE_NEAR
			# (a ray that is on a panel is pressing a button there: the handle of a slim panel like the dock is close by)
			var pointing := not touching and bool(s.aiming) and _ray_miss(s.ray_o, s.ray_d, hp) < InputTuning.HANDLE_RAY_R and not _ray_on_panel(s)
			if not (touching or pointing):
				continue
			hover = true
			_handle_hits[s.id] = {"point": hp, "touch": touching}
			if bool(s.ray_down) and _grab_src == "":
				busy[s.id] = true
				_grab_src = s.id
				_grab_panel = p
				_grab_origin = p.global_position
				_grab_p0 = pt
				_grab_gain = 1.0 if touching else InputTuning.carry_gain(camera.global_position, p.global_position, pt)
				_grab_touch = touching
				break
		p.set_handle_state(hover, _grab_panel == p)


## Holding the stylus's front button with nothing to grab (the nib away from every canvas, and not pointing at one): the menu comes.
func _stylus_summon(delta: float, pen: PenState, stylus_here: bool) -> void:
	if panel == null or not stylus_here or not pen.front or board.hand_ctl.is_holding() or not board.grabs.is_empty() or _ui_src == "pen" or _grab_src == "pen" \
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
