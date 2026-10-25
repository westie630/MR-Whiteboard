extends Node
## The PDF engine, piece by piece: reading objects, the filters, decryption, the document (cross-reference, damaged files, encrypted files), fonts
## against the engine's own font reader, the geometry (two independent ways of filling an outline must agree), strokes, the interpreter on small
## hand-made pages, shadings, images, soft masks (the little rasteriser, the baked masks), transparency groups, function-based gradients, clips that are
## unions, page rotation, and the budget of a Quest 2 against a Quest 3's. If the folder named by the environment
## variable MRW_PDF_CORPUS exists, the first page of every PDF in it is also made (a crash or a hang there is a failure).

const FIX := "res://tests/fixtures/pdf/"

var t := TestCase.new("pdf_engine")


func _ready() -> void:
	_lexer()
	_filters()
	_crypto()
	_documents()
	_fonts()
	_geometry()
	_strokes()
	_interpreter()
	_shadings()
	_images()
	_fax()
	_rasters()
	_soft_masks()
	_groups_and_textures()
	_meshes()
	_text_clips()
	_blends()
	_tiling_state()
	_clip_union()
	_budget()
	_corpus()
	get_tree().quit(t.done())


func _bytes(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(FIX + name)


# ------------------------------------------------------------------------------------------------ objects

func _lexer() -> void:
	var src := "<< /Type /Page /Count 3 /Kids [1 0 R 2 0 R] /S (a\\(b\\)c\\101\\n(x)) /H <48656C6C6F> /N#20x 1.5 /neg -.5 /t true /n null % comment\n /Big 123456 >>"
	var d: Dictionary = PdfLex.new(src.to_utf8_buffer()).object()
	t.check(typeof(d.get("Type")) == TYPE_STRING_NAME and d.Type == &"Page", "a name is a StringName")
	t.eq(d.Count, 3, "an integer")
	t.eq(d.Kids, [Vector2i(1, 0), Vector2i(2, 0)], "references are Vector2i")
	t.eq((d.S as PackedByteArray).get_string_from_ascii(), "a(b)cA\n(x)", "a string with escapes, octal and nested brackets")
	t.eq((d.H as PackedByteArray).get_string_from_ascii(), "Hello", "a hex string")
	t.check(d.has("N x") and is_equal_approx(float(d["N x"]), 1.5), "a name with #20 is a key with a space")
	t.near(d.neg, -0.5, 1e-9, "-.5")
	t.check(d.t == true and d.n == null and d.Big == 123456, "true, null and a comment skipped")
	var lex := PdfLex.new("+17 -98 0.0 4. .002 1.5-3 12abc".to_utf8_buffer())
	var got: Array = []
	for i in 7:
		got.append(lex.next())
	t.check(got[0] == 17 and got[1] == -98 and is_equal_approx(got[2], 0.0) and is_equal_approx(got[3], 4.0) and is_equal_approx(got[4], 0.002), "numbers: %s" % str(got))
	t.check(typeof(got[5]) == TYPE_FLOAT and is_equal_approx(got[5], 1.5) and got[6] == -3, "1.5-3 is 1.5 and then -3")
	var ops := PdfLex.new("0 0 m BT /F1 12 Tf (x) Tj ET".to_utf8_buffer())
	var seen: Array = []
	while true:
		var tok: Variant = ops.next()
		if typeof(tok) == TYPE_STRING_NAME and tok == PdfLex.END:
			break
		seen.append(tok)
	t.check(typeof(seen[2]) == TYPE_STRING and seen[2] == "m" and typeof(seen[4]) == TYPE_STRING_NAME, "operators are Strings, names StringNames")


# ------------------------------------------------------------------------------------------------ filters

func _filters() -> void:
	var lzw := PdfFilters.lzw(PackedByteArray([0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01]), {})
	t.eq(Array(lzw), [45, 45, 45, 45, 45, 65, 45, 45, 45, 66], "LZW: the example of the specification")
	t.eq(PdfFilters.ascii85("9jqo^~>".to_utf8_buffer()).get_string_from_ascii(), "Man ", "ASCII85")
	t.eq(PdfFilters.ascii85("<~87cURD]i,\"Ebo7~>".to_utf8_buffer()).get_string_from_ascii(), "Hello World", "ASCII85 with its marks, and a short last group")
	t.eq(PdfFilters.ascii_hex("48 65 6C6c 6F>".to_utf8_buffer()).get_string_from_ascii(), "Hello", "ASCIIHex")
	t.eq(PdfFilters.run_length(PackedByteArray([2, 65, 66, 67, 254, 68, 128])).get_string_from_ascii(), "ABCDDD", "RunLength")
	# PNG predictors
	var png := PackedByteArray([0, 1, 2, 3, 2, 1, 1, 1, 1, 5, 1, 1, 4, 0, 0, 0])
	var out := PdfFilters.predict(png, {"Predictor": 15, "Colors": 1, "BitsPerComponent": 8, "Columns": 3})
	t.eq(Array(out), [1, 2, 3, 2, 3, 4, 5, 6, 7, 5, 6, 7], "PNG predictors: none, up, sub, paeth")
	# the eight-bytes-at-a-time Up filter against a plain loop
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var row := 29
	var rows := 6
	var raw := PackedByteArray()
	for r in rows:
		raw.append(2 if r > 0 else 0)
		for i in row:
			raw.append(rng.randi() & 255)
	var want := PackedByteArray()
	want.resize(rows * row)
	for r in rows:
		for i in row:
			var prev := want[(r - 1) * row + i] if r > 0 else 0
			want[r * row + i] = (raw[r * (row + 1) + 1 + i] + prev) & 255
	t.check(PdfFilters.predict(raw, {"Predictor": 12, "Colors": 1, "BitsPerComponent": 8, "Columns": row}) == want, "PNG up filter, eight bytes at a time, agrees with the plain loop")
	var tiff := PdfFilters.predict(PackedByteArray([10, 5, 5, 1, 1, 1]), {"Predictor": 2, "Colors": 1, "BitsPerComponent": 8, "Columns": 3})
	t.eq(Array(tiff), [10, 15, 20, 1, 2, 3], "the TIFF predictor")
	# Flate: whole, with a stray byte after it (the engine's decompress_dynamic dies on that), cut short
	var text := ""
	for i in 3000:
		text += "line %d of some text that repeats and varies %d\n" % [i, i * 7 % 13]
	var plain := text.to_utf8_buffer()
	var z := plain.compress(FileAccess.COMPRESSION_DEFLATE)
	t.check(PdfFilters.flate(z) == plain, "Flate")
	var stray := z.duplicate()
	stray.append(10)
	t.check(PdfFilters.flate(stray) == plain, "Flate with a newline after the data")
	var cut := PdfFilters.flate(z.slice(0, z.size() - 40))
	t.check(cut.size() > 1000 and cut == plain.slice(0, cut.size()), "Flate cut short: what could be read (%d of %d bytes)" % [cut.size(), plain.size()])
	t.check(PdfInflate.inflate(z, true) == plain, "the plain-script inflate agrees (dynamic Huffman codes)")
	var stored := PackedByteArray([0x78, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFF, 72, 101, 108, 108, 111])
	t.eq(PdfInflate.inflate(stored, true).get_string_from_ascii(), "Hello", "a stored block")
	t.check(PdfFilters.flate(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])).is_empty(), "garbage is not Flate")


