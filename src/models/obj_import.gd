class_name ObjImport
extends RefCounted
## Wavefront OBJ (with its MTL materials and their pictures) read at run time: Godot only imports OBJ in the editor. One surface per material,
## polygons cut into triangles (a fan, as every OBJ exporter writes convex faces), negative indices, vertex colours (`v x y z r g b`), and
## normals made where the file has none: smooth across edges flatter than CREASE_DEG, sharp across steeper ones (a box stays a box, a ball
## stays round), and flat for faces under `s off`. Materials: colour (Kd), opacity (d / Tr), shininess (Ns, or the PBR extension's Pr / Pm),
## emission (Ke) and the pictures map_Kd, map_d, map_Bump / bump / norm, map_Ke, map_Pr, map_Pm. Runs on a worker thread (ModelLoader).
## OBJ is y-up with counter-clockwise faces like glTF; Godot's front faces are clockwise, so every triangle is written backwards.

const CREASE_DEG := 50.0

## {ok, message, root (Node3D), triangles, notes (PackedStringArray: what was left out)}. `files`: lower-case base name -> bytes of the
## files that came with it (the .mtl, the pictures). More triangles than the budget allows is refused before anything is built.
static func parse(text: String, files: Dictionary, budget: ModelBudget) -> Dictionary:
	var notes := PackedStringArray()
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var has_col := false
	var uvs := PackedVector2Array()
	var nrm := PackedVector3Array()
	var mtl_files: Array = []
	var cur_mat := ""
	var smooth := true
	# per material: the triangles as corner triples (v, t, n) and whether each triangle is smooth
	var groups: Dictionary = {}
	var order: Array = []
	var tris := 0
	var cur: Dictionary = {}
	# the current material's triangles are gathered here and put in its group when the material changes (a PackedArray taken out of a
	# Dictionary is a copy: appending to it would be lost)
	var cc := PackedInt32Array()
	var ss := PackedByteArray()
	for raw in text.split("\n", false):
		var line := (raw as String).strip_edges()
		if line.length() < 2 or line[0] == "#":
			continue
		var c0 := line[0]
		var c1 := line[1]
		if c0 == "v" and c1 == " ":
			var p := line.substr(2).split(" ", false)
			if p.size() >= 3:
				pos.append(Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float()))
				if p.size() >= 6:
					has_col = true
					col.append(Color(p[3].to_float(), p[4].to_float(), p[5].to_float()))
				else:
					col.append(Color.WHITE)
		elif c0 == "v" and c1 == "t":
			var q := line.substr(3).split(" ", false)
			if q.size() >= 2:
				uvs.append(Vector2(q[0].to_float(), 1.0 - q[1].to_float()))
			elif q.size() == 1:
				uvs.append(Vector2(q[0].to_float(), 1.0))
		elif c0 == "v" and c1 == "n":
			var r := line.substr(3).split(" ", false)
			if r.size() >= 3:
				nrm.append(Vector3(r[0].to_float(), r[1].to_float(), r[2].to_float()))
		elif c0 == "f" and c1 == " ":
			if cur.is_empty():
				cur = _group(groups, order, cur_mat)
				cc = cur.c
				ss = cur.s
			var corners := line.substr(2).split(" ", false)
			if corners.size() < 3:
				continue
			var first := _corner(corners[0], pos.size(), uvs.size(), nrm.size())
			var prev := _corner(corners[1], pos.size(), uvs.size(), nrm.size())
			for k in range(2, corners.size()):
				var now := _corner(corners[k], pos.size(), uvs.size(), nrm.size())
				if first.x >= 0 and prev.x >= 0 and now.x >= 0:
					cc.append_array([first.x, first.y, first.z, now.x, now.y, now.z, prev.x, prev.y, prev.z])   # (backwards: see the top)
					ss.append(1 if smooth else 0)
					tris += 1
				prev = now
			if tris > budget.max_triangles:
				return {"ok": false, "message": _too_many(tris, budget), "triangles": tris}
		elif line.begins_with("usemtl"):
			if not cur.is_empty():
				cur.c = cc
				cur.s = ss
			cur_mat = line.substr(6).strip_edges()
			cur = _group(groups, order, cur_mat)
			cc = cur.c
			ss = cur.s
		elif line.begins_with("mtllib"):
			mtl_files.append(line.substr(6).strip_edges())
		elif c0 == "s" and c1 == " ":
			var sv := line.substr(2).strip_edges().to_lower()
			smooth = not (sv == "off" or sv == "0")
	if not cur.is_empty():
		cur.c = cc
		cur.s = ss
	if tris == 0:
		return {"ok": false, "message": "This OBJ file has no faces (only points or lines): there is nothing to show."}
	var mats := {}
	for mf in mtl_files:
		var mb: Variant = files.get(String(mf).get_file().to_lower())
		if mb == null:
			notes.append("its materials file %s was not included (it is shown in grey)" % String(mf).get_file())
			continue
		_read_mtl((mb as PackedByteArray).get_string_from_utf8(), files, budget, mats, notes)
	var root := Node3D.new()
	root.name = "OBJ"
	var mesh := ImporterMesh.new()
	for name in order:
		var g: Dictionary = groups[name]
		if (g.s as PackedByteArray).is_empty():
			continue
		var mat: StandardMaterial3D = mats.get(name)
		if mat == null:
			mat = _plain()
		_add_surface(mesh, g, pos, col if has_col else PackedColorArray(), uvs, nrm, mat, str(name))
		if has_col:
			mat.vertex_color_use_as_albedo = true
	if mesh.get_surface_count() == 0:
		root.free()
		return {"ok": false, "message": "This OBJ file has no faces that can be shown."}
	if budget.lods and tris >= budget.lod_min_triangles:
		mesh.generate_lods(25.0, 60.0, [])
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh.get_mesh()
	root.add_child(mi)
	mi.owner = root
	return {"ok": true, "root": root, "triangles": tris, "notes": notes}


