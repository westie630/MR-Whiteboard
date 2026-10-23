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
	t.check(rig.ui != null and rig.panel != null and rig.panels.size() == rig.ui.panels.size(), "every surface of the interface has its panel")
	t.check(not rig.stylus.pen.tracked, "no stylus is reported without a headset")
	# the rig placed the menu once the (fake) head is above the floor
	rig.camera.position = Vector3(0, 1.6, 0)
	for i in 30:
		await get_tree().process_frame
	t.check(rig.panel.visible, "the dock appears in front of the user")
	t.check(rig.panel.global_position.y < rig.camera.global_position.y - 0.15, "...low, out of the way of the view")
	t.check(not (rig.panels["home"] as XrPanel).visible and not (rig.panels["popover"] as XrPanel).visible, "...and nothing else shows yet")
	# the board runs with a pinch pen when there is no stylus: simulate the right hand pinching in the air
	var hand: HandInput = rig.hands["right"]
	hand.tracked = true
	hand.pinching = true
	hand.pinch_point = Vector3(0.0, 1.4, -0.5)
	for i in 20:
		await get_tree().process_frame
	t.check(true, "frames run with a simulated hand")
	# the hand cursor: a ring where the ray lands, a beam from the hand, and the bar and corners of the canvas under it
	var cv := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.4, -1.0)))
	for i in 10:
		await get_tree().process_frame
	hand.tracked = true
	hand.system_aim = true
	hand.aim_o = Vector3(0.1, 1.3, -0.3)
	var fnode: FrameNode = board.frame_nodes[cv.id]
	var hv := {"right": {"fn": fnode, "point": Vector3(0.0, 0.8, -1.0), "kind": "bar", "corner": -1}}
	rig.cursor.update(rig.hands, {}, hv, Vector3(0, 1.6, 0), "")
	var side: Dictionary = rig.cursor._sides["right"]
	t.check((side.ring as MeshInstance3D).visible, "a hand on a canvas shows its ring")
	t.check((side.bar as MeshInstance3D).visible and (side.corners[0] as MeshInstance3D).visible, "...and the bar and the corners of that canvas")
	rig.cursor.update(rig.hands, {"right": {"point": Vector3(0, 1.4, -0.6), "poke": false}}, hv, Vector3(0, 1.6, 0), "")
	t.check((side.ring as MeshInstance3D).visible and not (side.bar as MeshInstance3D).visible, "a hand on the menu shows its ring but no canvas bar")
	rig.cursor.update(rig.hands, {}, {}, Vector3(0, 1.6, 0), "")
	t.check(not (side.ring as MeshInstance3D).visible and not (side.bar as MeshInstance3D).visible, "a hand on nothing shows nothing")
	for c in rig.cursor.get_children():
		t.check(not (c is MeshInstance3D and (c.mesh is BoxMesh)), "no line mesh exists")
	hand.tracked = false
	await get_tree().process_frame
	# a spare canvas for the menu rules to move about (hidden until a rule needs it)
	var spare := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.4, 3.0)))
	for i in 10:
		await get_tree().process_frame
	var spare_node: FrameNode = board.frame_nodes[spare.id]
	spare_node.visible = false
	_menu_rules(t, rig, board, cv, spare_node)
	await _panel_rules(t, rig, board, cv)
	DocStore.delete(board.doc.id)
	get_tree().quit(t.done())


