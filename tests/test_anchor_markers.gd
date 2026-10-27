extends Node
## Show spatial anchors (Settings > Display): nothing is drawn while it is off; switched on, every anchor that has a place in the room gets
## its axes and a label saying what it holds (room, canvas, panels); switched off again, they go.

var t := TestCase.new("anchor_markers")
var board: Board
var pen := PenState.new()


func _ready() -> void:
	App.settings_path = "user://test_settings_anchor_markers.cfg"
	App.docs_dir = "user://test_docs_anchor_markers"
	App.reload()
	App.put("sim_room", "A")
	App.put("show_anchors", false)
	var sim_path := "user://test_sim_anchors_markers.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(sim_path))
	board = Board.new()
	add_child(board)
	var anchors := SimAnchors.new(sim_path)
	add_child(anchors)
	board.setup(anchors)
	board.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	board.extra_anchor_roles.append(func() -> Dictionary: return {"panel-anchor": "panels|Panels"})
	var doc := DemoDoc.build()
	doc.id = "anchor-markers"
	doc.save()
	board.open(doc)
	await _frames(120)
	t.eq(board.room_state, "found", "the demo room is found")
	t.eq(board.anchor_markers.shown(), 0, "nothing is drawn while the setting is off")

	App.put("show_anchors", true)
	await _frames(3)
	var tracked := 0
	for u in anchors.known():
		if anchors.has_pose(u):
			tracked += 1
	t.check(tracked > 0, "the room has anchors with a place")
	t.eq(board.anchor_markers.shown(), tracked, "each anchor with a place is drawn")
	var roles := board.anchor_roles()
	var room_anchor := str(board.doc.room(board.current_room)["anchor"])
	t.check(str(roles.get(room_anchor, "")).begins_with("room|"), "the room's anchor is labelled as a room")
	t.check(str(roles.get("panel-anchor", "")) == "panels|Panels", "the panels' anchor is labelled too")
	var labelled := false
	for m in board.anchor_markers._marks.values():
		if (m as AnchorMarkers.Mark).label.text.contains(room_anchor.substr(0, 8)):
			labelled = true
	t.check(labelled, "a label carries the start of the anchor's id")

	anchors.blackout = true
	await _frames(3)
	t.eq(board.anchor_markers.shown(), 0, "an anchor without a place is not drawn")
	anchors.blackout = false

	App.put("show_anchors", false)
	await _frames(3)
	t.eq(board.anchor_markers.shown(), 0, "switched off, they go")
	get_tree().quit(t.done())


func _frames(n: int) -> void:
	for i in n:
		board.tick(pen, [], 0.016)
		await get_tree().process_frame
