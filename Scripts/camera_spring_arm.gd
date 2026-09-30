extends SpringArm3D

@export_group("Input")
@export var mouse_sensitivity: float = 0.005
@export var min_pitch_deg: float = -80.0
@export var max_pitch_deg: float = 60.0

var yaw_input: float = 0.0
var pitch_input: float = 0.0
var camera_moved: bool = false
var look_forward: Vector3 = Vector3.FORWARD
var pitch_angle: float = 0.0
var last_up: Vector3 = Vector3.UP

@export_group("References")
@export var camera_3D: Node3D
@export var aim_pivot: Node3D
@export var mouse_aim: Node3D = null

var player: Player
var gravity_controller: GravityController

@export_group("Shifting Camera Focus")
@export var focus_pivot_transition_time: float = 0.2

var focus_pivot_blend_weight: float = 0.0

@export_group("Aiming")
@export var aim_distance: float = 500.0
@export var boresight_lag_time: float = 0.05
@export var boresight_jitter_smoothing_time: float = 0.12

var frozen_direction: Vector3 = Vector3.FORWARD
var is_mouse_aim_frozen: bool = false
var smoothed_boresight_dir: Vector3 = Vector3.FORWARD
var smoothed_boresight_dir_stage2: Vector3 = Vector3.FORWARD

@export_group("Up Vector Smoothing")
@export var up_smoothing_time: float = 0.6

var smoothed_up: Vector3 = Vector3.UP

@export_group("Root Offset")
@export var pivot_position_smoothing_time: float = 0.03
@export var walk_lag_distance: float = 0.0
@export var walk_lag_smoothing_time: float = 0.2

var smoothed_lag_offset: Vector3 = Vector3.ZERO
var smoothed_pivot_position: Vector3 = Vector3.ZERO

@export_group("Ground Confirmation")
@export var ground_state_confirm_time: float = 0.06

var grounded_confirm_timer: float = 0.0
var airborne_confirm_timer: float = 0.0
var confirmed_grounded: bool = true

@export_group("Walk / Run Blend")
@export var speed_blend_smoothing_time: float = 0.6
@export var running_camera_pullback: float = 0.8

var speed_blend_weight: float = 0.0

@export_subgroup("Camera Profiles/Run (Grounded)")
@export var grounded_spring_length: float = 1.2
@export var grounded_shoulder_offset: Vector3 = Vector3(0.0, 0.0, 0.0)
@export var grounded_fov: float = 75.0

@export_subgroup("Camera Profiles/Wall")
@export var wall_spring_length: float = 1.2
@export var wall_shoulder_offset: Vector3 = Vector3(0.4, 0.0, 0.0)
@export var wall_fov: float = 75.0

@export_subgroup("Camera Profiles/Shifting")
@export var shifting_spring_length: float = 3.0
@export var shifting_shoulder_offset: Vector3 = Vector3.ZERO
@export var shifting_fov: float = 90.0

var smoothed_shoulder_offset: Vector3 = Vector3.ZERO

@export_subgroup("Pitch Pivot/Grounded")
@export var grounded_look_down_height_range: float = 0.65
@export var grounded_look_down_back_range: float = 0.45
@export var grounded_look_up_height_range: float = 0.26
@export var grounded_look_up_back_range: float = 0.2
@export var grounded_pitch_run_multiplier: float = 1.3

@export_subgroup("Pitch Pivot/Wall")
@export var wall_look_down_height_range: float = 0.5
@export var wall_look_down_back_range: float = 0.35
@export var wall_look_up_height_range: float = 0.2
@export var wall_look_up_back_range: float = 0.15

@export_subgroup("Pitch Pivot/Shifting")
@export var shifting_look_down_height_range: float = 0.0
@export var shifting_look_down_back_range: float = 0.0
@export var shifting_look_up_height_range: float = 0.0
@export var shifting_look_up_back_range: float = 0.0

@export_group("OTS Camera")
@export var ots_transition_time: float = 0.25

var ots_blend_weight: float = 0.0

@export_subgroup("Explore Mode")
@export var ots_explore_spring_length: float = 1.0
@export var ots_explore_shoulder_offset: Vector3 = Vector3(0.4, 0.1, 0.0)
@export var ots_explore_fov: float = 65.0
@export var ots_explore_mouse_sensitivity_multiplier: float = 0.5

