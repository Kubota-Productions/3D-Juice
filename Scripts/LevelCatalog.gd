class_name LevelCatalog
extends Resource

@export var levels: Array[LevelData] = []

func find_by_id(id: StringName) -> LevelData:
	for l in levels:
		if l.id == id:
			return l
	return null

static func _res_path(path: String) -> String:
	if path.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(path)
		if ResourceUID.has_id(uid):
			return ResourceUID.get_id_path(uid)
	return path

func find_by_scene(path: String) -> LevelData:
	for l in levels:
		if _res_path(l.scene_path) == _res_path(path):
			return l
	return null
