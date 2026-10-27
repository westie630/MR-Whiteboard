extends Node
## 3D models on a real board: the library (glTF .glb, a .gltf with its .bin beside it, an .obj with its .mtl and picture, a .zip, what is
## refused and why), the OBJ reader (normals, winding, materials), a model put down in front of you, fitted to the room when it is first
## loaded, and every handle of the gizmo driven by simulated hands: tap to select, carry it, slide along an axis, turn on a ring (with snap),
## resize at a corner, stretch along an axis, two hands turning and resizing it, a canvas in front of it taking the pointer, a locked place,
## putting it down on the floor, undo, saving, the device budget (a Quest 2 refusing a model that is too detailed) and the web page.

const HEAD := {"x-requested-with": "mrw"}

var t := TestCase.new("models")
var board: Board
var anchors: SimAnchors
var hand := HandInput.new("right")
var left := HandInput.new("left")
var _glb_bytes: PackedByteArray


func _ready() -> void:
	App.settings_path = "user://test_settings_models.cfg"
	App.reload()
	App.docs_dir = "user://test_docs_models"
	App.model_dir = "user://test_models_lib"
	_clean(App.docs_dir)
	_clean(App.model_dir)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_sim_anchors_models.json"))
	anchors = SimAnchors.new("user://test_sim_anchors_models.json")
	add_child(anchors)
	board = Board.new()
	add_child(board)
	board.setup(anchors)
	board.models.threaded = false
	board.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var doc := Document.create("Models")
	doc.add_room("Studio")
	board.open(doc)
	await ticks(5)
	_glb_bytes = _box_glb(Vector3(0.2, 0.1, 0.3))
	_obj_reader()
	await _library()
	await _placing()
	await _handles()
	await _two_hands()
	await _one_hand_turn()
	await _pinch_pen()
	await _priority_and_locks()
	await _lay_down()
	_saving()
	await _budget()
	await _web()
	_clean(App.docs_dir)
	_clean(App.model_dir)
	get_tree().quit(t.done())


func _clean(dir: String) -> void:
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)


func ticks(n: int = 1) -> void:
	for i in n:
		await get_tree().process_frame
		board.tick(PenState.new(), _hands(), 0.016)
		hand.pinch_down = false
		hand.pinch_up = false
		left.pinch_down = false
		left.pinch_up = false


func _hands() -> Array:
	var out: Array = []
	for h in [hand, left]:
		if (h as HandInput).tracked:
			out.append(h)
	return out


## The right hand pointing from `o` at `at` (pinching or not).
func point(o: Vector3, at: Vector3, pinch: bool, h: HandInput = hand) -> void:
	h.tracked = true
	h.aiming = true
	h.palm_up = false
	h.aim_o = o
	h.aim_d = (at - o).normalized()
	h.press_o = h.aim_o
	h.press_d = h.aim_d
	h.live_o = h.aim_o
	h.live_d = h.aim_d
	h.pinch_point = o
	h.tip = o
	h.pinch_down = pinch and not h.pinching
	h.pinch_up = h.pinching and not pinch
	h.pinching = pinch


## A hand touching: its pinch point at `p`, not pointing.
func touch(p: Vector3, pinch: bool, h: HandInput = hand) -> void:
	h.tracked = true
	h.aiming = false
	h.palm_up = false
	h.pinch_point = p
	h.tip = p
	h.aim_o = p + Vector3(0, 0, 0.3)
	h.aim_d = Vector3.FORWARD
	h.press_o = h.aim_o
	h.press_d = h.aim_d
	h.pinch_down = pinch and not h.pinching
	h.pinch_up = h.pinching and not pinch
	h.pinching = pinch


func away() -> void:
	hand.tracked = false
	hand.pinching = false
	left.tracked = false
	left.pinching = false


## A drag with the right hand's ray from `o`: pinch on `from`, move to `to` in a few steps, let go.
func drag(o: Vector3, from: Vector3, to: Vector3) -> void:
	point(o, from, false)
	await ticks(2)
	point(o, from, true)
	await ticks(1)
	for k in range(1, 6):
		point(o, from.lerp(to, k / 5.0), true)
		await ticks(1)
	point(o, to, false)
	await ticks(2)


# ------------------------------------------------------------------------------------------------ fixtures

static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


