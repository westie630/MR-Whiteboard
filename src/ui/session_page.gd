class_name SessionPage
extends RefCounted
## The Session tab of Home: everything about starting and joining a session (Session). Not in a session: start one, or pick one found on the
## Wi-Fi (or type its address) and give its code. Owning: the code and address to tell the guests, who is here and what they may
## do, aligning with the room, ending the session. In a session as a guest: who the owner is, whether you may draw, aligning, leaving.
## The content is rebuilt when something it shows changes; the one live line (the delay) is updated in place.

var home: HomePanel

var _box: VBoxContainer
var _sig := ""
var _confirm := ""                         # a two-press button that has had its first press
var _status: Label
var _kit := UiKit.new()


func build(page: VBoxContainer, h: HomePanel) -> void:
	home = h
	_box = UiKit.vcol(page, 12)


func _s() -> Session:
	return home.shell.board.session


## Called every frame by Home: sessions are only listened for while this page is what is being looked at.
func tick(_delta: float) -> void:
	var s := _s()
	var want := home.visible and home.tab == "session" and s.role == Session.Role.NONE
	if want != s.scanning:
		s.scan(want)


func refresh() -> void:
	var s := _s()
	var sig := _signature(s)
	if sig != _sig:
		_sig = sig
		_status = null
		_kit = UiKit.new()
		UiKit.clear(_box)
		match s.role:
			Session.Role.HOST:
				_build_host(s)
			Session.Role.CLIENT:
				_build_client(s)
			_:
				_build_idle(s)
	_kit.sync()
	if _status != null:
		_status.text = _status_text(s)


func _signature(s: Session) -> String:
	var sig := "%d|%s|%s|%s|%s|%s|%s%s%s|%s|%s%s|%s|%s" % [s.role, s.phase, s.code, s.session_title, s.doc_name, s.last_error, s.locked, s.edit_all, s.canvas_edit,
		s.align_mode, s.realign_hint, s.can_edit(), _confirm, str(App.val("net_name"))]
	sig += "|%s%s" % [s.have_space, s.scan_failed]
	for id in s.peer_ids():
		var p: Dictionary = s.peers[id]
		sig += "/%d,%s,%s,%s,%d" % [id, p.name, p.can_edit, p.align, p.color]
	if s.role == Session.Role.NONE:
		for c in s.disco.sessions():
			sig += "~%s,%s,%d,%s,%d" % [c.name, c.host, c.n, c.locked, c.port]
	return sig


# ------------------------------------------------------------------------------------------------ not in a session

func _build_idle(s: Session) -> void:
	var me := _my_name(false)
	var who := UiKit.card(_box)
	who.add_child(UiKit.button("text", "Your name: %s" % me, func(): _ask_name(), 52.0, "ghost"))
	UiKit.note(who, "What the others in the session see next to your pointer. Owner or guest, it is the same name.")

	UiKit.header(_box, "Share this room")
	var t := UiKit.card(_box)
	UiKit.note(t, "Start a session: guests on this Wi-Fi join, see the canvases of this room and draw on them with you. Everything they draw stays in your document.")
	_kit.switch(t, "Guests need a code", "net_code", "Stops strangers on the network from joining")
	var start := UiKit.button("session", "Start a session", func(): _start(), 56.0)
	start.accent = UITheme.GOOD
	t.add_child(start)

	UiKit.header(_box, "Join")
	var j := UiKit.card(_box)
	if s.scan_failed:
		UiKit.note(j, "This network does not let the app look for sessions. Type the owner's address below.")
	var found := s.disco.sessions()
	if found.is_empty() and not s.scan_failed:
		UiKit.note(j, "Looking for sessions on this Wi-Fi... When the owner starts one it appears here.")
	for c in found:
		var entry: Dictionary = c
		var row := UiKit.hrow(j, 6)
		var b := Btn.new("wifi", "%s   %s" % [entry.name, entry.host])
		b.align = HORIZONTAL_ALIGNMENT_LEFT
		b.small = true
		b.custom_minimum_size = Vector2(0, 58)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = bool(entry.locked)
		b.pressed.connect(func(): _pick(entry))
		row.add_child(b)
		var info := UiKit.label("closed" if entry.locked else "%d here" % int(entry.n), true, UITheme.FONT_TINY)
		info.custom_minimum_size = Vector2(70, 0)
		info.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(info)
	j.add_child(UiKit.button("pin", "Join by address", func(): _ask_address(), 52.0, "ghost"))
	if s.last_error != "":
		var e := UiKit.label(s.last_error, false, UITheme.FONT_SMALL, 500)
		e.add_theme_color_override("font_color", UITheme.WARN)
		j.add_child(e)


