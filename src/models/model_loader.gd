class_name ModelLoader
extends RefCounted
## A model file into something to show, on the worker thread of ModelLibrary. What a library keeps is one file: a .glb, a .gltf (its buffers
## and pictures inside it as data: addresses), an .obj, or a .zip of a model with the files it uses (an .obj with its .mtl and pictures, a
## .gltf with its .bin and pictures). glTF is read by Godot's own GLTFDocument; OBJ by ObjImport. What this device can bear (ModelBudget)
## is applied here: too many triangles is refused, big pictures are made smaller, and detailed meshes get simpler versions for a distance.

const EXTS := ["glb", "gltf", "obj", "zip"]
const PARTS := ["mtl", "bin", "png", "jpg", "jpeg", "webp", "tga", "bmp", "ktx", "ktx2"]


## What kind of file this is, from its first bytes: "glb", "zip", "gltf", "obj" or "".
static func detect(bytes: PackedByteArray) -> String:
	if bytes.size() >= 12 and bytes[0] == 0x67 and bytes[1] == 0x6C and bytes[2] == 0x54 and bytes[3] == 0x46:
		return "glb"
	if bytes.size() >= 4 and bytes[0] == 0x50 and bytes[1] == 0x4B and bytes[2] == 0x03 and bytes[3] == 0x04:
		return "zip"
	var head := bytes.slice(0, mini(bytes.size(), 4096)).get_string_from_utf8().strip_edges()
	if head.begins_with("{") and head.contains("\"asset\""):
		return "gltf"
	if head.begins_with("{"):
		return "gltf" if bytes.slice(0, mini(bytes.size(), 262144)).get_string_from_utf8().contains("\"asset\"") else ""
	var text := bytes.slice(0, mini(bytes.size(), 262144)).get_string_from_utf8()
	if (text.contains("\nv ") or text.begins_with("v ")) and (text.contains("\nf ") or bytes.size() > 262144):
		return "obj"
	return ""


