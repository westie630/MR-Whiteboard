class_name ModelController
extends RefCounted
## What the pointers do to 3D models. The same vocabulary as on canvases (HandController): a pinch, or the stylus's front button (on the PC
## the left or middle mouse button), grabs; touching (the pinch point or the nib in or at the model) moves things 1:1, pointing moves them
## further than the hand by the ratio of the distances from the head.
##  - a tap on a model selects it: its handles appear (ModelGizmo) and the model bar under it (ModelBar),
##  - a drag on a model carries it (selected or not) and turns it as the hand (or the stylus) turns: touching, about the pinch point, as
##    if it were in the hand; pointing, about its middle. A second pointer on it turns and resizes it with the first (in any direction); while it
##    is carried it shows no box, no handles and no bar, and it stays unselected afterwards (a tap selects it again). A hand inside the
##    selected model grabs the model, not the handles inside it (those are pointed at; the ones outside it can be touched too),
##  - the handles of the selected model: Move (an arrow slides along an axis, a square in a plane, the ball moves freely), Rotate (a ring
##    turns about its axis), Scale (a corner makes it bigger or smaller about its middle, an axis cube stretches it along its own axis).
## Snap (the bar) moves in centimetre steps, turns in 15 degree steps and sizes in centimetre steps. Every hold is one undo step, done through
## the Board's grabs, so the others of a session see it move while it happens (LiveOut) and get the result when it is let go.
## A pointer is the model's when the model (or a handle) is nearer along its ray than any canvas, or when it touches the model; the
## HandController then leaves that pointer alone (`claimed`), and the pen does not start a stroke under it.

const POINTERS := ["left", "right", "pen"]
const MODES := ["move", "rotate", "scale"]
const BODY := "body"

var board: Board
var gizmo: ModelGizmo
var selected := ""                         # the frame id of the model whose handles show ("" none)
var mode := "move"
var space := "local"                       # the axes Move and Rotate use: "local" (the model's own) or "room"
var snap := false
## side -> {point, kind: "model" | "handle" | "hold", handle, fid, direct}: what each pointer is on (HandCursor draws it); rebuilt every update()
var hover: Dictionary = {}
var claimed: Dictionary = {}               # side -> true: the HandController must leave this pointer alone this frame
var readout := ""                          # what the held handle is doing ("+12.0 cm", "45 deg", "38 x 22 x 40 cm")

var _holds: Dictionary = {}                # side -> {fid, what, p0, xf0, scale0, stretch0, direct, gain, ...}
var _taps: Dictionary = {}                 # side -> {fid, p0, point, direct}: a pinch on a model, not yet a drag or a tap
var _two: Dictionary = {}                  # two pointers turning and resizing one model
var _pen_ptr := HandInput.new("pen")
var _pen_mouse := false
var _pen_state: PenState
var _armed := false
var _prev_press := false
var _mouse_depth := 1.0
var _told := false


func _init(b: Board) -> void:
	board = b
	gizmo = ModelGizmo.new()


# ------------------------------------------------------------------------------------------------ the selection

func select(fid: String) -> void:
	if fid == selected:
		return
	selected = fid
	if fid != "":
		board.clear_selection()
		if not _told:
			_told = true
			board.toast.emit("Model selected: pull its arrows to move it, its rings to turn it, its cubes to resize it (the bar under it switches). Drag the model itself to carry it; two hands turn and resize it.")
	board.changed.emit()


func deselect() -> void:
	select("")


func set_mode(m: String) -> void:
	if MODES.has(m) and m != mode:
		mode = m
		board.changed.emit()


func set_space(s: String) -> void:
	if s in ["local", "room"] and s != space:
		space = s
		board.changed.emit()


func set_snap(on: bool) -> void:
	if on != snap:
		snap = on
		board.changed.emit()


func selected_frame() -> FrameData:
	return board.doc.frames.get(selected) if board.doc != null and selected != "" else null


## Something is held or pressed on a model (the interface fades back meanwhile).
func is_holding() -> bool:
	return not _holds.is_empty() or not _taps.is_empty()


## The stylus (or the mouse) is busy with a model: no stroke may start under it.
func pen_busy() -> bool:
	return _holds.has("pen") or _taps.has("pen")


# ------------------------------------------------------------------------------------------------ per frame

