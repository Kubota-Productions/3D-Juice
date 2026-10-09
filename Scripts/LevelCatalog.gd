class_name LevelCatalog
extends Resource

@export var levels: Array[LevelData] = []

func find_by_id(id: StringName) -> LevelData:
	for l in levels:
		if l.id == id:
			return l
	return null

func find_by_scene(path: String) -> LevelData:
	for l in levels:
		if l.scene_path == path:
			return l
	return null