func _start() -> void:
	var s := _s()
	var err := s.start_hosting(_my_name(true), "", bool(App.val("net_code")))
	match err:
		OK:
			pass
		ERR_UNCONFIGURED:
			s.say("Wait until the room is found, then start the session.")
		_:
			s.say("Could not start the session (error %d): is another copy of the app running?" % err)


func _pick(c: Dictionary) -> void:
	if bool(c.pin):
		home.shell.ask_name("Session code from the owner", "", func(code: String): _join(str(c.address), int(c.port), code))
	else:
		_join(str(c.address), int(c.port), "")


func _ask_address() -> void:
	home.shell.ask_name("The owner's address (like 192.168.1.23)", str(App.val("net_last")), func(text: String):
		var t := text.strip_edges()
		var port := Session.PORT
		if t.contains(":"):
			port = int(t.get_slice(":", 1))
			t = t.get_slice(":", 0)
		if t == "" or not RegEx.create_from_string(r"^[A-Za-z0-9._-]+$").search(t):
			_s().say("That is not an address. It looks like 192.168.1.23.")
			return
		App.put("net_last", text.strip_edges())
		home.shell.ask_name("Session code from the owner (empty if there is none)", "", func(code: String): _join(t, port, code), true))


func _join(address: String, port: int, code: String) -> void:
	var s := _s()
	s.last_error = ""
	var err := s.join(address, port, code, _my_name(false))
	if err != OK:
		s.say("Could not start joining (error %d)." % err)


# ------------------------------------------------------------------------------------------------ as the owner

func _build_host(s: Session) -> void:
	var c := UiKit.card(_box)
	c.add_child(UiKit.label(s.session_title, false, UITheme.FONT, 600))
	if s.phase == "ending":
		UiKit.note(c, s.phase_text())
		return
	if s.code != "":
		var code := UiKit.label("Code  %s" % s.code, false, UITheme.FONT_BIG, 600)
		code.add_theme_color_override("font_color", UITheme.GOOD)
		c.add_child(code)
	var addr := ExportServer.lan_addresses()
	var where := "" if addr.is_empty() else str(addr[0]) + ("" if s.net.port == Session.PORT else ":%d" % s.net.port)
	UiKit.note(c, ("Guests open Home > Session and pick \"%s\"" % s.session_title) + ((" or type %s" % where) if where != "" else "") + ". Same Wi-Fi, no guest network.")
	var r := UiKit.hrow(c, 8)
	if s.code != "":
		r.add_child(UiKit.button("undo", "New code", func(): s.change_code(), 48.0, "ghost"))
	r.add_child(UiKit.button("session", "Align with the room", func(): s.align_begin(), 48.0))
	_status = UiKit.label(_status_text(s), true, UITheme.FONT_TINY)
	c.add_child(_status)
	_kit.switch(c, "Draw with a pinch", "finger_draw", "When you hand the stylus over, or have none")
	UiKit.note(c, "Owner and guests touch the same two real places with the stylus to see the board in the same real spot. Without it each guest sees the board in front of them.")
	if s.align_mode == "points":
		c.add_child(UiKit.button("undo", "Back to showing the board where I have it", func(): s.align_reset(), 44.0, "ghost"))

	UiKit.header(_box, "What guests may do")
	var rules := UiKit.card(_box)
	var close_sw := Switch.new("Closed to new guests", "Nobody else can join; those in stay")
	close_sw.on = s.locked
	close_sw.toggled.connect(func(on: bool): s.set_locked(on))
	rules.add_child(close_sw)
	var draw_sw := Switch.new("Guests can draw and write", "Off: they can look but not change")
	draw_sw.on = s.edit_all
	draw_sw.toggled.connect(func(on: bool): s.set_edit_all(on))
	rules.add_child(draw_sw)
	var cv_sw := Switch.new("Guests can add and move canvases", "Off: only you decide where canvases go. Lock a canvas in Canvases to keep it as it is.")
	cv_sw.on = s.canvas_edit
	cv_sw.toggled.connect(func(on: bool): s.set_canvas_edit(on))
	rules.add_child(cv_sw)

	UiKit.header(_box, "In the session (%d)" % s.guest_count())
	var list := UiKit.card(_box)
	if s.guest_count() == 0:
		UiKit.note(list, "Nobody has joined yet.")
	for id in s.peer_ids():
		_person(list, s, id)
	var end := UiKit.button("power", "End the session" if _confirm != "end" else "Press again to end it", func(): _arm("end", func(): s.end()), 52.0, "ghost")
	end.danger = true
	_box.add_child(end)


