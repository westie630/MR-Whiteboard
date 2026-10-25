extends Node
## Canvases stay exactly where they were left, at the size they were left, in every way the app can be stopped and started again or the
## headset can lose and find the room: a restart, a restart with the tracking space somewhere else, the headset taken off and put back on,
## a recentre, another document opened and this one opened again, an undone move, the room's own anchor lost, the room not found at first
## (and a canvas moved meanwhile), anchors that cannot be made at first, and a save cut short. The headset's anchors are simulated
## (SimAnchors), each "restart" is a new board with new anchors read from the same files.

const SIM := "user://test_sim_anchors_anchoring.json"
const DT := 0.016

var t := TestCase.new("anchoring")
var board: Board
var anchors: SimAnchors
var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
var pen := PenState.new()
var doc_id := ""
var toasts: Array = []


func _ready() -> void:
	App.settings_path = "user://test_settings_anchoring.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_anchoring"
	if DirAccess.dir_exists_absolute(App.docs_dir):
		for f in DirAccess.get_files_at(App.docs_dir):
			DirAccess.remove_absolute(App.docs_dir + "/" + f)
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SIM))
	App.put("sim_room", "A")
	await run()
	get_tree().quit(t.done())


## A fresh start of the app: a new board and new anchors (read from the same file), showing the document.
func boot(shift: Transform3D = Transform3D.IDENTITY, hidden: Array = []) -> void:
	if board != null:
		board.flush_save()
		board.free()
		anchors.free()
	anchors = SimAnchors.new(SIM)
	anchors.shift = shift
	for u in hidden:
		anchors.hidden[u] = true
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.head_provider = func(): return head
	board.toast.connect(func(line: String): toasts.append(line))
	if doc_id == "":
		board.new_document("Anchoring")
		doc_id = board.doc.id
	else:
		board.open(DocStore.open(doc_id))
	await get_tree().process_frame


func tick(n: int = 1) -> void:
	for i in n:
		board.tick(pen, [], DT)
		await get_tree().process_frame


func seconds(s: float) -> void:
	await tick(int(s / DT) + 1)


## Every canvas's pose in the world as shown (with its scale).
func poses() -> Dictionary:
	var out := {}
	for id in board.frame_nodes:
		var fn: FrameNode = board.frame_nodes[id]
		if fn.visible:
			out[id] = fn.global_transform
	return out


func same_place(a: Transform3D, b: Transform3D, tol: float = 0.002) -> bool:
	return a.origin.distance_to(b.origin) < tol and (a.basis.x - b.basis.x).length() < tol * 2.0 and (a.basis.y - b.basis.y).length() < tol * 2.0 \
		and (a.basis.z - b.basis.z).length() < tol * 2.0


func all_at(want: Dictionary, shift: Transform3D, what: String, tol: float = 0.002) -> void:
	var now := poses()
	for id in want:
		var w: Transform3D = shift * (want[id] as Transform3D)
		var ok := now.has(id) and same_place(now[id], w, tol)
		t.check(ok, "%s: %s is where it was left%s" % [what, board.doc.frames[id].name, "" if ok else " (now %s, want %s)" % [str(now.get(id, "hidden")), str(w.origin)]])


func move(f: FrameData, to: Transform3D, scale: float = -1.0) -> void:
	board.begin_grab(f)
	(board.grabs[f.id] as Dictionary).xf = to
	if scale > 0.0:
		(board.grabs[f.id] as Dictionary).scale = scale
	board.end_grab(f)


