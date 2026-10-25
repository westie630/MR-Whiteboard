class_name SurfaceController
extends RefCounted
## The desk. A canvas can stand on a real surface that the stylus nib has felt: the tip force sensor tells when the nib touches
## something, so pressing it on the desk in a few places (or rubbing it across) gives points of the desk's top, and a plane is fitted
## through them. The canvas then lies on that plane and is bound to it: carried, turned and scaled it slides along the surface and
## never leaves it (FrameData.on_surface, applied by the Board to every grab). While you draw on it, every touch of the nib is one more
## measurement of the desk, and the canvas follows the surface if the headset's idea of it drifts (tracking) or if the first guess was
## a little tilted.
##   finding   the calibration: points from the nib, the fitted plane, a preview of the canvas on it; finish() creates the canvas (or
##             pins an existing one to the desk), cancel() drops it
##   tracking  the measurements made while drawing on a desk canvas

const STEP := 0.02                         # rubbing: a point every this far (m)
const TAP_S := 0.12                        # a press shorter than this is one point (its average)
const MAX_POINTS := 240
const NEAR := 0.04                         # a nib this close to a desk canvas's plane is feeling the desk
const TRACK_STEP := 0.03                   # tracking: a measurement every this far while rubbing along it
const TRACK_MAX := 64
const TRACK_EVERY := 4                     # ...and the plane is reconsidered after this many new ones
const SHIFT_MIN := 0.004                   # the surface is this much (m) off the plane before the canvas is moved to it
const TILT_MIN := 0.0087                   # a refit turns the plane only when it differs by this (rad, half a degree)...
const TILT_MAX := 0.14                     # ...and by no more than this (8 degrees): a bigger difference is not the desk
const TRACK_SPAN := 0.25                   # the measurements must span this much (m) of the desk before its tilt is refitted
const TRACK_MIN := 12
const MARK_R := 0.006

var board: Board
var calib := {}                            # {target, size, points: PackedVector3Array, fit, ghost, tmp, marks, press}; empty = not finding
var _track := {}                           # frame id -> {pts: PackedVector3Array (room space), last: Vector3, down: bool, fresh: int}
var _was_back := false


func _init(b: Board) -> void:
	board = b


func finding() -> bool:
	return not calib.is_empty()


# ------------------------------------------------------------------------------------------------ finding the desk

## Start finding the desk. `target` is a canvas to pin to it afterwards ("" = a new canvas of `size`). `curved`: the canvas becomes a curved
## desk (DeskBend): aligned to you, it lies on the desk and bends up into a wall.
func begin(target: String = "", size: Vector2 = Vector2(1.2, 0.8), curved: bool = false) -> void:
	if board.doc == null:
		return
	board.cancel_place()
	cancel()
	var f: FrameData = board.doc.frames.get(target) if target != "" else null
	if f != null:
		if f.locked:
			board.toast.emit("That canvas is locked.")
			return
		size = f.size
	var tmp := Document.create("ghost")
	var gf := FrameData.make(FrameData.CANVAS, "", Transform3D.IDENTITY, "")
	gf.size = size
	var ghost := FrameNode.new()
	board.add_child(ghost)
	ghost.setup(gf, tmp)
	ghost.set_hover(1.0)
	ghost.visible = false
	var marks := Node3D.new()
	marks.name = "SurfaceMarks"
	board.add_child(marks)
	calib = {"target": target, "size": size, "curved": curved, "points": PackedVector3Array(), "fit": PlaneFit.fit(PackedVector3Array()), "ghost": ghost, "tmp": tmp,
		"marks": marks, "press": {"down": false, "acc": PackedVector3Array(), "t": 0.0, "added": false, "last": Vector3.ZERO}}
	_was_back = false
	board.toast.emit("Press the stylus tip on your desk in a few places, or rub it across. The canvas will %s." % ("lie on it and curve up at its far end" if curved else "lie on it"))
	board.changed.emit()


func cancel() -> void:
	if calib.is_empty():
		return
	(calib.ghost as Node).queue_free()
	(calib.marks as Node).queue_free()
	calib = {}
	board.changed.emit()


## The document closed: nothing is being found, nothing is tracked.
func reset() -> void:
	cancel()
	_track.clear()


## Forget the points and start again.
func restart() -> void:
	if calib.is_empty():
		return
	calib.points = PackedVector3Array()
	for c in (calib.marks as Node).get_children():
		c.queue_free()
	_refit()
	board.changed.emit()


