class_name HandController
extends RefCounted
## What the pointers do on the board: the bare hands (a pinch) and the stylus (its front button) share one vocabulary, so a task is done
## the same way with either. A pointer TOUCHES a canvas when its pinch point (the nib, for the stylus) is within DIRECT_NEAR of it, and
## otherwise POINTS at it with a ray. What it grabs depends only on what it is on, and nothing is picked up by accident:
##  - on a shape, line, stroke or one of the selection's handles: it selects, drags and reshapes exactly like the Select tool
##    (each pointer drives a PenController of its own in hand mode),
##  - on empty canvas: a drag carries the canvas, a tap lets go of the selection,
##  - on the grab bar under a canvas: it carries the canvas; letting go fixes it with a new anchor,
##  - on a corner of a canvas: it changes the canvas's extent,
##  - the second hand pinching the same canvas (bar or empty area) turns and resizes it together with the first,
##  - a curved desk: empty canvas slides its contents along the surface, the bar carries the desk along the real desk, two pointers turn
##    and move it (never resize it).
## Touching moves things 1:1 with the pinch point; pointing from a distance moves them further than the hand, by the ratio of their
## distances from the head. HandCursor draws what each pointer is on (`hover`), including the bar and the corners of the canvas under it.

const BAR_DROP := InputTuning.BAR_DROP     # the bar sits this far (world metres) below the canvas's bottom edge
const BAR_HIT_W := InputTuning.BAR_HIT_W   # half width / half height of the area that counts as the bar
const BAR_HIT_H := InputTuning.BAR_HIT_H
const CORNER_HIT := InputTuning.CORNER_HIT
const PLANE_SLACK := InputTuning.PLANE_SLACK   # a pointer may meet a canvas this far outside its extent (the bar and the corners are out there)
const REACH := InputTuning.REACH           # item pick radii at a distance are this many times the stylus's: a ray at arm's length is not a nib
const KINDS_THAT_JOIN := ["canvas", "bar"]
const MAX_GAIN := InputTuning.MAX_GAIN     # the most a carried canvas moves per metre of hand movement
const MOVE_START := InputTuning.MOVE_START # a pinch on empty canvas that moves this far (m) carries the canvas; less is a tap
const POINTERS := ["left", "right", "pen"]

var board: Board
var grab_anywhere := false                 # the PC's synthetic pinch picks a canvas up wherever it is
## side -> {fn: FrameNode, point: Vector3, kind: "canvas" | "item" | "bar" | "corner" | "hold", corner: int, direct: bool}; rebuilt every update()
var hover: Dictionary = {}

var _holds: Dictionary = {}                # side -> {f: FrameData, fn: FrameNode, p0, origin0, corner, opp, gain, direct}
var _two: Dictionary = {}                  # two-hand grab: {f, d0, mid0, yaw0, scale0, basis0, origin0}
var _pens: Dictionary = {}                 # side -> PenController (hand mode)
var _states: Dictionary = {}               # side -> PenState fed to it
var _gate: Dictionary = {}                 # side -> true while the current pinch belongs to the PenController
var _maybe_move: Dictionary = {}           # side -> {fn, p0, direct}: a pinch on empty canvas, not yet a drag or a tap
var _press_pt: Dictionary = {}             # side -> where the pinch began on its canvas (the first frame of the drag)
var _direct: Dictionary = {}               # side -> true while that pointer touches a canvas (with some hysteresis)
var _told := false                         # the first pick-up explains itself once
var _last_kind := {}
var _pen_ptr := HandInput.new("pen")       # the stylus as a pointer: its front button is the pinch, the nib the pinch point
var _pen_state: PenState                   # the stylus this frame (for haptics)
var _armed := false                        # the front button was pressed with the nib free: this press may grab
var _prev_front := false


func _init(b: Board) -> void:
	board = b


# ------------------------------------------------------------------------------------------------ geometry shared with HandCursor

## The four corners of a canvas in its own coordinates: bottom left, bottom right, top right, top left.
static func corner_points(fn: FrameNode) -> Array:
	var b := fn.bounds()
	return [b.position, Vector2(b.end.x, b.position.y), b.end, Vector2(b.position.x, b.end.y)]


## The middle of the grab bar under a canvas, in its own coordinates.
static func bar_center(fn: FrameNode) -> Vector2:
	var b := fn.bounds()
	return Vector2(b.get_center().x, b.position.y - BAR_DROP / fn.data.scale)


