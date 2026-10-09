extends CanvasLayer

const SAVE_PATH := "user://keybinds.cfg"
const SAVE_SECTION := "bindings"

@export var menu_action: StringName = &"OpenMenu"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	visible = false
	_load_bindings()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(menu_action):
		if visible:
			close()
		else:
			open()
		get_viewport().set_input_as_handled()


func open() -> void:
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	get_tree().call_group("keybind_rows", "cancel_listening")
	_save_bindings()
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_resume_button_pressed() -> void:
	close()


func _on_reset_button_pressed() -> void:
	InputMap.load_from_project_settings()
	DirAccess.remove_absolute(SAVE_PATH)
	get_tree().call_group("keybind_rows", "refresh")


func _on_exit_button_pressed() -> void:
	_save_bindings()
	get_tree().quit()

func _on_level_select_button_pressed() -> void:
	_save_bindings()
	get_tree().call_group("game_timer", "record_progress")
	LevelManager.go_to_selector()

func _save_bindings() -> void:
	var config := ConfigFile.new()

	for node in get_tree().get_nodes_in_group("keybind_rows"):
		var row := node as KeybindRow
		if row == null:
			continue

		var event := row.get_binding()
		if event is InputEventKey:
			config.set_value(SAVE_SECTION, String(row.action),
				{"type": "key", "code": (event as InputEventKey).physical_keycode})
		elif event is InputEventMouseButton:
			config.set_value(SAVE_SECTION, String(row.action),
				{"type": "mouse", "button": (event as InputEventMouseButton).button_index})

	config.save(SAVE_PATH)


func _load_bindings() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return

	for node in get_tree().get_nodes_in_group("keybind_rows"):
		var row := node as KeybindRow
		if row == null or not config.has_section_key(SAVE_SECTION, String(row.action)):
			continue

		var data: Dictionary = config.get_value(SAVE_SECTION, String(row.action))
		match data.get("type", ""):
			"key":
				var key := InputEventKey.new()
				key.physical_keycode = int(data["code"]) as Key
				row.set_binding(key)
			"mouse":
				var mouse := InputEventMouseButton.new()
				mouse.button_index = int(data["button"]) as MouseButton
				row.set_binding(mouse)
