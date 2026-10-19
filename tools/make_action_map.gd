extends SceneTree
## Builds res://openxr_action_map.tres: the actions of the whiteboard bound to the Logitech MX Ink stylus
## (interaction profile /interaction_profiles/logitech/mx_ink_stylus_logitech, extension XR_LOGITECH_mx_ink_stylus_interaction).
##   godot --headless --path . -s tools/make_action_map.gd
## The stylus reports on the hand chosen in the headset's stylus settings, so every action is bound for both hands.

const PROFILE := "/interaction_profiles/logitech/mx_ink_stylus_logitech"
const HANDS := ["/user/hand/left", "/user/hand/right"]
# [action name, localized name, type (0 bool, 1 float, 3 pose, 4 haptic), binding path below /user/hand/<side>]
const ACTIONS := [
	["tip_pose", "Stylus tip pose", 3, "/input/tip_logitech/pose"],
	["tip_force", "Stylus tip pressure", 1, "/input/tip_logitech/force"],
	["middle_force", "Stylus middle button pressure", 1, "/input/cluster_middle_logitech/force"],
	["front_click", "Stylus front button", 0, "/input/cluster_front_logitech/click"],
	["back_click", "Stylus back button", 0, "/input/cluster_back_logitech/click"],
	["dock", "Stylus docked", 0, "/input/dock_logitech/docked_logitech"],
	["haptic", "Stylus haptics", 4, "/output/haptic"],
]


func _initialize() -> void:
	var map := OpenXRActionMap.new()
	var set := OpenXRActionSet.new()
	set.resource_name = "whiteboard"
	set.localized_name = "Whiteboard"
	set.priority = 0
	var profile := OpenXRInteractionProfile.new()
	profile.interaction_profile_path = PROFILE
	var bindings: Array = []
	for a in ACTIONS:
		var act := OpenXRAction.new()
		act.resource_name = a[0]
		act.localized_name = a[1]
		act.action_type = a[2]
		act.toplevel_paths = PackedStringArray(HANDS)
		set.add_action(act)
		for hand in HANDS:
			var b := OpenXRIPBinding.new()
			b.action = act
			b.binding_path = hand + a[3]
			bindings.append(b)
	profile.set_bindings(bindings)
	map.add_action_set(set)
	map.add_interaction_profile(profile)
	var err := ResourceSaver.save(map, "res://openxr_action_map.tres")
	print("saved action map: ", error_string(err), "  actions=", set.get_action_count(), " bindings=", bindings.size())
	quit(0 if err == OK else 1)
