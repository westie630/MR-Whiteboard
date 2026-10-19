extends SceneTree
func _init():
	for cn in OS.get_cmdline_user_args():
		print("=== ", cn, " (inherits ", ClassDB.get_parent_class(cn), ")")
		for p in ClassDB.class_get_property_list(cn, true):
			if p.usage & PROPERTY_USAGE_EDITOR or p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				print("  prop ", p.name, " : ", type_string(p.type), " ", p.get("class_name", ""))
		for m in ClassDB.class_get_method_list(cn, true):
			var args := []
			for a in m.args:
				args.append("%s: %s%s" % [a.name, type_string(a.type), (" " + str(a.class_name)) if a.class_name != "" else ""])
			print("  func ", m.name, "(", ", ".join(args), ") -> ", type_string(m.return.type), " ", m.return.get("class_name", ""))
		for s in ClassDB.class_get_signal_list(cn, true):
			var args := []
			for a in s.args: args.append("%s: %s" % [a.name, type_string(a.type)])
			print("  signal ", s.name, "(", ", ".join(args), ")")
		for c in ClassDB.class_get_enum_list(cn, true):
			print("  enum ", c, " ", ClassDB.class_get_enum_constants(cn, c))
	quit()
