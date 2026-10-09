class_name LevelCard
extends Button

var level: LevelData

func setup(new_level: LevelData) -> void:
	level = new_level
	%NameLabel.text = level.display_name
	%Thumb.texture = level.thumbnail

	var unlocked: bool = LevelManager.is_unlocked(level)
	disabled = not unlocked

	if not unlocked:
		%InfoLabel.text = "Locked"
		%Thumb.modulate = Color(0.35, 0.35, 0.35)
	else:
		%InfoLabel.text = _build_info()

	pressed.connect(_on_pressed)

func _build_info() -> String:
	var total: int = SaveManager.get_bottles_total(level.id)
	if total <= 0:
		return "Bottles: -"
	var got: int = mini(SaveManager.get_bottles_collected(level.id), total)
	return "Bottles: %d / %d" % [got, total]

func _format_time(t: float) -> String:
	var total: int = int(ceil(t))
	return "%d:%02d" % [total / 60, total % 60]

func _on_pressed() -> void:
	LevelManager.start_level(level)