## A box of `size` metres as a .glb.
static func _box_glb(size: Vector3, segments: int = 0) -> PackedByteArray:
	var root := Node3D.new()
	root.name = "Box"
	var mi := MeshInstance3D.new()
	var mesh: PrimitiveMesh
	if segments > 0:
		var sp := SphereMesh.new()
		sp.radius = size.x * 0.5
		sp.height = size.x
		sp.radial_segments = segments
		sp.rings = segments / 2
		mesh = sp
	else:
		var bx := BoxMesh.new()
		bx.size = size
		mesh = bx
	mesh.surface_set_material(0, _mat(Color(0.8, 0.3, 0.2)))
	mi.mesh = mesh
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	doc.append_from_scene(root, st)
	var out := doc.generate_buffer(st)
	root.free()
	return out


const CUBE_OBJ := "# a cube\nmtllib cube.mtl\nv -0.5 -0.5 -0.5\nv 0.5 -0.5 -0.5\nv 0.5 0.5 -0.5\nv -0.5 0.5 -0.5\nv -0.5 -0.5 0.5\nv 0.5 -0.5 0.5\nv 0.5 0.5 0.5\nv -0.5 0.5 0.5\n" + \
	"vt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\nusemtl red\n" + \
	"f 5/1 6/2 7/3 8/4\nf 2/1 1/2 4/3 3/4\nf 6/1 2/2 3/3 7/4\nf 1/1 5/2 8/3 4/4\nf 8/1 7/2 3/3 4/4\nf 1/1 2/2 6/3 5/4\n"
const CUBE_MTL := "newmtl red\nKd 0.9 0.1 0.1\nNs 50\nd 1.0\nmap_Kd -s 1 1 1 tex.png\n"


static func _png() -> PackedByteArray:
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.8, 0.4))
	return img.save_png_to_buffer()


# ------------------------------------------------------------------------------------------------ the OBJ reader