## hands: the HandInputs that are free to act; pen: the stylus (or the mouse). Called before the HandController.
func update(hands: Array, dt: float, pen: PenState = null) -> void:
	claimed = {}
	hover = {}
	if board.doc == null:
		return
	var seen := {}
	for h in hands:
		seen[(h as HandInput).side] = h
	var sp := _feed_pen(pen)
	if sp != null:
		seen["pen"] = sp
	for side in POINTERS:
		var h: HandInput = seen.get(side)
		if h == null or not h.tracked:
			_release(side)
			_taps.erase(side)
			continue
		_update_pointer(side, h)
	_update_two(seen)
	if dt > 0.0:
		layout()


## The stylus as a pointer: the nib is its pinch point and its body the ray, the front button pinches (as in HandController). The mouse: its
## ray from the eye, and either button that acts (left: the "nib", Shift+left: the front button) pinches; its pinch point stays at the depth
## it pressed at.
func _feed_pen(pen: PenState) -> HandInput:
	_pen_state = pen
	var p := _pen_ptr
	p.pinch_down = false
	p.pinch_up = false
	var live := pen != null and pen.tracked and not pen.docked and (pen.source == "stylus" or pen.source == "mouse")
	if not live:
		_armed = false
		_prev_press = false
		p.tracked = false
		p.pinching = false
		return null
	_pen_mouse = pen.source == "mouse"
	var o := board.head.origin if _pen_mouse else pen.tip
	p.tracked = true
	p.palm_up = false
	p.aiming = true
	p.system_aim = true
	p.tip = pen.tip
	p.aim_o = o
	p.aim_d = pen.dir.normalized()
	p.live_o = o
	p.live_d = p.aim_d
	p.press_o = o
	p.press_d = p.aim_d
	var press := pen.front or (_pen_mouse and pen.down)
	if press and not _prev_press:
		_armed = board.pen_ctl.state == PenController.S.IDLE and not board.hand_ctl.pen_busy() and (_pen_mouse or not pen.down)
	_prev_press = press
	if not press:
		_armed = false
	var now := press and _armed
	p.pinch_down = now and not p.pinching
	p.pinch_up = p.pinching and not now
	p.pinching = now
	p.pinch_point = o + p.aim_d * _mouse_depth if _pen_mouse else pen.tip
	p.has_grip = not _pen_mouse
	p.grip = pen.basis
	return p


func _update_pointer(side: String, h: HandInput) -> void:
	if _holds.has(side):
		claimed[side] = true
		if not h.pinching:
			_release(side)
			return
		_step(side, h)
		return
	if _taps.has(side):
		claimed[side] = true
		var tp: Dictionary = _taps[side]
		if not board.model_nodes.has(str(tp.fid)):
			_taps.erase(side)
			return
		if not h.pinching:
			_taps.erase(side)
			select(str(tp.fid))                          # a tap: the model is selected
			_tick(side, 0.25, 0.015)
			return
		var turned := h.has_grip and rad_to_deg(_turn_angle(tp.b0 as Basis, h.grip)) > InputTuning.TURN_START
		if h.pinch_point.distance_to(tp.p0 as Vector3) > InputTuning.MOVE_START or turned:
			_taps.erase(side)
			_begin_hold(side, h, str(tp.fid), BODY, tp)
			if _holds.has(side):
				(_holds[side] as Dictionary).p0 = tp.p0       # the model catches up with the hand from where the pinch began
				(_holds[side] as Dictionary).b0 = tp.b0
				_step(side, h)
			return
		hover[side] = {"point": tp.point, "kind": "model", "handle": "", "fid": tp.fid, "direct": tp.direct}
		return
	if _hand_busy(side):
		return
	var t := _target(side, h, h.pinch_down)
	if t.is_empty():
		if h.pinch_down and selected != "" and _canvas_target(side, h, true).is_empty():
			deselect()                                   # a pinch on nothing at all lets go of the model
		return
	var ct := _canvas_target(side, h, h.pinch_down)
	if not _wins(t, ct):
		return
	claimed[side] = true
	hover[side] = {"point": t.point, "kind": t.kind, "handle": str(t.get("handle", "")), "fid": t.fid, "direct": t.direct}
	if not h.pinch_down:
		return
	if side == "pen" and _pen_mouse:
		_mouse_depth = maxf(float(t.t), 0.05)
		h.pinch_point = h.aim_o + h.aim_d * _mouse_depth
		t.p0 = h.pinch_point
	if str(t.kind) == "handle":
		_begin_hold(side, h, str(t.fid), str(t.handle), t)
	elif _partner(side, str(t.fid)) != "":
		_begin_hold(side, h, str(t.fid), BODY, t)       # the other hand carries it: this one joins (turn and resize with both)
	else:
		_taps[side] = {"fid": t.fid, "p0": h.pinch_point, "b0": h.grip, "point": t.point, "direct": t.direct}
		_tick(side, 0.3, 0.02)


