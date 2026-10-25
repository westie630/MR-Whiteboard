class_name FrameData
extends RefCounted
## A frame is a coordinate system fixed in a room by a spatial anchor. Two kinds:
##   canvas: a flat drawing surface (grid, shapes, text) - items live in its xy plane
##   volume: a "3D sketch" - free strokes drawn in the air, moved as one object
## `xf` is its pose in room space (relative to the room's anchor), `anchor` the frame's own spatial anchor.

const CANVAS := "canvas"
const VOLUME := "volume"

var id := ""
var name := ""
var kind := CANVAS
var room := ""
var xf := Transform3D.IDENTITY            # pose in room space
var scale := 1.0
var size := Vector2(1.2, 0.8)             # nominal canvas size (m at scale 1); it grows to fit the content
var offset := Vector2.ZERO                # centre of the nominal rectangle in the frame (it is not always on the origin after a resize)
var anchor := ""                          # uuid of this frame's own spatial anchor ("" = none yet)
var anchor_xf := Transform3D.IDENTITY     # the room-space pose the anchor was created at
var anchor_guess := false                 # the anchor was made while the room's place was only guessed (its anchors not found): it is
                                          # where the user put the canvas, but anchor_xf is relative to the guess
var grid := ""                            # "" = app default
var backing := ""
var locked := false
var created := 0
## A canvas on a physical surface (the desk), found with the stylus nib: it can slide and turn along that surface and be scaled, but never leaves it.
var surface := false
var plane_point := Vector3.ZERO           # a point of the surface (room space)
var plane_normal := Vector3.UP            # its normal, towards the side the canvas faces (room space)
var plane_error := 0.0                    # how far the points it was found from strayed from flat (rms, m)
var plane_points := 0                     # how many points it stands on
## A curved desk (DeskBend): the canvas is the surface in front of you that lies on the desk, bends up at `bend_at` metres from your edge through a
## quarter circle of `bend_radius` and climbs the wall. `offset` and `size` are then the shown window in surface coordinates (not in the canvas's),
## and `bend_pan` is how far the contents have slid along the surface: moving them away from you is making `bend_pan.y` larger.
var bend := false
var bend_at := DeskBend.DEFAULT_AT
var bend_radius := DeskBend.DEFAULT_RADIUS
var bend_pan := Vector2.ZERO
## A canvas that shows a PDF: its pages are drawn on the canvas (sharp at any size) and what is drawn on it belongs to the page it was drawn on.
var pdf := ""                             # the PDF's content id (PdfLibrary): "" for an ordinary canvas
var page := 1                             # the page shown (1 = the first); everybody following the owner shows this one
var pdf_pages := 0                        # how many pages it has (so every headset can say "3 / 12" before it has the file)
var pdf_width := 0.0                      # the page's width in metres (at scale 1) when it is put down; a page of another shape keeps the width


static func make(kind_id: String, room_id: String, pose: Transform3D, frame_name: String = "") -> FrameData:
	var f := FrameData.new()
	f.id = U.uid("f")
	f.kind = kind_id
	f.room = room_id
	f.xf = pose
	f.name = frame_name
	f.created = int(Time.get_unix_time_from_system())
	return f


func to_dict() -> Dictionary:
	return {"id": id, "name": name, "kind": kind, "room": room, "xf": U.xf_to_array(xf), "scale": snappedf(scale, 1e-5),
		"size": U.v2_to_array(size), "offset": U.v2_to_array(offset), "anchor": anchor, "anchor_xf": U.xf_to_array(anchor_xf), "anchor_guess": anchor_guess, "grid": grid, "backing": backing,
		"locked": locked, "created": created, "surface": surface,
		"plane": [snappedf(plane_point.x, 1e-5), snappedf(plane_point.y, 1e-5), snappedf(plane_point.z, 1e-5),
			snappedf(plane_normal.x, 1e-6), snappedf(plane_normal.y, 1e-6), snappedf(plane_normal.z, 1e-6)],
		"plane_error": snappedf(plane_error, 1e-5), "plane_points": plane_points,
		"bend": [snappedf(bend_at, 1e-5), snappedf(bend_radius, 1e-5), snappedf(bend_pan.x, 1e-5), snappedf(bend_pan.y, 1e-5)] if bend else [],
		"pdf": pdf, "page": page, "pdf_pages": pdf_pages, "pdf_width": snappedf(pdf_width, 1e-5)}


