extends Node

const SELECTOR_SCENE := "res://Scenes/UI/LevelSelect.tscn"
const CATALOG_PATH := "res://Levels/catalog.tres"

var catalog: LevelCatalog = load(CATALOG_PATH)
var current_level: LevelData = null

func get_current() -> LevelData:
	# Fallback so pressing F6 on a level scene in the editor still works.
	if current_level == null:
		var path: String = get_tree().current_scene.scene_file_path
		current_level = catalog.find_by_scene(path)
		if current_level == null:
			push_warning("LevelManager: '%s' isn't in the catalog, so progress won't be saved." % path)
	return current_level

func is_unlocked(level: LevelData) -> bool:
	for req in level.unlock_requires:
		if not SaveManager.is_completed(req):
			return false
	return true

func start_level(level: LevelData) -> void:
	if not is_unlocked(level):
		return
	current_level = level
	get_tree().paused = false
	get_tree().change_scene_to_file(level.scene_path)

func finish_level(result: Dictionary) -> void:
	var level := get_current()
	if level:
		SaveManager.record_run(level.id, result)

func go_to_selector() -> void:
	current_level = null
	get_tree().paused = false
	get_tree().change_scene_to_file(SELECTOR_SCENE)
