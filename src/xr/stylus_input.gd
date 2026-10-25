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
const NIB_SAMPLES := InputTuning.NIB_SAMPLES     # frames over which the nib is averaged in the grip pose's frame (aligns the model)

var pen := PenState.new()
var active := ""                           # "left" | "right" | "" (no stylus)
var tracked_ever := false

var _ctrls: Dictionary = {}                # side -> [XRController3D for "tip_pose", XRController3D for "tip"]
var _aims: Dictionary = {}                 # side -> XRController3D on the profile's aim pose (stylus_aim): the pointing ray
var _aim_noted := ""
var _grips: Dictionary = {}                # side -> XRController3D on the profile's grip pose (stylus_grip): where it is held
var _models: Dictionary = {}               # side -> StylusModel, the official MX Ink mesh on that side's grip pose
var _nib_grip_sum := Vector3.ZERO          # the nib in the grip pose's frame, summed over NIB_SAMPLES frames (aligns the model)
var _nib_n := 0
var _down := false
var _contact := false                      # the nib alone is pressed (with its own hysteresis)
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
		var model := StylusModel.new()
		model.name = "Model"
		model.visible = false
		grip.add_child(model)
		_models[side] = model


func _tracked_controller(side: String) -> XRController3D:
	for c in _ctrls[side]:
		if (c as XRController3D).get_has_tracking_data():
			return c
	return null


## The official model shows on the hand that holds the stylus, while its grip pose is tracked ("stylus_model" setting).
func _show_model(choice: String) -> void:
	var on := bool(App.val("stylus_model"))
	for side in _models:
		var m: StylusModel = _models[side]
		m.visible = on and side == choice and m.ready_model and (_grips[side] as XRController3D).get_has_tracking_data()


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
	_show_model(choice)
	if choice == "":
		active = ""
		pen.tracked = false
		pen.source = "none"
		pen.down = false
		pen.contact = false
		pen.front = false
		pen.back = false
		_down = false
		_contact = false
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
	# the pointing direction is along the stylus: -Z of the profile's aim pose (OpenXR's pointing ray), which on the MX Ink is -Z of the
	# nib pose too (a Quest 3 logs 180 deg between them), so twisting the stylus about its length cannot swing it. Not the line from the
	# grip pose to the nib: the grip pose sits about 3 cm off the stylus's centre line, on the side of the hand, so that line runs 18 deg
	# off the stylus (measured on a Quest 3, and the same in Logitech's model, which is authored for the grip pose).
	var aim: XRController3D = _aims[choice]
	var ray: XRController3D = aim if aim.get_has_tracking_data() else c2
	pen.dir = (-ray.global_transform.basis.z).normalized()
	var grip: XRController3D = _grips[choice]
	if _nib_n < NIB_SAMPLES and grip.get_has_tracking_data():
		_nib_grip_sum += grip.global_transform.affine_inverse() * c2.global_position
		_nib_n += 1
		if _nib_n == NIB_SAMPLES:
			var model: StylusModel = _models[choice]
			var nib_in_grip := _nib_grip_sum / float(NIB_SAMPLES)
			var moved := model.nib_local().distance_to(nib_in_grip)
			print("[stylus] MX Ink model: nib %.1f mm from the runtime's nib, %s" % [moved * 1000.0, "aligned" if model.align_nib(nib_in_grip) else "left as authored (too far apart)"])
			if model.ready_model:
				# the check that the ray runs along the real stylus: the model's body, turned with the grip pose (expect ~1 deg)
				var body := (grip.global_transform.basis.orthonormalized() * model.axis_local()).normalized()
				var held := c2.global_position - grip.global_position
				print("[stylus] pointing ray vs the stylus's body (model): %.1f deg; the grip-to-nib line vs it: %.1f deg" % [rad_to_deg(pen.dir.angle_to(body)), rad_to_deg(held.angle_to(body))])
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
	if _contact:
		_contact = tip > TIP_OFF
	else:
		_contact = tip > TIP_ON
	pen.contact = _contact
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
