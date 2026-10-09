extends Control

@export var card_scene: PackedScene

@onready var grid: GridContainer = $Margin/VBox/Scroll/Grid
@onready var quit_button: Button = $Margin/VBox/QuitButton

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	quit_button.pressed.connect(get_tree().quit)

	var first_unlocked: Button = null
	for level in LevelManager.catalog.levels:
		var card: LevelCard = card_scene.instantiate()
		grid.add_child(card)
		card.setup(level)
		if first_unlocked == null and not card.disabled:
			first_unlocked = card

	if first_unlocked:
		first_unlocked.grab_focus()