@export_subgroup("Explore Mode/Pitch Pivot")
@export var ots_look_down_height_range: float = 0.5
@export var ots_look_down_back_range: float = 0.35
@export var ots_look_up_height_range: float = 0.2
@export var ots_look_up_back_range: float = 0.15

var ots_explore_blend_weight: float = 0.0

@export_group("Combat Aim")
@export var combat_zoom_fov: float = 40.0
@export var combat_zoom_spring_length: float = 1.0
@export var combat_zoom_transition_time: float = 0.15

var is_combat_aiming: bool = false

var combat_zoom_blend_weight: float = 0.0

var combat_assist_target: Node3D = null
@export var combat_assist_max_angle_deg: float = 8.0
@export var combat_assist_release_angle_deg: float = 10.0
@export var combat_assist_max_speed_deg: float = 25.0

var assist_lock_target: Node3D = null

@export_group("Panini Projection")
@export var panini_rect: ColorRect
@export var panini_grounded_amount: float = 0.5

var smoothed_panini_amount: float = 0.0


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	player = get_parent()
	gravity_controller = player.get_node("GravityController")

	add_excluded_object(player.get_rid())

	look_forward = -global_basis.z
	pitch_angle = 0.0
	last_up = Vector3.UP
	smoothed_up = Vector3.UP
	spring_length = shifting_spring_length

	smoothed_pivot_position = global_position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var sensitivity: float = mouse_sensitivity
		if player and player.is_ots_mode:
			sensitivity *= ots_explore_mouse_sensitivity_multiplier

		yaw_input -= event.relative.x * sensitivity
		pitch_input -= event.relative.y * sensitivity


func get_boresight_pos() -> Vector3:
	if player:
		return (smoothed_boresight_dir_stage2 * aim_distance) + player.get_body_center()
	if camera_3D:
		return (-camera_3D.global_transform.basis.z * aim_distance) + camera_3D.global_position
	return (-global_transform.basis.z * aim_distance) + global_position


func get_mouse_aim_pos() -> Vector3:
	var x: Vector3
	if is_mouse_aim_frozen:
		if mouse_aim:
			x = mouse_aim.global_position + (frozen_direction * aim_distance)
		elif camera_3D:
			x = camera_3D.global_position + (-camera_3D.global_transform.basis.z * aim_distance)
		else:
			x = global_position + (-global_transform.basis.z * aim_distance)
	else:
		if mouse_aim:
			x = mouse_aim.global_position + (-mouse_aim.global_transform.basis.z * aim_distance)
		elif camera_3D:
			x = camera_3D.global_position + (-camera_3D.global_transform.basis.z * aim_distance)
		else:
			x = global_position + (-global_transform.basis.z * aim_distance)
	return x


func _is_shifting_or_levitating() -> bool:
	return gravity_controller \
		and (gravity_controller.gravity_state == GravityController.GravityState.LEVITATING \
			or gravity_controller.gravity_state == GravityController.GravityState.SHIFTING)


func update_pivot_position(delta: float) -> void:
	var focus_target_weight: float = 1.0 if (_is_shifting_or_levitating() and player != null) else 0.0
	var focus_blend_speed: float = 1.0 - exp(-delta / max(focus_pivot_transition_time, 0.001))
	focus_pivot_blend_weight = move_toward(focus_pivot_blend_weight, focus_target_weight, focus_blend_speed)

	var player_anchor: Vector3 = player.get_camera_anchor()
	var shift_anchor: Vector3 = player.get_body_center()

	var target_position: Vector3 = player_anchor.lerp(shift_anchor, focus_pivot_blend_weight)

	var target_lag: Vector3 = Vector3.ZERO
	if player:
		var planar_velocity: Vector3 = player.velocity
		if gravity_controller:
			planar_velocity = planar_velocity.slide(gravity_controller.gravity_direction)

		if planar_velocity.length_squared() > 0.01:
			target_lag = -planar_velocity.normalized() * walk_lag_distance * (1.0 - focus_pivot_blend_weight)

	var lag_weight: float = 1.0 - exp(-delta / max(walk_lag_smoothing_time, 0.001))
	smoothed_lag_offset = smoothed_lag_offset.lerp(target_lag, lag_weight)

	target_position += smoothed_lag_offset

	var weight: float = 1.0 - exp(-delta / max(pivot_position_smoothing_time, 0.001))
	smoothed_pivot_position = smoothed_pivot_position.lerp(target_position, weight)
	global_position = smoothed_pivot_position


