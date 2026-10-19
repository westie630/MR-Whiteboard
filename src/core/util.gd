class_name U
extends RefCounted
## Small shared helpers: ids, packing of point arrays, colour and transform (de)serialisation.

static var _rng := RandomNumberGenerator.new()


static func uid(prefix: String = "") -> String:
	if _rng.seed == 0 or _rng.state == 0:
		_rng.randomize()
	return "%s%08x%04x" % [prefix, _rng.randi(), _rng.randi() & 0xFFFF]


## Packed float array -> base64 (float32 little endian). Used for stroke points: far faster to parse than JSON number lists.
static func pack_floats(a: PackedFloat32Array) -> String:
	return Marshalls.raw_to_base64(a.to_byte_array())


static func unpack_floats(s: String) -> PackedFloat32Array:
	if s == "":
		return PackedFloat32Array()
	return Marshalls.base64_to_raw(s).to_float32_array()


static func color_to_str(c: Color) -> String:
	return "#" + c.to_html(true)


static func color_from(v: Variant, fallback: Color = Color.WHITE) -> Color:
	if v is Color:
		return v
	if v is String and (v as String) != "":
		return Color.html(v)
	return fallback


static func xf_to_array(t: Transform3D) -> Array:
	var b := t.basis
	return [snappedf(b.x.x, 1e-5), snappedf(b.x.y, 1e-5), snappedf(b.x.z, 1e-5),
		snappedf(b.y.x, 1e-5), snappedf(b.y.y, 1e-5), snappedf(b.y.z, 1e-5),
		snappedf(b.z.x, 1e-5), snappedf(b.z.y, 1e-5), snappedf(b.z.z, 1e-5),
		snappedf(t.origin.x, 1e-5), snappedf(t.origin.y, 1e-5), snappedf(t.origin.z, 1e-5)]


static func xf_from_array(a: Variant) -> Transform3D:
	if not (a is Array) or (a as Array).size() < 12:
		return Transform3D.IDENTITY
	var f: Array = a
	return Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]), Vector3(f[6], f[7], f[8])), Vector3(f[9], f[10], f[11]))


static func v2_to_array(v: Vector2) -> Array:
	return [snappedf(v.x, 1e-5), snappedf(v.y, 1e-5)]


static func v2_from(a: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if a is Array and (a as Array).size() >= 2:
		return Vector2(a[0], a[1])
	return fallback


## Remove the yaw (turn about world up) of a transform's basis from a node's pose: used to keep canvases standing upright.
static func yaw_of(b: Basis) -> float:
	var f := -b.z
	return atan2(-f.x, -f.z)
