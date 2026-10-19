class_name AnchorService
extends Node
## Spatial anchors as the board sees them: places in the real room that the headset remembers across sessions.
## Implementations: MetaAnchors (Quest, through the Godot OpenXR Vendors plugin) and SimAnchors (PC, for testing rooms).
## Poses are in world space (the Board's parent space). `tag` ties a creation request to its answer ("room:<id>", "frame:<id>").

signal created(tag: String, uuid: String)
signal create_failed(tag: String)
signal tracking_changed(uuid: String, tracked: bool)


func is_supported() -> bool:
	return false


## Create an anchor at a world pose and save it on the device. Answers with `created` or `create_failed`.
func create(_world_pose: Transform3D, _tag: String) -> void:
	pass


## Look the stored anchors up and track them (the ones that belong to another room simply never get a pose).
func track(_uuids: Array) -> void:
	pass


## Stop tracking (the anchor stays stored).
func untrack(_uuid: String) -> void:
	pass


## Remove an anchor from the device's storage.
func erase(_uuid: String) -> void:
	pass


func has_pose(_uuid: String) -> bool:
	return false


func pose(_uuid: String) -> Transform3D:
	return Transform3D.IDENTITY


## One line for the debug panel.
func status() -> String:
	return "no anchors"