## Is this pointer busy with a canvas (holding one, or the pen in the middle of something)?
func _hand_busy(side: String) -> bool:
	var hc := board.hand_ctl
	if hc._holds.has(side) or hc._maybe_move.has(side):
		return true
	if hc._pens.has(side) and (hc._pens[side] as PenController).state != PenController.S.IDLE:
		return true
	return side == "pen" and _pen_state != null and (_pen_state.down and not _pen_mouse or board.pen_ctl.state != PenController.S.IDLE)


## The canvas this pointer is on (as the HandController would see it): {t, direct, ...} or {}.
func _canvas_target(side: String, h: HandInput, at_press: bool) -> Dictionary:
	if side == "pen" and _pen_mouse:
		return board.hand_ctl.ray_target(h.aim_o, h.aim_d)
	return board.hand_ctl.target_of(h, at_press)


## A model (or a handle) wins a pointer over a canvas when it touches it, or when it is nearer along the ray.
static func _wins(t: Dictionary, ct: Dictionary) -> bool:
	if ct.is_empty() or bool(t.direct):
		return true
	if bool(ct.get("direct", false)):
		return false
	return float(t.t) <= float(ct.get("t", INF)) + 0.02


## What a pointer is on: a handle of the selected model, else a model. {kind: "handle" | "model", fid, handle, t, point, direct} or {}.
func _target(side: String, h: HandInput, at_press: bool) -> Dictionary:
	var o := h.press_o if at_press else h.aim_o
	var d := (h.press_d if at_press else h.aim_d).normalized()
	var can_touch := not (side == "pen" and _pen_mouse) and not h.palm_up
	var can_point := h.aiming
	if gizmo.visible and selected != "" and board.model_nodes.has(selected) and not _locked(selected):
		var g := {}
		# a hand inside the model grabs the model itself (to carry it), not the handles inside it: those outside it are touched, all pointed at
		var inside := can_touch and (board.model_nodes[selected] as ModelNode).contains(h.pinch_point)
		if can_touch and not inside:
			g = gizmo.pick(o, d, h.pinch_point, true)
			if not g.is_empty():
				return {"kind": "handle", "handle": g.id, "fid": selected, "t": 0.0, "point": h.pinch_point, "direct": true}
		if can_point and not inside:
			g = gizmo.pick(o, d, h.pinch_point, false)
			if not g.is_empty():
				return {"kind": "handle", "handle": g.id, "fid": selected, "t": float(g.t), "point": o + d * float(g.t), "direct": false}
	var best := {}
	var best_t := INF
	for fid in board.model_nodes:
		var mn: ModelNode = board.model_nodes[fid]
		if not mn.visible or _locked(fid):
			continue
		if can_touch and mn.contains(h.pinch_point, InputTuning.MODEL_TOUCH):
			var dc := h.pinch_point.distance_to(mn.global_position)
			if not bool(best.get("direct", false)) or dc < float(best.get("dc", INF)):
				best = {"kind": "model", "fid": fid, "t": 0.0, "point": h.pinch_point, "direct": true, "dc": dc}
			continue
		if can_point and not bool(best.get("direct", false)):
			var r := mn.ray_hit(o, d, InputTuning.MODEL_RAY_GROW)
			if not r.is_empty() and float(r.t) < best_t:
				best_t = float(r.t)
				best = {"kind": "model", "fid": fid, "t": float(r.t), "point": r.point, "direct": false}
	return best


func _locked(fid: String) -> bool:
	var f: FrameData = board.doc.frames.get(fid)
	return f == null or f.locked


## Another pointer carrying this model by its body ("" when there is none).
func _partner(side: String, fid: String) -> String:
	for s in POINTERS:
		if s != side and _holds.has(s) and str((_holds[s] as Dictionary).fid) == fid and str((_holds[s] as Dictionary).what) == BODY:
			return s
	return ""


# ------------------------------------------------------------------------------------------------ holding

