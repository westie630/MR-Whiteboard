class_name PdfStream
extends RefCounted
## A stream object: its dictionary and its bytes still as they are in the file (shared with the whole file's buffer, nothing is copied).
## decode() undoes decryption and every filter that is not an image codec; an image codec (DCT, JPX, CCITT, JBIG2) is left for the image
## reader, which asks image_filter() and image_parms().

var dict: Dictionary = {}
var raw := PackedByteArray()
var off := 0
var length := 0
var num := 0
var gen := 0
var crypt: PdfCrypt = null

var _dec := PackedByteArray()
var _have := false
var _image_filter := ""
var _image_parms: Dictionary = {}
var _ok := true


func bytes_raw() -> PackedByteArray:
	if off == 0 and length == raw.size():
		return raw
	return raw.slice(off, off + length)


## The data with decryption and the non-image filters undone. Empty (and ok() false) when a filter could not be read.
func decode() -> PackedByteArray:
	if _have:
		return _dec
	_have = true
	var data := bytes_raw()
	if crypt != null and not _is_clear():
		data = crypt.decrypt_stream(data, num, gen)
	var filters: Array = _list(dict.get("Filter", dict.get("F")))
	var parms: Array = _list(dict.get("DecodeParms", dict.get("DP")))
	for i in filters.size():
		var f := String(filters[i])
		var pr: Variant = parms[i] if i < parms.size() else {}
		var pd: Dictionary = pr if pr is Dictionary else {}
		var had_input := not data.is_empty()
		match f:
			"FlateDecode", "Fl":
				data = PdfFilters.flate(data, pd)
			"LZWDecode", "LZW":
				data = PdfFilters.lzw(data, pd)
			"ASCII85Decode", "A85":
				data = PdfFilters.ascii85(data)
			"ASCIIHexDecode", "AHx":
				data = PdfFilters.ascii_hex(data)
			"RunLengthDecode", "RL":
				data = PdfFilters.run_length(data)
			"Crypt":
				pass
			"DCTDecode", "DCT", "JPXDecode", "CCITTFaxDecode", "CCF", "JBIG2Decode":
				_image_filter = {"DCT": "DCTDecode", "CCF": "CCITTFaxDecode"}.get(f, f)
				_image_parms = pd
				break
			_:
				_ok = false
				data = PackedByteArray()
		if data.is_empty() and had_input and f != "Crypt":
			_ok = false
	_dec = data
	return _dec


func ok() -> bool:
	decode()
	return _ok


func image_filter() -> String:
	decode()
	return _image_filter


func image_parms() -> Dictionary:
	decode()
	return _image_parms


## Streams that are never encrypted: cross-reference streams, and ones that say so with a Crypt filter named Identity.
func _is_clear() -> bool:
	if str(dict.get("Type", "")) == "XRef":
		return true
	var parms: Array = _list(dict.get("DecodeParms", dict.get("DP")))
	for pr in parms:
		if pr is Dictionary and str((pr as Dictionary).get("Name", "")) == "Identity":
			return true
	return false


static func _list(v: Variant) -> Array:
	if v == null:
		return []
	if v is Array:
		return v
	return [v]
