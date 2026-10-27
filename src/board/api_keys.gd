class_name ApiKeys
extends RefCounted
## Every API key the app can use, for the web page (ExportServer, /keys): the three AI providers, the Wit.ai speech token and the
## Telegram bot token. The page can set or remove a key and learns only the last four characters of a saved one. AI keys go through
## AiController (it fetches the model list when one is saved); the Wit.ai token is the `wit_token` setting that WitSpeech reads; the
## Telegram token is the `tg_token` setting that TelegramBridge reads (it starts again whenever the token changes).
## The page also shows the Telegram connection and works its switches (on / off, a test message, unlink). The link that links a chat
## (t.me/<bot>?start=<code>) is given to the page only while the page asks for its own access code: without that, anyone on the Wi-Fi
## could link their own Telegram and be sent the canvases.

const WIT := "wit"
const TELEGRAM := "telegram"

var ai: AiController
var telegram: TelegramBridge               # the Telegram connection, for its status and buttons on the page (null: none)
var show_code := false                     # the page may carry the link that links a chat (only when the page itself needs the access code)


func _init(controller: AiController, bridge: TelegramBridge = null, code_ok: bool = false) -> void:
	ai = controller
	telegram = bridge
	show_code = code_ok


## What the keys page shows: [{id, name, what, has_key, key_hint, keys_url, note}] in display order.
func state() -> Dictionary:
	var services: Array = []
	for p in LlmApi.ORDER:
		services.append({"id": p, "name": LlmApi.name_of(p), "what": "AI assistant", "has_key": ai.key(p) != "", "key_hint": ai.key_hint(p),
			"keys_url": str(LlmApi.PROVIDERS[p].keys_url), "note": "", "field": "API key", "get": "Get a key"})
	var tok := WitSpeech.token()
	var own := str(App.val("wit_token")).strip_edges() != ""
	services.append({"id": WIT, "name": "Wit.ai", "what": "Speech to text", "has_key": tok != "", "key_hint": "" if tok == "" else "…" + tok.right(4),
		"keys_url": "https://wit.ai/apps", "note": "" if own or tok == "" else "This one comes from a file in the app, not from a setting; saving a token here replaces it.",
		"field": "server access token", "get": "Get a key"})
	var tg := str(App.val("tg_token")).strip_edges()
	services.append({"id": TELEGRAM, "name": "Telegram", "what": "Files to and from your phone", "has_key": tg != "", "key_hint": "" if tg == "" else "…" + tg.right(4),
		"keys_url": "https://t.me/BotFather", "note": _telegram_note(tg), "field": "bot token", "get": "Make a bot"})
	var out := {"ok": true, "services": services}
	if telegram != null:
		out["telegram"] = telegram_state()
	return out


## What the keys page shows of the Telegram connection.
func telegram_state() -> Dictionary:
	var tg := telegram
	var linkable := tg.state == "unlinked" and tg.code != "" and tg.bot() != ""
	return {"state": tg.state, "on": bool(App.val("tg_on")), "has_token": tg.token() != "", "bot": tg.bot(), "who": str(App.val("tg_who")),
		"linked": tg.linked_chat() != "", "busy": tg.busy, "error": tg.error,
		"link": TelegramApi.start_link(tg.bot(), tg.code) if linkable and show_code else "",
		"code_in_headset": linkable and not show_code}


func _telegram_note(tg: String) -> String:
	if tg == "":
		return "In Telegram, open @BotFather, send /newbot and follow it; paste the token it gives you here. Then link your chat in the headset: Home > Share > Telegram."
	var bot := str(App.val("tg_bot"))
	var who := str(App.val("tg_who"))
	if bot == "":
		return "The headset is checking this token with Telegram (it needs the internet)."
	if str(App.val("tg_chat")) == "":
		if show_code and telegram != null:
			return "Bot @%s. Not linked to a chat yet." % bot
		return "Bot @%s. Not linked to a chat yet: the headset shows a code in Home > Share > Telegram; send it to @%s." % [bot, bot]
	return "Bot @%s, linked to %s. Send it files from your phone; /svg, /glb or /mrw there gets the open document back." % [bot, who]


func api(cmd: String, data: Dictionary) -> Dictionary:
	match cmd:
		"state":
			return state()
		"set":
			var id := str(data.get("service", ""))
			var k := str(data.get("key", "")).strip_edges()
			if k.length() > 400 or k.contains(" ") or k.contains("\n"):
				return {"ok": false, "message": "That does not look like an API key."}
			if id == WIT:
				App.put("wit_token", k)
				return {"ok": true, "message": "Wit.ai token saved on the headset." if k != "" else "Wit.ai token removed."}
			if id == TELEGRAM:
				if k != "" and not TelegramApi.is_token(k):
					return {"ok": false, "message": "That does not look like a bot token: @BotFather gives a number, a colon and a long code, like 123456789:AAH..."}
				App.put("tg_token", k)
				return {"ok": true, "message": "Telegram bot token saved: the headset checks it now, then shows a code in Home > Share > Telegram to link your chat." if k != "" else "Telegram bot token removed: the headset stops listening to the bot."}
			if LlmApi.is_provider(id):
				return ai.api("key", {"provider": id, "key": k, "use": "1" if str(data.get("use", "")) != "" else ""})
		"telegram":
			return _telegram(str(data.get("do", "")))
	return {"ok": false, "message": "Unknown request."}


func _telegram(what: String) -> Dictionary:
	if telegram == null:
		return {"ok": false, "message": "Telegram is not available."}
	match what:
		"on", "off":
			App.put("tg_on", what == "on")
			return {"ok": true, "message": "Telegram switched on." if what == "on" else "Telegram switched off: the headset stops reading the bot's messages."}
		"unlink":
			if telegram.linked_chat() == "":
				return {"ok": false, "message": "No chat is linked."}
			telegram.unlink()
			return {"ok": true, "message": "The chat is unlinked. Link one again with the new code."}
		"test":
			if not telegram.is_linked():
				return {"ok": false, "message": "Link a chat first."}
			telegram.reply("A test from the whiteboard: this chat is linked to the headset.")
			return {"ok": true, "message": "Test message on its way: look in Telegram."}
	return {"ok": false, "message": "Unknown request."}
