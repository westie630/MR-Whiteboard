class_name PdfPageData
extends RefCounted
## A page ready to be put in the scene: its size in points and its layers in painting order. A layer is either
##   {kind: "tris", verts: PackedVector2Array, cols: PackedColorArray, blend: String}   coloured triangles (shapes, text, gradients), or
##   {kind: "image", verts: PackedVector2Array, uvs: PackedVector2Array, color: Image, alpha: Image (or null), mask: bool, fill: Color,
##    opacity: float, blend: String}   triangles of the picture (cut to its clip), with texture coordinates
## Only plain data and Images (no scene objects), so a page can be made on a worker thread and handed over.

var index := 0
var size := Vector2(612, 792)
var layers: Array = []
var stats: Dictionary = {}
var ok := true
var message := ""
var seconds := 0.0


func triangles() -> int:
	var n := 0
	for l in layers:
		if l.kind == "tris":
			n += (l.verts as PackedVector2Array).size() / 3
		else:
			n += (l.verts as PackedVector2Array).size() / 3
	return n
