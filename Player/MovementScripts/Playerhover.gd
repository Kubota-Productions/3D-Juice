class_name PlayerHover
extends PlayerMovementModule

## Hold the Slide/Crouch key in midair to hover: the fall eases down to a
## gentle sink and horizontal speed bleeds away to a small drift.
##
## - Reusable within one airtime, but every extra use bleeds speed faster.
## - Starting a hover spends ALL remaining jumps until the player lands
##   (or wall-jumps, which gives one back like it always does).
## - Never blocks wall moves: a wall run/slide ends the hover and takes over.

@export_group("Hover")
## Downward speed while hovering (units/sec).
@export var fall_speed: float = 1.5
## How hard vertical speed is pulled toward fall_speed (units/sec^2).
## Higher = the fall is caught faster; lower = a softer ease into the float.
@export var vertical_acceleration: float = 30.0
## Hover can only start while rising slower than this (units/sec), so it
## never cuts a jump short -- it begins once the jump has topped out.
@export var start_max_rise_speed: float = 0.5

@export_group("Slowdown")
## Planar speed the hover bleeds down to. Speed above this decays
## exponentially, i.e. proportionally to how fast the player is going.
@export var drift_speed: float = 1.0
## Time constant of the slowdown (seconds). Every this many seconds, the
## speed above drift_speed shrinks to about 37% of what it was.
@export var slowdown_time: float = 0.9
## Each hover after the first in the same airtime adds this to the
## slowdown multiplier (1.0 on the first hover).
@export var extra_slowdown_per_use: float = 0.6
## Ceiling for the slowdown multiplier.
@export var max_slowdown_multiplier: float = 3.0
## Max acceleration used to steer and slow planar velocity (units/sec^2).
## Keep this high enough to follow the slowdown, or it will lag behind it.
@export var acceleration: float = 50.0

@export_group("Control")
## Planar speed at or above which the hover has full steering and turning.
## Below it, both fall off toward their minimums as the player slows down.
@export var control_full_speed: float = 8.0
## Steering acceleration multiplier at a standstill (1.0 = no loss of control).
@export_range(0.0, 1.0) var min_air_control: float = 0.08
## Turn-rate multiplier at a standstill (1.0 = turns at full speed regardless).
@export_range(0.0, 1.0) var min_rotation_multiplier: float = 0.15
## Shapes how quickly control drops off. 1 = linear with speed. Above 1 the
## hover stays responsive longer, then falls away sharply at low speed.
@export var control_curve_power: float = 1.0

## Below this planar speed the travel direction isn't trusted.
const HEADING_MIN_SPEED := 0.1

var is_active := false
## How many times hover has started since the player last touched the ground.
var uses_this_airtime: int = 0
## Planar speed hover wants this frame. Read by Player in place of the
## normal walk/run speed while hovering.
var current_speed: float = 0.0

var _heading: Vector3 = Vector3.ZERO
var _target_direction: Vector3 = Vector3.ZERO
## Slide/Crouch was pressed in midair and is still held. Lets a press made
## during the rise start the hover as soon as the player begins to fall.
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


## Called every frame the player is on the floor (from Player._update_ground_state).
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

	# Hovering uses up every jump left this airtime. The coyote timer goes
	# too, otherwise a hover started just after walking off a ledge would
	# still allow a free ground jump.
	player.jumps_used = player.max_jumps
	player.coyote_timer = 0.0

	# Hand vertical motion over to the hover (stops a rise/hang in progress).
	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0


## Called from Player._physics_process, after wall.update() so a wall move
## that starts this frame ends the hover straight away.
func update(delta: float) -> void:
	# A press in midair "arms" the hover; it starts as soon as it's allowed
	# (falling, no wall/ledge/slide in the way) while the key stays held.
	if player.crouch_slide_pressed() and not player.is_on_floor():
		_armed = true
	if not player.crouch_slide_held():
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
		or not player.crouch_slide_held()
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

	# Track where the player is actually travelling.
	if speed > HEADING_MIN_SPEED:
		_heading = planar / speed

	# Speed above the drift speed decays at a rate proportional to itself.
	# It is measured from the real velocity each frame, so bumping into
	# something just means there's less left to bleed off.
	var decayed: float = speed
	if speed > drift_speed:
		var rate: float = get_slowdown_multiplier() / maxf(slowdown_time, 0.001)
		decayed = drift_speed + (speed - drift_speed) * exp(-rate * delta)

	# Steering stays available, capped by the decaying speed. With input the
	# player can always nudge along at the drift speed; with none, they keep
	# their momentum.
	var input_dir: Vector3 = player.get_input_direction()
	if input_dir.length_squared() > 0.0001:
		_target_direction = input_dir
		current_speed = maxf(decayed, drift_speed)
	else:
		_target_direction = _heading
		current_speed = decayed

## Steering/slowing acceleration this frame. Shrinks as the player slows down.
func get_acceleration() -> float:
	return acceleration * _control_factor


## Multiplier on the model's turn speed this frame. Shrinks as the player slows down.
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
