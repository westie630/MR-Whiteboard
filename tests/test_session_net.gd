extends Node
## The wire between headsets, over a real local connection: a server and two clients, the three channels (a big document on one never
## holds up a small message on another), and what happens to damaged packets and to a client that goes away.

var t := TestCase.new("session_net")
var server := SessionNet.new()
var c1 := SessionNet.new()
var c2 := SessionNet.new()
var log_server: Array = []                 # [from, channel, msg]
var log_c1: Array = []
var log_c2: Array = []
var live_server: Array = []
var live_c1: Array = []
var joined: Array = []
var left: Array = []
var c1_connected := false
var c1_failed := false


func _ready() -> void:
	server.received.connect(func(from, ch, msg): log_server.append([from, ch, msg]))
	c1.received.connect(func(from, ch, msg): log_c1.append([from, ch, msg]))
	c2.received.connect(func(from, ch, msg): log_c2.append([from, ch, msg]))
	server.received_live.connect(func(from, bytes): live_server.append([from, bytes]))
	c1.received_live.connect(func(from, bytes): live_c1.append([from, bytes]))
	server.peer_joined.connect(func(id): joined.append(id))
	server.peer_left.connect(func(id): left.append(id))
	c1.connected.connect(func(): c1_connected = true)
	c1.failed.connect(func(): c1_failed = true)
	await run()
	server.close()
	c1.close()
	c2.close()
	get_tree().quit(t.done())


