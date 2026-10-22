extends Node
## Presses every button of every menu tab (twice for toggles, once for the arm-then-confirm bins) and moves every slider and the colour
## picker, with a document that has content and a selection. The run fails on any script error the menu throws.

func _ready() -> void:
	var t := TestCase.new("ui_smoke")
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_ui"
	App.reload()
	var board := Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors3.json")
	add_child(anchors)
	board.setup(anchors)
	var doc := DemoDoc.build()
	doc.id = "ui-smoke"
	doc.save()
	board.open(doc)
	var pen := PenState.new()
	var menu := MenuPanel.new()
	add_child(menu)
	menu.setup(board)
	for i in 120:
		board.tick(pen, [], 0.016)
		await get_tree().process_frame
	t.eq(board.room_state, "found", "the demo room is found")
	# select two items so the selection strip is live
	var ids: Array = []
	for it in doc.items.values():
		if (it as Item).kind == Item.SHAPE and ids.size() < 2:
			ids.append((it as Item).id)
	board.select_items(ids, (doc.items[ids[0]] as Item).frame)
	await get_tree().process_frame

	var pressed := 0
	for tab in ["draw", "shapes", "canvas", "docs", "rooms", "more"]:
		menu._select_tab(tab)
		for i in 4:
			board.tick(pen, [], 0.016)
			await get_tree().process_frame
		for b in menu.find_children("*", "Btn", true, false):
			var btn := b as Btn
			if not is_instance_valid(btn) or not btn.is_visible_in_tree() or btn == menu._quit_btn:
				continue                                   # Quit really quits: it is checked below
			btn.pressed.emit()
			if btn.toggle_mode:
				btn.toggled.emit(not btn.on)
			pressed += 1
			await get_tree().process_frame
			if menu.entry_open():                      # Type, Rename ... open the typing box, which replaces the tabs: close it again
				menu.close_entry()
		for s in menu.find_children("*", "FlatSlider", true, false):
			var sl := s as FlatSlider
			if is_instance_valid(sl) and sl.is_visible_in_tree():
				sl.value = lerpf(sl.min_value, sl.max_value, 0.7)
				sl.value_changed.emit(sl.value)
		for p in menu.find_children("*", "HsvPicker", true, false):
			(p as HsvPicker).color_changed.emit(Color.from_hsv(0.3, 0.8, 0.9))
		board.cancel_place()
		for i in 3:
			await get_tree().process_frame
	t.check(pressed > 60, "pressed %d buttons across the tabs" % pressed)
	t.check(board.doc != null, "the board still has a document after all that")
	# Quit needs a second press: the first only arms it (and times out again)
	menu._quit_btn.pressed.emit()
	t.eq(menu._quit_btn.text, "Sure?", "the first press of Quit asks again")
	menu._process(3.5)
	t.eq(menu._quit_btn.text, "Quit", "...and gives up after a few seconds")
	# the document list can open another document
	menu._select_tab("docs")
	await get_tree().process_frame
	await get_tree().process_frame
	t.check(DocStore.list().size() >= 1, "documents are listed")
	for s in DocStore.list():
		DocStore.delete(s.id)
	get_tree().quit(t.done())
