extends Node
## The headset's panels (the dock, Home, the assistant) stay where they were left in the real room: after a restart, with the headset
## taken off and put back on, after recentring, and switching documents. First PanelPlaces on its own with simulated anchors, then the
## whole headset rig started twice on the PC (with the same simulated anchors handed in).

const SIM := "user://test_sim_anchors_panels.json"
const FILE := "user://test_panel_places.json"

var t := TestCase.new("panel_places")


func _ready() -> void:
	App.settings_path = "user://test_settings_panels.cfg"
	App.docs_dir = "user://test_docs_panels"
	App.panel_places_path = FILE
	App.reload()
	App.put("sim_room", "A")
	for p in [SIM, FILE]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	await places_alone()
	for p in [SIM, FILE]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	await whole_rig()
	get_tree().quit(t.done())


func same_place(a: Variant, b: Transform3D, tol: float = 0.002) -> bool:
	if a == null:
		return false
	var x := a as Transform3D
	return x.origin.distance_to(b.origin) < tol and (x.basis.x - b.basis.x).length() < tol * 2.0 and (x.basis.z - b.basis.z).length() < tol * 2.0


func sim(shift: Transform3D = Transform3D.IDENTITY) -> SimAnchors:
	var a := SimAnchors.new(SIM)
	a.shift = shift
	add_child(a)
	return a


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func places_alone() -> void:
	var a1 := sim()
	var pp := PanelPlaces.new()
	pp.setup(a1, FILE)
	var dock := Transform3D(Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, -0.5), Vector3(0.2, 1.2, -0.55))
	var home := Transform3D(Basis(Vector3.UP, 0.7), Vector3(-0.4, 1.45, -0.6))
	t.check(pp.place_of("dock") == null, "nothing is known before the panels were put anywhere")
	pp.put({"dock": dock, "home": home})
	pp.set_open("home", true)
	await frames(2)
	t.check(pp.anchor != "" and a1.is_stored(pp.anchor), "the panels got an anchor of their own")
	t.check(same_place(pp.place_of("dock"), dock) and same_place(pp.place_of("home"), home), "and are where they were put")

	# restart: the same file, new anchors
	a1.free()
	var a2 := sim()
	var pp2 := PanelPlaces.new()
	pp2.setup(a2, FILE)
	t.check(same_place(pp2.place_of("dock"), dock) and same_place(pp2.place_of("home"), home), "after a restart they are where they were left")
	t.check(pp2.is_open("home") and not pp2.is_open("assistant"), "and it is remembered which were open")

	# the tracking space moved under the room (recentred, or the headset was taken off)
	var s := Transform3D(Basis(Vector3.UP, deg_to_rad(50.0)), Vector3(1.5, 0.0, -0.4))
	a2.shift = s
	pp2.tracking_reset()
	pp2.update(0.016)
	t.check(same_place(pp2.place_of("dock"), s * dock) and same_place(pp2.place_of("home"), s * home), "recentred: they stay in the room")

	# the anchor not found (yet): no place is given, so the rig waits or brings the dock in front
	a2.hidden[pp2.anchor] = true
	t.check(pp2.place_of("dock") == null and not pp2.known(), "while the anchor is not found nothing is said about where they are")
	a2.hidden.clear()

	# the anchor found but still being placed (a Quest 3 just put on took longer than the rig waits): the rig puts the dock in front
	# meanwhile, and opens Home beside it. That must not take the anchor's place: once it is placed, they are where they were left
	var keep := pp2.anchor
	var asked := a2.creates
	a2.slow[keep] = true
	pp2.update(0.016)
	var stand_in := s * Transform3D(Basis.IDENTITY, Vector3(0.0, 1.3, -0.45))
	pp2.put({"dock": stand_in})
	pp2.put({"home": stand_in * Transform3D(Basis.IDENTITY, Vector3(-0.5, 0.1, 0.0))})
	for i in 20:
		pp2.update(0.016)
		await frames(1)
	t.eq(a2.creates, asked, "no new anchor is asked for while the old one is being placed")
	t.eq(pp2.anchor, keep, "...and it is kept")
	a2.slow.clear()
	pp2.update(0.016)
	t.check(same_place(pp2.place_of("dock"), s * dock) and same_place(pp2.place_of("home"), s * home), "placed: the dock and Home are where they were left")
	await frames(2)
	pp2.update(0.016)
	t.eq(a2.creates, asked, "...and still no new anchor")

	# the dock taken far away: a new anchor near it, Home stays where it was in the room
	var old := pp2.anchor
	var far := s * Transform3D(Basis.IDENTITY, Vector3(3.0, 1.1, 2.0))
	pp2.put({"dock": far})
	await frames(2)
	t.check(pp2.anchor != old and not a2.is_stored(old), "the dock put far away gets a new anchor (the old one is erased)")
	t.check(same_place(pp2.place_of("dock"), far) and same_place(pp2.place_of("home"), s * home), "nothing moved in the room")

	# making the anchor fails at first: tried again later
	a2.fail_next = 1
	var lost := pp2.anchor
	a2.erase(lost)                                   # (Space Setup redone: the anchor is gone)
	var moved := s * Transform3D(Basis.IDENTITY, Vector3(0.5, 1.2, -0.5))
	pp2.put({"dock": moved})
	await frames(2)
	t.eq(pp2.anchor, lost, "(the first try failed)")
	var until := Time.get_ticks_msec() + int((PanelPlaces.RETRY_MIN_S + 1.0) * 1000.0)
	while Time.get_ticks_msec() < until and pp2.anchor == lost:
		pp2.update(0.016)
		await frames(1)
	t.check(pp2.anchor != lost and same_place(pp2.place_of("dock"), moved), "a later try anchors the dock where it was put")

	# an anchor still being placed that never is (the service stops calling it locating: another room): what was put meanwhile gets
	# an anchor of its own after all
	var never := pp2.anchor
	a2.slow[never] = true
	var here := s * Transform3D(Basis.IDENTITY, Vector3(-0.3, 1.25, 0.6))
	pp2.put({"dock": here})
	pp2.update(0.016)
	await frames(2)
	t.eq(pp2.anchor, never, "(held while it is being placed)")
	a2.slow.erase(never)
	a2.hidden[never] = true
	pp2.update(0.016)
	await frames(2)
	t.check(pp2.anchor != never and same_place(pp2.place_of("dock"), here), "not placed after all: the dock is anchored where it was put")
	a2.hidden.clear()
	a2.free()

	# without anchors (the PC): the poses are kept as they are
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FILE))
	var pc := PanelPlaces.new()
	pc.setup(null, FILE)
	pc.put({"dock": dock})
	var pc2 := PanelPlaces.new()
	pc2.setup(null, FILE)
	t.check(same_place(pc2.place_of("dock"), dock), "without anchors the place is kept as it is")


