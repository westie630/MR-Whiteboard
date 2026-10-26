class_name ModelBudget
extends RefCounted
## How much a device is asked to do for 3D models. A Quest 2 has a weaker graphics chip and less memory than a Quest 3 (and a headset that joins
## a session may be either), so every limit of the model viewer is a number here, by device tier, like PdfBudget. A model is loaded by the same
## code on every device: only these numbers differ. The tier is PdfBudget's (`OS.get_model_name()`), the `model_tier` setting forces one.

var tier := "high"
var max_file_mb := 96                      # the biggest model file (or bundle) taken in
var max_triangles := 1500000               # a model with more than this is refused on this device (the others of a session still show it)
var max_texture := 2048                    # the longest side of a texture on the graphics chip (bigger ones are scaled down when loaded)
var lods := true                           # meshes get simpler versions for when they are far away (made when loaded)
var lod_min_triangles := 2000              # ...for meshes with at least this many triangles
var cached := 6                            # loaded models kept ready when no model in the room shows them
var radiance := 128                        # the size of the reflections of the light around the models
var shadow := true                         # a soft shadow on the surface under a model


static func detect_tier(forced: String = "") -> String:
	return PdfBudget.detect_tier(forced)


static func for_tier(tier_id: String) -> ModelBudget:
	var b := ModelBudget.new()
	b.tier = tier_id
	if tier_id == "low":
		b.max_file_mb = 48
		b.max_triangles = 400000
		b.max_texture = 1024
		b.lod_min_triangles = 1000
		b.cached = 2
		b.radiance = 64
	return b
