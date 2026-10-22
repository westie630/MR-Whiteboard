class_name StylusInput
extends Node3D
## The Logitech MX Ink stylus through OpenXR (XR_LOGITECH_mx_ink_stylus_interaction, exposed by Meta OS). Two XRController3D nodes,
## one per hand (the stylus reports for the hand chosen in the Quest's stylus settings), read the actions of openxr_action_map.tres:
##   tip_pose (pose of the nib), tip_force (pressure on the tip), middle_force (the pressure sensitive middle button),
##   front_click / back_click (buttons), dock (in its charging dock), haptic.
## The result is a PenState: nib position, pressure and the two buttons, with hysteresis so pen-down does not flicker.

const TIP_ON := InputTuning.TIP_ON
const TIP_OFF := InputTuning.TIP_OFF
const MID_ON := InputTuning.MID_ON
const MID_OFF := InputTuning.MID_OFF
const AXIS_SAMPLES := InputTuning.AXIS_SAMPLES   # frames over which the stylus axis (grip -> nib) is learnt

var pen := PenState.new()
var active := ""                           # "left" | "right" | "" (no stylus)
var tracked_ever := false

var _ctrls: Dictionary = {}                # side -> [XRController3D for "tip_pose", XRController3D for "tip"]
var _aims: Dictionary = {}                 # side -> XRController3D on the profile's aim pose (stylus_aim): the pointing ray
var _aim_noted := ""
var _grips: Dictionary = {}                # side -> XRController3D on the profile's grip pose (stylus_grip): where it is held
var _axis_local := Vector3.ZERO            # the stylus's length, pointing out of the nib, in the nib pose's frame (learnt from grip -> nib)
var _axis_sum := Vector3.ZERO
var _axis_n := 0
var _down := false
var _prev_active := ""
var _pose_name := ""
var _last_key := ""


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
		var aim := XRController3D.new()
		aim.name = "Stylus_%s_aim" % side
		aim.tracker = StringName(side + "_hand")
		aim.pose = &"stylus_aim"
		add_child(aim)
		_aims[side] = aim
		var grip := XRController3D.new()
		grip.name = "Stylus_%s_grip" % side
		grip.tracker = StringName(side + "_hand")
		grip.pose = &"stylus_grip"
		add_child(grip)
		_grips[side] = grip


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
	# the pointing direction: the profile's aim pose (OpenXR defines it as the pointing ray, along -Z); the nib pose's own axes are
	# not along the stylus. Without the aim pose, -Z of the nib pose.
	# the pointing direction is along the stylus: the line from where it is held (grip pose) to the nib, learnt once in the nib's own
	# frame so it does not jitter, then turned with the nib. Twisting the stylus about its length then cannot swing the pointer.
	var grip: XRController3D = _grips[choice]
	if _axis_n < AXIS_SAMPLES and grip.get_has_tracking_data():
		var v := c2.global_position - grip.global_position
		if v.length() > 0.02:
			_axis_sum += c2.global_transform.basis.orthonormalized().inverse() * v.normalized()
			_axis_n += 1
			if _axis_n == AXIS_SAMPLES:
				_axis_local = _axis_sum.normalized()
				print("[stylus] axis learnt: %s in the nib frame (grip to nib %.1f cm)" % [str(_axis_local), v.length() * 100.0])
	var aim: XRController3D = _aims[choice]
	if _axis_local != Vector3.ZERO:
		pen.dir = (c2.global_transform.basis.orthonormalized() * _axis_local).normalized()
	else:
		pen.dir = -aim.global_transform.basis.z if aim.get_has_tracking_data() else -c2.global_transform.basis.z
	var source := choice + (":aim" if aim.get_has_tracking_data() else ":nib")
	if _aim_noted != source:
		_aim_noted = source
		if aim.get_has_tracking_data():
			var d := -aim.global_transform.basis.z
			var b := c2.global_transform.basis
			print("[stylus] pointing with the aim pose; the nib pose axes vs it: x %.0f, y %.0f, z %.0f deg" % [rad_to_deg(d.angle_to(b.x)), rad_to_deg(d.angle_to(b.y)), rad_to_deg(d.angle_to(b.z))])
		else:
			print("[stylus] no aim pose: pointing along -Z of the nib pose")
	var tip := c2.get_float(&"tip_force")
	var mid := c2.get_float(&"middle_force")
	pen.docked = c2.is_button_pressed(&"dock")
	pen.tracked = not pen.docked
	if _down:
		_down = tip > TIP_OFF or mid > MID_OFF
	else:
		_down = tip > TIP_ON or mid > MID_ON
	pen.down = _down
	pen.pressure = pow(clampf(maxf(tip, mid), 0.0, 1.0), InputTuning.PRESSURE_EXP) if _down else 0.0
	pen.front = c2.is_button_pressed(&"front_click")
	pen.back = c2.is_button_pressed(&"back_click")
	# one log line per change, so a headset session shows exactly what the stylus reported (adb logcat -s godot)
	var state := "tip=%.2f mid=%.2f down=%s front=%s back=%s docked=%s" % [tip, mid, str(pen.down), str(pen.front), str(pen.back), str(pen.docked)]
	var key := "%s|%s|%s|%s" % [str(pen.down), str(pen.front), str(pen.back), str(pen.docked)]
	if key != _last_key:
		_last_key = key
		print("[stylus] ", state)
	pen.haptic = func(amplitude: float, seconds: float):
		c2.trigger_haptic_pulse(&"haptic", 0.0, clampf(amplitude, 0.0, 1.0), seconds, 0.0)