# ------------------------------------------------------------------------------------------------ pointing

## The canvas a ray lands on: {fn, local (frame coordinates), point (world), t}, or {}. The ray may land a little outside the extent.
func ray_target(o: Vector3, d: Vector3, slack: float = PLANE_SLACK) -> Dictionary:
	var best := {}
	var bt := INF
	for fn_any in board.visible_frames(FrameData.CANVAS):
		var fn := fn_any as FrameNode
		if fn.data.locked:
			continue
		var hit := fn.ray_hit(o, d, 0.05)
		if hit.is_empty() or float(hit.t) >= bt:
			continue
		var lp: Vector3 = hit.local
		if fn.bounds().grow(slack / fn.data.scale).has_point(Vector2(lp.x, lp.y)):
			bt = float(hit.t)
			best = {"fn": fn, "local": lp, "point": hit.point, "t": bt}
	return best


## What a pointer is on: {fn, local, point (world, on the canvas plane), t, direct}, or {}. Within DIRECT_NEAR of a canvas the pinch point
## itself touches it (`direct`); further away the ray decides. `at_press`: the ray the pinch clicked at (held while the fingers were
## closing) rather than the live one.
func target_of(h: HandInput, at_press: bool = false) -> Dictionary:
	var near := InputTuning.DIRECT_NEAR * (InputTuning.DIRECT_STAY if bool(_direct.get(h.side, false)) else 1.0)
	if not h.palm_up:
		var t := board.pen_target(h.pinch_point, near, PLANE_SLACK)
		if not t.is_empty():
			var fn := t.fn as FrameNode
			var l := t.local as Vector3
			l.z = 0.0
			return {"fn": fn, "local": l, "point": fn.to_world_point(l), "t": 0.0, "direct": true}
	if not h.aiming:
		return {}
	var r := ray_target(h.press_o, h.press_d) if at_press else ray_target(h.aim_o, h.aim_d)
	if not r.is_empty():
		r.direct = false
	return r


## Where a pointer is on the plane of one canvas (however far outside its extent): its pinch point when touching, else where its ray meets
## the plane. null when the ray runs parallel to the plane or points away.
func plane_hit(fn: FrameNode, h: HandInput, direct: bool) -> Variant:
	if direct:
		var l := fn.to_local_point(h.pinch_point)
		return fn.to_world_point(Vector3(l.x, l.y, 0.0))
	return plane_point(fn, h.aim_o, h.aim_d)


## Where a pointer is that moves a marker of a curved desk, a point in the world: the pinch point when touching, else where its ray meets the
## plane the marker slides in (the desk for the distance, the diagonal plane of the bend for the radius), whatever the bend is now.
func _marker_point(fn: FrameNode, h: HandInput, direct: bool, which: String) -> Variant:
	if direct:
		return h.pinch_point
	var inv := fn.global_transform.affine_inverse()
	var plane := Plane(Vector3(0, 0, 1), 0.0) if which == "d" else Plane(Vector3(0, 1, -1).normalized(), fn.bend.at / sqrt(2.0))
	var hit: Variant = plane.intersects_ray(inv * h.aim_o, inv.basis * h.aim_d)
	return null if hit == null else fn.global_transform * (hit as Vector3)


## Where a ray meets the plane of one canvas (anywhere on it, however far outside its extent), or null.
static func plane_point(fn: FrameNode, o: Vector3, d: Vector3) -> Variant:
	var hit := fn.ray_hit(o, d, 0.05)
	return null if hit.is_empty() else hit.point


## What is at a point of a canvas: {kind: "item" | "bar" | "corner" | "canvas", corner}. Items win over the bar and the corners. The pick
## radii follow the pointer's reach (touching or pointing), see _set_reach().
func classify(fn: FrameNode, l: Vector3, side: String) -> Dictionary:
	var s := fn.data.scale
	var p := Vector2(l.x, l.y)
	var pen := _pen(side)
	if fn.bend != null and pen.hit_marker(fn, p) != "":
		return {"kind": "item", "corner": -1}            # a marker of the curved desk: the stylus tip's controller moves it
	# (what has slid off the shown part of a curved desk is hidden, so it is not picked: it would cover the bar)
	if fn.bend == null or fn.bounds().has_point(p):
		if fn.data.id == board.sel_frame and not board.selection.is_empty() and not pen.hit_handle(fn, p).is_empty():
			return {"kind": "item", "corner": -1}
		if pen.hit_button(fn, p) != "":
			return {"kind": "item", "corner": -1}
		if board.doc.pick(fn.data.id, p, PenController.PICK_R * pen.reach / s) != null:
			return {"kind": "item", "corner": -1}
		if board.doc.shape_containing(fn.data.id, p) != null:
			return {"kind": "item", "corner": -1}
	var bc := bar_center(fn)
	if absf(p.x - bc.x) * s < BAR_HIT_W and absf(p.y - bc.y) * s < BAR_HIT_H:
		return {"kind": "bar", "corner": -1}
	var cs := corner_points(fn)
	for i in 4:
		if (cs[i] as Vector2).distance_to(p) * s < CORNER_HIT:
			return {"kind": "corner", "corner": i}
	return {"kind": "canvas", "corner": -1}


