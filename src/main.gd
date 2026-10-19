extends Node3D
## Entry point. In the headset (OpenXR started by the engine on Android) the XR rig runs; on the PC the desktop rig does.
## Development switches (after `--`): --demo  open the demo document;  --screenshot=PATH [--tab=NAME] [--type] [--frames=N] [--cam=x,y,z,yaw,pitch]
## saves a picture after N frames and quits.

var board: Board
var rig: Node


func _ready() -> void:
	var args := _args()
	if args.has("docs-dir"):
		App.docs_dir = str(args["docs-dir"])
	if args.has("settings"):
		App.settings_path = str(args["settings"])
		App.reload()
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
	if args.has("screenshot"):
		_screenshot_later(args)


func _args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var s := String(a).trim_prefix("--")
		var kv := s.split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return out


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
	if args.has("tab"):
		App.put("menu_tab", str(args.tab))
		if rig is DesktopRig and (rig as DesktopRig).menu != null:
			(rig as DesktopRig).menu._select_tab(str(args.tab))
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
			(rig as DesktopRig).menu.open_text_entry()
	var img := get_viewport().get_texture().get_image()
	var path := String(args.screenshot)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("saved ", path)
	get_tree().quit()
