extends Node
## Finding a session on the network: the owner's beacon, the listener's list, and what is not believed.

var t := TestCase.new("lan_discovery")


func _ready() -> void:
	var owner := LanDiscovery.new()
	var guest := LanDiscovery.new()
	owner.target = "127.0.0.1"                # the test machine's own loopback, so that it works on any network
	t.check(guest.listen(), "a guest starts listening")
	t.check(not owner.announcing(), "nothing is announced yet")
	owner.announce({"id": "s1", "name": "Sprint review", "host": "Ortiz", "doc": "Floor plan", "port": 8190, "pin": true, "locked": false, "n": 3})
	t.check(owner.announcing(), "the owner announces")
	await run_for(owner, guest, 1.3)
	var list := guest.sessions()
	t.eq(list.size(), 1, "the guest sees one session")
	if list.size() == 1:
		var c: Dictionary = list[0]
		t.eq(c.name, "Sprint review", "its name")
		t.eq(c.host, "Ortiz", "its owner")
		t.eq(c.doc, "Floor plan", "its document")
		t.eq(c.port, 8190, "its port")
		t.eq(c.address, "127.0.0.1", "the address is the one the beacon came from, not one the beacon claims")
		t.check(c.pin and not c.locked and c.n == 3, "needs a code, is open, three people")
	# the beacon changes as the session does
	owner.update_info({"id": "s1", "name": "Sprint review", "host": "Ortiz", "doc": "Floor plan", "port": 8190, "pin": true, "locked": true, "n": 5})
	await run_for(owner, guest, 1.2)
	t.check(guest.sessions()[0].locked and guest.sessions()[0].n == 5, "the list follows: locked, five people")
	t.eq(guest.sessions().size(), 1, "...still one entry")
	# nothing is heard from the beacon any more: off the list
	owner.stop_announcing()
	guest.expire_s = 1.0
	await run_for(owner, guest, 1.5)
	t.eq(guest.sessions().size(), 0, "a session that stopped announcing leaves the list")
	guest.stop_listening()
	# its own beacon is not offered back
	var both := LanDiscovery.new()
	both.target = "127.0.0.1"
	both.own_id = "me"
	var other := LanDiscovery.new()
	other.listen()
	other.expire_s = 3.0
	both.announce({"id": "me", "name": "Mine", "host": "Me", "doc": "d", "port": 8190})
	await run_for(both, other, 1.2)
	t.eq(other.sessions().size(), 1, "another listener hears it")
	other.own_id = "me"
	other.found.clear()
	await run_for(both, other, 1.2)
	t.eq(other.sessions().size(), 0, "a headset does not list its own session")
	both.stop_announcing()
	# nonsense on the port is not believed
	var junk := PacketPeerUDP.new()
	junk.set_dest_address("127.0.0.1", LanDiscovery.PORT)
	for payload in ["", "hello", "{}", "[1,2]", "{\"m\":\"other\",\"v\":1,\"port\":9000}", "{\"m\":\"mrw-session\",\"v\":99,\"port\":9000}", "{\"m\":\"mrw-session\",\"v\":1,\"port\":80}", "{\"m\":\"mrw-session\",\"v\":1,\"port\":70000}"]:
		junk.put_packet(payload.to_utf8_buffer())
	var long_name := "x".repeat(1100)
	junk.put_packet(("{\"m\":\"mrw-session\",\"v\":1,\"id\":\"z\",\"port\":9100,\"session\":\"" + long_name + "\"}").to_utf8_buffer())
	other.own_id = ""
	await run_for(both, other, 0.4)
	t.eq(other.sessions().size(), 0, "wrong magic, version or port are ignored (and an over-long packet is too)")
	junk.put_packet(("{\"m\":\"mrw-session\",\"v\":1,\"id\":\"z\",\"port\":9100,\"session\":\"" + "y".repeat(300) + "\"}").to_utf8_buffer())
	await run_for(both, other, 0.4)
	t.eq(other.sessions().size(), 1, "a long name in a small packet is listed")
	if other.sessions().size() == 1:
		t.check(String(other.sessions()[0].name).length() <= LanDiscovery.MAX_TEXT, "...cut to a sensible length")
	junk.close()
	# broadcast destinations include the all-ones address and local networks
	var d := LanDiscovery.new().destinations()
	t.check(d.has("255.255.255.255"), "beacons go to everyone")
	for a in d:
		t.check(String(a).ends_with(".255"), "...and to each network's broadcast address (%s)" % a)
	# two listeners on one machine: the second cannot bind, which must be survivable
	var second := LanDiscovery.new()
	var shared := second.listen()
	print("  (a second listener on the same port: %s)" % ("shares it" if shared else "is refused"))
	t.check(typeof(shared) == TYPE_BOOL, "a second listener on the same port gets a plain yes or no, and the caller can fall back to a typed address")
	second.stop_listening()
	other.stop_listening()
	get_tree().quit(t.done())


func run_for(a: LanDiscovery, b: LanDiscovery, seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	var last := Time.get_ticks_msec()
	while Time.get_ticks_msec() < end:
		var now := Time.get_ticks_msec()
		var dt := float(now - last) / 1000.0
		last = now
		a.update(dt)
		b.update(dt)
		await get_tree().process_frame
