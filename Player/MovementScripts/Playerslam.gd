class_name PlayerSlam
extends PlayerMovementModule

## Press ToggleOTS (E) in midair to slam straight down.
##
## A short hang, then a hard drop that kills horizontal speed. How hard it
## hits depends on how far the player dropped (see "Slam Strength"):
##
## - Landing on a tkplatform fires the platform upward by an amount that
##   scales with the drop. Once the platform STOPS, it launches the player
##   (if they're still standing on it) to a height that scales the same way.
## - A slam from barely above the platform does next to nothing.
## - Landing on anything else just ends in a brief recovery.

enum Phase { NONE, WINDUP, SLAMMING, RECOVERY }

@export_group("Slam")
## Input action that starts the slam while airborne.
@export var input_action: StringName = &"ToggleOTS"
## Hang time before the drop (seconds). 0 = drop immediately.
@export var windup_time: float = 0.06
## Downward speed of the slam (units/sec).
@export var slam_speed: float = 28.0
## How hard vertical speed is pulled toward slam_speed (units/sec^2).
## Also brakes the player to a stop during the wind-up.
@export var slam_acceleration: float = 160.0
## How hard horizontal speed is killed while slamming (units/sec^2).
@export var horizontal_deceleration: float = 60.0
## Seconds the player is rooted after a slam that did NOT launch anything.
## 0 = no recovery.
@export var landing_recovery_time: float = 0.12

@export_group("Slam Strength")
## Strength comes from the drop: how far above the landing spot the slam
## started (the highest point reached during the slam). At or below
## min_drop the strength is 0 and a platform is left alone.
@export var min_drop: float = 1.0
## Drop at which the slam reaches full strength (the max values below).
@export var full_drop: float = 7.0
## Shapes how strength builds between min_drop and full_drop.
## 1 = linear. Above 1 = small drops stay weak for longer.
@export var strength_curve_power: float = 1.0

@export_group("Platform Launch")
## Multiplier on TelekinesisController.platform_rise_speed for a slammed
## platform (2.0 = double speed).
@export var platform_speed_multiplier: float = 2.0
## How far a full-strength slam raises the platform. The platform's own
## max height still caps it.
@export var max_platform_rise: float = 6.0
## Height a full-strength slam launches the player to once the platform
## has stopped. Same jump maths as the normal jump, so it's the real peak.
@export var max_launch_height: float = 6.0
## Rise/fall time of a FULL-strength launch. Weaker launches scale these
## down so gravity stays the same (small hop, not a slow float).
@export var launch_rise_time: float = 0.5
@export var launch_fall_time: float = 0.45
@export var launch_air_control: float = 0.45

## Launches below this height are skipped entirely.
const MIN_LAUNCH_HEIGHT := 0.1
## How long the player can be off the floor (flicker) while waiting for the
## platform to stop before the pending launch is dropped (jumped / walked off).
const PLATFORM_FLOOR_GRACE := 0.15

var is_active := false
var phase: Phase = Phase.NONE
var timer: float = 0.0

var _peak_height: float = 0.0

# Launch waiting on a platform to stop moving.
var _pending_platform: Node3D = null
var _pending_launch_height: float = 0.0
var _platform_arrived := false
var _floor_lost_time: float = 0.0

# Height of the launch currently being started (read by get_launch_profile).
var _launch_height: float = 0.0


func setup(target: Player) -> void:
	super(target)

	var tk: TelekinesisController = player.telekinesis_controller
	if tk:
		tk.platform_boost_finished.connect(_on_platform_boost_finished)


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
	# A new slam replaces any launch still waiting on a platform.
	clear_pending()

	# A hover in progress is replaced by the slam.
	player.hover.cancel()

	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0
	player.coyote_timer = 0.0

	is_active = true
	_peak_height = _get_height()

	if windup_time > 0.0:
		set_phase(Phase.WINDUP, windup_time)
	else:
		set_phase(Phase.SLAMMING)


## Ends the slam AND drops any pending platform launch.
func cancel() -> void:
	is_active = false
	phase = Phase.NONE
	timer = 0.0
	clear_pending()