func _begin_hold(side: String, h: HandInput, fid: String, what: String, t: Dictionary) -> void:
	var f: FrameData = board.doc.frames.get(fid)
	var mn: ModelNode = board.model_nodes.get(fid)
	if f == null or mn == null or f.locked:
		return
	var turns := what == BODY or what.begins_with("m") or what.begins_with("p") or what.begins_with("r")
	if turns and what != BODY and f.place_locked:
		board.place_locked(f)
		return
	if not board.grabs.has(fid):
		board.begin_grab(f)
	if not board.grabs.has(fid):
		return                                           # refused (a guest without the owner's say-so)
	var g: Dictionary = board.grabs[fid]
	if not g.has("stretch"):
		g.stretch = f.stretch
	var xf := g.xf as Transform3D
	var direct := bool(t.get("direct", false))
	var hold := {"fid": fid, "what": what, "p0": h.pinch_point, "xf0": xf, "scale0": float(g.scale), "stretch0": g.stretch, "direct": direct,
		"c0": xf.origin, "last": h.pinch_point, "b0": h.grip, "last_b": h.grip}
	var c0 := xf.origin
	match what:
		BODY, "mc":
			hold.gain = 1.0 if direct or (side == "pen" and _pen_mouse) else InputTuning.carry_gain(board.head.origin, c0, h.pinch_point)
		"mx", "my", "mz":
			hold.axis = gizmo.axes[ModelGizmo.AXIS_IDS.find(what.substr(1))]
			hold.s0 = _axis_param(c0, hold.axis, h, direct)
		"pyz", "pxz", "pxy":
			var ax: Array = ModelGizmo.PLANE_AXES[what]
			hold.n = gizmo.axes[int(ax[2])]
			hold.u = gizmo.axes[int(ax[0])]
			hold.v = gizmo.axes[int(ax[1])]
			hold.q0 = _plane_point(c0, hold.n, h, direct)
		"rx", "ry", "rz":
			hold.axis = gizmo.axes[ModelGizmo.AXIS_IDS.find(what.substr(1))]
			hold.v0 = _ring_vec(c0, hold.axis, h, direct)
		"sx", "sy", "sz":
			var i := ModelGizmo.AXIS_IDS.find(what.substr(1))
			hold.i = i
			hold.axis = gizmo.own[i]
			hold.s0 = _axis_param(c0, hold.axis, h, direct)
		_:
			if what.begins_with("c"):
				var diag := (gizmo.corner(int(what.substr(1))) - c0).normalized()
				hold.axis = diag
				hold.s0 = _axis_param(c0, diag, h, direct)
	for key in ["s0", "q0", "v0"]:
		if hold.has(key) and hold[key] == null:
			board.end_grab(f)                            # (the ray runs along the axis: nothing to measure against)
			return
	_holds[side] = hold
	if what != BODY:
		gizmo.held = what
		select(fid)
	elif selected == fid:
		deselect()                                       # carried by hand: no box, no handles, no bar; a tap brings them back
	_tick(side, 0.3, 0.02)


