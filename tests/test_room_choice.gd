extends Node
## Which room the app starts in when the headset's map spans the whole home (a Quest 3 maps every room it has been in, so the anchors of
## the room next door are found as well): the one the user stands in, not the one used last; also when the rooms are found one after
## the other, when the headset is put back on in another room, and not against the user's own choice. The rooms are made in one
## simulated room (SimAnchors), so all their anchors have a pose at once; each "restart" is a new board reading the same files.

const SIM := "user://test_sim_anchors_room_choice.json"
const DT := 0.016

var t := TestCase.new("room_choice")
var board: Board
var anchors: SimAnchors
var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
var pen := PenState.new()
var doc_id := ""


func _ready() -> void:
	App.settings_path = "user://test_settings_room_choice.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_room_choice"
	if DirAccess.dir_exists_absolute(App.docs_dir):
		for f in DirAccess.get_files_at(App.docs_dir):
			DirAccess.remove_absolute(App.docs_dir + "/" + f)
	DirAccess.make_dir_recursive_absolute(App.docs_dir)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SIM))
	App.put("sim_room", "A")
	await run()
	get_tree().quit(t.done())


## A fresh start of the app: a new board and new anchors (read from the same file), showing the document. `slow`: anchors the headset
## has found but is still placing.
func boot(slow: Array = []) -> void:
	if board != null:
		board.flush_save()
		board.free()
		anchors.free()
	anchors = SimAnchors.new(SIM)
	for u in slow:
		anchors.slow[u] = true
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.head_provider = func(): return head
	if doc_id == "":
		board.new_document("Home")
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


func stand(x: float, z: float) -> void:
	head = Transform3D(Basis.IDENTITY, Vector3(x, 1.6, z))


func room_name() -> String:
	return str(board.doc.room(board.current_room).get("name", "(none)"))


func run() -> void:
	# ---- the living room (the document's first room, made where you stand) and the office next door, used last
	stand(0.0, 0.0)
	await boot()
	await seconds(1.6)
	var living := board.current_room
	board.rename_room(living, "Living room")
	var sofa := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, -2.2)))
	await seconds(1.5)
	stand(6.0, 0.0)
	await tick(2)
	board.create_room_here("Office")
	var office := board.current_room
	var desk := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(6.4, 1.3, -1.5)))
	await seconds(1.5)
	t.eq(board.doc.last_room, office, "the office is the room used last")
	t.check(str(board.doc.room(living).anchor) != "" and str(board.doc.room(office).anchor) != "", "both rooms have their anchors")
	var sofa_anchor := (board.doc.frames[sofa.id] as FrameData).anchor
	var living_anchor := str(board.doc.room(living).anchor)

	# ---- restart standing in the living room: both rooms' anchors are found, the living room is the one you are in
	stand(0.4, -0.3)
	await boot()
	await tick(3)
	t.eq(board.room_state, "found", "restart: a room is found at once")
	t.eq(room_name(), "Living room", "restart in the living room: it is the room shown, not the office used last")
	t.check(board.frame_nodes[sofa.id].visible and not board.frame_nodes[desk.id].visible, "the living room's canvas is shown, the office's is not")
	t.eq(board.doc.last_room, living, "the living room is now the room used last")

	# ---- restart in the office: the office
	stand(6.2, -0.4)
	await boot()
	await tick(3)
	t.eq(room_name(), "Office", "restart in the office: the office is shown")
	t.check(board.frame_nodes[desk.id].visible and not board.frame_nodes[sofa.id].visible, "the office's canvas is shown, the living room's is not")

	# ---- restart in the living room, its anchors placed late (a Quest 3 just put on): the office is found first, the living room
	# takes over once it is found, even after ROOM_PICK_S
	stand(0.4, -0.3)
	await boot([sofa_anchor, living_anchor])
	await tick(3)
	t.eq(room_name(), "Office", "while the living room is still being placed, only the office is found")
	await seconds(Board.ROOM_PICK_S + 1.0)
	anchors.slow.clear()
	await tick(3)
	t.eq(room_name(), "Living room", "the living room is found late and takes over: it is the one you stand in")
	t.check(board.frame_nodes[sofa.id].visible and not board.frame_nodes[desk.id].visible, "...with its canvas")

	await seconds(Board.ROOM_PICK_S + 0.5)
	t.eq(room_name(), "Living room", "settled in the living room")

	# ---- headset taken off in the living room and put back on in the office
	board.tracking_live = false
	anchors.blackout = true
	await seconds(1.0)
	stand(6.3, -0.2)
	anchors.blackout = false
	board.tracking_reset()
	board.tracking_live = true
	await tick(3)
	t.eq(room_name(), "Office", "headset put back on in the office: the office is shown")

	# ---- the user's own choice stays, even standing nearer to the other room
	board.select_room(living)
	await seconds(Board.ROOM_PICK_S + 1.0)
	t.eq(room_name(), "Living room", "a room picked in Home > Rooms stays picked")
	t.check(board.frame_nodes[sofa.id].visible, "...and its canvas is shown")