static func _too_many(tris: int, budget: ModelBudget) -> String:
	return ModelLoader.TOO_MANY % ["more than " + ModelLoader.count_text(tris), ModelLoader.count_text(budget.max_triangles)]


static func _group(groups: Dictionary, order: Array, mat: String) -> Dictionary:
	if not groups.has(mat):
		groups[mat] = {"c": PackedInt32Array(), "s": PackedByteArray()}
		order.append(mat)
	return groups[mat]


## "v/vt/vn", "v//vn", "v/vt" or "v" as 0-based indices (-1: none); negative numbers count back from the end.
static func _corner(tok: String, nv: int, nt: int, nn: int) -> Vector3i:
	var parts := tok.split("/")
	var v := _index(parts[0], nv)
	var t := _index(parts[1], nt) if parts.size() > 1 and parts[1] != "" else -1
	var n := _index(parts[2], nn) if parts.size() > 2 and parts[2] != "" else -1
	return Vector3i(v, t, n)


static func _index(s: String, count: int) -> int:
	var i := s.to_int()
	if i < 0:
		i = count + i
	else:
		i -= 1
	return i if i >= 0 and i < count else -1


## One material's triangles as an indexed surface: corners that share position, picture coordinate and normal share a vertex.
static func _add_surface(mesh: ImporterMesh, g: Dictionary, pos: PackedVector3Array, col: PackedColorArray, uvs: PackedVector2Array,
		nrm: PackedVector3Array, mat: StandardMaterial3D, name: String) -> void:
	var c: PackedInt32Array = g.c
	var sm: PackedByteArray = g.s
	var ntri := sm.size()
	var need_normals := false
	for i in ntri:
		if c[i * 9 + 2] < 0 or c[i * 9 + 5] < 0 or c[i * 9 + 8] < 0:
			need_normals = true
			break
	var made := PackedVector3Array()                      # normals made here, one per corner (when the file has none)
	if need_normals:
		made = _make_normals(c, sm, pos)
	var key_to := {}
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_t := PackedVector2Array()
	var out_c := PackedColorArray()
	var idx := PackedInt32Array()
	var any_uv := false
	for i in ntri * 3:
		var v := c[i * 3]
		var t := c[i * 3 + 1]
		var n := c[i * 3 + 2]
		var normal: Vector3
		var nkey := n
		var tri := i / 3
		if c[tri * 9 + 2] >= 0 and c[tri * 9 + 5] >= 0 and c[tri * 9 + 8] >= 0:
			normal = nrm[n]                                # the file's own normals
		else:
			normal = made[i]
			nkey = -2 - (hash(Vector3i(roundi(normal.x * 1000.0), roundi(normal.y * 1000.0), roundi(normal.z * 1000.0))) & 0x3fffffff)
		var key := Vector3i(v, t, nkey)
		var at: Variant = key_to.get(key)
		if at == null:
			at = out_v.size()
			key_to[key] = at
			out_v.append(pos[v])
			out_n.append(normal.normalized() if normal.length_squared() > 1e-12 else Vector3.UP)
			out_t.append(uvs[t] if t >= 0 else Vector2.ZERO)
			if t >= 0:
				any_uv = true
			if not col.is_empty():
				out_c.append(col[v])
		idx.append(int(at))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out_v
	arrays[Mesh.ARRAY_NORMAL] = out_n
	if any_uv:
		arrays[Mesh.ARRAY_TEX_UV] = out_t
	if not out_c.is_empty():
		arrays[Mesh.ARRAY_COLOR] = out_c
	arrays[Mesh.ARRAY_INDEX] = idx
	if any_uv and mat.normal_enabled:
		var st := SurfaceTool.new()
		st.create_from_arrays(arrays)
		st.generate_tangents()
		arrays = st.commit_to_arrays()
	elif mat.normal_enabled:
		mat.normal_enabled = false                       # (a bump map needs picture coordinates)
	mesh.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mat, name)


