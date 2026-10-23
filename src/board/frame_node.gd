class_name FrameNode
extends Node3D
## The scene node of one frame. A canvas shows its fading grid, border and items on its xy plane; a 3D sketch shows its strokes
## and a small origin gizmo. The Board sets this node's transform from the frame's anchor / room pose.

const GRID_SHADER := "res://shaders/grid.gdshader"
const MARGIN := 0.12                       # content margin that keeps the grid around what has been drawn (infinite canvas feel)
const DESK_COLOR := UITheme.DESK
const AI_COLOR :=Color(0.72, 0.62, 1.0, 0.95)

var data: FrameData
var doc: Document
var views: Dictionary = {}                 # item id -> ItemView
var hover := 0.0                           # 0..1 how near a pen or hand is (the border and title fade in)
var is_canvas: bool:
	get:
		return data.kind == FrameData.CANVAS

var _items: Node3D
var _grid: MeshInstance3D
var _grid_mat: ShaderMaterial
var _overlay: MeshInstance3D
var _overlay_mesh := ArrayMesh.new()
var _title: Label3D
var _draw := OverlayDraw.new()
var _bounds := Rect2()
var _bounds_dirty := true
var _extra: Callable = Callable()          # extra overlay drawing (selection, handles, cursor) set by the Board
var _overlay_dirty := true
var _ai: Node3D                            # the AI assistant's suggestion layer (items not in the document), drawn over the canvas
var _ai_items: Array = []
var _ai_hidden: Array = []                 # ids of document items the suggestion replaces: hidden while it is shown
var _ai_marks: Array = []                  # [{rect, kind: new | removed}] outlines drawn in the overlay
var _ai_tag: Label3D


func setup(d: FrameData, document: Document) -> void:
	data = d
	doc = document
	name = d.id
	_items = Node3D.new()
	_items.name = "Items"
	add_child(_items)
	if is_canvas:
		_grid = MeshInstance3D.new()
		_grid.name = "Grid"
		_grid.mesh = QuadMesh.new()
		_grid_mat = ShaderMaterial.new()
		_grid_mat.shader = load(GRID_SHADER)
		_grid_mat.render_priority = -128
		_grid.material_override = _grid_mat
		_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_grid)
	_overlay = MeshInstance3D.new()
	_overlay.name = "Overlay"
	_overlay.mesh = _overlay_mesh
	_overlay.material_override = OverlayDraw.material()
	_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_overlay)
	_title = Label3D.new()
	_title.font = TextLayout.font()
	_title.font_size = 64
	_title.pixel_size = 0.032 / 64.0
	_title.shaded = false
	_title.no_depth_test = true
	_title.render_priority = 124
	_title.modulate = Color(0.85, 1.0, 1.0, 0.0)
	_title.outline_size = 0
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title.double_sided = true
	add_child(_title)
	_ai = Node3D.new()
	_ai.name = "AiLayer"
	_ai.position = Vector3(0, 0, 0.0006)
	add_child(_ai)
	_ai_tag = Label3D.new()
	_ai_tag.font = TextLayout.font(600)
	_ai_tag.font_size = 64
	_ai_tag.pixel_size = 0.024 / 64.0
	_ai_tag.shaded = false
	_ai_tag.no_depth_test = true
	_ai_tag.render_priority = 125
	_ai_tag.modulate = AI_COLOR
	_ai_tag.outline_size = 0
	_ai_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_ai_tag.double_sided = true
	_ai_tag.text = "AI suggestion: Accept or Discard above the canvas"
	_ai_tag.visible = false
	add_child(_ai_tag)
	for it in doc.items_of(d.id):
		add_view(it)
	apply_style()
	refresh_frame()


# ------------------------------------------------------------------------------------------------ items

func add_view(it: Item) -> ItemView:
	if views.has(it.id):
		(views[it.id] as ItemView).item = it
		(views[it.id] as ItemView).rebuild()
		_bounds_dirty = true
		return views[it.id]
	var v := ItemView.new()
	_items.add_child(v)
	v.setup(it, not is_canvas)
	v.visible = not _ai_hidden.has(it.id)
	views[it.id] = v
	_bounds_dirty = true
	return v


func remove_view(item_id: String) -> void:
	if views.has(item_id):
		(views[item_id] as ItemView).queue_free()
		views.erase(item_id)
		_bounds_dirty = true


