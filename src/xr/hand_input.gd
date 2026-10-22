class_name HandInput
extends RefCounted
## One tracked hand reduced to what the interface needs, read the way the Godot documentation suggests: the OpenXR hand interaction
## profile through the action map (see openxr_action_map.tres, actions hand_aim / hand_poke / hand_pinch). The runtime supplies
##  - the pointing ray (its aim pose: the same ray the headset's own menus use),
##  - the pinch strength (0..1),
##  - the index fingertip (its poke pose), for touching the menu directly.
## The hand tracker's joints add the pinch point (between thumb and index) and the palm direction (palm up brings the menu), and stand
## in for the ray (along the index finger) and the pinch (fingertip distance) when the runtime does not report the profile.
##
## Pinch stabilisation (the hand moves while the fingers close, and the raw ray slides off what it was on):
##  - open: the ray is the live one;
##  - closing (strength past CLOSE_START): the ray stays where it was just before the fingers began to close;
##  - pinched (strength past PINCH_ON): a click at that held ray (pinch_down, press_o / press_d). While the pinch is held the ray
##    follows the hand *relative to* that point, so a drag starts exactly there instead of jumping;
##  - releasing (strength below PINCH_OFF): pinch_up, still on the relative ray (a button only clicks when it is let go on itself);
##    the live ray returns once the fingers are apart (below CLOSE_CANCEL).

enum Phase { OPEN, CLOSING, PINCHED, RELEASING }

const PINCH_ON := InputTuning.PINCH_ON     # pinch strength that counts as pinched...
const PINCH_OFF := InputTuning.PINCH_OFF   # ...and the lower one that releases it
const CLOSE_START := InputTuning.CLOSE_START   # the fingers are closing: hold the ray
const CLOSE_CANCEL := InputTuning.CLOSE_CANCEL # the fingers are apart again: the live ray
const RISE_STEP := InputTuning.RISE_STEP   # a strength change smaller than this between frames is noise, not the fingers closing
const JOINT_ON := InputTuning.JOINT_ON     # without the profile the strength comes from the thumb-tip to index-tip distance (m):
const JOINT_FAR := InputTuning.JOINT_FAR   # 1 at JOINT_ON, 0 at JOINT_FAR
const LOST_GRACE := InputTuning.LOST_GRACE # seconds a missing frame is bridged

var side := "right"
var tracked := false
var tip := Vector3.ZERO                    # index fingertip (poke pose, or the steadied joint)
var knuckle := Vector3.ZERO                # index knuckle (steadied)
var palm := Vector3.ZERO
var palm_up := false
var pinch_point := Vector3.ZERO            # between thumb and index tip
var pinch_strength := 0.0
var pinching := false
var pinch_down := false                    # true for the single frame the pinch closes
var pinch_up := false                      # ...and the frame it opens
var phase := Phase.OPEN
var aiming := false                        # the ray is pointing somewhere useful (forward, palm not up)
var system_aim := false                    # the ray comes from the runtime's aim pose (false: the index-finger fallback)
var aim_o := Vector3.ZERO                  # the ray to point with (stabilised, see above)
var aim_d := Vector3.FORWARD
var live_o := Vector3.ZERO                 # the raw ray this frame
var live_d := Vector3.FORWARD
var press_o := Vector3.ZERO                # the ray the pinch clicked at
var press_d := Vector3.FORWARD

var _f_tip := OneEuro3.new(2.5, 45.0)
var _f_knuckle := OneEuro3.new(1.0, 30.0)
var _f_palm := OneEuro3.new(1.5, 6.0)
var _lost := 0.0
var _now := 0.0
var _hist: Array = []                      # [{t, o, d, s}] newest last
var _hold_o := Vector3.ZERO                # the held ray while closing
var _hold_d := Vector3.FORWARD
var _rel_rot := Quaternion.IDENTITY        # pinched: live ray -> the ray relative to the press point
var _rel_off := Vector3.ZERO


func _init(s: String = "right") -> void:
	side = s
	_f_tip.d_cutoff = 8.0
	_f_knuckle.d_cutoff = 8.0