## A normal for every corner: the corner's face's own, averaged (by area) with the faces round the same point that bend away from it by less
## than CREASE_DEG, among the smooth ones.
static func _make_normals(c: PackedInt32Array, sm: PackedByteArray, pos: PackedVector3Array) -> PackedVector3Array:
	var ntri := sm.size()
	var fn := PackedVector3Array()
	fn.resize(ntri)
	var around := {}                                      # position -> triangles that use it
	for i in ntri:
		var a := pos[c[i * 9]]
		var b := pos[c[i * 9 + 3]]
		var d := pos[c[i * 9 + 6]]
		fn[i] = (d - a).cross(b - a)                      # (the triangle is stored backwards: this is its outward normal, area-weighted)
		if sm[i] == 1:
			for k in 3:
				var v := c[i * 9 + k * 3]
				if not around.has(v):
					around[v] = PackedInt32Array()
				(around[v] as PackedInt32Array).append(i)
	var cos_lim := cos(deg_to_rad(CREASE_DEG))
	var out := PackedVector3Array()
	out.resize(ntri * 3)
	for i in ntri:
		var own := fn[i].normalized()
		for k in 3:
			if sm[i] == 0:
				out[i * 3 + k] = own
				continue
			var sum := Vector3.ZERO
			for j in (around[c[i * 9 + k * 3]] as PackedInt32Array):
				var other := fn[j]
				if other.normalized().dot(own) >= cos_lim:
					sum += other
			out[i * 3 + k] = sum.normalized() if sum.length_squared() > 0.0 else own
	return out


static func _plain() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.78, 0.78, 0.8)
	m.roughness = 0.6
	return m


