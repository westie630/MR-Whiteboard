extends Node
## MetaAnchors' own bookkeeping, with stand-ins for the plugin's spatial entities (the PC has no OpenXR runtime): stored anchors are
## tracked by the app itself (never re-saved first, which fails on the Quest after the headset was off), let go when the headset is
## taken off, and tracked again from the entities they had when it is put back on, without a new storage query. The anchors made
## this session (whose nodes the plugin owns and drops when the session stops) come back the same way.

class FakeEntity:
	extends RefCounted
	signal openxr_fb_spatial_entity_set_component_enabled_completed(succeeded: bool, component: int, enabled: bool)
	var uuid: StringName
	var locatable := true
	var refuse := false                      # making it locatable fails
	var settled := true                      # its status says what was set (on the headset it lags behind the answer to the request)
	var tracked := 0                         # track() minus untrack()
	var saves := 0

	func _init(id: String, is_locatable: bool = true) -> void:
		uuid = StringName(id)
		locatable = is_locatable

	func is_component_enabled(_component: int) -> bool:
		return locatable and settled

	func set_component_enabled(component: int, on: bool) -> void:
		locatable = on and not refuse
		openxr_fb_spatial_entity_set_component_enabled_completed.emit(not refuse, component, on)

	func track() -> void:
		tracked += 1

	func untrack() -> void:
		tracked -= 1

	func is_tracked() -> bool:
		return tracked > 0

	func save_to_storage(_location: int) -> void:
		saves += 1