func clear_pending() -> void:
	_pending_platform = null
	_pending_launch_height = 0.0
	_platform_arrived = false
	_floor_lost_time = 0.0


func set_phase(new_phase: Phase, duration: float = 0.0) -> void:
	phase = new_phase
	timer = duration


func _get_height() -> float:
	return player.global_position.dot(player.up_direction)


## 0..1 from how far the slam dropped.
func get_strength(drop: float) -> float:
	var span_end: float = maxf(full_drop, min_drop + 0.001)
	var t: float = clampf(inverse_lerp(min_drop, span_end, drop), 0.0, 1.0)
	return pow(t, maxf(strength_curve_power, 0.001))


## Called from Player._physics_process before move_and_slide(), so
## is_on_floor() and the slide collisions are from the previous frame --
## which is what slam_boost_platform() needs to see what was landed on.
func update(delta: float) -> void:
	if _pending_platform != null:
		_update_pending_launch(delta)

	if not is_active:
		if Input.is_action_just_pressed(input_action) and can_start():
			start()
		return

	if player.movement_locked:
		cancel()
		return

	if phase == Phase.WINDUP or phase == Phase.SLAMMING:
		_peak_height = maxf(_peak_height, _get_height())

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
	var drop: float = _peak_height - _get_height()
	var strength: float = get_strength(drop)
	var tk: TelekinesisController = player.telekinesis_controller

	if strength > 0.0 and tk != null:
		var platform: Node3D = tk.slam_boost_platform(
			platform_speed_multiplier,
			max_platform_rise * strength
		)

		if platform != null:
			# The platform does the launching, once it stops. No recovery:
			# the player keeps control, but has to still be standing on it.
			cancel()
			_pending_platform = platform
			_pending_launch_height = max_launch_height * strength
			return

	if landing_recovery_time > 0.0:
		set_phase(Phase.RECOVERY, landing_recovery_time)
	else:
		cancel()


func _on_platform_boost_finished(platform: Node3D) -> void:
	if platform != null and platform == _pending_platform:
		_platform_arrived = true


func _update_pending_launch(delta: float) -> void:
	var tk: TelekinesisController = player.telekinesis_controller

	if not is_instance_valid(_pending_platform) or tk == null or player.movement_locked:
		clear_pending()
		return

	# Jumped or walked off while the platform was rising: no launch.
	if player.is_on_floor():
		_floor_lost_time = 0.0
	else:
		_floor_lost_time += delta
		if _floor_lost_time > PLATFORM_FLOOR_GRACE:
			clear_pending()
			return

	if not _platform_arrived:
		return

	# The platform has stopped moving.
	if tk.is_standing_on_platform(_pending_platform):
		launch(_pending_launch_height)
	else:
		clear_pending()


func launch(height: float) -> void:
	cancel()

	if height < MIN_LAUNCH_HEIGHT:
		return

	_launch_height = height

	player.start_jump(Player.JumpKind.SLAM)
	player.jumps_used = 1

	# Without these, a buffered press or the coyote window from being on the
	# floor would start a normal jump on top of the launch.
	player.jump_buffer_timer = 0.0
	player.coyote_timer = 0.0

	var anim: Node = player.animation_controller
	if anim and anim.has_method("play_launch"):
		anim.play_launch()


## Jump profile for the launch (read by Player._set_jump_profile). Rise and
## fall times scale with sqrt(height) so gravity matches a full launch.
func get_launch_profile() -> Dictionary:
	var ratio: float = sqrt(clampf(_launch_height / maxf(max_launch_height, 0.001), 0.0, 1.0))
	return {
		"height": _launch_height,
		"rise_time": launch_rise_time * ratio,
		"fall_time": launch_fall_time * ratio
	}


## Vertical motion during the wind-up (brake to a hang) and the drop.
## Returns true while it owns gravity; recovery uses normal gravity.
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


## Horizontal motion: no steering, just bleed speed off and keep facing.
func get_target_motion() -> Dictionary:
	var forward: Vector3 = (-player.character_model.global_basis.z).slide(player.up_direction).normalized()
	return {
		"target_velocity": Vector3.ZERO,
		"target_forward": forward
	}
