class_name StylusModel
extends Node3D
## The Logitech MX Ink drawn over the real one: the model Logitech published for the stylus (assets/models/logitech_mx_ink.glb, see the
## README beside it), authored for the stylus's OpenXR grip pose, so this node is a child of the grip pose and needs no placement. The
## stylus does not lie along an axis of the grip pose (about 60 deg from -Z, and 3 cm off its origin): `nib_local()` is the far end of
## the model's "tip" mesh and `axis_local()` the way the body points, from its middle to the nib, both in the grip pose's frame.

const MODEL_PATH := "res://assets/models/logitech_mx_ink.glb"
const MAX_SHIFT := 0.025                    # a learnt correction bigger than this is a different model of the pose, not a calibration

var _nib := Vector3.ZERO
var _middle := Vector3.ZERO                 # the centre of the model's bounds, on the body's centre line
var _shift := Vector3.ZERO
var _holder: Node3D
var ready_model := false


func _ready() -> void:
	var scene := load(MODEL_PATH) as PackedScene
	if scene == null:
		print("[stylus] the MX Ink model is missing: ", MODEL_PATH)
		return
	_holder = Node3D.new()
	_holder.name = "Model"
	add_child(_holder)
	var root := scene.instantiate() as Node3D
	_holder.add_child(root)
	var box := _bounds(root, root.transform)
	if box.size == Vector3.ZERO:
		return
	_middle = box.get_center()
	_nib = _far_end(root.find_child("tip", true, false) as MeshInstance3D, _middle)
	if _nib == _middle:
		print("[stylus] the MX Ink model has no tip mesh")
		return
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ModelLighting.use_layer(root)                       # lit like the 3D models (the rest of the app is unshaded)
	ready_model = true


## The nib of the model in the frame this node sits in (the grip pose), with the learnt correction.
func nib_local() -> Vector3:
	return _nib + _shift


## Along the stylus, out of the nib, in the grip pose's frame (within a couple of degrees: the bounds' centre is not exactly on the
## centre line of a tapered body).
func axis_local() -> Vector3:
	return (_nib - _middle).normalized()


## Move the model so its nib lands where the runtime says the nib is (`nib` in the grip pose's frame). Done once, after the stylus is
## seen holding still enough to be believed; returns false (and changes nothing) when the two are further apart than a calibration.
func align_nib(nib: Vector3) -> bool:
	if _holder == null:
		return false
	var d := nib - _nib
	if d.length() > MAX_SHIFT:
		return false
	_shift = d
	_holder.position = d
	return true


## The point of a mesh furthest from `from`, in the frame of `_holder` (`from` itself when there is no mesh): the nib is the end of the
## tip that is furthest from the middle of the stylus, whichever way the stylus lies in the grip pose's frame.
func _far_end(mi: MeshInstance3D, from: Vector3) -> Vector3:
	if mi == null or mi.mesh == null:
		return from
	var xf := mi.transform
	var p := mi.get_parent()
	while p != _holder and p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	var out := from
	for s in mi.mesh.get_surface_count():
		for v: Vector3 in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			var q := xf * v
			if q.distance_squared_to(from) > out.distance_squared_to(from):
				out = q
	return out


func _bounds(n: Node3D, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out = xf * (n as MeshInstance3D).mesh.get_aabb()
		first = false
	for c in n.get_children():
		if c is Node3D:
			var b := _bounds(c as Node3D, xf * (c as Node3D).transform)
			if b.size != Vector3.ZERO:
				out = b if first else out.merge(b)
				first = false
	return out
