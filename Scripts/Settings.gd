extends Node

const SAVE_PATH := "user://keybinds.cfg"
const SECTION := "bindings"

func _ready() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK or not config.has_section(SECTION):
		return

	for action in config.get_section_keys(SECTION):
		if not InputMap.has_action(action):
			continue
		var d: Dictionary = config.get_value(SECTION, action)
		var ev: InputEvent = null
		match d.get("type", ""):
			"key":
				if int(d.get("code", 0)) == 0:
					continue
				var k := InputEventKey.new()
				k.physical_keycode = int(d["code"]) as Key
				ev = k
			"mouse":
				var m := InputEventMouseButton.new()
				m.button_index = int(d["button"]) as MouseButton
				ev = m
		if ev == null:
			continue
		for old in InputMap.action_get_events(action):
			if old is InputEventKey or old is InputEventMouseButton:
				InputMap.action_erase_event(action, old)
		InputMap.action_add_event(action, ev)
