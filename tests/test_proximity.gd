extends Node
## "Keep running when taken off": the setting tells the sensor the headset is worn, gives it back when switched off or when the app
## is left, and the web page's Headset page reads and sets it. (Whether the Quest honours the broadcast needs the headset.)

func _ready() -> void:
	var t := TestCase.new("proximity")
	App.settings_path = "user://test_settings_proximity.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(App.settings_path))
	App.reload()
	t.check(not App.val("keep_awake"), "off by default")
	t.check(not ProximitySensor.available(), "the PC has no sensor to talk to")

	var s := ProximitySensor.new()
	add_child(s)
	t.eq(s.sent, "", "off at start: nothing is sent")
	App.put("keep_awake", true)
	t.eq(s.sent, ProximitySensor.CLOSE, "switched on: the sensor is told the headset is worn")
	s.sent = ""
	s._process(ProximitySensor.RESEND_S + 1.0)
	t.eq(s.sent, ProximitySensor.CLOSE, "sent again after a while")
	s._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	t.eq(s.sent, ProximitySensor.GIVE_BACK, "the app left: the sensor is given back")
	s._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	t.eq(s.sent, ProximitySensor.CLOSE, "back in the app: worn again")
	App.put("keep_awake", false)
	t.eq(s.sent, ProximitySensor.GIVE_BACK, "switched off: the sensor is given back")
	s.sent = ""
	s._process(ProximitySensor.RESEND_S + 1.0)
	s._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	t.eq(s.sent, "", "off: nothing is sent")
	App.put("keep_awake", true)
	remove_child(s)
	t.eq(s.sent, ProximitySensor.GIVE_BACK, "closing the app gives the sensor back")
	s.free()
	App.put("keep_awake", false)

	var srv := ExportServer.new()
	add_child(srv)
	var doc := Document.new()
	srv.doc_source = func(): return doc
	srv.require_pin = false
	var page := _body(srv.handle("GET", "/headset", {}, PackedByteArray(), "pc"))
	t.check(page.contains("id=hs-awake") and page.contains("Keep running when taken off"), "the Headset page has the switch")
	t.check(_body(srv.handle("GET", "/", {}, PackedByteArray(), "pc")).contains("href='/headset'"), "the top bar links to it")
	var st: Dictionary = JSON.parse_string(_body(srv.handle("GET", "/api/headset/state", {}, PackedByteArray(), "pc")))
	t.check(st.ok and not st.keep_awake and not st.available, "the state: off, not a Quest")
	var res := srv.handle("POST", "/api/headset/set", {"x-requested-with": "mrw"}, JSON.stringify({"keep_awake": true}).to_utf8_buffer(), "pc")
	t.check(res.status == 200 and App.val("keep_awake"), "the page switches it on")
	res = srv.handle("POST", "/api/headset/set", {"x-requested-with": "mrw"}, JSON.stringify({"keep_awake": "yes"}).to_utf8_buffer(), "pc")
	t.check(res.status == 422 and App.val("keep_awake"), "a wrong value is refused")
	res = srv.handle("POST", "/api/headset/set", {}, JSON.stringify({"keep_awake": false}).to_utf8_buffer(), "pc")
	t.check(res.status != 200 and App.val("keep_awake"), "a change from another site is refused")
	res = srv.handle("POST", "/api/headset/set", {"x-requested-with": "mrw"}, JSON.stringify({"keep_awake": false}).to_utf8_buffer(), "pc")
	t.check(res.status == 200 and not App.val("keep_awake"), "the page switches it off")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(App.settings_path))
	get_tree().quit(t.done())


func _body(res: Dictionary) -> String:
	return (res.body as PackedByteArray).get_string_from_utf8()