## The headset rig on the PC, its anchors simulated: the dock moved by its handle, Home opened and moved, then the app restarted, the
## headset taken off and put back on with the tracking space moved, recentred, and another document opened.
func whole_rig() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null:
		t.check(false, "the OpenXR interface class exists")
		return
	var a1 := sim()
	var r1 := await start_rig(a1)
	var rig: XrRig = r1.rig
	t.check(rig.panel.visible, "first start: the dock comes in front")
	var dock_at := Transform3D(Basis(Vector3.UP, -0.6) * Basis(Vector3.RIGHT, -0.4), Vector3(0.6, 1.0, -0.4))
	await carry(rig, rig.panel, dock_at)
	rig.ui.open_side("home")
	await frames(3)
	var home_at := Transform3D(Basis(Vector3.UP, 0.5), Vector3(-0.5, 1.6, -0.8))
	await carry(rig, rig.panels["home"], home_at)
	await frames(5)
	t.check(rig.places.anchor != "", "the panels are anchored")
	var dock_world := rig.panel.global_transform
	var home_world := (rig.panels["home"] as XrPanel).global_transform

	# restart
	await stop_rig(r1)
	a1.free()
	var a2 := sim()
	var r2 := await start_rig(a2)
	rig = r2.rig
	t.check(same_place(rig.panel.global_transform, dock_world), "after a restart the dock is where it was left")
	t.check(rig.ui.is_side_open("home"), "Home that was open is open again")
	t.check(same_place((rig.panels["home"] as XrPanel).global_transform, home_world), "...where it was left")

	# headset off; the tracking space moves; headset on
	rig._on_session("session_visible")
	t.check(not (r2.board as Board).tracking_live, "taking the headset off stops the room search")
	var s := Transform3D(Basis(Vector3.UP, deg_to_rad(-70.0)), Vector3(-1.2, 0.0, 0.8))
	a2.shift = s
	rig._on_session("session_focussed")
	await frames(5)
	t.check(rig.panel.visible and same_place(rig.panel.global_transform, s * dock_world), "headset back on: the dock is where it was left in the room")
	t.check(same_place((rig.panels["home"] as XrPanel).global_transform, s * home_world), "...and Home too")

	# recentred
	var s2 := Transform3D(Basis(Vector3.UP, deg_to_rad(30.0)), Vector3(0.4, 0.0, -2.0))
	a2.shift = s2
	rig._on_recentered()
	await frames(3)
	t.check(same_place(rig.panel.global_transform, s2 * dock_world) and same_place((rig.panels["home"] as XrPanel).global_transform, s2 * home_world), "recentred: the panels stay in the room")

	# another document: the panels do not move
	(r2.board as Board).new_document("Another")
	await frames(10)
	t.check(same_place(rig.panel.global_transform, s2 * dock_world), "another document: the dock stays put")

	# walking away from the dock does not drag it along (only the palm or the stylus brings it)
	rig.camera.position = s2 * Vector3(4.0, 1.6, 4.0)
	await frames(5)
	t.check(same_place(rig.panel.global_transform, s2 * dock_world), "walking away leaves the dock where it was left")
	rig._place_panel_front()
	await frames(2)
	t.check(rig.panel.global_position.distance_to(rig.camera.global_position) < 1.0, "summoning brings it")
	var summoned := rig.panel.global_transform

	# its anchor not found at the next start: it waits a little, then comes in front
	await stop_rig(r2)
	a2.free()
	var a3 := sim(s2)
	a3.hidden[str(JSON.parse_string(FileAccess.get_file_as_string(FILE)).anchor)] = true
	var r3 := await start_rig(a3, s2 * Vector3(4.0, 1.6, 4.0), 10)
	rig = r3.rig
	t.check(not rig.panel.visible, "the dock waits for its anchor")
	a3.hidden.clear()
	await frames(5)
	t.check(rig.panel.visible and same_place(rig.panel.global_transform, summoned), "found: it is where it was left")
	await stop_rig(r3)
	a3.free()


func start_rig(a: SimAnchors, head: Vector3 = Vector3(0, 1.6, 0), n: int = 30) -> Dictionary:
	var board := Board.new()
	add_child(board)
	var rig := XrRig.new()
	add_child(rig)
	board.setup(rig.start(board, a))
	board.open(DocStore.create_new("Panels"))
	rig.camera.position = head
	await frames(n)
	return {"board": board, "rig": rig}


func stop_rig(r: Dictionary) -> void:
	(r.board as Board).flush_save()
	(r.rig as Node).free()
	(r.board as Node).free()
	await frames(2)


## Pick a panel up by its handle with the right hand's pinch, carry it to `to`, let go (through the rig's own handle code).
func carry(rig: XrRig, xp: XrPanel, to: Transform3D) -> void:
	var src := {"id": "right", "point": xp.handle_world(), "holding": true}
	rig._grab_src = "right"
	rig._grab_panel = xp
	rig._grab_origin = xp.global_position
	rig._grab_p0 = src.point
	rig._grab_gain = 1.0
	xp.global_transform = to
	src.holding = false
	rig._update_handle([src], {})
	await frames(2)
