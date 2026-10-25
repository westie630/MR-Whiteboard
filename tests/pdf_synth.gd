class_name PdfSynth
extends RefCounted
## Builds small PDF files in memory for the tests: one page with the given content, and any extra objects (numbered from 5 in the order given).
## An extra object is a String (its text) or {"dict": "/Type /XObject ...", "data": PackedByteArray} (a stream: /Length is added).


static func page_pdf(content: String, resources: String = "", media: String = "[0 0 200 100]", extras: Array = [], page_extra: String = "") -> PackedByteArray:
	var objs: Array = []
	objs.append("<< /Type /Catalog /Pages 2 0 R >>")
	objs.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
	objs.append("<< /Type /Page /Parent 2 0 R /MediaBox %s /Contents 4 0 R /Resources << %s >> %s >>" % [media, resources, page_extra])
	objs.append({"dict": "", "data": content.to_utf8_buffer()})
	for e in extras:
		objs.append(e)
	var out := PackedByteArray()
	out.append_array("%PDF-1.7\n".to_utf8_buffer())
	var offs: Array = []
	for i in objs.size():
		offs.append(out.size())
		out.append_array(("%d 0 obj\n" % (i + 1)).to_utf8_buffer())
		var o: Variant = objs[i]
		if o is String:
			out.append_array((o as String).to_utf8_buffer())
		else:
			var data: PackedByteArray = o.data
			out.append_array(("<< %s /Length %d >>\nstream\n" % [o.dict, data.size()]).to_utf8_buffer())
			out.append_array(data)
			out.append_array("\nendstream".to_utf8_buffer())
		out.append_array("\nendobj\n".to_utf8_buffer())
	var xref := out.size()
	out.append_array(("xref\n0 %d\n0000000000 65535 f \n" % (objs.size() + 1)).to_utf8_buffer())
	for o in offs:
		out.append_array(("%010d 00000 n \n" % o).to_utf8_buffer())
	out.append_array(("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % [objs.size() + 1, xref]).to_utf8_buffer())
	return out


## The display list a one-page PDF draws.
static func display_of(pdf: PackedByteArray) -> PdfDisplay:
	var doc := PdfDoc.open(pdf)
	var it := PdfInterp.new()
	it.doc = doc
	return it.run_page(doc.page(0))


static func fill_ops(d: PdfDisplay) -> Array:
	return d.ops.filter(func(o): return o.t == "fill")


static func soup_area(soup: PackedVector2Array) -> float:
	var tot := 0.0
	var i := 0
	while i + 2 < soup.size():
		tot += absf((soup[i + 1] - soup[i]).cross(soup[i + 2] - soup[i])) * 0.5
		i += 3
	return tot
