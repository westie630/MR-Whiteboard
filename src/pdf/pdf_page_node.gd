class_name PdfPageNode
extends Node3D
## A prepared page (PdfPageData) standing in the scene: a white sheet and, on top of it in painting order, one mesh per layer. The page
## lies in the node's xy plane, its middle on the origin, `mpp` metres to a point. Text and drawing are triangles (so they stay sharp however
## near you come); pictures are textures with mipmaps.

const IMAGE_SHADER := "res://shaders/pdf_image.gdshader"
const MASKED_SHADER := "res://shaders/pdf_masked.gdshader"
const PRIORITY := -128                      # the lowest: the ink of every brush (-127 and up) and the interface draw over the page
const LAYER_DZ := 0.00002                   # metres between layers: among things of one priority the engine draws the farther first
const MAX_LAYERS := 100

var data: PdfPageData
var mpp := 0.001
var paper := Color(1, 1, 1, 1)

static var _variants: Dictionary = {}       # "shader path|blend" -> the shader with that blend mode (made from the plain one when first needed)

var _root: Node3D


## Puts the page in the scene (replacing what was shown). `metres_per_point` sets its size.
func show_page(d: PdfPageData, metres_per_point: float) -> void:
	clear()
	data = d
	mpp = metres_per_point
	_root = Node3D.new()
	_root.name = "Page"
	_root.scale = Vector3(mpp, mpp, 1.0)
	_root.position = Vector3(-d.size.x * 0.5 * mpp, -d.size.y * 0.5 * mpp, 0.0)
	add_child(_root)
	_add_paper(d.size)
	var i := 0
	for layer in d.layers:
		var mi := _layer_mesh(layer, PRIORITY)
		if mi != null:
			mi.position = Vector3(0, 0, -(MAX_LAYERS + 2 - mini(i + 1, MAX_LAYERS)) * LAYER_DZ)
			mi.sorting_use_aabb_center = false          # all layers have the same origin, so the order is the order of their depth offsets
			_root.add_child(mi)
		i += 1


## The page is made larger or smaller (the canvas was resized) without being built again.
func set_metres_per_point(metres_per_point: float) -> void:
	if data == null or _root == null or is_equal_approx(metres_per_point, mpp):
		return
	mpp = metres_per_point
	_root.scale = Vector3(mpp, mpp, 1.0)
	_root.position = Vector3(-data.size.x * 0.5 * mpp, -data.size.y * 0.5 * mpp, 0.0)


func clear() -> void:
	if _root != null:
		_root.queue_free()
		_root = null
	data = null


func size_m() -> Vector2:
	return data.size * mpp if data != null else Vector2.ZERO


func _add_paper(sz: Vector2) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Paper"
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2.ZERO, Vector2(sz.x, 0), sz, Vector2.ZERO, sz, Vector2(0, sz.y)])
	var c := PackedColorArray()
	c.resize(6)
	c.fill(paper)
	arrays[Mesh.ARRAY_COLOR] = c
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = mesh
	mi.material_override = _tri_material(PRIORITY, "")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0, 0, -(MAX_LAYERS + 2) * LAYER_DZ)
	mi.sorting_use_aabb_center = false
	_root.add_child(mi)


func _tri_material(priority: int, blend: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.render_priority = priority
	if blend == "Multiply":
		m.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	elif blend == "Screen":
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD                 # (lightening: adding is the nearest the graphics chip does without reading what is behind)
	return m


## The shader at `path` as it is for the blend mode: the plain one, or a copy of it whose render mode blends by multiplying (or, for Screen, adding).
static func _shader_for(path: String, blend: String) -> Shader:
	var base: Shader = load(path)
	if blend != "Multiply" and blend != "Screen":
		return base
	var key := path + "|" + blend
	if not _variants.has(key):
		var variant := Shader.new()
		variant.code = base.code.replace("blend_mix", "blend_mul" if blend == "Multiply" else "blend_add")
		_variants[key] = variant
	return _variants[key]


## Coloured triangles drawn through a soft mask.
func _masked_material(priority: int, mask: Dictionary, blend: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _shader_for(MASKED_SHADER, blend)
	mat.render_priority = priority
	_set_mask(mat, mask)
	return mat


static func _set_mask(mat: ShaderMaterial, mask: Dictionary) -> void:
	var r: Rect2 = mask.rect
	mat.set_shader_parameter("use_mask", true)
	mat.set_shader_parameter("mask_tex", ImageTexture.create_from_image(mask.image))
	mat.set_shader_parameter("mask_rect", Vector4(r.position.x, r.position.y, r.size.x, r.size.y))
	mat.set_shader_parameter("outside", float(mask.outside))


func _layer_mesh(layer: Dictionary, priority: int) -> MeshInstance3D:
	var verts: PackedVector2Array = layer.verts
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if layer.kind == "tris":
		arrays[Mesh.ARRAY_COLOR] = layer.cols
		if layer.has("mask"):
			mi.material_override = _masked_material(priority, layer.mask, str(layer.blend))
		else:
			mi.material_override = _tri_material(priority, str(layer.blend))
	else:
		arrays[Mesh.ARRAY_TEX_UV] = layer.uvs
		var mat := ShaderMaterial.new()
		mat.shader = _shader_for(IMAGE_SHADER, str(layer.get("blend", "")))
		mat.render_priority = priority
		var color: Image = layer.color
		var alpha: Image = layer.alpha
		mat.set_shader_parameter("use_color", color != null)
		if color != null:
			mat.set_shader_parameter("tex_color", ImageTexture.create_from_image(color))
		mat.set_shader_parameter("use_alpha", alpha != null)
		if alpha != null:
			mat.set_shader_parameter("tex_alpha", ImageTexture.create_from_image(alpha))
		mat.set_shader_parameter("fill", layer.fill)
		mat.set_shader_parameter("opacity", float(layer.opacity))
		if layer.has("soft"):
			_set_mask(mat, layer.soft)
		mi.material_override = mat
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = mesh
	return mi
