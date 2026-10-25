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
var pdfs: PdfLibrary                       # where the PDF of a PDF canvas comes from (the Board sets it before setup)
var pdf_state := ""                        # "" not a PDF | loading | ready | missing (not on this headset) | failed
var pdf_note := ""                         # what the canvas says in place of a page that is not there
var views: Dictionary = {}                 # item id -> ItemView
var bend: DeskBend                         # the curved desk this canvas is (null for a flat canvas): see DeskBend
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
var _ghost: ItemView                       # the text being placed (Board.begin_place_text), drawn over the canvas but not part of it
var _ai_items: Array = []
var _ai_hidden: Array = []                 # ids of document items the suggestion replaces: hidden while it is shown
var _ai_marks: Array = []                  # [{rect, kind: new | removed}] outlines drawn in the overlay
var _ai_tag: Label3D
var _pdf: PdfPageNode
var _pdf_label: Label3D
var _pdf_key := ""                         # "id:page" of the page being shown or waited for
var _items_page := -1                      # the page whose drawings the item views are of
var _pdf_shown_size := Vector2.ZERO        # the page's size in points as it is shown
var _grid_key := ""                        # what the grid mesh was built for
var _bend_tag: Label3D                     # says the bend's numbers beside its marker while it is touched or moved
var _marker_hot := ""                      # the marker ("d" distance, "r" radius) the pointer is on or moving, "" none
var _marks: MeshInstance3D                 # a curved desk's edge and markers: a mesh of their own, drawn again only when they change (not with the cursor)
var _marks_mesh := ArrayMesh.new()
var _mdraw := OverlayDraw.new()
var _marks_key := ""


func setup(d: FrameData, document: Document) -> void:
	data = d
	doc = document
	name = d.id
	_items = Node3D.new()
	_items.name = "Items"
	add_child(_items)
	bend = _make_bend()
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
	_set_bend_nodes()
	_bend_tag = Label3D.new()
	_bend_tag.font = TextLayout.font(600)
	_bend_tag.font_size = 64
	_bend_tag.pixel_size = 0.026 / 64.0
	_bend_tag.shaded = false
	_bend_tag.no_depth_test = true
	_bend_tag.render_priority = 125
	_bend_tag.modulate = DESK_COLOR
	_bend_tag.outline_size = 0
	_bend_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_bend_tag.double_sided = true
	_bend_tag.visible = false
	add_child(_bend_tag)
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
	_pdf_label = Label3D.new()
	_pdf_label.font = TextLayout.font(500)
	_pdf_label.font_size = 64
	_pdf_label.pixel_size = 0.03 / 64.0
	_pdf_label.shaded = false
	_pdf_label.modulate = Color(0.25, 0.28, 0.35, 1.0)
	_pdf_label.outline_size = 0
	_pdf_label.double_sided = true
	_pdf_label.visible = false
	_pdf_label.position = Vector3(0, 0, 0.0005)
	add_child(_pdf_label)
	_items_page = doc.page_of(d.id)
	for it in doc.items_of(d.id):
		add_view(it)
	apply_style()
	refresh_frame()
	refresh_pdf()


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


## Does this item belong on what the canvas shows now? (On a PDF canvas, only the page being looked at has its drawings.)
func shows_item(it: Item) -> bool:
	return not data.is_pdf() or it.page == doc.page_of(data.id)


## The page turned: the drawings of the new page replace those of the old one.
func rebuild_items() -> void:
	for id in views.keys():
		(views[id] as ItemView).queue_free()
	views.clear()
	for it in doc.items_of(data.id):
		add_view(it)
	_bounds_dirty = true
	refresh_frame()


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


## The extent of the canvas: the nominal rectangle, grown to hold everything drawn on it. A curved desk is the part of the canvas
## that is on the shown part of the surface.
func bounds() -> Rect2:
	if bend != null:
		return bend.canvas_window()
	if _bounds_dirty:
		var nominal := Rect2(data.offset - data.size * 0.5, data.size)
		if data.is_pdf():
			nominal = nominal.merge(page_rect())
		var cb := content_bounds()
		_bounds = nominal.merge(cb.grow(MARGIN)) if cb.size != Vector2.ZERO or cb.position != Vector2.ZERO else nominal
		for it in _ai_items:
			_bounds = _bounds.merge((it as Item).bounds().grow(MARGIN))
		_bounds_dirty = false
	return _bounds