func _crypto() -> void:
	var abc := "abc".to_utf8_buffer()
	t.eq(PdfSha512.hash(abc, false).hex_encode(), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "SHA-512")
	t.eq(PdfSha512.hash(abc, true).hex_encode(), "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "SHA-384")
	t.eq(PdfSha512.hash(PackedByteArray(), false).hex_encode().left(32), "cf83e1357eefb8bdf1542850d66d8007", "SHA-512 of nothing")
	var long := "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".to_utf8_buffer()
	t.eq(PdfSha512.hash(long, false).hex_encode().left(32), "8e959b75dae313da8cf4f72814fc143f", "SHA-512 over two blocks")
	t.eq(PdfCrypt.rc4("Key".to_utf8_buffer(), "Plaintext".to_utf8_buffer()).hex_encode(), "bbf316e8d940af0ad3", "RC4")


# ------------------------------------------------------------------------------------------------ documents

func _documents() -> void:
	var base := PdfDoc.open(_bytes("base14.pdf"))
	t.check(base.ok() and base.page_count() == 2 and not base.rebuilt, "a PDF opens: 2 pages")
	var content := base.d_stream(base.page(0).get("Contents")).decode()
	t.check(content.size() > 100 and content.get_string_from_ascii().contains("Tj"), "its content stream is text operators")
	for n in ["rc4_128.pdf", "aes_128.pdf", "aes_256.pdf"]:
		var enc := PdfDoc.open(_bytes(n))
		t.check(enc.ok() and enc.crypt != null and enc.page_count() == 2, "%s opens (the user password is empty)" % n)
		var c2 := enc.d_stream(enc.page(0).get("Contents"))
		t.check(c2 != null and c2.decode() == content, "%s: its content is the same as the unprotected file's" % n)
	var locked := PdfDoc.open(_bytes("locked.pdf"))
	t.check(not locked.ok() and locked.error.contains("password"), "a PDF that wants a password is refused: %s" % locked.error)
	var nox := PdfDoc.open(_bytes("no_xref.pdf"))
	t.check(nox.ok() and nox.rebuilt and nox.page_count() == 2, "without its cross-reference table it is read by scanning")
	var many := PdfDoc.open(_bytes("many.pdf"))
	t.check(many.ok() and many.page_count() == 30 and many.page(29).has("MediaBox"), "30 pages, each with its box")
	t.check(not PdfDoc.open("hello".to_utf8_buffer()).ok(), "something that is not a PDF is refused")
	t.check(not PdfDoc.open("%PDF-1.4\n garbage".to_utf8_buffer()).ok(), "a PDF with nothing in it is refused")
	var stray := PdfDoc.open(_bytes("stray_byte.pdf"))
	var sc := stray.d_stream(stray.page(0).get("Contents"))
	t.check(stray.ok() and sc != null and sc.decode().get_string_from_ascii().contains("re f"), "a Flate stream with a stray byte is read")
	# inherited page attributes
	var tree := "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 50] /Rotate 90 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n4 0 obj\n<< /Type /Page /Parent 2 0 R /Rotate 0 >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n"
	var td := PdfDoc.open(tree.to_utf8_buffer())
	t.check(td.ok() and td.page_count() == 2 and td.page(0).Rotate == 90 and td.page(1).Rotate == 0 and td.d_nums(td.page(1).MediaBox)[2] == 100.0, "MediaBox and Rotate are inherited from the page tree")


# ------------------------------------------------------------------------------------------------ fonts

func _fonts() -> void:
	var ts := TextServerManager.get_primary_interface()
	var ff: FontFile = load("res://assets/pdf_fonts/LiberationSans-Regular.ttf")
	var f := PdfFontTtf.parse(ff.data)
	t.check(f.ok and f.num_glyphs > 2000 and f.units_per_em == 2048.0, "TrueType: Liberation Sans reads (%d glyphs)" % f.num_glyphs)
	var rid: RID = ff.get_rids()[0]
	var same := 0
	var total := 0
	for ch in range(32, 800):
		var mine := f.gid_for_unicode(ch)
		var theirs := ts.font_get_glyph_index(rid, 16, ch, 0)
		total += 1
		if mine == theirs:
			same += 1
	t.eq(same, total, "the character map agrees with the engine's own for all %d characters" % total)
	var gid_a := f.gid_for_unicode(ord("A"))
	t.near(f.advance(gid_a), 1366.0 / 2048.0, 0.0005, "the advance of A is Helvetica's 0.667 em")
	t.near(f.advance(f.gid_for_unicode(ord("i"))), 455.0 / 2048.0, 0.0005, "and of i")
	var o_path := f.glyph_path(f.gid_for_unicode(ord("o"))).flatten(Transform2D.IDENTITY, 2.0)
	t.eq((o_path[0] as Array).size(), 2, "an o has two contours")
	var area_o := 0.0
	for c in o_path[0]:
		area_o += PdfGeom.area(c)
	t.check(absf(area_o) > 100000.0 and absf(area_o) < 700000.0, "and a sensible area")
	t.check(f.glyph_path(f.gid_for_unicode(ord(" "))).is_empty(), "a space has no outline")
	var acc := f.glyph_path(f.gid_for_unicode(0xC5))                  # Å: a composite glyph
	t.check(not acc.is_empty() and (acc.flatten(Transform2D.IDENTITY, 2.0)[0] as Array).size() >= 3, "a composite glyph (Å) is put together")
	# a font inside a PDF: loaded as the page names it
	var doc := PdfDoc.open(_bytes("embedded.pdf"))
	var fonts := doc.d_dict(doc.d_dict(doc.page(0).get("Resources")).get("Font"))
	var cache := {}
	var embedded := 0
	for k in fonts:
		var font := PdfFont.load_font(doc, fonts[k], cache)
		if font.substituted:
			continue
		embedded += 1
		t.check(font.program != null and font.program is PdfFontTtf, "%s: its own font file is used" % str(font.base_font))
		var g := font.decode("Affe".to_utf8_buffer())
		t.check(g.size() == 4 and int(g[0].gid) > 0 and float(g[0].w) > 0.3, "%s: a string is cut into glyphs with their widths" % str(font.base_font))
	t.eq(embedded, 2, "the embedded fixture carries two fonts")
	# a font that is not carried is replaced by one of the same widths
	var b14 := PdfDoc.open(_bytes("base14.pdf"))
	var bf := b14.d_dict(b14.d_dict(b14.page(0).get("Resources")).get("Font"))
	var helv := PdfFont.load_font(b14, bf[bf.keys()[0]], {})
	t.check(helv.substituted and helv.program is PdfFontTtf, "Helvetica without its file gets a stand-in")
	var gl := helv.decode("H".to_utf8_buffer())
	t.near(float(gl[0].w), 722.0 / 1000.0, 0.002, "with Helvetica's own width for H (0.722)")
	var std := PdfStdFonts.classify("ABCDEF+Arial-BoldMT", 0)
	t.check(std.family == PdfStdFonts.SANS and std.bold and not std.italic, "Arial Bold is the bold sans")
	t.check(PdfStdFonts.classify("TimesNewRoman,Italic", 0).family == PdfStdFonts.SERIF and PdfStdFonts.classify("CourierNewPSMT", 0).family == PdfStdFonts.MONO, "Times is serif, Courier mono")
	t.eq(PdfGlyphList.unicode_of("Aacute"), 0xC1, "the glyph list: Aacute")
	t.check(PdfGlyphList.unicode_of("uni20AC") == 0x20AC and PdfGlyphList.unicode_of("f_i") == ord("f") and PdfGlyphList.unicode_of("a.sc") == ord("a"), "uniXXXX, ligature parts and suffixes")
	t.check(PdfEncodings.WIN_ANSI[0x80] == "Euro" and PdfEncodings.STANDARD[0x27] == "quoteright" and PdfEncodings.MAC_ROMAN[0x8A] == "adieresis", "the predefined encodings")


# ------------------------------------------------------------------------------------------------ geometry

func _geometry() -> void:
	# many glyphs: the quick triangulation and the sweep that handles anything must give the same area
	var worst := 0.0
	var checked := 0
	for nm in ["LiberationSans-Regular", "LiberationSerif-Italic", "LiberationMono-Bold"]:
		var ff: FontFile = load("res://assets/pdf_fonts/%s.ttf" % nm)
		var f := PdfFontTtf.parse(ff.data)
		for g in range(1, 700, 3):
			var path := f.glyph_path(g)
			if path.is_empty():
				continue
			var contours: Array = path.flatten(Transform2D.IDENTITY, 2.0)[0]
			var a := PdfSynth.soup_area(PdfGeom.fill(contours, false))
			var b := PdfSynth.soup_area(PdfGeom._slab(contours, false))
			worst = maxf(worst, absf(a - b) / maxf(b, 1.0))
			checked += 1
	t.check(checked > 400 and worst < 1e-5, "two ways of filling agree on %d glyphs of three fonts (worst difference %s)" % [checked, str(worst)])
	# an H as one outline (every vertex on a straight line: the ear test must not cut across the notches)
	var h := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 12), Vector2(20, 12), Vector2(20, 0), Vector2(30, 0), Vector2(30, 30), Vector2(20, 30), Vector2(20, 18), Vector2(10, 18), Vector2(10, 30), Vector2(0, 30)])
	t.near(PdfSynth.soup_area(PdfGeom.fill([h], false)), 660.0, 1e-6, "an H is 660 square units")
	# holes, nesting and the two rules
	var outer := PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 40), Vector2(0, 40)])
	var hole := PackedVector2Array([Vector2(10, 10), Vector2(10, 30), Vector2(30, 30), Vector2(30, 10)])
	var inner := PackedVector2Array([Vector2(15, 15), Vector2(25, 15), Vector2(25, 25), Vector2(15, 25)])
	t.near(PdfSynth.soup_area(PdfGeom.fill([outer, hole], false)), 1200.0, 1e-6, "a square with a square hole (opposite ways round)")
	t.near(PdfSynth.soup_area(PdfGeom.fill([outer, hole, inner], false)), 1300.0, 1e-6, "and an island in the hole")
	var same_way := PackedVector2Array([Vector2(10, 10), Vector2(30, 10), Vector2(30, 30), Vector2(10, 30)])
	t.near(PdfSynth.soup_area(PdfGeom.fill([outer, same_way], false)), 1600.0, 1e-6, "non-zero: an inner square the same way round is no hole")
	t.near(PdfSynth.soup_area(PdfGeom.fill([outer, same_way], true)), 1200.0, 1e-6, "even-odd: it is")
	var star := PackedVector2Array()
	for k in 5:
		var an := -PI / 2.0 + k * TAU * 2.0 / 5.0
		star.append(Vector2(cos(an), sin(an)) * 10.0)
	var nz := PdfSynth.soup_area(PdfGeom.fill([star], false))
	var eo := PdfSynth.soup_area(PdfGeom.fill([star], true))
	t.check(nz > eo * 1.3 and absf(nz - 112.26) < 0.1 and absf(eo - 77.57) < 0.1, "a pentagram: %.2f (non-zero) and %.2f (even-odd)" % [nz, eo])
	var r1 := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 30), Vector2(0, 30)])
	var r2 := PackedVector2Array([Vector2(20, 0), Vector2(30, 0), Vector2(30, 30), Vector2(20, 30)])
	var r3 := PackedVector2Array([Vector2(0, 12), Vector2(30, 12), Vector2(30, 18), Vector2(0, 18)])
	t.near(PdfSynth.soup_area(PdfGeom.fill([r1, r2, r3], false)), 660.0, 1e-6, "overlapping rectangles are counted once")
	# a ring whose hole touches nothing, with many edges (the grid that looks for crossings)
	var ring_o := PackedVector2Array()
	var ring_i := PackedVector2Array()
	for k in 200:
		var a2 := TAU * k / 200.0
		ring_o.append(Vector2(cos(a2), sin(a2)) * 50.0)
		ring_i.append(Vector2(cos(-a2), sin(-a2)) * 30.0)
	var ring := PdfSynth.soup_area(PdfGeom.fill([ring_o, ring_i], false))
	t.near(ring, absf(PdfGeom.area(ring_o)) - absf(PdfGeom.area(ring_i)), 0.01, "a ring of 400 edges")
	t.check(not PdfGeom._crossings([ring_o, ring_i]), "(whose contours do not cross)")
	var crossing := ring_i.duplicate()
	for k in crossing.size():
		crossing[k] += Vector2(30, 0)
	t.check(PdfGeom._crossings([ring_o, crossing]), "(and a moved hole that does, which the grid finds)")
	# clipping
	var sq := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 0), Vector2(10, 10), Vector2(0, 10)])
	t.near(PdfSynth.soup_area(PdfGeom.clip_rect(sq, Rect2(5, 5, 10, 10))), 25.0, 1e-6, "a square cut to a rectangle")
	var tri := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])
	t.near(PdfSynth.soup_area(PdfGeom.clip_convex(sq, tri)), 50.0, 1e-6, "a square cut to a triangle")
	# curves
	var line := PackedVector2Array()
	PdfGeom.flatten_cubic(Vector2(0, 0), Vector2(0, 100), Vector2(100, 100), Vector2(100, 0), 0.05, line)
	var worst_d := 0.0
	for pi in range(1, line.size()):
		var p := (line[pi] + line[pi - 1]) * 0.5
		var best := INF
		for k in 4000:
			var tt := k / 3999.0
			var mt := 1.0 - tt
			var c := mt * mt * mt * Vector2(0, 0) + 3.0 * mt * mt * tt * Vector2(0, 100) + 3.0 * mt * tt * tt * Vector2(100, 100) + tt * tt * tt * Vector2(100, 0)
			best = minf(best, c.distance_to(p))
		worst_d = maxf(worst_d, best)
	t.check(line.size() > 20 and worst_d < 0.05, "a curve is cut into %d pieces whose middles are within 0.05 of it (worst %.3f)" % [line.size(), worst_d])