func _pen(side: String) -> PenController:
	if not _pens.has(side):
		var pc := PenController.new(board)
		pc.hand_mode = true
		pc.reach = REACH
		_pens[side] = pc
		var ps := PenState.new()
		ps.source = "hand"
		_states[side] = ps
	return _pens[side]


## A finger is not as fine as a nib, and a ray at arm's length is not as fine as a finger: the item pick radii grow accordingly.
func _set_reach(side: String, direct: bool) -> void:
	_pen(side).reach = InputTuning.DIRECT_REACH if direct else REACH


## The pointers' selection controllers (the board draws the selection by whichever of them is dragging).
func controllers() -> Array:
	return _pens.values()


## Another pointer that is carrying a canvas (not changing its size by a corner) and may be joined by `side`: the same canvas as `fn`, or
## any when `fn` is null. "" when there is none. A hand and the stylus's front button join each other like two hands.
func _partner(side: String, fn: FrameNode) -> String:
	for s in POINTERS:
		if s == side or not _holds.has(s):
			continue
		var hold: Dictionary = _holds[s]
		if int(hold.corner) < 0 and (fn == null or hold.fn == fn):
			return s
	return ""


## The stylus's front button is busy with a grab (or a drag of items): a stroke must not start under it.
func pen_busy() -> bool:
	if _holds.has("pen") or _maybe_move.has("pen"):
		return true
	return _pens.has("pen") and (_pens["pen"] as PenController).state != PenController.S.IDLE


# ------------------------------------------------------------------------------------------------ per frame

## hands: the HandInputs that are free to act; pen: the stylus (or the mouse), whose front button grabs like a pinch.
func update(hands: Array, dt: float, pen: PenState = null) -> void:
	var seen := {}
	for h in hands:
		seen[(h as HandInput).side] = h
	var sp := _feed_stylus(pen)
	if sp != null:
		seen["pen"] = sp
	hover = {}
	for side in POINTERS:
		var h: HandInput = seen.get(side)
		if h == null or not h.tracked:
			_lose(side, dt)
			continue
		_update_hand(h, dt)
	_update_two(seen)
	# one log line whenever what a pointer is on changes (adb logcat -s godot)
	for side in POINTERS:
		var kind: String = str((hover.get(side, {}) as Dictionary).get("kind", "-"))
		if kind != _last_kind.get(side, ""):
			_last_kind[side] = kind
			var hd: HandInput = seen.get(side)
			var how := ""
			if hd != null and bool((hover.get(side, {}) as Dictionary).get("direct", false)):
				how = " (touching)"
			elif hd != null:
				how = " (profile ray)" if hd.system_aim else " (joint ray)"
			print("[hand] %s on: %s%s" % [side, kind, how])


## The stylus as a pointer: the nib is its pinch point and its body the ray; the front button pinches. A press that begins while the nib
## is on the board (pen down, or a tool in the middle of something) is not a grab: the front button then belongs to the tool.
func _feed_stylus(pen: PenState) -> HandInput:
	_pen_state = pen
	var p := _pen_ptr
	p.pinch_down = false
	p.pinch_up = false
	var live := pen != null and pen.tracked and not pen.docked and (pen.source == "stylus" or pen.source == "mouse")
	if not live:
		_armed = false
		_prev_front = false
		p.tracked = false
		p.pinching = false
		return null
	p.tracked = true
	p.palm_up = false
	p.aiming = true
	p.system_aim = true
	p.tip = pen.tip
	p.pinch_point = pen.tip
	p.aim_o = pen.tip
	p.aim_d = pen.dir
	p.live_o = p.aim_o
	p.live_d = p.aim_d
	p.press_o = p.aim_o
	p.press_d = p.aim_d
	if pen.front and not _prev_front:
		_armed = not pen.down and board.pen_ctl.state == PenController.S.IDLE
	_prev_front = pen.front
	if not pen.front:
		_armed = false
	var now := pen.front and _armed
	p.pinch_down = now and not p.pinching
	p.pinch_up = p.pinching and not now
	p.pinching = now
	return p


