class_name TestCase
extends RefCounted
## Tiny assertion helper for the headless tests: `godot --headless --path . -s tests/<name>.gd`.

var name := ""
var passed := 0
var failed := 0


func _init(test_name: String = "") -> void:
	name = test_name


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL: ", msg)


func eq(a: Variant, b: Variant, msg: String) -> void:
	check(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


func near(a: float, b: float, tol: float, msg: String) -> void:
	check(absf(a - b) <= tol, "%s (got %.5f, want %.5f +-%.5f)" % [msg, a, b, tol])


func done() -> int:
	print("%s: %d passed, %d failed" % [name, passed, failed])
	return failed
