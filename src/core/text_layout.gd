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


const WEIGHTS := [[300, "Light"], [400, "Regular"], [500, "Medium"], [600, "SemiBold"], [700, "Bold"], [800, "ExtraBold"]]
const REGULAR := 400
## Text sizes like Markdown's: [id, name, em height (m), weight]. A style is always exactly this size, so every Heading 1 matches.
const STYLES := [["h1", "Heading 1", 0.09, 700], ["h2", "Heading 2", 0.07, 700], ["h3", "Heading 3", 0.055, 600],
	["body", "Body", 0.045, 400], ["small", "Small", 0.032, 400]]
const MIN_WEIGHT := 300
const MAX_WEIGHT := 800
const FACES := {false: "res://assets/fonts/OpenSans.ttf", true: "res://assets/fonts/OpenSans-Italic.ttf"}

static var _fonts := {}                     # "weight/italic" -> Font


## Open Sans (variable font: upright and italic files, weight axis 300..800) as a multichannel signed distance field, so text stays
## razor sharp at any size and distance (a normal font is a bitmap and turns blocky when you lean in or scale it up).
## `weight` is the CSS weight (300 Light .. 800 ExtraBold); the fonts are built once and shared.
static func font(weight: int = REGULAR, italic: bool = false) -> Font:
	weight = clampi(roundi(weight / 50.0) * 50, MIN_WEIGHT, MAX_WEIGHT)
	var key := "%d/%s" % [weight, italic]
	if not _fonts.has(key):
		_fonts[key] = _build(weight, italic)
	return _fonts[key]


static func _build(weight: int, italic: bool) -> Font:
	var face := load(FACES[italic]) as FontFile
	if face == null:
		return ThemeDB.fallback_font
	var f := face.duplicate() as FontFile
	f.multichannel_signed_distance_field = true
	f.msdf_pixel_range = 16
	f.msdf_size = 96
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.hinting = TextServer.HINTING_NONE
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	var v := FontVariation.new()
	v.base_font = f
	v.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): float(weight)}
	return v


## The style entry ([id, name, em, weight]) for an id; Body when unknown.
static func style(id: String) -> Array:
	for s in STYLES:
		if s[0] == id:
			return s
	return STYLES[3]


## The id of the style a text of this size and weight is in, or "" when it is custom (scaled by hand, or converted handwriting).
static func style_id(em: float, weight: int) -> String:
	for s in STYLES:
		if absf(em - float(s[2])) < 1e-4 and weight == int(s[3]):
			return s[0]
	return ""


## Bounding box (m) of the text drawn at the given em height, one or several lines.
static func measure(text: String, em: float, weight: int = REGULAR, italic: bool = false) -> Vector2:
	var f := font(weight, italic)
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