func _ready() -> void:
	var t := TestCase.new("meta_anchors")
	var origin := Node3D.new()
	add_child(origin)
	var ma := MetaAnchors.new()
	add_child(ma)
	ma._supported = true                     # (setup() needs the headset's extensions)
	ma._origin = origin
	var a := FakeEntity.new("aaaaaaaa-1")
	var b := FakeEntity.new("bbbbbbbb-2", false)
	var c := FakeEntity.new("cccccccc-3")
	var changes: Array = []
	ma.tracking_changed.connect(func(u: String, _on: bool): changes.append(u))

	# found in storage: tracked here, made locatable first when it is not, and followed only once its status says so
	ma._wanted = {"aaaaaaaa-1": true, "bbbbbbbb-2": true}
	b.settled = false
	ma._on_query_done([a, b], [&"aaaaaaaa-1", &"bbbbbbbb-2"])
	t.check(ma._has_node("aaaaaaaa-1"), "a locatable stored anchor is followed at once")
	await get_tree().process_frame
	t.check(not ma._has_node("bbbbbbbb-2") and b.tracked == 0, "the other is not tracked while its status still lags")
	b.settled = true
	await get_tree().process_frame
	t.check(ma._has_node("bbbbbbbb-2"), "...and is once it is locatable")
	t.eq([a.tracked, b.tracked], [1, 1], "each is tracked once")
	t.check(b.locatable, "the one that was not locatable was made so")
	t.eq([a.saves, b.saves], [0, 0], "nothing is saved again to track a stored anchor")
	t.eq((ma._nodes["aaaaaaaa-1"] as XRAnchor3D).tracker, &"aaaaaaaa-1", "its node follows the anchor's tracker")
	t.check(changes.has("aaaaaaaa-1"), "the board is told")
	t.check(ma._missing.is_empty(), "nothing is missing")

	# one made this session: the plugin owns its node
	var c_node := XRAnchor3D.new()
	origin.add_child(c_node)
	ma._wanted["cccccccc-3"] = true
	ma._nodes["cccccccc-3"] = c_node
	ma._entities["cccccccc-3"] = c
	c.tracked = 1

	# the headset is taken off: ours are let go, the plugin drops its own
	ma.suspend()
	c_node.free()
	c.tracked = 0
	await get_tree().process_frame
	await get_tree().process_frame
	t.check(not ma._has_node("aaaaaaaa-1") and not ma._has_node("bbbbbbbb-2") and not ma._has_node("cccccccc-3"), "no anchor nodes while the headset is off")
	t.eq([a.tracked, b.tracked], [0, 0], "ours are untracked")
	t.check(not ma.has_pose("aaaaaaaa-1"), "no pose meanwhile")
	t.check(ma._query == null, "nothing is looked up while the headset is off")

	# and put back on: every one is tracked again from its entity, without a storage query
	ma.reload()
	t.check(ma._query == null, "no storage query")
	t.check(ma._has_node("aaaaaaaa-1") and ma._has_node("bbbbbbbb-2") and ma._has_node("cccccccc-3"), "all three anchors are back")
	t.eq([a.tracked, b.tracked, c.tracked], [1, 1, 1], "each tracked once again")
	t.eq([a.saves, b.saves, c.saves], [0, 0, 0], "still nothing saved")
	t.check(ma._own.has("cccccccc-3"), "the one the plugin had made is now followed here")
	ma.reload()
	t.eq([a.tracked, b.tracked, c.tracked], [1, 1, 1], "a second reload (begun, then focussed) changes nothing")

	# untrack: ours are let go without the plugin (which would also erase them from storage)
	var a_node: Node = ma._nodes["aaaaaaaa-1"]
	ma.untrack("aaaaaaaa-1")
	t.eq(a.tracked, 0, "untrack stops tracking it")
	t.check(not ma._wanted.has("aaaaaaaa-1") and not ma._nodes.has("aaaaaaaa-1") and a_node.is_queued_for_deletion(), "and drops its node")

	# an anchor that cannot be made locatable is looked up again later
	var d := FakeEntity.new("dddddddd-4", false)
	d.refuse = true
	ma._wanted["dddddddd-4"] = true
	ma._on_query_done([d], [&"dddddddd-4"])
	t.check(not ma._has_node("dddddddd-4") and not ma._entities.has("dddddddd-4") and ma._missing.has("dddddddd-4"), "refused: missing, to be looked up again")
	ma.untrack("dddddddd-4")
	var e := FakeEntity.new("eeeeeeee-5", false)
	e.settled = false
	ma._wanted["eeeeeeee-5"] = true
	ma._on_query_done([e], [&"eeeeeeee-5"])
	t.check(ma.locating("eeeeeeee-5"), "found but not placed yet: locating (worth waiting for)")
	ma._query = RefCounted.new()             # (a storage query in flight: the PC has no runtime to run the one asked for next)
	ma._query_started_ms = Time.get_ticks_msec()
	ma._settle(MetaAnchors.LOCATABLE_WAIT_S + 0.1)
	t.check(not ma._has_node("eeeeeeee-5") and not ma._enabling.has("eeeeeeee-5") and ma._missing.has("eeeeeeee-5"), "not locatable in time: its entity is dropped, to be looked up again")
	t.check(ma.locating("eeeeeeee-5"), "...but it is still locating: on a Quest 3 just put on that is only slow, nobody gives up on it")
	ma._query = null
	ma._on_query_done([], [&"eeeeeeee-5"])
	t.check(ma.locating("eeeeeeee-5"), "a query answering nothing (a failed one does) does not end that")
	ma._found["eeeeeeee-5"] = MetaAnchors.LOCATE_S
	t.check(not ma.locating("eeeeeeee-5"), "unplaced for LOCATE_S with the headset on, it is no longer waited for (another room)")
	ma._found["eeeeeeee-5"] = 0.0
	ma.suspend()
	ma._found["eeeeeeee-5"] = MetaAnchors.LOCATE_S
	ma._query = RefCounted.new()
	ma._query_started_ms = Time.get_ticks_msec()
	ma.reload()
	t.check(ma.locating("eeeeeeee-5"), "with the headset put back on it is waited for afresh")
	ma._query = null
	ma.untrack("eeeeeeee-5")

	# the session itself lost: the entities' handles are gone with it
	ma.suspend(true)
	t.check(ma._entities.is_empty(), "a lost session forgets the entities")
	get_tree().quit(t.done())
