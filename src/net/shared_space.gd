class_name SharedSpace
extends RefCounted
## The maths of a shared room. Every headset has its own tracking space, so two people looking at the same canvas disagree about where
## it is until they agree on a common frame: the session's shared space P. Everything on the wire is in P; each participant holds F,
## the pose of P in its own tracking space (local = F * p, p = F.affine_inverse() * local), and converts at the edge.
##
## Two ways to get F, both gravity-aligned (a headset's floor is level, so F only turns about up and slides):
##   points   everyone presses the stylus on the same two real places, in the same order (two corners of a table): the frame those two
##            points make is the same physical frame for everybody, so every F is that frame as seen from its own tracking space
##   here     not in the same room: F stands the session's board in front of me, facing me, wherever I am

const MIN_SPAN := 0.6                      # the two points must be this far apart (m, along the floor): yaw error = point error / span
const HERE_DIST := 1.1                     # "here": the board is put this far in front of the head (m)


## The frame two touched points make: origin at `a`, x along the floor towards `b`, y up. {ok, xf, span, reason}.
static func from_points(a: Vector3, b: Vector3) -> Dictionary:
	var h := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var span := h.length()
	if span < MIN_SPAN:
		return {"ok": false, "xf": Transform3D.IDENTITY, "span": span, "reason": "close"}
	var x := h / span
	return {"ok": true, "xf": Transform3D(Basis(x, Vector3.UP, x.cross(Vector3.UP)), a), "span": span, "reason": ""}


## The yaw (turn about up) that points a forward vector's floor part: Basis(UP, heading(v)) * -Z has the direction of v.
static func heading(v: Vector3) -> float:
	return atan2(-v.x, -v.z)


## Where a head is looking along the floor: its forward, or, with the head tipped right back or down, the way its top points.
static func gaze(head: Transform3D) -> Vector3:
	var f := -head.basis.z
	var h := Vector3(f.x, 0.0, f.z)
	if h.length() < 0.25:
		var u := head.basis.y if f.y < 0.0 else -head.basis.y
		h = Vector3(u.x, 0.0, u.z)
	return h.normalized() if h.length() > 0.001 else Vector3.FORWARD


## F that stands a board at `board_pos` (in P) whose front faces `board_facing` (in P, only its floor part counts) in front of `head`:
## `HERE_DIST` away along the gaze, facing the head. The floor stays the floor (no change in height).
static func here(board_pos: Vector3, board_facing: Vector3, head: Transform3D, dist: float = HERE_DIST) -> Transform3D:
	var g := gaze(head)
	var turn := heading(-g) - heading(board_facing)
	var rot := Basis(Vector3.UP, turn)
	var c := Vector3(board_pos.x, 0.0, board_pos.z)
	var w := Vector3(head.origin.x, 0.0, head.origin.z) + g * dist
	return Transform3D(rot, w - rot * c)


## F that puts P's point `p_head` (a head in P) onto my head: I stand where that person stands. For a board that does not exist yet.
static func stand_with(p_head: Transform3D, my_head: Transform3D) -> Transform3D:
	return flat(my_head) * flat(p_head).affine_inverse()


## A pose reduced to what gravity allows: turned about up only, on the floor under it.
static func flat(t: Transform3D) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, heading(gaze(t))), Vector3(t.origin.x, 0.0, t.origin.z))


## The direction a canvas faces, along the floor, for putting it in front of someone: its normal when it stands up, the way its top
## points away from you when it lies flat (so that it reads right way up from where you stand).
static func facing_of(pose: Transform3D) -> Vector3:
	var n := pose.basis.z
	var h := Vector3(n.x, 0.0, n.z)
	if h.length() >= 0.5:
		return h.normalized()
	var top := Vector3(pose.basis.y.x, 0.0, pose.basis.y.z)
	return (-top).normalized() if top.length() > 0.001 else Vector3.BACK


## Do two poses differ by less than a step worth announcing?
static func close(a: Transform3D, b: Transform3D, metres: float = 0.002, degrees: float = 0.15) -> bool:
	return a.origin.distance_to(b.origin) <= metres and a.basis.get_rotation_quaternion().angle_to(b.basis.get_rotation_quaternion()) <= deg_to_rad(degrees)
