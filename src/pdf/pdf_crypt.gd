class_name PdfCrypt
extends RefCounted
## PDF's standard security handler, for documents that open without a password (the user password is empty: the ones that only
## restrict printing or copying). RC4 40 / 128 bit, AES-128 and AES-256 (revisions 2 to 6). A document that wants a password is refused.

const PAD := [0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
	0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A]

var key := PackedByteArray()
var stream_method := "RC4"                 # RC4 | AESV2 | AESV3 | Identity
var string_method := "RC4"
var v := 0
var r := 0
var ok := false
var error := ""


## `enc` is the (resolved) Encrypt dictionary, `id0` the first string of the trailer's ID array.
static func create(enc: Dictionary, id0: PackedByteArray) -> PdfCrypt:
	var c := PdfCrypt.new()
	if str(enc.get("Filter", "Standard")) != "Standard":
		c.error = "This PDF uses a security handler the viewer does not know."
		return c
	c.v = int(enc.get("V", 0))
	c.r = int(enc.get("R", 2))
	var o: PackedByteArray = enc.get("O", PackedByteArray())
	var u: PackedByteArray = enc.get("U", PackedByteArray())
	var p := int(enc.get("P", 0))
	var length := int(enc.get("Length", 40)) / 8
	var meta := bool(enc.get("EncryptMetadata", true))
	if c.v >= 4:
		var cf: Dictionary = enc.get("CF", {})
		c.stream_method = c._method(cf, str(enc.get("StmF", "Identity")))
		c.string_method = c._method(cf, str(enc.get("StrF", "Identity")))
		if c.v == 4:
			length = 16
	elif c.v == 1:
		length = 5
	if c.r >= 5:
		c._key_v5(enc, o, u)
		return c
	length = clampi(length, 5, 16)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(PackedByteArray(PAD))
	h.update(o.slice(0, 32))
	var pb := PackedByteArray()
	pb.resize(4)
	pb.encode_s32(0, p)
	h.update(pb)
	h.update(id0)
	if c.r >= 4 and not meta:
		h.update(PackedByteArray([255, 255, 255, 255]))
	var digest := h.finish()
	if c.r >= 3:
		for i in 50:
			var h2 := HashingContext.new()
			h2.start(HashingContext.HASH_MD5)
			h2.update(digest.slice(0, length))
			digest = h2.finish()
	c.key = digest.slice(0, length)
	# does the empty user password open it? (algorithm 6: compare with U)
	c.ok = c._check_user(u, id0)
	if not c.ok:
		c.error = "This PDF needs a password to open."
	return c


func _method(cf: Dictionary, name: String) -> String:
	if name == "Identity":
		return "Identity"
	var f: Variant = cf.get(name)
	if f is Dictionary:
		match str((f as Dictionary).get("CFM", "None")):
			"V2":
				return "RC4"
			"AESV2":
				return "AESV2"
			"AESV3":
				return "AESV3"
	return "Identity"


func _check_user(u: PackedByteArray, id0: PackedByteArray) -> bool:
	if r == 2:
		return rc4(key, PackedByteArray(PAD)) == u.slice(0, 32)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(PackedByteArray(PAD))
	h.update(id0)
	var d := h.finish()
	d = rc4(key, d)
	for i in range(1, 20):
		var k2 := PackedByteArray()
		for b in key:
			k2.append(b ^ i)
		d = rc4(k2, d)
	return d == u.slice(0, 16)


# ------------------------------------------------------------------------------------------------ AES-256 (revisions 5 and 6)

func _key_v5(enc: Dictionary, o: PackedByteArray, u: PackedByteArray) -> void:
	var ue: PackedByteArray = enc.get("UE", PackedByteArray())
	if u.size() < 48 or ue.size() < 32:
		error = "This PDF's security data is damaged."
		return
	var empty := PackedByteArray()
	var vsalt := u.slice(32, 40)
	var ksalt := u.slice(40, 48)
	var check := _hash_v5(empty, vsalt, PackedByteArray())
	if check != u.slice(0, 32):
		error = "This PDF needs a password to open."
		return
	var ik := _hash_v5(empty, ksalt, PackedByteArray())
	var aes := AESContext.new()
	var iv := PackedByteArray()
	iv.resize(16)
	aes.start(AESContext.MODE_CBC_DECRYPT, ik, iv)
	key = aes.update(ue.slice(0, 32))
	aes.finish()
	ok = key.size() == 32


