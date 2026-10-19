class_name SpeechRecognizer
extends RefCounted
## A speech-to-text back end. Audio goes in as 16-bit signed little-endian mono PCM at `rate` Hz; the answer comes back through the
## callback as {ok: bool, text: String, error: String}. Providers: WitSpeech (online). Others can be added by implementing transcribe().


func name_of() -> String:
	return "none"


## True when the provider can be used right now (for the online one: a token is set). `why` explains what is missing.
func ready_reason() -> String:
	return "Speech to text is switched off (More tab)."


func transcribe(_pcm: PackedByteArray, _rate: int, done: Callable) -> void:
	done.call({"ok": false, "text": "", "error": ready_reason()})
