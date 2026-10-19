extends Node
## Autoload "App": persistent settings (user://settings.cfg) and a few shared helpers.
## Tests point `settings_path` somewhere else so they never touch the real settings.

signal setting_changed(key: String)

const SETTINGS_PATH := "user://settings.cfg"
const DOCS_DIR := "user://docs"

const DEFAULTS := {
	"brush": "pen",                  # Brushes id
	"color": Color("#ffd166"),
	"width": 0.004,                  # metres, at full pressure
	"fill": false,                   # new shapes get a translucent fill in the pen colour
	"fill_alpha": 0.25,
	"recognize": "hold",             # off | hold (keep the pen still at the end of a stroke) | auto (every stroke)
	"hold_seconds": 0.55,
	"snap_connectors": true,         # arrow/line ends stick to shapes
	"tool": "draw",                  # Tools.Mode id
	"grid": "lines",                 # lines | dots | none
	"grid_minor": 0.05,
	"backing": "glass",              # none | glass | dark | white
	"grid_fade_viewer": 2.5,         # metres from a canvas at which its grid has faded away
	"grid_focus": 0.55,              # radius (m) of the lit grid around the pen / hand
	"ink_provider": "google",        # google | none
	"ink_language": "en",
	"haptics": true,
	"stylus_hand": "auto",           # auto | left | right
	"finger_draw": true,             # draw with a pinch when there is no stylus (so the app can be tried without one)
	"ui_scale": 1.0,                 # PC panel scale
	"last_doc": "",
	"sim_room": "A",                 # PC: which simulated room the anchors belong to
	"menu_tab": "draw",
	"xr_quality": "sharp",           # performance | sharp | ultra: render resolution in the headset
}

var settings_path := SETTINGS_PATH
var docs_dir := DOCS_DIR              # dev runs and tests point this at a scratch folder
var _s: Dictionary = {}
var _cfg := ConfigFile.new()
var xr_active := false               # set by the XR rig when an OpenXR session is running


func _ready() -> void:
	reload()


func reload() -> void:
	_s = DEFAULTS.duplicate()
	_cfg = ConfigFile.new()
	if _cfg.load(settings_path) == OK:
		for k in DEFAULTS.keys():
			if _cfg.has_section_key("settings", k):
				_s[k] = _cfg.get_value("settings", k)


func val(key: String) -> Variant:
	return _s.get(key, DEFAULTS.get(key))


func put(key: String, v: Variant, save: bool = true) -> void:
	if typeof(_s.get(key)) == typeof(v) and _s.get(key) == v:
		return
	_s[key] = v
	if save:
		_cfg.set_value("settings", key, v)
		_cfg.save(settings_path)
	setting_changed.emit(key)
