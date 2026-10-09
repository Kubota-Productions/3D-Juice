class_name KeybindRow
extends HBoxContainer

@export var action: StringName = &""
@export var display_name: String = ""

@onready var name_label: Label = $NameLabel
@onready var bind_button: Button = $BindButton

var _listening: bool = false


func _ready() -> void:
	add_to_group("keybind_rows")
	name_label.text = display_name if not display_name.is_empty() else String(action)

	if not InputMap.has_action(action):
		push_warning("KeybindRow: '%s' isn't an action in the Input Map." % action)

	refresh()

func refresh() -> void:
	_listening = false
	var event := get_binding()
	if event == null:
		bind_button.text = "Unbound"
	elif event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.physical_keycode != KEY_NONE:
			bind_button.text = key_event.as_text_physical_keycode()
		elif key_event.keycode != KEY_NONE:
			bind_button.text = key_event.as_text_keycode()
		else:
			bind_button.text = key_event.as_text()
	else:
		bind_button.text = event.as_text()

func cancel_listening() -> void:
	if _listening:
		refresh()


# First keyboard/mouse event on the action (gamepad events are left alone).
func get_binding() -> InputEvent:
	if not InputMap.has_action(action):
		return null

	for event in InputMap.action_get_events(action):
		if event is InputEventKey or event is InputEventMouseButton:
			return event

	return null


func set_binding(new_event: InputEvent) -> void:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey or event is InputEventMouseButton:
			InputMap.action_erase_event(action, event)

	InputMap.action_add_event(action, new_event)
	refresh()


func _on_bind_button_pressed() -> void:
	if not InputMap.has_action(action):
		return

	get_tree().call_group("keybind_rows", "cancel_listening")
	_listening = true
	bind_button.text = "Press a key..."


func _input(event: InputEvent) -> void:
	if not _listening:
		return

	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return

		get_viewport().set_input_as_handled()

		if key_event.physical_keycode == KEY_ESCAPE:
			refresh()
			return

		var new_key := InputEventKey.new()
		new_key.physical_keycode = key_event.physical_keycode
		set_binding(new_key)

	elif event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if not mouse_event.pressed:
			return

		get_viewport().set_input_as_handled()

		var new_mouse := InputEventMouseButton.new()
		new_mouse.button_index = mouse_event.button_index
		set_binding(new_mouse)