func _step(side: String, h: HandInput) -> void:
	var hold: Dictionary = _holds[side]
	var fid := str(hold.fid)
	var f: FrameData = board.doc.frames.get(fid)
	var mn: ModelNode = board.model_nodes.get(fid)
	if f == null or mn == null or not board.grabs.has(fid):
		_release(side)
		return
	var g: Dictionary = board.grabs[fid]
	var direct := bool(hold.direct)
	var what := str(hold.what)
	var xf0 := hold.xf0 as Transform3D
	var xf := g.xf as Transform3D
	var c0 := hold.c0 as Vector3
	hold.last = h.pinch_point
	hold.last_b = h.grip
	var point := h.pinch_point
	match what:
		BODY, "mc":
			if not _two.is_empty() and str(_two.fid) == fid:
				pass                                     # both hands turn and resize it (_update_two)
			elif f.place_locked:
				if not hold.has("told") and h.pinch_point.distance_to(hold.p0 as Vector3) > InputTuning.MOVE_START * 2.5:
					hold.told = true
					board.place_locked(f)
			else:
				var delta := (h.pinch_point - (hold.p0 as Vector3)) * float(hold.gain)
				xf.origin = xf0.origin + _snap_vec(delta, gizmo.axes if what == "mc" else Basis.IDENTITY, what == "mc")
				if what == BODY and h.has_grip:                      # (the PC's pointers have none: Q / E turn it)
					var turn := _turn(hold.b0 as Basis, h.grip)
					xf.basis = turn * xf0.basis
					if direct:
						var arm := xf0.origin - (hold.p0 as Vector3)
						xf.origin += turn * arm - arm             # held in the hand: it turns about the pinch point
				readout = _cm(delta.length()) if what == "mc" else ""
		"mx", "my", "mz":
			var s1: Variant = _axis_param(c0, hold.axis, h, direct)
			if s1 != null:
				var dist := _snap_len(float(s1) - float(hold.s0))
				xf.origin = xf0.origin + (hold.axis as Vector3) * dist
				readout = ("+" if dist >= 0.0 else "-") + _cm(absf(dist))
				point = c0 + (hold.axis as Vector3) * float(s1)
		"pyz", "pxz", "pxy":
			var q1: Variant = _plane_point(c0, hold.n, h, direct)
			if q1 != null:
				var dv := (q1 as Vector3) - (hold.q0 as Vector3)
				var du := _snap_len(dv.dot(hold.u))
				var dw := _snap_len(dv.dot(hold.v))
				var moved := (hold.u as Vector3) * du + (hold.v as Vector3) * dw
				xf.origin = xf0.origin + moved
				readout = _cm(moved.length())
				point = q1
		"rx", "ry", "rz":
			var v1: Variant = _ring_vec(c0, hold.axis, h, direct)
			if v1 != null:
				var ang := (hold.v0 as Vector3).signed_angle_to(v1, hold.axis)
				if snap:
					ang = deg_to_rad(snappedf(rad_to_deg(ang), InputTuning.SNAP_TURN))
				xf.basis = Basis(hold.axis as Vector3, ang) * xf0.basis
				readout = "%d deg" % roundi(rad_to_deg(ang))
				point = c0 + (v1 as Vector3).normalized() * gizmo.ring_r
		"sx", "sy", "sz":
			var s2: Variant = _axis_param(c0, hold.axis, h, direct)
			if s2 != null and absf(float(hold.s0)) > 1e-4:
				var i := int(hold.i)
				var st := hold.stretch0 as Vector3
				var ratio := maxf(float(s2) / float(hold.s0), 0.01)
				var want := clampf(st[i] * ratio, FrameData.STRETCH.x, FrameData.STRETCH.y)
				if snap:
					var side_len := f.model_box.size[i] * float(g.scale)    # metres per unit of stretch along this axis
					if side_len > 1e-6:
						want = clampf(maxf(snappedf(want * side_len, InputTuning.SNAP_SIZE), InputTuning.SNAP_SIZE) / side_len, FrameData.STRETCH.x, FrameData.STRETCH.y)
				st[i] = want
				g.stretch = st
				mn.set_live_stretch(st)
				readout = _size_text(f.model_box.size * st * float(g.scale))
		_:
			if what.begins_with("c"):
				var s3: Variant = _axis_param(c0, hold.axis, h, direct)
				if s3 != null and absf(float(hold.s0)) > 1e-4:
					var sc := f.clamp_scale(float(hold.scale0) * maxf(float(s3) / float(hold.s0), 0.01))
					if snap:
						var longest := _longest(f.model_box.size * (g.stretch as Vector3))
						if longest > 1e-6:
							sc = f.clamp_scale(maxf(snappedf(sc * longest, InputTuning.SNAP_SIZE), InputTuning.SNAP_SIZE) / longest)
					g.scale = sc
					readout = _size_text(f.model_box.size * (g.stretch as Vector3) * sc)
	g.xf = xf
	hover[side] = {"point": point, "kind": "hold", "handle": what, "fid": fid, "direct": direct}


func _release(side: String) -> void:
	if not _holds.has(side):
		return
	var hold: Dictionary = _holds[side]
	_holds.erase(side)
	var fid := str(hold.fid)
	if not _two.is_empty() and str(_two.fid) == fid:
		_two = {}
		_rebase(fid)
	for s in _holds:
		if str((_holds[s] as Dictionary).fid) == fid:
			return                                       # the other pointer still holds it
	gizmo.held = ""
	readout = ""
	var f: FrameData = board.doc.frames.get(fid) if board.doc != null else null
	if f != null:
		board.end_grab(f)
	var mn: ModelNode = board.model_nodes.get(fid)
	if mn != null:
		mn.set_live_stretch(null)
	_tick(side, 0.2, 0.015)