func _sha(kind: int, data: PackedByteArray) -> PackedByteArray:
	if kind == 0:
		var h := HashingContext.new()
		h.start(HashingContext.HASH_SHA256)
		h.update(data)
		return h.finish()
	return PdfSha512.hash(data, kind == 1)          # 1 = SHA-384, 2 = SHA-512


func _hash_v5(password: PackedByteArray, salt: PackedByteArray, udata: PackedByteArray) -> PackedByteArray:
	var input := password + salt + udata
	var k := _sha(0, input)
	if r == 5:
		return k
	var round := 0
	while true:
		var k1 := password + k + udata
		var rep := PackedByteArray()
		for i in 64:
			rep.append_array(k1)
		var aes := AESContext.new()
		aes.start(AESContext.MODE_CBC_ENCRYPT, k.slice(0, 16), k.slice(16, 32))
		var e := aes.update(rep)
		aes.finish()
		var mod := 0
		for i in 16:
			mod += e[i]
		mod %= 3
		k = _sha(mod, e)
		round += 1
		if round >= 64 and e[e.size() - 1] <= round - 32:
			break
	return k.slice(0, 32)


# ------------------------------------------------------------------------------------------------ objects

func decrypt_stream(data: PackedByteArray, num: int, gen: int) -> PackedByteArray:
	return _apply(stream_method, data, num, gen)


func decrypt_string(data: PackedByteArray, num: int, gen: int) -> PackedByteArray:
	return _apply(string_method, data, num, gen)


func _apply(method: String, data: PackedByteArray, num: int, gen: int) -> PackedByteArray:
	match method:
		"Identity":
			return data
		"AESV3":
			return _aes(key, data)
		"AESV2":
			return _aes(_object_key(num, gen, true), data)
		_:
			return rc4(_object_key(num, gen, false), data)


func _object_key(num: int, gen: int, aes: bool) -> PackedByteArray:
	var s := key.duplicate()
	s.append(num & 255)
	s.append((num >> 8) & 255)
	s.append((num >> 16) & 255)
	s.append(gen & 255)
	s.append((gen >> 8) & 255)
	if aes:
		s.append_array(PackedByteArray([0x73, 0x41, 0x6C, 0x54]))
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(s)
	return h.finish().slice(0, mini(key.size() + 5, 16))


static func _aes(k: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	if data.size() < 32 or (data.size() % 16) != 0:
		if data.size() < 16:
			return PackedByteArray()
		data = data.slice(0, data.size() - (data.size() % 16))
		if data.size() < 32:
			return PackedByteArray()
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, k, data.slice(0, 16))
	var out := aes.update(data.slice(16))
	aes.finish()
	if out.is_empty():
		return out
	var pad := out[out.size() - 1]
	if pad >= 1 and pad <= 16 and pad <= out.size():
		out.resize(out.size() - pad)
	return out


static func rc4(k: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	var s := PackedByteArray()
	s.resize(256)
	for i in 256:
		s[i] = i
	var j := 0
	var kl := k.size()
	if kl == 0:
		return data
	for i in 256:
		j = (j + s[i] + k[i % kl]) & 255
		var t := s[i]
		s[i] = s[j]
		s[j] = t
	var out := PackedByteArray()
	out.resize(data.size())
	var a := 0
	var b := 0
	for n in data.size():
		a = (a + 1) & 255
		b = (b + s[a]) & 255
		var t2 := s[a]
		s[a] = s[b]
		s[b] = t2
		out[n] = data[n] ^ s[(s[a] + s[b]) & 255]
	return out
