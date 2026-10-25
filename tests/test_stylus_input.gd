extends Node
## StylusInput's pointing ray, fed by a fake MX Ink tracker laid out the way a Quest 3 reports the real stylus: the aim pose's -Z is
## the nib pose's -Z (logged: 180 deg), and the grip pose's origin is 10 cm from the nib but 3 cm off the stylus's centre line, so the
## grip-to-nib line is 18 deg off the stylus (logged: (0, 0.31, -0.95) in the nib frame). The ray must follow the stylus, not that line,
## from the first frame on and after the nib has been sampled for the model, and twisting the stylus about its length must not swing it.

# the nib pose in the grip pose's frame: -Z along the stylus, +Y towards the buttons (the same in Logitech's model)
const NIB_BASIS := Basis(Vector3(1, 0, 0), Vector3(0, 0.5, -0.8660254), Vector3(0, 0.8660254, 0.5))
const GRIP_TO_NIB := Vector3(0.0, 0.310, -0.951)   # in the nib frame, unit length, as logged on the headset


func pose(tracker: XRPositionalTracker, world: Transform3D, with_aim: bool) -> void:
	var nib := Transform3D(NIB_BASIS, NIB_BASIS * GRIP_TO_NIB * 0.10)
	var tip := world * nib
	tracker.set_pose(&"stylus_grip", world, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	tracker.set_pose(&"tip_pose", tip, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	if with_aim:
		tracker.set_pose(&"stylus_aim", tip, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	else:
		tracker.invalidate_pose(&"stylus_aim")


func _ready() -> void:
	var t := TestCase.new("stylus_input")
	var tracker := XRServer.get_tracker(&"right_hand") as XRPositionalTracker
	var added := tracker == null
	if added:
		tracker = XRControllerTracker.new()
		tracker.name = &"right_hand"
		XRServer.add_tracker(tracker)
	var stylus := StylusInput.new()
	add_child(stylus)
	await get_tree().process_frame
	# held in front, tipped forward and to the side
	var grip := Transform3D(Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, -0.3), Vector3(0.2, 1.1, -0.35))
	var along := (grip.basis * NIB_BASIS * Vector3.FORWARD).normalized()   # the real stylus, out of the nib
	pose(tracker, grip, true)
	stylus.update()
	var pen := stylus.pen
	t.check(pen.tracked and stylus.active == "right", "the stylus is found on the right hand")
	t.near(pen.tip.distance_to(grip * (NIB_BASIS * GRIP_TO_NIB * 0.10)), 0.0, 1e-5, "the nib is the tip pose")
	t.near(rad_to_deg(pen.dir.angle_to(along)), 0.0, 0.05, "the ray runs along the stylus")
	var held := pen.tip - grip.origin
	t.check(rad_to_deg(held.angle_to(along)) > 15.0, "...which is not the grip-to-nib line (%.1f deg off it)" % rad_to_deg(held.angle_to(along)))
	# the nib is sampled for the model over NIB_SAMPLES frames: the ray must not change once that is done
	for i in StylusInput.NIB_SAMPLES + 15:
		stylus.update()
	t.near(rad_to_deg(pen.dir.angle_to(along)), 0.0, 0.05, "...and still does after the nib has been sampled")
	# Logitech's model, on the grip pose, agrees with the ray (this is the check the headset logs)
	var model := stylus.find_child("Model", true, false) as StylusModel
	if model != null and model.ready_model:
		t.near(rad_to_deg(pen.dir.angle_to(grip.basis * model.axis_local())), 0.0, 3.0, "the model's body lies along the ray")
	# twisting the stylus about its own length (about the nib) leaves the ray alone
	var twist := Transform3D(Basis(along, 1.1), Vector3.ZERO)
	var nib_world := pen.tip
	var twisted := Transform3D(Basis.IDENTITY, nib_world) * twist * Transform3D(Basis.IDENTITY, -nib_world) * grip
	pose(tracker, twisted, true)
	stylus.update()
	t.near(rad_to_deg(pen.dir.angle_to(along)), 0.0, 0.05, "twisting the stylus does not swing the ray")
	t.near(pen.tip.distance_to(nib_world), 0.0, 1e-5, "...nor move the nib")
	# a runtime without the aim pose: -Z of the nib pose, the same line
	pose(tracker, grip, false)
	stylus.update()
	t.near(rad_to_deg(pen.dir.angle_to(along)), 0.0, 0.05, "without the aim pose the nib pose's -Z is used, the same line")
	stylus.queue_free()
	if added:
		XRServer.remove_tracker(tracker)
	get_tree().quit(t.done())