func update_look(delta: float) -> void:
	var target_up: Vector3 = Vector3.UP
	if gravity_controller:
		target_up = -gravity_controller.gravity_direction

	if smoothed_up.dot(target_up) < 0.99999:
		var weight: float = 1.0 - exp(-delta / max(up_smoothing_time, 0.001))
		var full_align: Quaternion = _shortest_arc(smoothed_up, target_up)
		var step_align: Quaternion = Quaternion.IDENTITY.slerp(full_align, weight)
		smoothed_up = (step_align * smoothed_up).normalized()
	else:
		smoothed_up = target_up

	var up: Vector3 = smoothed_up

	var flat_forward: Vector3 = look_forward.slide(up)
	if flat_forward.length_squared() < 0.0001:
		flat_forward = (-global_basis.x).slide(up)
	flat_forward = flat_forward.normalized()

	if yaw_input != 0.0:
		flat_forward = flat_forward.rotated(up, yaw_input).normalized()

	look_forward = flat_forward
	last_up = up

	if pitch_input != 0.0:
		pitch_angle = clamp(
			pitch_angle + pitch_input,
			deg_to_rad(min_pitch_deg),
			deg_to_rad(max_pitch_deg)
		)

	yaw_input = 0.0
	pitch_input = 0.0

	_apply_combat_assist(delta, up)
	flat_forward = look_forward

	if _is_shifting_or_levitating():
		var right: Vector3 = flat_forward.cross(up).normalized()
		var final_forward: Vector3 = flat_forward.rotated(right, pitch_angle).normalized()
		global_basis = Basis.looking_at(final_forward, up)

		if camera_3D:
			camera_3D.rotation = Vector3.ZERO
	else:
		global_basis = Basis.looking_at(flat_forward, up)

		if camera_3D:
			camera_3D.rotation = Vector3(pitch_angle, 0.0, 0.0)

	if aim_pivot:
		aim_pivot.global_basis = global_basis

	yaw_input = 0.0
	pitch_input = 0.0

	_update_boresight_dir(delta)
	_update_camera_distance(delta)
	_update_pitch_pivot()
	_update_panini(delta)


func _update_boresight_dir(delta: float) -> void:
	var target_dir: Vector3
	var snap_instant := false

	if gravity_controller \
	and gravity_controller.gravity_state == GravityController.GravityState.SHIFTING \
	and player and player.velocity.length_squared() > 0.01:
		target_dir = player.velocity.normalized()
		snap_instant = true
	elif camera_3D:
		target_dir = -camera_3D.global_transform.basis.z
	else:
		target_dir = -global_basis.z

	if snap_instant:
		smoothed_boresight_dir = target_dir
		smoothed_boresight_dir_stage2 = target_dir
	else:
		var weight1: float = 1.0 - exp(-delta / max(boresight_lag_time, 0.001))
		smoothed_boresight_dir = smoothed_boresight_dir.slerp(target_dir, weight1).normalized()

		var weight2: float = 1.0 - exp(-delta / max(boresight_jitter_smoothing_time, 0.001))
		smoothed_boresight_dir_stage2 = smoothed_boresight_dir_stage2.slerp(smoothed_boresight_dir, weight2).normalized()


func _shortest_arc(from_dir: Vector3, to_dir: Vector3) -> Quaternion:
	from_dir = from_dir.normalized()
	to_dir = to_dir.normalized()
	var dot_val := from_dir.dot(to_dir)

	if dot_val > 0.99999:
		return Quaternion.IDENTITY
	if dot_val < -0.99999:
		var axis := from_dir.cross(Vector3.RIGHT)
		if axis.length_squared() < 0.001:
			axis = from_dir.cross(Vector3.UP)
		return Quaternion(axis.normalized(), PI)

	var axis2 := from_dir.cross(to_dir).normalized()
	var angle := acos(clamp(dot_val, -1.0, 1.0))
	return Quaternion(axis2, angle)