func invalidate_bounds() -> void:
	_bounds_dirty = true
	refresh_frame()


## Local position (canvas metres, z the height above the canvas) of a world point.
func to_local_point(world: Vector3) -> Vector3:
	var l := global_transform.affine_inverse() * world
	return bend.from_node(l) if bend != null else l


func to_world_point(local: Vector3) -> Vector3:
	return global_transform * (bend.to_node(local) if bend != null else local)


## Where a world ray first meets the canvas (the plane of a flat one, the bent surface of a curved desk) at or after distance `tmin`:
## {t, local (canvas coordinates, z = 0), point (world)}, or {} when it does not (a ray parallel to the plane, or pointing away).
func ray_hit(o: Vector3, d: Vector3, tmin: float = 0.0) -> Dictionary:
	var inv := global_transform.affine_inverse()
	var lo := inv * o
	var ld := inv.basis * d
	if bend != null:
		var h := bend.ray(lo, ld, tmin)
		if h.is_empty():
			return {}
		return {"t": float(h.t), "local": h.canvas, "point": o + d * float(h.t)}
	if absf(ld.z) < 1e-4:
		return {}
	var t := -lo.z / ld.z
	if t < tmin:
		return {}
	var lp := lo + ld * t
	return {"t": t, "local": Vector3(lp.x, lp.y, 0.0), "point": o + d * t}


## The pose in world space a thing standing on the canvas at `c` has: x to the right, y up the canvas, z out of it. `lift` is the height off it.
func world_frame_at(c: Vector2, lift: float = 0.0) -> Transform3D:
	if bend != null:
		return global_transform * bend.frame_at(c, lift)
	return global_transform * Transform3D(Basis.IDENTITY, Vector3(c.x, c.y, lift))


# ------------------------------------------------------------------------------------------------ curved desk

func _make_bend() -> DeskBend:
	if not (is_canvas and data.bend and not data.is_pdf()):
		return null
	return DeskBend.new(data.bend_at, data.bend_radius, data.bend_pan, data.bend_window())


## The frame's data changed: follow its bend (its numbers, or it being switched on or off).
func refresh_bend() -> void:
	var want := is_canvas and data.bend and not data.is_pdf()
	if want == (bend != null):
		if want:
			bend.set_params(data.bend_at, data.bend_radius, data.bend_pan, data.bend_window())
			_after_bend_moved()
		return
	bend = _make_bend()
	_grid_key = ""
	_rebuild_for_bend()


## The numbers of the bend as they are right now (a pointer is moving the contents or a marker, before it is let go and kept).
func set_bend_live(at: float, radius: float, pan: Vector2) -> void:
	if bend == null:
		return
	if is_equal_approx(bend.at, at) and is_equal_approx(bend.radius, radius) and bend.pan.is_equal_approx(pan):
		return
	bend.set_params(at, radius, pan, data.bend_window())
	_after_bend_moved()


func _after_bend_moved() -> void:
	_bounds_dirty = true
	refresh_frame()


## The views are drawn differently on a curved desk (cut into strips, bent by their material, text as geometry): all of them again.
func _rebuild_for_bend() -> void:
	for id in views:
		(views[id] as ItemView).rebuild()
	for c in _ai.get_children():
		if c is ItemView:
			(c as ItemView).rebuild()
	if _ghost != null:
		_ghost.rebuild()
	_bounds_dirty = true
	apply_style()
	refresh_frame()
	_set_bend_nodes()
	if bend == null:
		_bend_tag.visible = false


## The nodes the frame owns itself follow the bend: the overlay's material, and no culling by the unbent bounds (a bent surface lies far from them).
func _set_bend_nodes() -> void:
	_overlay.material_override = bend.overlay_material() if bend != null else OverlayDraw.material()
	var box := AABB(Vector3.ONE * -DeskBend.FAR, Vector3.ONE * (2.0 * DeskBend.FAR)) if bend != null else AABB()
	_overlay.custom_aabb = box
	if _grid != null:
		_grid.custom_aabb = box
	if bend != null and _marks == null:
		_marks = MeshInstance3D.new()
		_marks.name = "BendMarks"
		_marks.mesh = _marks_mesh
		_marks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_marks)
	if _marks != null:
		_marks.visible = bend != null
		_marks.material_override = bend.overlay_material() if bend != null else null
		_marks.custom_aabb = box
	_marks_key = ""


