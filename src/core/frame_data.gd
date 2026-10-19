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
var grid := ""                            # "" = app default
var backing := ""
var locked := false
var created := 0


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
		"size": U.v2_to_array(size), "offset": U.v2_to_array(offset), "anchor": anchor, "anchor_xf": U.xf_to_array(anchor_xf), "grid": grid, "backing": backing,
		"locked": locked, "created": created}


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
	f.grid = str(d.get("grid", ""))
	f.backing = str(d.get("backing", ""))
	f.locked = bool(d.get("locked", false))
	f.created = int(d.get("created", 0))
	return f


func copy() -> FrameData:
	return FrameData.from_dict(to_dict())


## Has the frame moved since its anchor was created (so a new anchor is needed)?
func anchor_stale() -> bool:
	if anchor == "":
		return true
	return xf.origin.distance_to(anchor_xf.origin) > 0.004 or xf.basis.get_rotation_quaternion().angle_to(anchor_xf.basis.get_rotation_quaternion()) > deg_to_rad(0.4)