func run() -> void:
	# ---- a room and two canvases, one moved and scaled
	await boot()
	await seconds(1.6)
	t.eq(board.room_state, "found", "a new document makes its room where you stand")
	var a := board.add_frame(FrameData.CANVAS, Transform3D(Basis(Vector3.UP, 0.3), Vector3(-0.6, 1.4, -1.2)))
	var b := board.add_frame(FrameData.CANVAS, Transform3D(Basis(Vector3.UP, -0.5), Vector3(1.2, 1.2, -0.8)))
	await seconds(1.5)
	move(board.doc.frames[a.id], Transform3D(Basis(Vector3.UP, 0.6) * Basis(Vector3.RIGHT, -0.2), Vector3(-0.9, 1.5, -1.6)), 1.7)
	await seconds(1.5)
	t.check(not (board.doc.frames[a.id] as FrameData).anchor_stale() and not (board.doc.frames[b.id] as FrameData).anchor_stale(), "both canvases have anchors at their places")
	var p0 := poses()
	t.eq(p0.size(), 2, "both canvases are shown")
	var room_anchor := str(board.doc.room(board.current_room).anchor)

	# ---- restart
	await boot()
	await tick(3)
	t.eq(board.room_state, "found", "after a restart the room is found at once by its anchors")
	all_at(p0, Transform3D.IDENTITY, "restart")
	t.near(float((board.doc.frames[a.id] as FrameData).scale), 1.7, 1e-4, "restart: the scaled canvas keeps its scale")

	# ---- restart with the tracking space elsewhere (the headset started somewhere else in the room)
	var s1 := Transform3D(Basis(Vector3.UP, deg_to_rad(65.0)), Vector3(2.5, 0.0, -1.0))
	await boot(s1)
	await tick(3)
	all_at(p0, s1, "restart in another tracking space")

	# ---- headset taken off (no poses, tracking stopped) and put back on, the tracking space moved meanwhile
	anchors.blackout = true
	board.tracking_live = false
	await seconds(Board.ROOM_SEARCH_S + 3.0)
	t.check(board.room_state != "assumed", "with the headset off the room is not given up on (%s)" % board.room_state)
	var s2 := Transform3D(Basis(Vector3.UP, deg_to_rad(-30.0)), Vector3(-1.0, 0.0, 2.0))
	anchors.shift = s2
	anchors.blackout = false
	board.tracking_reset()
	board.tracking_live = true
	await tick(3)
	t.eq(board.room_state, "found", "headset back on: the room is found")
	all_at(p0, s2, "headset off and on")

	# ---- a short dropout (re-localising) keeps everything shown where it was
	anchors.blackout = true
	await tick(20)
	t.eq(board.room_state, "found", "a short dropout keeps the room")
	all_at(p0, s2, "short dropout")
	anchors.blackout = false

	# ---- recentring (no dropout)
	var s3 := Transform3D(Basis(Vector3.UP, deg_to_rad(120.0)), Vector3(0.5, 0.0, 0.7))
	anchors.shift = s3
	board.tracking_reset()
	await tick(3)
	all_at(p0, s3, "recentre")

	# ---- another document, then this one again
	board.new_document("Other")
	await seconds(1.6)
	board.open(DocStore.open(doc_id))
	await tick(2)
	t.eq(board.room_state, "found", "back to the document: its room is found at once")
	all_at(p0, s3, "document opened again")

	# ---- an undone move: the canvas goes back and is anchored there (no erased anchor comes back with the undo)
	var fb: FrameData = board.doc.frames[b.id]
	move(fb, s3 * Transform3D(Basis.IDENTITY, Vector3(0.0, 1.3, -2.0)))
	await seconds(1.5)
	var moved_anchor := str((board.doc.frames[b.id] as FrameData).anchor)
	board.undo()
	await tick(1)
	var after_undo := str((board.doc.frames[b.id] as FrameData).anchor)
	t.eq(after_undo, moved_anchor, "undo keeps the anchor the canvas has now")
	t.check(anchors.is_stored(after_undo), "...which still exists")
	await seconds(1.5)
	fb = board.doc.frames[b.id]
	t.check(not fb.anchor_stale() and anchors.is_stored(fb.anchor) and fb.anchor != moved_anchor, "the canvas put back by the undo has a new anchor there")
	all_at(p0, s3, "undo")

	# ---- the room's own anchor lost (Space Setup redone, storage cleared): its canvases still find the room
	anchors.erase(room_anchor)
	await boot(s3)
	await tick(3)
	t.eq(board.room_state, "found", "the room is found through its canvases' anchors")
	t.eq(str(board._located_by.get(board.current_room, "")), "frame", "...(by them)")
	all_at(p0, s3, "room anchor lost")
	await seconds(Board.ANCHOR_LOST_S + 2.0)
	var new_room_anchor := str(board.doc.room(board.current_room).anchor)
	t.check(new_room_anchor != "" and new_room_anchor != room_anchor and anchors.is_stored(new_room_anchor), "the room got a new anchor of its own")
	await boot(s3)
	await tick(3)
	t.eq(str(board._located_by.get(board.current_room, "")), "room", "next start the room is found by its new anchor")
	all_at(p0, s3, "new room anchor")
	room_anchor = new_room_anchor

	# ---- the anchors found on the device but slow to be placed (a Quest 3 just put on: well over 5 s, seen on the headset): the room
	# is not given up on and shown in front of the user, it is waited for; then everything is where it was, and nothing is re-anchored
	await boot(s3)
	for u in anchors.stored():
		anchors.slow[u] = true
	toasts.clear()
	var made := anchors.creates
	await seconds(Board.ROOM_SEARCH_S + Board.ANCHOR_LOST_S + 2.0)
	t.eq(board.room_state, "searching", "anchors being placed: the room is still being looked for, not shown in front")
	t.check(toasts.filter(func(l): return str(l).contains("were not found")).is_empty(), "...and the user is not told it was not found")
	anchors.slow.clear()
	await seconds(1.5)
	t.eq(str(board._located_by.get(board.current_room, "")), "room", "placed: the room is found by its anchor")
	all_at(p0, s3, "anchors placed late")
	t.eq(anchors.creates, made, "no anchor was replaced meanwhile")
	t.eq(str(board.doc.room(board.current_room).anchor), room_anchor, "the room keeps its anchor")

	# ---- the room not found at first (the headset still localising): it is shown in front; a canvas moved meanwhile stays where it
	# was put, the room's own anchor is not given up, and once the anchors are found everything else is back in its place
	var all_now: Array = anchors.stored()
	await boot(s3, all_now)
	await seconds(Board.ROOM_SEARCH_S + 0.5)
	t.eq(board.room_state, "assumed", "anchors not found: the room is shown in front of the user")
	var put_at := Transform3D(Basis(Vector3.UP, 0.2), Vector3(0.3, 1.5, -0.9))
	move(board.doc.frames[a.id], put_at, 1.7)
	await seconds(1.5)
	var fa: FrameData = board.doc.frames[a.id]
	t.check(fa.anchor != "" and not fa.anchor_stale() and fa.anchor_guess, "the canvas moved meanwhile is anchored where it was put (marked as made under a guess)")
	t.check(not (board.doc.frames[b.id] as FrameData).anchor_guess and (board.doc.frames[b.id] as FrameData).anchor in all_now, "the other canvas keeps its real anchor")
	await seconds(Board.ANCHOR_LOST_S + 2.0)
	t.eq(str(board.doc.room(board.current_room).anchor), room_anchor, "the room's real anchor is not replaced while its place is only guessed")
	anchors.hidden.clear()
	await seconds(1.5)
	t.eq(str(board._located_by.get(board.current_room, "")), "room", "the anchors are found: the room is where it really is")
	t.check(same_place((board.frame_nodes[a.id] as FrameNode).global_transform, put_at.scaled_local(Vector3.ONE * 1.7)), "the canvas moved meanwhile stays where it was put")
	all_at({b.id: p0[b.id]}, s3, "anchors found after a guess")
	fa = board.doc.frames[a.id]
	t.check(not fa.anchor_guess, "its place in the room is corrected from its anchor")
	var by_room: Transform3D = (board.room_world(board.current_room) as Transform3D) * fa.xf
	t.check(by_room.origin.distance_to(put_at.origin) < 0.002, "...so the room alone puts it there too")
	var p1 := poses()
	await boot(s3)
	await tick(3)
	all_at(p1, Transform3D.IDENTITY, "restart after the guess")

	# ---- anchors that cannot be made at first (no Space Setup yet): tried again later, the user told once
	toasts.clear()
	anchors.fail_next = 1
	anchors.creates = 0
	var c := board.add_frame(FrameData.CANVAS, s3 * Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, -1.5)))
	var until := Time.get_ticks_msec() + int((Board.RETRY_MIN_S + 1.5) * 1000.0)
	while Time.get_ticks_msec() < until:
		await tick()
	t.eq(toasts.filter(func(l): return str(l).contains("spatial anchor")).size(), 1, "the failure is told once")
	t.check(anchors.creates <= 3, "and not tried on every frame (%d tries)" % anchors.creates)
	var fc: FrameData = board.doc.frames[c.id]
	t.check(fc.anchor != "" and not fc.anchor_stale(), "a later try makes the anchor")

	# ---- the canvas last drawn on lies on a desk and the room is not found (seen on the Quest after the headset was put back on): it
	# is shown still lying flat, within reach at the desk's height, its top away from the user; the room is not tipped over for it
	var desk_at := s3 * Vector3(0.2, 0.74, -0.5)
	var d := board.add_frame(FrameData.CANVAS, board.surface.pose_for(desk_at, Vector3.UP), Vector2(0.6, 0.4),
			{"point": desk_at, "normal": Vector3.UP, "error": 0.002, "count": 8})
	await seconds(1.5)
	t.check((board.doc.frames[d.id] as FrameData).surface, "a canvas on the desk")
	var desk_shown: Transform3D = poses()[d.id]
	var desk_in_room: Transform3D = (board.doc.frames[d.id] as FrameData).xf
	await boot(s3, anchors.stored())
	board.active_frame = d.id
	await seconds(Board.ROOM_SEARCH_S + 0.5)
	t.eq(board.room_state, "assumed", "desk canvas, anchors not found: the room is shown in front of the user")
	var shown: Transform3D = poses()[d.id]
	t.near(shown.basis.z.normalized().dot(Vector3.UP), 1.0, 1e-4, "the desk canvas still lies flat (normal %s)" % str(shown.basis.z))
	t.near(shown.origin.y, desk_in_room.origin.y, 0.002, "at the desk's height in the room")
	t.near(Vector2(shown.origin.x - head.origin.x, shown.origin.z - head.origin.z).length(), Board.DESK_DIST, 0.002, "within reach in front of the user")
	t.check(shown.basis.y.normalized().dot(Vector3.FORWARD) > 0.999, "its top points away from the user")
	t.near((board.room_world(board.current_room) as Transform3D).basis.y.dot(Vector3.UP), 1.0, 1e-5, "the room stays level")
	anchors.hidden.clear()
	await seconds(1.5)
	t.eq(str(board._located_by.get(board.current_room, "")), "room", "the anchors are found again")
	all_at({d.id: desk_shown}, Transform3D.IDENTITY, "desk canvas after the guess")
	t.check(same_place((board.doc.frames[d.id] as FrameData).xf, desk_in_room), "drawing nothing meanwhile, its place on the desk is unchanged")

	# ---- a save cut short: only the new file (not yet renamed) is left
	board.flush_save()
	board.doc.save()
	var path := DocStore.path_for(doc_id)
	DirAccess.copy_absolute(path, path + ".tmp")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path + ".bak")
	var ids: Array = DocStore.list().map(func(e): return str(e.id))
	t.check(ids.has(doc_id), "a document whose save was cut short is still listed")
	var back := DocStore.open(doc_id)
	t.check(back != null and back.frames.size() == board.doc.frames.size(), "and opens with everything in it")
	t.check(FileAccess.file_exists(path), "its file is back in place")
	DocStore.delete(doc_id)
	t.check(not FileAccess.file_exists(path + ".tmp") and not DocStore.list().map(func(e): return str(e.id)).has(doc_id), "deleting it removes every copy")
