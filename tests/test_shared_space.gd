extends Node
## The maths of a shared room: two headsets with different tracking spaces agree on a frame made of two touched points, and "here"
## stands a board in front of someone.

var t := TestCase.new("shared_space")


func _ready() -> void:
	frame_from_points()
	two_headsets_agree()
	here_in_front()
	stand_with_someone()
	gaze_and_facing()
	get_tree().quit(t.done())


## A tracking space as the physical room sees it: the pose of the headset's origin is yaw about up and a slide on the floor, so a
## physical point `x` is `space * x` for that headset.
func tracking_space(yaw_deg: float, shift: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), shift)


func frame_from_points() -> void:
	var f := SharedSpace.from_points(Vector3(1, 0.74, 2), Vector3(2.5, 0.78, 2))
	t.check(f.ok, "two points 1.5 m apart make a frame")
	t.near(f.span, 1.5, 1e-5, "the span is the distance along the floor")
	var xf: Transform3D = f.xf
	t.check(xf.origin.is_equal_approx(Vector3(1, 0.74, 2)), "the frame starts at the first point")
	t.check(xf.basis.x.is_equal_approx(Vector3.RIGHT), "x runs from the first point to the second")
	t.check(xf.basis.y.is_equal_approx(Vector3.UP), "y is up whatever the points' heights")
	t.check(xf.basis.determinant() > 0.99, "a proper rotation, not a mirror")
	var close := SharedSpace.from_points(Vector3.ZERO, Vector3(0.3, 0.5, 0.2))
	t.check(not close.ok and close.reason == "close", "points too close together are refused (a tall pair is still close on the floor)")
	var steep := SharedSpace.from_points(Vector3(0, 0, 0), Vector3(0.0, 1.5, 0.7))
	t.check(steep.ok, "points a table apart with a height difference still count")
	# the same two physical points, touched in the other order, are another frame (turned half way round)
	var back := SharedSpace.from_points(Vector3(2.5, 0.78, 2), Vector3(1, 0.74, 2))
	t.near(absf(back.xf.basis.x.dot(xf.basis.x)), 1.0, 1e-5, "the other order points the other way")
	t.check(back.xf.basis.x.dot(xf.basis.x) < 0.0, "...so everybody has to touch them in the same order")


func two_headsets_agree() -> void:
	# the room: two physical points on a table, and a physical thing somewhere else (the corner of a poster)
	var pa := Vector3(3.0, 0.75, -1.0)
	var pb := Vector3(4.2, 0.75, -2.1)
	var poster := Vector3(-1.0, 1.6, 2.0)
	# two headsets that started up in different places facing different ways: tracking = space * physical
	var s1 := tracking_space(37.0, Vector3(1.2, 0.0, -0.4))
	var s2 := tracking_space(-112.0, Vector3(-3.0, 0.0, 5.0))
	var f1: Transform3D = SharedSpace.from_points(s1 * pa, s1 * pb).xf
	var f2: Transform3D = SharedSpace.from_points(s2 * pa, s2 * pb).xf
	# headset 1 puts a mark on the poster, in the shared space...
	var in_p := f1.affine_inverse() * (s1 * poster)
	# ...and headset 2 shows it where the poster really is
	var shown := f2 * in_p
	var want := s2 * poster
	t.check(shown.distance_to(want) < 1e-4, "a point sent in the shared space lands on the same real place for the other headset (off by %.5f)" % shown.distance_to(want))
	# a pose (a head, a canvas) keeps its turn too
	var head1 := Transform3D(Basis(Vector3.UP, deg_to_rad(10.0)), s1 * Vector3(0, 1.6, 0))
	var head_in_p := f1.affine_inverse() * head1
	var head_seen_by_2 := f2 * head_in_p
	var truth := s2 * (s1.affine_inverse() * head1)
	t.check(head_seen_by_2.origin.distance_to(truth.origin) < 1e-4, "a head is seen where it is")
	t.check(head_seen_by_2.basis.get_rotation_quaternion().angle_to(truth.basis.get_rotation_quaternion()) < 1e-4, "...looking the way it looks")
	# touching the points a little inaccurately: 5 mm off on the second point of one headset, 1.5 m apart: a fraction of a degree
	var f3: Transform3D = SharedSpace.from_points(s2 * pa, s2 * pb + Vector3(0.0, 0.0, 0.005)).xf
	var err := (f3 * in_p).distance_to(want)
	t.check(err < 0.03, "a 5 mm slip on the second point moves a mark 3 m away by under 3 cm (%.1f mm)" % (err * 1000.0))


