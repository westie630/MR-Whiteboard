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

var _ctrls: Dictionary = {}                # side -> [XRController3D for "tip_pose", XRController3D for "tip"]
var _down := false
var _prev_active := ""
var _pose_name := ""


func _ready() -> void:
	# Godot names the pose of a pose action after the action; depending on the version the "_pose" suffix is kept or dropped, so
	# listen on both names and use whichever one reports tracking data. Buttons and forces are read from the tracker either way.
	for side in ["left", "right"]:
		var pair: Array = []
		for pose_name in [&"tip_pose", &"tip"]:
			var c := XRController3D.new()
			c.name = "Stylus_%s_%s" % [side, pose_name]
			c.tracker = StringName(side + "_hand")
			c.pose = pose_name
			add_child(c)
			pair.append(c)
		_ctrls[side] = pair


func _tracked_controller(side: String) -> XRController3D:
	for c in _ctrls[side]:
		if (c as XRController3D).get_has_tracking_data():
			return c
	return null


func update() -> void:
	var order := ["right", "left"]
	match str(App.val("stylus_hand")):
		"left":
			order = ["left"]
		"right":
			order = ["right"]
	var choice := ""
	for side in order:
		if _tracked_controller(side) != null:
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
	var c2: XRController3D = _tracked_controller(choice)
	active = choice
	if active != _prev_active or str(c2.pose) != _pose_name:
		_pose_name = str(c2.pose)
		print("[stylus] connected on the %s hand (pose '%s')" % [choice, _pose_name])
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
