class_name Exporter
extends RefCounted
## Export of the open document, in three formats:
##   SVG  (.svg)  one vector file per canvas - the editable format for diagrams (Inkscape, Illustrator, Figma, browsers)
##   glTF (.glb)  the 3D drawings (3D sketches and, flattened, the canvas ink) for Blender, Unity, Unreal and web viewers
##   MRW  (.mrw)  the document itself, to back up or move to another device
## Files go to Documents/MR Whiteboard on a PC and to the app's folder (user://exports) on the headset.

static func folder_for(doc: Document) -> String:
	return "%s/%s" % [DocStore.export_dir(), DocStore.safe_name(doc.name)]


## One SVG per canvas. Returns {ok, paths, folder, message}.
static func svg(doc: Document, opts: Dictionary = {}) -> Dictionary:
	var folder := folder_for(doc)
	var written := SvgExport.export_document(doc, folder, opts)
	if written.is_empty():
		return {"ok": false, "paths": written, "folder": folder, "message": "There is no canvas to export. (3D sketches export as .glb.)"}
	return {"ok": true, "paths": written, "folder": folder, "message": "Saved %d SVG file%s to %s" % [written.size(), "" if written.size() == 1 else "s", folder]}


## The whole document as one .glb: each frame a node placed at its pose, ink as coloured meshes.
static func glb(doc: Document) -> Dictionary:
	var root := Node3D.new()
	root.name = DocStore.safe_name(doc.name)
	var count := 0
	for f in doc.frames.values():
		var fd: FrameData = f
		var fnode := Node3D.new()
		fnode.name = DocStore.safe_name(fd.name)
		fnode.transform = Transform3D(fd.xf.basis.scaled(Vector3.ONE * fd.scale), fd.xf.origin)
		root.add_child(fnode)
		for it in doc.items_of(fd.id):
			var item: Item = it
			var mesh := _item_mesh(item, fd.kind == FrameData.VOLUME)
			if mesh == null:
				continue
			var mi := MeshInstance3D.new()
			mi.name = item.id
			mi.mesh = mesh
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.vertex_color_use_as_albedo = true
			m.vertex_color_is_srgb = true
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			if item.color.a < 0.99 or Brushes.get_def(item.brush).alpha < 0.99:
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mi.material_override = m
			fnode.add_child(mi)
			count += 1
	var folder := DocStore.export_dir()
	var path := "%s/%s.glb" % [folder, DocStore.safe_name(doc.name)]
	if count == 0:
		root.free()
		return {"ok": false, "paths": PackedStringArray(), "folder": folder, "message": "Nothing to export yet."}
	var state := GLTFState.new()
	var gd := GLTFDocument.new()
	var err := gd.append_from_scene(root, state)
	if err == OK:
		err = gd.write_to_filesystem(state, path)
	root.free()
	if err != OK:
		return {"ok": false, "paths": PackedStringArray(), "folder": folder, "message": "glTF export failed (error %d)." % err}
	return {"ok": true, "paths": PackedStringArray([path]), "folder": folder, "message": "Saved 3D model %s (text is not included)" % path}


## Copy of the document file (.mrw).
static func document(doc: Document) -> Dictionary:
	var folder := DocStore.export_dir()
	var path := "%s/%s.%s" % [folder, DocStore.safe_name(doc.name), Document.EXT]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "paths": PackedStringArray(), "folder": folder, "message": "Could not write %s" % path}
	f.store_string(JSON.stringify(doc.to_dict()))
	f.close()
	return {"ok": true, "paths": PackedStringArray([path]), "folder": folder, "message": "Saved %s" % path}


static func _item_mesh(item: Item, volume: bool) -> ArrayMesh:
	var col := Brushes.color_for(item.brush, item.color)
	match item.kind:
		Item.STROKE:
			var p := PackedVector3Array()
			var w := PackedFloat32Array()
			for i in item.point_count():
				p.append(item.pt(i))
				w.append(Brushes.width_at(item.brush, item.width, item.pressure(i)))
			var arrays := StrokeMesher.tube_arrays(p, w, col, 8) if volume else StrokeMesher.ribbon_arrays(p, w, col, false, true)
			return StrokeMesher.to_mesh(arrays) if not arrays.is_empty() else null
		Item.SHAPE:
			var m := ArrayMesh.new()
			if item.fill.a > 0.01 and not item.is_line():
				var poly := item.poly if item.shape == "poly" else Shapes.world_fill_poly(item)
				StrokeMesher.to_mesh(StrokeMesher.fill_arrays(poly, item.fill), m)
			var outlines: Array = [{"pts": item.poly, "closed": true}] if item.shape == "poly" else Shapes.world_outlines(item)
			for o in outlines:
				var p3 := PackedVector3Array()
				var w3 := PackedFloat32Array()
				for q in o.pts:
					p3.append(Vector3(q.x, q.y, 0.0005))
					w3.append(item.width)
				StrokeMesher.to_mesh(StrokeMesher.ribbon_arrays(p3, w3, item.color, o.closed, not o.closed), m)
			return m if m.get_surface_count() > 0 else null
	return null
