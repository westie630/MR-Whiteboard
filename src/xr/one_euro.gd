class_name OneEuro3
extends RefCounted
## One-euro low-pass filter for a 3D point: heavy smoothing while the hand is nearly still (kills the tracking
## jitter that makes a pointer shake) and almost none while it moves fast (so it still feels instant).

var min_cutoff := 1.0          # Hz: smoothing at rest (lower = steadier)
var beta := 0.0                # how quickly smoothing relaxes with speed (higher = more responsive)
var d_cutoff := 1.0
var _x := Vector3.ZERO
var _dx := Vector3.ZERO
var _ready_ := false


func _init(min_c: float = 1.0, b: float = 0.0) -> void:
	min_cutoff = min_c
	beta = b


func reset() -> void:
	_ready_ = false


func filter(v: Vector3, dt: float) -> Vector3:
	if not _ready_:
		_x = v
		_dx = Vector3.ZERO
		_ready_ = true
		return v
	dt = maxf(dt, 1e-4)
	var d := (v - _x) / dt
	_dx = _dx.lerp(d, _alpha(d_cutoff, dt))
	var cutoff := min_cutoff + beta * _dx.length()
	_x = _x.lerp(v, _alpha(cutoff, dt))
	return _x


static func _alpha(cutoff: float, dt: float) -> float:
	var tau := 1.0 / (TAU * cutoff)
	return 1.0 / (1.0 + tau / dt)
