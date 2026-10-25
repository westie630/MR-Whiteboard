class_name PdfReader
extends RefCounted
## One open PDF: its objects, the fonts its pages use (kept between pages), and the step from a page number to a PdfPageData. Everything
## in here is plain data, so render() can run on a worker thread; one thread at a time, because the document caches what it reads.

var doc: PdfDoc
var budget: PdfBudget
var error := ""
var page_count := 0
var title := ""

var _fonts: Dictionary = {}
var _templates: Dictionary = {}
var _sizes: Dictionary = {}


static func open(bytes: PackedByteArray, b: PdfBudget = null) -> PdfReader:
	var r := PdfReader.new()
	r.budget = b if b != null else PdfBudget.for_tier("high")
	r.doc = PdfDoc.open(bytes)
	if not r.doc.ok():
		r.error = r.doc.error
		return r
	r.page_count = r.doc.page_count()
	var info := r.doc.d_dict(r.doc.trailer.get("Info"))
	var t: Variant = r.doc.res(info.get("Title"))
	if t is PackedByteArray:
		r.title = _text(t)
	return r


func ok() -> bool:
	return error == "" and page_count > 0


## A PDF text string (UTF-16 with a mark, or UTF-8, or Latin-1 style) as a String.
static func _text(b: PackedByteArray) -> String:
	if b.size() >= 2 and b[0] == 0xFE and b[1] == 0xFF:
		return _utf16be(b.slice(2))
	if b.size() >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF:
		return b.slice(3).get_string_from_utf8()
	var s := ""
	for c in b:
		s += char(c)
	return s.strip_edges()


static func _utf16be(b: PackedByteArray) -> String:
	var s := ""
	var i := 0
	while i + 1 < b.size():
		var u := (b[i] << 8) | b[i + 1]
		i += 2
		if u >= 0xD800 and u < 0xDC00 and i + 1 < b.size():
			var lo := (b[i] << 8) | b[i + 1]
			if lo >= 0xDC00 and lo < 0xE000:
				i += 2
				u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
		s += char(u)
	return s.strip_edges()


## The visible size of a page in points (after Rotate and CropBox).
func page_size(i: int) -> Vector2:
	if _sizes.has(i):
		return _sizes[i]
	var pg := doc.page(i)
	var media := doc.d_nums(pg.get("MediaBox"))
	var r := Rect2(0, 0, 612, 792)
	if media.size() >= 4:
		r = Rect2(minf(media[0], media[2]), minf(media[1], media[3]), absf(media[2] - media[0]), absf(media[3] - media[1]))
	var crop := doc.d_nums(pg.get("CropBox"))
	if crop.size() >= 4:
		var c := Rect2(minf(crop[0], crop[2]), minf(crop[1], crop[3]), absf(crop[2] - crop[0]), absf(crop[3] - crop[1]))
		var inter := r.intersection(c)
		if inter.size.x > 1.0 and inter.size.y > 1.0:
			r = inter
	if r.size.x < 1.0 or r.size.y < 1.0:
		r = Rect2(0, 0, 612, 792)
	var rot := ((doc.d_int(pg.get("Rotate"), 0) % 360) + 360) % 360
	var s := r.size if rot == 0 or rot == 180 else Vector2(r.size.y, r.size.x)
	_sizes[i] = s
	return s


func render(i: int) -> PdfPageData:
	var t0 := Time.get_ticks_msec()
	var data: PdfPageData
	if i < 0 or i >= page_count:
		data = PdfPageData.new()
		data.ok = false
		data.message = "No such page."
		return data
	var it := PdfInterp.new()
	it.doc = doc
	it.fonts = _fonts
	it.tol = budget.tolerance
	it.min_line = budget.min_line
	it.max_triangles = budget.max_triangles
	it.budget = budget
	it.templates = _templates
	var disp := it.run_page(doc.page(i))
	var b := PdfBuilder.new()
	b.doc = doc
	b.budget = budget
	b.templates = _templates
	data = b.build(disp)
	data.index = i
	data.seconds = float(Time.get_ticks_msec() - t0) / 1000.0
	return data
