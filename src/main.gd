extends Node3D
## Entry point. In the headset (OpenXR started by the engine on Android) the XR rig runs; on the PC the desktop rig does.
## Development switches (after `--`): --demo  open the demo document;  --screenshot=PATH [--tab=NAME] [--type] [--frames=N] [--cam=x,y,z,yaw,pitch]
## saves a picture after N frames and quits (--tab: brush, shapes, write, add, ai, docs, canvas, rooms, share, settings, guide [--topic=ID], --welcome: as on the very first start, the guide opens on its own; --select=text|shape|stroke
## selects the first such item first);  --battery=NN[c]  shows a made-up battery level (c: charging).  --host[=NAME] [--session=TITLE] [--code=NNNN|none]  starts a
## session as soon as the room is found (--align then opens the card for lining up with the room);  --join=ADDRESS[:PORT] [--code=NNNN] [--guest=NAME] [--place=together|apart]  joins one (for trying a session with several copies on one PC; --tab=session shows it; together: in the owner's real room, so it waits to be lined up; apart, the default here: the board is put in front of it).  --share  starts the web server for the canvases (as the Docs tab's switch does); --share=nopin leaves out the access code (for scripts).  --pdf=FILE [--pdf-page=N]  takes a PDF into the library and puts it down in front of you;  --pdf-dir=DIR  keeps the PDF library there.  --model=FILE[,FILE...]  takes a 3D model (.glb, .gltf, .obj, .zip; an .obj's .mtl and pictures after it, comma-separated) into the library and puts it down in front of you, selected [--model-mode=move|rotate|scale|none];  --model-dir=DIR  keeps the model library there.

var board: Board
var rig: Node


func _ready() -> void:
	var args := _args()
	if args.has("docs-dir"):
		App.docs_dir = str(args["docs-dir"])
	if args.has("pdf-dir"):
		App.pdf_dir = str(args["pdf-dir"])
	if args.has("model-dir"):
		App.model_dir = str(args["model-dir"])
	if args.has("settings"):
		App.settings_path = str(args["settings"])
		App.reload()
	if args.has("battery"):
		Battery.set_fake(str(args["battery"]))
	var headset := _headset_active()
	App.xr_active = headset
	board = Board.new()
	add_child(board)
	var anchors: AnchorService
	if headset:
		var script: GDScript = load("res://src/xr/xr_rig.gd")
		rig = script.new()
		add_child(rig)
		anchors = rig.start(board)
	else:
		anchors = SimAnchors.new()
		add_child(anchors)
		rig = DesktopRig.new()
		add_child(rig)
	board.setup(anchors)
	if not headset:
		(rig as DesktopRig).setup(board)
	board.toast.connect(func(t: String): print("[board] ", t))
	_open_document(args)
	if args.has("welcome") or not (args.has("demo") or args.has("new") or args.has("screenshot") or args.has("host") or args.has("join")):
		(rig.get("ui") as UiShell).welcome()                # a real start: the first one shows the guide
	if args.has("host"):
		_host_later(args)
	if args.has("join"):
		_join_later(args)
	if not (args.has("host") or args.has("join") or args.has("demo") or args.has("new") or args.has("screenshot")):
		board.session.resume_saved()                     # the session this headset was in when the app stopped
	elif not (App.val("session_resume") as Dictionary).is_empty():
		print("[session] not going back to the saved session (a development switch was given)")
	if args.has("pdf"):
		_pdf_later(args)
	if args.has("model"):
		_model_later(args)
	if args.has("share"):
		board.share.require_pin = str(args["share"]) != "nopin"
		board.share.start()
		print("[share] code %s  %s" % [board.share.pin, ", ".join(board.share.urls())])
	if args.has("screenshot"):
		_screenshot_later(args)


func _args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var s := String(a).trim_prefix("--")
		var kv := s.split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return out


## --host: wait for the room to be found, then start the session.
func _host_later(args: Dictionary) -> void:
	for i in 600:
		await get_tree().process_frame
		if board.current_room != "":
			break
	var who := str(args.host) if str(args.host) != "1" else "Owner"
	var code := str(args.get("code", ""))
	var err := board.session.start_hosting(who, str(args.get("session", "")), code != "none")
	if err == OK and code.is_valid_int() and code.length() == 4:
		board.session.code = code
	print("[session] hosting: error %d, code %s, port %d, document \"%s\"" % [err, board.session.code, board.session.net.port, board.doc.name])
	if err == OK and args.has("align"):
		board.session.align_begin()