## The pointers left holding a model start again from where it is now (after the other hand let go).
func _rebase(fid: String) -> void:
	if not board.grabs.has(fid):
		return
	var g: Dictionary = board.grabs[fid]
	for s in _holds:
		var hd: Dictionary = _holds[s]
		if str(hd.fid) == fid:
			hd.xf0 = g.xf
			hd.c0 = (g.xf as Transform3D).origin
			hd.scale0 = float(g.scale)
			hd.p0 = hd.get("last", hd.p0)
			hd.b0 = hd.get("last_b", hd.b0)


## Two pointers carrying the same model turn it (in any direction: the line between them turns it) and resize it (their spread), about
## the point between them. A model whose place is locked only changes size, about its middle.
func _update_two(seen: Dictionary) -> void:
	var pair: Array = []
	var fid := ""
	for s in POINTERS:
		var hd: Dictionary = _holds.get(s, {})
		if hd.is_empty() or str(hd.what) != BODY or not seen.has(s):
			continue
		if pair.is_empty():
			pair.append(s)
			fid = str(hd.fid)
		elif str(hd.fid) == fid:
			pair.append(s)
			break
	if pair.size() < 2:
		if not _two.is_empty():
			var was := str(_two.fid)
			_two = {}
			_rebase(was)
		return
	var f: FrameData = board.doc.frames.get(fid)
	if f == null or not board.grabs.has(fid):
		return
	var a := (seen[pair[0]] as HandInput).pinch_point
	var b := (seen[pair[1]] as HandInput).pinch_point
	var g: Dictionary = board.grabs[fid]
	if _two.is_empty():
		if a.distance_to(b) < InputTuning.TWO_HAND_MIN:
			return
		_two = {"fid": fid, "v0": b - a, "mid0": (a + b) * 0.5, "scale0": float(g.scale), "xf0": g.xf}
		return
	var v0 := _two.v0 as Vector3
	var v := b - a
	var ratio := clampf(v.length() / maxf(v0.length(), 1e-4), InputTuning.TWO_HAND_RATIO.x, InputTuning.TWO_HAND_RATIO.y)
	var xf0 := _two.xf0 as Transform3D
	var sc := f.clamp_scale(float(_two.scale0) * ratio)
	ratio = sc / maxf(float(_two.scale0), 1e-9)
	var xf := xf0
	if not f.place_locked:
		var turn := Basis.IDENTITY
		if v0.normalized().dot(v.normalized()) > -0.999:
			turn = Basis(Quaternion(v0.normalized(), v.normalized()))
		var mid := (a + b) * 0.5
		xf.basis = turn * xf0.basis
		xf.origin = mid + turn * ((xf0.origin - (_two.mid0 as Vector3)) * ratio)
	g.xf = xf
	g.scale = sc
	readout = _size_text(f.model_box.size * (g.get("stretch", f.stretch) as Vector3) * sc)


# ------------------------------------------------------------------------------------------------ the maths of a handle

## How far along the line through `c` along `a` the pointer is: the pinch point's distance when touching, else the point of the line nearest
## the ray. null when the ray runs along the line.
func _axis_param(c: Vector3, a: Vector3, h: HandInput, direct: bool) -> Variant:
	if direct:
		return (h.pinch_point - c).dot(a)
	var d := h.aim_d.normalized()
	var w0 := c - h.aim_o
	var b := a.dot(d)
	var den := 1.0 - b * b
	if den < 1e-4:
		return null
	return (b * d.dot(w0) - a.dot(w0)) / den


## Where the pointer is on the plane through `c` with normal `n`: the pinch point put onto it when touching, else where the ray meets it.
func _plane_point(c: Vector3, n: Vector3, h: HandInput, direct: bool) -> Variant:
	if direct:
		return h.pinch_point - n * n.dot(h.pinch_point - c)
	var d := h.aim_d.normalized()
	if absf(d.dot(n)) < 0.05:
		return null
	return Plane(n, c).intersects_ray(h.aim_o, d)


