extends SceneTree
## Compile-checks every GDScript under src/ (and tools/dev on request). Prints engine errors with line numbers.
func _initialize() -> void:
	var bad := 0
	var files: Array = []
	_collect("res://src", files)
	for a in OS.get_cmdline_user_args():
		files.append(a)
	for f in files:
		var s = ResourceLoader.load(f, "GDScript", ResourceLoader.CACHE_MODE_IGNORE)
		if s == null or not (s as GDScript).can_instantiate():
			print("FAIL ", f)
			bad += 1
	print("checked ", files.size(), " scripts, failures: ", bad)
	quit(bad)

func _collect(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_collect(dir + "/" + d, out)
