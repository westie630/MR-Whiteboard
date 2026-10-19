class_name HandController
extends RefCounted
## What the bare hands do: pinch a canvas or 3D sketch to move it (the hand carries it), pinch it with both hands to turn and
## resize it, pinch a canvas corner to change its extent. Releasing fixes it in its new place: a new spatial anchor is made there.
## Drawing is the stylus's job; the hands only arrange.

var board: Board

var _holds: Dictionary = {}                # side -> {f: FrameData, p0: Vector3, origin0: Vector3, corner: int, opp: Vector2, fn: FrameNode}
var _two: Dictionary = {}                  # two-hand grab: {f, d0, mid0, yaw0, scale0, basis0, origin0}
var _prev_pinch := {"left": false, "right": false}


func _init(b: Board) -> void:
	board = b


func update(hands: Array, _dt: float) -> void:
	var seen := {}
	for h in hands:
		var hi := h as HandInput
		seen[hi.side] = hi
		_update_hand(hi)
	for side in _holds.keys():
		if not seen.has(side) or not (seen[side] as HandInput).tracked:
			_release(side)
	_update_two(seen)


func _update_hand(h: HandInput) -> void:
	var side := h.side
	if h.pinch_down and not _holds.has(side) and h.tracked:
		var p := board.pick_frame(h.pinch_point)
		if not p.is_empty():
			var fn := p.fn as FrameNode
			if not fn.data.locked:
				board.begin_grab(fn.data)
				if board.grabs.has(fn.data.id):
					var g: Dictionary = board.grabs[fn.data.id]
					var hold := {"f": fn.data, "fn": fn, "p0": h.pinch_point, "origin0": (g.xf as Transform3D).origin, "corner": int(p.corner), "opp": Vector2.ZERO}
					if int(p.corner) >= 0 and fn.is_canvas:
						var b := fn.bounds()
						var cs: Array = [b.position, Vector2(b.end.x, b.position.y), b.end, Vector2(b.position.x, b.position.y + b.size.y)]
						hold.opp = cs[(int(p.corner) + 2) % 4]
					_holds[side] = hold
	if _holds.has(side):
		(_holds[side] as Dictionary).last = h.pinch_point
		if h.pinch_up or not h.pinching:
			_release(side)
			return
		if _two.is_empty():
			_step_single(side, h)


func _step_single(side: String, h: HandInput) -> void:
	var hold: Dictionary = _holds[side]
	var f: FrameData = hold.f
	if not board.grabs.has(f.id):
		_holds.erase(side)
		return
	var g: Dictionary = board.grabs[f.id]
	if int(hold.corner) >= 0:
		_resize(hold, h.pinch_point)
		return
	var xf := g.xf as Transform3D
	xf.origin = (hold.origin0 as Vector3) + (h.pinch_point - (hold.p0 as Vector3))
	g.xf = xf


## Corner drag: the dragged corner follows the pinch, the opposite corner stays where it is (the nominal rectangle changes; the frame origin does not).
func _resize(hold: Dictionary, world_p: Vector3) -> void:
	var fn: FrameNode = hold.fn
	if not is_instance_valid(fn):
		return
	var l := fn.to_local_point(world_p)
	var opp: Vector2 = hold.opp
	var p := Vector2(l.x, l.y)
	var minimum := Vector2(0.25, 0.18) / fn.data.scale
	var size := Vector2(maxf(absf(p.x - opp.x), minimum.x), maxf(absf(p.y - opp.y), minimum.y))
	var sx := signf(p.x - opp.x) if absf(p.x - opp.x) > 1e-4 else 1.0
	var sy := signf(p.y - opp.y) if absf(p.y - opp.y) > 1e-4 else 1.0
	var far := opp + Vector2(sx * size.x, sy * size.y)
	fn.data.size = size
	fn.data.offset = (opp + far) * 0.5
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


func _update_two(seen: Dictionary) -> void:
	var l: Dictionary = _holds.get("left", {})
	var r: Dictionary = _holds.get("right", {})
	if l.is_empty() or r.is_empty() or l.f != r.f or not seen.has("left") or not seen.has("right"):
		if not _two.is_empty() and (l.is_empty() or r.is_empty()):
			_two = {}
		return
	var f: FrameData = l.f
	if not board.grabs.has(f.id):
		return
	var a := (seen["left"] as HandInput).pinch_point
	var b := (seen["right"] as HandInput).pinch_point
	var g: Dictionary = board.grabs[f.id]
	if _two.is_empty():
		var d := a.distance_to(b)
		if d < 0.04:
			return
		var v := b - a
		_two = {"f": f, "d0": d, "mid0": (a + b) * 0.5, "yaw0": atan2(v.x, v.z), "scale0": float(g.scale), "basis0": (g.xf as Transform3D).basis, "origin0": (g.xf as Transform3D).origin}
		return
	var mid := (a + b) * 0.5
	var v2 := b - a
	var ratio := clampf(a.distance_to(b) / float(_two.d0), 0.2, 6.0)
	var dyaw := angle_difference(float(_two.yaw0), atan2(v2.x, v2.z))
	var rot := Basis(Vector3.UP, dyaw)
	var xf := g.xf as Transform3D
	xf.basis = rot * (_two.basis0 as Basis)
	xf.origin = mid + rot * (((_two.origin0 as Vector3) - (_two.mid0 as Vector3)) * ratio)
	g.xf = xf
	g.scale = clampf(float(_two.scale0) * ratio, 0.15, 8.0)


func is_holding() -> bool:
	return not _holds.is_empty()
