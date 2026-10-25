extends Node
## The PDF library: taking files in (named by their content), the index that survives a restart, what is refused, pages made on the worker thread
## and on the spot, the cache, and the lighter budget of a Quest 2.

const FIX := "res://tests/fixtures/pdf/"
const DIR := "user://test_pdfs_library"

var t := TestCase.new("pdf_library")
var lib: PdfLibrary
var got: Array = []
var failed: Array = []


func _ready() -> void:
	_clean()
	lib = _make("high")
	await _taking_in()
	await _pages(true)
	await _pages(false)
	_budgets()
	await _restart()
	_clean()
	get_tree().quit(t.done())


func _clean() -> void:
	var d := ProjectSettings.globalize_path(DIR)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


func _make(tier: String, threaded: bool = true) -> PdfLibrary:
	var l := PdfLibrary.new()
	l.dir = DIR
	l.budget = PdfBudget.for_tier(tier)
	l.threaded = threaded
	add_child(l)
	l.page_ready.connect(func(id: String, page: int, d: PdfPageData): got.append([id, page, d]))
	l.page_failed.connect(func(id: String, page: int, msg: String): failed.append([id, page, msg]))
	return l


func _bytes(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(FIX + name)


func _taking_in() -> void:
	var r := lib.add(_bytes("base14.pdf"), "My Notes.pdf")
	t.check(bool(r.ok) and int(r.pages) == 2 and str(r.name) == "My Notes" and not bool(r.dup), "a PDF is taken in: %s" % str(r))
	t.eq(str(r.id).length(), 32, "its id is a hash of its content")
	t.eq(str(r.id), PdfLibrary.id_of(_bytes("base14.pdf")), "the same content has the same id on every headset")
	var again := lib.add(_bytes("base14.pdf"), "other name.pdf")
	t.check(bool(again.ok) and bool(again.dup) and str(again.id) == str(r.id), "the same file again is not stored twice")
	t.eq(lib.list().size(), 1, "one PDF listed")
	var e := lib.entry(str(r.id))
	t.check(int(e.pages) == 2 and int(e.size) == _bytes("base14.pdf").size(), "the index knows its pages and size")
	t.check(lib.page_size(str(r.id), 1).is_equal_approx(Vector2(300, 200)) and lib.page_size(str(r.id), 2).is_equal_approx(Vector2(400, 220)), "and the size of each page: %s %s" % [str(lib.page_size(str(r.id), 1)), str(lib.page_size(str(r.id), 2))])
	t.check(lib.file_bytes(str(r.id)) == _bytes("base14.pdf"), "the file is kept as it came")
	var bad := lib.add("this is not a pdf at all, it is just text".to_utf8_buffer(), "x.pdf")
	t.check(not bool(bad.ok), "something that is not a PDF is refused: %s" % str(bad.message))
	var locked := lib.add(_bytes("locked.pdf"), "locked.pdf")
	t.check(not bool(locked.ok) and str(locked.message).contains("password"), "a PDF that needs a password is refused and says so: %s" % str(locked.message))
	t.check(not bool(lib.add(PackedByteArray(), "e.pdf").ok), "an empty file is refused")
	for n in ["rc4_128.pdf", "aes_128.pdf", "aes_256.pdf"]:
		var rr := lib.add(_bytes(n), n)
		t.check(bool(rr.ok), "%s (restricted, opens without a password) is taken in" % n)
	var damaged := lib.add(_bytes("no_xref.pdf"), "no_xref.pdf")
	t.check(bool(damaged.ok), "a PDF whose cross-reference table is gone is read by scanning")
	t.check(bool(lib.add(_bytes("stray_byte.pdf"), "stray.pdf").ok), "a stream with a stray byte after it is read (the engine's own decompressor would have crashed the app)")
	lib.rename(str(r.id), "  Renamed\n")
	t.eq(str(lib.entry(str(r.id)).name), "Renamed", "a name is cleaned")
	t.eq(PdfLibrary.clean_name("C:\\docs\\Report 2024.PDF"), "Report 2024", "a path and the extension are dropped from the name")
	var low := _make("low", false)
	low.dir = DIR + "_low"
	var big := PackedByteArray()
	big.resize(49 * 1048576)
	t.check(not bool(low.add(big, "big.pdf").ok), "a file over a Quest 2's limit is refused: %s" % str(low.add(big, "big.pdf").message))
	low.queue_free()


func _pages(threaded: bool) -> void:
	var l := _make("high", threaded)
	l.dir = DIR
	got.clear()
	failed.clear()
	var id := PdfLibrary.id_of(_bytes("base14.pdf"))
	l.request(id, 1)
	var end := Time.get_ticks_msec() + 8000
	while got.is_empty() and failed.is_empty() and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	var how := "on the worker" if threaded else "on the spot"
	t.check(not got.is_empty() and failed.is_empty(), "a page is made %s" % how)
	if got.is_empty():
		l.queue_free()
		return
	var d: PdfPageData = got[0][2]
	t.check(d.ok and d.size.is_equal_approx(Vector2(300, 200)) and d.layers.size() >= 1 and int(d.stats.glyphs) > 50, "%s: the page has its text (%d glyphs) and its size" % [how, int(d.stats.glyphs)])
	t.check(d.triangles() > 500, "%s: and its shapes (%d triangles)" % [how, d.triangles()])
	# page 2 is another shape
	got.clear()
	l.request(id, 2)
	end = Time.get_ticks_msec() + 8000
	while got.is_empty() and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	t.check(not got.is_empty() and (got[0][2] as PdfPageData).size.is_equal_approx(Vector2(400, 220)), "%s: page 2 comes out in its own shape" % how)
	# a page that is ready is announced again at once, from the cache
	got.clear()
	l.request(id, 1)
	await get_tree().process_frame
	await get_tree().process_frame
	t.check(not got.is_empty() and l.cached_page(id, 1) != null, "%s: a page asked for twice comes from the cache" % how)
	# pages that do not exist
	got.clear()
	l.request(id, 99)
	l.request("0123456789abcdef0123456789abcdef", 1)
	await get_tree().process_frame
	t.check(got.is_empty(), "%s: a page beyond the end, or of a PDF that is not here, is not made" % how)
	l.queue_free()


func _budgets() -> void:
	t.eq(PdfBudget.detect_tier("low"), "low", "the tier can be forced to low")
	t.eq(PdfBudget.detect_tier("high"), "high", "and to high")
	var hi := PdfBudget.for_tier("high")
	var lo := PdfBudget.for_tier("low")
	t.check(lo.tolerance > hi.tolerance and lo.max_triangles < hi.max_triangles and lo.max_image_dim < hi.max_image_dim and lo.cached_pages < hi.cached_pages and not lo.prefetch and hi.prefetch,
		"a Quest 2 asks for less of everything than a Quest 3 and does not make pages ahead")


func _restart() -> void:
	var l2 := PdfLibrary.new()
	l2.dir = DIR
	add_child(l2)
	await get_tree().process_frame
	t.check(l2.has(PdfLibrary.id_of(_bytes("base14.pdf"))) and l2.list().size() >= 6, "after a restart the PDFs are still there (%d)" % l2.list().size())
	# the index lost: the files are read again
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + "/index.json"))
	var l3 := PdfLibrary.new()
	l3.dir = DIR
	add_child(l3)
	await get_tree().process_frame
	t.check(l3.list().size() >= 6 and l3.page_count(PdfLibrary.id_of(_bytes("base14.pdf"))) == 2, "and without the index they are found again")
	t.check(l3.remove(PdfLibrary.id_of(_bytes("base14.pdf"))) and not l3.has(PdfLibrary.id_of(_bytes("base14.pdf"))), "a PDF is removed")
	var left := 0
	for f in DirAccess.get_files_at(ProjectSettings.globalize_path(DIR)):
		if f == PdfLibrary.id_of(_bytes("base14.pdf")) + ".pdf":
			left += 1
	t.eq(left, 0, "with its file")
	l2.queue_free()
	l3.queue_free()
