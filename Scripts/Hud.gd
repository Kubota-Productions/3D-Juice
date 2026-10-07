extends Control
@export var Cam_controller: Node
@export var player_cam: Camera3D
@export var boresight: Control
@export var mouse_pos: Control
@export var gravity_controller: GravityController
@export var shift_power_bar: TextureProgressBar
@export var player: Player
@export var speed_lines: ColorRect

@export_group("Look At")
@export var look_at_target: Node3D

@export var flash_threshold: float = 0.3
@export var flash_speed_min: float = 3.0
@export var flash_speed_max: float = 8.0
@export var flash_color: Color = Color(1.0, 0.2, 0.2)
var flash_time: float = 0.0
var base_bar_color: Color = Color.WHITE

@export_group("Speed Lines")
@export var speed_lines_start_ratio: float = 0.55  
@export var speed_lines_full_ratio: float = 0.9   
@export var speed_lines_smoothing_time: float = 0.25
@export var speed_lines_shift_align_min: float = 0.2
@export var speed_lines_shift_align_full: float = 0.7
var speed_lines_intensity: float = 0.0

@export_group("Wall Move Indicators")
@export var wall_power_indicator1: Control
@export var wall_power_indicator2: Control

@export_group("Dive Indicator")
@export var Dive_indicator1: Control
@export var dive_indicator_min_scale: float = 0.2
@export var dive_indicator_shrink_speed: float = 8.0
var _dive_indicator_scale: float = 1.0

@export_group("Tooltip")
@export var tooltip_item: Control

@export_group("Bottle Counter")
@export var bottle_label: RichTextLabel
@export_multiline var bottle_text_format: String = "Bottles Picked Up: %d\nBottles Left: %d"
var _bottles_total: int = 0
var _bottles_picked_up: int = 0


func _ready() -> void:
	if shift_power_bar:
		base_bar_color = shift_power_bar.modulate
	_setup_bottle_counter()


func _process(delta: float) -> void:
	update_graphics(delta)
	update_wall_indicators()
	update_dive_indicator(delta)
	if Cam_controller == null or player_cam == null:
		return


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("DismissToolTip"):
		if tooltip_item:
			tooltip_item.visible = not tooltip_item.visible
		get_viewport().set_input_as_handled()

	elif event.is_action_pressed("CloseGame"):
		get_tree().quit()

func _setup_bottle_counter() -> void:
	var bottles: Array[Node] = get_tree().get_nodes_in_group("gravity_pickup")
	_bottles_total = bottles.size()
	_bottles_picked_up = 0

	for bottle in bottles:
		bottle.collected.connect(_on_bottle_collected)

	_update_bottle_label()

func _on_bottle_collected() -> void:
	_bottles_picked_up += 1
	_update_bottle_label()

func _update_bottle_label() -> void:
	if not bottle_label:
		return
	var bottles_left: int = _bottles_total - _bottles_picked_up
	bottle_label.text = bottle_text_format % [_bottles_picked_up, bottles_left]

func update_graphics(delta: float) -> void:
	if Cam_controller == null or player_cam == null:
		return

	var boresight_world_pos: Vector3 = Cam_controller.get_boresight_pos()

	if boresight:
		var boresight_screen_pos: Vector2 = player_cam.unproject_position(boresight_world_pos)
		boresight.position = boresight_screen_pos - boresight.size / 2

	if look_at_target:
		look_at_target.global_position = boresight_world_pos

	if mouse_pos:
		var mouse_aim_world_pos: Vector3 = Cam_controller.get_mouse_aim_pos()
		var mouse_pos_screen_pos: Vector2 = player_cam.unproject_position(mouse_aim_world_pos)
		mouse_pos.position = mouse_pos_screen_pos - mouse_pos.size / 2

	if shift_power_bar and gravity_controller:
		shift_power_bar.max_value = gravity_controller.max_shift_power
		shift_power_bar.value = gravity_controller.shift_power
		var ratio: float = gravity_controller.shift_power / gravity_controller.max_shift_power
		if ratio <= flash_threshold and ratio > 0.0:
			var urgency: float = 1.0 - (ratio / flash_threshold)
			var speed: float = lerp(flash_speed_min, flash_speed_max, urgency)
			flash_time += delta * speed
			var pulse: float = (sin(flash_time * TAU) + 1.0) * 0.5
			shift_power_bar.modulate = base_bar_color.lerp(flash_color, pulse)
		else:
			flash_time = 0.0
			shift_power_bar.modulate = base_bar_color

	if speed_lines and player:
		var speed_ratio: float

		if gravity_controller and gravity_controller.gravity_state == GravityController.GravityState.SHIFTING:
			speed_ratio = clampf(
				gravity_controller.shift_speed / max(gravity_controller.max_shift_speed, 0.001),
				0.0, 1.0
			)

			var camera_forward: Vector3 = -player_cam.global_transform.basis.z
			var shift_direction: Vector3 = gravity_controller.gravity_direction.normalized()
			var alignment: float = camera_forward.dot(shift_direction)
			var alignment_factor: float = smoothstep(
				speed_lines_shift_align_min,
				speed_lines_shift_align_full,
				alignment
			)
			speed_ratio *= alignment_factor
		else:
			speed_ratio = clampf(
				player.get_planar_speed() / max(player.lean_top_speed, 0.001),
				0.0, 1.0
			)

		var target_intensity: float = smoothstep(speed_lines_start_ratio, speed_lines_full_ratio, speed_ratio)
		var weight: float = 1.0 - exp(-delta / max(speed_lines_smoothing_time, 0.001))
		speed_lines_intensity = lerpf(speed_lines_intensity, target_intensity, weight)
		var mat := speed_lines.material as ShaderMaterial
		if mat:
			mat.set_shader_parameter("intensity", speed_lines_intensity)

func update_dive_indicator(delta: float) -> void:
	if not player or not Dive_indicator1:
		return

	Dive_indicator1.pivot_offset = Dive_indicator1.size / 2.0

	var target: float = lerpf(dive_indicator_min_scale, 1.0, player.dive.get_ready_fraction())

	if target < _dive_indicator_scale:
		_dive_indicator_scale = move_toward(_dive_indicator_scale, target, dive_indicator_shrink_speed * delta)
	else:
		_dive_indicator_scale = target

	Dive_indicator1.scale = Vector2.ONE * _dive_indicator_scale

func update_wall_indicators() -> void:
	if not player:
		return

	var remaining: int = _wall_moves_remaining()
	if wall_power_indicator1:
		wall_power_indicator1.visible = remaining >= 1
	if wall_power_indicator2:
		wall_power_indicator2.visible = remaining >= 2

func _wall_moves_remaining() -> int:
	if player.movement_locked or player.is_ots_mode:
		return 0
	return maxi(player.max_wall_moves - player._wall_moves_used, 0)
	
	