func _update_hand(h: HandInput, dt: float) -> void:
	var side := h.side
	var pen := _pen(side)
	var ps: PenState = _states[side]
	if _holds.has(side):
		_step_hold(side, h)
		ps.tracked = false
		ps.down = false
		pen.update(ps, dt)
		return
	if _maybe_move.has(side):
		var mm: Dictionary = _maybe_move[side]
		if not h.pinching or not is_instance_valid(mm.fn):
			_maybe_move.erase(side)
			board.clear_selection()                      # a tap on empty canvas
		elif h.pinch_point.distance_to(mm.p0) > MOVE_START:
			_maybe_move.erase(side)
			_begin_hold(h, mm.fn, -1, bool(mm.direct), (mm.fn as FrameNode).bend != null, mm.ref)
			if _holds.has(side):
				(_holds[side] as Dictionary).p0 = mm.p0       # the canvas catches up with the hand from where the pinch began
				(_holds[side] as Dictionary).prev = mm.p0
		if _holds.has(side):
			_step_hold(side, h)
		else:
			var pp: Variant = plane_hit(mm.fn, h, bool(mm.direct))
			hover[side] = {"fn": mm.fn, "point": pp if pp != null else h.pinch_point, "kind": "canvas", "corner": -1, "direct": bool(mm.direct)}
		ps.tracked = false
		ps.down = false
		pen.update(ps, dt)
		return
	if h.pinch_down and pen.state == PenController.S.IDLE:
		_gate[side] = false
		_press(h)
		if _maybe_move.has(side) or _holds.has(side):
			if _holds.has(side):
				_step_hold(side, h)
			ps.tracked = false
			ps.down = false
			pen.update(ps, dt)
			return
	var busy := pen.state != PenController.S.IDLE
	var target := {}
	if busy:
		var wf: FrameNode = pen.working_frame()
		var pp2: Variant = null
		if wf != null:
			var mk := pen.marker_drag()
			pp2 = _marker_point(wf, h, bool(_direct.get(side, false)), mk) if mk != "" else plane_hit(wf, h, bool(_direct.get(side, false)))
		if pp2 != null:
			ps.tip = pp2
	else:
		target = target_of(h)
		_direct[side] = not target.is_empty() and bool(target.direct)
		if not target.is_empty():
			_set_reach(side, bool(target.direct))
			ps.tip = target.point
			var c := classify(target.fn as FrameNode, target.local as Vector3, side)
			hover[side] = {"fn": target.fn, "point": target.point, "kind": c.kind, "corner": c.corner, "direct": target.direct}
	if h.pinch_down and bool(_gate.get(side, false)) and _press_pt.has(side):
		ps.tip = _press_pt[side]
		target = {"point": ps.tip}
	ps.tracked = busy or not target.is_empty()
	ps.down = h.pinching and bool(_gate.get(side, false))
	ps.pressure = 0.7
	if not h.pinching:
		_gate[side] = false
	pen.update(ps, dt)
	if busy and pen.working_frame() != null:
		hover[side] = {"fn": pen.working_frame(), "point": ps.tip, "kind": "item", "corner": -1, "direct": bool(_direct.get(side, false))}


## A pointer that is no longer tracked lets go of everything.
func _lose(side: String, dt: float) -> void:
	_release(side)
	_maybe_move.erase(side)
	_gate[side] = false
	_direct[side] = false
	if _pens.has(side):
		var ps: PenState = _states[side]
		ps.tracked = false
		ps.down = false
		(_pens[side] as PenController).update(ps, dt)


