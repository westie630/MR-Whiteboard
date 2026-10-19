extends Node
## The headset rig started on the PC, where there is no OpenXR session: no stylus, no hands, no anchors. It must start, build its menu,
## and run frames without a single script error (anything that would crash on the headset's first frame shows up here).

func _ready() -> void:
	var t := TestCase.new("xr_rig")
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_xr"
	App.reload()
	var board := Board.new()
	add_child(board)
	var rig := XrRig.new()
	add_child(rig)
	var xr := XRServer.find_interface("OpenXR")
	t.check(xr != null, "the OpenXR interface class exists")
	if xr == null:
		get_tree().quit(t.done())
		return
	var anchors: AnchorService = rig.start(board)
	t.check(anchors != null, "the rig returns an anchor service")
	board.setup(anchors)
	board.open(DocStore.create_new("XR rig smoke"))
	for i in 90:
		await get_tree().process_frame
	t.check(rig.menu != null and rig.panel != null, "the menu panel is built")
	t.check(not rig.stylus.pen.tracked, "no stylus is reported without a headset")
	# the rig placed the menu once the (fake) head is above the floor
	rig.camera.position = Vector3(0, 1.6, 0)
	for i in 30:
		await get_tree().process_frame
	t.check(rig.panel.visible, "the menu appears in front of the user")
	# the board runs with a pinch pen when there is no stylus: simulate the right hand pinching in the air
	var hand: HandInput = rig.hands["right"]
	hand.tracked = true
	hand.pinching = true
	hand.pinch_point = Vector3(0.0, 1.4, -0.5)
	for i in 20:
		await get_tree().process_frame
	t.check(true, "frames run with a simulated hand")
	DocStore.delete(board.doc.id)
	get_tree().quit(t.done())
