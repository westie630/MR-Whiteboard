extends Node
## Runs one test script as a node inside a scene (so the App autoload exists):
##   godot --headless --path . res://tests/runner.tscn -- test_document
## Every tests/test_*.gd is a Node whose _ready() runs the checks and calls get_tree().quit(failures).
## A watchdog ends the run if a test crashes before it can quit.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: ... res://tests/runner.tscn -- <test name>")
		get_tree().quit(2)
		return
	var script: GDScript = load("res://tests/%s.gd" % args[0])
	if script == null:
		print("no such test: ", args[0])
		get_tree().quit(2)
		return
	get_tree().create_timer(90.0).timeout.connect(func():
		print("TIMEOUT: the test did not finish")
		get_tree().quit(3))
	add_child(script.new())
