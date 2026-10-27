class_name PenState
extends RefCounted
## What the board needs to know about the pen each frame, whatever supplies it: the MX Ink stylus in the headset, the mouse
## (or a graphics tablet) on the PC, or a pinch when no stylus is present.

var tracked := false
var source := "none"                      # stylus | mouse | pinch
var tip := Vector3.ZERO                   # world position of the nib
var dir := Vector3.FORWARD                # world direction the stylus points in
var basis := Basis.IDENTITY               # the stylus's orientation (its aim pose; the mouse keeps the identity)
var pressure := 0.0                       # 0..1
var down := false                         # the nib is pressed (tip force or middle button) / mouse button held
var contact := false                      # the nib itself is pressed against something (not the middle button): the stylus feels a surface
var front := false                       # front (grab) button held
var back := false                         # back button held
var docked := false
var haptic := Callable()                  # (amplitude: float, seconds: float) -> void, set by the rig


func tick(amplitude: float = 0.4, seconds: float = 0.02) -> void:
	if haptic.is_valid() and bool(App.val("haptics")):
		haptic.call(amplitude, seconds)