## Which marker the pointer is on (or moving): it lights up and says its number.
func set_marker_hot(which: String) -> void:
	if which != _marker_hot:
		_marker_hot = which
		_overlay_dirty = true


## Where the markers of the bend stand, in canvas coordinates: "d" at the distance where the flat part ends, "r" where the wall starts
## (the end of the quarter circle). Just outside the left edge of the shown part.
func marker_pos(which: String) -> Vector2:
	if bend == null:
		return Vector2.ZERO
	var x := bend.canvas_window().position.x - InputTuning.MARKER_SIDE
	return Vector2(x, (bend.at if which == "d" else bend.wall_at()) - bend.pan.y)


# ------------------------------------------------------------------------------------------------ look

func apply_style() -> void:
	if not is_canvas:
		return
	if data.is_pdf():
		_grid.visible = false                         # the page is the surface: no grid and no backing under it
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
	_apply_bend_to_grid()


## The grid mesh of a curved desk is laid out on the surface (so it does not move when the contents slide); its pattern belongs to the canvas.
func _apply_bend_to_grid() -> void:
	if _grid_mat == null:
		return
	if bend == null:
		_grid_mat.set_shader_parameter("bend_a", Vector4(0, 0, 0, 0))
		_grid_mat.set_shader_parameter("canvas_shift", Vector2.ZERO)
		return
	_grid_mat.set_shader_parameter("bend_a", Vector4(1.0, bend.at, bend.radius, 0.0))
	_grid_mat.set_shader_parameter("bend_pan", Vector2.ZERO)
	_grid_mat.set_shader_parameter("canvas_shift", -bend.pan)
	var w := bend.window
	_grid_mat.set_shader_parameter("bend_win", Vector4(w.position.x, w.position.y, w.end.x, w.end.y))


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
	_title.text = data.name + ("   curved desk" if bend != null else ("   on the desk" if data.surface else ""))
	if is_canvas:
		var b := bounds()
		_refresh_grid(b)
		_grid_mat.set_shader_parameter("bounds", Vector4(b.position.x, b.position.y, b.end.x, b.end.y))
		_apply_bend_to_grid()
		if bend != null:
			# at your edge of the surface, on the left: where the flat part begins
			_title.transform = bend.frame_at(Vector2(b.position.x + 0.02, b.position.y - 0.035), 0.001)
		else:
			_title.transform = Transform3D(Basis.IDENTITY, Vector3(b.position.x + 0.02, b.end.y + 0.035, 0.001))
	else:
		_title.position = Vector3(0.0, 0.12, 0.0)
		_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place_pdf()
	_overlay_dirty = true


## The grid's mesh: one quad over the canvas; on a curved desk a strip mesh over the shown part of the surface, cut finely enough to bend.
func _refresh_grid(b: Rect2) -> void:
	if bend != null:
		var w := bend.window
		var key := "bent %s %s" % [w.position, w.size]
		if key != _grid_key:
			_grid_key = key
			var pm := PlaneMesh.new()
			pm.orientation = PlaneMesh.FACE_Z
			pm.size = w.size + Vector2(0.02, 0.02)
			pm.center_offset = Vector3(w.get_center().x, w.get_center().y, 0.0)
			pm.subdivide_width = 0
			pm.subdivide_depth = clampi(ceili(pm.size.y / DeskBend.PITCH), 1, 700)
			_grid.mesh = pm
		return
	var key2 := "flat %s %s" % [b.position, b.size]
	if key2 != _grid_key or not _grid.mesh is QuadMesh:
		_grid_key = key2
		if not _grid.mesh is QuadMesh:
			_grid.mesh = QuadMesh.new()
		(_grid.mesh as QuadMesh).size = b.size + Vector2(0.02, 0.02)
		(_grid.mesh as QuadMesh).center_offset = Vector3(b.get_center().x, b.get_center().y, 0.0)


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
	if bend != null:
		_refresh_marks()


