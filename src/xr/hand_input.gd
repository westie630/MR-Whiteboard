class_name HandInput
extends RefCounted
## One tracked hand reduced to what the interface needs: steadied fingertip positions, a pointing ray that
## does not jump when you pinch, and a pinch with hysteresis. Fed once per frame with world-space joint
## positions (from OpenXR hand tracking on the headset, or synthetic data in tests).
##
## The pointing ray runs from an estimated shoulder through the centre of the PALM. The palm hardly moves
## while thumb and finger close (the index knuckle and fingertip do), so a pinch does not drag the cursor off its
## target the way a ray through the finger, the pinch point or a wrist-based aim pose does. The fingertip is used only
## for touching a panel directly. On top of that the ray from the moment the pinch *began* is remembered, so a
## click lands where you were pointing, not where the hand drifted to.
##
## The moment the fingers start to close (`closing`) the aim is frozen: `aim_o` / `aim_d` stay on the ray from just before they
## moved, so whatever the pointer line was on stays hovered through the pinch. The freeze ends when the pinch completes (the press
## uses that same ray) or is reversed (the fingers open again).

const PINCH_ON := 0.022            # thumb-tip to index-tip distance (m) that counts as pinched
const PINCH_OFF := 0.038           # ...and the larger distance that releases it (hysteresis)
const PINCH_FAR := 0.065           # distance at which the pinch strength is zero
const LOST_GRACE := 0.15           # seconds a missing frame is bridged
const HISTORY := 0.5
const CLOSE_RISE := 0.15           # the fingers are closing when the pinch strength rose this much within CLOSE_WINDOW...
const CLOSE_WINDOW := 0.15
const CLOSE_MIN := 0.15            # ...and has reached this (a thumb resting near the finger never counts)
const CLOSE_REVERSE := 0.12        # closing is reversed when the strength falls this far below its peak since the freeze (or to ~zero)
const CLOSE_MAX := 1.5             # seconds a half-closed pinch is held before the aim is let go again (a thumb that just rests there)

var side := "right"
var tracked := false
var tip := Vector3.ZERO            # index fingertip (steadied)
var thumb_tip := Vector3.ZERO
var knuckle := Vector3.ZERO        # index knuckle (steadied)
var aim_point := Vector3.ZERO      # palm centre as used for the pointing ray (steadied for aiming)
var palm := Vector3.ZERO
var palm_normal := Vector3.DOWN    # out of the palm
var palm_speed := 0.0              # m/s
var pinch_point := Vector3.ZERO
var pinch_dist := 1.0
var pinch_strength := 0.0
var pinching := false
var pinch_down := false            # true for the single frame the pinch closes
var pinch_up := false              # ...and the frame it opens
var aiming := false                # hand raised and pointing forward: the ray may be used
var ray_o := Vector3.ZERO
var ray_d := Vector3.FORWARD
var press_o := Vector3.ZERO        # ray at the moment the pinch began (latency-compensated)
var press_d := Vector3.FORWARD
var closing := false               # the fingers have started to close and have neither met nor opened again: the aim is frozen
var aim_o := Vector3.ZERO          # the ray to point with: the live one (ray_o / ray_d), or the frozen one while `closing`
var aim_d := Vector3.FORWARD
var palm_down := false
var palm_up := false

# One-euro filters. The palm drives the pointer: the ring sits ~2.3x further from the hand than the palm is from
# the shoulder, so any lag in the palm shows up multiplied at the ring (a simulation of the old 0.9 Hz / beta 8 /
# 1 Hz derivative setting gave up to 8 cm of ring lag during a quick sweep). A faster derivative filter and a stronger
# speed term cut that to under 3 cm while keeping rest jitter at the ring around 2-3 mm.
var _f_tip := OneEuro3.new(2.5, 45.0)
var _f_knuckle := OneEuro3.new(1.0, 30.0)
var _f_aim := OneEuro3.new(1.0, 30.0)
var _f_palm := OneEuro3.new(1.5, 6.0)
var _lost := 0.0
var _close_frames := 0
var _now := 0.0
var _hist: Array = []              # [{t, o, d, s}] newest last
var _close_o := Vector3.ZERO       # the frozen aim
var _close_d := Vector3.FORWARD
var _close_t := 0.0                # when the freeze began
var _close_peak := 0.0             # the highest pinch strength since then
var _close_blocked := false        # a freeze that timed out: no new one until the fingers have opened again
var _prev_palm := Vector3.ZERO
var _have_prev := false


func _init(s: String = "right") -> void:
	side = s
	_f_tip.d_cutoff = 8.0
	_f_knuckle.d_cutoff = 8.0
	_f_aim.d_cutoff = 8.0


