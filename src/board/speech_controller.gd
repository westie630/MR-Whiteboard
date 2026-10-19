class_name SpeechController
extends RefCounted
## Speech to text. Tap Dictate, speak, pause: the words are recorded, sent to the speech recogniser and placed as a text item on the
## canvas you are looking at (below any text already there), selected so you can move or correct it. With a `target` callable
## (the name / correct-the-text box) the words go there instead. Undo removes placed text like any other edit.

enum S { IDLE, LISTENING, THINKING }

const EM := 0.045                          # size of dictated text (m)
const WRAP_CHARS := 30                     # lines are broken at about this many characters
const MIN_SPEECH_S := 0.3

var board: Board
var state := S.IDLE
var last_error := ""
var recorder: MicRecorder

var _provider: SpeechRecognizer
var _target := Callable()


func _init(b: Board) -> void:
	board = b


func provider() -> SpeechRecognizer:
	var want := str(App.val("speech_provider"))
	if _provider == null or _provider.name_of() != want:
		_provider = WitSpeech.new(board) if want == "wit" else SpeechRecognizer.new()
	return _provider


func listening() -> bool:
	return state == S.LISTENING


func busy() -> bool:
	return state != S.IDLE


## 0..1 loudness while listening (for the button).
func level() -> float:
	return recorder.level if recorder != null and state == S.LISTENING else 0.0


## The Dictate button: start listening, or (while listening) stop and send what was said. `target` receives the text instead of the canvas.
func toggle(target: Callable = Callable()) -> void:
	match state:
		S.IDLE:
			start(target)
		S.LISTENING:
			recorder.stop()


func start(target: Callable = Callable()) -> void:
	if state != S.IDLE:
		return
	var why := provider().ready_reason()
	if why != "":
		board.toast.emit(why)
		return
	if recorder == null:
		recorder = MicRecorder.new()
		board.add_child(recorder)
		recorder.finished.connect(_on_recorded)
	var err := recorder.start()
	if err != "":
		last_error = err
		board.toast.emit(err)
		return
	_target = target
	state = S.LISTENING
	board.changed.emit()


func cancel() -> void:
	if recorder != null:
		recorder.cancel()
	state = S.IDLE
	board.changed.emit()


func _on_recorded(pcm: PackedByteArray, heard: bool) -> void:
	if not heard or float(pcm.size()) / 2.0 / float(MicRecorder.RATE) < MIN_SPEECH_S:
		state = S.IDLE
		board.toast.emit("Did not hear anything. Tap Dictate and speak.")
		board.changed.emit()
		return
	submit_audio(pcm)


## Send recorded speech (16 kHz mono 16-bit) to the recogniser. Also the entry point for tests.
func submit_audio(pcm: PackedByteArray) -> void:
	state = S.THINKING
	board.toast.emit("Reading what you said...")
	board.changed.emit()
	provider().transcribe(pcm, MicRecorder.RATE, _on_result)


func _on_result(res: Dictionary) -> void:
	state = S.IDLE
	board.changed.emit()
	if not bool(res.ok):
		last_error = str(res.error)
		board.toast.emit(last_error)
		return
	var text := str(res.text).strip_edges()
	if _target.is_valid():
		var cb := _target
		_target = Callable()
		cb.call(text)
		return
	place_text(text)


## Put dictated text on the canvas the head is looking at. Returns the new item, or null when there is nowhere to put it.
func place_text(text: String) -> Item:
	if board.doc == null or text == "":
		return null
	var spot := board.dictation_spot()
	if spot.is_empty():
		board.toast.emit("Place a canvas first, then dictate. You said: \"%s\"" % text)
		return null
	var frame_id: String = spot.frame
	var col: Color = App.val("color")
	var t := Item.make_text(frame_id, wrap_text(text, WRAP_CHARS), Color(col.r, col.g, col.b, 1.0), EM)
	t.center = _clear_spot(frame_id, spot.center, t.size)
	board.history.do(History.op_add([t]))
	board.select_items([t.id], frame_id)
	return t


## Move the wanted centre down until the new text does not sit on other text.
func _clear_spot(frame_id: String, want: Vector2, size: Vector2) -> Vector2:
	var c := want
	for _i in 40:
		var r := Rect2(c - size * 0.5, size).grow(size.y * 0.1)
		var hit := false
		for it in board.doc.items.values():
			if (it as Item).kind == Item.TEXT and (it as Item).frame == frame_id and r.intersects((it as Item).bounds()):
				hit = true
				break
		if not hit:
			break
		c.y -= size.y * 1.2
	return c


## Break text into lines of at most `width` characters, at spaces (a longer word keeps its own line).
static func wrap_text(text: String, width: int) -> String:
	var lines := PackedStringArray()
	var line := ""
	for w in text.split(" ", false):
		if line != "" and line.length() + 1 + w.length() > width:
			lines.append(line)
			line = w
		else:
			line = w if line == "" else line + " " + w
	if line != "":
		lines.append(line)
	return "\n".join(lines)
