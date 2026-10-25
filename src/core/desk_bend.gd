class_name DeskBend
extends RefCounted
## The curved desk: a canvas whose surface lies flat on the desk in front of you, bends up through a quarter circle at a set distance and
## then climbs the wall straight up. The canvas itself stays an ordinary flat page (everything drawn on it keeps its canvas coordinates
## and sizes); the surface is like a sheet of paper curved round a cylinder, so lengths along it do not change and a drawing is never
## stretched. Only where a point of the page appears in the room depends on the bend.
##
##   canvas (x, y)      the page: x to the right, y away from you, z the height above the surface (0 = on it)
##   surface (u, s, h)  the page as it lies on the surface: u = x + pan.x, s = y + pan.y, the distance run along the surface from your
##                      edge. Moving the contents away from you is changing `pan`: the page slides along the fixed surface
##   node (x, y, z)     the frame's own space, in which the surface stands: your edge at y = 0 on the desk, z up
##
## The surface in node space, by s: s <= at flat on the desk | then a quarter circle of `radius` round the axis (y = at, z = radius), its
## concave side to you | then straight up the wall at y = at + radius. The vertex shaders (bend.gdshaderinc) do the same mapping; the two
## must agree. The window is the part of the surface that is shown (surface coordinates): what slides outside it is hidden.

const PITCH := 0.008                       # geometry is cut into strips this tall (canvas metres) so a vertex shader can bend it
const MIN_AT := 0.05
const MAX_AT := 1.2
const MIN_RADIUS := 0.04
const MAX_RADIUS := 0.6
const DEFAULT_AT := 0.4
const DEFAULT_RADIUS := 0.12
const DEFAULT_SIZE := Vector2(1.0, 1.5)    # the window of a new curved desk: wide, and long enough for the desk, the bend and the wall
const SCREEN_SHADER := "res://shaders/ink_overlay.gdshader"
const EPS := 1e-6                          # a vertex this close to a cutting line is on it (a micron: vertices are 32-bit floats)
const MAX_PIECES := 20000                  # no one triangle is cut into more pieces than this
const FAR := 6.0                           # the frame is never culled by its own (unbent) bounds: a bent surface lies far from them

var at := DEFAULT_AT                       # surface distance from your edge where the flat part ends
var radius := DEFAULT_RADIUS
var pan := Vector2.ZERO                    # canvas -> surface offset
var window := Rect2(Vector2(-0.5, 0.0), DEFAULT_SIZE)   # the shown part of the surface

var _variants := {}                        # source material instance id -> the copy with this bend's uniforms


func _init(at_: float = DEFAULT_AT, radius_: float = DEFAULT_RADIUS, pan_: Vector2 = Vector2.ZERO, win: Rect2 = Rect2(Vector2(-0.5, 0.0), DEFAULT_SIZE)) -> void:
	set_params(at_, radius_, pan_, win)


static func clamp_at(v: float) -> float:
	return clampf(v, MIN_AT, MAX_AT)


static func clamp_radius(v: float) -> float:
	return clampf(v, MIN_RADIUS, MAX_RADIUS)


func set_params(at_: float, radius_: float, pan_: Vector2, win: Rect2) -> void:
	at = clamp_at(at_)
	radius = clamp_radius(radius_)
	pan = pan_
	window = win
	sync()


## The length of the quarter circle.
func arc() -> float:
	return PI * 0.5 * radius


## Where the wall starts (surface distance).
func wall_at() -> float:
	return at + arc()


## The part of the canvas (canvas coordinates) that is shown.
func canvas_window() -> Rect2:
	return Rect2(window.position - pan, window.size)


# ------------------------------------------------------------------------------------------------ the mapping

## Node-space position of surface point (u, s) lifted `h` off the surface towards you.
func surface_to_node(u: float, s: float, h: float = 0.0) -> Vector3:
	if s <= at:
		return Vector3(u, s, h)
	var l := arc()
	if s <= at + l:
		var p := (s - at) / radius
		return Vector3(u, at + (radius - h) * sin(p), radius - (radius - h) * cos(p))
	return Vector3(u, at + radius - h, radius + (s - at - l))


## Node-space position of a canvas point (x, y, height).
func to_node(c: Vector3) -> Vector3:
	return surface_to_node(c.x + pan.x, c.y + pan.y, c.z)


