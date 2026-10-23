class_name DocStore
extends RefCounted
## The documents folder: list, open, create, duplicate, rename, delete, import and export of whole documents (.mrw).

static func dir() -> String:
	return App.docs_dir


static func path_for(id: String) -> String:
	return "%s/%s.%s" % [dir(), id, Document.EXT]


## The AI assistant's file of a document: its suggestion layers and the questions asked, kept apart from the document itself.
static func ai_path(id: String) -> String:
	return "%s/%s.ai.json" % [dir(), id]


## Summaries of every saved document, newest first: [{id, name, modified, frames, items, path}].
static func list() -> Array:
	var out: Array = []
	DirAccess.make_dir_recursive_absolute(dir())
	for f in DirAccess.get_files_at(dir()):
		if not f.ends_with("." + Document.EXT):
			continue
		var p := dir() + "/" + f
		var d := _summary(p)
		if not d.is_empty():
			out.append(d)
	out.sort_custom(func(a, b): return a.modified > b.modified)
	return out


static func _summary(p: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (parsed is Dictionary) or (parsed as Dictionary).get("format", "") != "mr-whiteboard":
		return {}
	var d: Dictionary = parsed
	return {"id": str(d.get("id", "")), "name": str(d.get("name", "Untitled")), "modified": int(d.get("modified", 0)),
		"frames": (d.get("frames", []) as Array).size(), "items": (d.get("items", []) as Array).size(),
		"rooms": (d.get("rooms", []) as Array).size(), "path": p}


static func open(id: String) -> Document:
	return Document.load_file(path_for(id))


static func create_new(doc_name: String = "") -> Document:
	var n := doc_name if doc_name != "" else next_untitled()
	var d := Document.create(n)
	d.save(path_for(d.id))
	return d


static func next_untitled() -> String:
	var used: Array = []
	for s in list():
		used.append(s.name)
	var k := 1
	while used.has("Untitled %d" % k):
		k += 1
	return "Untitled %d" % k


static func rename(id: String, new_name: String) -> void:
	var d := open(id)
	if d != null and new_name.strip_edges() != "":
		d.name = new_name.strip_edges()
		d.save()


## Copy of a document with a new id. The copy keeps the same room and frame anchors (they describe places in the real room), so it
## opens in place straight away; deleting one of the two only erases anchors the other does not use.
static func clone(id: String) -> Document:
	var d := open(id)
	if d == null:
		return null
	d.id = U.uid("d")
	d.name = d.name + " copy"
	d.created = int(Time.get_unix_time_from_system())
	d.path = path_for(d.id)
	d.save()
	return d


static func anchors_of(d: Document) -> Array:
	var out: Array = []
	for r in d.rooms:
		if str(r.anchor) != "":
			out.append(str(r.anchor))
	for f in d.frames.values():
		if (f as FrameData).anchor != "":
			out.append((f as FrameData).anchor)
	return out


## Delete a document file and return the anchors only it used (the caller erases them on the device).
static func delete(id: String) -> Array:
	var mine: Array = []
	var d := open(id)
	if d != null:
		mine = anchors_of(d)
	var p := path_for(id)
	DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(p + ".bak")
	if FileAccess.file_exists(ai_path(id)):
		DirAccess.remove_absolute(ai_path(id))
	var shared := {}
	for s in list():
		var other := open(str(s.id))
		if other != null:
			for a in anchors_of(other):
				shared[a] = true
	var orphans: Array = []
	for a in mine:
		if not shared.has(a):
			orphans.append(a)
	return orphans


## Where exported files go: Documents/MR Whiteboard on a PC, the app's own folder on the headset.
static func export_dir() -> String:
	var base := ""
	if OS.get_name() == "Android":
		base = ProjectSettings.globalize_path("user://exports")
	else:
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		base = (docs if docs != "" else ProjectSettings.globalize_path("user://")) + "/MR Whiteboard"
	DirAccess.make_dir_recursive_absolute(base)
	return base


static func safe_name(s: String) -> String:
	var rx := RegEx.create_from_string(r"[^A-Za-z0-9 _.-]")
	var out := rx.sub(s, "_", true).strip_edges()
	return out if out != "" else "untitled"
