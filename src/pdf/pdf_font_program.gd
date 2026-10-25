class_name PdfFontProgram
extends RefCounted
## What a font file gives the renderer, whichever format it is in: the outline of a glyph, how far it advances, and how a glyph is found
## (by name, by Unicode value, by the font's own numbering, by CID). The subclasses read TrueType / OpenType (PdfFontTtf), Compact Font
## Format (PdfFontCff) and Type 1 (PdfFontT1).

var units_per_em := 1000.0
var num_glyphs := 0
var matrix := Transform2D(Vector2(0.001, 0.0), Vector2(0.0, 0.001), Vector2.ZERO)   # glyph units -> em
var _paths: Dictionary = {}


## The outline of a glyph in glyph units (y up), or an empty path. Cached.
func glyph_path(gid: int) -> PdfPath:
	var p: Variant = _paths.get(gid)
	if p == null:
		p = _build_path(gid)
		_paths[gid] = p
	return p


func _build_path(_gid: int) -> PdfPath:
	return PdfPath.new()


## Horizontal advance of a glyph in em (1.0 = the font size); -1 when the font does not say.
func advance(_gid: int) -> float:
	return -1.0


func gid_for_name(_glyph_name: String) -> int:
	return -1


func gid_for_unicode(_u: int) -> int:
	return 0


## The glyph the font's own encoding gives a character code (Type 1 / CFF built-in encodings), -1 when none.
func gid_for_builtin_code(_code: int) -> int:
	return -1


func gid_for_cid(cid: int) -> int:
	return cid


## The name of a glyph, "" when the font has none.
func glyph_name(_gid: int) -> String:
	return ""


# ------------------------------------------------------------------------------------------------ big-endian readers

static func u16(b: PackedByteArray, at: int) -> int:
	return (b[at] << 8) | b[at + 1]


static func s16(b: PackedByteArray, at: int) -> int:
	var v := (b[at] << 8) | b[at + 1]
	return v - 65536 if v >= 32768 else v


static func u32(b: PackedByteArray, at: int) -> int:
	return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]
