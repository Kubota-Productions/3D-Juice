extends Node

const SAVE_PATH := "user://save.tres"

var data: SaveData = SaveData.new()

func _ready() -> void:
	load_game()

func load_game() -> void:
	data = SaveData.new()
	print("SaveManager: file exists? ", FileAccess.file_exists(SAVE_PATH))
	if not ResourceLoader.exists(SAVE_PATH):
		return

	var loaded: Resource = ResourceLoader.load(SAVE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded is SaveData:
		data = loaded
	else:
		push_warning("SaveManager: %s couldn't be read as SaveData, starting fresh." % SAVE_PATH)

func save_game() -> void:
	var err: Error = ResourceSaver.save(data, SAVE_PATH)
	print("5 save err = ", error_string(err))

func get_progress(id: StringName) -> LevelProgress:
	return data.levels.get(String(id))   # null if the level was never played

func _get_or_create(id: StringName) -> LevelProgress:
	var key := String(id)
	if not data.levels.has(key):
		data.levels[key] = LevelProgress.new()
	return data.levels[key]

func is_completed(id: StringName) -> bool:
	var p := get_progress(id)
	return p != null and p.completed

func get_best_time(id: StringName) -> float:
	var p := get_progress(id)
	return p.best_time if p else 0.0

func has_bottle(id: StringName, bottle_id: String) -> bool:
	var p := get_progress(id)
	return p != null and p.bottles.has(bottle_id)

func get_bottles_collected(id: StringName) -> int:
	var p := get_progress(id)
	return p.bottles.size() if p else 0

func get_bottles_total(id: StringName) -> int:
	var p := get_progress(id)
	return p.bottles_total if p else 0

func record_run(id: StringName, result: Dictionary) -> void:
	print("4 record_run ", id)
	var p := _get_or_create(id)

	for b in result.get("bottles", []):
		if not p.bottles.has(b):
			p.bottles.append(b)
	p.bottles_total = result.get("bottles_total", 0)

	if result.get("escaped", false):
		var t: float = result["time"]
		if not p.completed or t < p.best_time:
			p.best_time = t
		p.completed = true

	save_game()
