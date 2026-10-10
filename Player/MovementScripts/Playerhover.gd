class_name PlayerHover
extends PlayerMovementModule

@export_group("Hover")
@export var fall_speed: float = 1.5
@export var vertical_acceleration: float = 30.0
@export var start_max_rise_speed: float = 0.5

@export_group("Slowdown")
@export var drift_speed: float = 1.0
@export var slowdown_time: float = 0.9
@export var extra_slowdown_per_use: float = 0.6
@export var max_slowdown_multiplier: float = 3.0
@export var acceleration: float = 50.0

@export_group("Control")
@export var control_full_speed: float = 8.0
@export_range(0.0, 1.0) var min_air_control: float = 0.08
@export_range(0.0, 1.0) var min_rotation_multiplier: float = 0.15
@export var control_curve_power: float = 1.0

const HEADING_MIN_SPEED := 0.1

var is_active := false
var uses_this_airtime: int = 0
var current_speed: float = 0.0

var _heading: Vector3 = Vector3.ZERO
var _target_direction: Vector3 = Vector3.ZERO
var _armed := false
var _control_factor: float = 1.0
var _rotation_factor: float = 1.0

func get_slowdown_multiplier() -> float:
	var extra: float = float(maxi(uses_this_airtime - 1, 0)) * extra_slowdown_per_use
	return minf(1.0 + extra, maxf(max_slowdown_multiplier, 1.0))


func cancel() -> void:
	is_active = false
	_armed = false


func end() -> void:
	is_active = false

func on_grounded() -> void:
	uses_this_airtime = 0
	_armed = false
	if is_active:
		end()


func can_start() -> bool:
	return (
		not player.is_on_floor()
		and not is_active
		and not player.movement_locked
		and not player.is_ots_mode
		and not player.slide.is_active
		and not player.ledge.is_active()
		and player.wall.state == PlayerWallMovement.WallState.NONE
		and player.velocity.dot(player.up_direction) <= start_max_rise_speed
		and not player.slam.is_active
	)


func start() -> void:
	var heading: Vector3 = player.velocity.slide(player.up_direction)
	if heading.length() < HEADING_MIN_SPEED:
		heading = (-player.character_model.global_basis.z).slide(player.up_direction)

	_heading = heading.normalized()
	_target_direction = _heading
	current_speed = player.get_planar_speed()

	is_active = true
	_armed = false
	uses_this_airtime += 1

	player.jumps_used = player.max_jumps
	player.coyote_timer = 0.0

	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0

func update(delta: float) -> void:
	if Input.is_action_just_pressed("Jump"):
		_armed = true
	if not Input.is_action_pressed("Jump"):
		_armed = false

	if is_active:
		if _should_end():
			end()
			return
	elif _armed and can_start():
		start()
	else:
		return

	_update_slowdown(delta)


func _should_end() -> bool:
	return (
		player.is_on_floor()
		or player.movement_locked
		or not Input.is_action_pressed("Jump")
		or player.wall.state != PlayerWallMovement.WallState.NONE
		or player.ledge.is_active()
	)


func _update_slowdown(delta: float) -> void:
	var planar: Vector3 = player.velocity.slide(player.up_direction)
	var speed: float = planar.length()
	var speed_ratio: float = clampf(speed / maxf(control_full_speed, 0.001), 0.0, 1.0)
	var shaped: float = pow(speed_ratio, maxf(control_curve_power, 0.001))
	_control_factor = lerpf(min_air_control, 1.0, shaped)
	_rotation_factor = lerpf(min_rotation_multiplier, 1.0, shaped)

	if speed > HEADING_MIN_SPEED:
		_heading = planar / speed

	var decayed: float = speed
	if speed > drift_speed:
		var rate: float = get_slowdown_multiplier() / maxf(slowdown_time, 0.001)
		decayed = drift_speed + (speed - drift_speed) * exp(-rate * delta)

	var input_dir: Vector3 = player.get_input_direction()
	if input_dir.length_squared() > 0.0001:
		_target_direction = input_dir
		current_speed = maxf(decayed, drift_speed)
	else:
		_target_direction = _heading
		current_speed = decayed

func get_acceleration() -> float:
	return acceleration * _control_factor

func get_rotation_multiplier() -> float:
	return _rotation_factor

func apply_gravity(delta: float) -> bool:
	if not is_active:
		return false

	var up: Vector3 = player.up_direction
	var projected: Vector3 = player.velocity + player.pending_acceleration * delta

	player.add_acceleration(Player.acceleration_toward(
		projected.project(up),
		-up * fall_speed,
		vertical_acceleration,
		delta
	))
	return true


func get_target_motion() -> Dictionary:
	return {
		"target_velocity": _target_direction * current_speed,
		"target_forward": _target_direction
	}