func _strokes() -> void:
	var seg: Array = [PackedVector2Array([Vector2(0, 0), Vector2(10, 0)])]
	var open := PackedByteArray([0])
	t.near(PdfSynth.soup_area(PdfStroker.stroke(seg, open, 2.0, 0, 0, 10.0, PackedFloat64Array(), 0.0, 0.01)), 20.0, 1e-6, "a line 10 long and 2 wide with butt ends: 20")
	t.near(PdfSynth.soup_area(PdfStroker.stroke(seg, open, 2.0, 2, 0, 10.0, PackedFloat64Array(), 0.0, 0.01)), 24.0, 1e-6, "with square caps: 24")
	t.near(PdfSynth.soup_area(PdfStroker.stroke(seg, open, 2.0, 1, 0, 10.0, PackedFloat64Array(), 0.0, 0.002)), 20.0 + PI, 0.02, "with round caps: 20 + pi")
	var ell: Array = [PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])]
	t.near(PdfSynth.soup_area(PdfStroker.stroke(ell, open, 2.0, 0, 0, 10.0, PackedFloat64Array(), 0.0, 0.01)), 41.0, 1e-6, "a corner with a mitre join (the overlap is drawn twice: 41)")
	t.near(PdfSynth.soup_area(PdfStroker.stroke(ell, open, 2.0, 0, 2, 10.0, PackedFloat64Array(), 0.0, 0.01)), 40.5, 1e-6, "a bevel join cuts the corner")
	t.near(PdfSynth.soup_area(PdfStroker.stroke(ell, open, 2.0, 0, 0, 1.0, PackedFloat64Array(), 0.0, 0.01)), 40.5, 1e-6, "a mitre beyond the limit becomes a bevel")
	var dashed := PdfStroker.stroke([PackedVector2Array([Vector2(0, 0), Vector2(28, 0)])], open, 2.0, 0, 0, 10.0, PackedFloat64Array([5.0, 5.0]), 0.0, 0.01)
	t.near(PdfSynth.soup_area(dashed), 15.0 * 2.0, 1e-6, "dashes 5 on, 5 off along 28: three marks, 15 long in all")
	var shifted := PdfStroker.stroke([PackedVector2Array([Vector2(0, 0), Vector2(28, 0)])], open, 2.0, 0, 0, 10.0, PackedFloat64Array([5.0, 5.0]), 5.0, 0.01)
	t.near(PdfSynth.soup_area(shifted), 13.0 * 2.0, 1e-6, "a phase of 5 starts in the gap: 13 long in all")
	var closed := PdfStroker.stroke([PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])], PackedByteArray([1]), 1.0, 0, 0, 10.0, PackedFloat64Array(), 0.0, 0.01)
	t.check(PdfSynth.soup_area(closed) > 40.0 and PdfSynth.soup_area(closed) < 43.0, "a closed square outline has four corners")
	var outline := PdfStroker.outline(seg, open, 2.0, 0, 0, 10.0, PackedFloat64Array(), 0.0)
	t.check(outline.size() == 1 and absf(absf(PdfGeom.area(outline[0])) - 20.0) < 0.01, "a translucent stroke is one outline (no overlap): area %.2f" % absf(PdfGeom.area(outline[0])))
	t.near(PdfSynth.soup_area(PdfStroker.stroke([PackedVector2Array([Vector2(5, 5)])], open, 2.0, 1, 0, 10.0, PackedFloat64Array(), 0.0, 0.002)), PI, 0.02, "a dot (a zero-length line with round caps)")


# ------------------------------------------------------------------------------------------------ the interpreter on small pages

func _interpreter() -> void:
	var d := PdfSynth.display_of(PdfSynth.page_pdf("1 0 0 rg 10 10 50 30 re f"))
	var fills := PdfSynth.fill_ops(d)
	t.check(fills.size() == 1 and (fills[0].color as Color).is_equal_approx(Color(1, 0, 0)) and absf(PdfSynth.soup_area(fills[0].soup) - 1500.0) < 1e-6, "a red rectangle: one fill, red, 1500")
	t.eq(d.size, Vector2(200, 100), "the page is 200 x 100")
	d = PdfSynth.display_of(PdfSynth.page_pdf("20 20 40 40 re W n 0 0 100 100 re f"))
	t.near(PdfSynth.soup_area(PdfSynth.fill_ops(d)[0].soup), 1600.0, 1e-6, "a clip to a rectangle cuts what is drawn")
	d = PdfSynth.display_of(PdfSynth.page_pdf("q 2 0 0 2 0 0 cm 10 10 10 10 re f Q 0 g 10 10 10 10 re f"))
	var f2 := PdfSynth.fill_ops(d)
	t.check(f2.size() == 2 and absf(PdfSynth.soup_area(f2[0].soup) - 400.0) < 1e-6 and absf(PdfSynth.soup_area(f2[1].soup) - 100.0) < 1e-6, "q / Q and cm: the scaled square is 400, the next 100")
	d = PdfSynth.display_of(PdfSynth.page_pdf("/G gs 0 0 1 rg 0 0 10 10 re f", "/ExtGState << /G << /ca 0.5 >> >>"))
	t.near((PdfSynth.fill_ops(d)[0].color as Color).a, 0.5, 1e-6, "a graphics state with ca 0.5 makes the fill half transparent")
	d = PdfSynth.display_of(PdfSynth.page_pdf("4 w 10 50 m 110 50 l S"))
	t.near(PdfSynth.soup_area(PdfSynth.fill_ops(d)[0].soup), 400.0, 1e-6, "a stroke 4 wide and 100 long")
	d = PdfSynth.display_of(PdfSynth.page_pdf("0 w 10 50 m 110 50 l S"))
	t.check(PdfSynth.soup_area(PdfSynth.fill_ops(d)[0].soup) > 20.0, "a hairline is not thinner than the least that is drawn")
	d = PdfSynth.display_of(PdfSynth.page_pdf("0 0 1 RG 0.5 0.5 0.5 rg 10 10 20 20 re B"))
	t.eq(PdfSynth.fill_ops(d).size(), 2, "B fills and strokes")
	# text
	var res := "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >>"
	d = PdfSynth.display_of(PdfSynth.page_pdf("BT /F1 20 Tf 10 50 Td (Hi) Tj ET", res))
	var glyphs := d.ops.filter(func(o): return o.t == "glyph")
	t.eq(glyphs.size(), 2, "two letters are two glyphs")
	t.check((glyphs[0].m as Transform2D).origin.is_equal_approx(Vector2(10, 50)), "the first at the text position")
	t.near((glyphs[1].m as Transform2D).origin.x, 10.0 + 20.0 * 0.722, 0.01, "the second after the width of H (0.722 em)")
	d = PdfSynth.display_of(PdfSynth.page_pdf("BT /F1 20 Tf 3 Tr 10 50 Td (Hi) Tj ET", res))
	t.eq(d.ops.size(), 0, "invisible text (render mode 3: the hidden text of scanned pages) draws nothing")
	d = PdfSynth.display_of(PdfSynth.page_pdf("BT /F1 10 Tf 2 Tc 50 Tz 10 50 Td [(A) -1000 (B)] TJ ET", res))
	glyphs = d.ops.filter(func(o): return o.t == "glyph")
	t.near((glyphs[1].m as Transform2D).origin.x - (glyphs[0].m as Transform2D).origin.x, (0.667 * 10.0 + 2.0) * 0.5 + 1.0 * 10.0 * 0.5, 0.02, "character spacing, horizontal scale and a TJ gap")
	# forms, patterns of operators, optional content
	var form := {"dict": "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 50 0]", "data": "1 0 0 rg 0 0 10 10 re f".to_utf8_buffer()}
	d = PdfSynth.display_of(PdfSynth.page_pdf("/X Do", "/XObject << /X 5 0 R >>", "[0 0 200 100]", [form]))
	var xo := PdfSynth.fill_ops(d)
	t.check(xo.size() == 1 and PdfGeom.bounds(xo[0].soup).position.is_equal_approx(Vector2(50, 0)), "a form is run at its matrix")
	var oc_cat := "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [6 0 R] /D << /OFF [6 0 R] >> >> >>"
	var pdf := PdfSynth.page_pdf("/OC /L1 BDC 0 0 10 10 re f EMC 20 20 10 10 re f", "/Properties << /L1 6 0 R >>", "[0 0 200 100]", ["<< >>", "<< /Type /OCG /Name (Layer) >>"])
	var pdf_text := pdf.get_string_from_ascii().replace("<< /Type /Catalog /Pages 2 0 R >>", oc_cat)
	d = PdfSynth.display_of(pdf_text.to_ascii_buffer())
	t.eq(PdfSynth.fill_ops(d).size(), 1, "content in a layer that is switched off is not drawn")
	# page boxes and rotation
	d = PdfSynth.display_of(PdfSynth.page_pdf("10 10 20 20 re f", "", "[0 0 200 100]", [], "/Rotate 90"))
	t.eq(d.size, Vector2(100, 200), "Rotate 90 swaps the sides")
	t.check(PdfGeom.bounds(PdfSynth.fill_ops(d)[0].soup).is_equal_approx(Rect2(10, 170, 20, 20)), "and turns the page clockwise (bottom left goes to top left): %s" % str(PdfGeom.bounds(PdfSynth.fill_ops(d)[0].soup)))
	d = PdfSynth.display_of(PdfSynth.page_pdf("10 10 20 20 re f", "", "[0 0 200 100]", [], "/Rotate 180"))
	t.check(PdfGeom.bounds(PdfSynth.fill_ops(d)[0].soup).is_equal_approx(Rect2(170, 70, 20, 20)), "Rotate 180")
	d = PdfSynth.display_of(PdfSynth.page_pdf("0 0 200 100 re f", "", "[0 0 200 100]", [], "/CropBox [50 20 150 80]"))
	t.check(d.size == Vector2(100, 60) and PdfGeom.bounds(PdfSynth.fill_ops(d)[0].soup).size.is_equal_approx(Vector2(100, 60)), "the crop box is the page that is shown")
	d = PdfSynth.display_of(PdfSynth.page_pdf("BI /W 2 /H 2 /CS /RGB /BPC 8 ID abcdefghijkl\nEI 5 5 10 10 re f"))
	t.check(d.ops.filter(func(o): return o.t == "image").size() == 1 and PdfSynth.fill_ops(d).size() == 1, "an inline image is an image, and the content after it is read on")
	d = PdfSynth.display_of(PdfSynth.page_pdf("0 0 m 10 0 l 10 10 l W n 0 0 100 100 re f"))
	t.near(PdfSynth.soup_area(PdfSynth.fill_ops(d)[0].soup), 50.0, 1e-6, "a clip to a triangle")
	var many := PdfSynth.display_of(PdfSynth.page_pdf("%s" % "0 0 1 1 re f ".repeat(2000)))
	t.eq(PdfSynth.fill_ops(many).size(), 2000, "two thousand operators")


