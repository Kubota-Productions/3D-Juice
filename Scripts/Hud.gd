extends Control
@export var Cam_controller: Node
@export var player_cam: Camera3D
@export var boresight: Control
@export var mouse_pos: Control
@export var gravity_controller: GravityController
@export var shift_power_bar: TextureProgressBar
@export var player: Player
@export var speed_lines: ColorRect

# ============================================================
# LOOK AT  (drives a LookAtModifier3D on the character's head/spine)
# ============================================================
@export_group("Look At")
@export var look_at_target: Node3D  # a Marker3D that LookAtModifier3D's Target Node points at

#hud flash
@export var flash_threshold: float = 0.3
@export var flash_speed_min: float = 3.0
@export var flash_speed_max: float = 8.0
@export var flash_color: Color = Color(1.0, 0.2, 0.2)
var flash_time: float = 0.0
var base_bar_color: Color = Color.WHITE

@export_group("Speed Lines")
@export var speed_lines_start_ratio: float = 0.55  # fraction of max speed where lines start appearing
@export var speed_lines_full_ratio: float = 0.9    # fraction of max speed where lines reach full intensity
@export var speed_lines_smoothing_time: float = 0.25
## While shifting, lines fade based on how closely the camera faces the
## shift direction (dot product, -1..1). Below _min: fully faded out.
## At/above _full: no fade from this at all. Between: smoothstep blend.
@export var speed_lines_shift_align_min: float = 0.2
@export var speed_lines_shift_align_full: float = 0.7
var speed_lines_intensity: float = 0.0

# ============================================================
# WALL MOVE INDICATORS
# ============================================================
@export_group("Wall Move Indicators")
## Any Control (TextureRect, Label, Panel, ...). Visible while a wall run
## is available; hidden while one is in progress or all runs are used up.
@export var wall_run_indicator: Control
## Visible while a wall slide is available; hidden while one is in
## progress or all slides are used up.
@export var wall_slide_indicator: Control

# ============================================================
# TOOLTIP
# ============================================================
@export_group("Tooltip")
## Any Control. Toggled shown/hidden each time the "DismissToolTip"
## input action is pressed. Its visibility in the editor is its starting state.
@export var tooltip_item: Control


func _ready() -> void:
	if shift_power_bar:
		base_bar_color = shift_power_bar.modulate


func _process(delta: float) -> void:
	update_graphics(delta)
	update_wall_indicators()
	if Cam_controller == null or player_cam == null:
		return


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("DismissToolTip"):
		if tooltip_item:
			tooltip_item.visible = not tooltip_item.visible
		get_viewport().set_input_as_handled()

	elif event.is_action_pressed("CloseGame"):
		get_tree().quit()


func update_graphics(delta: float) -> void:
	if Cam_controller == null or player_cam == null:
		return

	# Boresight world position -- shared by the 2D reticle and the 3D look-at target.
	var boresight_world_pos: Vector3 = Cam_controller.get_boresight_pos()

	# Boresight (2D reticle)
	if boresight:
		var boresight_screen_pos: Vector2 = player_cam.unproject_position(boresight_world_pos)
		boresight.position = boresight_screen_pos - boresight.size / 2

	# Drive the LookAtModifier3D's target to the same point in world space.
	if look_at_target:
		look_at_target.global_position = boresight_world_pos

	# Mouse Aim Position
	if mouse_pos:
		var mouse_aim_world_pos: Vector3 = Cam_controller.get_mouse_aim_pos()
		var mouse_pos_screen_pos: Vector2 = player_cam.unproject_position(mouse_aim_world_pos)
		mouse_pos.position = mouse_pos_screen_pos - mouse_pos.size / 2

	# Shift Power Bar
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

	# Speed Lines
	if speed_lines and player:
		var speed_ratio: float

		if gravity_controller and gravity_controller.gravity_state == GravityController.GravityState.SHIFTING:
			# predicted_speed is planar speed (velocity.slide(gravity_direction)) --
			# during a shift, velocity is almost entirely ALONG gravity_direction,
			# so it gets sliced away to near-zero and never registers here. Use
			# the actual shift speed instead while actively shifting.
			speed_ratio = clampf(
				gravity_controller.shift_speed / max(gravity_controller.max_shift_speed, 0.001),
				0.0, 1.0
			)

			# Fade out when looking away from the direction of travel --
			# the effect should only read as "you're going fast" when
			# you're actually facing where you're going.
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


# ============================================================
# WALL MOVE INDICATORS
# ============================================================
func update_wall_indicators() -> void:
	if not player:
		return

	if wall_run_indicator:
		wall_run_indicator.visible = _is_wall_run_available()

	if wall_slide_indicator:
		wall_slide_indicator.visible = _is_wall_slide_available()


## A wall run counts as available when the player isn't mid-run, still has
## runs left (Player resets the count on landing), and wall movement isn't
## disabled by being locked or in OTS mode.
func _is_wall_run_available() -> bool:
	if player.movement_locked or player.is_ots_mode:
		return false

	if player.is_wall_running:
		return false

	return player._wall_runs_used < player.max_wall_runs


## Same rules as the wall run, using the slide's own counter and limit.
func _is_wall_slide_available() -> bool:
	if player.movement_locked or player.is_ots_mode:
		return false

	if player.is_wall_sliding:
		return false

	return player._wall_slides_used < player.max_wall_slides
