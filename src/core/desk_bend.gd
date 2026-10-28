class_name DeskBend
extends RefCounted
## The curved desk: a canvas whose surface lies flat on the desk in front of you, bends up through a quarter circle at a set distance and
## then climbs the wall straight up. The canvas itself stays an ordinary flat page (everything drawn on it keeps its canvas coordinates
## and sizes); the surface is like a sheet of paper curved round a cylinder, so lengths along it do not change and a drawing is never
## stretched. Only where a point of the page appears in the room depends on the bend.
##
##   canvas (x, y)      the page: x to the right, y away from you, z the height above the surface (0 = on it)
##   surface (u, s, h)  the page as it lies on the surface: u = x * zoom + pan.x, s = y * zoom + pan.y, the distance run along the surface
##                      from your edge. Moving the contents away from you is changing `pan`: the page slides along the fixed surface;
##                      `zoom` (the frame's scale) shows the page bigger or smaller on it, while the surface keeps its size
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
const FAR := 6.0                           # the frame is never culled by its own (unbent) bounds: a bent surface lies far from them
const MIN_ZOOM := 0.25                     # how much smaller / bigger the contents of a curved desk can be shown (the frame's scale)
const MAX_ZOOM := 4.0

var at := DEFAULT_AT                       # surface distance from your edge where the flat part ends
var radius := DEFAULT_RADIUS
var pan := Vector2.ZERO                    # canvas -> surface offset
var zoom := 1.0                            # canvas -> surface scale
var window := Rect2(Vector2(-0.5, 0.0), DEFAULT_SIZE)   # the shown part of the surface

var _variants := {}                        # source material instance id -> the copy with this bend's uniforms


func _init(at_: float = DEFAULT_AT, radius_: float = DEFAULT_RADIUS, pan_: Vector2 = Vector2.ZERO, win: Rect2 = Rect2(Vector2(-0.5, 0.0), DEFAULT_SIZE),
		zoom_: float = 1.0) -> void:
	set_params(at_, radius_, pan_, win, zoom_)


static func clamp_at(v: float) -> float:
	return clampf(v, MIN_AT, MAX_AT)


static func clamp_radius(v: float) -> float:
	return clampf(v, MIN_RADIUS, MAX_RADIUS)


static func clamp_zoom(v: float) -> float:
	return clampf(v, MIN_ZOOM, MAX_ZOOM) if is_finite(v) else 1.0


func set_params(at_: float, radius_: float, pan_: Vector2, win: Rect2, zoom_: float = 1.0) -> void:
	at = clamp_at(at_)
	radius = clamp_radius(radius_)
	pan = pan_
	window = win
	zoom = clamp_zoom(zoom_)
	sync()


## How tall (canvas metres) the strips are that geometry on this bend is cut into: PITCH, halved for a page shown more than twice its size,
## so that a strip never covers more than 2 x PITCH of the surface. Stepped, so that zooming rebuilds the geometry only when a step is passed.
func cut_pitch() -> float:
	return PITCH / pow(2.0, maxf(ceilf(log(zoom * 0.5) / log(2.0)), 0.0))


## The length of the quarter circle.
func arc() -> float:
	return PI * 0.5 * radius


## Where the wall starts (surface distance).
func wall_at() -> float:
	return at + arc()


## The part of the canvas (canvas coordinates) that is shown.
func canvas_window() -> Rect2:
	return Rect2((window.position - pan) / zoom, window.size / zoom)


## Surface coordinates (u, s) of a canvas point, and back.
func to_surface(c: Vector2) -> Vector2:
	return c * zoom + pan


func to_canvas(surf: Vector2) -> Vector2:
	return (surf - pan) / zoom


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
	return surface_to_node(c.x * zoom + pan.x, c.y * zoom + pan.y, c.z * zoom)


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
	return Vector3((s.x - pan.x) / zoom, (s.y - pan.y) / zoom, s.z / zoom)


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


## The frame a thing standing on the surface at canvas point (x, y) has, in node space: x along u, y along the surface, z off it (unit
## axes: a thing in metres; `lift` is in canvas metres).
func frame_at(c: Vector2, lift: float = 0.0) -> Transform3D:
	var sf := to_surface(c)
	return frame_at_surface(sf.x, sf.y, lift * zoom)


## The same at surface point (u, s), `lift` metres off it.
func frame_at_surface(u: float, s: float, lift: float = 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3(1, 0, 0), tangent_at(s), normal_at(s)), surface_to_node(u, s, lift))


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
	return {"t": best_t, "canvas": Vector3((u - pan.x) / zoom, (best_s - pan.y) / zoom, 0.0), "surface": Vector3(u, best_s, 0.0)}


# ------------------------------------------------------------------------------------------------ cutting geometry

## A line (points and widths, for StrokeMesher.ribbon_arrays) with points put in wherever it climbs more than a strip (`pitch`) between two
## of its points, so that its ribbon bends instead of cutting the corner. Cheap: this, not slice(), is how lines are made bendable (the
## overlay is drawn again every frame). Unchanged when no segment is that long. Returns [points, widths].
static func subdivide(pts: PackedVector3Array, widths: PackedFloat32Array, closed: bool = false, pitch: float = PITCH) -> Array:
	var n := pts.size()
	if n < 2:
		return [pts, widths]
	var segs := n if closed else n - 1
	var need := false
	for i in segs:
		if absf(pts[(i + 1) % n].y - pts[i].y) > pitch:
			need = true
			break
	if not need:
		return [pts, widths]
	var op := PackedVector3Array()
	var ow := PackedFloat32Array()
	var last := widths.size() - 1
	for i in n:
		var wi := widths[mini(i, last)]
		op.append(pts[i])
		ow.append(wi)
		if i < segs:
			var j := (i + 1) % n
			var k := ceili(absf(pts[j].y - pts[i].y) / pitch)
			var wj := widths[mini(j, last)]
			for m in range(1, k):
				var t := float(m) / float(k)
				op.append(pts[i].lerp(pts[j], t))
				ow.append(lerpf(wi, wj, t))
	return [op, ow]