## The direction from `c` to the pointer, in the plane square to `a` (a ring's plane). A ray almost along that plane uses its point nearest
## to `c` instead. null when the pointer is on the axis itself.
func _ring_vec(c: Vector3, a: Vector3, h: HandInput, direct: bool) -> Variant:
	var p: Vector3
	if direct:
		p = h.pinch_point
	else:
		var d := h.aim_d.normalized()
		var hit: Variant = Plane(a, c).intersects_ray(h.aim_o, d) if absf(d.dot(a)) > 0.15 else null
		p = hit if hit != null else h.aim_o + d * maxf((c - h.aim_o).dot(d), 0.0)
	var v := p - c
	v -= a * a.dot(v)
	return v if v.length() > 1e-4 else null


## How the hand (or the stylus) has turned since `b0`; with Snap, in SNAP_TURN steps about the same axis.
func _turn(b0: Basis, b1: Basis) -> Basis:
	var q := (b1 * b0.inverse()).orthonormalized().get_rotation_quaternion()
	if snap:
		var ang := q.get_angle()
		if ang < 1e-4:
			return Basis.IDENTITY
		return Basis(q.get_axis().normalized(), deg_to_rad(snappedf(rad_to_deg(ang), InputTuning.SNAP_TURN)))
	return Basis(q)


static func _turn_angle(b0: Basis, b1: Basis) -> float:
	return (b1 * b0.inverse()).orthonormalized().get_rotation_quaternion().get_angle()


func _snap_len(x: float) -> float:
	return snappedf(x, InputTuning.SNAP_MOVE) if snap else x


## A free move, snapped along `axes` when Snap is on (`use_axes` false: the room's).
func _snap_vec(v: Vector3, axes: Basis, use_axes: bool) -> Vector3:
	if not snap:
		return v
	var b := axes if use_axes else Basis.IDENTITY
	return b * Vector3(_snap_len(b.x.dot(v)), _snap_len(b.y.dot(v)), _snap_len(b.z.dot(v)))


static func _longest(v: Vector3) -> float:
	return maxf(absf(v.x), maxf(absf(v.y), absf(v.z)))


static func _cm(m: float) -> String:
	return "%.1f cm" % (m * 100.0) if m < 1.0 else "%.2f m" % m


## "38 x 22 x 40 cm" (or in metres when it is bigger).
static func size_text(v: Vector3) -> String:
	return _size_text(v)


static func _size_text(v: Vector3) -> String:
	v = v.abs()
	if _longest(v) >= 1.0:
		return "%.2f x %.2f x %.2f m" % [v.x, v.y, v.z]
	return "%s x %s x %s cm" % [_num(v.x * 100.0), _num(v.y * 100.0), _num(v.z * 100.0)]


static func _num(cm: float) -> String:
	return "%.1f" % cm if cm < 10.0 else str(roundi(cm))


func _tick(side: String, amplitude: float, seconds: float) -> void:
	if side == "pen" and _pen_state != null and not _pen_mouse:
		_pen_state.tick(amplitude, seconds)


# ------------------------------------------------------------------------------------------------ what is shown

## The handles round the selected model, and which models are lit (pointed at, selected). After update().
func layout() -> void:
	if selected != "" and (board.doc == null or not board.doc.frames.has(selected) or not board.model_nodes.has(selected) \
			or not (board.model_nodes[selected] as ModelNode).visible):
		selected = ""
		board.changed.emit()
	var lit := {}
	gizmo.hot = ""
	for side in hover:
		var hv: Dictionary = hover[side]
		lit[str(hv.fid)] = true
		if str(hv.kind) == "handle" and gizmo.hot == "":
			gizmo.hot = str(hv.handle)
	var carried := {}
	for side in _holds:
		if str((_holds[side] as Dictionary).what) == BODY:
			carried[str((_holds[side] as Dictionary).fid)] = true
	for fid in board.model_nodes:
		var mn: ModelNode = board.model_nodes[fid]
		mn.set_selected(fid == selected)
		mn.set_hover(1.0 if not carried.has(fid) and (lit.has(fid) or board.grabs.has(fid)) else 0.0)
	var node: ModelNode = board.model_nodes.get(selected)
	var rw: Variant = board.room_world(board.current_room) if board.doc != null else null
	gizmo.readout = readout
	gizmo.layout(node, mode, space, (rw as Transform3D).basis if rw != null else Basis.IDENTITY, board.head.origin)


## Every pointer lets go (a document closing).
func reset() -> void:
	for side in _holds.keys():
		_release(side)
	_holds.clear()
	_taps.clear()
	_two = {}
	selected = ""
	hover = {}
	claimed = {}
	readout = ""
	gizmo.held = ""
	gizmo.visible = false