## What the interface shows: {finding, points, ok, reason, rms_mm, tilt_deg, extent}.
func status() -> Dictionary:
	if calib.is_empty():
		return {"finding": false, "points": 0, "ok": false, "reason": "", "rms_mm": 0.0, "tilt_deg": 0.0, "extent": Vector2.ZERO}
	var fit: Dictionary = calib.fit
	var plot := PackedVector2Array()                  # the points in the surface's own directions (m, round their middle)
	for p in (calib.points as PackedVector3Array):
		var d: Vector3 = p - (fit.point as Vector3)
		plot.append(Vector2(d.dot(fit.u), d.dot(fit.v)))
	return {"finding": true, "points": (calib.points as PackedVector3Array).size(), "ok": bool(fit.ok), "reason": str(fit.reason),
		"rms_mm": float(fit.rms) * 1000.0, "tilt_deg": rad_to_deg(acos(clampf(absf((fit.normal as Vector3).dot(Vector3.UP)), 0.0, 1.0))),
		"extent": fit.extent, "plot": plot}


## Every frame while finding: the nib's presses are the measurements. The back button cancels.
func update(pen: PenState, dt: float) -> void:
	if calib.is_empty():
		return
	if pen.back and not _was_back:
		_was_back = true
		cancel()
		board.toast.emit("Cancelled: no desk was set.")
		return
	_was_back = pen.back
	var pr: Dictionary = calib.press
	if pen.tracked and pen.contact:
		if not bool(pr.down):
			pr.down = true
			pr.acc = PackedVector3Array()
			pr.t = 0.0
			pr.added = false
		var acc: PackedVector3Array = pr.acc
		acc.append(pen.tip)
		pr.acc = acc
		pr.t = float(pr.t) + dt
		if not bool(pr.added):
			if float(pr.t) >= TAP_S:
				_add_point(_mean(pr.acc), pen)
				pr.added = true
				pr.last = pen.tip
		elif pen.tip.distance_to(pr.last) >= STEP:
			_add_point(pen.tip, pen)
			pr.last = pen.tip
	elif bool(pr.down):
		pr.down = false
		if not bool(pr.added) and not (pr.acc as PackedVector3Array).is_empty():
			_add_point(_mean(pr.acc), pen)           # a quick tap is one point: where the nib was while it was pressed
		pr.acc = PackedVector3Array()


func _mean(pts: PackedVector3Array) -> Vector3:
	var s := Vector3.ZERO
	for p in pts:
		s += p
	return s / float(maxi(pts.size(), 1))


func _add_point(p: Vector3, pen: PenState) -> void:
	var pts: PackedVector3Array = calib.points
	if pts.size() >= MAX_POINTS:
		return
	pts.append(p)
	calib.points = pts
	var m := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = MARK_R
	sph.height = MARK_R * 2.0
	sph.radial_segments = 12
	sph.rings = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = UITheme.DESK
	mat.no_depth_test = true
	mat.render_priority = 120
	sph.material = mat
	m.mesh = sph
	m.position = p
	(calib.marks as Node3D).add_child(m)
	pen.tick(0.35, 0.02)
	_refit()
	board.changed.emit()


func _refit() -> void:
	var fit := PlaneFit.fit(calib.points)
	if (calib.points as PackedVector3Array).size() > 0:
		fit.normal = _facing_head(fit.point, fit.normal)
	calib.fit = fit
	var ghost: FrameNode = calib.ghost
	ghost.visible = bool(fit.ok)
	if bool(fit.ok):
		ghost.transform = pose_for(fit.point, fit.normal)


## The normal turned to the side the head is on (the canvas faces the user).
func _facing_head(point: Vector3, n: Vector3) -> Vector3:
	return n if n.dot(board.head.origin - point) >= 0.0 else -n


## World pose of a canvas lying on the surface at `point`: facing along the normal, its top pointing away from you on a flat desk
## (up on a wall).
func pose_for(point: Vector3, n: Vector3) -> Transform3D:
	var h := board.head
	var yb := Vector3.UP
	if absf(n.dot(Vector3.UP)) > 0.85:
		yb = Vector3(point.x - h.origin.x, 0.0, point.z - h.origin.z)
		if yb.length() < 0.05:
			yb = Vector3(-h.basis.z.x, 0.0, -h.basis.z.z)
		if yb.length() < 0.05:
			yb = Vector3.FORWARD
	yb = (yb - n * n.dot(yb)).normalized()
	return Transform3D(Basis(yb.cross(n).normalized(), yb, n), point)