func _obj_reader() -> void:
	var budget := ModelBudget.for_tier("high")
	var res := ObjImport.parse(CUBE_OBJ, {"cube.mtl": CUBE_MTL.to_utf8_buffer(), "tex.png": _png()}, budget)
	t.check(bool(res.ok), "an OBJ cube is read: %s" % str(res.get("message", "")))
	t.eq(int(res.triangles), 12, "six squares are twelve triangles")
	var root: Node3D = res.root
	var mi := root.get_child(0) as MeshInstance3D
	var arr := mi.mesh.surface_get_arrays(0)
	t.eq((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 24, "sharp edges: each face has its own corners (normals made with the crease)")
	var mat := mi.mesh.surface_get_material(0) as StandardMaterial3D
	t.check(mat != null and mat.albedo_color.is_equal_approx(Color(0.9, 0.1, 0.1)), "its material's colour comes from the .mtl")
	t.check(mat != null and mat.albedo_texture != null, "and its picture (map_Kd, after its options)")
	t.check(mat != null and mat.roughness < 0.5, "shininess becomes a smoother surface")
	# the triangles face the way Godot's own meshes do (OBJ is counter-clockwise, Godot's front faces clockwise)
	var box := BoxMesh.new()
	var ba := box.surface_get_arrays(0)
	t.eq(_winding(arr), _winding(ba), "the faces point outwards as Godot draws them")
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var outward := true
	for i in verts.size():
		if nrm[i].dot(verts[i]) <= 0.0:
			outward = false
	t.check(outward, "every normal points out of the cube")
	root.free()
	var bad := ObjImport.parse("v 0 0 0\nv 1 0 0\n", {}, budget)
	t.check(not bool(bad.ok), "an OBJ of points only is refused")
	var tiny := ModelBudget.for_tier("low")
	tiny.max_triangles = 5
	var big := ObjImport.parse(CUBE_OBJ, {}, tiny)
	t.check(not bool(big.ok) and str(big.message).contains("too detailed"), "more triangles than the device takes is refused: %s" % str(big.get("message", "")))


## +1 when the triangles' right-hand normals agree with the vertex normals, -1 when they are opposite.
static func _winding(arr: Array) -> int:
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var a := v[idx[0]]
	var cross := (v[idx[1]] - a).cross(v[idx[2]] - a)
	return 1 if cross.dot(n[idx[0]]) > 0.0 else -1


# ------------------------------------------------------------------------------------------------ the library

func _library() -> void:
	var lib := board.models
	var r := lib.add(_glb_bytes, "Crate.glb")
	t.check(bool(r.ok) and not bool(r.dup), "a .glb is taken in: %s" % str(r.message))
	t.eq(str(r.name), "Crate", "named after its file")
	t.eq(str(lib.entry(str(r.id)).ext), "glb", "kept as it came")
	t.eq(str(lib.add(_glb_bytes, "Again.glb").id), str(r.id), "the same file is the same model (named by its content)")
	t.check(bool(lib.add(_glb_bytes, "Again.glb").dup), "and is not stored twice")
	var notmodel := lib.add("hello".to_utf8_buffer(), "notes.txt")
	t.check(not bool(notmodel.ok), "a file that is not a model is refused")
	var part := lib.add(CUBE_MTL.to_utf8_buffer(), "cube.mtl")
	t.check(not bool(part.ok) and str(part.message).contains("part of a model"), "a lone .mtl is refused with what to do: %s" % str(part.message))
	# an .obj with its .mtl and picture: one bundle, kept as one .zip
	var files := {"cube.obj": CUBE_OBJ.to_utf8_buffer(), "cube.mtl": CUBE_MTL.to_utf8_buffer(), "tex.png": _png()}
	var ro := lib.add_files(files, "cube.obj")
	t.check(bool(ro.ok), "an .obj with its .mtl and picture is taken in: %s" % str(ro.message))
	t.eq(str(lib.entry(str(ro.id)).ext), "zip", "as one .zip")
	t.check((ro.notes as PackedStringArray).is_empty(), "nothing it needs is missing")
	var ro2 := lib.add_files(files, "cube.obj")
	t.eq(str(ro2.id), str(ro.id), "the same files give the same model")
	var lone := lib.add(CUBE_OBJ.to_utf8_buffer(), "cube.obj")
	t.check(bool(lone.ok) and not (lone.notes as PackedStringArray).is_empty(), "an .obj alone is taken, with a note that its materials are missing")
	# a .gltf with its .bin beside it
	var dir := ProjectSettings.globalize_path("user://test_models_gltf")
	DirAccess.make_dir_recursive_absolute(dir)
	var gd := GLTFDocument.new()
	var gs := GLTFState.new()
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	gd.append_from_scene(root, gs)
	gd.write_to_filesystem(gs, dir + "/thing.gltf")
	root.free()
	var gfiles := {}
	for f in DirAccess.get_files_at(dir):
		gfiles[f] = FileAccess.get_file_as_bytes(dir + "/" + f)
	t.check(gfiles.has("thing.gltf") and gfiles.size() >= 2, "(a .gltf and its .bin were written: %s)" % str(gfiles.keys()))
	var only_gltf := lib.add(gfiles["thing.gltf"], "thing.gltf")
	t.check(not bool(only_gltf.ok) and str(only_gltf.message).contains("not sent"), "a .gltf without its .bin is refused, saying which file is missing")
	var rg := lib.add_files(gfiles, "thing.gltf")
	t.check(bool(rg.ok), "a .gltf with its .bin is taken in: %s" % str(rg.message))
	for f in gfiles:
		DirAccess.remove_absolute(dir + "/" + str(f))
	# loading: each kind becomes something to show
	for id in [str(r.id), str(ro.id), str(rg.id)]:
		lib.request(id)
	await ticks(3)
	for id in [str(r.id), str(ro.id), str(rg.id)]:
		t.check(not lib.stats(id).is_empty(), "%s is loaded (%s)" % [str(lib.entry(id).name), lib.failure(id)])
	t.check((lib.stats(str(r.id)).box as AABB).size.is_equal_approx(Vector3(0.2, 0.1, 0.3)), "a model's bounds are measured: %s" % str(lib.stats(str(r.id)).get("box")))
	t.check((lib.stats(str(ro.id)).box as AABB).size.is_equal_approx(Vector3.ONE), "the OBJ cube too")
	t.check(lib.box_of(str(r.id)).size.is_equal_approx(Vector3(0.2, 0.1, 0.3)), "and kept in the index for next time")
	var draco := {"asset": {"version": "2.0"}, "extensionsRequired": ["KHR_draco_mesh_compression"]}
	var rd := lib.add(JSON.stringify(draco).to_utf8_buffer(), "squashed.gltf")
	t.check(not bool(rd.ok) and str(rd.message).contains("compressed"), "a Draco-compressed model is refused with the reason")
	t.check(lib.remove(str(lone.id)) and not lib.has(str(lone.id)), "a model can be removed from the library")


# ------------------------------------------------------------------------------------------------ putting it down

var fid := ""


func node() -> ModelNode:
	return board.model_nodes.get(fid)


func frame() -> FrameData:
	return board.doc.frames.get(fid)


func _placing() -> void:
	var id := ModelLibrary.id_of(_glb_bytes)
	var undo_before := board.history.serial
	var res := board.place_model(id)
	t.check(bool(res.ok), "a model is put down: %s" % str(res.message))
	fid = str(res.id)
	var f := frame()
	t.check(f != null and f.is_model() and f.model == id, "as a frame of kind model, naming its file")
	t.eq(board.model_ctl.selected, fid, "selected, so its handles show")
	await ticks(4)
	f = frame()
	t.check(f.model_measured(), "it is measured")
	t.near(f.scale, 1.0, 1e-6, "a model of a plausible real size (30 cm) keeps it")
	t.check(node().state == "ready", "it is shown (%s)" % node().state)
	t.check(node().visible, "in the room")
	var c := node().global_position
	t.near(c.z, -0.9, 0.05, "in front of you")
	t.near(c.y, 1.35, 0.05, "at chest height")
	t.check(node().global_transform.basis.z.dot(Vector3.BACK) > 0.99, "facing you")
	var layer_ok := true
	for vi in node().find_child("Content", true, false).find_children("*", "VisualInstance3D", true, false):
		if ((vi as VisualInstance3D).layers & ModelLighting.LAYER) == 0:
			layer_ok = false
	t.check(layer_ok, "its meshes are on the models' light layer")
	t.check(board.model_ctl.gizmo.visible, "the gizmo shows round it")
	board.undo()
	await ticks(1)
	t.check(not board.doc.frames.has(fid), "undo takes it away again")
	board.redo()
	await ticks(3)
	t.check(board.doc.frames.has(fid) and node() != null and node().state == "ready", "redo puts it back")
	t.check(board.history.serial != undo_before, "(it was undoable)")
	board.model_ctl.select(fid)
	# a model in millimetres is fitted to 40 cm
	var mm := board.models.add(_box_glb(Vector3(120, 80, 60)), "Engine.glb")
	var r2 := board.place_model(str(mm.id))
	await ticks(4)
	var f2: FrameData = board.doc.frames[str(r2.id)]
	t.near(f2.model_size().x, InputTuning.MODEL_FIT, 1e-3, "a model far bigger than a room thing is made 40 cm long: %s" % str(f2.model_size()))
	board.real_size_model(f2.id)
	t.near((board.doc.frames[f2.id] as FrameData).model_size().x, FrameData.MODEL_SIZE.y, 1e-3, "Real size is as big as allowed (the file says 120 m)")
	board.delete_frame(f2.id)
	board.model_ctl.select(fid)
	await ticks(2)


# ------------------------------------------------------------------------------------------------ the handles

const EYE := Vector3(0.25, 1.45, -0.2)              # where the pointing hand is


func _handles() -> void:
	var ctl := board.model_ctl
	var g := ctl.gizmo
	# a tap selects (after letting go of it)
	ctl.deselect()
	var c := node().global_position
	point(EYE, c, false)
	await ticks(2)
	t.check(ctl.claimed.has("right") and str((ctl.hover.right as Dictionary).kind) == "model", "pointing at the model: it has the pointer")
	t.check(node().hover > 0.5, "and is outlined")
	point(EYE, c, true)
	await ticks(1)
	point(EYE, c, false)
	await ticks(2)
	t.eq(ctl.selected, fid, "a tap selects it")
	# move along X
	ctl.set_mode("move")
	await ticks(1)
	var serial := board.history.serial
	var on_x := c + Vector3(g.extent.x + g.s * 4.0, 0, 0)
	point(EYE, on_x, false)
	await ticks(1)
	t.eq(str((ctl.hover.get("right", {}) as Dictionary).get("handle", "")), "mx", "the ray is on the red arrow")
	await drag(EYE, on_x, on_x + Vector3(0.15, 0, 0))
	var c2 := node().global_position
	t.near(c2.x - c.x, 0.15, 0.003, "dragging the arrow slides it along X")
	t.near(c2.y, c.y, 0.001, "and only along X (y)")
	t.near(c2.z, c.z, 0.001, "and only along X (z)")
	t.eq(board.history.serial, serial + 1, "one undo step")
	board.undo()
	await ticks(2)
	t.near(node().global_position.x, c.x, 0.002, "undo puts it back")
	# a plane: the floor square slides it in X and Z only
	c = node().global_position
	var sq := g.plane_center("pxz")
	await drag(Vector3(0.0, 1.9, -0.4), sq, sq + Vector3(0.1, 0.0, -0.05))
	var c3 := node().global_position
	t.check(absf(c3.y - c.y) < 0.002 and absf(c3.x - c.x - 0.1) < 0.01 and absf(c3.z - c.z + 0.05) < 0.01, "the floor square slides it along the floor: %s" % str(c3 - c))
	board.undo()
	await ticks(2)
	# rotate about Y with snap: a turn of 40 degrees becomes 45
	ctl.set_mode("rotate")
	ctl.set_snap(true)
	await ticks(1)
	c = node().global_position
	var on_ring := c + Vector3(g.ring_r, 0, 0)
	var turned := c + Basis(Vector3.UP, deg_to_rad(40.0)) * Vector3(g.ring_r, 0, 0)
	var above := c + Vector3(0.1, 0.5, 0.3)
	point(above, on_ring, false)
	await ticks(1)
	t.eq(str((ctl.hover.get("right", {}) as Dictionary).get("handle", "")), "ry", "the ray is on the green ring")
	await drag(above, on_ring, turned)
	var b := node().global_transform.basis.orthonormalized()
	t.near(rad_to_deg(atan2(b.z.x, b.z.z)), 45.0, 0.5, "turning on the ring turns it about Y, in 15 degree steps with Snap")
	t.near(b.y.y, 1.0, 1e-3, "and only about Y")
	ctl.set_snap(false)
	board.undo()
	await ticks(2)
	# scale at a corner: pulled out half as far again
	ctl.set_mode("scale")
	await ticks(1)
	c = node().global_position
	var corner := g.corner(7)
	var out := c + (corner - c) * 1.5
	await drag(EYE + Vector3(0.2, 0.2, 0), corner, out)
	t.near(frame().scale, 1.5, 0.03, "a corner resizes it about its middle")
	t.near(node().global_position.distance_to(c), 0.0, 0.002, "its middle stays")
	t.check(frame().stretch.is_equal_approx(Vector3.ONE), "evenly")
	board.undo()
	await ticks(2)
	# stretch along its own X
	var cube := g.axis_cube(0)
	await drag(EYE + Vector3(0, 0.3, 0), cube, c + (cube - c) * 2.0)
	t.near(frame().stretch.x, 2.0, 0.05, "an axis cube stretches it along that axis")
	t.near(frame().stretch.y, 1.0, 1e-6, "and only that axis")
	t.near(frame().model_size().x, 0.4, 0.01, "it is twice as wide")
	board.undo()
	await ticks(2)
	# carrying it by touching it: 1:1, a hand in the middle takes the model (not the ball), and no box or handles while it is carried
	ctl.set_mode("move")
	await ticks(1)
	t.check(ctl.selected == fid and g.visible, "(selected: the move handles show)")
	c = node().global_position
	touch(c, false)
	await ticks(1)
	t.eq(str((ctl.hover.get("right", {}) as Dictionary).get("kind", "")), "model", "a hand in the middle of the selected model is on the model, not on the ball")
	touch(c, true)
	await ticks(1)
	var bare := true
	for k in range(1, 6):
		touch(c + Vector3(0, 0.02 * k, -0.01 * k), true)
		await ticks(1)
		if k >= 2 and (ctl.selected != "" or g.visible or node().selected or node().hover > 0.01):
			bare = false
	t.check(bare, "while it is carried it shows no box and no handles")
	touch(c + Vector3(0, 0.1, -0.05), false)
	await ticks(2)
	t.check(node().global_position.distance_to(c + Vector3(0, 0.1, -0.05)) < 0.003, "a hand in the model carries it 1:1: %s" % str(node().global_position - c))
	away()
	await ticks(2)
	t.check(ctl.selected == "" and not g.visible and node().hover < 0.01, "let go, it stays unselected: no box, no handles")
	c = node().global_position
	touch(c, false)
	await ticks(1)
	touch(c, true)
	await ticks(1)
	touch(c, false)
	await ticks(2)
	t.check(ctl.selected == fid and g.visible, "a tap selects it again: the handles are back")
	board.undo()
	await ticks(2)
	away()
	await ticks(1)


func _two_hands() -> void:
	var c := node().global_position
	var s0 := frame().scale
	board.model_ctl.select(fid)
	touch(c + Vector3(0.05, 0, 0), false, hand)
	touch(c - Vector3(0.05, 0, 0), false, left)
	await ticks(1)
	touch(c + Vector3(0.05, 0, 0), true, hand)
	touch(c - Vector3(0.05, 0, 0), true, left)
	await ticks(1)
	touch(c + Vector3(0.08, 0, 0), true, hand)
	touch(c - Vector3(0.08, 0, 0), true, left)
	await ticks(2)
	for k in range(1, 9):
		var half := 0.08 + 0.01 * k
		var turn := Basis(Vector3.UP, deg_to_rad(5.0 * k))
		touch(c + turn * Vector3(half, 0, 0), true, hand)
		touch(c - turn * Vector3(half, 0, 0), true, left)
		await ticks(1)
	t.check(board.model_ctl.selected == "" and not board.model_ctl.gizmo.visible and node().hover < 0.01, "two hands on it: no box, no handles either")
	touch(c + Basis(Vector3.UP, deg_to_rad(40.0)) * Vector3(0.16, 0, 0), false, hand)
	touch(c - Basis(Vector3.UP, deg_to_rad(40.0)) * Vector3(0.16, 0, 0), false, left)
	await ticks(2)
	t.near(frame().scale / s0, 2.0, 0.05, "two hands moving apart resize it")
	var b := node().global_transform.basis.orthonormalized()
	t.near(rad_to_deg(atan2(-b.x.z, b.x.x)), 40.0, 1.0, "and turning together turn it")
	board.undo()
	await ticks(2)
	t.near(frame().scale, s0, 1e-4, "both in one undo step")
	away()
	await ticks(1)


## One hand (or the stylus) turns what it carries as it turns: touching, about the pinch point as if it were in the hand; pointing, about the
## model's middle (in 15 degree steps with Snap). A grab that only turns, without moving, carries it too.
func _one_hand_turn() -> void:
	var ctl := board.model_ctl
	ctl.deselect()
	var c := node().global_position
	var b0 := node().global_transform.basis.orthonormalized()
	var p := c + Vector3(0.05, 0.0, 0.0)                # held off its middle
	hand.has_grip = true
	hand.grip = Basis.IDENTITY
	touch(p, false)
	await ticks(1)
	touch(p, true)
	await ticks(1)
	for k in range(1, 7):
		hand.grip = Basis(Vector3.UP, deg_to_rad(10.0 * k))
		touch(p + Vector3(0, 0.01 * k, 0), true)
		await ticks(1)
	await ticks(1)
	var turn := Basis(Vector3.UP, deg_to_rad(60.0))
	var want := p + Vector3(0, 0.06, 0) + turn * (c - p)
	t.check(node().global_position.distance_to(want) < 0.003, "a hand that turns while it carries turns the model with it, about the pinch point: %s" % str(node().global_position - want))
	var b := node().global_transform.basis.orthonormalized()
	t.near(rad_to_deg((b * b0.inverse()).get_rotation_quaternion().get_angle()), 60.0, 0.5, "by as much as the hand turned")
	t.check(ctl.selected == "" and not ctl.gizmo.visible, "(and shows no handles meanwhile)")
	touch(p + Vector3(0, 0.06, 0), false)
	await ticks(2)
	board.undo()
	await ticks(2)
	t.near(node().global_position.distance_to(c), 0.0, 0.002, "undo puts it back, turned back")
	away()
	await ticks(1)
	# pointing, with Snap, and the hand only turning: about its middle, 40 degrees become 45
	ctl.set_snap(true)
	hand.grip = Basis.IDENTITY
	point(EYE, c, false)
	await ticks(2)
	point(EYE, c, true)
	await ticks(1)
	for k in range(1, 5):
		hand.grip = Basis(Vector3.RIGHT, deg_to_rad(10.0 * k))
		point(EYE, c, true)
		await ticks(1)
	await ticks(1)
	t.check(ctl._holds.has("right"), "a grab that only turns carries it too")
	b = node().global_transform.basis.orthonormalized()
	t.near(rad_to_deg((b * b0.inverse()).get_rotation_quaternion().get_angle()), 45.0, 0.5, "pointing, it turns about its middle, in 15 degree steps with Snap")
	t.near(node().global_position.distance_to(c), 0.0, 0.002, "its middle stays where it was")
	point(EYE, c, false)
	await ticks(2)
	ctl.set_snap(false)
	board.undo()
	await ticks(2)
	hand.has_grip = false
	hand.grip = Basis.IDENTITY
	away()
	await ticks(1)


func _pinch_pen() -> void:
	# no stylus and "Draw with a pinch": the right hand is the board's pen (source "pinch"), and its pinch still carries a model
	var c := node().global_position
	var pen := PenState.new()
	pen.source = "pinch"
	pen.tracked = true
	pen.dir = Vector3.FORWARD
	var p := c + Vector3(0.03, 0.0, 0.0)
	for k in range(0, 8):
		pen.tip = p + Vector3(0, 0.01 * maxi(k - 1, 0), 0)
		pen.pressure = 0.7 if k > 0 else 0.0
		pen.down = k > 0
		await get_tree().process_frame
		board.tick(pen, [], 0.016)
	await get_tree().process_frame
	board.tick(pen, [], 0.016)
	t.check(board.model_ctl._holds.has("pen"), "a pinch of the hand that is the pen carries a model")
	t.near(node().global_position.distance_to(c + Vector3(0, 0.06, 0)), 0.0, 0.003, "and the model follows it")
	pen.down = false
	pen.pressure = 0.0
	await get_tree().process_frame
	board.tick(pen, [], 0.016)
	t.check(not board.model_ctl._holds.has("pen"), "until it lets go")
	await get_tree().process_frame
	board.tick(PenState.new(), [], 0.016)
	board.undo()
	await ticks(2)
	t.near(node().global_position.distance_to(c), 0.0, 0.002, "(undone)")


func _priority_and_locks() -> void:
	var c := node().global_position
	# a canvas between the hand and the model takes the pointer
	var cv := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(c.x, c.y, c.z + 0.4)), Vector2(1.2, 0.8))
	await ticks(2)
	board.model_ctl.deselect()
	point(Vector3(c.x, c.y, c.z + 0.9), c, false)
	await ticks(2)
	t.check(not board.model_ctl.claimed.has("right"), "a canvas in front of the model has the pointer")
	t.check(str((board.hand_ctl.hover.get("right", {}) as Dictionary).get("kind", "")) != "", "the canvas's controller sees it")
	board.delete_frame(cv.id)
	await ticks(2)
	point(Vector3(c.x, c.y, c.z + 0.9), c, false)
	await ticks(2)
	t.check(board.model_ctl.claimed.has("right"), "with the canvas gone, the model has it")
	t.check(board.hand_ctl.hover.get("right", {}).is_empty(), "and the canvases' controller leaves it alone")
	away()
	await ticks(1)
	# a locked place: no move, but a size change
	board.set_frame_prop(fid, "place_locked", true)
	board.model_ctl.select(fid)
	board.model_ctl.set_mode("move")
	await ticks(2)
	var g := board.model_ctl.gizmo
	var on_x := c + Vector3(g.extent.x + g.s * 4.0, 0, 0)
	await drag(EYE, on_x, on_x + Vector3(0.15, 0, 0))
	t.near(node().global_position.x, c.x, 1e-4, "a model whose place is locked does not move")
	board.model_ctl.set_mode("scale")
	await ticks(1)
	var corner := g.corner(7)
	await drag(EYE + Vector3(0.2, 0.2, 0), corner, c + (corner - c) * 1.2)
	t.near(frame().scale, 1.2, 0.03, "but it can still be resized")
	board.undo()
	board.set_frame_prop(fid, "place_locked", false)
	board.set_frame_prop(fid, "locked", true)
	await ticks(2)
	point(EYE, c, false)
	await ticks(2)
	t.check(not board.model_ctl.claimed.has("right"), "a locked model takes no pointer at all")
	board.set_frame_prop(fid, "locked", false)
	away()
	await ticks(2)