## A pinch has just closed: decide who owns it.
func _press(h: HandInput) -> void:
	var side := h.side
	_pen(side).lasso_ok = false
	var t := target_of(h, true)
	if t.is_empty() and not h.aiming:
		print("[hand] %s pinch: not touching a canvas and not pointing (palm up, or turned away)" % side)
		return
	# the other hand is carrying a canvas: this pinch takes hold of it too (turn and resize with both hands), wherever this ray is,
	# unless it is on another canvas
	var other_hold: Dictionary = _holds.get(_partner(side, null), {})
	if not other_hold.is_empty() and (t.is_empty() or t.fn == other_hold.fn):
		print("[hand] %s pinch: second hand on the carried canvas: turn and resize" % side)
		_begin_hold(h, other_hold.fn, -1, false)
		return
	if t.is_empty():
		print("[hand] %s pinch: on no canvas (%d visible)" % [side, board.visible_frames(FrameData.CANVAS).size()])
		return
	var fn := t.fn as FrameNode
	var direct := bool(t.direct)
	_set_reach(side, direct)
	_direct[side] = direct
	var c := classify(fn, t.local as Vector3, side)
	var joins: bool = _partner(side, fn) != "" and KINDS_THAT_JOIN.has(str(c.kind))
	var how := "touching" if direct else "pointing"
	# on a curved desk one pointer slides the contents along the surface (from the spot it pinched, on the surface), the bar carries the desk
	var slide: bool = fn.bend != null and c.kind != "bar" and not joins
	var ref := fn.bend.to_surface(Vector2(t.local.x, t.local.y)) if fn.bend != null else Vector2.ZERO
	var first := _pinched_first(side, fn) if fn.bend != null and KINDS_THAT_JOIN.has(str(c.kind)) else ""
	if first != "":
		# the other pointer has just pinched the same curved desk and not moved yet: the two carry and turn the desk, nothing slides
		print("[hand] %s pinch on %s (%s): carrying the curved desk with both hands" % [side, c.kind, how])
		var mm: Dictionary = _maybe_move[first]
		_maybe_move.erase(first)
		_begin_hold(mm.h, fn, -1, bool(mm.direct))
		_begin_hold(h, fn, -1, direct)
	elif joins or grab_anywhere or c.kind == "bar":
		print("[hand] %s pinch on %s (%s): %s%s" % [side, c.kind, how, "sliding the contents" if slide else "carrying the canvas", " with both hands" if joins else ""])
		_begin_hold(h, fn, -1, direct, slide, ref)
	elif c.kind == "canvas" and not direct and str(App.val("tool")) == "select":
		# empty canvas pointed at with the Select tool chosen: a loop, drawn where the ray runs, selects what it goes round (the canvas is
		# carried by its bar, or with both hands)
		print("[hand] %s pinch on empty canvas (pointing, Select tool): drawing a loop" % side)
		_pen(side).lasso_ok = true
		_gate[side] = true
		_press_pt[side] = t.point
		_tick(side, 0.3, 0.02)
	elif c.kind == "corner":
		print("[hand] %s pinch on corner %d (%s): resizing the canvas" % [side, int(c.corner), how])
		_begin_hold(h, fn, int(c.corner), direct)
	elif c.kind == "canvas":
		# empty canvas: a drag carries the canvas, a tap lets go of the selection (decided by whether the hand moves)
		print("[hand] %s pinch on empty canvas (%s): drag to move it, or let go to deselect" % [side, how])
		_maybe_move[side] = {"fn": fn, "p0": h.pinch_point, "direct": direct, "h": h, "ref": ref}
	else:
		print("[hand] %s pinch on an item (%s): select / drag" % [side, how])
		_gate[side] = true
		_press_pt[side] = t.point
		_tick(side, 0.3, 0.02)


## `slide`: on a curved desk, slide its contents from `ref` (the surface spot the pointer pinched) rather than carry the desk.
func _begin_hold(h: HandInput, fn: FrameNode, corner: int, direct: bool, slide: bool = false, ref: Vector2 = Vector2.ZERO) -> void:
	if fn.data.locked:
		return
	if fn.bend != null and corner < 0:
		# the contents slide under one pointer only (two would pull them against each other): a second pointer on the desk carries and
		# turns the desk with the first, which stops sliding where it is
		for s in _holds:
			var other: Dictionary = _holds[s]
			if other.fn == fn and int(other.corner) < 0:
				slide = false
				if bool(other.get("slide", false)) and board.grabs.has(fn.data.id):
					other.slide = false
					other.p0 = other.get("last", other.p0)
					other.origin0 = ((board.grabs[fn.data.id] as Dictionary).xf as Transform3D).origin
	board.begin_grab(fn.data)
	if not board.grabs.has(fn.data.id):
		return
	var g: Dictionary = board.grabs[fn.data.id]
	# touching: the canvas follows the pinch point 1:1. Pointing: a canvas further away than the hand moves further than the hand (by
	# their distances from the head), so a far one can be pulled in with one movement
	var origin := (g.xf as Transform3D).origin
	var gain := 1.0 if direct else InputTuning.carry_gain(board.head.origin, origin, h.pinch_point)
	var hold := {"f": fn.data, "fn": fn, "p0": h.pinch_point, "origin0": origin, "corner": corner, "opp": Vector2.ZERO, "gain": gain, "direct": direct}
	if corner >= 0:
		var cs := corner_points(fn)
		hold.opp = cs[(corner + 2) % 4]
	if slide and fn.bend != null and corner < 0:
		hold.slide = true
		hold.pan0 = g.get("pan", fn.data.bend_pan)
		hold.ref = ref
		hold.held_s = ref.y                                # where the spot held is on the surface now (touching)
		hold.prev = h.pinch_point
	_holds[h.side] = hold
	_tick(h.side, 0.3, 0.02)
	if not _told:
		_told = true
		board.toast.emit("You picked up a canvas: it follows your hand (or the stylus's front button) until you let go, then stays there. Both hands turn and resize it. A corner changes its size.")