## data: {valid, tip, thumb, knuckle, palm, palm_normal} from the joints, plus from the action map when the runtime reports the hand
## interaction profile: {aim_valid, aim_o, aim_d, pinch_value, poke}.
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
		_f_palm.reset()
		_hist.clear()
		phase = Phase.OPEN
	var raw_tip: Vector3 = data.tip
	var raw_thumb: Vector3 = data.thumb
	var joint_tip := _f_tip.filter(raw_tip, dt)
	tip = data.poke if data.has("poke") else joint_tip
	knuckle = _f_knuckle.filter(data.knuckle, dt)
	palm = _f_palm.filter(data.palm, dt)
	palm_up = (data.palm_normal as Vector3).normalized().y > InputTuning.PALM_UP_Y
	pinch_point = (raw_tip + raw_thumb) * 0.5
	# the live ray
	var head_fwd := -head.basis.z
	if bool(data.get("aim_valid", false)):
		system_aim = true
		live_o = data.aim_o
		live_d = (data.aim_d as Vector3).normalized()
		aiming = live_d.dot(head_fwd) > InputTuning.AIM_DOT_PROFILE and not palm_up
	else:
		system_aim = false
		live_o = joint_tip
		live_d = (joint_tip - knuckle).normalized()
		aiming = live_d.dot(head_fwd) > InputTuning.AIM_DOT_JOINT and not palm_up
	# the strength
	if data.has("pinch_value"):
		pinch_strength = clampf(float(data.pinch_value), 0.0, 1.0)
	else:
		pinch_strength = clampf((JOINT_FAR - raw_tip.distance_to(raw_thumb)) / (JOINT_FAR - JOINT_ON), 0.0, 1.0)
	_hist.append({"t": _now, "o": live_o, "d": live_d, "s": pinch_strength})
	while _hist.size() > 2 and float(_hist[0].t) < _now - InputTuning.PINCH_HISTORY_S:
		_hist.pop_front()
	_step(pinch_strength)


func _step(s: float) -> void:
	match phase:
		Phase.OPEN:
			if s >= CLOSE_START:
				_begin_hold()
				phase = Phase.CLOSING
				if s >= PINCH_ON:
					_press()
		Phase.CLOSING:
			if s >= PINCH_ON:
				_press()
			elif s < CLOSE_CANCEL:
				phase = Phase.OPEN
		Phase.PINCHED:
			if s < PINCH_OFF:
				phase = Phase.RELEASING
				pinching = false
				pinch_up = true
		Phase.RELEASING:
			if s >= PINCH_ON:
				phase = Phase.PINCHED                  # closed again before opening fully: a new click at the same relative ray
				pinching = true
				pinch_down = true
				press_o = _rel_off + live_o
				press_d = _rel_rot * live_d
			elif s < CLOSE_CANCEL:
				phase = Phase.OPEN
	match phase:
		Phase.OPEN:
			aim_o = live_o
			aim_d = live_d
		Phase.CLOSING:
			aim_o = _hold_o
			aim_d = _hold_d
		_:
			aim_o = live_o + _rel_off
			aim_d = (_rel_rot * live_d).normalized()


## The ray from just before the fingers began to close: walk back while the strength keeps falling, to where its rise began.
func _begin_hold() -> void:
	var i := _hist.size() - 1
	while i > 0 and float(_hist[i - 1].s) < float(_hist[i].s) - RISE_STEP:
		i -= 1
	_hold_o = _hist[i].o
	_hold_d = _hist[i].d


func _press() -> void:
	phase = Phase.PINCHED
	pinching = true
	pinch_down = true
	press_o = _hold_o
	press_d = _hold_d
	_rel_rot = Quaternion(live_d, _hold_d) if live_d.angle_to(_hold_d) > 1e-4 else Quaternion.IDENTITY
	_rel_off = _hold_o - live_o


func _drop() -> void:
	if pinching:
		pinching = false
		pinch_up = true
	tracked = false
	aiming = false
	palm_up = false
	pinch_strength = 0.0
	phase = Phase.OPEN