## --join: join a session at an address (the code and a name can be given too).
func _join_later(args: Dictionary) -> void:
	for i in 60:
		await get_tree().process_frame
	var target := str(args.join).split(":")
	var port := int(target[1]) if target.size() > 1 else Session.PORT
	var err := board.session.join(target[0], port, str(args.get("code", "")), str(args.get("guest", "Guest")), str(args.get("place", "apart")))
	print("[session] joining %s:%d as %s: error %d" % [target[0], port, board.session.place, err])


## --pdf: wait for the room to be found, then take the file into the library and put it down.
func _pdf_later(args: Dictionary) -> void:
	for i in 600:
		await get_tree().process_frame
		if board.current_room != "" or board.room_state == "unanchored":
			break
	var path := str(args.pdf)
	var res := board.pdfs.add(FileAccess.get_file_as_bytes(path), path.get_file())
	if not bool(res.ok):
		print("[pdf] %s: %s" % [path, str(res.message)])
		return
	var placed := board.place_pdf(str(res.id), int(args.get("pdf-page", "1")))
	print("[pdf] %s: %d pages, placed: %s" % [str(res.name), int(res.pages), str(placed.get("ok"))])


## --model: wait for the room to be found, then take the file(s) into the library and put the model down.
func _model_later(args: Dictionary) -> void:
	for i in 600:
		await get_tree().process_frame
		if board.current_room != "" or board.room_state == "unanchored":
			break
	var paths := str(args.model).split(",", false)
	var files := {}
	for p in paths:
		files[String(p).get_file()] = FileAccess.get_file_as_bytes(String(p))
	var res: Dictionary = board.models.add(files[paths[0].get_file()], paths[0].get_file()) if paths.size() == 1 else board.models.add_files(files, paths[0].get_file())
	if not bool(res.ok):
		print("[models] %s: %s" % [paths[0], str(res.message)])
		return
	var placed := board.place_model(str(res.id))
	if str(args.get("model-mode", "move")) == "none":
		board.model_ctl.deselect()                          # (a picture of the model alone)
	else:
		board.model_ctl.set_mode(str(args.get("model-mode", "move")))
	print("[models] %s: placed: %s %s" % [str(res.name), str(placed.get("ok")), ", ".join(res.get("notes", PackedStringArray()))])


func _headset_active() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


func _open_document(args: Dictionary) -> void:
	var doc: Document = null
	if args.has("demo"):
		doc = DemoDoc.build()
		doc.id = "demo-document"
		doc.save()
	elif args.has("new"):
		doc = DocStore.create_new("Sketch")
	else:
		var last := str(App.val("last_doc"))
		if last != "":
			doc = DocStore.open(last)
		if doc == null:
			var list := DocStore.list()
			if not list.is_empty():
				doc = DocStore.open(str(list[0].id))
		if doc == null:
			doc = DocStore.create_new()
	board.open(doc)


func _screenshot_later(args: Dictionary) -> void:
	if args.has("tab") and rig is DesktopRig:
		_show_tab((rig as DesktopRig).ui, str(args.tab))
	if args.has("topic") and rig is DesktopRig:
		(rig as DesktopRig).ui.home.guide_page.show_topic(str(args.topic))
	if args.has("cam") and rig is DesktopRig:
		var c := String(args.cam).split(",")
		var cam := (rig as DesktopRig).camera
		cam.position = Vector3(float(c[0]), float(c[1]), float(c[2]))
		(rig as DesktopRig)._yaw = deg_to_rad(float(c[3]))
		(rig as DesktopRig)._pitch = deg_to_rad(float(c[4]))
		(rig as DesktopRig)._apply_look()
	get_window().size = Vector2i(1500, 900)
	var frames := int(args.get("frames", "90"))
	for i in frames:
		await get_tree().process_frame
		if i == frames / 2 and args.has("type") and rig is DesktopRig:
			(rig as DesktopRig).ui.open_text_entry()
		if i == frames / 3 and args.has("select"):
			_select_kind(str(args.select))
	var img := get_viewport().get_texture().get_image()
	var path := String(args.screenshot)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("saved ", path)
	get_tree().quit()


func _show_tab(ui: UiShell, tab: String) -> void:
	match tab:
		"draw", "brush":
			ui.open_popover("brush")
		"shapes", "write", "add", "dictate":
			ui.open_popover(tab)
		"ai":
			ui.open_side("assistant")
		"more":
			ui.show_home("settings")
		_:
			ui.show_home(tab)


func _select_kind(kind: String) -> void:
	for it in board.doc.items.values():
		var item: Item = it
		var k := "text" if item.kind == Item.TEXT else ("stroke" if item.kind == Item.STROKE else "shape")
		if k == kind and board.doc.frames.has(item.frame):
			App.put("tool", "select")
			board.select_items([item.id], item.frame)
			return