static func from_dict(d: Dictionary) -> FrameData:
	var f := FrameData.new()
	f.id = str(d.get("id", U.uid("f")))
	f.name = str(d.get("name", ""))
	f.kind = str(d.get("kind", CANVAS))
	f.room = str(d.get("room", ""))
	f.xf = U.xf_from_array(d.get("xf"))
	f.scale = float(d.get("scale", 1.0))
	f.size = U.v2_from(d.get("size"), Vector2(1.2, 0.8))
	f.offset = U.v2_from(d.get("offset"))
	f.anchor = str(d.get("anchor", ""))
	f.anchor_xf = U.xf_from_array(d.get("anchor_xf"))
	f.anchor_guess = bool(d.get("anchor_guess", false))
	f.grid = str(d.get("grid", ""))
	f.backing = str(d.get("backing", ""))
	f.locked = bool(d.get("locked", false))
	f.created = int(d.get("created", 0))
	f.surface = bool(d.get("surface", false))
	var pl: Variant = d.get("plane")
	if pl is Array and (pl as Array).size() >= 6:
		f.plane_point = Vector3(pl[0], pl[1], pl[2])
		f.plane_normal = Vector3(pl[3], pl[4], pl[5]).normalized()
	f.plane_error = float(d.get("plane_error", 0.0))
	f.plane_points = int(d.get("plane_points", 0))
	var bd: Variant = d.get("bend")
	if bd is Array and (bd as Array).size() >= 4:
		f.bend = true
		f.bend_at = DeskBend.clamp_at(float(bd[0]))
		f.bend_radius = DeskBend.clamp_radius(float(bd[1]))
		f.bend_pan = Vector2(clampf(float(bd[2]), -1e4, 1e4), clampf(float(bd[3]), -1e4, 1e4))
	f.pdf = str(d.get("pdf", ""))
	f.page = maxi(int(d.get("page", 1)), 1)
	f.pdf_pages = maxi(int(d.get("pdf_pages", 0)), 0)
	f.pdf_width = float(d.get("pdf_width", 0.0))
	return f


func copy() -> FrameData:
	return FrameData.from_dict(to_dict())


func is_pdf() -> bool:
	return pdf != ""


## The part of a curved desk that is shown, in surface coordinates.
func bend_window() -> Rect2:
	return Rect2(offset - size * 0.5, size)


## Take another copy's spatial anchor (what only this device knows about the frame; not part of an undo or of what a session shares).
func keep_anchor_of(other: FrameData) -> void:
	anchor = other.anchor if other != null else ""
	anchor_xf = other.anchor_xf if other != null else Transform3D.IDENTITY
	anchor_guess = other.anchor_guess if other != null else false


## A pose in room space put onto the surface: the origin slides to the nearest point of it, the canvas's z axis is the surface's
## normal, and the turn about that normal is kept (the canvas's x axis, flattened onto the surface). Unchanged when not on a surface.
func on_surface(pose: Transform3D) -> Transform3D:
	if not surface:
		return pose
	var n := plane_normal.normalized()
	var o := pose.origin - n * n.dot(pose.origin - plane_point)
	var x := pose.basis.x - n * n.dot(pose.basis.x)
	if x.length() < 0.2:                                # standing edge-on to the surface: turn by the y axis instead
		x = pose.basis.y.cross(n)
	if x.length() < 1e-4:
		x = n.cross(Vector3.UP) if absf(n.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	x = x.normalized()
	return Transform3D(Basis(x, n.cross(x), n), o)


## Has the frame moved since its anchor was created (so a new anchor is needed)?
func anchor_stale() -> bool:
	if anchor == "":
		return true
	return xf.origin.distance_to(anchor_xf.origin) > 0.004 or xf.basis.get_rotation_quaternion().angle_to(anchor_xf.basis.get_rotation_quaternion()) > deg_to_rad(0.4)
