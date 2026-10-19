class_name MetaScene
extends Node
## The room scan of the Quest (Space Setup): walls, tables, desks and other flat surfaces. Used to snap a new canvas onto a real
## wall or table. Everything here is optional: without a scan the board places canvases in the air in front of you.

const SURFACE_LABELS := ["WALL_FACE", "TABLE", "DESK", "COUCH", "DOOR_FRAME", "WINDOW_FRAME", "OTHER"]

var planes: Array = []                     # [{node, entity, label}]
var _mgr: Node
var ready_for_use := false


func setup(origin: Node3D) -> void:
	if not ClassDB.class_exists("OpenXRFbSceneManager"):
		return
	_mgr = ClassDB.instantiate("OpenXRFbSceneManager")
	var ps := PackedScene.new()
	var n := Node3D.new()
	n.name = "SceneAnchor"
	ps.pack(n)
	n.free()
	_mgr.set("default_scene", ps)
	_mgr.set("auto_create", true)
	_mgr.set("visible", false)
	origin.add_child(_mgr)
	_mgr.connect("openxr_fb_scene_anchor_created", _on_anchor)
	_mgr.connect("openxr_fb_scene_data_missing", func(): print("[scene] no room scan found (run Space Setup in the Quest settings for walls and tables)"))
	ready_for_use = true


func _on_anchor(scene_node: Node, entity: Object) -> void:
	var labels: PackedStringArray = entity.call("get_semantic_labels")
	for l in labels:
		if SURFACE_LABELS.has(l):
			planes.append({"node": scene_node, "entity": entity, "label": l})
			return


## Nearest flat surface along a ray: {point, normal} or {}.
func hit(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var bt := INF
	for p in planes:
		var n: Node3D = p.node
		if not is_instance_valid(n):
			continue
		var inv := n.global_transform.affine_inverse()
		var lo := inv * origin
		var ld := inv.basis * dir
		if absf(ld.z) < 1e-4:
			continue
		var t := -lo.z / ld.z
		if t < 0.05 or t > bt:
			continue
		var lp := lo + ld * t
		var ent: Object = p.entity
		var ok := true
		if bool(ent.call("is_component_enabled", 3)):
			var r: Rect2 = ent.call("get_bounding_box_2d")
			ok = r.grow(0.05).has_point(Vector2(lp.x, lp.y))
		if ok:
			bt = t
			var normal := n.global_transform.basis.z.normalized()
			best = {"point": origin + dir * t, "normal": normal, "label": p.label}
	return best
