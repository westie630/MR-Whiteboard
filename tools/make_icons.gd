extends SceneTree
## Renders the logo (assets/icon_bg.svg, icon_fg.svg, icon_mono.svg) into every icon the app needs, sharp at each size:
##   godot --headless --path . -s tools/make_icons.gd
## Writes assets/icons/*.png, a multi-size Windows icon (assets/icons/app.ico) and the project icon (icon.svg).

const OUT := "res://assets/icons"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var bg := FileAccess.get_file_as_string("res://assets/icon_bg.svg")
	var fg := FileAccess.get_file_as_string("res://assets/icon_fg.svg")
	var mono := FileAccess.get_file_as_string("res://assets/icon_mono.svg")

	# Android adaptive icon layers (432 px; the logo sits inside the central 66 % safe zone)
	_save(_render(bg, 432, 432), "adaptive_background_432.png")
	_save(_render_padded(fg, 432, 0.70), "adaptive_foreground_432.png")
	_save(_render_padded(mono, 432, 0.70), "adaptive_monochrome_432.png")

	# the full rounded-square icon at every size
	var sizes := [16, 24, 32, 48, 64, 96, 128, 192, 256, 512, 1024]
	var full := {}
	for s in sizes:
		var img := _full_icon(bg, fg, s)
		full[s] = img
		if s in [192, 512, 1024]:
			_save(img, "icon_%d.png" % s)
	_write_ico([16, 24, 32, 48, 64, 128, 256], full)

	# launcher icon for the Quest library (192 px) and the VR splash
	_save(full[192], "launcher_192.png")
	_save(_splash(bg, fg), "vr_splash.png")

	# the project / editor icon as a vector
	var svg := _combined_svg(bg, fg)
	var f := FileAccess.open("res://icon.svg", FileAccess.WRITE)
	f.store_string(svg)
	f.close()
	print("icons written to ", ProjectSettings.globalize_path(OUT))
	quit()


func _render(svg: String, w: int, h: int) -> Image:
	var img := Image.new()
	var scale := float(w) / 512.0
	var err := img.load_svg_from_string(svg, scale)
	if err != OK:
		push_error("svg render failed: %d" % err)
	img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != w or img.get_height() != h:
		img.resize(w, h, Image.INTERPOLATE_LANCZOS)
	return img


## Render a layer smaller than its canvas (so it sits inside an adaptive icon's safe zone).
func _render_padded(svg: String, size: int, fraction: float) -> Image:
	var inner := int(size * fraction)
	var layer := _render(svg, inner, inner)
	var out := Image.create(size, size, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	out.blend_rect(layer, Rect2i(0, 0, inner, inner), Vector2i((size - inner) / 2, (size - inner) / 2))
	return out


## The rounded-square app icon: background and foreground layers, corners cut to a squircle-like radius.
func _full_icon(bg: String, fg: String, size: int) -> Image:
	# render at 2x and downsample for the smoothest edges at small sizes
	var ss := size * 2 if size <= 256 else size
	var base := _render(bg, ss, ss)
	var top := _render(fg, ss, ss)
	base.blend_rect(top, Rect2i(0, 0, ss, ss), Vector2i.ZERO)
	var r := int(ss * 0.2)
	for y in ss:
		for x in ss:
			var a := _corner_alpha(x, y, ss, r)
			if a < 1.0:
				var c := base.get_pixel(x, y)
				c.a *= a
				base.set_pixel(x, y, c)
	if ss != size:
		base.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return base


func _corner_alpha(x: int, y: int, s: int, r: int) -> float:
	var cx := clampf(float(x) + 0.5, float(r), float(s - r))
	var cy := clampf(float(y) + 0.5, float(r), float(s - r))
	var d := Vector2(float(x) + 0.5 - cx, float(y) + 0.5 - cy).length()
	return clampf(float(r) - d + 0.5, 0.0, 1.0)


## Just the mark (brackets and M) on a transparent canvas: no tile behind it (project.godot's boot_splash/bg_color shows through).
func _splash(_bg: String, fg: String) -> Image:
	var size := 1024
	var icon_size := 640
	var icon := _render(fg, icon_size, icon_size)
	var out := Image.create(size, size, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	var at := (size - icon_size) / 2
	out.blend_rect(icon, Rect2i(0, 0, icon_size, icon_size), Vector2i(at, at))
	return out


func _save(img: Image, file: String) -> void:
	img.save_png(ProjectSettings.globalize_path(OUT) + "/" + file)


## Windows .ico with PNG-compressed images (Vista and later).
func _write_ico(sizes: Array, full: Dictionary) -> void:
	var pngs: Array = []
	for s in sizes:
		var img: Image = full[s] if full.has(s) else _full_icon(FileAccess.get_file_as_string("res://assets/icon_bg.svg"), FileAccess.get_file_as_string("res://assets/icon_fg.svg"), s)
		pngs.append(img.save_png_to_buffer())
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_16(0)
	buf.put_16(1)
	buf.put_16(sizes.size())
	var offset := 6 + 16 * sizes.size()
	for i in sizes.size():
		var s: int = sizes[i]
		buf.put_8(0 if s >= 256 else s)
		buf.put_8(0 if s >= 256 else s)
		buf.put_8(0)
		buf.put_8(0)
		buf.put_16(1)
		buf.put_16(32)
		buf.put_32((pngs[i] as PackedByteArray).size())
		buf.put_32(offset)
		offset += (pngs[i] as PackedByteArray).size()
	for p in pngs:
		buf.put_data(p)
	var f := FileAccess.open(OUT + "/app.ico", FileAccess.WRITE)
	f.store_buffer(buf.data_array)
	f.close()


## One vector icon (rounded square with both layers) for icon.svg.
func _combined_svg(bg: String, fg: String) -> String:
	var bg_body := _inner(bg)
	var fg_body := _inner(fg)
	return '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">\n<defs>\n<clipPath id="round"><rect width="512" height="512" rx="102"/></clipPath>\n%s\n</defs>\n<g clip-path="url(#round)">%s</g>\n%s\n</svg>\n' % [_defs(bg) + _defs(fg), bg_body, fg_body]


func _defs(svg: String) -> String:
	var a := svg.find("<defs>")
	var b := svg.find("</defs>")
	return svg.substr(a + 6, b - a - 6) if a >= 0 else ""


func _inner(svg: String) -> String:
	var b := svg.find("</defs>")
	var start := b + 7 if b >= 0 else svg.find(">") + 1
	return svg.substr(start, svg.rfind("</svg>") - start)