## Make the canvas: a new one on the desk, or the one `begin` was given pinned to it. False (with a message) when the points are not enough.
func finish() -> bool:
	if calib.is_empty():
		return false
	var fit: Dictionary = calib.fit
	if not bool(fit.ok):
		board.toast.emit(reason_text(str(fit.reason)))
		return false
	var target := str(calib.target)
	var size: Vector2 = calib.size
	var curved := bool(calib.get("curved", false))
	if curved and (fit.normal as Vector3).normalized().y < Board.CURVE_LEVEL:
		board.toast.emit("A curved desk needs a level desk: this surface is too steep. Try the desk top.")
		return false
	var pose := pose_for(fit.point, fit.normal)
	var plane := {"point": fit.point, "normal": fit.normal, "error": float(fit.rms), "count": (calib.points as PackedVector3Array).size()}
	cancel()
	var f: FrameData = board.doc.frames.get(target) if target != "" else null
	if f == null:
		var made := board.add_frame(FrameData.CANVAS, pose, size, plane, {"bend": true} if curved else {})
		if made != null:
			board.toast.emit("Canvas \"%s\" curves up at the end of your desk. Move the markers on its left edge." % made.name if curved else "Canvas \"%s\" lies on your desk." % made.name)
		return made != null
	var rw: Variant = board.room_world(f.room)
	if rw == null:
		board.toast.emit("This canvas's room is not here, so it cannot be put on the desk.")
		return false
	var upd := f.copy()
	_set_plane(upd, rw as Transform3D, plane)
	upd.xf = upd.on_surface((rw as Transform3D).affine_inverse() * pose)
	if curved and not f.is_pdf():
		board.make_curved(upd, rw as Transform3D)
	board.history.do(History.op_frame(f, upd))
	board.active_frame = f.id
	board.toast.emit("\"%s\" now lies on your desk%s." % [f.name, " and curves up at its far end" if upd.bend else ""])
	return true


## Put a world-space plane ({point, normal, error, count}) on a frame as its surface.
func _set_plane(f: FrameData, rw: Transform3D, plane: Dictionary) -> void:
	f.surface = true
	f.plane_point = rw.affine_inverse() * (plane.point as Vector3)
	f.plane_normal = (rw.basis.orthonormalized().inverse() * (plane.normal as Vector3)).normalized()
	f.plane_error = float(plane.get("error", 0.0))
	f.plane_points = int(plane.get("count", 0))


## Fill in the surface of a frame about to be added (Board.add_frame).
func apply_plane(f: FrameData, rw: Variant, plane: Dictionary) -> void:
	_set_plane(f, rw as Transform3D if rw != null else Transform3D.IDENTITY, plane)


## A canvas leaves the desk: it can be carried anywhere again. `upright` also stands it up (see stood_up) instead of leaving it lying.
func release(frame_id: String, upright: bool = false) -> void:
	var f: FrameData = board.doc.frames.get(frame_id) if board.doc != null else null
	if f == null or not f.surface:
		return
	var upd := f.copy()
	upd.surface = false
	board.make_flat(upd)                                 # (a curved desk is only curved on the desk)
	if upright:
		var rw: Variant = board.room_world(f.room)
		var w: Transform3D = rw as Transform3D if rw != null else Transform3D.IDENTITY
		upd.xf = w.affine_inverse() * stood_up(w * upd.xf, upd)
	board.history.do(History.op_frame(f, upd))
	_track.erase(frame_id)
	if upright:
		board.toast.emit("\"%s\" stands upright and is free: it can be carried anywhere." % f.name)
	else:
		board.toast.emit("\"%s\" is free again: it can be carried anywhere." % f.name)


## A world pose of canvas `f` made vertical: top edge up, facing you, about the same middle. A canvas lying on a desk is turned up about
## its middle and lifted by half its height so it stands on the desk (not sunk into it); one already on a wall only has its roll taken out.
func stood_up(world_xf: Transform3D, f: FrameData) -> Transform3D:
	var mid := Vector3(f.offset.x, f.offset.y, 0.0) * f.scale        # the canvas's middle in its own frame
	var centre := world_xf * mid
	var n := world_xf.basis.orthonormalized().z
	var out := Vector3(n.x, 0.0, n.z)                                # on a wall: it already faces horizontally
	if absf(n.y) > 0.5:
		centre += Vector3.UP * (f.size.y * f.scale * 0.5)
		out = Vector3(board.head.origin.x - centre.x, 0.0, board.head.origin.z - centre.z)
		if out.length() < 0.05:                                       # head right above it: face where its top edge pointed away from
			var y := world_xf.basis.orthonormalized().y
			out = Vector3(-y.x, 0.0, -y.z)
	if out.length() < 0.05:
		out = Vector3.BACK
	var z := out.normalized()
	var basis := Basis(Vector3.UP.cross(z), Vector3.UP, z)
	return Transform3D(basis, centre - basis * mid)


