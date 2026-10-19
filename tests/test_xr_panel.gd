extends Node
## The headset menu panel: pointer positions on the 3D panel must land on the right buttons at 2x render scale, taps inside scrolling
## lists must click, drags must scroll, and sliders must follow the pointer.

func _ready() -> void:
	var t := TestCase.new("xr_panel")
	App.settings_path = "user://test_settings.cfg"
	App.reload()
	var board := Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors2.json")
	add_child(anchors)
	board.setup(anchors)
	board.open(Document.create("Panel test"))
	var menu := MenuPanel.new()
	menu.setup(board)
	var panel := XrPanel.new()
	add_child(panel)
	panel.setup(menu, MenuPanel.DESIGN_SIZE, 1450.0, false)
	for i in 6:
		await get_tree().process_frame

	t.eq(panel.viewport.size, Vector2i(MenuPanel.DESIGN_SIZE * 2.0), "the panel texture is twice the logical size")
	# poke the "Shapes" tab
	var tab_btn: Btn = menu._tab_btns["shapes"]
	await _tap(panel, menu, tab_btn)
	t.eq(str(App.val("menu_tab")), "shapes", "poking a tab button switches the tab")

	# a button inside the scrolling Draw page (taps are deferred until release)
	menu._select_tab("draw")
	await get_tree().process_frame
	await get_tree().process_frame
	var erase_btn := _find_btn(menu, "Erase")
	t.check(erase_btn != null, "found the Erase tool button")
	if erase_btn != null:
		await _tap(panel, menu, erase_btn)
		t.eq(str(App.val("tool")), "erase", "a tap inside the scroll list clicks the button")
		var write_btn := _find_btn(menu, "Write")
		await _tap(panel, menu, write_btn)
		t.eq(str(App.val("tool")), "write", "another tool button")

	# the width slider follows the pointer
	var slider: FlatSlider = _find_slider(menu)
	t.check(slider != null, "found a slider")
	if slider != null:
		(menu._pages["draw"].scroll as ScrollContainer).ensure_control_visible(slider)
		await get_tree().process_frame
		await get_tree().process_frame
		var r := slider.get_global_rect()
		var y := r.position.y + r.size.y * 0.5
		var uv_a := _uv(panel, Vector2(r.position.x + r.size.x * 0.2, y))
		var uv_b := _uv(panel, Vector2(r.position.x + r.size.x * 0.8, y))
		panel.pointer_move(uv_a)
		panel.pointer_press(uv_a)
		await get_tree().process_frame
		var v1 := slider.value
		panel.pointer_move(uv_b)
		await get_tree().process_frame
		panel.pointer_release(uv_b)
		await get_tree().process_frame
		t.check(slider.value > v1 + 0.005, "dragging the slider raises its value (%f -> %f)" % [v1, slider.value])

	# a vertical drag scrolls the page instead of clicking
	var page_scroll: ScrollContainer = menu._pages["draw"].scroll
	var before := page_scroll.scroll_vertical
	var tool_before := str(App.val("tool"))
	var a := _uv(panel, Vector2(300, 520))
	var b := _uv(panel, Vector2(300, 300))
	panel.pointer_move(a)
	panel.pointer_press(a)
	for i in 8:
		panel.pointer_move(a.lerp(b, float(i + 1) / 8.0))
		await get_tree().process_frame
	panel.pointer_release(b)
	await get_tree().process_frame
	t.check(page_scroll.scroll_vertical > before, "dragging up scrolls the page (%d -> %d)" % [before, page_scroll.scroll_vertical])
	t.eq(str(App.val("tool")), tool_before, "the drag did not click anything")

	# ray / poke geometry
	panel.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -0.6))
	var rc := panel.raycast(Vector3(0, 1.4, 0.4), Vector3(0, 0, -1))
	t.check(rc.hit and absf(rc.uv.x - 0.5) < 0.01 and absf(rc.uv.y - 0.5) < 0.01, "a ray through the middle hits the middle of the panel")
	var ti := panel.touch_info(Vector3(0, 1.4, -0.595))
	t.check(ti.inside and ti.depth > 0.0, "a fingertip 5 mm in front of the panel is in front of it")
	get_tree().quit(t.done())


func _uv(panel: XrPanel, logical: Vector2) -> Vector2:
	return Vector2(logical.x / panel.design.x, logical.y / panel.design.y)


func _tap(panel: XrPanel, menu: MenuPanel, btn: Control) -> void:
	var r := btn.get_global_rect()
	var uv := _uv(panel, r.get_center())
	panel.pointer_move(uv)
	await get_tree().process_frame
	panel.pointer_press(uv)
	await get_tree().process_frame
	panel.pointer_release(uv)
	await get_tree().process_frame
	await get_tree().process_frame


func _find_btn(root: Node, text: String) -> Btn:
	for n in root.find_children("*", "Btn", true, false):
		if (n as Btn).text == text and (n as Btn).is_visible_in_tree():
			return n
	return null


func _find_slider(root: Node) -> FlatSlider:
	for n in root.find_children("*", "FlatSlider", true, false):
		if (n as FlatSlider).is_visible_in_tree():
			return n
	return null