func here_in_front() -> void:
	# a board at (2, 1.4, 3) facing +x (towards a viewer standing on +x), seen from a head at (10, 1.7, -4) looking along -z
	var board_pos := Vector3(2.0, 1.4, 3.0)
	var facing := Vector3.RIGHT
	var head := Transform3D(Basis.IDENTITY, Vector3(10, 1.7, -4))
	var f := SharedSpace.here(board_pos, facing, head)
	var at := f * board_pos
	t.near(at.x, 10.0, 1e-4, "the board is straight ahead of the head (x)")
	t.near(at.z, -4.0 - SharedSpace.HERE_DIST, 1e-4, "the board is HERE_DIST in front of the head")
	t.near(at.y, 1.4, 1e-5, "heights are kept: the floor is still the floor")
	var turned := f.basis * facing
	t.check(turned.is_equal_approx(Vector3.BACK), "the board faces the head")
	t.check(f.basis.is_equal_approx(f.basis.orthonormalized()), "only a turn: nothing is scaled or tilted")
	t.check(f.basis.y.is_equal_approx(Vector3.UP), "upright stays upright")
	# the same, with the head turned 90 degrees to the left
	var head2 := Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3(0, 1.5, 0))
	var f2 := SharedSpace.here(board_pos, facing, head2)
	var ahead := -head2.basis.z
	t.check(((f2 * board_pos) - Vector3(0, 1.4, 0)).normalized().is_equal_approx(Vector3(ahead.x, 0.0, ahead.z).normalized()), "wherever the head looks, the board is there")
	t.check((f2.basis * facing).is_equal_approx(-Vector3(ahead.x, 0.0, ahead.z).normalized()), "...facing back at it")


func stand_with_someone() -> void:
	var theirs := Transform3D(Basis(Vector3.UP, deg_to_rad(30.0)), Vector3(2, 1.7, -1))
	var mine := Transform3D(Basis(Vector3.UP, deg_to_rad(-80.0)), Vector3(-5, 1.5, 4))
	var f := SharedSpace.stand_with(theirs, mine)
	var at := f * theirs.origin
	t.near(at.x, -5.0, 1e-4, "their head lands on mine (x)")
	t.near(at.z, 4.0, 1e-4, "their head lands on mine (z)")
	var look := f.basis * SharedSpace.gaze(theirs)
	t.check(look.is_equal_approx(SharedSpace.gaze(mine)), "and they look where I look")


func gaze_and_facing() -> void:
	var down := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-80.0)), Vector3(0, 1.6, 0))
	t.check(SharedSpace.gaze(down).dot(Vector3.FORWARD) > 0.9, "looking at the floor still has a heading: the way the top of the head points")
	var up := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(80.0)), Vector3(0, 1.6, 0))
	t.check(SharedSpace.gaze(up).dot(Vector3.FORWARD) > 0.9, "and looking at the ceiling too")
	var wall := Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3(0, 1.4, 0))        # a canvas standing up, turned so its front faces +x
	t.check(SharedSpace.facing_of(wall).is_equal_approx(Vector3(1, 0, 0)), "an upright canvas faces along its normal")
	var desk := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-90.0)), Vector3(0, 0.75, 0))   # lying flat, front up, its top pointing along -z
	var top := desk.basis.y
	t.check(SharedSpace.facing_of(desk).dot(Vector3(top.x, 0, top.z).normalized()) < -0.99, "a flat canvas faces the side opposite its top, so it reads upright from there")
	t.check(SharedSpace.close(Transform3D.IDENTITY, Transform3D(Basis.IDENTITY, Vector3(0.001, 0, 0))), "a millimetre is not worth announcing")
	t.check(not SharedSpace.close(Transform3D.IDENTITY, Transform3D(Basis.IDENTITY, Vector3(0.01, 0, 0))), "a centimetre is")
