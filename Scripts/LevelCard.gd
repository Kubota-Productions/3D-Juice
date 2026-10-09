class_name LevelCard
extends Button

@onready var thumb: TextureRect = %Thumb
@onready var name_label: Label = %NameLabel
@onready var info_label: Label = %InfoLabel

var level: LevelData

func setup(new_level: LevelData) -> void:
	level = new_level
	name_label.text = level.display_name
	thumb.texture = level.thumbnail

	var unlocked: bool = LevelManager.is_unlocked(level)
	disabled = not unlocked

	if not unlocked:
		info_label.text = "Locked"
		thumb.modulate = Color(0.35, 0.35, 0.35)
	else:
		info_label.text = _build_info()

	pressed.connect(_on_pressed)

func _build_info() -> String:
	var lines: PackedStringArray = []

	if SaveManager.is_completed(level.id):
		lines.append("Completed  -  %s" % _format_time(SaveManager.get_best_time(level.id)))
	else:
		lines.append("Not completed")

	var total: int = SaveManager.get_bottles_total(level.id)
	if total > 0:
		var got: int = mini(SaveManager.get_bottles_collected(level.id), total)
		lines.append("Bottles: %d / %d" % [got, total])
	else:
		lines.append("Bottles: -")

	return "\n".join(lines)

func _format_time(t: float) -> String:
	var total: int = int(ceil(t))
	return "%d:%02d" % [total / 60, total % 60]

func _on_pressed() -> void:
	LevelManager.start_level(level)