func feed(dt: float, head: Transform3D, data: Dictionary) -> void:
	_now += dt
	pinch_down = false
	pinch_up = false
	if not bool(data.get("valid", false)):
		_lost += dt
		if _lost > LOST_GRACE and tracked:
			_drop()
		return
	_lost = 0.0
	if not tracked:
		tracked = true
		_f_tip.reset()
		_f_knuckle.reset()
		_f_aim.reset()
		_f_palm.reset()
		_hist.clear()
		_have_prev = false
		_close_frames = 0
		closing = false
		_close_blocked = false
	var raw_tip: Vector3 = data.tip
	var raw_thumb: Vector3 = data.thumb
	tip = _f_tip.filter(raw_tip, dt)
	thumb_tip = raw_thumb
	knuckle = _f_knuckle.filter(data.knuckle, dt)
	palm = _f_palm.filter(data.palm, dt)
	aim_point = _f_aim.filter(data.palm, dt)
	palm_normal = (data.palm_normal as Vector3).normalized()
	palm_down = palm_normal.y < -0.6
	palm_up = palm_normal.y > 0.6
	if _have_prev and dt > 0.0:
		palm_speed = lerpf(palm_speed, palm.distance_to(_prev_palm) / dt, 0.3)
	_prev_palm = palm
	_have_prev = true
	# pinch (raw distance: no filter lag), with hysteresis and a two-frame debounce on closing
	pinch_dist = raw_tip.distance_to(raw_thumb)
	pinch_point = (raw_tip + raw_thumb) * 0.5
	pinch_strength = clampf((PINCH_FAR - pinch_dist) / (PINCH_FAR - PINCH_ON * 0.75), 0.0, 1.0)
	_update_ray(head)
	_hist.append({"t": _now, "o": ray_o, "d": ray_d, "s": pinch_strength})
	while _hist.size() > 2 and float(_hist[0].t) < _now - HISTORY:
		_hist.pop_front()
	_update_closing()
	if pinching:
		if pinch_dist > PINCH_OFF:
			pinching = false
			pinch_up = true
			_close_frames = 0
	else:
		if pinch_dist < PINCH_ON:
			_close_frames += 1
			if _close_frames >= 2:
				pinching = true
				pinch_down = true
				_capture_press_ray()
				closing = false
				aim_o = ray_o
				aim_d = ray_d
		else:
			_close_frames = 0


func _update_ray(head: Transform3D) -> void:
	var fwd := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z)
	if fwd.length() < 0.05:
		fwd = Vector3(-head.basis.y.x, 0.0, -head.basis.y.z)
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP)
	var sgn := 1.0 if side == "right" else -1.0
	var shoulder := head.origin + right * (0.17 * sgn) + Vector3(0.0, -0.2, 0.0) - fwd * 0.04
	ray_o = aim_point
	ray_d = (aim_point - shoulder).normalized()
	var head_fwd := -head.basis.z
	aiming = aim_point.y > head.origin.y - 0.7 and ray_d.dot(head_fwd) > 0.15 and not palm_up \
		and aim_point.distance_to(head.origin) > 0.14


## Notice the start of a pinch and hold the aim where it was: a hand that begins to close drifts a little, and the pointer line
## must not fall off the control it was on. Ends when the fingers meet (feed() takes it from here), open again, or the hand stops pointing.
func _update_closing() -> void:
	if pinching or not aiming:
		closing = false
		_close_blocked = false
	elif closing:
		_close_peak = maxf(_close_peak, pinch_strength)
		if pinch_strength < 0.03 or pinch_strength < _close_peak - CLOSE_REVERSE:
			closing = false                                          # reversed: the fingers opened again
		elif _now - _close_t > CLOSE_MAX:
			closing = false
			_close_blocked = true
	elif pinch_strength < 0.03:
		_close_blocked = false
	elif pinch_strength >= CLOSE_MIN and not _close_blocked:
		# the fingers are closing when the strength has risen fast enough within the last moment: the ray to hold is the one from
		# where that rise began
		var lowest := pinch_strength
		var from := -1
		for i in range(_hist.size() - 1, -1, -1):
			var h: Dictionary = _hist[i]
			if float(h.t) < _now - CLOSE_WINDOW:
				break
			if float(h.s) < lowest:
				lowest = float(h.s)
				from = i
		if from >= 0 and pinch_strength - lowest >= CLOSE_RISE:
			closing = true
			_close_t = _now
			_close_peak = pinch_strength
			_close_o = _hist[from].o
			_close_d = _hist[from].d
	aim_o = _close_o if closing else ray_o
	aim_d = _close_d if closing else ray_d


## The ray from just before the fingers started closing (strength still low), so the click goes where the
## hand was pointing and not where it moved while pinching.
func _capture_press_ray() -> void:
	if closing:
		press_o = _close_o
		press_d = _close_d
		return
	press_o = ray_o
	press_d = ray_d
	for i in range(_hist.size() - 1, -1, -1):
		var h: Dictionary = _hist[i]
		press_o = h.o
		press_d = h.d
		if float(h.s) < 0.3:
			break


func _drop() -> void:
	if pinching:
		pinching = false
		pinch_up = true
	tracked = false
	closing = false
	aiming = false
	palm_down = false
	palm_up = false
	palm_speed = 0.0
	pinch_strength = 0.0
