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
	"ink_auto": true,                # convert handwriting by itself after a pause (off: only when To text is pressed)
	"ink_pause": 2.0,                # seconds of rest before the automatic conversion
	"smart_ink": "suggest",          # the pen tool notices handwriting: suggest (offer to convert) | auto (convert clear writing) | off
	"speech_provider": "wit",        # wit | none
	"wit_token": "",                 # Wit.ai server access token (or put it in user://wit_token.txt)
	"ai_provider": "anthropic",      # LlmApi provider of the AI assistant: anthropic | openai | minimax
	"ai_key_anthropic": "",          # API keys (typed on the web page or in the assistant; kept only here, on the device)
	"ai_key_openai": "",
	"ai_key_minimax": "",
	"ai_model_anthropic": "",        # model id per provider ("" = the provider's suggested one)
	"ai_model_openai": "",
	"ai_model_minimax": "",
	"ai_think_anthropic": "default", # thinking mode per provider (an effort level, or "default")
	"ai_think_openai": "default",
	"ai_think_minimax": "default",
	"ai_picture": true,              # send a picture of the canvas along with its description
	"ai_note": true,                 # put answers in words on the canvas as a note too (they are always in the assistant's conversation)
	"vkeyboard": true,              # show the on-screen keyboard while a text field is being edited (a physical keyboard always works)
	"haptics": true,
	"stylus_hand": "auto",           # auto | left | right
	"finger_draw": false,            # draw with a pinch of the right hand when there is no stylus (off: both hands point and select)
	"ui_scale": 1.0,                 # size of the interface (PC: its scale; headset: the panels' size)
	"ui_fade": true,                 # the panels fade back while you draw
	"panel_pos": {},                 # PC: where the movable panels were dragged to (id -> offset from their home position)
	"last_doc": "",
	"sim_room": "A",                 # PC: which simulated room the anchors belong to
	"menu_tab": "docs",              # the Home panel's tab
	"text_style": "body",            # TextLayout style id for new typed and dictated text (the last one chosen)
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
