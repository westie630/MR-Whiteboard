class_name ComposePanel
extends FloatPanel
## The typing card: the text box (new text, an edit, a label, a name, a key) with the on-screen keyboard under it, or the writing pad
## when the keyboard is switched off. Every bit of typing in the app happens here, so the keyboard is always next to its field.

var entry: TextEntry
var keyboard: VKeyboard


func _init() -> void:
	super()
	id = "compose"
	kind = "compose"
	pivot = Vector2(0.5, 1.0)
	max_size = Vector2(700, 760)
	add_theme_stylebox_override("panel", UITheme.glass(26, 16.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.custom_minimum_size = Vector2(640, 0)
	add_child(v)
	entry = TextEntry.new()
	v.add_child(entry)
	keyboard = VKeyboard.new()
	keyboard.visible = false
	v.add_child(keyboard)


func refresh() -> void:
	var kb := bool(App.val("vkeyboard")) and entry.is_open()
	keyboard.visible = kb
	if kb:
		keyboard.target = entry.field()
	entry.show_pad(not bool(App.val("vkeyboard")))