func _step_hold(side: String, h: HandInput) -> void:
	var hold: Dictionary = _holds[side]
	var fn: FrameNode = hold.fn
	if h.pinch_up or not h.pinching or not is_instance_valid(fn) or not board.grabs.has((hold.f as FrameData).id):
		_release(side)
		return
	hold.last = h.pinch_point
	var pt := h.pinch_point
	if int(hold.corner) >= 0:
		var pp: Variant = plane_hit(fn, h, bool(hold.direct)) if (bool(hold.direct) or h.aiming) else null
		if pp != null:
			pt = pp
			_resize(hold, pt)
	elif bool(hold.get("slide", false)):
		_slide(hold, fn, h)
	elif _two.is_empty() and fn.data.place_locked:
		# its place is locked: it is held all the same (a second hand resizes it), but it does not follow; one try is enough to say why
		if not hold.has("told") and h.pinch_point.distance_to(hold.p0 as Vector3) > InputTuning.MOVE_START * 2.5:
			hold.told = true
			board.place_locked(fn.data)
	elif _two.is_empty():
		var g: Dictionary = board.grabs[(hold.f as FrameData).id]
		var xf := g.xf as Transform3D
		xf.origin = (hold.origin0 as Vector3) + (h.pinch_point - (hold.p0 as Vector3)) * float(hold.get("gain", 1.0))
		g.xf = xf
	var kind := "corner" if int(hold.corner) >= 0 else "bar"
	hover[side] = {"fn": fn, "point": pt, "kind": "hold", "corner": int(hold.corner), "held": kind, "direct": bool(hold.direct)}


## The contents of a curved desk slide along its surface under one pointer (the desk itself stays put).
##  - Touching: each frame, by as far as the hand moved along the surface, plus as far as it moved into the surface (or back out of it) by
##    how far round the bend it is. "The surface" is the part under the hand while the hand is near it (BEND_SLIDE_NEAR), else the part
##    where the spot held is now. A hand traced along the surface keeps the page under it, round the bend too; on the desk lifting the
##    hand does nothing; on the wall pushing at it sends them up and pulling back brings them down; and a hand pushed on along the desk
##    keeps sending them round the bend and up the wall instead of stalling there. Step by step, so a hand that leaves the surface never
##    makes them jump.
##  - Pointing: the spot the ray pinched stays under the ray, on the desk, round the bend and up the wall.
func _slide(hold: Dictionary, fn: FrameNode, h: HandInput) -> void:
	var g: Dictionary = board.grabs[(hold.f as FrameData).id]
	var b := fn.bend
	if bool(hold.direct):
		var inv := fn.global_transform.affine_inverse()
		var d := inv.basis * (h.pinch_point - (hold.prev as Vector3))
		var under := b.node_to_surface(inv * (hold.prev as Vector3))
		hold.prev = h.pinch_point
		var s := float(hold.held_s)
		var gear := 1.0
		if absf(under.z) <= InputTuning.BEND_SLIDE_NEAR:
			s = under.y
			if s > b.at and s < b.wall_at():
				gear = clampf(b.radius / maxf(b.radius - under.z, 1e-4), 0.5, 2.0)   # (a hand off the bend goes round a smaller circle)
		var round_by := clampf((s - b.at) / b.radius, 0.0, PI * 0.5)
		var ds := d.dot(b.tangent_at(s)) * gear - d.dot(b.normal_at(s)) * sin(round_by)
		hold.held_s = float(hold.held_s) + ds
		g.pan = (g.pan as Vector2) + Vector2(d.x, ds)
	else:
		var inv := fn.global_transform.affine_inverse()
		var hit := b.ray(inv * h.aim_o, inv.basis * h.aim_d, 0.0)
		if not hit.is_empty():                             # (a ray that misses the surface leaves the contents where they are)
			var on := hit.surface as Vector3
			g.pan = (hold.pan0 as Vector2) + Vector2(on.x, on.y) - (hold.ref as Vector2)