## The files inside a zip (path -> bytes), folders and the Mac's resource forks left out.
static func unzip(bytes: PackedByteArray, tmp_path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return out
	f.store_buffer(bytes)
	f.close()
	var z := ZIPReader.new()
	if z.open(tmp_path) == OK:
		for p in z.get_files():
			if p.ends_with("/") or p.begins_with("__MACOSX") or p.get_file().begins_with("._"):
				continue
			out[p.replace("\\", "/")] = z.read_file(p)
		z.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
	return out


## Of a set of files, the model: a .glb, else a .gltf, else an .obj (the biggest, when there are several). "" when none.
static func main_of(files: Dictionary) -> String:
	for ext in ["glb", "gltf", "obj"]:
		var best := ""
		for p in files:
			if String(p).get_extension().to_lower() == ext and (best == "" or (files[p] as PackedByteArray).size() > (files[best] as PackedByteArray).size()):
				best = p
		if best != "":
			return best
	return ""


## Checks a set of files that is to be kept, without building anything (main thread, quick): {ok, message, kind, main, notes}.
## `files`: name (path in a bundle) -> bytes.
static func check(files: Dictionary) -> Dictionary:
	var main := main_of(files)
	if main == "":
		return {"ok": false, "message": "There is no model among these files: a .glb, .gltf or .obj file is needed."}
	var bytes: PackedByteArray = files[main]
	var kind := main.get_extension().to_lower()
	var notes := PackedStringArray()
	match kind:
		"glb":
			if detect(bytes) != "glb":
				return {"ok": false, "message": "%s is not a glTF binary (.glb) file." % main.get_file()}
			var json := _glb_json(bytes)
			if json.is_empty():
				return {"ok": false, "message": "%s is damaged: its glTF description cannot be read." % main.get_file()}
			var bad := _unsupported(json)
			if bad != "":
				return {"ok": false, "message": bad}
		"gltf":
			var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
			if not (parsed is Dictionary) or not (parsed as Dictionary).has("asset"):
				return {"ok": false, "message": "%s is not a glTF file." % main.get_file()}
			var bad2 := _unsupported(parsed)
			if bad2 != "":
				return {"ok": false, "message": bad2}
			var missing := PackedStringArray()
			for list_key in ["buffers", "images"]:
				for e in (parsed as Dictionary).get(list_key, []):
					var uri := str((e as Dictionary).get("uri", ""))
					if uri != "" and not uri.begins_with("data:") and _find(files, main, uri) == "":
						missing.append(uri.uri_decode().get_file())
			if not missing.is_empty():
				return {"ok": false, "message": "%s needs files that were not sent with it: %s. Drop them together (or as one .zip)." % [main.get_file(), ", ".join(missing)]}
		"obj":
			var text := bytes.get_string_from_utf8()
			if not (text.contains("\nf ") or text.begins_with("f ")):
				return {"ok": false, "message": "%s has no faces: there is nothing to show." % main.get_file()}
			for line in text.split("\n", false):
				var l := (line as String).strip_edges()
				if l.begins_with("mtllib"):
					var mtl := l.substr(6).strip_edges().get_file()
					if _find(files, main, mtl) == "":
						notes.append("%s was not sent with it: the model is shown in grey (drop the .obj and its .mtl and pictures together, or as one .zip)" % mtl)
					else:
						for pic in _mtl_pictures(files[_find(files, main, mtl)] as PackedByteArray):
							if _find(files, main, pic) == "":
								notes.append("the picture %s was not sent with it" % pic.get_file())
	return {"ok": true, "kind": kind, "main": main, "notes": notes}


static func _mtl_pictures(bytes: PackedByteArray) -> PackedStringArray:
	var out := PackedStringArray()
	for line in bytes.get_string_from_utf8().split("\n", false):
		var l := (line as String).strip_edges()
		var k := l.get_slice(" ", 0).to_lower()
		if k in ["map_kd", "map_d", "map_bump", "bump", "norm", "map_ke", "map_pr", "map_pm"]:
			var f := ObjImport._map_file(l.substr(k.length()).strip_edges())
			if f != "" and not out.has(f):
				out.append(f)
	return out


## What the file needs that Godot cannot read, said plainly ("" when nothing).
static func _unsupported(json: Dictionary) -> String:
	var req: Array = json.get("extensionsRequired", [])
	if req.has("KHR_draco_mesh_compression") or req.has("EXT_meshopt_compression"):
		return "This model is compressed (%s), which the headset cannot read. Export it again without mesh compression." % ("Draco" if req.has("KHR_draco_mesh_compression") else "meshopt")
	return ""


static func _glb_json(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 20:
		return {}
	var n := bytes.decode_u32(12)
	if bytes.decode_u32(16) != 0x4E4F534A or 20 + n > bytes.size():
		return {}
	var parsed: Variant = JSON.parse_string(bytes.slice(20, 20 + n).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


## The file of a bundle that a model refers to as `uri` (relative to the model's own folder, or anywhere by its name). "" when not there.
static func _find(files: Dictionary, main: String, uri: String) -> String:
	var rel := uri.uri_decode().replace("\\", "/")
	var folder := main.get_base_dir()
	var want := (folder + "/" + rel if folder != "" else rel).simplify_path()
	for p in files:
		if String(p).simplify_path() == want:
			return p
	var base := rel.get_file().to_lower()
	for p in files:
		if String(p).get_file().to_lower() == base:
			return p
	return ""


# ------------------------------------------------------------------------------------------------ loading (worker thread)

## The model in `bytes` (a library file) as a scene: {ok, message, root, triangles, box (AABB, the file's units), notes, animations}.
static func load_model(bytes: PackedByteArray, budget: ModelBudget, tmp_path: String) -> Dictionary:
	var files := {}
	var kind := detect(bytes)
	match kind:
		"zip":
			files = unzip(bytes, tmp_path)
			var main := main_of(files)
			if main == "":
				return {"ok": false, "message": "There is no model in this .zip."}
			return _load_files(files, main, budget)
		"glb", "gltf", "obj":
			files["model." + kind] = bytes
			return _load_files(files, "model." + kind, budget)
	return {"ok": false, "message": "This is not a model file the headset can read (glTF .glb / .gltf or .obj)."}


static func _load_files(files: Dictionary, main: String, budget: ModelBudget) -> Dictionary:
	var res: Dictionary
	if main.get_extension().to_lower() == "obj":
		var parts := {}
		for p in files:
			parts[String(p).get_file().to_lower()] = files[p]
		res = ObjImport.parse((files[main] as PackedByteArray).get_string_from_utf8(), parts, budget)
	else:
		res = _load_gltf(files, main, budget)
	if not bool(res.get("ok", false)):
		return res
	var root: Node3D = res.root
	var box := bounds(root)
	if box.size == Vector3.ZERO:
		root.free()
		return {"ok": false, "message": "This model has nothing to show (no meshes)."}
	res["box"] = box
	var anims := PackedStringArray()
	for ap in root.find_children("*", "AnimationPlayer", true, false):
		for a in (ap as AnimationPlayer).get_animation_list():
			anims.append(a)
	res["animations"] = anims
	if not res.has("notes"):
		res["notes"] = PackedStringArray()
	return res


static func _load_gltf(files: Dictionary, main: String, budget: ModelBudget) -> Dictionary:
	var bytes: PackedByteArray = files[main]
	if main.get_extension().to_lower() == "gltf":
		bytes = _inline(files, main)
		if bytes.is_empty():
			return {"ok": false, "message": "This glTF file cannot be read."}
	var json := _glb_json(bytes) if detect(bytes) == "glb" else (JSON.parse_string(bytes.get_string_from_utf8()) as Dictionary)
	var bad := _unsupported(json if json != null else {})
	if bad != "":
		return {"ok": false, "message": bad}
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var err := doc.append_from_buffer(bytes, "", state)
	if err != OK:
		return {"ok": false, "message": "This glTF model could not be read (error %d)." % err}
	# triangles: each mesh as often as the scene uses it
	var uses := {}
	for n in state.get_nodes():
		var gn := n as GLTFNode
		if gn.mesh >= 0:
			uses[gn.mesh] = int(uses.get(gn.mesh, 0)) + 1
	var meshes := state.get_meshes()
	var tris := 0
	var per_mesh: Array = []
	for i in meshes.size():
		var im: ImporterMesh = (meshes[i] as GLTFMesh).mesh
		var t := 0
		var skinned := false
		if im != null:
			for s in im.get_surface_count():
				var arr := im.get_surface_arrays(s)
				var idx: Variant = arr[Mesh.ARRAY_INDEX]
				var verts: Variant = arr[Mesh.ARRAY_VERTEX]
				if im.get_surface_primitive_type(s) == Mesh.PRIMITIVE_TRIANGLES:
					t += (idx as PackedInt32Array).size() / 3 if idx != null else ((verts as PackedVector3Array).size() / 3 if verts != null else 0)
				if arr[Mesh.ARRAY_BONES] != null:
					skinned = true
		per_mesh.append([t, skinned])
		tris += t * maxi(int(uses.get(i, 0)), 1 if uses.is_empty() else 0)
	if tris > budget.max_triangles:
		return {"ok": false, "message": TOO_MANY % [count_text(tris), count_text(budget.max_triangles)], "triangles": tris}
	if budget.lods:
		for i in meshes.size():
			var im2: ImporterMesh = (meshes[i] as GLTFMesh).mesh
			if im2 != null and int(per_mesh[i][0]) >= budget.lod_min_triangles and not bool(per_mesh[i][1]):
				im2.generate_lods(25.0, 60.0, [])
	for tex in state.get_images():
		_shrink(tex as Texture2D, budget)
	var root := doc.generate_scene(state)
	if root == null:
		return {"ok": false, "message": "This glTF model has no scene to show."}
	return {"ok": true, "root": root, "triangles": tris}


const TOO_MANY := "This model is too detailed for this headset (%s triangles; it shows up to %s)."


## A .gltf whose buffers and pictures are files beside it, with those files put inside it (data: addresses), so it is one buffer.
static func _inline(files: Dictionary, main: String) -> PackedByteArray:
	var parsed: Variant = JSON.parse_string((files[main] as PackedByteArray).get_string_from_utf8())
	if not (parsed is Dictionary):
		return PackedByteArray()
	var json: Dictionary = parsed
	for list_key in ["buffers", "images"]:
		for e in json.get(list_key, []):
			var entry := e as Dictionary
			var uri := str(entry.get("uri", ""))
			if uri == "" or uri.begins_with("data:"):
				continue
			var p := _find(files, main, uri)
			if p == "":
				continue
			var mime := "application/octet-stream"
			match p.get_extension().to_lower():
				"png":
					mime = "image/png"
				"jpg", "jpeg":
					mime = "image/jpeg"
				"webp":
					mime = "image/webp"
			entry["uri"] = "data:%s;base64,%s" % [mime, Marshalls.raw_to_base64(files[p] as PackedByteArray)]
	return JSON.stringify(json).to_utf8_buffer()


## A picture no bigger than the budget allows (on the graphics chip), with its mipmaps.
static func _shrink(tex: Texture2D, budget: ModelBudget) -> void:
	if not (tex is ImageTexture):
		return
	var img := tex.get_image()
	if img == null or img.is_compressed():
		return
	var longest := maxi(img.get_width(), img.get_height())
	if longest <= budget.max_texture:
		return
	var k := float(budget.max_texture) / float(longest)
	img.resize(maxi(roundi(img.get_width() * k), 1), maxi(roundi(img.get_height() * k), 1), Image.INTERPOLATE_LANCZOS)
	if not img.has_mipmaps():
		img.generate_mipmaps()
	(tex as ImageTexture).set_image(img)


## A picture from a file's bytes (`ext` its extension), within the budget, with mipmaps; null if it cannot be read.
static func texture_from(bytes: PackedByteArray, ext: String, budget: ModelBudget) -> Texture2D:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match ext.to_lower():
		"png":
			err = img.load_png_from_buffer(bytes)
		"jpg", "jpeg":
			err = img.load_jpg_from_buffer(bytes)
		"webp":
			err = img.load_webp_from_buffer(bytes)
		"tga":
			err = img.load_tga_from_buffer(bytes)
		"bmp":
			err = img.load_bmp_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	var longest := maxi(img.get_width(), img.get_height())
	if longest > budget.max_texture:
		var k := float(budget.max_texture) / float(longest)
		img.resize(maxi(roundi(img.get_width() * k), 1), maxi(roundi(img.get_height() * k), 1), Image.INTERPOLATE_LANCZOS)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## The bounds of everything drawn under `root`, in root's coordinates (the file's units).
static func bounds(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for vi in root.find_children("*", "VisualInstance3D", true, false):
		var v := vi as VisualInstance3D
		var b := v.get_aabb()
		if b.size == Vector3.ZERO:
			continue
		var xf := v.transform
		var p := v.get_parent()
		while p != null and p != root and p is Node3D:
			xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var wb := xf * b
		box = wb if first else box.merge(wb)
		first = false
	return box


## 1 234 567 -> "1.2 million", 400 000 -> "400 000".
static func count_text(n: int) -> String:
	if n >= 1000000:
		return "%.1f million" % (n / 1000000.0)
	if n >= 1000:
		return "%d %03d" % [n / 1000, n % 1000]
	return str(n)