## Surface coordinates (u, s, h) of a node-space point: h is the signed distance off the surface (positive towards you).
func node_to_surface(p: Vector3) -> Vector3:
	if p.y <= at:
		return Vector3(p.x, p.y, p.z)
	if p.z >= radius:
		return Vector3(p.x, at + arc() + (p.z - radius), at + radius - p.y)
	var vy := p.y - at
	var vz := p.z - radius
	var rho := sqrt(vy * vy + vz * vz)
	var phi := atan2(vy, -vz)
	return Vector3(p.x, at + radius * phi, radius - rho)


## Canvas coordinates (x, y, height) of a node-space point.
func from_node(p: Vector3) -> Vector3:
	var s := node_to_surface(p)
	return Vector3(s.x - pan.x, s.y - pan.y, s.z)


## The direction along the surface (away from you) at surface distance s, in node space.
func tangent_at(s: float) -> Vector3:
	if s <= at:
		return Vector3(0, 1, 0)
	if s <= at + arc():
		var p := (s - at) / radius
		return Vector3(0, cos(p), sin(p))
	return Vector3(0, 0, 1)


## The direction off the surface, towards you.
func normal_at(s: float) -> Vector3:
	if s <= at:
		return Vector3(0, 0, 1)
	if s <= at + arc():
		var p := (s - at) / radius
		return Vector3(0, -sin(p), cos(p))
	return Vector3(0, -1, 0)


## The frame a thing standing on the surface at canvas point (x, y) has, in node space: x along u, y along the surface, z off it.
func frame_at(c: Vector2, lift: float = 0.0) -> Transform3D:
	var s := c.y + pan.y
	var n := normal_at(s)
	var t := tangent_at(s)
	return Transform3D(Basis(Vector3(1, 0, 0), t, n), to_node(Vector3(c.x, c.y, lift)))


## The first place a node-space ray meets the surface at or after distance `tmin`: {t, canvas: Vector3 (x, y, 0), surface: Vector3}, or {}.
## The ray may come from either side; the surface is the concave sheet only (flat, quarter circle, wall).
func ray(o: Vector3, d: Vector3, tmin: float = 0.0) -> Dictionary:
	var best_t := INF
	var best_s := 0.0
	# the desk
	if absf(d.z) > 1e-6:
		var t := -o.z / d.z
		if t >= tmin and t < best_t and o.y + d.y * t <= at:
			best_t = t
			best_s = o.y + d.y * t
	# the wall
	if absf(d.y) > 1e-6:
		var t2 := (at + radius - o.y) / d.y
		if t2 >= tmin and t2 < best_t and o.z + d.z * t2 >= radius:
			best_t = t2
			best_s = at + arc() + (o.z + d.z * t2 - radius)
	# the quarter circle
	var oy := o.y - at
	var oz := o.z - radius
	var a := d.y * d.y + d.z * d.z
	if a > 1e-12:
		var b := 2.0 * (d.y * oy + d.z * oz)
		var c := oy * oy + oz * oz - radius * radius
		var disc := b * b - 4.0 * a * c
		if disc >= 0.0:
			var sq := sqrt(disc)
			for t3 in [(-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a)]:
				if t3 >= tmin and t3 < best_t:
					var py: float = oy + d.y * t3
					var pz: float = oz + d.z * t3
					if py >= 0.0 and pz <= 0.0:
						best_t = t3
						best_s = at + radius * atan2(py, -pz)
	if best_t == INF:
		return {}
	var u := o.x + d.x * best_t
	return {"t": best_t, "canvas": Vector3(u - pan.x, best_s - pan.y, 0.0), "surface": Vector3(u, best_s, 0.0)}


# ------------------------------------------------------------------------------------------------ cutting geometry