func _lay_down() -> void:
	board.model_ctl.select(fid)
	await ticks(2)
	board.lay_down_model(fid)
	await ticks(2)
	var low := INF
	for p in node().corners():
		low = minf(low, (p as Vector3).y)
	t.near(low, board.floor_y(), 0.002, "Put down: it stands on the floor")
	await ticks(1)
	t.check(node().shadow.visible, "with its soft shadow under it")
	board.undo()
	await ticks(2)
	t.check(not node().shadow.visible or node().global_position.y > 1.0, "lifted back to chest height by undo")
	var dup_before := board.doc.frames.size()
	board.duplicate_model(fid)
	await ticks(3)
	t.eq(board.doc.frames.size(), dup_before + 1, "Duplicate makes a copy")
	t.check(board.model_ctl.selected != fid and (board.doc.frames[board.model_ctl.selected] as FrameData).model == frame().model, "beside it, selected, the same model")
	board.undo()
	board.model_ctl.select(fid)
	await ticks(2)


func _saving() -> void:
	var upd := frame().copy()
	upd.stretch = Vector3(1.5, 1.0, 0.5)
	board.history.do(History.op_frame(frame(), upd))
	var back := Document.from_dict(JSON.parse_string(JSON.stringify(board.doc.to_dict())))
	var f2: FrameData = back.frames[fid]
	t.check(f2.is_model() and f2.model == frame().model, "a saved model frame comes back")
	t.check(f2.stretch.is_equal_approx(Vector3(1.5, 1.0, 0.5)), "with its stretch")
	t.check(f2.model_box.size.is_equal_approx(frame().model_box.size), "and its bounds")
	var canvas := FrameData.make(FrameData.CANVAS, "r", Transform3D.IDENTITY)
	t.check(not canvas.to_dict().has("model"), "(a canvas's file carries nothing of it)")
	board.undo()


