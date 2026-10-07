class_name PlayerDive
extends PlayerMovementModule

@export_group("Dive")
@export var forward_boost: float = 7.0
@export var min_speed: float = 11.0
@export var max_speed: float = 14.0
@export var launch_up_speed: float = 4.0
@export var gravity: float = 30.0
@export var max_fall_speed: float = 22.0
@export var acceleration: float = 60.0
@export var slide_duration: float = 1.1
@export var cooldown: float = 3.0
## After a dive, jumping into a wall runs you straight up it once, this high
## and for this long (it slows to a stop at the top, then you fall).
@export var wall_climb_height: float = 1.2
@export var wall_climb_time: float = 0.35
## How head-on you have to be heading into the wall (dot product, 1 = straight in).
@export_range(0.0, 1.0) var wall_climb_min_approach: float = 0.5
@export var wall_climb_momentum_transfer: float = 0.5
@export var wall_climb_max_speed: float = 12.0

## Strong enough that the climb follows its speed curve exactly.
const WALL_CLIMB_ACCELERATION := 200.0

var is_active := false
var direction: Vector3 = Vector3.ZERO
var current_speed: float = 0.0
var used := false
var cooldown_timer: float = 0.0
var wall_climb_available := false
var climb_used := false
var climb_elapsed: float = 0.0
var climb_start_speed: float = 0.0



func cancel() -> void:
	is_active = false


func tick(delta: float) -> void:
	cooldown_timer = maxf(cooldown_timer - delta, 0.0)


func get_ready_fraction() -> float:
	if used:
		return 0.0

	if cooldown <= 0.0:
		return 1.0

	return 1.0 - clampf(cooldown_timer / cooldown, 0.0, 1.0)


func on_grounded() -> void:
	used = false
	climb_used = false
	wall_climb_available = false


func on_slide_jump() -> void:
	if player.slide.from_dive and not climb_used:
		wall_climb_available = true


## Only during the first jump (or a plain fall): once you've double jumped,
## jumps_used is 2+ and the dive is gone until you land.
func can_start() -> bool:
	return (
		not player.is_on_floor()
		and not is_active
		and not used
		and cooldown_timer <= 0.0
		and player.jumps_used <= 1
		and not player.slide.is_active
		and not player.movement_locked
		and not player.is_ots_mode
		and player.wall.state == PlayerWallMovement.WallState.NONE
		and not player.slam.is_active
	)


func start() -> void:
	var heading: Vector3 = player.velocity.slide(player.up_direction)

	if heading.length() < 1.0:
		heading = player.get_input_direction()

	if heading.length_squared() < 0.0001:
		heading = (-player.character_model.global_basis.z).slide(player.up_direction)

	if heading.length_squared() < 0.0001:
		return

	direction = heading.normalized()
	current_speed = clampf(player.get_planar_speed() + forward_boost, min_speed, max_speed)
	is_active = true
	cooldown_timer = cooldown

	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0

	var predicted_velocity: Vector3 = player.get_predicted_velocity()
	var impulse: Vector3 = direction * current_speed - predicted_velocity.slide(player.up_direction)
	impulse += player.up_direction * (launch_up_speed - predicted_velocity.dot(player.up_direction))

	player.add_impulse(impulse)

	# Diving uses up this airtime's wall runs/slides and gives one
	# straight-up wall climb instead (unless one was already used before
	# touching the ground). The climb can be wall-kicked out of.
	player.wall.moves_used = player.wall.max_moves
	used = true
	wall_climb_available = not climb_used


func land() -> void:
	var landing_direction: Vector3 = direction
	var landing_speed: float = maxf(player.slide.speed, minf(current_speed, player.get_planar_speed()))

	is_active = false

	player.slide.begin(landing_direction)
	player.slide.current_speed = landing_speed
	player.slide.current_duration = slide_duration
	player.slide.from_dive = true


func update(_delta: float) -> void:
	if is_active:
		if player.movement_locked:
			is_active = false
			return

		if touched_ground():
			land()
		return

	if player.crouch_slide_pressed() and can_start():
		start()