## Corner drag: the dragged corner follows the pointer, the opposite corner stays where it is (the nominal rectangle changes; the frame origin does not).
func _resize(hold: Dictionary, world_p: Vector3) -> void:
	var fn: FrameNode = hold.fn
	if not is_instance_valid(fn):
		return
	var l := fn.to_local_point(world_p)
	var opp: Vector2 = hold.opp
	var p := Vector2(l.x, l.y)
	var minimum := InputTuning.MIN_CANVAS / fn.data.scale
	var size := Vector2(maxf(absf(p.x - opp.x), minimum.x), maxf(absf(p.y - opp.y), minimum.y))
	var sx := signf(p.x - opp.x) if absf(p.x - opp.x) > 1e-4 else 1.0
	var sy := signf(p.y - opp.y) if absf(p.y - opp.y) > 1e-4 else 1.0
	var far := opp + Vector2(sx * size.x, sy * size.y)
	fn.data.size = size
	fn.data.offset = (opp + far) * 0.5
	if fn.bend != null:
		fn.data.size *= fn.bend.zoom                       # (the shown part of a curved desk is kept in surface coordinates)
		fn.data.offset = fn.bend.to_surface(fn.data.offset)
		fn.refresh_bend()
	fn.invalidate_bounds()


func _release(side: String) -> void:
	if not _holds.has(side):
		return
	var hold: Dictionary = _holds[side]
	_holds.erase(side)
	if not _two.is_empty() and _two.f == hold.f:
		_two = {}
		# the other hand keeps holding the frame: re-base its single grab so it does not jump
		for s in _holds.keys():
			if (_holds[s] as Dictionary).f == hold.f and board.grabs.has(hold.f.id):
				(_holds[s] as Dictionary).origin0 = ((board.grabs[hold.f.id] as Dictionary).xf as Transform3D).origin
				(_holds[s] as Dictionary).p0 = (_holds[s] as Dictionary).get("last", (_holds[s] as Dictionary).p0)
	var still_held := false
	for s in _holds.keys():
		if (_holds[s] as Dictionary).f == hold.f:
			still_held = true
	if not still_held:
		board.end_grab(hold.f)
		_tick(side, 0.2, 0.015)


## The two pointers that turn and resize one canvas together: the pair already doing so while both still hold it, else the first two (of
## left, right, stylus) that carry the same canvas. [] when there are not two.
func _two_pair(seen: Dictionary) -> Array:
	var carrying: Dictionary = {}                      # frame id -> sides carrying it
	for s in POINTERS:
		var hold: Dictionary = _holds.get(s, {})
		if hold.is_empty() or int(hold.corner) >= 0 or not seen.has(s) or bool(hold.get("slide", false)):
			continue
		var id: String = (hold.f as FrameData).id
		if not carrying.has(id):
			carrying[id] = []
		(carrying[id] as Array).append(s)
	if not _two.is_empty():
		var kept: Array = _two.sides
		if (carrying.get((_two.f as FrameData).id, []) as Array).has(kept[0]) and (carrying[(_two.f as FrameData).id] as Array).has(kept[1]):
			return kept
	for id in carrying:
		if (carrying[id] as Array).size() >= 2:
			return [carrying[id][0], carrying[id][1]]
	return []


