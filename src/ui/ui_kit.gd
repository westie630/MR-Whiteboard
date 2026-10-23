class_name UiKit
extends RefCounted
## Small builders shared by the surfaces: labels, section headers, segmented choices, switches and sliders bound to a setting.
## Every bound widget registers a refresher here; sync() brings them all in step with the settings and the board.

var syncers: Array = []


func sync() -> void:
	for s in syncers:
		(s as Callable).call()


static func label(text: String, dim: bool = false, size: int = UITheme.FONT_SMALL, weight: int = 400) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", UITheme.TEXT_DIM if dim else UITheme.TEXT)
	if weight != 400:
		l.add_theme_font_override("font", UITheme.font(weight))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## A quiet section title.
static func header(parent: Control, text: String) -> Label:
	var l := label(text, true, UITheme.FONT_TINY, 600)
	l.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	l.text = text.to_upper()
	parent.add_child(l)
	return l


## A one-line explanation under a control, in the faint colour.
static func note(parent: Control, text: String) -> Label:
	var l := label(text, true, UITheme.FONT_TINY)
	parent.add_child(l)
	return l


static func hrow(parent: Control, sep: int = 8) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", sep)
	parent.add_child(r)
	return r


static func vcol(parent: Control, sep: int = 10) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.add_theme_constant_override("separation", sep)
	parent.add_child(c)
	return c


static func flow(parent: Control, sep: int = 8) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", sep)
	f.add_theme_constant_override("v_separation", sep)
	parent.add_child(f)
	return f


## A group of rows on a slightly lighter well, like a settings card.
static func card(parent: Control, pad: float = 12.0) -> VBoxContainer:
	var p := PanelContainer.new()
	var sb := UITheme.box(UITheme.WELL, 16)
	sb.set_content_margin_all(pad)
	p.add_theme_stylebox_override("panel", sb)
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	p.add_child(v)
	return v


static func button(icon: String, text: String, cb: Callable, h: float = 52.0, variant: String = "") -> Btn:
	var b := Btn.new(icon, text)
	b.custom_minimum_size = Vector2(0, h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.variant = variant
	b.pressed.connect(cb)
	return b


static func chip(text: String, cb: Callable, icon: String = "", h: float = 40.0) -> Btn:
	var b := Btn.new(icon, text)
	b.variant = "chip"
	var fs := UITheme.FONT_SMALL
	var w := UITheme.font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + (34.0 if icon == "" else 36.0 + h * 0.46 + 10.0)
	b.custom_minimum_size = Vector2(maxf(w, h), h)
	b.pressed.connect(cb)
	return b


static func tool(icon: String, hint: String, cb: Callable, size: float = UITheme.TOOL) -> Btn:
	var b := Btn.new(icon, "")
	b.variant = "tool"
	b.hint = hint
	b.custom_minimum_size = Vector2(size, size)
	b.pressed.connect(cb)
	return b


static func divider(parent: Control, vertical: bool = true) -> Control:
	var d := ColorRect.new()
	d.color = UITheme.DIVIDER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.custom_minimum_size = Vector2(1, 30) if vertical else Vector2(0, 1)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER if vertical else Control.SIZE_FILL
	parent.add_child(d)
	return d


## Mutually exclusive pills bound to a getter and a setter.
func segmented(parent: Control, options: Array, getter: Callable, setter: Callable, h: float = 44.0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var btns: Array = []
	for o in options:
		var b := Btn.new("", str(o[1]))
		b.variant = "chip"
		b.custom_minimum_size = Vector2(0, h)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			setter.call(o[0])
			sync())
		row.add_child(b)
		btns.append([o[0], b])
	syncers.append(func():
		var cur: Variant = getter.call()
		for pair in btns:
			if is_instance_valid(pair[1]):
				(pair[1] as Btn).on = pair[0] == cur)
	return row


## A labelled switch for a boolean setting: the whole row toggles it.
func switch(parent: Control, text: String, key: String, sub: String = "") -> Control:
	var sw := Switch.new(text, sub)
	sw.toggled.connect(func(v: bool): App.put(key, v))
	parent.add_child(sw)
	syncers.append(func(): sw.on = bool(App.val(key)))
	return sw


## A labelled slider for a numeric setting, with its value shown on the right.
func slider(parent: Control, text: String, lo: float, hi: float, key: String, step: float, fmt: Callable) -> FlatSlider:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	parent.add_child(box)
	var top := HBoxContainer.new()
	box.add_child(top)
	var l := label(text, false, UITheme.FONT_SMALL)
	top.add_child(l)
	var v := label("", true, UITheme.FONT_SMALL)
	v.autowrap_mode = TextServer.AUTOWRAP_OFF
	v.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top.add_child(v)
	var s := FlatSlider.new(lo, hi, float(App.val(key)), step)
	box.add_child(s)
	s.value_changed.connect(func(x: float): App.put(key, x))
	syncers.append(func():
		v.text = str(fmt.call(float(App.val(key))))
		if absf(s.value - float(App.val(key))) > 0.0001:
			s.value = float(App.val(key)))
	return s


static func clear(c: Node) -> void:
	for ch in c.get_children():
		c.remove_child(ch)
		ch.queue_free()