## Hitting ground steeper than the body's normal floor limit doesn't count as
## is_on_floor(), so the dive used to carry on down the slope until it found
## flat ground. Any surface the slide can grip ends the dive (the slide it
## lands in raises the floor angle, so it sticks to that slope).
func touched_ground() -> bool:
	if player.is_on_floor():
		return true

	var default_angle: float = player.slide.default_floor_max_angle
	var max_angle: float = maxf(default_angle, deg_to_rad(player.slide.floor_max_angle_deg))

	for i in player.get_slide_collision_count():
		var collision: KinematicCollision3D = player.get_slide_collision(i)
		var normal: Vector3 = collision.get_normal()
		if acos(clampf(normal.dot(player.up_direction), -1.0, 1.0)) > max_angle:
			continue

		# Steeper than normal floor: only a real slope counts, not the
		# corner of a flat ledge.
		var surface_normal: Vector3 = player.slide.get_slope_surface_normal(collision)
		if surface_normal == Vector3.ZERO:
			continue

		var surface_angle: float = acos(clampf(surface_normal.dot(player.up_direction), -1.0, 1.0))
		if surface_angle > default_angle and surface_angle <= max_angle:
			return true

	return false


func apply_gravity(_delta: float) -> bool:
	if not is_active:
		return false

	if player.velocity.dot(player.up_direction) > -max_fall_speed:
		player.add_acceleration(-player.up_direction * gravity)

	return true


func get_target_motion() -> Dictionary:
	return {
		"target_velocity": direction * current_speed,
		"target_forward": direction
	}


func get_wall_climb_speed() -> float:
	var total: float = maxf(wall_climb_time, 0.01)
	var remaining: float = 1.0 - clampf(climb_elapsed / total, 0.0, 1.0)
	return climb_start_speed * remaining


func get_wall_climb_along_velocity() -> Vector3:
	var total: float = maxf(wall_climb_time, 0.01)
	var remaining: float = 1.0 - clampf(climb_elapsed / total, 0.0, 1.0)
	return Vector3.ZERO


func try_start_wall_climb() -> bool:
	if not wall_climb_available or climb_used or is_active:
		return false

	var heading: Vector3 = player.get_input_direction()
	if heading.length_squared() < 0.0001:
		heading = player.velocity.slide(player.up_direction)
		if heading.length() < 1.0:
			return false
		heading = heading.normalized()

	var hit: Dictionary = player.wall.probe_wall(heading)
	if hit.is_empty():
		return false

	var normal: Vector3 = hit["normal"]
	if -heading.dot(normal) < wall_climb_min_approach:
		return false

	var predicted_velocity: Vector3 = player.get_predicted_velocity()
	var planar: Vector3 = predicted_velocity.slide(player.up_direction)
	var into_wall: float = maxf(-planar.dot(normal), 0.0)
	var base_speed: float = 2.0 * wall_climb_height / maxf(wall_climb_time, 0.01)

	wall_climb_available = false
	climb_used = true
	player.wall.begin_climb(normal)
	climb_elapsed = 0.0
	climb_start_speed = minf(
		base_speed + into_wall * wall_climb_momentum_transfer,
		maxf(wall_climb_max_speed, base_speed)
	)

	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0

	player.add_impulse(
		-planar
		- normal * PlayerWallMovement.STICK_SPEED
		+ player.up_direction * (climb_start_speed - predicted_velocity.dot(player.up_direction))
	)
	return true


func update_wall_climb(delta: float) -> void:
	climb_elapsed += delta

	if climb_elapsed >= maxf(wall_climb_time, 0.01) or player.is_on_ceiling():
		player.wall.end_wall_movement(false)
		return

	# Topped out (or the wall ended): stop climbing and keep the upward speed.
	var hit: Dictionary = player.wall.probe_wall(-player.wall.wall_normal)
	if hit.is_empty():
		player.wall.end_wall_movement(false)
		return

	player.wall.wall_normal = hit["normal"]


func apply_wall_climb_gravity(delta: float) -> void:
	var projected: Vector3 = player.velocity + player.pending_acceleration * delta

	player.add_acceleration(Player.acceleration_toward(
		projected.project(player.up_direction),
		player.up_direction * get_wall_climb_speed(),
		WALL_CLIMB_ACCELERATION,
		delta
	))
	
	var lateral: Vector3 = projected.slide(player.up_direction).slide(player.wall.wall_normal)
	player.add_acceleration(Player.acceleration_toward(
		lateral,
		Vector3.ZERO,
		WALL_CLIMB_ACCELERATION,
		delta
	))
