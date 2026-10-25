extends Node
## The battery indicator: the development override parses, the gauge shows only when there is a level, picks its warning colours,
## and sits in the dock without a script error. (The Android read itself needs the headset.)

func _ready() -> void:
	var t := TestCase.new("battery")
	t.check(Battery.set_fake("42c"), "42c is accepted")
	t.eq(Battery.read(), {"level": 42, "charging": true}, "a charging fake")
	t.check(Battery.set_fake("250"), "250 is accepted")
	t.eq(Battery.read(), {"level": 100, "charging": false}, "a fake is clamped")
	t.check(not Battery.set_fake("abc"), "junk is refused")
	Battery.fake = {}
	var real := Battery.read()
	t.eq(int(real["level"]), -1, "the PC has no battery to read")

	var g := BatteryGauge.new()
	add_child(g)
	g.set_state(-1, false)
	t.check(not g.visible, "hidden without a battery")
	g.set_state(80, false)
	t.check(g.visible, "shown with a level")
	t.eq(g.tint(), UITheme.TEXT_DIM, "plenty: quiet")
	g.set_state(25, false)
	t.eq(g.tint(), UITheme.WARN, "low: amber")
	g.set_state(10, false)
	t.eq(g.tint(), UITheme.BAD, "very low: red")
	g.set_state(10, true)
	t.eq(g.tint(), UITheme.GOOD, "charging: green")
	await get_tree().process_frame

	Battery.set_fake("63")
	var dock := Dock.new()
	add_child(dock)
	await get_tree().process_frame
	t.check(dock.battery.visible and dock.battery.level == 63, "the dock shows the battery")
	Battery.fake = {}
	get_tree().quit(t.done())
