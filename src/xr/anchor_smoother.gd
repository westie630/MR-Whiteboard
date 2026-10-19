class_name AnchorSmoother
extends RefCounted
## Steadies the room anchor's pose before the circuit and the panels are glued to it. The headset reports a spatial anchor's pose
## afresh every frame, and it wanders by fractions of a millimetre and hundredths of a degree as the headset refines its map of the
## room (more while the head moves); applied raw, that shakes the circuit. The anchor is only there to correct slow drift and the
## jumps of a re-localisation, so:
##  - the raw pose is low-passed first (`TAU_FILTER`), which takes out the frame-to-frame noise;
##  - the held pose does not move while the filtered one stays within a few millimetres and a fraction of a degree of it (`DEAD_*`);
##  - beyond that it eases over to it (`TAU_EASE`) until it is there again (`SETTLE_*`), so a real shift is followed all the way;
##  - a big jump (`SNAP_*`: the headset re-localised, or a new anchor) is taken at once, as is the first pose after reset().
## Only the position and the turn about the vertical are kept (the circuit stands level), so tilt noise never reaches the panels.

const TAU_FILTER := 0.4                  # s: low-pass of the raw pose
const TAU_EASE := 0.25                   # s: how quickly the held pose catches up once it moves
const DEAD_M := 0.004                    # the held pose ignores differences smaller than these...
const DEAD_DEG := 0.25
const SETTLE_M := 0.0005                 # ...and once moving, stops when this close
const SETTLE_DEG := 0.03
const SNAP_M := 0.10                     # a jump at least this big is taken at once
const SNAP_DEG := 5.0

var held := Transform3D.IDENTITY         # the pose to use (valid when has_pose())
var _has := false
var _moving := false
var _f_pos := Vector3.ZERO               # the low-passed raw pose
var _f_yaw := 0.0
var _h_pos := Vector3.ZERO
var _h_yaw := 0.0


func has_pose() -> bool:
	return _has


## Forget the held pose: the next one fed is taken as it is (after a restore, a new anchor, or the circuit being moved by hand).
func reset() -> void:
	_has = false
	_moving = false


## Feed this frame's raw anchor pose; returns the pose to apply.
func feed(raw: Transform3D, dt: float) -> Transform3D:
	var pos := raw.origin
	var yaw := raw.basis.get_euler(EULER_ORDER_YXZ).y
	if not _has or pos.distance_to(_h_pos) > SNAP_M or absf(angle_difference(_h_yaw, yaw)) > deg_to_rad(SNAP_DEG):
		_snap(pos, yaw)
		return held
	var k := 1.0 - exp(-maxf(dt, 0.0) / TAU_FILTER)
	_f_pos = _f_pos.lerp(pos, k)
	_f_yaw += angle_difference(_f_yaw, yaw) * k
	var d := _f_pos.distance_to(_h_pos)
	var a := absf(angle_difference(_h_yaw, _f_yaw))
	if not _moving and (d > DEAD_M or a > deg_to_rad(DEAD_DEG)):
		_moving = true
	if _moving:
		var e := 1.0 - exp(-maxf(dt, 0.0) / TAU_EASE)
		_h_pos = _h_pos.lerp(_f_pos, e)
		_h_yaw += angle_difference(_h_yaw, _f_yaw) * e
		if _f_pos.distance_to(_h_pos) < SETTLE_M and absf(angle_difference(_h_yaw, _f_yaw)) < deg_to_rad(SETTLE_DEG):
			_moving = false
		held = _pose(_h_pos, _h_yaw)
	return held


func _snap(pos: Vector3, yaw: float) -> void:
	_has = true
	_moving = false
	_f_pos = pos
	_f_yaw = yaw
	_h_pos = pos
	_h_yaw = yaw
	held = _pose(pos, yaw)


static func _pose(pos: Vector3, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, wrapf(yaw, -PI, PI)), pos)