func _shadings() -> void:
	var sh := "/Shading << /S1 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >> >>"
	var d := PdfSynth.display_of(PdfSynth.page_pdf("0 0 100 50 re W n /S1 sh", sh))
	var meshes := d.ops.filter(func(o): return o.t == "mesh")
	t.check(meshes.size() == 1, "a shading is a coloured mesh")
	var cols: PackedColorArray = meshes[0].cols
	var verts: PackedVector2Array = meshes[0].soup
	var left := Color.WHITE
	var right := Color.WHITE
	var lx := INF
	var rx := -INF
	for i in verts.size():
		if verts[i].x < lx:
			lx = verts[i].x
			left = cols[i]
		if verts[i].x > rx:
			rx = verts[i].x
			right = cols[i]
	t.check(left.r > 0.95 and left.b < 0.05 and right.b > 0.95 and right.r < 0.05, "red at the start of the axis, blue at its end")
	t.near(PdfSynth.soup_area(verts), 5000.0, 1e-3, "covering exactly the clip")
	var radial := "/Shading << /S1 << /ShadingType 3 /ColorSpace /DeviceRGB /Coords [50 50 0 50 50 40] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0 0 0] /N 1 >> /Extend [false false] >> >>"
	d = PdfSynth.display_of(PdfSynth.page_pdf("0 0 100 100 re W n /S1 sh", radial))
	meshes = d.ops.filter(func(o): return o.t == "mesh")
	var rv: PackedVector2Array = meshes[0].soup
	var disc := PdfSynth.soup_area(rv)
	t.check(disc > PI * 40 * 40 * 0.97 and disc < PI * 40 * 40 * 1.01, "a radial shading with no extension is the disc and no more (%.0f of %.0f)" % [disc, PI * 1600.0])
	var fn := PdfFunction.make(PdfDoc.open(PdfSynth.page_pdf("")), {"FunctionType": 3, "Domain": [0, 1], "Functions": [{"FunctionType": 2, "Domain": [0, 1], "C0": [0.0], "C1": [1.0], "N": 1}, {"FunctionType": 2, "Domain": [0, 1], "C0": [1.0], "C1": [0.0], "N": 1}], "Bounds": [0.5], "Encode": [0, 1, 0, 1]})
	t.check(fn != null and absf(float(fn.evaluate([0.25])[0]) - 0.5) < 1e-6 and absf(float(fn.evaluate([0.75])[0]) - 0.5) < 1e-6, "a stitching function")
	var calc_doc := PdfDoc.open(PdfSynth.page_pdf("", "", "[0 0 10 10]", [{"dict": "/FunctionType 4 /Domain [0 1] /Range [0 1 0 1]", "data": "{ dup 0.5 gt { 1 exch sub } if dup }".to_utf8_buffer()}]))
	var calc := PdfFunction.make(calc_doc, Vector2i(5, 0))
	t.check(calc != null and absf(float(calc.evaluate([0.8])[0]) - 0.2) < 1e-6 and absf(float(calc.evaluate([0.3])[1]) - 0.3) < 1e-6, "a PostScript calculator function")


func _images() -> void:
	var doc := PdfDoc.open(PdfSynth.page_pdf(""))
	# raw RGB
	var rgb := PdfStream.new()
	rgb.dict = {"Width": 2, "Height": 1, "ColorSpace": &"DeviceRGB", "BitsPerComponent": 8}
	rgb.raw = PackedByteArray([255, 0, 0, 0, 0, 255])
	rgb.length = 6
	var im := PdfImage.decode(doc, rgb, {}, 1024, 100000)
	t.check(im.ok() and im.color.get_pixel(0, 0).is_equal_approx(Color(1, 0, 0)) and im.color.get_pixel(1, 0).is_equal_approx(Color(0, 0, 1)), "raw RGB samples")
	# 1-bit grey with Decode [1 0]
	var g1 := PdfStream.new()
	g1.dict = {"Width": 8, "Height": 1, "ColorSpace": &"DeviceGray", "BitsPerComponent": 1, "Decode": [1, 0]}
	g1.raw = PackedByteArray([0b10101010])
	g1.length = 1
	var gi := PdfImage.decode(doc, g1, {}, 1024, 100000)
	t.check(gi.ok() and gi.color.get_pixel(0, 0).r < 0.1 and gi.color.get_pixel(1, 0).r > 0.9, "1-bit grey, inverted by Decode")
	# indexed, 4 bits
	var ix := PdfStream.new()
	ix.dict = {"Width": 2, "Height": 1, "ColorSpace": [&"Indexed", &"DeviceRGB", 2, PackedByteArray([255, 0, 0, 0, 255, 0, 0, 0, 255])], "BitsPerComponent": 4}
	ix.raw = PackedByteArray([0x12])
	ix.length = 1
	var ii := PdfImage.decode(doc, ix, {}, 1024, 100000)
	t.check(ii.ok() and ii.color.get_pixel(0, 0).is_equal_approx(Color(0, 1, 0)) and ii.color.get_pixel(1, 0).is_equal_approx(Color(0, 0, 1)), "indexed colour with 4-bit samples")
	# CMYK
	var ck := PdfStream.new()
	ck.dict = {"Width": 1, "Height": 1, "ColorSpace": &"DeviceCMYK", "BitsPerComponent": 8}
	ck.raw = PackedByteArray([0, 255, 255, 0])
	ck.length = 4
	var ci := PdfImage.decode(doc, ck, {}, 1024, 100000)
	t.check(ci.ok() and ci.color.get_pixel(0, 0).r > 0.9 and ci.color.get_pixel(0, 0).g < 0.25, "CMYK magenta + yellow is red")
	var cyan := PdfColor.cmyk(1.0, 0.0, 0.0, 0.0)                    # what Acrobat and Chrome show for 100 % cyan is (0, 174, 239), not pure cyan
	t.check(absf(cyan.r) < 0.06 and absf(cyan.g - 0.68) < 0.06 and absf(cyan.b - 0.94) < 0.06, "CMYK cyan is the sky blue of print (%s)" % str(cyan))
	var key := PdfColor.cmyk(0.0, 0.0, 0.0, 1.0)
	t.check(key.r < 0.22 and key.g < 0.22 and key.b < 0.22 and PdfColor.cmyk(0.0, 0.0, 0.0, 0.0).is_equal_approx(Color.WHITE), "CMYK black is near black and no ink is white")
	# a stencil mask: sample 0 paints
	var st := PdfStream.new()
	st.dict = {"Width": 8, "Height": 1, "ImageMask": true}
	st.raw = PackedByteArray([0b10101010])
	st.length = 1
	var si := PdfImage.decode(doc, st, {}, 1024, 100000)
	t.check(si.ok() and si.is_mask and si.alpha.get_pixel(0, 0).r < 0.1 and si.alpha.get_pixel(1, 0).r > 0.9, "a stencil mask paints where the sample is 0")
	# JPEG through the engine
	var photo := Image.create(16, 16, false, Image.FORMAT_RGB8)
	photo.fill(Color(0.2, 0.7, 0.3))
	var jpeg := PdfStream.new()
	jpeg.dict = {"Width": 16, "Height": 16, "ColorSpace": &"DeviceRGB", "BitsPerComponent": 8, "Filter": &"DCTDecode"}
	jpeg.raw = photo.save_jpg_to_buffer(0.95)
	jpeg.length = jpeg.raw.size()
	var ji := PdfImage.decode(doc, jpeg, {}, 1024, 100000)
	t.check(ji.ok() and ji.color.get_pixel(8, 8).g > 0.6 and ji.color.get_pixel(8, 8).r < 0.3, "a JPEG")
	# a soft mask is a second picture
	var alpha := PdfStream.new()
	alpha.dict = {"Width": 2, "Height": 1, "ColorSpace": &"DeviceGray", "BitsPerComponent": 8}
	alpha.raw = PackedByteArray([0, 255])
	alpha.length = 2
	var masked := PdfStream.new()
	masked.dict = rgb.dict.duplicate()
	masked.dict["SMask"] = alpha
	masked.raw = rgb.raw
	masked.length = 6
	var mi := PdfImage.decode(doc, masked, {}, 1024, 100000)
	t.check(mi.ok() and mi.alpha != null and mi.alpha.get_pixel(0, 0).r < 0.05 and mi.alpha.get_pixel(1, 0).r > 0.95, "a soft mask becomes the alpha picture")
	# too large: reduced
	var wide := PdfStream.new()
	wide.dict = {"Width": 400, "Height": 100, "ColorSpace": &"DeviceGray", "BitsPerComponent": 8}
	var wr := PackedByteArray()
	wr.resize(40000)
	wide.raw = wr
	wide.length = 40000
	var wi := PdfImage.decode(doc, wide, {}, 100, 100000)
	t.check(wi.ok() and wi.color.get_width() == 100 and wi.color.get_height() == 25, "a picture beyond the device's limit is reduced to it (%d x %d)" % [wi.color.get_width(), wi.color.get_height()])
	var unsupported := PdfStream.new()
	unsupported.dict = {"Width": 4, "Height": 4, "ColorSpace": &"DeviceGray", "BitsPerComponent": 8, "Filter": &"JPXDecode"}
	unsupported.raw = PackedByteArray([1, 2, 3])
	unsupported.length = 3
	t.check(not PdfImage.decode(doc, unsupported, {}, 1024, 100000).ok(), "JPEG 2000 is not drawn (and says so)")