## The menu's rules for hands and the stylus, run by calling the rig's own functions on simulated input. Nothing here awaits: the rig's
## per-frame update would otherwise replace the simulated hands with the (absent) real ones.
## Several panels: a side panel opened from the dock stands beside it and takes the pointer where it is; the bar beside a selection
## stands just in front of the canvas, and the nib touching it presses it (but not in the middle of a stroke).
func _panel_rules(t: TestCase, rig: XrRig, board: Board, cv: FrameData) -> void:
	rig.camera.position = Vector3(0, 1.6, 0)
	rig._place_panel_front()
	rig.ui.open_side("home")
	var box := Item.new()
	box.id = U.uid("i")
	box.kind = Item.SHAPE
	box.shape = "rect"
	box.frame = cv.id
	box.center = Vector2(0.0, -0.1)
	box.size = Vector2(0.2, 0.12)
	board.history.do(History.op_add([box]))
	board.select_items([box.id], cv.id)
	for i in 40:
		await get_tree().process_frame
	var p := rig.panel
	var hp: XrPanel = rig.panels["home"]
	t.check(hp.visible, "Home opens on its own panel")
	var rel := p.global_transform.affine_inverse() * hp.global_position
	t.check(rel.x < -0.2 and rel.y > 0.1, "...beside the dock, on the left and higher up (%s)" % str(rel))
	var cp: XrPanel = rig.panels["context"]
	t.check(cp.visible, "the bar for the selection shows")
	var fn: FrameNode = board.frame_nodes[cv.id]
	var lz := fn.to_local_point(cp.widget_center()).z * cv.scale
	t.check(lz > 0.005 and lz < 0.03, "...just in front of the canvas (%.3f m)" % lz)
	t.check(fn.to_local_point(cp.global_position).y > box.center.y + box.size.y * 0.5, "...above the selection")
	# no awaiting from here: the rig's frame would replace the simulated hands with the real (absent) ones
	var pen := PenState.new()
	var rh: HandInput = rig.hands["right"]
	rh.tracked = true
	rh.aiming = true
	rh.pinching = false
	rh.pinch_down = false
	rh.pinch_up = false
	rh.palm_up = false
	rh.aim_o = rig.camera.global_position + Vector3(0.0, -0.25, -0.05)
	rh.tip = rh.aim_o
	rh.pinch_point = rh.tip
	rh.aim_d = (hp.widget_center() - rh.aim_o).normalized()
	rig._update_menu(pen)
	t.check(rig._ui_panel == hp and not rig._ui_pressed, "a ray on Home hovers Home")
	rh.aim_d = (p.widget_center() - rh.aim_o).normalized()
	rig._update_menu(pen)
	t.check(rig._ui_panel == p, "...and on the dock, the dock")
	rh.tracked = false
	rig._update_menu(pen)
	t.check(rig._ui_panel == null and rig._ui_src == "", "a hand that goes away leaves the panels")
	# the nib on the bar pinned to the canvas presses it, even though the nib is at the canvas
	var n := fn.global_transform.basis.z.normalized()
	rig.stylus.active = "right"
	pen.tracked = true
	pen.tip = cp.widget_center() - n * 0.004
	pen.dir = -n
	var busy := rig._update_menu(pen)
	t.check(not board.pen_target(pen.tip, Board.CAPTURE).is_empty(), "(the nib is at the canvas)")
	t.check(rig._ui_pressed and busy.has("pen") and rig._ui_panel == cp, "the nib at the canvas presses the bar pinned to it")
	pen.tip = cp.widget_center() + n * 0.2
	rig._update_menu(pen)
	t.check(not rig._ui_pressed, "...and lets go when it is drawn back")
	board.pen_ctl.state = PenController.S.DRAWING
	pen.tip = cp.widget_center() - n * 0.004
	busy = rig._update_menu(pen)
	t.check(not busy.has("pen") and not rig._ui_pressed, "in the middle of a stroke the nib goes past the bar")
	board.pen_ctl.state = PenController.S.IDLE
	pen.tracked = false
	rig.stylus.active = ""
	rig._update_menu(pen)
	rig.ui.close_side("home")
	board.clear_selection()


