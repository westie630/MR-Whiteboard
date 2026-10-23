class_name FloatPanel
extends PanelContainer
## One floating surface of the interface (the dock, a popover, the bar beside a selection, a side panel ...). UiShell decides when it
## is wanted; the rig hosts it: on the PC it is placed over the 3D view, in the headset it floats in the room on its own XrPanel.
## Where it goes is described here and turned into a position by the rig:
##   kind "dock"     the toolbar: low in front of you (PC: bottom centre); movable
##   kind "popover"  opens from a dock button and sits above the dock, over that button
##   kind "side"     a larger card beside the dock (`side` = -1 left, 1 right); movable
##   kind "canvas"   pinned to a point of a canvas (`anchor`): beside the selection, the handwriting, the AI suggestion
##   kind "toast"    a message near the middle of the view
##   kind "compose"  the typing card, above the dock

var id := ""
var kind := "dock"
var shell                                  # UiShell (untyped: the shell refers to its panels too)
var wanted := false                        # the shell wants it shown; it fades in and out
var dim := 1.0                             # how opaque it is while shown (lowered while you draw)
var side := 1
var anchor := {}                           # kind "canvas": {frame: id, pos: Vector2 (canvas local), lift: m in front of the canvas}
var pivot := Vector2(0.5, 1.0)             # the point of the panel that sits on its anchor (0..1 of its size)
var max_size := Vector2(600, 400)          # the largest it gets (the headset renders it into a texture this big)
var movable := false
var source_x := 0.0                        # popover: the x (dock pixels) of the button it opened from
var ppm := 1450.0                          # headset: logical pixels per metre
var auto_size := true                      # shrink to the content whenever it changes

var _alpha := 0.0
var _kit := UiKit.new()


func _init() -> void:
	theme = UITheme.theme()
	add_theme_stylebox_override("panel", UITheme.glass())
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	modulate.a = 0.0


func _ready() -> void:
	reset_size()


## Override: bring the contents in step with the board and the settings (called when something changed).
func refresh() -> void:
	_kit.sync()


func is_shown() -> bool:
	return visible and _alpha > 0.5


func _process(delta: float) -> void:
	var goal := dim if wanted else 0.0
	if not is_equal_approx(_alpha, goal):
		_alpha = move_toward(_alpha, goal, delta * (9.0 if wanted else 12.0))
	modulate.a = _alpha
	var show := wanted or _alpha > 0.01
	if visible != show:
		visible = show
	if auto_size and visible:
		var m := get_combined_minimum_size()
		if not size.is_equal_approx(m):
			size = m


## Show or hide at once (tests, first frame).
func snap_fade() -> void:
	_alpha = dim if wanted else 0.0
	modulate.a = _alpha
	visible = wanted


func kit() -> UiKit:
	return _kit
