class_name InkRecognizer
extends RefCounted
## A handwriting recognition back end. Strokes go in as arrays of points (x, y in a pixel-like unit with y DOWN, t in milliseconds);
## the answer comes back through the callback as {ok: bool, candidates: PackedStringArray, error: String}.
## Providers: GoogleInk (online). Others can be added by implementing recognize().

const LANGUAGES := [
	["en", "English"], ["es", "Español"], ["fr", "Français"], ["de", "Deutsch"], ["it", "Italiano"], ["pt", "Português"],
	["nl", "Nederlands"], ["eu", "Euskara"], ["ca", "Català"], ["pl", "Polski"], ["sv", "Svenska"], ["tr", "Türkçe"],
]


func name_of() -> String:
	return "none"


## strokes: Array of {x: PackedFloat32Array, y: PackedFloat32Array, t: PackedFloat32Array}; area: Vector2 (width, height of the writing box).
func recognize(_strokes: Array, _area: Vector2, _language: String, done: Callable) -> void:
	done.call({"ok": false, "candidates": PackedStringArray(), "error": "No handwriting recogniser is set up."})
