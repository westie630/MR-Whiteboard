class_name LanDiscovery
extends RefCounted
## How a guest's headset finds the owner's session without typing an address: the owner's headset shouts a small beacon (UDP
## broadcast, once a second) saying who it is and which port to call, and a headset that is looking listens for them. A session is on the
## list while its beacons keep coming. Some networks (guest Wi-Fi, a client-isolating router) swallow broadcasts: the address typed in
## by hand always works. A beacon never carries the session code.

const PORT := 8191
const MAGIC := "mrw-session"
const VERSION := 1
const MAX_TEXT := 48

var beacon_s := 1.0                        # how often the owner shouts
var expire_s := 4.5                        # a session whose beacons stopped this long ago is off the list
var target := ""                           # tests: send here instead of broadcasting
var found: Dictionary = {}                 # "address:port" -> {id, name, host, doc, address, port, pin, locked, n, seen}
var own_id := ""                           # a beacon with this id is our own and is not listed

var _tx: PacketPeerUDP
var _rx: PacketPeerUDP
var _info := {}
var _since := 0.0
var _now := 0.0


func announcing() -> bool:
	return _tx != null


func listening() -> bool:
	return _rx != null


## Start shouting. `info`: {id, name (the session), host (the owner), doc, port (the session's), pin (needs a code), locked, n (people)}.
func announce(info: Dictionary) -> void:
	_info = info
	if _tx == null:
		_tx = PacketPeerUDP.new()
		_tx.set_broadcast_enabled(true)
		_since = beacon_s                      # the first one goes out at once


func update_info(info: Dictionary) -> void:
	_info = info


func stop_announcing() -> void:
	if _tx != null:
		_tx.close()
	_tx = null


## Start listening. False when the port is taken (another app, or a second copy on this machine).
func listen() -> bool:
	if _rx != null:
		return true
	var rx := PacketPeerUDP.new()
	rx.set_broadcast_enabled(true)
	if rx.bind(PORT, "*") != OK:
		return false
	_rx = rx
	return true


func stop_listening() -> void:
	if _rx != null:
		_rx.close()
	_rx = null
	found.clear()


func update(dt: float) -> void:
	_now += dt
	if _tx != null:
		_since += dt
		if _since >= beacon_s:
			_since = 0.0
			_shout()
	if _rx != null:
		while _rx.get_available_packet_count() > 0:
			var data := _rx.get_packet()
			_heard(data, _rx.get_packet_ip())
	for k in found.keys():
		if _now - float(found[k].seen) > expire_s:
			found.erase(k)


## What can be chosen from, the most recently heard first: [{id, name, host, doc, address, port, pin, locked, n}].
func sessions() -> Array:
	var out: Array = found.values()
	out.sort_custom(func(a, b): return a.seen > b.seen)
	return out


# ------------------------------------------------------------------------------------------------ the wire

func _shout() -> void:
	var text := JSON.stringify({"m": MAGIC, "v": VERSION, "id": str(_info.get("id", "")), "title": _clip(_info.get("name", "")),
		"host": _clip(_info.get("host", "")), "doc": _clip(_info.get("doc", "")), "port": int(_info.get("port", 0)),
		"pin": bool(_info.get("pin", true)), "locked": bool(_info.get("locked", false)), "n": int(_info.get("n", 0))})
	var bytes := text.to_utf8_buffer()
	for address in destinations():
		_tx.set_dest_address(address, PORT)
		_tx.put_packet(bytes)


## Where a beacon goes: everybody on the wire, and the broadcast address of each network this device is on (the first alone
## only leaves by one of the adapters on a PC with several).
func destinations() -> PackedStringArray:
	if target != "":
		return PackedStringArray([target])
	var out := PackedStringArray(["255.255.255.255"])
	var rx := RegEx.create_from_string(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}$")
	for a in IP.get_local_addresses():
		var m := rx.search(str(a))
		if m == null or str(a).begins_with("127.") or str(a).begins_with("169.254."):
			continue
		var b := "%s.%s.%s.255" % [m.get_string(1), m.get_string(2), m.get_string(3)]
		if not out.has(b):
			out.append(b)
	return out


func _heard(data: PackedByteArray, address: String) -> void:
	if data.size() > 1024 or data.size() < 2 or data[0] != 0x7b:        # not a "{...}" of a sane size
		return
	var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
	if not (parsed is Dictionary):
		return
	var d: Dictionary = parsed
	if str(d.get("m", "")) != MAGIC or int(d.get("v", 0)) != VERSION:
		return
	var id := str(d.get("id", ""))
	var port := int(d.get("port", 0))
	if port < 1024 or port > 65535 or (own_id != "" and id == own_id):
		return
	found["%s:%d" % [address, port]] = {"id": id, "name": _clip(d.get("title", "")), "host": _clip(d.get("host", "")), "doc": _clip(d.get("doc", "")),
		"address": address, "port": port, "pin": bool(d.get("pin", true)), "locked": bool(d.get("locked", false)), "n": int(d.get("n", 0)), "seen": _now}


static func _clip(v: Variant) -> String:
	return str(v).strip_edges().left(MAX_TEXT)