func _update_camera_distance(delta: float) -> void:
	var is_grounded: bool = gravity_controller \
		and gravity_controller.gravity_state == GravityController.GravityState.GROUNDED \
		and player and player.is_on_floor()
	var is_wall: bool = gravity_controller and gravity_controller.gravity_state == GravityController.GravityState.WALL

	if is_grounded and player:
		var planar_speed: float = player.velocity.slide(gravity_controller.gravity_direction).length()
		var speed_target: float = clamp(planar_speed / max(player.run_speed, 0.001), 0.0, 1.0)

		var speed_weight: float = 1.0 - exp(-delta / max(speed_blend_smoothing_time, 0.001))
		speed_blend_weight = move_toward(speed_blend_weight, speed_target, speed_weight)

	var grounded_length: float = grounded_spring_length
	var grounded_offset: Vector3 = grounded_shoulder_offset
	var grounded_fov_value: float = grounded_fov

	var target_weight: float = 1.0 if (is_grounded or is_wall) else 0.0
	var blend_speed: float = 1.0 - exp(-delta / max(ots_transition_time, 0.001))
	ots_blend_weight = move_toward(ots_blend_weight, target_weight, blend_speed)

	var ots_length: float = wall_spring_length if is_wall else grounded_length
	var ots_offset: Vector3 = wall_shoulder_offset if is_wall else grounded_offset
	var ots_fov: float = wall_fov if is_wall else grounded_fov_value

	var target_length: float = lerp(shifting_spring_length, ots_length, ots_blend_weight)
	var target_offset: Vector3 = shifting_shoulder_offset.lerp(ots_offset, ots_blend_weight)
	var target_fov: float = lerp(shifting_fov, ots_fov, ots_blend_weight)

	if player and player.is_running:
		target_offset.z += running_camera_pullback

	var explore_target_weight: float = 1.0 if (player and player.is_ots_mode) else 0.0
	ots_explore_blend_weight = move_toward(ots_explore_blend_weight, explore_target_weight, blend_speed)

	target_length = lerp(target_length, ots_explore_spring_length, ots_explore_blend_weight)
	target_offset = target_offset.lerp(ots_explore_shoulder_offset, ots_explore_blend_weight)
	target_fov = lerp(target_fov, ots_explore_fov, ots_explore_blend_weight)

	var combat_target_weight: float = 1.0 if is_combat_aiming else 0.0
	var combat_blend_speed: float = 1.0 - exp(-delta / max(combat_zoom_transition_time, 0.001))
	combat_zoom_blend_weight = move_toward(combat_zoom_blend_weight, combat_target_weight, combat_blend_speed)

	target_length = lerp(target_length, combat_zoom_spring_length, combat_zoom_blend_weight)
	target_fov = lerp(target_fov, combat_zoom_fov, combat_zoom_blend_weight)

	spring_length = lerp(spring_length, target_length, blend_speed)
	smoothed_shoulder_offset = smoothed_shoulder_offset.lerp(target_offset, blend_speed)

	if camera_3D:
		camera_3D.position = smoothed_shoulder_offset
		camera_3D.fov = lerp(camera_3D.fov, target_fov, blend_speed)


func _get_subject_world_pos() -> Vector3:
	if _is_shifting_or_levitating() and player:
		return player.get_body_center()
	if player:
		return player.get_camera_anchor()
	return global_position


