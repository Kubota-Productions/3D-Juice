extends CanvasLayer
class_name GameController

signal captured
signal escaped

enum State { RUNNING, CAPTURED, ESCAPED }

@export_group("Scene References")
@export var player: Node3D
@export var chase_camera: Camera3D

@export_group("Escape Requirements")
@export var required_kills_to_escape: int = 0
@export var not_enough_kills_message: String = "Kill %d more to escape"

@export_group("Keys")
@export var keys_text: String = "Keys: %d / %d"
@export var all_keys_text: String = "All keys collected, get to the train!!!"
@export var keys_font_size: int = 32
@export var keys_color: Color = Color.WHITE
@export var all_keys_color: Color = Color(0.4, 1.0, 0.4)

@export_group("Timer")
@export var start_time: float = 60.0
@export var max_time: float = 0.0

@export_group("End Messages")
@export var captured_text: String = "Captured"
@export var escaped_text: String = "Escaped"
@export var captured_color: Color = Color(1.0, 0.2, 0.2)
@export var escaped_color: Color = Color(0.4, 1.0, 0.4)
@export var end_font_size: int = 72
@export var stats_font_size: int = 28
@export var escape_time_prefix: String = "Time: "
@export var escape_kills_prefix: String = "NPCs killed: "
@export var restart_delay: float = 3.0
@export var restart_after_escape: bool = false

@export_group("Display")
@export var font_size: int = 48
@export var top_margin: int = 20
@export var normal_color: Color = Color.WHITE
@export var low_time_color: Color = Color(1.0, 0.2, 0.2)
@export var low_time_threshold: float = 10.0
@export var bonus_color: Color = Color(0.4, 1.0, 0.4)
@export var bonus_font_size: int = 28

var time_left: float = 0.0
var state: State = State.RUNNING
var elapsed_time: float = 0.0
var npc_kills: int = 0

var _pulse_time: float = 0.0
var _label: Label
var _keys_label: Label
var _stats_label: Label
var _bonus_label: Label
var _bonus_tween: Tween


func _ready() -> void:
	add_to_group("game_timer")
	time_left = start_time
	elapsed_time = 0.0
	npc_kills = 0
	_build_ui()
	_update_label(0.0)
	_update_keys_label()


func _physics_process(delta: float) -> void:
	if state != State.RUNNING:
		return

	elapsed_time += delta
	time_left -= delta

	if time_left <= 0.0:
		capture()
		return

	_update_label(delta)


func add_time(seconds: float) -> void:
	if state != State.RUNNING:
		return

	time_left += seconds

	if max_time > 0.0:
		time_left = minf(time_left, max_time)

	_show_bonus(seconds)


func register_kill(time_bonus: float) -> void:
	if state != State.RUNNING:
		return

	npc_kills += 1
	_update_keys_label()
	add_time(time_bonus)


func capture() -> void:
	if state != State.RUNNING:
		return

	state = State.CAPTURED
	time_left = 0.0

	var player_ref := player as Player
	if player_ref:
		player_ref.set_captured(true)
	else:
		push_warning("GameController: 'player' isn't assigned, or isn't (or doesn't contain as its root) a Player -- movement can't be locked. Assign the actual Player-scripted node under Scene References.")

	_show_end_message(captured_text, captured_color)
	captured.emit()
	_schedule_reload()


func escape() -> void:
	if state != State.RUNNING:
		return

	var kills_needed: int = required_kills_to_escape - npc_kills
	if kills_needed > 0:
		_flash_message(not_enough_kills_message % kills_needed)
		return

	state = State.ESCAPED

	if is_instance_valid(player):
		var player_ref := player as Player
		if player_ref:
			player_ref.remove_for_escape()
		else:
			push_warning("GameController: 'player' isn't (or doesn't contain as its root) a Player -- the character won't be removed. Assign the actual Player-scripted node under Scene References.")
	else:
		push_warning("GameController: 'player' isn't assigned -- the character won't be removed. Assign it under Scene References in the Inspector.")

	if is_instance_valid(chase_camera):
		chase_camera.make_current()
	else:
		push_warning("GameController: no chase_camera assigned -- the view won't switch to the train.")

	var stats_text: String = "%s%s    %s%d" % [
		escape_time_prefix, _format_time(elapsed_time),
		escape_kills_prefix, npc_kills
	]
	_show_end_message(escaped_text, escaped_color, stats_text)
	escaped.emit()

	if restart_after_escape:
		_schedule_reload()