# ------------------------------------------------------------------------------------------------ fax

## Bitmaps coded by libtiff (Group 4, Group 3 with end-of-line codes, Modified Huffman) and what libtiff reads back from them: the decoder must give the same bits.
func _fax() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ccitt/manifest.json"))
	t.check(manifest.size() >= 36, "the fax fixtures are there (%d)" % manifest.size())
	var names := manifest.keys()
	names.sort()
	for key in names:
		var m: Dictionary = manifest[key]
		var coded := FileAccess.get_file_as_bytes("res://tests/fixtures/ccitt/%s.bin" % key)
		var want := FileAccess.get_file_as_bytes("res://tests/fixtures/ccitt/%s.exp" % key)
		var parms := {"K": int(m.k), "Columns": int(m.columns), "Rows": int(m.rows), "EncodedByteAlign": bool(m.align), "EndOfLine": bool(m.eol)}
		var got := PdfCcitt.decode(coded, parms, int(m.columns), int(m.rows))
		var diff := 0
		var stride := (int(m.columns) + 7) / 8
		var pad_mask := (0xFF << (stride * 8 - int(m.columns))) & 0xFF                   # the bits after the last column of a row mean nothing
		for i in want.size():
			var mask := pad_mask if i % stride == stride - 1 else 0xFF
			if i >= got.size() or (got[i] & mask) != (want[i] & mask):
				diff += 1
		t.check(got.size() == want.size() and diff == 0, "fax %s: %d x %d from %d bytes (%d bytes differ)" % [key, m.columns, m.rows, coded.size(), diff])
	# black as 1, when the filter says so
	var lines: Dictionary = manifest["lines_g4"]
	var lines_coded := FileAccess.get_file_as_bytes("res://tests/fixtures/ccitt/lines_g4.bin")
	var lines_want := FileAccess.get_file_as_bytes("res://tests/fixtures/ccitt/lines_g4.exp")
	var inverted := PdfCcitt.decode(lines_coded, {"K": -1, "Columns": 160, "BlackIs1": true}, 160, 100)
	var same := inverted.size() == lines_want.size()
	for i in mini(inverted.size(), lines_want.size()):
		same = same and (inverted[i] & 0xF0) == (~lines_want[i] & 0xF0)
	t.check(same, "BlackIs1 gives the bits the other way round")
	# cut short: the rows before the cut are right, the rest is blank paper
	var text_coded := FileAccess.get_file_as_bytes("res://tests/fixtures/ccitt/text_g4.bin")
	var text_want := FileAccess.get_file_as_bytes("res://tests/fixtures/ccitt/text_g4.exp")
	var cut := PdfCcitt.decode(text_coded.slice(0, text_coded.size() / 2), {"K": -1, "Columns": 203}, 203, 120)
	var stride := 26
	var head_ok := cut.size() == stride * 120
	for i in stride * 30:
		head_ok = head_ok and i < cut.size() and (cut[i] & (0xFF if i % stride != stride - 1 else 0xE0)) == (text_want[i] & (0xFF if i % stride != stride - 1 else 0xE0))
	var tail_blank := cut.size() == stride * 120
	for i in range(stride * 118, mini(stride * 120, cut.size())):
		tail_blank = tail_blank and cut[i] == 0xFF
	t.check(head_ok and tail_blank, "a cut-short fax: the first 30 rows are right and the end is blank")
	# nonsense must neither crash nor hang
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var junk := PackedByteArray()
	junk.resize(6000)
	for i in junk.size():
		junk[i] = rng.randi() & 0xFF
	var junk_ok := true
	for kk in [-1, 0, 3]:
		for align in [false, true]:
			var r := PdfCcitt.decode(junk, {"K": kk, "Columns": 200, "EncodedByteAlign": align}, 200, 300)
			junk_ok = junk_ok and (r.is_empty() or r.size() == 25 * 300)
	t.check(junk_ok, "random bytes are not a fax (and not a crash)")
	t.check(PdfCcitt.decode(PackedByteArray([0, 0, 0, 0]), {"K": -1, "Columns": 64}, 64, 8).is_empty(), "an end of block with no rows is nothing")
	# through a picture of a PDF
	var doc := PdfDoc.open(PdfSynth.page_pdf(""))
	var st := PdfStream.new()
	st.dict = {"Width": 160, "Height": 100, "ColorSpace": &"DeviceGray", "BitsPerComponent": 1, "Filter": &"CCITTFaxDecode", "DecodeParms": {"K": -1, "Columns": 160, "Rows": 100}}
	st.raw = lines_coded
	st.length = lines_coded.size()
	var im := PdfImage.decode(doc, st, {}, 1024, 100000)
	var pix_ok := im.ok() and im.color != null and im.color.get_width() == 160 and im.color.get_height() == 100
	if pix_ok:
		var wrong := 0
		for y in range(0, 100, 3):
			for x in range(0, 160, 3):
				var white := (lines_want[y * 20 + x / 8] >> (7 - (x & 7))) & 1 == 1
				if (im.color.get_pixel(x, y).r > 0.5) != white:
					wrong += 1
		pix_ok = wrong == 0
	t.check(pix_ok, "a fax-coded picture is read as a picture (black where the fax is black)")


# ------------------------------------------------------------------------------------------------ soft masks, groups, textures

func _white(n: int) -> PackedColorArray:
	var c := PackedColorArray()
	for i in n:
		c.append(Color.WHITE)
	return c


func _quad(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y0), Vector2(x1, y1), Vector2(x0, y1)])


func _rasters() -> void:
	var r := PdfRaster.new(10, 10, Rect2(0, 0, 10, 10), 0.0)
	r.tris(_quad(0, 0, 5, 10), _white(6))
	var lum := r.to_image(false)
	var cov := r.to_image(true)
	t.check(lum.get_pixel(2, 5).r > 0.99 and lum.get_pixel(7, 5).r < 0.01, "the rasteriser paints the left half only")
	t.check(cov.get_pixel(2, 5).r > 0.99 and cov.get_pixel(7, 5).r < 0.01, "and counts what it covered")
	var black := PackedColorArray()
	for i in 6:
		black.append(Color.BLACK)
	var over_white := PdfRaster.new(10, 10, Rect2(0, 0, 10, 10), 1.0)
	over_white.tris(_quad(0, 0, 5, 10), black)
	var ow := over_white.to_image(false)
	t.check(ow.get_pixel(2, 5).r < 0.01 and ow.get_pixel(7, 5).r > 0.99, "a backdrop shows where nothing is painted")
	var ramp := PackedColorArray([Color.BLACK, Color.WHITE, Color.WHITE, Color.BLACK, Color.WHITE, Color.BLACK])
	var g := PdfRaster.new(10, 10, Rect2(0, 0, 10, 10), 0.0)
	g.tris(_quad(0, 0, 10, 10), ramp)
	var gi := g.to_image(false)
	t.check(absf(gi.get_pixel(1, 5).r - 0.15) < 0.03 and absf(gi.get_pixel(8, 5).r - 0.85) < 0.03, "smooth colours: black to white across the square")
	# a picture with its own transparency
	var colour := Image.create(1, 1, false, Image.FORMAT_RGB8)
	colour.set_pixel(0, 0, Color.WHITE)
	var alpha := Image.create_from_data(2, 1, false, Image.FORMAT_L8, PackedByteArray([0, 255]))
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	var pic := PdfRaster.new(10, 10, Rect2(0, 0, 10, 10), 0.0)
	pic.image_tris(_quad(0, 0, 10, 10), uvs, colour, alpha, 0.5, Color.WHITE)
	var pi := pic.to_image(false)
	t.check(pi.get_pixel(1, 5).r < 0.02 and absf(pi.get_pixel(8, 5).r - 0.5) < 0.02, "a picture with a soft mask of its own, drawn at half opacity")


