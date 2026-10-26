class_name LiveOut
extends RefCounted
## What this headset is in the middle of doing to the canvases, as a stream for the others of a session to show while it happens: the
## stroke being drawn (its points as they come), items being dragged, a shape being resized, a stencil being dragged out, what the
## eraser has touched, and a canvas being carried. Nothing here changes the document: when the stroke, drag or move is finished the
## ordinary edit (DocSync) arrives and takes over from the preview (LivePreview shows these on the other side).
##
## The pen's controllers are asked what they are doing (PenController.live_view) about 12 times a second; only what changed is sent, and a
## drag that stands still is repeated now and then so that the others know it is still going. Messages are dictionaries with a kind "k":
##   s  points of a stroke {key, id, f (frame), b, c, w, i (index of the first point), p (x y z pressure ...), vis}
##   e  a stroke ended {key, id, keep (it became an item with that id)}
##   d  items carried {key, f, ids, t}     w  a shape reshaped or a stencil dragged out {key, f, item, ghost}     x  erased {key, ids}
##   g  a canvas carried {f, xf (in its room), s (scale)}
## and for d, w, x, g: {end: true} says it is over.

const EVERY_S := 0.08
const BEAT_S := 0.4                        # a drag that is not changing is repeated this often
const MAX_POINTS := 400                    # points per message (a long stroke goes in several)

var board: Board

var _t := 0.0
var _beat := 0.0
var _sent := {}                            # "source/slot" -> what the others have been told


## Call every frame; returns the messages to send now (usually none).
func update(dt: float) -> Array:
	_t += dt
	if _t < EVERY_S:
		return []
	_beat += _t
	_t = 0.0
	var beat := _beat >= BEAT_S
	if beat:
		_beat = 0.0
	var out: Array = []
	var ctls: Array = [board.pen_ctl]
	ctls.append_array(board.hand_ctl.controllers())
	for i in ctls.size():
		var v: Dictionary = (ctls[i] as PenController).live_view()
		var key := "c%d" % i
		_stroke(key, v.get("stroke", {}), out)
		_slot(key, "d", v.get("drag", {}), beat, out)
		_slot(key, "w", v.get("work", {}), beat, out)
		_slot(key, "x", v.get("erase", {}), beat, out)
	_grabs(beat, out)
	return out


## Forget what the others were told (a new document, a new session): the next thing starts afresh.
func reset() -> void:
	_sent.clear()
	_t = 0.0


func _stroke(key: String, st: Dictionary, out: Array) -> void:
	var k := key + "/s"
	var had: Dictionary = _sent.get(k, {})
	if st.is_empty():
		if not had.is_empty():
			out.append(_end_of(key, str(had.id)))
			_sent.erase(k)
		return
	var pts: PackedFloat32Array = st.pts
	var n: int = mini(int(st.n), pts.size() / 4)
	if had.is_empty() or str(had.id) != str(st.id):
		if not had.is_empty():
			out.append(_end_of(key, str(had.id)))
		var first := mini(n, MAX_POINTS)
		out.append({"k": "s", "key": key, "id": st.id, "f": st.frame, "b": st.brush, "c": st.color, "w": st.width, "i": 0,
			"p": pts.slice(0, first * 4), "vis": st.vis})
		_sent[k] = {"id": st.id, "n": first, "vis": st.vis}
	elif n > int(had.n) or bool(st.vis) != bool(had.vis):
		var upto := mini(n, int(had.n) + MAX_POINTS)
		out.append({"k": "s", "key": key, "id": st.id, "i": had.n, "p": pts.slice(int(had.n) * 4, upto * 4), "vis": st.vis})
		had.n = upto
		had.vis = st.vis


func _end_of(key: String, id: String) -> Dictionary:
	return {"k": "e", "key": key, "id": id, "keep": board.doc != null and board.doc.items.has(id)}


## A thing that is either going on (sent when it changes, and now and then anyway) or not.
func _slot(key: String, slot: String, state: Dictionary, beat: bool, out: Array) -> void:
	var k := key + "/" + slot
	var had: Dictionary = _sent.get(k, {})
	if state.is_empty():
		if not had.is_empty():
			var done := {"k": slot, "key": key, "end": true}
			if slot == "w":                              # a shape that became an item with that id stays shown until the item is there
				done["keep"] = board.doc != null and board.doc.items.has(str((had.item as Dictionary).get("id", "")))
			out.append(done)
			_sent.erase(k)
		return
	if beat or had != state:
		var msg := state.duplicate()
		msg["k"] = slot
		msg["key"] = key
		out.append(msg)
		_sent[k] = state


## Canvases (and 3D models) being carried: where each is (in its room, as it is shown, so a canvas on the desk stays on it) and its scale.
func _grabs(beat: bool, out: Array) -> void:
	for fid in board.grabs.keys():
		var fn: FrameNode = board.frame_nodes.get(fid)
		var mn: ModelNode = board.model_nodes.get(fid)
		var node: Node3D = fn if fn != null else mn
		if node == null:
			continue
		var rw: Variant = board.room_world((fn.data if fn != null else mn.data).room)
		if rw == null:
			continue
		var xf := (rw as Transform3D).affine_inverse() * Transform3D(node.transform.basis.orthonormalized(), node.transform.origin)
		var st := {"xf": xf, "s": float((board.grabs[fid] as Dictionary).scale)}
		if fn != null and fn.bend != null:           # a curved desk: how far its contents have slid, and its bend, as they are now
			st.merge({"p": fn.bend.pan, "ba": fn.bend.at, "br": fn.bend.radius})
		if mn != null:                               # a 3D model: how far it is stretched along its own axes
			st["st"] = (board.grabs[fid] as Dictionary).get("stretch", mn.data.stretch)
		var k := "g/" + str(fid)
		if beat or _sent.get(k, {}) != st:
			var msg := st.duplicate()
			msg["k"] = "g"
			msg["f"] = fid
			out.append(msg)
			_sent[k] = st
	for k in _sent.keys():
		if str(k).begins_with("g/") and not board.grabs.has(str(k).substr(2)):
			out.append({"k": "g", "f": str(k).substr(2), "end": true})
			_sent.erase(k)