func pump(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		server.poll()
		c1.poll()
		c2.poll()
		await get_tree().process_frame


func until(cond: Callable, seconds: float = 4.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		server.poll()
		c1.poll()
		c2.poll()
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func run() -> void:
	t.eq(server.host(18400, 8), OK, "the server listens")
	t.check(server.port >= 18400 and server.is_server, "on a port of its own")
	# a second server on the same port takes the next free one
	var other := SessionNet.new()
	t.eq(other.host(server.port, 4), OK, "a second server finds the next free port")
	t.check(other.port != server.port, "...a different one (%d, %d)" % [server.port, other.port])
	other.close()

	t.eq(c1.join("127.0.0.1", server.port), OK, "a client starts connecting")
	t.check(await until(func(): return c1_connected), "the client is connected")
	t.check(c1.is_connected_to_server(), "and knows it")
	t.check(await until(func(): return joined.size() == 1), "the server sees it join")
	var id1: int = joined[0]
	t.check(id1 > 1 and c1.my_id() == id1, "the id the server gave is the id the client has (%d)" % id1)
	t.eq(server.my_id(), 1, "the server is always 1")
	t.check(server.address_of(id1).begins_with("127.") or server.address_of(id1) != "", "the server can tell where it calls from (%s)" % server.address_of(id1))

	# messages both ways, structured data intact
	c1.send(SessionNet.SERVER, {"t": "hello", "name": "Ana", "xf": Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3)), "list": [1, 2.5, "x"]})
	t.check(await until(func(): return log_server.size() == 1), "a message reaches the server")
	var got: Dictionary = log_server[0][2]
	t.eq(log_server[0][0], id1, "it says who it is from")
	t.eq(log_server[0][1], SessionNet.CH_CONTROL, "on the control channel")
	t.eq(got.name, "Ana", "text arrives")
	t.check((got.xf as Transform3D).is_equal_approx(Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3))), "a pose arrives")
	server.send(id1, {"t": "welcome", "you": id1})
	t.check(await until(func(): return log_c1.size() == 1), "and back")
	t.eq(log_c1[0][2].t, "welcome", "the answer")

	# a second client; broadcast and "all but"
	t.eq(c2.join("127.0.0.1", server.port), OK, "a second client")
	t.check(await until(func(): return joined.size() == 2), "joins")
	var id2: int = joined[1]
	server.send(0, {"t": "roster", "n": 2})
	t.check(await until(func(): return log_c1.size() == 2 and log_c2.size() == 1), "a broadcast reaches both")
	server.send(-id1, {"t": "edit", "who": "owner"})
	t.check(await until(func(): return log_c2.size() == 2), "'all but' reaches the others")
	await pump(0.3)
	t.eq(log_c1.size(), 2, "...and not the one left out")

	# a big message on the data channel does not hold up the control channel
	var big := PackedByteArray()
	big.resize(4 * 1024 * 1024)
	for i in range(0, big.size(), 4093):
		big[i] = i % 253
	log_c2.clear()
	server.send(id2, {"t": "snap", "bytes": big}, SessionNet.CH_DATA)
	server.send(id2, {"t": "kick-check"}, SessionNet.CH_CONTROL)
	var t0 := Time.get_ticks_msec()
	t.check(await until(func(): return log_c2.any(func(e): return e[2].t == "kick-check")), "a small control message gets through...")
	var small_ms := Time.get_ticks_msec() - t0
	var big_in_by_then := log_c2.any(func(e): return e[2].t == "snap")
	t.check(await until(func(): return log_c2.any(func(e): return e[2].t == "snap"), 15.0), "...and the big document arrives too")
	var snap_entry: Array = log_c2.filter(func(e): return e[2].t == "snap")[0]
	t.eq(snap_entry[1], SessionNet.CH_DATA, "on the data channel")
	t.check((snap_entry[2].bytes as PackedByteArray) == big, "intact (%d bytes)" % big.size())
	print("  (control message after %d ms; the 4 MB document was %s by then)" % [small_ms, "already in" if big_in_by_then else "still on its way"])

	# the live channel (reliable, but a channel of its own)
	for i in 20:
		c1.send_live(SessionNet.SERVER, PackedByteArray([1, 2, 3, i]))
		server.send_live(0, PackedByteArray([9, i]))
		await pump(0.03)
	await pump(0.3)
	t.eq(live_server.size(), 20, "live packets all arrive")
	t.eq(live_c1.size(), 20, "...to the clients too")
	t.eq(live_server[0][0], id1, "with the sender")
	t.eq((live_server[19][1] as PackedByteArray)[3], 19, "in order")

	# damaged and foreign packets are dropped before anybody sees them
	log_server.clear()
	var raw := ENetMultiplayerPeer.new()                 # a third party that talks nonsense on the control channel
	t.eq(raw.create_client("127.0.0.1", server.port, SessionNet.CHANNELS), OK, "a stranger connects")
	var end := Time.get_ticks_msec() + 3000
	while raw.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() < end:
		raw.poll()
		server.poll()
		await get_tree().process_frame
	for junk in [PackedByteArray([0xff, 0xfe, 0x01]), var_to_bytes([1, 2, 3]), var_to_bytes({"no_type": 1}), var_to_bytes({"t": 5}), var_to_bytes("hello")]:
		raw.set_target_peer(1)
		raw.set_transfer_channel(0)
		raw.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		raw.put_packet(junk)
	raw.set_target_peer(1)
	raw.put_packet(var_to_bytes({"t": "real"}))
	await pump(0.4)
	raw.poll()
	t.eq(log_server.size(), 1, "only the one well-formed message gets through")
	if log_server.size() == 1:
		t.eq(log_server[0][2].t, "real", "...the real one")
	t.eq(SessionNet.decode(var_to_bytes({"t": "x", "o": null})).t, "x", "null values are fine")
	raw.close()
	await pump(0.3)

	# leaving
	left.clear()
	c2.close()
	t.check(await until(func(): return left.has(id2)), "the server notices a client that goes away")
	server.kick(id1)
	t.check(await until(func(): return c1_failed), "a kicked client is told it lost the connection")
	t.check(await until(func(): return left.has(id1)), "and the server sees it gone")
	var lonely := SessionNet.new()
	var gone := [false]
	lonely.failed.connect(func(): gone[0] = true)
	lonely.join("127.0.0.1", 18999)                       # nobody there
	end = Time.get_ticks_msec() + 9000
	while not gone[0] and Time.get_ticks_msec() < end:
		lonely.poll()
		await get_tree().process_frame
	t.check(gone[0], "a client that finds nobody is told so")
	lonely.close()
