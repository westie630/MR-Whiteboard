class_name SessionNet
extends RefCounted
## The wire between the headsets of a session: Godot's ENet (UDP with reliability) used as a plain packet pipe, one server (the owner)
## and its clients. Three channels so that a big thing in flight never holds up a small one:
##   CONTROL  reliable   who is here, permissions, acknowledgements
##   DATA     reliable   the document: the snapshot a joiner gets and every edit afterwards (can be megabytes)
##   LIVE     unreliable where everybody is looking and pointing, a dozen times a second (a lost packet is out of date anyway)
## Messages are dictionaries with a "t" (type); only plain data is accepted (no objects), and anything else is dropped here, so the
## code above never sees what the network made of it. Everything arrives through poll(), which the owner calls every frame.

signal peer_joined(id: int)                # server: a headset connected (it has not said hello yet)
signal peer_left(id: int)
signal connected()                         # client: the server answered
signal failed()                            # client: could not reach the server, or lost it
signal received(from: int, channel: int, msg: Dictionary)
signal received_live(from: int, bytes: PackedByteArray)

const CH_CONTROL := 0
const CH_DATA := 1
const CH_LIVE := 2
const CHANNELS := 3
const MAX_PACKET := 64 * 1024 * 1024
const SERVER := 1                          # the server's peer id in ENet
const CONNECT_TIMEOUT_MS := 6000           # a client that has not reached the server by then has not

var peer: ENetMultiplayerPeer
var is_server := false
var port := 0
var address := ""                          # client: where it connected to

var _was := MultiplayerPeer.CONNECTION_DISCONNECTED
var _started_ms := 0
var _ids: Dictionary = {}                  # the peers that are connected now (the engine complains when asked about one that is not)


func is_open() -> bool:
	return peer != null


## The headset's own id (1 on the server).
func my_id() -> int:
	return peer.get_unique_id() if peer != null else 0


func is_connected_to_server() -> bool:
	return peer != null and not is_server and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## Listen on `preferred_port`, or the next free one. Returns OK or the error of the last try.
func host(preferred_port: int, max_clients: int, tries: int = 10) -> Error:
	close()
	var err := ERR_CANT_CREATE
	for i in tries:
		var p := ENetMultiplayerPeer.new()
		err = p.create_server(preferred_port + i, max_clients, CHANNELS)
		if err == OK:
			peer = p
			is_server = true
			port = preferred_port + i
			_hook()
			return OK
	return err


func join(server_address: String, server_port: int) -> Error:
	close()
	var p := ENetMultiplayerPeer.new()
	var err := p.create_client(server_address, server_port, CHANNELS)
	if err != OK:
		return err
	peer = p
	is_server = false
	port = server_port
	address = server_address
	_was = MultiplayerPeer.CONNECTION_CONNECTING
	_started_ms = Time.get_ticks_msec()
	_hook()
	return OK


func _hook() -> void:
	_ids.clear()
	peer.peer_connected.connect(func(id: int):
		_ids[id] = true
		if is_server:
			peer_joined.emit(id))
	peer.peer_disconnected.connect(func(id: int):
		_ids.erase(id)
		if is_server:
			peer_left.emit(id))


func close() -> void:
	if peer != null:
		peer.close()
	peer = null
	is_server = false
	port = 0
	address = ""
	_ids.clear()
	_was = MultiplayerPeer.CONNECTION_DISCONNECTED


## The address a connected client is calling from ("" when unknown).
func address_of(id: int) -> String:
	if peer == null or not _ids.has(id):
		return ""
	var pp := peer.get_peer(id)
	return pp.get_remote_address() if pp != null else ""


## Let the server drop a client (it is told to go; its state is cleaned up by peer_left).
func kick(id: int) -> void:
	if peer != null and is_server and _ids.has(id):
		peer.disconnect_peer(id, false)


# ------------------------------------------------------------------------------------------------ sending

## A message to one headset (`to`), to all (0) or to all but one (-id). Clients can only send to the server.
func send(to: int, msg: Dictionary, channel: int = CH_CONTROL) -> void:
	_put(to, var_to_bytes(msg), channel)


## Raw bytes on the live channel (already packed by the caller).
func send_live(to: int, bytes: PackedByteArray) -> void:
	_put(to, bytes, CH_LIVE)


func _put(to: int, bytes: PackedByteArray, channel: int) -> void:
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	peer.set_target_peer(to if is_server else SERVER)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	peer.put_packet(bytes)


# ------------------------------------------------------------------------------------------------ receiving

func poll() -> void:
	if peer == null:
		return
	peer.poll()
	if not is_server and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and _was != MultiplayerPeer.CONNECTION_CONNECTED:
		_was = MultiplayerPeer.CONNECTION_CONNECTED
		connected.emit()
		if peer == null:
			return
	# what has arrived is read before a lost connection is reported: the last thing a server says is often "you are out"
	while peer != null and peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var ch := peer.get_packet_channel()
		var data := peer.get_packet()
		if data.size() > MAX_PACKET:
			continue
		if ch == CH_LIVE:
			received_live.emit(from, data)
			continue
		var msg := decode(data)
		if not msg.is_empty():
			received.emit(from, ch, msg)
	if peer == null or is_server:
		return
	var st := peer.get_connection_status()
	if st == MultiplayerPeer.CONNECTION_DISCONNECTED and _was != MultiplayerPeer.CONNECTION_DISCONNECTED:
		close()                                          # closed first: the handler may well start a new connection
		failed.emit()
	elif st == MultiplayerPeer.CONNECTION_CONNECTING and Time.get_ticks_msec() - _started_ms > CONNECT_TIMEOUT_MS:
		close()
		failed.emit()


## Bytes -> a message dictionary with a text "t", or {} for anything else (objects, other types, damaged data).
static func decode(data: PackedByteArray) -> Dictionary:
	if data.size() < 4:                              # shorter than any encoded value
		return {}
	var v: Variant = bytes_to_var(data)             # without objects: a packet cannot smuggle a script in
	if v is Dictionary and (v as Dictionary).get("t") is String:
		return v
	return {}