func reset_timer() -> void:
	state = State.RUNNING
	time_left = start_time
	elapsed_time = 0.0
	npc_kills = 0
	_pulse_time = 0.0
	_label.add_theme_font_size_override("font_size", font_size)
	if _stats_label:
		_stats_label.visible = false
	_update_label(0.0)
	_update_keys_label()


func _schedule_reload() -> void:
	get_tree().create_timer(restart_delay).timeout.connect(_reload_scene)


func _reload_scene() -> void:
	get_tree().reload_current_scene()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_top", top_margin)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	_label = Label.new()
	_label.text = "0:00"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 10)
	box.add_child(_label)

	_keys_label = Label.new()
	_keys_label.text = ""
	_keys_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_keys_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_keys_label.add_theme_font_size_override("font_size", keys_font_size)
	_keys_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_keys_label.add_theme_constant_override("outline_size", 8)
	box.add_child(_keys_label)

	_stats_label = Label.new()
	_stats_label.text = ""
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats_label.add_theme_font_size_override("font_size", stats_font_size)
	_stats_label.add_theme_color_override("font_color", normal_color)
	_stats_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_stats_label.add_theme_constant_override("outline_size", 8)
	_stats_label.visible = false
	box.add_child(_stats_label)

	_bonus_label = Label.new()
	_bonus_label.text = " "
	_bonus_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bonus_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bonus_label.add_theme_font_size_override("font_size", bonus_font_size)
	_bonus_label.add_theme_color_override("font_color", bonus_color)
	_bonus_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_bonus_label.add_theme_constant_override("outline_size", 8)
	_bonus_label.modulate.a = 0.0
	box.add_child(_bonus_label)


func _update_label(delta: float) -> void:
	if not _label:
		return

	_label.text = _format_time(time_left)

	var color := normal_color
	if time_left <= low_time_threshold:
		_pulse_time += delta
		var pulse: float = (sin(_pulse_time * TAU * 1.5) + 1.0) * 0.5
		color = normal_color.lerp(low_time_color, 0.4 + 0.6 * pulse)
	else:
		_pulse_time = 0.0

	_label.add_theme_color_override("font_color", color)


func _update_keys_label() -> void:
	if not _keys_label:
		return

	_keys_label.visible = required_kills_to_escape > 0

	if npc_kills >= required_kills_to_escape:
		_keys_label.text = all_keys_text
		_keys_label.add_theme_color_override("font_color", all_keys_color)
	else:
		_keys_label.text = keys_text % [npc_kills, required_kills_to_escape]
		_keys_label.add_theme_color_override("font_color", keys_color)


func _show_end_message(message: String, color: Color, stats_text: String = "") -> void:
	if not _label:
		return

	_label.text = message
	_label.add_theme_font_size_override("font_size", end_font_size)
	_label.add_theme_color_override("font_color", color)

	if _keys_label:
		_keys_label.visible = false

	if _stats_label:
		_stats_label.text = stats_text
		_stats_label.visible = not stats_text.is_empty()

	if _bonus_tween and _bonus_tween.is_valid():
		_bonus_tween.kill()
	if _bonus_label:
		_bonus_label.modulate.a = 0.0


func _show_bonus(seconds: float) -> void:
	if is_zero_approx(seconds):
		return

	var amount_text: String = ("%.1f" % absf(seconds)).trim_suffix(".0")
	var sign_text: String = "+" if seconds > 0.0 else "-"
	_flash_message("%s%ss" % [sign_text, amount_text])


func _flash_message(text: String) -> void:
	if not _bonus_label:
		return

	_bonus_label.text = text
	_bonus_label.modulate.a = 1.0

	if _bonus_tween and _bonus_tween.is_valid():
		_bonus_tween.kill()

	_bonus_tween = create_tween()
	_bonus_tween.tween_interval(0.8)
	_bonus_tween.tween_property(_bonus_label, "modulate:a", 0.0, 0.6)


func _format_time(t: float) -> String:
	var total: int = int(ceil(t))
	return "%d:%02d" % [floori(total / 60.0), total % 60]