func _redraw_overlay() -> void:
	_draw.clear()
	_draw.bent = bend != null
	if is_canvas:
		if data.surface and bend == null:
			# a canvas on the desk keeps a thin amber edge: it is bound to that surface (a curved desk's is with its markers)
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


## The curved desk's edge and markers are drawn again when one of them, or how near a pointer is (in tenths), has changed.
func _refresh_marks() -> void:
	var key := "%s %s %s %s %d %s" % [bend.at, bend.radius, bend.pan, bend.window, roundi(clampf(hover, 0.0, 1.0) * 10.0), _marker_hot]
	if key == _marks_key:
		return
	_marks_key = key
	_mdraw.clear()
	_mdraw.bent = true
	_mdraw.rect(bounds(), 0.0016, Color(DESK_COLOR.r, DESK_COLOR.g, DESK_COLOR.b, 0.3 + 0.45 * clampf(hover, 0.0, 1.0)))
	_draw_bend_markers(_mdraw)
	_mdraw.build(_marks_mesh)


## The curved desk's markers: a line across where the flat part ends and another where the wall starts, each with a round handle outside the
## left edge that slides along the surface. The first sets the distance, the second the radius of the bend.
func _draw_bend_markers(od: OverlayDraw) -> void:
	var win := bend.canvas_window()
	var a := clampf(hover, 0.0, 1.0)
	var amber := Color(DESK_COLOR.r, DESK_COLOR.g, DESK_COLOR.b, 1.0)
	od.z = 0.0
	for which: String in ["d", "r"]:
		var hot := _marker_hot == which
		var p := marker_pos(which)
		var line_a := (0.9 if hot else (0.2 + 0.3 * a)) * (1.0 if which == "d" else 0.7)
		var n := maxi(int(win.size.x / 0.03), 2)
		for i in n:
			if i % 2 == 0:
				var x0 := win.position.x + win.size.x * float(i) / n
				var x1 := win.position.x + win.size.x * float(i + 1) / n
				od.segment(Vector2(x0, p.y), Vector2(x1, p.y), 0.0014, Color(amber.r, amber.g, amber.b, line_a))
		od.segment(Vector2(p.x, p.y), Vector2(win.position.x, p.y), 0.0014, Color(amber.r, amber.g, amber.b, line_a))
		var r := InputTuning.MARKER_R * (1.25 if hot else 1.0)
		od.disc(p, r + 0.0025, Color(0.05, 0.06, 0.08, 0.85))
		od.disc(p, r, Color(amber.r, amber.g, amber.b, 1.0 if hot else 0.55 + 0.4 * a))
		var ink := Color(0.1, 0.08, 0.04, 0.95)
		if which == "d":
			# arrows up and down the surface: it slides along it
			for sgn: float in [-1.0, 1.0]:
				var tip: Vector2 = p + Vector2(0, sgn * r * 0.62)
				od.polygon(PackedVector2Array([tip, tip - Vector2(r * 0.4, sgn * r * 0.4), tip - Vector2(-r * 0.4, sgn * r * 0.4)]), ink)
		else:
			# a quarter of a circle: the bend
			var arc := PackedVector2Array()
			var centre := p + Vector2(-0.3, 0.3) * r
			for i in 9:
				var t := -PI * 0.5 + PI * 0.5 * float(i) / 8.0
				arc.append(centre + Vector2(cos(t), sin(t)) * (0.55 * r))
			od.line(arc, r * 0.2, ink)
	# the numbers beside the handle that is touched
	if _marker_hot != "":
		var q := marker_pos(_marker_hot)
		_bend_tag.text = ("%d cm from you" % roundi(bend.at * 100.0)) if _marker_hot == "d" else ("radius %d cm" % roundi(bend.radius * 100.0))
		_bend_tag.transform = bend.frame_at(q + Vector2(-0.03, 0.0), 0.004)
		_bend_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_bend_tag.visible = true
	else:
		_bend_tag.visible = false


# ------------------------------------------------------------------------------------------------ PDF

