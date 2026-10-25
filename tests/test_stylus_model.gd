extends Node
## The official MX Ink model: it loads, its nib and body agree with what the headset reports, and aligning it moves it only by a
## believable amount.

func _ready() -> void:
	var t := TestCase.new("stylus_model")
	var m := StylusModel.new()
	add_child(m)
	await get_tree().process_frame
	t.check(m.ready_model, "the model loads from assets/models")
	# a Quest 3 reports the real stylus's nib 10.0 cm from the grip pose's origin, with the line between them 18 deg off the stylus (the
	# origin is on the hand's side of the body): the model agrees, so it is authored for the same pose
	var nib := m.nib_local()
	var axis := m.axis_local()
	print("nib in the grip frame: ", nib, ", body ", axis)
	t.check(absf(nib.length() - 0.100) < 0.005 and absf(nib.x) < 0.002, "the nib is 10 cm from the grip pose, on the stylus's plane of symmetry")
	t.check(absf(rad_to_deg(nib.angle_to(axis)) - 18.0) < 3.0, "...and the grip-to-nib line is 18 deg off the body, as on the headset")
	t.check(axis.dot(Vector3.FORWARD) > 0.3 and axis.y < -0.7, "the body points forward and down out of the grip")
	var names := []
	for n in m.find_children("*", "", true, false):
		names.append(str(n.name))
	for want in ["front_button", "middle_button", "rear_button", "tip"]:
		t.check(names.has(want), "the model has its " + want)
	# Godot's generated LODs tear the UV seams round the logos (the "logi" text breaks up once the stylus is small in view, i.e. at
	# arm's length in the headset), and VRAM compression smears the dim grey logos: the import keeps both off
	var cfg := ConfigFile.new()
	t.check(cfg.load(StylusModel.MODEL_PATH + ".import") == OK and not bool(cfg.get_value("params", "meshes/generate_lods", true)), "the model is imported without LODs")
	var tex_cfg := ConfigFile.new()
	t.check(tex_cfg.load("res://assets/models/logitech_mx_ink_Image_0.png.import") == OK and int(tex_cfg.get_value("params", "compress/mode", -1)) == 0 \
			and int(tex_cfg.get_value("params", "detect_3d/compress_to", -1)) == 0, "...and its logo texture stays lossless")
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		var surf: Dictionary = RenderingServer.mesh_get_surface((mi as MeshInstance3D).mesh.get_rid(), 0)
		t.check((surf.get("lods", []) as Array).is_empty(), "%s has no LODs" % mi.name)
	t.check(m.align_nib(nib + Vector3(0.004, -0.003, 0.005)), "a few millimetres off is aligned")
	t.check(m.nib_local().distance_to(nib + Vector3(0.004, -0.003, 0.005)) < 1e-5, "...and the nib is then where the runtime says")
	var before := m.nib_local()
	t.check(not m.align_nib(nib + Vector3(0.0, 0.0, 0.1)), "10 cm off is refused")
	t.check(m.nib_local() == before, "...and nothing moves")
	get_tree().quit(t.done())
