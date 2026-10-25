class_name PdfStdFonts
extends RefCounted
## Stand-ins for the fonts a PDF names but does not carry (Helvetica, Times, Courier, Arial, Calibri ...): the Liberation fonts, which have
## the same character widths as Helvetica / Times / Courier, so a line set in the original lays out the same. A font that is none of
## those families gets the nearest of them (by its name and its flags); Open Sans, the interface's own font, is the last resort.

const DIR := "res://assets/pdf_fonts/"
const SANS := "LiberationSans"
const SERIF := "LiberationSerif"
const MONO := "LiberationMono"

static var _cache: Dictionary = {}


## The family, bold and italic that a font's name and flags ask for: {family, bold, italic, symbol}.
static func classify(base_font: String, flags: int, descriptor: Dictionary = {}) -> Dictionary:
	var n := base_font.to_lower()
	if n.length() > 7 and n[6] == "+":
		n = n.substr(7)
	n = n.replace(" ", "").replace("-", "").replace("_", "").replace(",", "")
	var family := SANS
	if n.contains("courier") or n.contains("mono") or n.contains("consolas") or n.contains("typewriter") or n.contains("menlo") or (flags & 1) != 0:
		family = MONO
	elif n.contains("sans") or n.contains("arial") or n.contains("helvetica") or n.contains("calibri") or n.contains("verdana") or n.contains("tahoma"):
		family = SANS
	elif n.contains("times") or n.contains("serif") or n.contains("georgia") or n.contains("garamond") or n.contains("palatino") or n.contains("bookman") \
			or n.contains("century") or n.contains("cambria") or n.contains("minion") or n.contains("roman") or n.contains("book") or n.contains("charter") \
			or (flags & 2) != 0:
		family = SERIF
	var bold := n.contains("bold") or n.contains("black") or n.contains("heavy") or n.contains("demi") or (flags & 262144) != 0 or float(descriptor.get("FontWeight", 400)) >= 600.0
	var italic := n.contains("italic") or n.contains("oblique") or n.contains("slanted") or (flags & 64) != 0 or absf(float(descriptor.get("ItalicAngle", 0))) > 1.0
	var symbol := n.begins_with("symbol") or n.contains("zapfdingbats") or n.contains("dingbats")
	return {"family": family, "bold": bold, "italic": italic, "symbol": symbol}


static func pick(base_font: String, flags: int, descriptor: Dictionary = {}) -> PdfFontTtf:
	var c := classify(base_font, flags, descriptor)
	var style := "Regular"
	if c.bold and c.italic:
		style = "BoldItalic"
	elif c.bold:
		style = "Bold"
	elif c.italic:
		style = "Italic"
	return _load("%s-%s" % [c.family, style])


static func _load(file_stem: String) -> PdfFontTtf:
	if _cache.has(file_stem):
		return _cache[file_stem]
	var f: PdfFontTtf = null
	var res: Variant = load(DIR + file_stem + ".ttf") if ResourceLoader.exists(DIR + file_stem + ".ttf") else null
	if res is FontFile:
		f = PdfFontTtf.parse((res as FontFile).data)
	if f == null or not f.ok:
		var fallback: Variant = load("res://assets/fonts/OpenSans.ttf")
		if fallback is FontFile:
			f = PdfFontTtf.parse((fallback as FontFile).data)
	_cache[file_stem] = f
	return f