func _soft_masks() -> void:
	var res := "/ExtGState << /G1 << /SMask << /Type /Mask /S /Luminosity /G 5 0 R >> >> /G0 << /SMask /None >> >>"
	var form := {"dict": "/Type /XObject /Subtype /Form /BBox [0 0 200 100] /Group << /S /Transparency /CS /DeviceGray >>", "data": "1 g 0 0 100 100 re f".to_utf8_buffer()}
	var d := PdfSynth.display_of(PdfSynth.page_pdf("/G1 gs 1 0 0 rg 0 0 200 100 re f", res, "[0 0 200 100]", [form]))
	var fills := PdfSynth.fill_ops(d)
	t.check(d.masks.size() == 1 and fills.size() == 1 and fills[0].mask == 1, "a soft mask is baked once and the shape drawn under it refers to it")
	var m: Dictionary = d.masks[0]
	var img: Image = m.image
	t.check((m.rect as Rect2).is_equal_approx(Rect2(0, 0, 200, 100)) and absf(float(m.outside)) < 1e-6, "it covers its group's area and is closed beyond it")
	t.check(img.get_pixel(20, img.get_height() / 2).r > 0.98 and img.get_pixel(img.get_width() - 20, img.get_height() / 2).r < 0.02, "white where the group painted white, black where it painted nothing")
	# a backdrop colour is what the group did not paint
	var bc := "/ExtGState << /G1 << /SMask << /Type /Mask /S /Luminosity /BC [1] /G 5 0 R >> >> >>"
	var dark := {"dict": "/Type /XObject /Subtype /Form /BBox [0 0 200 100] /Group << /S /Transparency /CS /DeviceGray >>", "data": "0 g 0 0 100 100 re f".to_utf8_buffer()}
	var db := PdfSynth.display_of(PdfSynth.page_pdf("/G1 gs 0 0 200 100 re f", bc, "[0 0 200 100]", [dark]))
	var bi: Image = db.masks[0].image
	t.check(bi.get_pixel(20, bi.get_height() / 2).r < 0.02 and bi.get_pixel(bi.get_width() - 20, bi.get_height() / 2).r > 0.98 and absf(float(db.masks[0].outside) - 1.0) < 1e-6, "the backdrop colour fills what the group left alone")
	# an alpha mask uses coverage, not brightness
	var al := "/ExtGState << /G1 << /SMask << /Type /Mask /S /Alpha /G 5 0 R >> >> >>"
	var da := PdfSynth.display_of(PdfSynth.page_pdf("/G1 gs 0 0 200 100 re f", al, "[0 0 200 100]", [dark]))
	var ai: Image = da.masks[0].image
	t.check(ai.get_pixel(20, ai.get_height() / 2).r > 0.98 and ai.get_pixel(ai.get_width() - 20, ai.get_height() / 2).r < 0.02, "an alpha mask is where the group painted, whatever the colour")
	# a transfer function (/TR) is applied to the mask, and to what lies beyond it
	var tr := "/ExtGState << /G1 << /SMask << /Type /Mask /S /Alpha /TR << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >> /G 5 0 R >> >> >>"
	var dt := PdfSynth.display_of(PdfSynth.page_pdf("/G1 gs 0 0 200 100 re f", tr, "[0 0 200 100]", [dark]))
	var ti: Image = dt.masks[0].image
	t.check(ti.get_pixel(20, ti.get_height() / 2).r < 0.02 and ti.get_pixel(ti.get_width() - 20, ti.get_height() / 2).r > 0.98 and absf(float(dt.masks[0].outside) - 1.0) < 1e-6, "a mask's transfer function turns it round (and what is outside it)")
	# turning it off
	var off := PdfSynth.display_of(PdfSynth.page_pdf("/G1 gs 0 0 10 10 re f /G0 gs 20 0 10 10 re f 1 0 0 rg 40 0 10 10 re f", res, "[0 0 200 100]", [form]))
	var of := PdfSynth.fill_ops(off)
	t.check(of.size() == 3 and of[0].mask == 1 and of[1].mask == 0 and of[2].mask == 0, "/SMask /None ends the mask")
	# through the builder: the layer carries the mask; a Quest 2 bakes it smaller
	var pdf := PdfSynth.page_pdf("/G1 gs 1 0 0 rg 0 0 200 100 re f", res, "[0 0 200 100]", [form])
	var hi := PdfReader.open(pdf, PdfBudget.for_tier("high")).render(0)
	var lo := PdfReader.open(pdf, PdfBudget.for_tier("low")).render(0)
	t.check(hi.ok and lo.ok and hi.layers.size() == 1 and hi.layers[0].has("mask") and lo.layers[0].has("mask"), "the layer of a masked shape carries its mask")
	var hw: int = (hi.layers[0].mask.image as Image).get_width()
	var lw: int = (lo.layers[0].mask.image as Image).get_width()
	t.check(hw == 512 and lw == 256, "the mask picture is smaller on a Quest 2 (%d against %d)" % [lw, hw])


func _groups_and_textures() -> void:
	# a transparency group is drawn at the alpha it is called with; what is drawn inside multiplies with it
	var res := "/ExtGState << /G2 << /ca 0.5 >> >> /XObject << /Fm1 5 0 R >>"
	var form := {"dict": "/Type /XObject /Subtype /Form /BBox [0 0 200 100] /Group << /S /Transparency >>", "data": "1 0 0 rg 0 0 100 100 re f /G2 gs 0 1 0 rg 100 0 50 100 re f".to_utf8_buffer()}
	var d := PdfSynth.display_of(PdfSynth.page_pdf("/G2 gs /Fm1 Do 0 0 1 rg 150 0 50 100 re f", res, "[0 0 200 100]", [form]))
	var f := PdfSynth.fill_ops(d)
	t.check(f.size() == 3, "three shapes")
	t.near(f[0].color.a, 0.5, 1e-6, "an opaque shape in a group called at half is half")
	t.near(f[1].color.a, 0.25, 1e-6, "a half-transparent shape in it is a quarter")
	t.near(f[2].color.a, 0.5, 1e-6, "and the state outside the group is what it was")
	# a translucent colour is drawn stronger than its number (the engine blends in linear light): on the Quest 2 budget too
	var pdf := PdfSynth.page_pdf("/G2 gs 1 0 0 rg 0 0 50 50 re f 0 0 1 rg 50 0 50 50 re f", "/ExtGState << /G2 << /ca 0.25 >> >>")
	var boosted := PdfReader.open(pdf, PdfBudget.for_tier("high")).render(0)
	var plain_budget := PdfBudget.for_tier("high")
	plain_budget.alpha_power = 1.0
	var plain := PdfReader.open(pdf, plain_budget).render(0)
	t.near(plain.layers[0].cols[0].a, 0.25, 1e-6, "with the power at 1 a quarter is a quarter")
	t.near(boosted.layers[0].cols[0].a, pow(0.25, 0.6), 1e-6, "by default a quarter is drawn at 0.25^0.6")
	var solid := PdfReader.open(PdfSynth.page_pdf("1 0 0 rg 0 0 50 50 re f"), PdfBudget.for_tier("low")).render(0)
	t.near(solid.layers[0].cols[0].a, 1.0, 1e-9, "an opaque shape stays opaque")
	# a function of two variables: sampled into a picture
	var fn := {"dict": "/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1]", "data": "{ 0 }".to_utf8_buffer()}
	var sh := "/Shading << /S1 << /ShadingType 1 /ColorSpace /DeviceRGB /Domain [0 1 0 1] /Matrix [200 0 0 100 0 0] /Function 5 0 R >> >>"
	var td := PdfSynth.display_of(PdfSynth.page_pdf("/S1 sh", sh, "[0 0 200 100]", [fn]))
	var tex := td.ops.filter(func(o): return o.t == "tex")
	t.check(tex.size() == 1, "a function-based shading is one picture drawn over its region")
	var ci: Image = tex[0].color
	t.check(ci.get_pixel(ci.get_width() - 1, ci.get_height() - 1).r > 0.97 and ci.get_pixel(0, ci.get_height() - 1).r < 0.03, "red grows with x")
	t.check(ci.get_pixel(0, 0).g > 0.97 and ci.get_pixel(0, ci.get_height() - 1).g < 0.03, "green grows with y (the top of the picture is the top of the page)")
	t.near(PdfSynth.soup_area(tex[0].soup), 20000.0, 1e-3, "over the whole page")
	var uv_ok := true
	for uv in (tex[0].uvs as PackedVector2Array):
		uv_ok = uv_ok and uv.x >= -1e-6 and uv.x <= 1.000001 and uv.y >= -1e-6 and uv.y <= 1.000001
	t.check(uv_ok, "with texture coordinates inside the picture")
	# only the function's own rectangle is painted, and a clip cuts the picture as it cuts anything else
	var small := "/Shading << /S1 << /ShadingType 1 /ColorSpace /DeviceRGB /Domain [0 1 0 1] /Matrix [100 0 0 100 0 0] /Function 5 0 R >> >>"
	var ts := PdfSynth.display_of(PdfSynth.page_pdf("/S1 sh", small, "[0 0 200 100]", [fn]))
	t.near(PdfSynth.soup_area(ts.ops.filter(func(o): return o.t == "tex")[0].soup), 10000.0, 1e-3, "only the function's own rectangle is painted")
	var tc := PdfSynth.display_of(PdfSynth.page_pdf("0 0 50 50 re W n /S1 sh", small, "[0 0 200 100]", [fn]))
	var cut: Dictionary = tc.ops.filter(func(o): return o.t == "tex")[0]
	t.near(PdfSynth.soup_area(cut.soup), 2500.0, 1e-3, "a clip cuts it")
	t.check((cut.soup as PackedVector2Array).size() == (cut.uvs as PackedVector2Array).size(), "and its texture coordinates with it")
	# the built layer is a picture with a colour and an alpha
	var pg := PdfReader.open(PdfSynth.page_pdf("/S1 sh", sh, "[0 0 200 100]", [fn]), PdfBudget.for_tier("low")).render(0)
	t.check(pg.ok and pg.layers.size() == 1 and pg.layers[0].kind == "image" and pg.layers[0].alpha != null, "the page layer is a picture")

# ------------------------------------------------------------------------------------------------ mesh shadings

static func _bytes_of(values: Array) -> PackedByteArray:
	var b := PackedByteArray()
	for v in values:
		b.append(int(v))
	return b


## The picture a mesh shading of the given type and data paints over a 100 x 100 page.
func _mesh_op(type: int, data: PackedByteArray, extra: String = "") -> Dictionary:
	var sh := {"dict": "/ShadingType %d /ColorSpace /DeviceRGB /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 100 0 100 0 1 0 1 0 1] %s" % [type, extra], "data": data}
	var pdf := PdfSynth.page_pdf("/Pattern cs /P1 scn 0 0 100 100 re f", "/Pattern << /P1 6 0 R >>", "[0 0 100 100]", [sh, "<< /PatternType 2 /Shading 5 0 R >>"])
	var d := PdfSynth.display_of(pdf)
	var tex := d.ops.filter(func(o): return o.t == "tex")
	return tex[0] if not tex.is_empty() else {}