## One line of the roster: a colour, the name, how they are aligned, and for a guest the switches the owner has.
func _person(parent: Control, s: Session, id: int) -> void:
	var p: Dictionary = s.peers[id]
	var row := UiKit.hrow(parent, 6)
	var who := Btn.new("", str(p.name) + ("  (you)" if id == s.my_id else ""))
	who.swatch = Session.COLORS[int(p.color) % Session.COLORS.size()]
	who.align = HORIZONTAL_ALIGNMENT_LEFT
	who.small = true
	who.custom_minimum_size = Vector2(0, 52)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(who)
	var mode := s.align_mode if id == s.my_id else str(p.align)
	var state := UiKit.label(_align_word(mode, id == Session.HOST_ID), true, UITheme.FONT_TINY)
	state.custom_minimum_size = Vector2(118, 0)
	state.size_flags_horizontal = Control.SIZE_SHRINK_END
	state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(state)
	if s.role == Session.Role.HOST and id != s.my_id:
		var ed := UiKit.tool("write", "Can draw: press to make them view only" if bool(p.can_edit) else "View only: press to let them draw", func(): s.set_peer_edit(id, not bool(p.can_edit)), 52.0)
		ed.on = bool(p.can_edit)
		row.add_child(ed)
		var out := UiKit.tool("close", "Remove from the session", func(): s.kick(id), 52.0)
		out.danger = true
		row.add_child(out)


func _align_word(mode: String, owner: bool) -> String:
	match mode:
		"points":
			return "lined up"
		"here":
			return "board in front"
	return "" if owner else "waiting"


# ------------------------------------------------------------------------------------------------ as a guest

func _build_client(s: Session) -> void:
	var c := UiKit.card(_box)
	var title := s.session_title if s.session_title != "" else "Session"
	c.add_child(UiKit.label(title, false, UITheme.FONT, 600))
	if s.phase != "live":
		var line := UiKit.label(s.phase_text(), true, UITheme.FONT_SMALL)
		c.add_child(line)
		c.add_child(UiKit.button("close", "Cancel", func(): s.leave(), 52.0, "ghost"))
		return
	UiKit.note(c, "Owner: %s    Document: %s" % [s.host_name, s.doc_name])
	_status = UiKit.label(_status_text(s), true, UITheme.FONT_TINY)
	c.add_child(_status)
	var ed := UiKit.label("", false, UITheme.FONT_SMALL, 500)
	if not s.can_edit():
		ed.text = "The owner has switched editing off: you can look, not change."
		ed.add_theme_color_override("font_color", UITheme.WARN)
	elif not s.canvas_edit:
		ed.text = "You can draw, write and move what is on the canvases. The owner places the canvases."
	else:
		ed.text = "You can draw, write, and add or move canvases."
	c.add_child(ed)
	_kit.switch(c, "Draw with a pinch", "finger_draw", "No stylus? There is only one in the session. Pinch on a canvas to draw")
	var r := UiKit.hrow(c, 8)
	r.add_child(UiKit.button("align", "Align with the room", func(): s.align_begin(), 52.0))
	r.add_child(UiKit.button("pin", "Board in front of me", func(): s.use_here(), 52.0))
	if s.realign_hint:
		var w := UiKit.label("The owner aligned again. If you used the same two points you are fine; if not, align again.", false, UITheme.FONT_TINY)
		w.add_theme_color_override("font_color", UITheme.WARN)
		c.add_child(w)
	UiKit.header(_box, "In the session (%d)" % s.peers.size())
	var list := UiKit.card(_box)
	for id in s.peer_ids():
		_person(list, s, id)
	var r2 := UiKit.hrow(_box, 8)
	r2.add_child(UiKit.button("doc", "Keep a copy", func():
		var name := s.save_copy()
		s.say(("Saved \"%s\" in your documents." % name) if name != "" else "Nothing to save."), 52.0, "ghost"))
	var leave := UiKit.button("close", "Leave the session" if _confirm != "leave" else "Press again to leave", func(): _arm("leave", func(): s.leave()), 52.0, "ghost")
	leave.danger = true
	r2.add_child(leave)


func _status_text(s: Session) -> String:
	var parts: Array = []
	if s.role == Session.Role.CLIENT and s.phase == "live":
		parts.append("%d ms" % s.rtt_ms if s.rtt_ms > 0 else "connected")
	parts.append(s.align_text())
	return "  ·  ".join(parts)


# ------------------------------------------------------------------------------------------------ small things

func _arm(key: String, act: Callable) -> void:
	if _confirm == key:
		_confirm = ""
		act.call()
	else:
		_confirm = key
		_s().say("Press again to confirm.")


func _my_name(for_host: bool) -> String:
	var n := str(App.val("net_name")).strip_edges()
	return n if n != "" else ("Owner" if for_host else "Guest")


func _ask_name() -> void:
	home.shell.ask_name("Your name in the session", _my_name(false), func(t: String): App.put("net_name", t.strip_edges().left(Session.MAX_NAME)))