## The materials of an MTL file into `mats` (name -> StandardMaterial3D).
static func _read_mtl(text: String, files: Dictionary, budget: ModelBudget, mats: Dictionary, notes: PackedStringArray) -> void:
	var m: StandardMaterial3D = null
	var pics := {}
	for raw in text.split("\n", false):
		var line := (raw as String).strip_edges()
		if line == "" or line[0] == "#":
			continue
		var sp := line.find(" ")
		var key := (line if sp < 0 else line.substr(0, sp)).to_lower()
		var rest := "" if sp < 0 else line.substr(sp + 1).strip_edges()
		var nums := rest.split(" ", false)
		if key == "newmtl":
			m = _plain()
			m.resource_name = rest
			mats[rest] = m
			continue
		if m == null:
			continue
		match key:
			"kd":
				if nums.size() >= 3:
					m.albedo_color = Color(nums[0].to_float(), nums[1].to_float(), nums[2].to_float(), m.albedo_color.a)
			"d":
				if nums.size() >= 1:
					_alpha(m, nums[0].to_float())
			"tr":
				if nums.size() >= 1:
					_alpha(m, 1.0 - nums[0].to_float())
			"ns":
				if nums.size() >= 1:
					m.roughness = clampf(sqrt(2.0 / (maxf(nums[0].to_float(), 0.0) + 2.0)), 0.05, 1.0)
			"pr":
				if nums.size() >= 1:
					m.roughness = clampf(nums[0].to_float(), 0.0, 1.0)
			"pm":
				if nums.size() >= 1:
					m.metallic = clampf(nums[0].to_float(), 0.0, 1.0)
			"ke":
				if nums.size() >= 3:
					var e := Color(nums[0].to_float(), nums[1].to_float(), nums[2].to_float())
					if e.r + e.g + e.b > 0.001:
						m.emission_enabled = true
						m.emission = e
			"map_kd", "map_d", "map_bump", "bump", "norm", "map_ke", "map_pr", "map_pm":
				var tex := _picture(_map_file(rest), files, budget, pics, notes)
				if tex == null:
					continue
				match key:
					"map_kd":
						m.albedo_texture = tex
						if _has_alpha(tex):
							m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
					"map_d":
						m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
					"map_bump", "bump", "norm":
						m.normal_enabled = true
						m.normal_texture = tex
					"map_ke":
						m.emission_enabled = true
						m.emission_texture = tex
						if m.emission.r + m.emission.g + m.emission.b <= 0.001:
							m.emission = Color.WHITE                 # (the picture is the colour)
					"map_pr":
						m.roughness_texture = tex
					"map_pm":
						m.metallic_texture = tex
						m.metallic = 1.0


static func _alpha(m: StandardMaterial3D, a: float) -> void:
	a = clampf(a, 0.0, 1.0)
	m.albedo_color.a = a
	if a < 0.999:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		m.cull_mode = BaseMaterial3D.CULL_DISABLED


## The file name of a map statement, after its options ("-bm 0.5 -s 1 1 1 bricks.png" -> "bricks.png").
static func _map_file(rest: String) -> String:
	var args := {"-bm": 1, "-s": 3, "-o": 3, "-t": 3, "-mm": 2, "-clamp": 1, "-blendu": 1, "-blendv": 1, "-imfchan": 1, "-texres": 1, "-boost": 1, "-cc": 1, "-type": 1}
	var toks := rest.split(" ", false)
	var i := 0
	while i < toks.size() and toks[i].begins_with("-"):
		var n: int = args.get(toks[i].to_lower(), 0)
		i += 1
		while n > 0 and i < toks.size() and (toks[i].is_valid_float() or toks[i] in ["on", "off"]):
			i += 1
			n -= 1
	return " ".join(toks.slice(i)).replace("\\", "/")


static func _picture(file: String, files: Dictionary, budget: ModelBudget, pics: Dictionary, notes: PackedStringArray) -> Texture2D:
	var key := file.get_file().to_lower()
	if key == "":
		return null
	if pics.has(key):
		return pics[key]
	var bytes: Variant = files.get(key)
	var tex: Texture2D = null
	if bytes == null:
		notes.append("the picture %s was not included" % file.get_file())
	else:
		tex = ModelLoader.texture_from(bytes as PackedByteArray, key.get_extension(), budget)
		if tex == null:
			notes.append("the picture %s could not be read" % file.get_file())
	pics[key] = tex
	return tex


static func _has_alpha(tex: Texture2D) -> bool:
	var img := tex.get_image()
	return img != null and img.detect_alpha() != Image.ALPHA_NONE