static func reason_text(reason: String) -> String:
	match reason:
		"points":
			return "A few more points: press the nib on the desk in at least three places."
		"spread":
			return "Spread them out: the points are in a line or too close together. Rub the nib across the desk."
		"flat":
			return "That surface is not flat enough: keep to one flat part of the desk."
	return ""


# ------------------------------------------------------------------------------------------------ tracking the desk while drawing

## Every frame (not finding): a nib pressed on a desk canvas measures the desk. A few measurements make the canvas follow the
## surface: shifted when it drifted, turned when the first guess was tilted.
func track(pen: PenState, _dt: float) -> void:
	var down := pen.tracked and pen.contact
	for fn_any in board.visible_frames(FrameData.CANVAS):
		var fn := fn_any as FrameNode
		var f := fn.data
		if not f.surface or f.locked or board.grabs.has(f.id):
			continue
		var st: Dictionary = _track.get(f.id, {})
		if st.is_empty():
			st = {"pts": PackedVector3Array(), "last": Vector3.ZERO, "down": false, "fresh": 0}
			_track[f.id] = st
		if not down:
			st.down = false
			continue
		var l := fn.to_local_point(pen.tip)
		if absf(l.z) * f.scale > NEAR or not fn.bounds().grow(0.3 / f.scale).has_point(Vector2(l.x, l.y)):
			st.down = false
			continue
		if fn.bend != null and l.y + fn.bend.pan.y > fn.bend.at:
			st.down = false                                   # (on the bend or the wall the nib is not touching the desk)
			continue
		if bool(st.down) and pen.tip.distance_to(st.last) < TRACK_STEP:
			continue
		st.down = true
		st.last = pen.tip
		var rw: Variant = board.room_world(f.room)
		if rw == null or board.room_guessed(f.room):
			continue                                          # (shown at a guessed place: the nib there says nothing about the desk)
		var pts: PackedVector3Array = st.pts
		pts.append((rw as Transform3D).affine_inverse() * pen.tip)
		if pts.size() > TRACK_MAX:
			pts = pts.slice(pts.size() - TRACK_MAX)
		st.pts = pts
		st.fresh = int(st.fresh) + 1
		if int(st.fresh) >= TRACK_EVERY:
			st.fresh = 0
			if _refine(f, pts):
				st.pts = PackedVector3Array()                 # measured against the old plane: start again from the new one


## Consider the measurements of one desk canvas (room space): its tilt when they span the desk, else only how high the newest ones say
## the surface is. True when the canvas was moved.
func _refine(f: FrameData, pts: PackedVector3Array) -> bool:
	var n := f.plane_normal.normalized()
	var plane_point := f.plane_point
	var normal := n
	var rms := f.plane_error
	var changed := false
	if pts.size() >= TRACK_MIN:
		var fit := PlaneFit.fit(pts)
		if bool(fit.ok) and (fit.extent as Vector2).y >= TRACK_SPAN:
			var fn2: Vector3 = fit.normal
			if fn2.dot(n) < 0.0:
				fn2 = -fn2
			var ang := fn2.angle_to(n)
			if ang > TILT_MIN and ang < TILT_MAX and float(fit.rms) < 0.006:
				plane_point = fit.point
				normal = fn2
				rms = float(fit.rms)
				changed = true
	if not changed:
		var ds: Array = []                                # the median, so one touch on a book does not move the canvas
		for i in range(maxi(pts.size() - TRACK_EVERY, 0), pts.size()):
			ds.append(PlaneFit.signed_distance(pts[i], plane_point, n))
		ds.sort()
		var d: float = 0.0 if ds.is_empty() else (float(ds[ds.size() / 2]) + float(ds[(ds.size() - 1) / 2])) * 0.5
		if absf(d) >= SHIFT_MIN and absf(d) < NEAR:
			plane_point += n * d
			changed = true
	if not changed:
		return false
	var upd := f.copy()
	upd.plane_point = plane_point
	upd.plane_normal = normal
	upd.plane_error = rms
	upd.xf = upd.on_surface(f.xf)
	board.doc.replace_frame(upd)
	print("[surface] %s follows its desk: %.1f mm along the normal, turned %.2f deg" % [f.name, n.dot(plane_point - f.plane_point) * 1000.0, rad_to_deg(normal.angle_to(n))])
	return true
