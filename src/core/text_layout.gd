class_name TextLayout
extends RefCounted
## Text measuring and the "same size and placement" rule for converted handwriting.
## Sizes are the em height in metres. Y points up (frame coordinates).

const REF_PX := 64                          # the pixel size text is measured at
const ASC_GLYPH := 0.72                     # cap / ascender height as a fraction of the em
const X_HEIGHT := 0.52
const DESC_GLYPH := 0.22
const TALL := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789bdfhklt!?/|()[]{}%&@#$"
const DEEP := "gjpqy,;()[]{}|/@$"


static var _font: Font


## The text font: the engine's built-in font as a multichannel signed distance field, so text stays razor sharp at any size and
## distance (a normal font is a bitmap and turns blocky when you lean in or scale it up).
static func font() -> Font:
	if _font == null:
		var base := ThemeDB.fallback_font
		if base is FontFile:
			var f := (base as FontFile).duplicate() as FontFile
			f.multichannel_signed_distance_field = true
			f.msdf_pixel_range = 16
			f.msdf_size = 96
			f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
			f.hinting = TextServer.HINTING_NONE
			f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
			_font = f
		else:
			_font = base
	return _font


## Bounding box (m) of the text drawn at the given em height, one or several lines.
static func measure(text: String, em: float) -> Vector2:
	var f := font()
	var s := f.get_multiline_string_size(text if text != "" else " ", HORIZONTAL_ALIGNMENT_LEFT, -1, REF_PX)
	var k := em / float(REF_PX)
	return Vector2(maxf(s.x * k, em * 0.3), maxf(s.y * k, em * 1.0))


## Distance (as a fraction of the em) the line box extends above and below the baseline.
static func box_metrics() -> Vector2:
	var f := font()
	return Vector2(f.get_ascent(REF_PX) / float(REF_PX), f.get_descent(REF_PX) / float(REF_PX))


## Vertical extent of the glyphs of a string above/below its baseline, as fractions of the em: (top, bottom<=0).
static func glyph_span(text: String) -> Vector2:
	var top := X_HEIGHT
	var bottom := 0.0
	for ch in text:
		if TALL.contains(ch):
			top = ASC_GLYPH
		if DEEP.contains(ch):
			bottom = -DESC_GLYPH
	return Vector2(top, bottom)


## Size and centre of text that replaces ink occupying `ink` (frame coordinates, y up).
## Returns {em, center}. The text takes the ink's height (short strings) or width (longer ones), so a word comes out as big as it was written.
static func fit_ink(text: String, ink: Rect2) -> Dictionary:
	var span := glyph_span(text)
	var glyph_h := maxf(span.x - span.y, 0.2)
	var em_h := ink.size.y / glyph_h
	var unit := measure(text, 1.0)
	var em := em_h
	if text.length() >= 3 and unit.x > 0.0:
		var em_w := ink.size.x / unit.x
		em = clampf(em_w, em_h * 0.6, em_h * 1.7)
	em = maxf(em, 0.008)
	var bm := box_metrics()
	var box_center_above_baseline := (bm.x - bm.y) * 0.5
	var glyph_center_above_baseline := (span.x + span.y) * 0.5
	var c := ink.get_center()
	c.y += (box_center_above_baseline - glyph_center_above_baseline) * em
	return {"em": em, "center": c}