## The page on the canvas in frame metres: as wide as the canvas's `pdf_width`, as tall as the page's shape makes it, centred on the canvas.
## Before the file is here (a guest still receiving it) it is the canvas's own rectangle.
func page_rect() -> Rect2:
	if not data.is_pdf():
		return Rect2()
	var pts := pdfs.page_size(data.pdf, doc.page_of(data.id)) if pdfs != null else Vector2.ZERO
	if pts == Vector2.ZERO:
		return Rect2(data.offset - data.size * 0.5, data.size)
	var w := data.pdf_width if data.pdf_width > 0.0 else data.size.x
	var sz := pts * (w / pts.x)
	return Rect2(data.offset - sz * 0.5, sz)


## Brings what is shown in line with the canvas: the PDF and page it names (asking the library, and the session when the file is not here).
func refresh_pdf() -> void:
	if not data.is_pdf():
		if _pdf != null:
			_pdf.queue_free()
			_pdf = null
		_pdf_key = ""
		pdf_state = ""
		_pdf_label.visible = false
		return
	var page := doc.page_of(data.id)
	if page != _items_page:
		_items_page = page
		rebuild_items()                               # the drawings of the page now shown
	var key := "%s:%d" % [data.pdf, page]
	if key == _pdf_key and pdf_state in ["ready", "loading"] and pdfs != null and pdfs.has(data.pdf):
		_place_pdf()
		return
	_pdf_key = key
	if pdfs == null:
		return
	if not pdfs.has(data.pdf):
		pdf_state = "missing"
		if _pdf != null:
			_pdf.clear()
		pdfs.want(data.pdf)
		_say(pdfs.state_text(data.pdf))
		return
	if page > pdfs.page_count(data.pdf):
		pdf_state = "failed"
		_say("This PDF has no page %d." % page)
		return
	pdf_state = "loading"
	if _pdf == null or _pdf.data == null:
		_say("Page %d..." % page)
	pdfs.request(data.pdf, page)


## The library has made a page: it is put on the canvas when it is the one wanted.
func on_pdf_page(pdf_id: String, page: int, page_data: PdfPageData) -> void:
	if not data.is_pdf() or pdf_id != data.pdf or page != doc.page_of(data.id):
		return
	if _pdf == null:
		_pdf = PdfPageNode.new()
		_pdf.name = "Pdf"
		add_child(_pdf)
	_pdf.show_page(page_data, 1.0 / maxf(page_data.size.x, 1.0))
	_pdf_shown_size = page_data.size
	pdf_state = "ready"
	_pdf_label.visible = false
	_place_pdf()
	_bounds_dirty = true
	refresh_frame()


func on_pdf_failed(pdf_id: String, page: int, message: String) -> void:
	if data.is_pdf() and pdf_id == data.pdf and page == doc.page_of(data.id):
		pdf_state = "failed"
		_say(message)


func _say(text: String) -> void:
	pdf_note = text
	_pdf_label.text = text
	_pdf_label.visible = text != "" and pdf_state != "ready"
	var r := page_rect()
	_pdf_label.position = Vector3(r.get_center().x, r.get_center().y, 0.0006)


func _place_pdf() -> void:
	if _pdf == null or _pdf.data == null:
		return
	var r := page_rect()
	var width := r.size.x
	var mpp := width / maxf(_pdf_shown_size.x, 1.0)
	_pdf.set_metres_per_point(mpp)
	_pdf.position = Vector3(r.get_center().x, r.get_center().y, 0.0)


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


## Show `it` (a text item not in the document, its centre at the origin) with its middle at `center` as a ghost; null clears it.
## Not part of the canvas's extent: it only follows the pointer.
func show_ghost(it: Item, center: Vector2) -> void:
	if it == null:
		if _ghost != null:
			_ghost.queue_free()
			_ghost = null
		return
	if _ghost == null or _ghost.item != it:
		if _ghost != null:
			_ghost.queue_free()
		_ghost = ItemView.new()
		add_child(_ghost)
		_ghost.setup(it, false)
	_ghost.set_preview(Transform3D(Basis.IDENTITY, Vector3(center.x, center.y, 0.0012)))


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
