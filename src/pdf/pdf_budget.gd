class_name PdfBudget
extends RefCounted
## How much a device is asked to do for a page. A Quest 2 has a weaker processor and graphics chip and less memory than a Quest 3 (and a
## headset joining a session may be either), so every limit of the PDF viewer is a number in one place, by device tier. A page is drawn by
## the same code on every device: only these numbers differ.

var tier := "high"
var tolerance := 0.04                      # curves are flattened to within this many points (1 pt = 0.35 mm on paper)
var min_line := 0.3                        # the thinnest line (pt)
var text_boost := 0.14                     # every glyph outline is grown by this much (points): a letter's thin stems are about a pixel wide in a headset and the
                                           # engine blends edges in linear light, which makes such stems look lighter than other viewers show them
var alpha_power := 0.6                     # a translucent colour is drawn with its alpha raised to this power: blending in linear light also makes translucent
                                           # colours look fainter than in other viewers (a PDF blends the numbers of the colours as they are)
var max_triangles := 2500000               # a page with more than this is left unfinished
var max_image_dim := 4096                  # the longest side of a picture on the graphics chip
var pixel_budget := 3000000                # pixels the slow colour conversions may touch per image
var cached_pages := 4                      # pages kept ready (the shown one and its neighbours)
var prefetch := true                       # the next page is prepared while the shown one is read
var max_file_mb := 64                      # the biggest PDF taken in
var max_pages_shown := 1


## "low" for a Quest 2, "high" for a Quest 3, 3S, Pro and the PC. `forced` is the user's choice of tier ("" = by the device).
static func detect_tier(forced: String = "") -> String:
	if forced in ["low", "high"]:
		return forced
	return tier_of_model(OS.get_model_name())


## The tier of a device by the model name the system reports ("Quest 2" and the first Quest are `low`, everything else `high`).
static func tier_of_model(model_name: String) -> String:
	var model := model_name.to_lower().strip_edges()
	if model.contains("quest 2") or model.contains("quest2") or model == "quest" or model == "meta quest":
		return "low"
	return "high"


static func for_tier(tier_id: String) -> PdfBudget:
	var b := PdfBudget.new()
	b.tier = tier_id
	if tier_id == "low":
		b.tolerance = 0.08
		b.min_line = 0.4
		b.max_triangles = 700000
		b.max_image_dim = 2048
		b.pixel_budget = 1200000
		b.cached_pages = 2
		b.prefetch = false
		b.max_file_mb = 48
	return b
