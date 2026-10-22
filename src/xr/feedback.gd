class_name Feedback
extends Node
## Click sounds for the hands, which cannot be given haptics (the stylus can): a tick when a pinch closes, a softer lower one when it
## opens. Made of a decaying sine, generated here so there are no sound files. Follows the Feedback setting (`haptics`).

const RATE := 22050
const KINDS := {
	"press": {"hz": 1500.0, "ms": 26.0, "gain": 0.5},
	"release": {"hz": 1000.0, "ms": 20.0, "gain": 0.3},
}

var _players := {}


func _ready() -> void:
	for kind in KINDS:
		var k: Dictionary = KINDS[kind]
		var p := AudioStreamPlayer.new()
		p.stream = tone(float(k.hz), float(k.ms), float(k.gain))
		p.volume_db = -8.0
		add_child(p)
		_players[kind] = p


## A short click: a sine of `hz` that dies away over `ms` milliseconds, as 16 bit mono.
static func tone(hz: float, ms: float, gain: float) -> AudioStreamWAV:
	var n := int(RATE * ms / 1000.0)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / float(RATE)
		var env := exp(-5.0 * float(i) / float(n)) * minf(float(i) / 40.0, 1.0)
		var v := int(clampf(sin(TAU * hz * t) * env * gain, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


func play(kind: String) -> void:
	if not bool(App.val("haptics")) or not _players.has(kind):
		return
	(_players[kind] as AudioStreamPlayer).play()
