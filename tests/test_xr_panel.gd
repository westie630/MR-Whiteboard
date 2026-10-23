extends Node
## A surface on a headset panel: pointer positions on the 3D panel must land on the right controls at 2x render scale, taps inside
## scrolling lists must click, drags must scroll, sliders must follow the pointer; only the surface itself catches rays (the empty
## texture around it lets them through), and the node sits on the surface's pivot.

var t: TestCase


func _ready() -> void:
	t = TestCase.new("xr_panel")
	App.settings_path = "user://test_settings.cfg"
	App.reload()
	var board := Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors2.json")
	add_child(anchors)
	board.setup(anchors)
	board.open(Document.create("Panel test"))
	var ui := UiShell.new()
	add_child(ui)
	ui.setup(board)
	ui.open_side("home")
	var home := ui.home
	var panel := XrPanel.new()
	add_child(panel)
	panel.pivot = home.pivot
	panel.setup(home, home.max_size, home.ppm, false)
	for i in 8:
		await get_tree().process_frame

	t.eq(panel.viewport.size, Vector2i((home.max_size * 2.0).ceil()), "the panel texture is twice the logical size")
	t.check(home.visible and home.size.x >= HomePanel.W, "the Home panel shows (%s)" % str(home.size))
	t.check(panel.widget_rect().get_center().distance_to(home.max_size * 0.5) < 1.0, "a centred surface sits in the middle of its texture")
	# poke the Settings tab
	await _tap(panel, home._tab_btns["settings"])
	t.eq(home.tab, "settings", "poking a tab chip switches the tab")
	# a switch inside the scrolling page (taps there are deferred until release)
	var sw := _find(home, "Switch", func(n): return (n as Switch).text == "Convert after a pause") as Switch
	t.check(sw != null, "found a switch on the settings page")
	if sw != null:
		var before := bool(App.val("ink_auto"))
		await _tap(panel, sw)
		t.eq(bool(App.val("ink_auto")), not before, "a tap inside the scroll list toggles the switch")
		await _tap(panel, sw)
		t.eq(bool(App.val("ink_auto")), before, "...and again back")
	# a slider follows the pointer
	var slider := _find(home, "FlatSlider", func(_n): return true) as FlatSlider
	t.check(slider != null, "found a slider")
	if slider != null:
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
	var page_scroll := home._scroll
	var before_scroll := page_scroll.scroll_vertical
	var settings_before := str(App.val("ink_provider")) + str(App.val("stylus_hand")) + str(App.val("grid"))
	var wr := panel.widget_rect()
	var a := _uv(panel, wr.position + Vector2(wr.size.x * 0.5, wr.size.y * 0.75))
	var b := _uv(panel, wr.position + Vector2(wr.size.x * 0.5, wr.size.y * 0.4))
	panel.pointer_move(a)
	panel.pointer_press(a)
	for i in 8:
		panel.pointer_move(a.lerp(b, float(i + 1) / 8.0))
		await get_tree().process_frame
	panel.pointer_release(b)
	await get_tree().process_frame
	t.check(page_scroll.scroll_vertical > before_scroll, "dragging up scrolls the page (%d -> %d)" % [before_scroll, page_scroll.scroll_vertical])
	t.eq(str(App.val("ink_provider")) + str(App.val("stylus_hand")) + str(App.val("grid")), settings_before, "the drag did not click anything")

	# ray / poke geometry: the node is at the pivot (the middle of a side panel)
	panel.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -0.6))
	var rc := panel.raycast(Vector3(0, 1.4, 0.4), Vector3(0, 0, -1))
	t.check(rc.hit and (rc.uv as Vector2).distance_to(Vector2(0.5, 0.5)) < 0.01, "a ray through the middle hits the middle of the panel")
	var ti := panel.touch_info(Vector3(0, 1.4, -0.595))
	t.check(ti.inside and ti.depth > 0.0, "a fingertip 5 mm in front of the panel is in front of it")
	t.check(panel.widget_center().distance_to(Vector3(0, 1.4, -0.6)) < 0.001, "the widget's middle is the node's origin")

	# the dock: its texture has room above it for the tooltips, and that room lets rays through
	var dp := XrPanel.new()
	add_child(dp)
	dp.pivot = ui.dock.pivot
	dp.setup(ui.dock, ui.dock.max_size, ui.dock.ppm, false)
	for i in 4:
		await get_tree().process_frame
	dp.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.0, -0.6))
	var dr := dp.widget_rect()
	t.near(dr.end.y, ui.dock.max_size.y, 1.0, "the dock sits at the bottom of its texture")
	var mid := dp.widget_center()
	t.check(dp.raycast(mid + Vector3(0, 0, 0.5), Vector3(0, 0, -1)).hit, "a ray on the dock hits it")
	var above := mid + Vector3(0, (dr.size.y * 0.5 + 30.0) * dp.mpp(), 0)
	t.check(not dp.raycast(above + Vector3(0, 0, 0.5), Vector3(0, 0, -1)).hit, "a ray through the empty texture above it goes through")
	t.check(not dp.touch_info(above + Vector3(0, 0, 0.005)).inside, "...and so does a fingertip")
	t.near(dp.global_position.y, mid.y - dr.size.y * 0.5 * dp.mpp(), 0.001, "the node is at the dock's lower edge (its pivot)")
	t.check(dp.handle_world().y < dp.global_position.y, "the handle hangs under the dock")
	get_tree().quit(t.done())


func _uv(panel: XrPanel, logical: Vector2) -> Vector2:
	return Vector2(logical.x / panel.design.x, logical.y / panel.design.y)


func _tap(panel: XrPanel, c: Control) -> void:
	var r := c.get_global_rect()
	var uv := _uv(panel, r.get_center())
	panel.pointer_move(uv)
	await get_tree().process_frame
	panel.pointer_press(uv)
	await get_tree().process_frame
	panel.pointer_release(uv)
	await get_tree().process_frame
	await get_tree().process_frame


func _find(root: Node, cls: String, ok: Callable) -> Control:
	for n in root.find_children("*", cls, true, false):
		if (n as Control).is_visible_in_tree() and ok.call(n):
			return n
	return null