func _update_pitch_pivot() -> void:
	if not camera_3D:
		return

	var down_height_range: float
	var down_back_range: float
	var up_height_range: float
	var up_back_range: float
	var run_multiplier: float = 1.0

	if player and player.is_ots_mode:
		down_height_range = ots_look_down_height_range
		down_back_range = ots_look_down_back_range
		up_height_range = ots_look_up_height_range
		up_back_range = ots_look_up_back_range
	elif _is_shifting_or_levitating():
		down_height_range = shifting_look_down_height_range
		down_back_range = shifting_look_down_back_range
		up_height_range = shifting_look_up_height_range
		up_back_range = shifting_look_up_back_range
	elif gravity_controller and gravity_controller.gravity_state == GravityController.GravityState.WALL:
		down_height_range = wall_look_down_height_range
		down_back_range = wall_look_down_back_range
		up_height_range = wall_look_up_height_range
		up_back_range = wall_look_up_back_range
	else:
		down_height_range = grounded_look_down_height_range
		down_back_range = grounded_look_down_back_range
		up_height_range = grounded_look_up_height_range
		up_back_range = grounded_look_up_back_range
		run_multiplier = grounded_pitch_run_multiplier

	var pitch_ratio: float = 0.0
	if pitch_angle >= 0.0:
		pitch_ratio = pitch_angle / max(deg_to_rad(max_pitch_deg), 0.0001)
	else:
		pitch_ratio = pitch_angle / max(deg_to_rad(abs(min_pitch_deg)), 0.0001)
	pitch_ratio = clamp(pitch_ratio, -1.0, 1.0)

	var distance_scale: float = lerp(1.0, run_multiplier, speed_blend_weight)

	var height_offset: float
	var back_offset: float

	if pitch_ratio < 0.0:
		height_offset = -pitch_ratio * down_height_range * distance_scale
		back_offset = -pitch_ratio * down_back_range * distance_scale
	else:
		height_offset = -pitch_ratio * up_height_range * distance_scale
		back_offset = pitch_ratio * up_back_range * distance_scale

	camera_3D.position += Vector3(0.0, height_offset, back_offset)


func _update_panini(delta: float) -> void:
	if not panini_rect or not camera_3D:
		return

	var mat: ShaderMaterial = panini_rect.material as ShaderMaterial
	if not mat:
		return

	smoothed_panini_amount = panini_grounded_amount * ots_blend_weight
	mat.set_shader_parameter("panini_amount", smoothed_panini_amount)


func _find_collision_shape(node: Node) -> CollisionShape3D:
	for child in node.get_children():
		if child is CollisionShape3D:
			return child
		var nested := _find_collision_shape(child)
		if nested:
			return nested
	return null


func _get_assist_point(target: Node3D) -> Vector3:
	var marker := target.find_child("AimPoint", true, false) as Node3D
	if marker:
		return marker.global_position

	var head: Node = target if target.name == &"NPCHead" else target.find_child("NPCHead", true, false)
	if head:
		var shape := _find_collision_shape(head)
		if shape:
			return shape.global_position

	return target.global_position

func _assist_target_alive(target: Node3D) -> bool:
	return is_instance_valid(target)


func _apply_combat_assist(delta: float, up: Vector3) -> void:
	if combat_assist_max_speed_deg <= 0.0:
		return

	if not is_combat_aiming or not _assist_target_alive(assist_lock_target):
		assist_lock_target = null

	var right: Vector3 = look_forward.cross(up)
	if right.length_squared() < 0.0001:
		return
	right = right.normalized()

	var current_dir: Vector3 = look_forward.rotated(right, pitch_angle).normalized()
	var origin: Vector3 = camera_3D.global_position if camera_3D else global_position

	if assist_lock_target == null:
		if not is_combat_aiming or not _assist_target_alive(combat_assist_target):
			return
		var to_candidate: Vector3 = _get_assist_point(combat_assist_target) - origin
		if to_candidate.length_squared() < 0.0001:
			return
		if rad_to_deg(current_dir.angle_to(to_candidate.normalized())) > combat_assist_max_angle_deg:
			return
		assist_lock_target = combat_assist_target

	var to_target: Vector3 = _get_assist_point(assist_lock_target) - origin
	if to_target.length_squared() < 0.0001:
		return
	var target_dir: Vector3 = to_target.normalized()
	var angle: float = current_dir.angle_to(target_dir)

	if rad_to_deg(angle) > combat_assist_release_angle_deg:
		assist_lock_target = null
		return

	var max_step: float = deg_to_rad(combat_assist_max_speed_deg) * delta
	var t: float = 1.0 if angle <= max_step else max_step / angle
	var new_dir: Vector3 = current_dir.slerp(target_dir, t).normalized()

	var new_flat: Vector3 = new_dir.slide(up)
	if new_flat.length_squared() > 0.0001:
		look_forward = new_flat.normalized()

	pitch_angle = clamp(
		asin(clampf(new_dir.dot(up), -1.0, 1.0)),
		deg_to_rad(min_pitch_deg),
		deg_to_rad(max_pitch_deg)
	)
