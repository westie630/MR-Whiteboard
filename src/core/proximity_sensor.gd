class_name ProximitySensor
extends Node
## The sensor inside the Quest that notices the headset being taken off (the app pauses, the screen goes dark, the headset sleeps).
## With the `keep_awake` setting on it is told the headset is still worn, so the app keeps running with the headset off (to show
## someone, to let a session or a download carry on). Godot has no call for it: the app sends the same Android broadcast that
## `adb shell am broadcast -a com.oculus.vrpowermanager.prox_close` sends (Meta Quest Developer Hub's "Proximity sensor" switch),
## over JNI, and `automation_disable` to give the sensor back. Meta does not document these; a headset update could ignore them.
## The sensor is given back whenever the app is left or closed, so the headset never stays awake on its own; the broadcast is sent
## again every few minutes while the setting is on, because the headset may switch the sensor back on after a while.

const CLOSE := "com.oculus.vrpowermanager.prox_close"              # "something is in front of the sensor": the headset counts as worn
const GIVE_BACK := "com.oculus.vrpowermanager.automation_disable"  # the sensor works normally again
const RESEND_S := 240.0

var sent := ""                              # the last broadcast sent ("" none); tests read it
var _wait := 0.0


static func available() -> bool:
	return OS.get_name() == "Android" and Engine.has_singleton("AndroidRuntime")


## For the web page's Headset page (ExportServer, /api/headset/state).
static func web_state() -> Dictionary:
	return {"ok": true, "keep_awake": bool(App.val("keep_awake")), "available": available()}


## The web page's switch (ExportServer, POST /api/headset/set {keep_awake: bool}).
static func web_set(data: Dictionary) -> Dictionary:
	if not data.has("keep_awake") or typeof(data.keep_awake) != TYPE_BOOL:
		return {"ok": false, "message": "keep_awake must be true or false."}
	var on := bool(data.keep_awake)
	App.put("keep_awake", on)
	return {"ok": true, "keep_awake": on, "message": "The headset keeps running when it is taken off." if on else "The headset sleeps again when it is taken off."}


func _ready() -> void:
	App.setting_changed.connect(func(k: String):
		if k == "keep_awake":
			_apply())
	_apply()


func _process(delta: float) -> void:
	if not App.val("keep_awake"):
		return
	_wait -= delta
	if _wait <= 0.0:
		_apply()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			if sent == CLOSE:
				_send(GIVE_BACK)                    # left the app: the headset sleeps as usual when it is taken off
		NOTIFICATION_APPLICATION_RESUMED:
			_apply()
		NOTIFICATION_WM_CLOSE_REQUEST:
			if sent == CLOSE:
				_send(GIVE_BACK)


func _exit_tree() -> void:
	if sent == CLOSE:
		_send(GIVE_BACK)


func _apply() -> void:
	_wait = RESEND_S
	if App.val("keep_awake"):
		_send(CLOSE)
	elif sent == CLOSE:
		_send(GIVE_BACK)


func _send(action: String) -> void:
	sent = action
	if not available():
		return
	var rt: Object = Engine.get_singleton("AndroidRuntime")
	var activity: Object = rt.call("getActivity")
	var intent_class: Object = JavaClassWrapper.wrap("android.content.Intent")
	if activity == null or intent_class == null:
		push_warning("[awake] no Android activity: the proximity sensor is left as it is")
		return
	var intent: Object = intent_class.call("Intent", action)
	if intent == null:
		push_warning("[awake] could not make the Android intent")
		return
	activity.call("sendBroadcast", intent)
	var err: Object = JavaClassWrapper.get_exception()
	if err != null:
		push_warning("[awake] the headset refused %s: %s" % [action, err.call("toString")])
		return
	print("[awake] sent ", action.get_slice(".", 3))
