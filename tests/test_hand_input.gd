extends Node
## HandInput's pinch stabilisation: the hand drifts while the fingers close, yet the click lands where it pointed before they began
## to close; a held pinch moves relative to that point (no jump); the release happens there too; the live ray returns afterwards.

var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))


func frame(h: HandInput, dir: Vector3, strength: float) -> void:
	h.feed(1.0 / 72.0, head, {
		"valid": true, "tip": Vector3(0.2, 1.3, -0.4), "thumb": Vector3(0.21, 1.29, -0.4), "knuckle": Vector3(0.2, 1.3, -0.33),
		"palm": Vector3(0.2, 1.28, -0.33), "palm_normal": Vector3(0, -1, 0),
		"aim_valid": true, "aim_o": Vector3(0.2, 1.3, -0.35), "aim_d": dir, "pinch_value": strength})


## The hand's orientation (a grab turns what it holds by it): from the joints, steadied while still, following a fast turn.
func _grip(t: TestCase) -> void:
	var h := HandInput.new("right")
	t.check(not h.has_grip, "no orientation before the joints give one")
	var feed := func(turn: Basis) -> void:
		h.feed(1.0 / 72.0, head, {"valid": true, "tip": Vector3(0.2, 1.3, -0.4), "thumb": Vector3(0.18, 1.29, -0.38), "knuckle": Vector3(0.2, 1.3, -0.36),
			"palm": Vector3(0.2, 1.28, -0.33), "palm_normal": turn * Vector3(0, -1, 0), "hand_fwd": turn * Vector3(0, 0, -0.08)})
	feed.call(Basis.IDENTITY)
	t.check(h.has_grip, "the joints give the hand's orientation")
	var b0 := h.grip
	var turned := Basis(Vector3.UP, deg_to_rad(40.0))
	for i in 72:
		feed.call(turned)
	t.near(rad_to_deg((h.grip * b0.inverse()).get_rotation_quaternion().get_angle()), 40.0, 1.0, "a hand turned 40 degrees turns its grip 40 degrees")
	var still := h.grip
	var jitter := Basis(Vector3.RIGHT, deg_to_rad(1.0))
	feed.call(jitter * turned)
	t.check(rad_to_deg((h.grip * still.inverse()).get_rotation_quaternion().get_angle()) < 0.5, "a one-degree twitch of a still hand is mostly smoothed away")


func _ready() -> void:
	var t := TestCase.new("hand_input")
	var h := HandInput.new("right")
	var target := Vector3(0, 0, -1)
	for i in 10:
		frame(h, target, 0.0)
	t.check(h.tracked and h.system_aim and h.aiming, "the profile's ray is used")
	t.near(h.aim_d.angle_to(target), 0.0, 1e-4, "open hand: the live ray")
	# the fingers close over 8 frames while the hand drifts 12 degrees down
	var down := Basis(Vector3.RIGHT, deg_to_rad(-12.0))
	var clicked := false
	for i in 8:
		var k := float(i + 1) / 8.0
		var d := Basis(Vector3.RIGHT, deg_to_rad(-12.0 * k)) * target
		frame(h, d, k)
		if h.pinch_down:
			clicked = true
			t.near(h.press_d.angle_to(target), 0.0, 1e-3, "the click is at the ray from before the fingers closed")
		if h.phase == HandInput.Phase.CLOSING:
			t.near(h.aim_d.angle_to(target), 0.0, 1e-3, "while closing the ray stays on its target")
	t.check(clicked and h.pinching, "the pinch closed")
	t.near(h.aim_d.angle_to(target), 0.0, 1e-3, "at the click the ray is on the target, not where the hand drifted")
	# a drag: the hand turns 10 degrees right from where it was at the click; the ray turns with it from the target
	var drifted := down * target
	var turned := Basis(Vector3.UP, deg_to_rad(-10.0)) * drifted
	frame(h, turned, 1.0)
	t.near(rad_to_deg(h.aim_d.angle_to(target)), 10.0, 0.5, "a held pinch moves the ray relative to the click point")
	# release: still on the relative ray, then the live ray once the fingers are apart
	frame(h, turned, 0.5)
	t.check(h.pinch_up and not h.pinching, "the pinch opened")
	t.near(rad_to_deg(h.aim_d.angle_to(target)), 10.0, 0.5, "the release happens on the same relative ray")
	frame(h, turned, 0.05)
	t.eq(h.phase, HandInput.Phase.OPEN, "fingers apart: open again")
	t.near(h.aim_d.angle_to(turned), 0.0, 1e-4, "...with the live ray")
	# a hesitation: the fingers half close and open again without pinching
	frame(h, target, 0.0)
	frame(h, target, 0.4)
	t.eq(h.phase, HandInput.Phase.CLOSING, "half closed: the ray is held")
	frame(h, target, 0.1)
	t.eq(h.phase, HandInput.Phase.OPEN, "opened again without a click")
	t.check(not h.pinching, "no click")
	# the numbers that decide how a pinch feels live in InputTuning, pinned here so a tuning pass is a deliberate act
	t.eq(InputTuning.PINCH_ON, 0.9, "a pinch is recognised at 0.9")
	t.eq(InputTuning.PINCH_OFF, 0.6, "...and released at 0.6")
	t.eq(InputTuning.CLOSE_START, 0.35, "the ray is held from 0.35")
	t.eq(InputTuning.CLOSE_CANCEL, 0.2, "...until the fingers are back under 0.2")
	t.eq(HandInput.PINCH_ON, InputTuning.PINCH_ON, "HandInput takes its thresholds from InputTuning")
	t.eq(StylusInput.TIP_ON, InputTuning.TIP_ON, "StylusInput takes its thresholds from InputTuning")
	t.eq(Board.CAPTURE, InputTuning.CAPTURE, "the board takes the capture distance from InputTuning")
	t.check(InputTuning.DIRECT_NEAR <= InputTuning.CAPTURE, "touching a canvas is never looser than drawing on it")
	t.near(InputTuning.carry_gain(Vector3(0, 1.6, 0), Vector3(0, 1.6, -3.0), Vector3(0, 1.6, -0.5)), 6.0, 1e-6, "carrying gain is capped at MAX_GAIN")
	t.near(InputTuning.carry_gain(Vector3(0, 1.6, 0), Vector3(0, 1.6, -0.4), Vector3(0, 1.6, -0.5)), 1.0, 1e-6, "...and never below 1")
	_grip(t)
	get_tree().quit(t.done())