func refresh_view(it: Item) -> void:
	if views.has(it.id):
		(views[it.id] as ItemView).item = it
		(views[it.id] as ItemView).rebuild()
	else:
		add_view(it)
	_bounds_dirty = true


func view_of(item_id: String) -> ItemView:
	return views.get(item_id)


## Add a node (live stroke, ghost) that lives in this frame's space.
func add_live(n: Node3D) -> void:
	_items.add_child(n)


# ------------------------------------------------------------------------------------------------ geometry

func content_bounds() -> Rect2:
	var r := Rect2()
	var first := true
	for it in doc.items_of(data.id):
		var b: Rect2 = (it as Item).bounds()
		r = b if first else r.merge(b)
		first = false
	return r if not first else Rect2(Vector2.ZERO, Vector2.ZERO)


## The extent of the canvas: the nominal rectangle, grown to hold everything drawn on it.
func bounds() -> Rect2:
	if _bounds_dirty:
		var nominal := Rect2(data.offset - data.size * 0.5, data.size)
		var cb := content_bounds()
		_bounds = nominal.merge(cb.grow(MARGIN)) if cb.size != Vector2.ZERO or cb.position != Vector2.ZERO else nominal
		for it in _ai_items:
			_bounds = _bounds.merge((it as Item).bounds().grow(MARGIN))
		_bounds_dirty = false
	return _bounds


func invalidate_bounds() -> void:
	_bounds_dirty = true
	refresh_frame()


## Local position (frame metres) of a world point.
func to_local_point(world: Vector3) -> Vector3:
	return global_transform.affine_inverse() * world


func to_world_point(local: Vector3) -> Vector3:
	return global_transform * local


# ------------------------------------------------------------------------------------------------ look

func apply_style() -> void:
	if not is_canvas:
		return
	var style := data.grid if data.grid != "" else str(App.val("grid"))
	var backing := data.backing if data.backing != "" else str(App.val("backing"))
	_grid_mat.set_shader_parameter("style", {"lines": 0, "dots": 1, "none": 2}.get(style, 0))
	_grid_mat.set_shader_parameter("minor", float(App.val("grid_minor")))
	_grid_mat.set_shader_parameter("focus_r", float(App.val("grid_focus")))
	var bc := Color(1, 1, 1, 0.0)
	match backing:
		"glass":
			bc = Color(0.55, 0.8, 1.0, 0.07)
		"dark":
			bc = Color(0.03, 0.04, 0.06, 0.78)
		"white":
			bc = Color(0.97, 0.97, 0.95, 0.94)
	_grid_mat.set_shader_parameter("backing", bc)
	var light := backing == "white"
	_grid_mat.set_shader_parameter("line_color", Color(0.2, 0.3, 0.45, 1.0) if light else Color(0.55, 0.9, 1.0, 1.0))
	_grid.visible = not (style == "none" and bc.a == 0.0)


## Update the shader inputs: where the pen / gaze is on the plane and how far away the viewer is.
func set_focus(local_focus: Vector3, view_alpha: float) -> void:
	if is_canvas:
		_grid_mat.set_shader_parameter("focus", local_focus)
		_grid_mat.set_shader_parameter("view_alpha", view_alpha)


func set_hover(h: float) -> void:
	if absf(h - hover) > 0.01:
		hover = h
		if is_canvas:
			_grid_mat.set_shader_parameter("hover", h)
		_overlay_dirty = true
	if is_canvas:
		_title.modulate.a = clampf((h - 0.15) * 1.6, 0.0, 1.0)
		_title.visible = _title.modulate.a > 0.02


## Rebuild what depends on the bounds: the grid quad, the title position and the overlay.
func refresh_frame() -> void:
	_title.text = data.name + ("   on the desk" if data.surface else "")
	if is_canvas:
		var b := bounds()
		(_grid.mesh as QuadMesh).size = b.size + Vector2(0.02, 0.02)
		(_grid.mesh as QuadMesh).center_offset = Vector3(b.get_center().x, b.get_center().y, 0.0)
		_grid_mat.set_shader_parameter("bounds", Vector4(b.position.x, b.position.y, b.end.x, b.end.y))
		_title.position = Vector3(b.position.x + 0.02, b.end.y + 0.035, 0.001)
	else:
		_title.position = Vector3(0.0, 0.12, 0.0)
		_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_dirty = true


