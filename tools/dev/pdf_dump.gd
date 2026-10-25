extends SceneTree
## Prints what is inside a PDF page: its decoded content stream and its resources (to see why a page does not draw as it should):
##   godot --headless --path . -s tools/dev/pdf_dump.gd -- file.pdf [page=1] [max_chars=4000] [obj=N]
## With obj=N the object N (a dictionary or a stream, decoded) is printed instead.

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var doc := PdfDoc.open(FileAccess.get_file_as_bytes(a[0]))
	if not doc.ok():
		print("cannot open: ", doc.error)
		quit()
		return
	var max_chars := 4000
	var page_no := 1
	var obj := -1
	for i in range(1, a.size()):
		if a[i].begins_with("obj="):
			obj = int(a[i].substr(4))
		elif a[i].begins_with("max="):
			max_chars = int(a[i].substr(4))
		elif a[i].is_valid_int():
			page_no = int(a[i])
	if obj >= 0:
		var o: Variant = doc.get_obj(obj)
		_show(o, max_chars)
		quit()
		return
	var pg := doc.page(page_no - 1)
	print("PAGE ", page_no, " of ", doc.page_count(), ": ", _short(pg))
	var c: Variant = doc.res(pg.get("Contents"))
	var bytes := PackedByteArray()
	if c is PdfStream:
		bytes = (c as PdfStream).decode()
	elif c is Array:
		for x in c:
			var s := doc.d_stream(x)
			if s != null:
				bytes.append_array(s.decode())
				bytes.append(10)
	print("--- content (", bytes.size(), " bytes)")
	print(bytes.get_string_from_ascii().left(max_chars))
	print("--- resources")
	var res := doc.d_dict(pg.get("Resources"))
	for k in res:
		print(k, ": ", _short(doc.res(res[k])))
		var sub := doc.d_dict(res[k])
		if k in ["ExtGState", "XObject", "Shading", "Pattern", "Font", "ColorSpace"]:
			for n in sub:
				print("    ", n, " = ", _short(doc.res(sub[n])))
	quit()


func _short(v: Variant) -> String:
	if v is PdfStream:
		return "STREAM " + _short((v as PdfStream).dict)
	if v is Dictionary:
		var parts: Array = []
		for k in v:
			parts.append("/%s %s" % [k, _short(v[k])])
		var s := "<< " + " ".join(parts) + " >>"
		return s.left(400)
	if v is Array:
		var items: Array = []
		for x in (v as Array).slice(0, 12):
			items.append(_short(x))
		return "[" + " ".join(items) + ("..." if (v as Array).size() > 12 else "") + "]"
	if v is PackedByteArray:
		return "(" + (v as PackedByteArray).get_string_from_ascii().left(40) + ")"
	if typeof(v) == TYPE_VECTOR2I:
		return "%d R" % (v as Vector2i).x
	return str(v)


func _show(o: Variant, max_chars: int) -> void:
	print(_short(o))
	if o is PdfStream:
		var bytes := (o as PdfStream).decode()
		print("--- stream (", bytes.size(), " bytes, image filter '", (o as PdfStream).image_filter(), "')")
		print(bytes.get_string_from_ascii().left(max_chars))
