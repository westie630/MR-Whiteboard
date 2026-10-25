class_name PdfBar
extends FloatPanel
## The page bar of a PDF canvas: previous, a slider over the pages, "3 / 12", next. It hangs just under the page. For somebody who has
## turned away from the owner's page (a guest who may not move canvases looks at their own page), a chip takes them back.

var _frame := ""
var _prev: Btn
var _next: Btn
var _first: Btn
var _last: Btn
var _slider: FlatSlider
var _count: Label
var _follow: Btn
var _note: Label
var _updating := false


func _init() -> void:
	super()
	id = "pdf"
	kind = "canvas"
	pivot = Vector2(0.5, 0.0)                  # hangs just under the page's bottom edge
	max_size = Vector2(900, 140)
	ppm = 1500.0
	var sb := UITheme.glass(30, 6.0)
	add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	col.add_child(row)
	_first = UiKit.tool("pdf_first", "First page", func(): _go(1), 46.0)
	row.add_child(_first)
	_prev = UiKit.tool("left", "Previous page", func(): _step(-1), 46.0)
	row.add_child(_prev)
	_slider = FlatSlider.new(1.0, 2.0, 1.0, 1.0)
	_slider.custom_minimum_size = Vector2(300, 46)
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.value_changed.connect(func(v: float):
		if not _updating:
			_go(int(v)))
	row.add_child(_slider)
	_count = UiKit.label("1 / 1", false, UITheme.FONT_SMALL, 600)
	_count.autowrap_mode = TextServer.AUTOWRAP_OFF
	_count.custom_minimum_size = Vector2(96, 0)
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_count)
	_next = UiKit.tool("right", "Next page", func(): _step(1), 46.0)
	row.add_child(_next)
	_last = UiKit.tool("pdf_last", "Last page", func(): _go(1000000), 46.0)
	row.add_child(_last)
	_follow = UiKit.chip("Back to the owner's page", func():
		if shell != null:
			shell.board.pdf_follow(_frame), "pin", 40.0)
	_follow.accent = UITheme.GOOD
	_follow.visible = false
	col.add_child(_follow)
	_note = UiKit.label("", true, UITheme.FONT_TINY)
	_note.autowrap_mode = TextServer.AUTOWRAP_OFF
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.visible = false
	col.add_child(_note)


## Pins the bar under the PDF canvas being looked at. False when there is none.
func place_for(board: Board) -> bool:
	var fn := board.current_pdf_frame()
	if fn == null:
		return false
	_frame = fn.data.id
	var r := fn.bounds()
	anchor = {"frame": _frame, "pos": Vector2(r.get_center().x, r.position.y - 0.014 / fn.data.scale), "lift": 0.012}
	return true


func _step(d: int) -> void:
	if shell == null:
		return
	_go(shell.board.doc.page_of(_frame) + d)


func _go(page: int) -> void:
	if shell != null:
		shell.board.pdf_turn(_frame, page)


func refresh() -> void:
	if shell == null or shell.board.doc == null or not shell.board.doc.frames.has(_frame):
		return
	var b: Board = shell.board
	var f: FrameData = b.doc.frames[_frame]
	var count := maxi(f.pdf_pages, b.pdfs.page_count(f.pdf))
	var page := b.doc.page_of(_frame)
	_updating = true
	_slider.min_value = 1.0
	_slider.max_value = maxf(float(count), 2.0)
	_slider.value = float(page)
	_slider.visible = count > 1
	_updating = false
	_count.text = "%d / %d" % [page, maxi(count, page)]
	_prev.disabled = page <= 1
	_first.disabled = page <= 1
	_next.disabled = page >= count
	_last.disabled = page >= count
	_follow.visible = not b.pdf_is_following(_frame)
	var fn: FrameNode = b.frame_nodes.get(_frame)
	var note := ""
	if fn != null and fn.pdf_state in ["missing", "failed"]:
		note = fn.pdf_note
	elif not b.can_edit_pdf_pages() and b.pdf_is_following(_frame):
		note = "The owner turns the pages: use the slider to look at another one."
	_note.text = note
	_note.visible = note != ""