func _budget() -> void:
	# a Quest 2's budget, made small for the test: the model is refused there, with the reason, and a box stands in for it
	var keep := board.models.budget
	board.models.budget = ModelBudget.for_tier("low")
	board.models.budget.max_triangles = 100
	var bid := board.models.add(_box_glb(Vector3(0.3, 0.3, 0.3), 32), "Ball.glb")
	var r := board.place_model(str(bid.id))
	await ticks(3)
	var mn: ModelNode = board.model_nodes[str(r.id)]
	t.eq(mn.state, "failed", "a model too detailed for this headset is not loaded")
	t.check(mn.note.contains("too detailed"), "and its box says why: %s" % mn.note)
	t.check(not board.doc.frames[str(r.id)].model_measured(), "it is not fitted by a headset that could not load it")
	board.delete_frame(str(r.id))
	board.models.budget = keep
	t.eq(ModelBudget.for_tier("low").max_texture, 1024, "a Quest 2 keeps pictures at 1024 px at most")
	t.eq(ModelBudget.detect_tier("low"), "low", "the tier can be forced")
	await ticks(1)


func _web() -> void:
	var srv := board.share
	srv.require_pin = false
	var n0 := board.model_nodes.size()
	var res := srv.handle("POST", "/api/model?name=Table.glb", HEAD, _box_glb(Vector3(1.2, 0.75, 0.8)), "x")
	var j: Dictionary = JSON.parse_string((res.body as PackedByteArray).get_string_from_utf8())
	t.check(res.status == 200 and bool(j.ok) and bool(j.get("shown", false)), "a .glb dropped on the page is put in front of you: %s" % str(j.message))
	t.eq(board.model_nodes.size(), n0 + 1, "as a model in the room")
	# an .obj with its .mtl and picture, packed by the page
	var pack := ExportServer.BUNDLE_MAGIC.to_utf8_buffer()
	for pair in [["cube.obj", CUBE_OBJ.to_utf8_buffer()], ["cube.mtl", CUBE_MTL.to_utf8_buffer()], ["tex.png", _png()]]:
		var nm := (pair[0] as String).to_utf8_buffer()
		var head := PackedByteArray()
		head.resize(2)
		head.encode_u16(0, nm.size())
		pack.append_array(head)
		pack.append_array(nm)
		var sz := PackedByteArray()
		sz.resize(4)
		sz.encode_u32(0, (pair[1] as PackedByteArray).size())
		pack.append_array(sz)
		pack.append_array(pair[1])
	var rb := srv.handle("POST", "/api/model/bundle?name=cube.obj", HEAD, pack, "x")
	var jb: Dictionary = JSON.parse_string((rb.body as PackedByteArray).get_string_from_utf8())
	t.check(rb.status == 200 and bool(jb.ok), "an .obj with its .mtl and picture, dropped together: %s" % str(jb.message))
	t.eq(ExportServer.unpack_bundle(pack).size(), 3, "the page's bundle holds the three files")
	t.check(ExportServer.unpack_bundle(pack.slice(0, pack.size() - 3)).is_empty(), "a bundle cut short is refused")
	var torn := srv.handle("POST", "/api/model/bundle?name=x.obj", HEAD, "MRWB1\nxx".to_utf8_buffer(), "x")
	t.eq(torn.status, 400, "and answered as such")
	var nope := srv.handle("POST", "/api/model?name=x.mtl", HEAD, CUBE_MTL.to_utf8_buffer(), "x")
	t.eq(nope.status, 422, "a part of a model on its own is refused")
	t.eq(srv.handle("POST", "/api/model?name=x.glb", {}, _glb_bytes, "x").status, 403, "an upload not made from the page itself is refused")
	var page := (srv.handle("GET", "/", {}, PackedByteArray(), "x").body as PackedByteArray).get_string_from_utf8()
	t.check(page.contains("3D models") and page.contains("Table"), "the dashboard lists the models")
	t.check(page.contains(".glb") and page.contains(".obj"), "and the upload box takes them")
	var id := str(j.id)
	var dl := srv.handle("GET", "/model/" + id, {}, PackedByteArray(), "x")
	t.check(dl.status == 200 and (dl.body as PackedByteArray).size() > 100 and str(dl.get("download", "")) == "Table.glb", "a model can be downloaded as it was sent")
	var rn := srv.handle("POST", "/api/model/rename", HEAD, JSON.stringify({"id": id, "name": "Dining table"}).to_utf8_buffer(), "x")
	t.check(rn.status == 200 and str(board.models.entry(id).name) == "Dining table", "renamed")
	var sh := srv.handle("POST", "/api/model/show", HEAD, JSON.stringify({"id": id}).to_utf8_buffer(), "x")
	t.eq(sh.status, 200, "shown again in the headset")
	var dd := srv.handle("POST", "/api/model/delete", HEAD, JSON.stringify({"ids": [id]}).to_utf8_buffer(), "x")
	t.check(dd.status == 200 and not board.models.has(id), "deleted from the headset")
	await ticks(2)
	var missing := 0
	for mn in board.model_nodes.values():
		if (mn as ModelNode).data.model == id and (mn as ModelNode).state == "missing":
			missing += 1
	t.check(missing >= 1, "where it stood, a box says it is missing")