## Cut triangles (arrays as ArrayMesh takes them: vertex, uv, colour, index) wherever they cross a line y = k * pitch, so that each piece is
## short enough for a vertex shader to bend it without cutting a corner. Every attribute is interpolated; arrays without a triangle that
## crosses are returned as they are.
static func slice(arrays: Array, pitch: float = PITCH) -> Array:
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
		elif floorf((minf(y0, minf(y1, y2)) + EPS) / pitch) < floorf((maxf(y0, maxf(y1, y2)) - EPS) / pitch):
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
	var poly := PackedInt32Array()
	for t in crossing:
		var i0 := idx[t * 3]
		var i1 := idx[t * 3 + 1]
		var i2 := idx[t * 3 + 2]
		var v0 := verts[i0]
		var facing := (verts[i1].x - v0.x) * (verts[i2].y - v0.y) - (verts[i1].y - v0.y) * (verts[i2].x - v0.x)
		# the corners from low to high: `a` - `c` is the long side, `a` - `b` - `c` the short one
		var a := i0
		var b := i1
		var c := i2
		if verts[b].y < verts[a].y:
			var sw := a
			a = b
			b = sw
		if verts[c].y < verts[b].y:
			var sw2 := b
			b = c
			c = sw2
		if verts[b].y < verts[a].y:
			var sw3 := a
			a = b
			b = sw3
		var yb := verts[b].y
		var yc := verts[c].y
		var lo := int(floorf((verts[a].y + EPS) / pitch))
		var hi := int(floorf((yc - EPS) / pitch))
		# one strip after the other, bottom up: each is the part of the triangle between two cutting lines, a convex polygon
		var prev_l := a
		var prev_s := a
		var prev_y := verts[a].y
		for k in range(lo + 1, hi + 2):
			var top := k > hi
			var y := yc if top else float(k) * pitch
			var l := c if top else _lerp_vertex(verts, uvs, cols, a, c, y)
			var sv := c
			if not top:
				sv = _lerp_vertex(verts, uvs, cols, a, b, y) if y <= yb else _lerp_vertex(verts, uvs, cols, b, c, y)
			poly.clear()
			poly.append(prev_l)
			poly.append(prev_s)
			if yb >= prev_y and (yb < y or top) and b != prev_s:
				poly.append(b)                                 # (also when it is level with the bottom or the top corner)
			poly.append(sv)
			poly.append(l)
			for j in range(1, poly.size() - 1):
				_emit(out_idx, verts, poly[0], poly[j], poly[j + 1], facing)
			prev_l = l
			prev_s = sv
			prev_y = y
	var res := arrays.duplicate()
	res[Mesh.ARRAY_VERTEX] = verts
	res[Mesh.ARRAY_TEX_UV] = uvs
	res[Mesh.ARRAY_COLOR] = cols
	res[Mesh.ARRAY_INDEX] = out_idx
	return res


## One triangle of a cut, turned to face the way the triangle it is cut from faced; nothing when it has no area.
static func _emit(out: PackedInt32Array, verts: PackedVector3Array, p: int, q: int, r: int, facing: float) -> void:
	var vp := verts[p]
	var cr := (verts[q].x - vp.x) * (verts[r].y - vp.y) - (verts[q].y - vp.y) * (verts[r].x - vp.x)
	if absf(cr) < 1e-14:
		return
	if (cr > 0.0) == (facing > 0.0):
		out.append(p)
		out.append(q)
		out.append(r)
	else:
		out.append(p)
		out.append(r)
		out.append(q)


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


## The material of geometry laid out in surface coordinates (the edge and the markers, which keep their size and place whatever the
## contents do): the overlay's, without the pan and the zoom.
func surface_material() -> Material:
	var key := -2
	if not _variants.has(key):
		var m := (overlay_material() as ShaderMaterial).duplicate() as ShaderMaterial
		_variants[key] = m
		apply(m)
	return _variants[key]


## The material of the overlay (selection, handles, markers): ink drawn after the canvas's contents, hidden only by what really stands in front
## of it (a model, a stroke in the air).
func overlay_material() -> Material:
	var key := -1
	if not _variants.has(key):
		var m := ShaderMaterial.new()
		m.shader = load(SCREEN_SHADER)
		m.set_shader_parameter("style", 0)
		m.render_priority = Brushes.OVERLAY_PRIORITY
		_variants[key] = m
		apply(m)
	return _variants[key]


## Put this bend into a material's uniforms.
func apply(m: ShaderMaterial) -> void:
	var on_surface: bool = _variants.get(-2) == m
	m.set_shader_parameter("bend_a", Vector4(1.0, at, radius, 1.0 if on_surface else zoom))
	m.set_shader_parameter("bend_pan", Vector2.ZERO if on_surface else pan)
	m.set_shader_parameter("bend_win", Vector4(window.position.x, window.position.y, window.end.x, window.end.y))


## The numbers changed: every material made for this bend follows.
func sync() -> void:
	for m in _variants.values():
		apply(m as ShaderMaterial)