## Cut triangles (arrays as ArrayMesh takes them: vertex, uv, colour, index) wherever they cross a line y = k * PITCH, so that each piece is
## short enough for a vertex shader to bend it without cutting a corner. Every attribute is interpolated; arrays without a triangle that
## crosses are returned as they are.
static func slice(arrays: Array) -> Array:
	if arrays.is_empty():
		return arrays
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var n := idx.size() / 3
	var crossing := PackedInt32Array()
	var broken := {}                                   # triangles with a corner that is not a number: dropped, they could not be cut
	for t in n:
		var y0 := verts[idx[t * 3]].y
		var y1 := verts[idx[t * 3 + 1]].y
		var y2 := verts[idx[t * 3 + 2]].y
		if not is_finite(y0 + y1 + y2):
			broken[t] = true
		elif floorf((minf(y0, minf(y1, y2)) + EPS) / PITCH) < floorf((maxf(y0, maxf(y1, y2)) - EPS) / PITCH):
			crossing.append(t)
	if crossing.is_empty() and broken.is_empty():
		return arrays
	verts = verts.duplicate()                          # (the caller's arrays are left as they were)
	var uvs: PackedVector2Array = (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).duplicate()
	var cols: PackedColorArray = (arrays[Mesh.ARRAY_COLOR] as PackedColorArray).duplicate()
	var out_idx := PackedInt32Array()
	var is_cut := {}
	for t in crossing:
		is_cut[t] = true
	for t in n:
		if not is_cut.has(t) and not broken.has(t):
			out_idx.append_array(PackedInt32Array([idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]]))
	for t in crossing:
		var stack: Array = [[idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]]]
		var guard := 0
		while not stack.is_empty():
			guard += 1
			if guard > MAX_PIECES:
				break                                  # (cannot happen; but a hang in a frame would be worse than a gap in a mesh)
			var tri: Array = stack.pop_back()
			var ia: int = tri[0]
			var ib: int = tri[1]
			var ic: int = tri[2]
			var ya := verts[ia].y
			var yb := verts[ib].y
			var yc := verts[ic].y
			var lo := floorf((minf(ya, minf(yb, yc)) + EPS) / PITCH)
			var hi := floorf((maxf(ya, maxf(yb, yc)) - EPS) / PITCH)
			if lo >= hi:
				out_idx.append_array(PackedInt32Array([ia, ib, ic]))
				continue
			var cut := (lo + 1.0) * PITCH
			var below := [ya < cut - EPS * 0.5, yb < cut - EPS * 0.5, yc < cut - EPS * 0.5]
			var nb := int(below[0]) + int(below[1]) + int(below[2])
			var corner: Array = [ia, ib, ic]
			# rotate so that `a` is the corner alone on its side of the line, keeping the winding
			var lone := 0
			if nb == 1:
				lone = below.find(true)
			else:
				lone = below.find(false)
			var a: int = corner[lone]
			var b: int = corner[(lone + 1) % 3]
			var c: int = corner[(lone + 2) % 3]
			var ab := _lerp_vertex(verts, uvs, cols, a, b, cut)
			var ac := _lerp_vertex(verts, uvs, cols, a, c, cut)
			stack.append([a, ab, ac])
			stack.append([ab, b, c])
			stack.append([ab, c, ac])
	var res := arrays.duplicate()
	res[Mesh.ARRAY_VERTEX] = verts
	res[Mesh.ARRAY_TEX_UV] = uvs
	res[Mesh.ARRAY_COLOR] = cols
	res[Mesh.ARRAY_INDEX] = out_idx
	return res


## A new vertex on the edge a-b at height y (appended to the arrays); the index of a or b itself when the edge lies on that height.
static func _lerp_vertex(verts: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, a: int, b: int, y: float) -> int:
	var va := verts[a]
	var vb := verts[b]
	var dy := vb.y - va.y
	if absf(dy) < 1e-12:
		return a
	var k := clampf((y - va.y) / dy, 0.0, 1.0)
	var v := va.lerp(vb, k)
	v.y = y
	verts.append(v)
	uvs.append(uvs[a].lerp(uvs[b], k))
	cols.append(cols[a].lerp(cols[b], k))
	return verts.size() - 1


# ------------------------------------------------------------------------------------------------ materials

## The material to show `src` (an ink / grid ShaderMaterial) with on this bend: a copy of it with the bend's uniforms, made once.
func material(src: Material) -> Material:
	if not src is ShaderMaterial:
		return src
	var key := src.get_instance_id()
	if not _variants.has(key):
		var m := (src as ShaderMaterial).duplicate() as ShaderMaterial
		_variants[key] = m
		apply(m)
	return _variants[key]


## The material of the overlay (selection, handles, markers): ink that is never hidden by the depth of anything in front of it.
func overlay_material() -> Material:
	var key := -1
	if not _variants.has(key):
		var m := ShaderMaterial.new()
		m.shader = load(SCREEN_SHADER)
		m.set_shader_parameter("style", 0)
		m.render_priority = 120
		_variants[key] = m
		apply(m)
	return _variants[key]


## Put this bend into a material's uniforms.
func apply(m: ShaderMaterial) -> void:
	m.set_shader_parameter("bend_a", Vector4(1.0, at, radius, 0.0))
	m.set_shader_parameter("bend_pan", pan)
	m.set_shader_parameter("bend_win", Vector4(window.position.x, window.position.y, window.end.x, window.end.y))


## The numbers changed: every material made for this bend follows.
func sync() -> void:
	for m in _variants.values():
		apply(m as ShaderMaterial)