func _update_two(seen: Dictionary) -> void:
	var pair := _two_pair(seen)
	if pair.is_empty():
		if not _two.is_empty():
			_two = {}
			# one hand let go of the turn / resize: the other carries on from where the frame is now
			for s in _holds.keys():
				var hd: Dictionary = _holds[s]
				if board.grabs.has(hd.f.id):
					hd.origin0 = ((board.grabs[hd.f.id] as Dictionary).xf as Transform3D).origin
					hd.p0 = hd.get("last", hd.p0)
		return
	var f: FrameData = (_holds[pair[0]] as Dictionary).f
	if not board.grabs.has(f.id):
		return
	var a := (seen[pair[0]] as HandInput).pinch_point
	var b := (seen[pair[1]] as HandInput).pinch_point
	var g: Dictionary = board.grabs[f.id]
	if _two.is_empty():
		var d := a.distance_to(b)
		if d < InputTuning.TWO_HAND_MIN:
			return
		var v := b - a
		_two = {"f": f, "sides": pair, "d0": d, "mid0": (a + b) * 0.5, "yaw0": atan2(v.x, v.z), "scale0": float(g.scale), "basis0": (g.xf as Transform3D).basis, "origin0": (g.xf as Transform3D).origin}
		var fn0 := (_holds[pair[0]] as Dictionary).fn as FrameNode
		if fn0.bend != null:
			# a curved desk zooms its contents about the spot between the two pointers on its surface
			var sa := _surface_spot(fn0, seen[pair[0]], bool((_holds[pair[0]] as Dictionary).direct))
			var sb := _surface_spot(fn0, seen[pair[1]], bool((_holds[pair[1]] as Dictionary).direct))
			_two.merge({"spot0": (sa + sb) * 0.5, "pan0": g.get("pan", f.bend_pan)})
		_two.pivot = fn0.bounds().get_center()            # (a canvas whose place is locked is resized about its middle)
		return
	var mid := (a + b) * 0.5
	var v2 := b - a
	var spread := clampf(a.distance_to(b) / float(_two.d0), InputTuning.TWO_HAND_RATIO.x, InputTuning.TWO_HAND_RATIO.y)
	# (a curved desk turns and moves but keeps its size: its bend and wall are in real metres)
	var fixed := _two.has("spot0")
	var ratio := 1.0 if fixed else spread
	var dyaw := angle_difference(float(_two.yaw0), atan2(v2.x, v2.z))
	var rot := Basis(Vector3.UP, dyaw)
	var xf := g.xf as Transform3D
	if f.place_locked:
		# its place is locked: it neither turns nor moves, it only changes size (about its middle; a curved desk only zooms its contents)
		xf.basis = _two.basis0 as Basis
		xf.origin = _two.origin0 as Vector3
		if not fixed:
			var c := _two.pivot as Vector2
			var sc := clampf(float(_two.scale0) * ratio, InputTuning.CANVAS_SCALE.x, InputTuning.CANVAS_SCALE.y)
			xf.origin += xf.basis.orthonormalized() * (Vector3(c.x, c.y, 0.0) * (float(_two.scale0) - sc))
	else:
		xf.basis = rot * (_two.basis0 as Basis)
		xf.origin = mid + rot * (((_two.origin0 as Vector3) - (_two.mid0 as Vector3)) * ratio)
	g.xf = xf
	if fixed:
		# ...spreading the hands zooms its contents instead, about the spot between them, which stays where it is on the surface (the
		# desk turns and moves with the hands, so it stays between them too)
		var zoom := DeskBend.clamp_zoom(float(_two.scale0) * spread)
		var spot := _two.spot0 as Vector2
		g.scale = zoom
		g.pan = spot - (spot - (_two.pan0 as Vector2)) * (zoom / float(_two.scale0))
	else:
		g.scale = clampf(float(_two.scale0) * ratio, InputTuning.CANVAS_SCALE.x, InputTuning.CANVAS_SCALE.y)


## Where a pointer is on the surface of a curved desk (u, s): under the pinch point when touching, where the ray meets it when pointing.
func _surface_spot(fn: FrameNode, h: HandInput, direct: bool) -> Vector2:
	var inv := fn.global_transform.affine_inverse()
	if not direct:
		var hit := fn.bend.ray(inv * h.aim_o, inv.basis * h.aim_d, 0.0)
		if not hit.is_empty():
			return Vector2((hit.surface as Vector3).x, (hit.surface as Vector3).y)
	var on := fn.bend.node_to_surface(inv * h.pinch_point)
	return Vector2(on.x, on.y)


## Another pointer that has pinched empty canvas of `fn` and not moved yet (not a drag or a tap so far), or "".
func _pinched_first(side: String, fn: FrameNode) -> String:
	for s in _maybe_move:
		if s != side and (_maybe_move[s] as Dictionary).fn == fn:
			return s
	return ""


func is_holding() -> bool:
	return not _holds.is_empty()


## A haptic tick for the stylus's own grabs (a hand has none: the rig plays a sound for it).
func _tick(side: String, amplitude: float, seconds: float) -> void:
	if side == "pen" and _pen_state != null:
		_pen_state.tick(amplitude, seconds)
