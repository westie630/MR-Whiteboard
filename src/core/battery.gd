class_name Battery
extends RefCounted
## The headset's own battery. Godot 4 has no battery call, so the Quest is asked through Android's BatteryManager over JNI (no
## permission needed). On the PC there is nothing to read: use the --battery switch to see the gauge.
## `read()` -> {"level": 0..100 or -1 when there is no battery or it cannot be read, "charging": bool}.

static var fake: Dictionary = {}           # development switch (--battery=NN[c]): reported instead of the real one


static func read() -> Dictionary:
	if not fake.is_empty():
		return fake
	if OS.get_name() == "Android":
		return _android()
	return {"level": -1, "charging": false}    # Godot 4 has no battery call on other platforms


## `--battery=42` (discharging) or `--battery=42c` (charging); returns false for anything else.
static func set_fake(arg: String) -> bool:
	var s := arg.strip_edges().to_lower()
	var charging := s.ends_with("c")
	s = s.trim_suffix("c")
	if not s.is_valid_int():
		return false
	fake = {"level": clampi(int(s), 0, 100), "charging": charging}
	return true


static func _android() -> Dictionary:
	var out := {"level": -1, "charging": false}
	if not Engine.has_singleton("AndroidRuntime"):
		return out
	var rt: Object = Engine.get_singleton("AndroidRuntime")
	var ctx: Object = rt.call("getApplicationContext")
	if ctx == null:
		ctx = rt.call("getActivity")
	if ctx == null:
		return out
	var bm: Object = ctx.call("getSystemService", "batterymanager")
	if bm == null:
		return out
	var cap: Variant = bm.call("getIntProperty", 4)    # BATTERY_PROPERTY_CAPACITY
	if cap is int and int(cap) >= 0 and int(cap) <= 100:
		out["level"] = int(cap)
	var chg: Variant = bm.call("isCharging")
	out["charging"] = chg is bool and bool(chg)
	return out