func _menu_rules(t: TestCase, rig: XrRig, board: Board, cv: FrameData, spare: FrameNode) -> void:
	var p := rig.panel
	p.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.4, -0.6))
	p.global_position += Vector3(0.0, 1.4, -0.6) - p.widget_center()      # the middle of the dock where the rules below point
	p.visible = true
	var pen := PenState.new()
	pen.tracked = false
	var rh: HandInput = rig.hands["right"]
	rh.tracked = true
	rh.aiming = true
	rh.palm_up = false
	rh.tip = Vector3(0.0, 1.4, -0.1)
	rh.pinch_point = rh.tip
	rh.aim_o = Vector3(0.0, 1.4, 0.0)
	rh.aim_d = Vector3(0.0, 0.0, -1.0)
	rh.pinching = false
	rh.pinch_down = false
	rh.pinch_up = false
	# a ray that merely crosses the menu is still the board's
	var busy := rig._update_menu(pen)
	t.check(rig._menu_hits.has("right") and not bool(rig._menu_hits.right.poke), "a hand pointing at the menu shows its ring there")
	t.check(not busy.has("right"), "...but a ray that only crosses the menu does not capture the hand")
	# a pinch that closes on it presses it, and the hand is the menu's until it opens
	rh.pinching = true
	rh.pinch_down = true
	busy = rig._update_menu(pen)
	t.check(busy.has("right") and rig._ui_pressed, "a pinch that closes on the menu presses it and captures the hand")
	rh.pinch_down = false
	busy = rig._update_menu(pen)
	t.check(busy.has("right") and rig._ui_pressed, "...for as long as the pinch is held")
	rh.pinching = false
	rh.pinch_up = true
	busy = rig._update_menu(pen)
	t.check(not rig._ui_pressed, "opening the pinch releases the button")
	rh.pinch_up = false
	busy = rig._update_menu(pen)
	# a pinch that began somewhere else is not turned into a menu press when the ray crosses the menu
	rh.pinching = true
	busy = rig._update_menu(pen)
	t.check(not rig._ui_pressed and not busy.has("right"), "a pinch that began on a canvas is not a menu press when its ray crosses the menu")
	rh.pinching = false
	busy = rig._update_menu(pen)
	# a canvas in front of the menu hides it from the ray
	spare.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.4, -0.3))
	spare.visible = true
	rh.pinching = true
	rh.pinch_down = true
	busy = rig._update_menu(pen)
	t.check(not rig._ui_pressed and not rig._menu_hits.has("right"), "a canvas between the hand and the menu takes the pinch")
	rh.pinching = false
	rh.pinch_down = false
	spare.visible = false
	busy = rig._update_menu(pen)
	# touching it
	rh.tip = Vector3(0.0, 1.4, -0.59)
	rh.pinch_point = rh.tip
	busy = rig._update_menu(pen)
	t.check(busy.has("right") and rig._ui_pressed and bool(rig._menu_hits.right.poke), "a fingertip on the menu presses it")
	rh.tip = Vector3(0.0, 1.4, -0.1)
	rh.pinch_point = rh.tip
	busy = rig._update_menu(pen)
	t.check(not rig._ui_pressed, "...and lets go when it is drawn back")
	# the stylus: its front button clicks along its body, the nib does not
	rig.stylus.active = "left"
	rh.tracked = false
	pen.tracked = true
	pen.tip = Vector3(0.0, 1.0, -0.1)
	pen.dir = (Vector3(0.0, 1.4, -0.6) - pen.tip).normalized()
	pen.down = true
	busy = rig._update_menu(pen)
	t.check(not rig._ui_pressed, "the nib pressed at a distance does not click the menu")
	pen.down = false
	pen.front = true
	busy = rig._update_menu(pen)
	t.check(rig._ui_pressed and busy.has("pen"), "the front button along the stylus clicks it")
	pen.front = false
	busy = rig._update_menu(pen)
	t.check(not rig._ui_pressed, "...and releasing it lets go")
	busy = rig._update_menu(pen)
	# touching the menu with the nib presses it too; at a canvas the stylus is not offered the menu at all
	pen.tip = Vector3(0.0, 1.4, -0.59)
	busy = rig._update_menu(pen)
	t.check(rig._ui_pressed and busy.has("pen"), "the nib on the menu presses it")
	pen.tip = Vector3(0.0, 1.0, -0.1)
	busy = rig._update_menu(pen)
	spare.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.4, -0.62))
	spare.visible = true
	pen.tip = Vector3(0.0, 1.4, -0.59)
	busy = rig._update_menu(pen)
	t.check(not rig._ui_pressed and not busy.has("pen"), "with the nib at a canvas the stylus draws instead of operating the menu")
	spare.visible = false
	pen.tracked = false
	rig.stylus.active = ""
	busy = rig._update_menu(pen)
	# the menu's handle moves it like a canvas bar: touching it, 1:1; pointing at it from afar, geared up
	rh.tracked = true
	var handle: Vector3 = p.handle_world()
	rh.tip = Vector3(0.0, 1.45, -0.3)                     # the hand held back near the face, pointing at the handle
	rh.pinch_point = rh.tip
	rh.aim_o = rh.tip
	rh.aim_d = (handle - rh.tip).normalized()
	rh.pinching = true
	rh.pinch_down = true
	var y0 := p.global_position
	busy = rig._update_menu(pen)
	t.check(rig._grab_src == "right" and busy.has("right"), "pinching with the ray on the handle grabs the menu")
	rh.pinch_down = false
	rh.pinch_point += Vector3(0.1, 0.0, 0.0)
	busy = rig._update_menu(pen)
	var expected := InputTuning.carry_gain(rig.camera.global_position, y0, rh.pinch_point - Vector3(0.1, 0.0, 0.0)) * 0.1
	t.check(expected > 0.15, "(the gain from here is more than 1: %f)" % expected)
	t.near(p.global_position.x - y0.x, expected, 0.01, "the menu moved further than the hand, by the ratio of their distances from the head")
	rh.pinching = false
	rh.pinch_up = true
	busy = rig._update_menu(pen)
	t.check(rig._grab_src == "", "opening the pinch drops the menu")
	rh.pinch_up = false
	rh.tip = p.handle_world() + Vector3(0.0, 0.0, 0.02)
	rh.pinch_point = rh.tip
	rh.aim_o = rh.tip + Vector3(0.0, 0.0, 0.5)
	rh.aim_d = Vector3(0.0, 0.0, -1.0)
	var y1 := p.global_position
	rh.pinching = true
	rh.pinch_down = true
	busy = rig._update_menu(pen)
	rh.pinch_down = false
	rh.pinch_point += Vector3(0.1, 0.0, 0.0)
	busy = rig._update_menu(pen)
	t.near(p.global_position.x - y1.x, 0.1, 0.005, "touching the handle: the menu follows the pinch point 1:1")
	rh.pinching = false
	rh.pinch_up = true
	busy = rig._update_menu(pen)
	rh.pinch_up = false
	rh.tracked = false
	# bringing the menu: an open palm and the stylus's front button both put it in front of the head, after the same hold
	var head := rig.camera.global_position
	p.global_position = Vector3(0.0, 1.4, -2.0)
	var lh: HandInput = rig.hands["left"]
	lh.tracked = true
	lh.palm_up = true
	lh.pinching = false
	lh.palm = head + Vector3(0.1, -0.3, -0.3)
	rig._palm_t["left"] = 0.0
	rig._summon_gesture(InputTuning.SUMMON_HOLD_S * 0.5, false)
	t.near(p.global_position.z, -2.0, 1e-6, "an open palm held for half the time does nothing yet")
	rig._summon_gesture(InputTuning.SUMMON_HOLD_S * 0.6, false)
	t.near(p.global_position.distance_to(head), Vector3(InputTuning.SUMMON_AHEAD, InputTuning.SUMMON_RIGHT, InputTuning.SUMMON_UP).length(), 0.1, "an open palm brings the menu in front of the head")
	lh.tracked = false
	lh.palm_up = false
	var in_front := p.global_position
	p.global_position = Vector3(0.0, 1.4, -2.0)
	rig.stylus.active = "right"
	pen.tracked = true
	pen.front = true
	pen.tip = head + Vector3(0.3, 0.0, -0.1)
	pen.dir = Vector3(0.0, 0.0, 1.0)
	rig._front_t = 0.0
	rig._stylus_summon(InputTuning.SUMMON_HOLD_S * 0.5, pen, true)
	t.near(p.global_position.z, -2.0, 1e-6, "the front button held for half the time does nothing yet")
	rig._stylus_summon(InputTuning.SUMMON_HOLD_S * 0.6, pen, true)
	t.near(p.global_position.distance_to(in_front), 0.0, 0.01, "the stylus brings the menu to the same place as the palm does")
	p.global_position = Vector3(0.0, 1.4, -2.0)
	pen.dir = (board.frame_nodes[cv.id].global_position - pen.tip).normalized()
	rig._front_t = 0.0
	rig._stylus_summon(InputTuning.SUMMON_HOLD_S * 2.0, pen, true)
	t.near(p.global_position.z, -2.0, 1e-6, "pointing at a canvas, the front button grabs it instead of bringing the menu")
	pen.front = false
	pen.tracked = false
	rig.stylus.active = ""
