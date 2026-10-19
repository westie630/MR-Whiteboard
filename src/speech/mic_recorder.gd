class_name MicRecorder
extends Node
## Records the microphone (the headset's, or the PC's default) as 16 kHz mono 16-bit speech. It stops by itself when you have spoken
## and then paused, when nothing is heard for a while, or after MAX_S (one speech request carries about 20 s). The audio is converted
## while it arrives, so finishing never hitches a frame. Needs `audio/driver/enable_input` and, on Android, the RECORD_AUDIO permission.

signal finished(pcm: PackedByteArray, heard_speech: bool)

const RATE := 16000
const MAX_S := 19.0
const END_SILENCE_S := 1.3                  # pause after speech that ends the recording
const NO_SPEECH_S := 7.0                    # give up when nothing was said
const MIN_THRESHOLD := 0.018                # speech level (RMS, 0..1); the real threshold follows the room's noise within these limits
const MAX_THRESHOLD := 0.05
const BUS := "MRW_Mic"
const SINK := "MRW_MicSink"
const ANDROID_PERMISSION := "RECORD_AUDIO"

var listening := false
var heard_speech := false
var level := 0.0                            # smoothed loudness 0..1 for the UI
var seconds := 0.0                          # recorded so far

var _player: AudioStreamPlayer
var _capture: AudioEffectCapture
var _pcm := PackedByteArray()
var _src_rate := 48000.0
var _acc := 0.0                             # decimator state: box average of the input samples that make up one output sample
var _acc_n := 0
var _phase := 0.0
var _floor := 1.0                           # noise floor estimate (RMS)
var _quiet := 0.0                           # seconds since the last speech


## Begin recording. Returns "" or a message saying why it could not.
func start() -> String:
	if listening:
		return ""
	if OS.get_name() == "Android" and not OS.get_granted_permissions().has("android.permission." + ANDROID_PERMISSION):
		OS.request_permission(ANDROID_PERMISSION)
		return "Allow microphone access for MR Whiteboard, then tap Dictate again."
	if not bool(ProjectSettings.get_setting("audio/driver/enable_input", false)):
		return "Audio input is switched off in this build."
	if OS.get_name() != "Android" and AudioServer.get_input_device_list().is_empty():
		return "No microphone found."
	_ensure_bus()
	_src_rate = AudioServer.get_mix_rate()
	reset_state()
	_capture.clear_buffer()
	_player.play()
	listening = true
	return ""


func stop() -> void:
	if listening:
		_finish()


func cancel() -> void:
	if listening:
		listening = false
		_player.stop()
		reset_state()


func reset_state() -> void:
	_pcm = PackedByteArray()
	_acc = 0.0
	_acc_n = 0
	_phase = 0.0
	_floor = 1.0
	_quiet = 0.0
	heard_speech = false
	level = 0.0
	seconds = 0.0


func _process(_delta: float) -> void:
	if not listening:
		return
	var n := _capture.get_frames_available()
	if n > 0:
		feed(_capture.get_buffer(n), _src_rate)


## Take a block of stereo frames at `rate` Hz (what the audio capture delivers): convert, run the speech detection, and decide
## whether the recording is over. Public so tests can play synthetic audio in.
func feed(frames: PackedVector2Array, rate: float) -> void:
	if frames.is_empty():
		return
	var ratio := rate / float(RATE)
	var out := PackedByteArray()
	out.resize(int(float(frames.size()) / ratio) * 2 + 8)
	var o := 0
	var sum_sq := 0.0
	for f in frames:
		var x := (f.x + f.y) * 0.5
		sum_sq += x * x
		_acc += x
		_acc_n += 1
		_phase += 1.0
		if _phase >= ratio:
			_phase -= ratio
			out.encode_s16(o, int(clampf(_acc / float(_acc_n), -1.0, 1.0) * 32767.0))
			o += 2
			_acc = 0.0
			_acc_n = 0
	out.resize(o)
	_pcm.append_array(out)
	var dt := float(frames.size()) / rate
	seconds += dt
	var rms := sqrt(sum_sq / float(frames.size()))
	level = lerpf(level, clampf(rms * 6.0, 0.0, 1.0), 0.35)
	# The noise floor drops at once to a quiet moment and creeps up slowly, so steady background noise is not mistaken for speech;
	# the threshold is capped so a long sentence can never raise it above the speech itself.
	_floor = rms if rms < _floor else _floor + (rms - _floor) * minf(dt * 0.05, 1.0)
	var speaking := rms > clampf(_floor * 3.0, MIN_THRESHOLD, MAX_THRESHOLD)
	if speaking:
		heard_speech = true
		_quiet = 0.0
	else:
		_quiet += dt
	if heard_speech and _quiet >= END_SILENCE_S:
		_finish()
	elif not heard_speech and seconds >= NO_SPEECH_S:
		_finish()
	elif seconds >= MAX_S:
		_finish()


func _finish() -> void:
	listening = false
	if _player != null:
		_player.stop()
	var pcm := _pcm
	var heard := heard_speech
	reset_state()
	finished.emit(pcm, heard)


## The capture bus (microphone -> capture effect) feeds a muted bus, so nothing you say is played back to you.
func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS) == -1:
		var sink := AudioServer.get_bus_index(SINK)
		if sink == -1:
			AudioServer.add_bus()
			sink = AudioServer.bus_count - 1
			AudioServer.set_bus_name(sink, SINK)
			AudioServer.set_bus_mute(sink, true)
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS)
		AudioServer.set_bus_send(idx, SINK)
		AudioServer.add_bus_effect(idx, AudioEffectCapture.new())
	var bus := AudioServer.get_bus_index(BUS)
	_capture = AudioServer.get_bus_effect(bus, 0) as AudioEffectCapture
	_capture.buffer_length = 0.5
	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.stream = AudioStreamMicrophone.new()
		_player.bus = BUS
		add_child(_player)
