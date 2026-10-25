extends SceneTree
## Opens PDF files with the engine and says what is in them: godot --headless --path . -s tools/dev/pdf_probe.gd -- file.pdf [more.pdf]
## Used while developing the PDF viewer (nothing in src/ depends on it).

func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var bytes := FileAccess.get_file_as_bytes(path)
		var t0 := Time.get_ticks_msec()
		var doc := PdfDoc.open(bytes)
		var dt := Time.get_ticks_msec() - t0
		if not doc.ok():
			print("%s: ERROR %s  (%d ms)" % [path.get_file(), doc.error, dt])
			continue
		var n := doc.page_count()
		var pg := doc.page(0)
		var st := PdfStream.new()
		var contents: Variant = doc.res(pg.get("Contents"))
		var clen := 0
		if contents is PdfStream:
			clen = (contents as PdfStream).decode().size()
		elif contents is Array:
			for c in contents:
				var s: Variant = doc.res(c)
				if s is PdfStream:
					clen += (s as PdfStream).decode().size()
		print("%s: %d pages, box %s, rotate %s, first page content %d bytes, rebuilt=%s, encrypted=%s  (%d ms)" % [
			path.get_file(), n, str(pg.get("MediaBox")), str(pg.get("Rotate", 0)), clen, doc.rebuilt, doc.crypt != null, dt])
	quit()
