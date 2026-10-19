class_name StylusInput
extends Node3D
## The Logitech MX Ink stylus through OpenXR (XR_LOGITECH_mx_ink_stylus_interaction, exposed by Meta OS). Two XRController3D nodes,
## one per hand (the stylus reports for the hand chosen in the Quest's stylus settings), read the actions of openxr_action_map.tres:
##   tip_pose (pose of the nib), tip_force (pressure on the tip), middle_force (the pressure sensitive middle button),
##   front_click / back_click (buttons), dock (in its charging dock), haptic.
## The result is a PenState: nib position, pressure and the two buttons, with hysteresis so pen-down does not flicker.

const TIP_ON := 0.035
const TIP_OFF := 0.018
const MID_ON := 0.09
const MID_OFF := 0.05

var pen := PenState.new()
var active := ""                           # "left" | "right" | "" (no stylus)
var tracked_ever := false

var _ctrls: Dictionary = {}
var _down := false
var _prev_active := ""


func _ready() -> void:
	for side in ["left", "right"]:
		var c := XRController3D.new()
		c.name = "Stylus_" + side
		c.tracker = StringName(side + "_hand")
		c.pose = &"tip_pose"
		add_child(c)
		_ctrls[side] = c


func update() -> void:
	var order := ["right", "left"]
	match str(App.val("stylus_hand")):
		"left":
			order = ["left"]
		"right":
			order = ["right"]
	var choice := ""
	for side in order:
		var c: XRController3D = _ctrls[side]
		if c.get_has_tracking_data():
			choice = side
			break
	if choice == "":
		active = ""
		pen.tracked = false
		pen.source = "none"
		pen.down = false
		pen.front = false
		pen.back = false
		_down = false
		return
	var c2: XRController3D = _ctrls[choice]
	active = choice
	if active != _prev_active:
		print("[stylus] connected on the %s hand" % choice)
	_prev_active = active
	tracked_ever = true
	pen.source = "stylus"
	pen.tip = c2.global_position
	pen.dir = -c2.global_transform.basis.z
	var tip := c2.get_float(&"tip_force")
	var mid := c2.get_float(&"middle_force")
	pen.docked = c2.is_button_pressed(&"dock")
	pen.tracked = not pen.docked
	if _down:
		_down = tip > TIP_OFF or mid > MID_OFF
	else:
		_down = tip > TIP_ON or mid > MID_ON
	pen.down = _down
	pen.pressure = pow(clampf(maxf(tip, mid), 0.0, 1.0), 0.75) if _down else 0.0
	pen.front = c2.is_button_pressed(&"front_click")
	pen.back = c2.is_button_pressed(&"back_click")
	pen.haptic = func(amplitude: float, seconds: float):
		c2.trigger_haptic_pulse(&"haptic", 0.0, clampf(amplitude, 0.0, 1.0), seconds, 0.0)
