class_name PlayerSlam
extends PlayerMovementModule

enum Phase { NONE, WINDUP, SLAMMING, RECOVERY }

@export_group("Slam")
@export var input_action: StringName = &"ToggleOTS"
@export var windup_time: float = 0.06
@export var slam_speed: float = 28.0
@export var slam_acceleration: float = 160.0
@export var horizontal_deceleration: float = 60.0
@export var landing_recovery_time: float = 0.12

@export_group("Platform Launch")
@export var platform_speed_multiplier: float = 2.0
@export var launch_height: float = 6.0
@export var launch_rise_time: float = 0.5
@export var launch_fall_time: float = 0.45
@export var launch_air_control: float = 0.45

var is_active := false
var phase: Phase = Phase.NONE
var timer: float = 0.0


func can_start() -> bool:
	return (
		not player.is_on_floor()
		and not is_active
		and not player.movement_locked
		and not player.slide.is_active
		and not player.dive.is_active
		and not player.ledge.is_active()
		and player.wall.state == PlayerWallMovement.WallState.NONE
	)


func start() -> void:
	player.hover.cancel()

	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0
	player.coyote_timer = 0.0

	is_active = true

	if windup_time > 0.0:
		set_phase(Phase.WINDUP, windup_time)
	else:
		set_phase(Phase.SLAMMING)


func cancel() -> void:
	is_active = false
	phase = Phase.NONE
	timer = 0.0


func set_phase(new_phase: Phase, duration: float = 0.0) -> void:
	phase = new_phase
	timer = duration

func update(delta: float) -> void:
	if not is_active:
		if Input.is_action_just_pressed(input_action) and can_start():
			start()
		return

	if player.movement_locked:
		cancel()
		return

	match phase:
		Phase.WINDUP:
			timer -= delta
			if player.is_on_floor():
				land()
			elif timer <= 0.0:
				set_phase(Phase.SLAMMING)
		Phase.SLAMMING:
			if player.is_on_floor():
				land()
		Phase.RECOVERY:
			timer -= delta
			if timer <= 0.0:
				cancel()


func land() -> void:
	var tk: TelekinesisController = player.telekinesis_controller

	if tk != null and tk.slam_boost_platform(platform_speed_multiplier):
		launch()
		return

	if landing_recovery_time > 0.0:
		set_phase(Phase.RECOVERY, landing_recovery_time)
	else:
		cancel()


func launch() -> void:
	cancel()

	player.start_jump(Player.JumpKind.SLAM)
	player.jumps_used = 1

	player.jump_buffer_timer = 0.0
	player.coyote_timer = 0.0

	var anim: Node = player.animation_controller
	if anim and anim.has_method("play_launch"):
		anim.play_launch()

func apply_gravity(delta: float) -> bool:
	if phase != Phase.WINDUP and phase != Phase.SLAMMING:
		return false

	var up: Vector3 = player.up_direction
	var projected: Vector3 = player.velocity + player.pending_acceleration * delta
	var target: Vector3 = Vector3.ZERO if phase == Phase.WINDUP else -up * slam_speed

	player.add_acceleration(Player.acceleration_toward(
		projected.project(up),
		target,
		slam_acceleration,
		delta
	))
	return true

func get_target_motion() -> Dictionary:
	var forward: Vector3 = (-player.character_model.global_basis.z).slide(player.up_direction).normalized()
	return {
		"target_velocity": Vector3.ZERO,
		"target_forward": forward
	}