## The colour of the picture at a place given as a fraction of the page (from its left, from its bottom); alpha 0 where nothing is painted.
func _at(op: Dictionary, fx: float, fy: float) -> Color:
	var c: Image = op.color
	var a: Image = op.alpha
	var x := clampi(int(fx * c.get_width()), 0, c.get_width() - 1)
	var y := clampi(int((1.0 - fy) * c.get_height()), 0, c.get_height() - 1)
	var col := c.get_pixel(x, y)
	col.a = a.get_pixel(x, y).r
	return col


func _meshes() -> void:
	# type 4: a triangle with a red, a green and a blue corner
	var tri := _bytes_of([0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255])
	var op := _mesh_op(4, tri)
	t.check(not op.is_empty(), "a free-form triangle mesh is drawn as a picture")
	if not op.is_empty():
		var inside := _at(op, 0.2, 0.5)
		t.check(inside.a > 0.99 and absf(inside.r - 0.3) < 0.06 and absf(inside.g - 0.2) < 0.06 and absf(inside.b - 0.5) < 0.06, "inside it the colours blend by distance to the corners (%s)" % str(inside))
		t.check(_at(op, 0.85, 0.85).a < 0.01, "and beyond its edge nothing is painted")
		t.check(_at(op, 0.03, 0.03).r > 0.85 and _at(op, 0.96, 0.02).g > 0.85 and _at(op, 0.02, 0.96).b > 0.85, "each corner has its colour")
		t.near(PdfSynth.soup_area(op.soup), 10000.0, 1e-3, "over the mesh's own area")
	# type 4 again: a second triangle that shares the last edge (flag 1)
	var two := tri.duplicate()
	two.append_array(_bytes_of([1, 255, 255, 255, 255, 0]))
	var op2 := _mesh_op(4, two)
	t.check(not op2.is_empty() and _at(op2, 0.85, 0.85).a > 0.99 and _at(op2, 0.85, 0.85).r > 0.6, "a flag 1 vertex makes a triangle with the last edge of the one before")
	# type 5: a lattice of 2 x 2 vertices
	var lat := _bytes_of([0, 0, 255, 0, 0,  255, 0, 0, 255, 0,  0, 255, 0, 0, 255,  255, 255, 255, 255, 255])        # x, y, r, g, b: red, green / blue, white
	var lop := _mesh_op(5, lat, "/VerticesPerRow 2")
	t.check(not lop.is_empty() and _at(lop, 0.5, 0.5).a > 0.99, "a lattice mesh is drawn")
	if not lop.is_empty():
		t.check(_at(lop, 0.03, 0.03).r > 0.85 and _at(lop, 0.97, 0.03).g > 0.85 and _at(lop, 0.03, 0.97).b > 0.85 and _at(lop, 0.97, 0.97).r > 0.85, "with the colours of its corners")
	# types 6 and 7: a square patch with straight sides and a colour at each corner (p00 red, p03 green, p33 blue, p30 white)
	var boundary: Array = [0, 0, 0, 84, 0, 170, 0, 255, 84, 255, 170, 255, 255, 255, 255, 170, 255, 84, 255, 0, 170, 0, 84, 0]
	var corners: Array = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
	var coons := _bytes_of([0] + boundary + corners)
	var cop := _mesh_op(6, coons)
	t.check(not cop.is_empty(), "a Coons patch is drawn")
	if not cop.is_empty():
		t.check(_at(cop, 0.03, 0.03).r > 0.85 and _at(cop, 0.03, 0.03).g < 0.2, "p00's colour is at the lower left")
		t.check(_at(cop, 0.03, 0.97).g > 0.85 and _at(cop, 0.97, 0.97).b > 0.85 and _at(cop, 0.97, 0.03).r > 0.85 and _at(cop, 0.97, 0.03).b > 0.85, "and the others at theirs")
		var mid := _at(cop, 0.5, 0.5)
		t.check(absf(mid.r - 0.5) < 0.05 and absf(mid.g - 0.5) < 0.05 and absf(mid.b - 0.5) < 0.05, "the middle is the average of the four (%s)" % str(mid))
		t.near(PdfSynth.soup_area(cop.soup), 10000.0, 1e-3, "over the patch's own area")
	var tensor := _bytes_of([0] + boundary + [84, 84, 84, 170, 170, 170, 170, 84] + corners)
	var top := _mesh_op(7, tensor)
	t.check(not top.is_empty() and absf(_at(top, 0.5, 0.5).g - 0.5) < 0.05, "a tensor-product patch is drawn")
	# a second Coons patch next to the first, sharing its right edge (flag 3: its p03.. p00 edge is the previous patch's p30 p20 p10 p00; here flag 2: p33 p32 p31 p30)
	var shared := coons.duplicate()
	shared.append_array(_bytes_of([2, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255]))
	t.check(not _mesh_op(6, shared).is_empty(), "a patch that shares an edge with the one before is read")
	# colours given by a function of one variable
	var fsh := {"dict": "/ShadingType 5 /VerticesPerRow 2 /ColorSpace /DeviceRGB /BitsPerCoordinate 8 /BitsPerComponent 8 /Decode [0 100 0 100 0 1] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >>", "data": _bytes_of([0, 0, 0,  255, 0, 255,  0, 255, 0,  255, 255, 255])}
	var fpdf := PdfSynth.page_pdf("/Pattern cs /P1 scn 0 0 100 100 re f", "/Pattern << /P1 6 0 R >>", "[0 0 100 100]", [fsh, "<< /PatternType 2 /Shading 5 0 R >>"])
	var fops := PdfSynth.display_of(fpdf).ops.filter(func(o): return o.t == "tex")
	t.check(fops.size() == 1 and _at(fops[0], 0.03, 0.5).r > 0.85 and _at(fops[0], 0.97, 0.5).b > 0.85, "mesh colours can come through a function (red to blue across)")
	# what cannot be drawn is not drawn: no filling with the pattern's stand-in colour
	var bad := PdfSynth.display_of(PdfSynth.page_pdf("/Pattern cs /P1 scn 0 0 100 100 re f", "/Pattern << /P1 6 0 R >>", "[0 0 100 100]",
		[{"dict": "/ShadingType 6 /ColorSpace /DeviceRGB /BitsPerCoordinate 7 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 100 0 100 0 1 0 1 0 1]", "data": PackedByteArray([1, 2, 3])}, "<< /PatternType 2 /Shading 5 0 R >>"]))
	t.check(bad.ops.is_empty() and bad.stats.unsupported.has("shading"), "a mesh that cannot be read paints nothing (and says so)")
	# a gradient whose function takes the wrong number of inputs is not painted either
	var many := PdfSynth.display_of(PdfSynth.page_pdf("/S1 sh", "/Shading << /S1 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function 5 0 R >> >>", "[0 0 100 100]",
		[{"dict": "/FunctionType 4 /Domain [0 1 0 1 0 1] /Range [0 1 0 1 0 1]", "data": "{ pop pop }".to_utf8_buffer()}]))
	t.check(many.ops.is_empty(), "a function with the wrong number of inputs paints no gradient")

# ------------------------------------------------------------------------------------------------ text as a clip

func _text_clips() -> void:
	var font := "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >>"
	# the coverage rasteriser: spans of whole rows
	var tri := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(0, 100)])
	var cov := PdfRaster.coverage(tri, 50, 50, Rect2(0, 0, 100, 100))
	var covered := 0
	for y in 50:
		for x in 50:
			if cov.get_pixel(x, y).r > 0.5:
				covered += 1
	t.check(absf(covered - 1250.0) < 90.0, "a triangle covers half of its square (%d of 2500 texels)" % covered)
	t.check(cov.get_pixel(5, 44).r > 0.5 and cov.get_pixel(44, 5).r < 0.5, "the right half: lower left is covered (page y runs up, the picture's rows down), upper right is not")
	# text shown in mode 7 clips what follows, until the graphics state is restored
	var d := PdfSynth.display_of(PdfSynth.page_pdf("q BT /F1 80 Tf 7 Tr 10 20 Td (HI) Tj ET 1 0 0 rg 0 0 200 100 re f Q 0 0 1 rg 190 90 10 10 re f", font))
	var fills := PdfSynth.fill_ops(d)
	t.check(d.masks.size() == 1 and fills.size() == 2 and fills[0].mask == 1 and fills[1].mask == 0, "the clip of text mode 7 is a mask for what follows, and Q ends it")
	t.check(d.ops.filter(func(o): return o.t == "glyph").is_empty(), "mode 7 draws no letters of its own")
	if d.masks.size() == 1:
		var m: Dictionary = d.masks[0]
		var img: Image = m.image
		var r: Rect2 = m.rect
		t.check(r.position.x > 10.0 and r.position.x < 24.0 and r.size.y > 50.0 and r.size.y < 64.0 and r.size.x > 50.0 and r.size.x < 100.0, "it covers the letters' own box (%s)" % str(r))
		var on := 0
		for y in range(0, img.get_height(), 3):
			for x in range(0, img.get_width(), 3):
				if img.get_pixel(x, y).r > 0.5:
					on += 1
		var seen := float(on) / float(((img.get_height() + 2) / 3) * ((img.get_width() + 2) / 3))
		t.check(seen > 0.12 and seen < 0.5, "and is white where the letters are and black elsewhere (%.2f of the box)" % seen)
		t.near(float(m.outside), 0.0, 1e-9, "nothing shows beyond it")
	# mode 4: the letters are drawn and also clip
	var both := PdfSynth.display_of(PdfSynth.page_pdf("BT /F1 80 Tf 4 Tr 10 20 Td (H) Tj ET 1 0 0 rg 0 0 200 100 re f", font))
	t.check(both.ops.filter(func(o): return o.t == "glyph").size() == 1 and both.masks.size() == 1, "mode 4 draws the letters and clips")
	# a text object without clip modes makes no mask
	var plain := PdfSynth.display_of(PdfSynth.page_pdf("BT /F1 80 Tf 0 Tr 10 20 Td (H) Tj ET 1 0 0 rg 0 0 200 100 re f", font))
	t.check(plain.masks.is_empty(), "ordinary text makes no mask")
	# on a Quest 2 the mask picture is smaller
	var pdf := PdfSynth.page_pdf("BT /F1 300 Tf 7 Tr 10 20 Td (H) Tj ET 1 0 0 rg 0 0 600 400 re f", font, "[0 0 600 400]")
	var hi := PdfReader.open(pdf, PdfBudget.for_tier("high")).render(0)
	var lo := PdfReader.open(pdf, PdfBudget.for_tier("low")).render(0)
	t.check(hi.ok and lo.ok and hi.layers.size() == 1 and lo.layers.size() == 1 and (lo.layers[0].mask.image as Image).get_width() < (hi.layers[0].mask.image as Image).get_width(), "a Quest 2 bakes the clip smaller")
	# a CID-keyed CFF font whose font dictionary has its own FontMatrix: the letters are the size they should be (they were twice as big)
	var real := PdfReader.open(FileAccess.get_file_as_bytes("res://tests/fixtures/pdf/cid_cff_clip.pdf"), PdfBudget.for_tier("high"))
	var rp := real.render(0)
	t.check(rp.ok and rp.layers.size() == 1 and rp.layers[0].has("mask"), "a PDF that fills text-shaped clip is made")
	if rp.ok and rp.layers.size() == 1 and rp.layers[0].has("mask"):
		var r2: Rect2 = rp.layers[0].mask.rect
		t.check(r2.size.y > 70.0 and r2.size.y < 110.0 and r2.size.x < 500.0, "120 pt capitals are about 85 pt tall, not twice that (%s)" % str(r2))

