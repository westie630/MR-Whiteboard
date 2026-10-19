extends Node3D
## Renders the demo document on the real GPU and saves screenshots (the headless renderer cannot):
##   godot --path . res://tools/dev/render_demo.tscn -- build/shots
## Used to check shaders, meshes and layout by eye.

var _shots := 0
var _out := "res://build/shots"
var _name := "demo"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	get_window().size = Vector2i(1400, 800)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.1, 0.13)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var doc := DemoDoc.build()
	for f in doc.frames.values():
		var fn := FrameNode.new()
		add_child(fn)
		fn.setup(f, doc)
		fn.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * (f as FrameData).scale), (f as FrameData).xf.origin)
		if (f as FrameData).kind == FrameData.CANVAS:
			fn.set_focus(Vector3(0.1, 0.1, 0), 1.0)
			fn.set_hover(0.0)
		else:
			fn.set_hover(0.5)
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 60
	cam.position = Vector3(0.45, 1.3, 1.0)
	var look := Vector3(0.45, 1.25, -1.2)
	var a := OS.get_cmdline_user_args()      # out_dir cam_x cam_y cam_z look_x look_y look_z fov name
	if a.size() >= 8:
		cam.position = Vector3(float(a[1]), float(a[2]), float(a[3]))
		look = Vector3(float(a[4]), float(a[5]), float(a[6]))
		cam.fov = float(a[7])
	if a.size() >= 9:
		_name = a[8]
	cam.look_at(look)
	get_tree().create_timer(1.0).timeout.connect(_shot)


func _shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var p := ProjectSettings.globalize_path(_out) + "/" + _name + ".png"
	img.save_png(p)
	print("saved ", p)
	get_tree().quit()
