extends Node
## Speech to text without a microphone or the network: the recorder is fed synthetic audio (silence, a tone standing in for speech,
## a pause) and must cut it at the right moment and deliver 16 kHz mono; the Wit.ai answer parser is checked against streamed
## responses and error codes; the controller must put dictated words on the canvas being looked at, below earlier text, and undo it.

class FakeSpeech extends SpeechRecognizer:
	var answer := "hello world"
	var fail := false
	var calls := 0
	var last_bytes := 0

	func name_of() -> String:
		return "wit"

	func ready_reason() -> String:
		return ""

	func transcribe(pcm: PackedByteArray, _rate: int, done: Callable) -> void:
		calls += 1
		last_bytes = pcm.size()
		if fail:
			done.call({"ok": false, "text": "", "error": "No internet connection for speech recognition (error 2)."})
		else:
			done.call({"ok": true, "text": answer, "error": ""})


func _ready() -> void:
	var t := TestCase.new("speech")
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_speech"
	App.reload()
	App.put("speech_provider", "wit")

	# 1. the Wit.ai answer: a stream of objects, partial then final; braces inside strings must not confuse the splitter
	var streamed := '{"text": "hel", "is_final": false}\r\n{"text": "hello {there}", "is_final": false}\r\n{"text": "hello there, \\"world\\"", "is_final": true, "speech": {"tokens": []}}\r\n'
	t.eq(WitSpeech.split_json_objects(streamed).size(), 3, "three objects in the stream")
	var ok := WitSpeech.parse_response(HTTPRequest.RESULT_SUCCESS, 200, streamed.to_utf8_buffer())
	t.check(bool(ok.ok), "the answer is understood")
	t.eq(ok.text, 'hello there, "world"', "the final transcription wins")
	var partial := WitSpeech.parse_response(HTTPRequest.RESULT_SUCCESS, 200, '{"text": "only partial", "is_final": false}'.to_utf8_buffer())
	t.eq(partial.text, "only partial", "the last text is used when no object is marked final")
	t.check(not bool(WitSpeech.parse_response(HTTPRequest.RESULT_SUCCESS, 200, '{"text": ""}'.to_utf8_buffer()).ok), "no words is a failure")
	t.check(str(WitSpeech.parse_response(HTTPRequest.RESULT_SUCCESS, 401, "{}".to_utf8_buffer()).error).contains("token"), "a refused token is explained")
	t.check(str(WitSpeech.parse_response(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray()).error).contains("internet"), "no network is explained")
	t.check(str(WitSpeech.parse_response(HTTPRequest.RESULT_SUCCESS, 400, '{"error": "bad audio", "code": "bad-request"}'.to_utf8_buffer()).error).contains("bad audio"), "the service's own message is passed on")
	t.eq(WitSpeech.content_type(16000), "audio/raw;encoding=signed-integer;bits=16;rate=16000;endian=little", "the audio format header")
	App.put("wit_token", "")
	var wit := WitSpeech.new(self)
	t.check(wit.ready_reason() != "" or WitSpeech.TOKEN_FILES.any(func(f): return FileAccess.file_exists(f)), "without a token the user is told what is missing")
	App.put("wit_token", "TOKEN")
	t.eq(wit.ready_reason(), "", "with a token it is ready")
	App.put("wit_token", "")

	# 2. the recorder: quiet room, one second of "speech", then a pause: it ends the recording by itself
	var rec := MicRecorder.new()
	add_child(rec)
	var got: Array = []
	rec.finished.connect(func(pcm: PackedByteArray, heard: bool): got.append([pcm, heard]))
	rec.listening = true
	_play(rec, 48000.0, 0.5, 0.0)
	_play(rec, 48000.0, 1.0, 0.3)
	t.eq(got.size(), 0, "still recording while speech goes on")
	_play(rec, 48000.0, 2.0, 0.0)
	t.eq(got.size(), 1, "a pause after speech ends the recording")
	if got.size() == 1:
		var pcm: PackedByteArray = got[0][0]
		t.check(bool(got[0][1]), "speech was heard")
		var secs := float(pcm.size()) / 2.0 / 16000.0
		t.near(secs, 2.8, 0.15, "the audio is 16 kHz mono 16-bit and ends just after the pause")
		var peak := 0
		for i in range(0, pcm.size() - 1, 2):
			peak = maxi(peak, absi(pcm.decode_s16(i)))
		t.check(peak > 7000 and peak < 11500, "the tone survives the conversion (peak %d)" % peak)
	t.check(not rec.listening, "the recorder stopped")

	got.clear()
	rec.listening = true
	_play(rec, 44100.0, 8.0, 0.002)
	t.eq(got.size(), 1, "silence ends the recording after a while")
	if got.size() == 1:
		t.check(not bool(got[0][1]), "no speech was heard")
		t.near(float(got[0][0].size()) / 2.0 / 16000.0, MicRecorder.NO_SPEECH_S, 0.2, "44.1 kHz input is brought to 16 kHz too")

	got.clear()
	rec.listening = true
	_play(rec, 48000.0, 25.0, 0.3)
	t.eq(got.size(), 1, "one long speech is cut at the limit")
	if got.size() == 1:
		t.near(float(got[0][0].size()) / 2.0 / 16000.0, MicRecorder.MAX_S, 0.2, "the limit is about 19 s")

	# 3. the controller puts dictated words on the canvas being looked at
	var board := Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors_speech.json")
	add_child(anchors)
	board.setup(anchors)
	board.open(Document.create("Speech test"))
	var fake := FakeSpeech.new()
	board.speech._provider = fake
	var toasts: Array = []
	board.toast.connect(func(m): toasts.append(m))
	board.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.4, 0.0))
	var pen := PenState.new()
	var audio := PackedByteArray()
	audio.resize(16000 * 2)

	for _i in 100:
		board.tick(pen, [], 0.016)                                 # the room is found
		await get_tree().process_frame
	board.speech.submit_audio(audio)
	t.eq(_texts(board).size(), 0, "no canvas, no text")
	t.check(toasts.any(func(m): return str(m).contains("Place a canvas")), "the user is told to place a canvas")

	var f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1)))
	for _i in 60:
		board.tick(pen, [], 0.016)                                 # the canvas appears in its room
		await get_tree().process_frame
	board.speech.submit_audio(audio)
	t.eq(fake.calls, 2, "the recogniser got the audio")
	t.eq(fake.last_bytes, audio.size(), "all of the audio was sent")
	var texts := _texts(board)
	t.eq(texts.size(), 1, "the words became a text item")
	if texts.size() == 1:
		var a: Item = texts[0]
		t.eq(a.text, "hello world", "the text is what was said")
		t.eq(a.frame, f.id, "it is on the canvas in front of the head")
		t.near(a.center.x, 0.0, 0.02, "it is where the head looks (x)")
		t.near(a.center.y, 0.0, 0.02, "it is where the head looks (y)")
		t.eq(board.selection, [a.id], "the new text is selected, ready to move or correct")
	fake.answer = "this is a much longer sentence that has to be broken into several lines"
	board.speech.submit_audio(audio)
	texts = _texts(board)
	t.eq(texts.size(), 2, "a second dictation adds a second text")
	if texts.size() == 2:
		var b: Item = texts[1]
		t.check(b.text.contains("\n"), "long text is wrapped")
		t.check(not (texts[0] as Item).bounds().intersects(b.bounds()), "it does not land on the earlier text")
		t.eq(board.speech.state, SpeechController.S.IDLE, "the controller is idle again")
	board.undo()
	t.eq(_texts(board).size(), 1, "undo removes the dictated text")

	# the correction box takes the words instead of the canvas
	var target: Array = []
	board.speech._target = func(s: String): target.append(s)
	fake.answer = "typed by voice"
	board.speech.submit_audio(audio)
	t.eq(target, ["typed by voice"], "a target receives the words")
	t.eq(_texts(board).size(), 1, "and nothing is added to the canvas")

	# failures are reported and leave the board alone
	fake.fail = true
	board.speech.submit_audio(audio)
	t.check(toasts.any(func(m): return str(m).contains("internet")), "a failed reading says why")
	t.eq(_texts(board).size(), 1, "nothing was added")
	t.eq(board.speech.state, SpeechController.S.IDLE, "the controller recovers")

	t.eq(SpeechController.wrap_text("one two three four five", 9), "one two\nthree\nfour five", "words wrap at the limit")
	t.eq(SpeechController.wrap_text("extraordinarily short", 5), "extraordinarily\nshort", "a long word keeps its own line")
	get_tree().quit(t.done())


## Feed `seconds` of a 440 Hz tone with the given amplitude (0: silence, tiny: room noise) in 20 ms blocks.
func _play(rec: MicRecorder, rate: float, seconds: float, amp: float) -> void:
	var block := int(rate * 0.02)
	var blocks := int(seconds / 0.02)
	var phase := 0.0
	for _b in blocks:
		if not rec.listening:
			return
		var fr := PackedVector2Array()
		fr.resize(block)
		for i in block:
			phase += 440.0 / rate
			var v := sin(phase * TAU) * amp
			fr[i] = Vector2(v, v)
		rec.feed(fr, rate)


func _texts(board: Board) -> Array:
	var out: Array = []
	for it in board.doc.items.values():
		if (it as Item).kind == Item.TEXT:
			out.append(it)
	return out