func mark_overlay_dirty() -> void:
	_overlay_dirty = true


## Set the extra overlay drawing (selection, handles ...) - a Callable taking an OverlayDraw - and redraw.
func set_overlay(extra: Callable) -> void:
	_extra = extra
	_overlay_dirty = true


func _process(_delta: float) -> void:
	if _overlay_dirty:
		_overlay_dirty = false
		_redraw_overlay()


func _redraw_overlay() -> void:
	_draw.clear()
	if is_canvas:
		if data.surface:
			# a canvas on the desk keeps a thin amber edge: it is bound to that surface
			_draw.rect(bounds(), 0.0016, Color(DESK_COLOR.r, DESK_COLOR.g, DESK_COLOR.b, 0.3 + 0.45 * clampf(hover, 0.0, 1.0)))
		if hover > 0.05:
			var b := bounds()
			var a := clampf(hover, 0.0, 1.0)
			var rail := Color(0.65, 1.0, 0.95, 0.5 * a)
			if data.surface:
				rail = Color(DESK_COLOR.r, DESK_COLOR.g, DESK_COLOR.b, 0.6 * a)
			for c in [b.position, Vector2(b.end.x, b.position.y), b.end, Vector2(b.position.x, b.end.y)]:
				_draw.disc(c, 0.014, rail)
			_draw.disc(Vector2(b.get_center().x, b.position.y), 0.014, Color(rail.r, rail.g, rail.b, rail.a * 0.7))
	else:
		# origin gizmo: three short axes
		var r := 0.035
		_draw.z = 0.0
		_draw.segment(Vector2.ZERO, Vector2(r, 0), 0.003, Color(1, 0.4, 0.4, 0.6))
		_draw.segment(Vector2.ZERO, Vector2(0, r), 0.003, Color(0.4, 1, 0.5, 0.6))
		_draw.disc(Vector2.ZERO, 0.006, Color(1, 1, 1, 0.7))
		if hover > 0.05:
			var cb := content_bounds()
			if cb.size != Vector2.ZERO:
				_draw.rect(cb.grow(0.03), 0.002, Color(0.65, 1.0, 0.95, 0.4 * hover))
	_draw_ai_marks()
	if _extra.is_valid():
		_extra.call(_draw)
	_draw.build(_overlay_mesh)


# ------------------------------------------------------------------------------------------------ AI suggestion layer

## Show the AI assistant's suggestion over the canvas: `items` drawn as they would be, the document items in `hidden` (the ones the
## suggestion changes) hidden meanwhile, and `marks` outlined ({rect, kind: new | removed}). Empty lists clear it.
func show_ai(items: Array, hidden: Array, marks: Array) -> void:
	for c in _ai.get_children():
		c.queue_free()
	for id in _ai_hidden:
		if views.has(id):
			(views[id] as ItemView).visible = true
	_ai_items = items.duplicate()
	_ai_hidden = hidden.duplicate()
	_ai_marks = marks.duplicate()
	for it in _ai_items:
		var v := ItemView.new()
		_ai.add_child(v)
		v.setup(it, not is_canvas)
	for id in _ai_hidden:
		if views.has(id):
			(views[id] as ItemView).visible = false
	var r := Rect2()
	var first := true
	for m in _ai_marks:
		r = m.rect if first else r.merge(m.rect)
		first = false
	_ai_tag.visible = not first
	if not first:
		_ai_tag.position = Vector3(r.position.x, r.end.y + 0.045, 0.001)
	_bounds_dirty = true
	refresh_frame()


func ai_shown() -> bool:
	return not _ai_marks.is_empty()


func _draw_ai_marks() -> void:
	for m in _ai_marks:
		var r: Rect2 = (m.rect as Rect2).grow(0.012)
		if str(m.kind) == "removed":
			var red := Color(1.0, 0.36, 0.45, 0.85)
			_draw.rect(r, 0.003, red)
			_draw.segment(r.position, r.end, 0.003, red)
			_draw.segment(Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.position.y), 0.003, red)
		else:
			_draw.rect(r, 0.0022, Color(AI_COLOR.r, AI_COLOR.g, AI_COLOR.b, 0.55))