# ------------------------------------------------------------------------------------------------ blend modes

func _blends() -> void:
	var picture := {"dict": "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "data": PackedByteArray([128])}
	var res := "/XObject << /Im1 5 0 R >> /ExtGState << /GM << /BM /Multiply >> /GS << /BM /Screen >> /GO << /BM /Overlay >> >>"
	for pair in [["GM", "Multiply"], ["GS", "Screen"], ["GO", ""]]:
		var page := PdfReader.open(PdfSynth.page_pdf("/%s gs q 100 0 0 100 0 0 cm /Im1 Do Q 1 0 0 rg 50 50 40 40 re f" % pair[0], res, "[0 0 200 100]", [picture]), PdfBudget.for_tier("high")).render(0)
		var kinds: Array = []
		for l in page.layers:
			kinds.append("%s:%s" % [l.kind, l.blend])
		t.check(page.ok and page.layers.size() == 2 and page.layers[0].kind == "image" and page.layers[0].blend == pair[1] and page.layers[1].blend == pair[1], "a picture and a shape drawn with /BM %s blend as %s (%s)" % [pair[0], pair[1] if pair[1] != "" else "normal", str(kinds)])
	t.check(PdfPageNode._shader_for(PdfPageNode.IMAGE_SHADER, "Multiply").code.contains("blend_mul") and PdfPageNode._shader_for(PdfPageNode.MASKED_SHADER, "Screen").code.contains("blend_add"), "the shaders of pictures and masked shapes have a multiplying and an adding variant")
	t.check(PdfPageNode._shader_for(PdfPageNode.IMAGE_SHADER, "").code.contains("blend_mix") and PdfPageNode._shader_for(PdfPageNode.IMAGE_SHADER, "Multiply") == PdfPageNode._shader_for(PdfPageNode.IMAGE_SHADER, "Multiply"), "the plain one is as it was and a variant is made once")
	# and on a page in the scene: the picture's material multiplies
	var node := PdfPageNode.new()
	add_child(node)
	node.show_page(PdfReader.open(PdfSynth.page_pdf("/GM gs q 100 0 0 100 0 0 cm /Im1 Do Q", res, "[0 0 200 100]", [picture]), PdfBudget.for_tier("high")).render(0), 0.001)
	var mat: ShaderMaterial = null
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		if mi.material_override is ShaderMaterial:
			mat = mi.material_override
	t.check(mat != null and mat.shader.code.contains("blend_mul"), "a picture drawn with Multiply is drawn with a multiplying material")
	node.queue_free()

func _tiling_state() -> void:
	# a tiling cell is drawn from the initial graphics state: the page's thick line and half-transparent stroke do not reach into it
	var cell := {"dict": "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 100 100] /XStep 100 /YStep 100 /Resources << >>", "data": "0 50 m 100 50 l S".to_utf8_buffer()}
	var d := PdfSynth.display_of(PdfSynth.page_pdf("/Pattern cs /P1 scn 20 w 1 0 0 RG /G gs 0 0 100 100 re f", "/Pattern << /P1 5 0 R >> /ExtGState << /G << /CA 0.5 >> >>", "[0 0 100 100]", [cell]))
	var fills := PdfSynth.fill_ops(d)
	t.check(fills.size() == 1, "the cell's line is drawn once")
	if fills.size() == 1:
		t.check(PdfSynth.soup_area(fills[0].soup) < 150.0 and fills[0].color.a > 0.99 and fills[0].color.r < 0.1, "with line width 1, opaque and black, not the page's 20 wide half-transparent red (%s)" % str(fills[0].color))


func _clip_union() -> void:
	# an L-shaped clip is the union of its convex pieces: a coloured triangle soup cut by it keeps the L's area, once, and its colours follow position
	var d := PdfDisplay.new()
	var l_shape := PackedVector2Array([Vector2(0, 0), Vector2(20, 0), Vector2(20, 10), Vector2(10, 10), Vector2(10, 20), Vector2(0, 20)])
	var id := d.clip_with_region(0, _quad(0, 0, 20, 20), l_shape)
	t.check(d.clip_has_pieces(id), "the L is kept as pieces")
	var soup := _quad(-50, -50, 50, 50)
	var cols := PackedColorArray()
	for p in soup:
		cols.append(Color(p.x / 100.0 + 0.5, p.y / 100.0 + 0.5, 0, 1))
	var res := d.clip_mesh(soup, cols, id)
	t.near(PdfSynth.soup_area(res[0]), 300.0, 1e-3, "the cut mesh has the area of the L, no more and no less")
	var colours_follow := true
	for i in (res[0] as PackedVector2Array).size():
		var p: Vector2 = res[0][i]
		var c: Color = res[1][i]
		colours_follow = colours_follow and absf(c.r - (p.x / 100.0 + 0.5)) < 1e-4 and absf(c.g - (p.y / 100.0 + 0.5)) < 1e-4
	t.check(colours_follow, "and the colours at the new corners are those of their place")
	# a solid fill and a coloured mesh agree on what the clip lets through
	var fill := d.clip_soup(soup, id)
	t.near(PdfSynth.soup_area(fill), 300.0, 1e-3, "a solid fill is cut to the same area")


func _budget() -> void:
	var bytes := _bytes("base14.pdf")
	var hi := PdfReader.open(bytes, PdfBudget.for_tier("high")).render(0)
	var lo := PdfReader.open(bytes, PdfBudget.for_tier("low")).render(0)
	t.check(hi.ok and lo.ok and hi.triangles() > 0, "a page is made on both budgets")
	t.check(lo.triangles() < hi.triangles(), "a Quest 2's page has fewer triangles (%d against %d)" % [lo.triangles(), hi.triangles()])
	var plain := PdfBudget.for_tier("high")
	plain.text_boost = 0.0
	var thin := PdfReader.open(bytes, plain).render(0)
	t.check(thin.stats.glyphs == hi.stats.glyphs and _area(thin) < _area(hi), "the letters are a little heavier than their outlines on purpose (they would look thin in a headset)")
	var rd := PdfReader.open(_bytes("many.pdf"), PdfBudget.for_tier("high"))
	t.check(rd.ok() and rd.page_count == 30 and rd.page_size(29).is_equal_approx(Vector2(200, 280)), "a reader knows its page sizes without making them")
	t.check(not rd.render(99).ok, "a page that does not exist is not made")
	var q2 := PdfBudget.for_tier("low")
	var q3 := PdfBudget.for_tier("high")
	t.check(q2.max_file_mb < q3.max_file_mb and q2.cached_pages < q3.cached_pages and q2.max_image_dim < q3.max_image_dim and q2.max_triangles < q3.max_triangles and q2.tolerance > q3.tolerance, "every limit of a Quest 2 is the tighter one")
	t.check(not q2.prefetch and q3.prefetch, "a Quest 2 does not make pages ahead")
	t.check(PdfBudget.detect_tier("low") == "low" and PdfBudget.detect_tier("high") == "high", "the tier can be chosen in the settings")
	var models := {"Quest 2": "low", "Meta Quest 2": "low", "Quest": "low", "Quest 3": "high", "Quest 3S": "high", "Quest Pro": "high", "": "high", "GenericDevice": "high"}
	var all_right := true
	for m in models:
		all_right = all_right and PdfBudget.tier_of_model(m) == models[m]
	t.check(all_right, "the tier follows the model name the headset reports")
	var tiny := PdfBudget.for_tier("high")
	tiny.max_triangles = 100
	var big := PdfReader.open(PdfSynth.page_pdf("0 0 1 1 re f ".repeat(2000)), tiny).render(0)
	t.check(big.ok and big.stats.unsupported.has("page too complex: the rest was left out") and big.triangles() < 4000, "a page beyond the triangle budget is left unfinished, with a note")


func _area(d: PdfPageData) -> float:
	var a := 0.0
	for l in d.layers:
		if l.kind == "tris":
			a += PdfSynth.soup_area(l.verts)
	return a


func _corpus() -> void:
	var dir := OS.get_environment("MRW_PDF_CORPUS")
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return
	var start := Time.get_ticks_msec()
	var n := 0
	var bad := 0
	for f in DirAccess.get_files_at(dir):
		if not f.to_lower().ends_with(".pdf") or Time.get_ticks_msec() - start > 60000:
			continue
		var r := PdfReader.open(FileAccess.get_file_as_bytes(dir + "/" + f), PdfBudget.for_tier("high"))
		n += 1
		if r.ok():
			var d := r.render(0)
			if not d.ok:
				bad += 1
				print("  corpus: %s: %s" % [f, d.message])
	t.check(n > 0 and bad == 0, "the corpus: %d files made without a crash (%d pages with a problem)" % [n, bad])
