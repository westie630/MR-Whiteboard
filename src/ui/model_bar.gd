class_name ModelBar
extends FloatPanel
## The bar of the selected 3D model: it stands at the model's front edge, on your side, under the model (or on top of it when the model is
## low, on a table or the floor), and turns to face you as you walk round. It offers:
##   Move / Rotate / Scale   which handles the model shows (ModelGizmo)
##   Snap                    centimetre steps, 15 degree turns
##   Room axes               Move and Rotate along the room's axes (up is up) instead of the model's own
##   Put down                it comes down until it stands on the surface under it (a table, the floor)
##   Real size               the size the file says, in metres (glTF files are in metres)
##   Reset                   upright, not stretched, its first size
##   Duplicate, lock its place, delete, and close (let go of the model)
## Under the buttons: its name, its size in the room and, while a handle is held, what the handle is doing.

const GAP := 0.06                          # metres between the model's box and the bar

var _info: Label
var _sig := ""


func _init() -> void:
	super()
	id = "model"
	kind = "canvas"
	pivot = Vector2(0.5, 0.0)
	max_size = Vector2(1000, 200)
	ppm = 1500.0
	add_theme_stylebox_override("panel", UITheme.glass(30, 6.0))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	col.add_child(row)
	for m in [["move", "move", "Move: arrows slide it along an axis, squares in a plane, the ball anywhere"],
			["rotate", "rotate", "Rotate: a ring turns it about its axis"],
			["scale", "scale", "Scale: a corner cube resizes it, an axis cube stretches it along that axis"]]:
		var mode: String = m[0]
		var b := _tool(str(m[1]), str(m[2]), func(): _ctl().set_mode(mode))
		row.add_child(b)
		_kit.syncers.append(func(): b.on = _ctl().mode == mode)
	UiKit.divider(row)
	var sn := _tool("magnet", "Snap: centimetre steps, 15 degree turns", func(): _ctl().set_snap(not _ctl().snap))
	row.add_child(sn)
	_kit.syncers.append(func(): sn.on = _ctl().snap)
	var ax := _tool("axes", "Room axes: move and turn along the room (up is up). Off: along the model's own axes", func():
		_ctl().set_space("local" if _ctl().space == "room" else "room"))
	row.add_child(ax)
	_kit.syncers.append(func(): ax.on = _ctl().space == "room")
	UiKit.divider(row)
	row.add_child(_tool("lay_down", "Put it down on the surface under it (a table, or the floor)", func(): _board().lay_down_model(_ctl().selected)))
	row.add_child(_tool("ruler", "Real size: as big as the file says, in metres", func(): _board().real_size_model(_ctl().selected)))
	row.add_child(_tool("reset", "Reset: upright, not stretched, its first size", func(): _board().reset_model(_ctl().selected)))
	UiKit.divider(row)
	row.add_child(_tool("copy", "Duplicate", func(): _board().duplicate_model(_ctl().selected)))
	var pl := _tool("lock_place", "Lock its place: it stays where it is, facing the same way (it can still be resized)", func():
		var f := _ctl().selected_frame()
		if f != null:
			_board().set_frame_prop(f.id, "place_locked", not f.place_locked))
	row.add_child(pl)
	_kit.syncers.append(func():
		var f := _ctl().selected_frame()
		pl.on = f != null and f.place_locked)
	row.add_child(_tool("trash", "Delete (undo brings it back)", func():
		var fid := _ctl().selected
		_ctl().deselect()
		_board().delete_frame(fid)
		_board().toast.emit("Model deleted: undo brings it back.")))
	UiKit.divider(row)
	row.add_child(_tool("close", "Done: let go of the model", func(): _ctl().deselect()))
	_info = UiKit.label("", true, UITheme.FONT_TINY)
	_info.autowrap_mode = TextServer.AUTOWRAP_OFF
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_info)


func _tool(icon: String, hint: String, cb: Callable) -> Btn:
	return UiKit.tool(icon, hint, cb, 46.0)


func _board() -> Board:
	return shell.board


func _ctl() -> ModelController:
	return shell.board.model_ctl


## Where it goes: at the selected model's edge nearest you, under it (or on top of it when the model is low), facing you. False when no model
## is selected or it is not in view.
func place_for(board: Board) -> bool:
	var mn: ModelNode = board.model_nodes.get(board.model_ctl.selected)
	if mn == null or not mn.visible:
		return false
	var c := mn.global_position
	var head := board.head.origin
	var to_head := Vector3(head.x - c.x, 0.0, head.z - c.z)
	to_head = to_head.normalized() if to_head.length() > 0.05 else Vector3.BACK
	var low := INF
	var high := -INF
	var reach := 0.0
	for p in mn.corners():
		var q := p as Vector3
		low = minf(low, q.y)
		high = maxf(high, q.y)
		reach = maxf(reach, (q - c).dot(to_head))
	var at := c + to_head * (reach + GAP)
	if low - board.floor_y() > 0.45:
		at.y = low - GAP
		pivot = Vector2(0.5, 0.0)                        # hangs under the model
	else:
		at.y = high + GAP
		pivot = Vector2(0.5, 1.0)                        # stands on top of it
	anchor = {"world": Transform3D(Basis(Vector3.UP, atan2(to_head.x, to_head.z)), at)}
	return true


func refresh() -> void:
	if shell == null or shell.board.doc == null:
		return
	var b: Board = shell.board
	var f := _ctl().selected_frame()
	var text := ""
	if f != null:
		var mn: ModelNode = b.model_nodes.get(f.id)
		var size := ModelController.size_text(f.model_size()) if f.model_measured() else "measuring..."
		text = "%s  -  %s" % [f.name, size]
		if mn != null and mn.state == "ready" and mn.triangles > 0:
			text += "  -  %s triangles" % ModelLoader.count_text(mn.triangles)
		elif mn != null and mn.note != "":
			text += "  -  " + mn.note
		if _ctl().readout != "":
			text = _ctl().readout
	_info.text = text
	_kit.sync()


func _process(delta: float) -> void:
	super(delta)
	if visible and shell != null:
		var sig := _ctl().readout + _ctl().selected
		if sig != _sig:
			_sig = sig
			refresh()
