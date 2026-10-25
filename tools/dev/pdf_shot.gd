extends Node3D
## Renders one page of a PDF with the viewer's own pipeline on the real GPU and saves it as a PNG (to compare with another renderer, or by eye):
##   godot --path . res://tools/dev/pdf_shot.tscn -- --pdf=file.pdf --out=page.png [--page=1] [--width=900] [--tier=low] [--zoom=2 --at=0.5,0.5]
## --zoom with --at looks at a part of the page (at is a fraction of the page from the left and from the top) to see how crisp the text is.

var _out := ""


func _ready() -> void:
	var opt := {"page": "1", "width": "900", "tier": "high", "zoom": "1", "at": "0.5,0.5"}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			opt[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	_out = str(opt.get("out", "page.png"))
	var bytes := FileAccess.get_file_as_bytes(str(opt.get("pdf", "")))
	var reader := PdfReader.open(bytes, PdfBudget.for_tier(str(opt.tier)))
	if not reader.ok():
		print("pdf_shot: cannot open: ", reader.error)
		get_tree().quit(1)
		return
	var index := clampi(int(opt.page) - 1, 0, reader.page_count - 1)
	var t0 := Time.get_ticks_msec()
	var data := reader.render(index)
	var ms := Time.get_ticks_msec() - t0
	print("pdf_shot: page %d of %d, %s pt, %d layers, %d triangles, %d glyphs, %d images, %d ms, unsupported %s" % [index + 1, reader.page_count, str(data.size),
		data.layers.size(), data.triangles(), int(data.stats.glyphs), int(data.stats.images), ms, str(data.stats.unsupported)])
	var width := int(opt.width)
	var aspect := data.size.y / data.size.x
	var zoom := float(opt.zoom)
	var win := Vector2i(width, int(width * aspect)) if zoom <= 1.0 else Vector2i(width, int(width * 0.75))
	get_window().size = win
	get_viewport().msaa_3d = Viewport.MSAA_4X
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.3, 0.3, 0.33)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var node := PdfPageNode.new()
	add_child(node)
	var mpp := 1.0 / data.size.x
	node.show_page(data, mpp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	var view_w := 1.0 / zoom
	cam.size = view_w * (float(win.y) / float(win.x)) if cam.keep_aspect == Camera3D.KEEP_WIDTH else view_w
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.size = view_w
	add_child(cam)
	var at := str(opt.at).split(",")
	var fx := float(at[0])
	var fy := float(at[1]) if at.size() > 1 else 0.5
	var sz := node.size_m()
	var cx := (fx - 0.5) * sz.x
	var cy := (0.5 - fy) * sz.y
	if zoom <= 1.0:
		cx = 0.0
		cy = 0.0
	cam.position = Vector3(cx, cy, 2.0)
	get_tree().create_timer(1.2).timeout.connect(_shot)


func _shot() -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out)
	print("pdf_shot: saved ", _out, " ", img.get_size())
	get_tree().quit()
