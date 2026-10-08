class_name PlayerWallMovement
extends PlayerMovementModule

enum WallState { NONE, RUNNING, SLIDING, CLIMBING }

@export_group("Wall Movement")
@export var check_distance: float = 0.8
@export var run_speed: float = 6.0
@export var run_min_speed: float = 4.0
@export var run_max_time: float = 1.6
@export var run_arc_height: float = 0.6
@export_range(0.1, 0.9) var run_apex_fraction: float = 0.4
@export var slide_speed: float = 2.0
@export var slide_turn_speed: float = 16.0
@export var kick_turn_speed: float = 8
@export var kick_turn_back_angle_deg: float = 25.0
@export var wall_kick_turn_wait_timer: float = 0.2
@export var jump_away_speed: float = 6.5
@export var jump_air_control: float = 0.2
@export var regrab_delay: float = 0.25
@export_range(0, 10, 1, "or_greater") var max_moves: int = 1

@export_group("Wall Run Placement")
@export var run_wall_gap: float = 0.03
@export var run_attach_gain: float = 12.0
@export var run_attach_max_speed: float = 8.0

const RUN_MAX_APPROACH := 0.64
const SLIDE_MIN_APPROACH := 0.3
const STICK_SPEED := 1.0
const RUN_ACCELERATION := 40.0
const VERTICAL_ACCELERATION := 30.0
const KICK_MIN_SPEED := 0.5

var state: WallState = WallState.NONE
var is_wall_running := false
var is_wall_sliding := false
var is_wall_climbing := false
var side: int = 0
var wall_normal: Vector3 = Vector3.ZERO
var run_direction: Vector3 = Vector3.ZERO
var current_run_speed: float = 0.0
var run_time_left: float = 0.0
var run_elapsed: float = 0.0
var lockout_timer: float = 0.0
var kick_facing := false
var kick_normal: Vector3 = Vector3.ZERO
var kick_launch_velocity: Vector3 = Vector3.ZERO
var kick_turn_wait_left: float = 0.0
var moves_used: int = 0
var gap: float = 0.0


func update(delta: float) -> void:

	lockout_timer = maxf(lockout_timer - delta, 0.0)

	if kick_facing:
		update_kick_facing()

	if player.is_on_floor() or player.movement_locked or player.is_ots_mode:
		end_wall_movement(false)
		if player.is_on_floor():
			run_time_left = run_max_time
			moves_used = 0
		return

	match state:
		WallState.RUNNING:
			update_run(delta)
		WallState.SLIDING:
			update_slide()
		WallState.CLIMBING:
			player.dive.update_wall_climb(delta)
		WallState.NONE:
			if player.dive.try_start_wall_climb():
				return

			if lockout_timer <= 0.0 and not player.dive.is_active and not player.slam.is_active and not try_start_run():
				try_start_slide()


func get_run_vertical_speed() -> float:
	var total: float = maxf(run_max_time, 0.01)
	var apex_time: float = maxf(total * run_apex_fraction, 0.01)
	var t: float = clampf(run_elapsed, 0.0, total)
	var rise_speed: float = 2.0 * run_arc_height / apex_time
	var arc_gravity: float = 2.0 * run_arc_height / (apex_time * apex_time)
	return rise_speed - arc_gravity * t


func try_start_run() -> bool:
	if not player.is_running or moves_used >= max_moves:
		return false

	var planar: Vector3 = player.velocity.slide(player.up_direction)
	if planar.length() < run_min_speed:
		return false

	var heading: Vector3 = planar.normalized()
	var right: Vector3 = heading.cross(player.up_direction)
	var center: Vector3 = player.get_body_center()

	var best: Dictionary = {}
	var best_distance: float = INF
	var candidates: Array[Dictionary] = [probe_wall(right), probe_wall(-right)]

	for hit in candidates:
		if hit.is_empty():
			continue

		var normal: Vector3 = hit["normal"]
		if absf(heading.dot(normal)) > RUN_MAX_APPROACH:
			continue

		var distance: float = center.distance_to(hit["position"])
		if distance < best_distance:
			best = hit
			best_distance = distance

	if best.is_empty():
		return false

	var best_normal: Vector3 = best["normal"]
	var along: Vector3 = heading.slide(best_normal)
	if along.length_squared() < 0.0001:
		return false

	set_state(WallState.RUNNING)
	run_elapsed = 0.0

	var entry_up_speed: float = player.velocity.dot(player.up_direction)
	var arc_start_speed: float = get_run_vertical_speed()
	if entry_up_speed < arc_start_speed:
		player.add_impulse(player.up_direction * (arc_start_speed - entry_up_speed))

	moves_used += 1
	run_time_left = run_max_time
	wall_normal = best_normal
	gap = measure_wall_gap(best)
	run_direction = along.normalized()
	current_run_speed = maxf(run_speed, planar.length())
	update_side()

	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0
	return true


func try_start_slide() -> void:
	if moves_used >= max_moves:
		return

	if player.velocity.dot(player.up_direction) > 0.5:
		return

	var input_dir: Vector3 = player.get_input_direction()
	if input_dir.length_squared() == 0.0:
		return

	var hit: Dictionary = probe_wall(input_dir)
	if hit.is_empty():
		return

	var normal: Vector3 = hit["normal"]
	if -input_dir.dot(normal) < SLIDE_MIN_APPROACH:
		return

	set_state(WallState.SLIDING)
	moves_used += 1
	wall_normal = normal
	player.jump_phase = Player.JumpPhase.NONE
	player.jump_phase_timer = 0.0


func update_run(delta: float) -> void:
	run_elapsed += delta
	run_time_left -= delta

	var hit: Dictionary = probe_wall(-wall_normal)

	var keep_going: bool = (
		player.is_running
		and run_time_left > 0.0
		and not hit.is_empty()
		and player.get_planar_speed() >= run_min_speed * 0.5
	)
	if not keep_going:
		end_wall_movement(true)
		return

	wall_normal = hit["normal"]
	gap = measure_wall_gap(hit)

	var along: Vector3 = run_direction.slide(wall_normal)
	if along.length_squared() < 0.0001:
		end_wall_movement(true)
		return

	run_direction = along.normalized()
	update_side()


func update_slide() -> void:
	var hit: Dictionary = probe_wall(-wall_normal)
	var pressing_in: bool = player.get_input_direction().dot(-wall_normal) > SLIDE_MIN_APPROACH

	if hit.is_empty() or not pressing_in:
		end_wall_movement(false)
		return

	wall_normal = hit["normal"]

func try_handle_jump() -> bool:
	if state != WallState.NONE:
		start_wall_jump()
		return true

	return false


func start_wall_jump() -> void:
	kick_off(wall_normal)

func kick_off(normal: Vector3) -> void:
	var along: Vector3 = player.velocity.slide(player.up_direction).slide(normal)
	var launch: Vector3 = along + normal * jump_away_speed
	player.start_jump(Player.JumpKind.WALL, launch)

	end_wall_movement(false)
	lockout_timer = regrab_delay
	player.jump_buffer_timer = 0.0
	player.jumps_used = 1

	kick_normal = normal
	kick_launch_velocity = launch
	kick_facing = true
	kick_turn_wait_left = wall_kick_turn_wait_timer

	if player.animation_controller:
		player.animation_controller.play_wall_kick()


func end_wall_movement(with_regrab_delay: bool) -> void:
	if state == WallState.NONE:
		return

	set_state(WallState.NONE)
	side = 0

	if with_regrab_delay:
		lockout_timer = regrab_delay


func set_state(new_state: WallState) -> void:
	if new_state != WallState.NONE:
		kick_facing = false

	state = new_state
	is_wall_running = new_state == WallState.RUNNING
	is_wall_sliding = new_state == WallState.SLIDING
	is_wall_climbing = new_state == WallState.CLIMBING


func begin_climb(normal: Vector3) -> void:
	set_state(WallState.CLIMBING)
	wall_normal = normal
	side = 0


func update_side() -> void:
	var right: Vector3 = run_direction.cross(player.up_direction)
	side = 1 if right.dot(-wall_normal) > 0.0 else -1


func apply_gravity(delta: float) -> bool:
	match state:
		WallState.RUNNING:
			player.add_acceleration(Player.acceleration_toward(
				(player.velocity + player.pending_acceleration * delta).project(player.up_direction),
				player.up_direction * get_run_vertical_speed(),
				VERTICAL_ACCELERATION,
				delta
			))
			return true

		WallState.SLIDING:
			player.add_acceleration(Player.acceleration_toward(
				player.velocity.project(player.up_direction),
				-player.up_direction * slide_speed,
				VERTICAL_ACCELERATION,
				delta
			))
			return true

		WallState.CLIMBING:
			player.dive.apply_wall_climb_gravity(delta)
			return true

	return false


func get_target_motion() -> Dictionary:
	if is_wall_running:
		return {
			"target_velocity": run_direction * current_run_speed - wall_normal * get_stick_speed(),
			"target_forward": run_direction
		}

	if is_wall_climbing:
		return {
			"target_velocity": -wall_normal * STICK_SPEED + player.dive.get_wall_climb_along_velocity(),
			"target_forward": -wall_normal
		}

	return {}


func update_facing(delta: float) -> void:
	if is_wall_sliding or is_wall_climbing:
		face_wall(delta, wall_normal, slide_turn_speed)
	elif kick_facing:
		kick_turn_wait_left = maxf(kick_turn_wait_left - delta, 0.0)
		if kick_turn_wait_left > 0.0:
			return
		face_away_from_wall(delta, kick_normal, kick_turn_speed)


func update_kick_facing() -> void:
	if kick_turn_wait_left > 0.0:
		return
	var planar: Vector3 = player.velocity.slide(player.up_direction)

	if planar.length() < KICK_MIN_SPEED:
		kick_facing = false
		return

	if rad_to_deg(planar.angle_to(kick_launch_velocity)) > kick_turn_back_angle_deg:
		kick_facing = false


func face_away_from_wall(delta: float, normal: Vector3, turn_speed: float) -> void:
	var away_from_wall: Vector3 = normal.slide(player.up_direction)
	if away_from_wall.length_squared() < 0.0001:
		return

	var target_basis := Basis.looking_at(away_from_wall.normalized(), player.up_direction)
	player.model_yaw_basis = Basis(
		player.model_yaw_basis
		.get_rotation_quaternion()
		.slerp(
			target_basis.get_rotation_quaternion(),
			clampf(turn_speed * delta, 0.0, 1.0)
		)
	)


func face_wall(delta: float, normal: Vector3, turn_speed: float) -> void:
	var toward_wall: Vector3 = (-normal).slide(player.up_direction)
	if toward_wall.length_squared() < 0.0001:
		return

	var target_basis := Basis.looking_at(toward_wall.normalized(), player.up_direction)
	player.model_yaw_basis = Basis(
		player.model_yaw_basis
		.get_rotation_quaternion()
		.slerp(
			target_basis.get_rotation_quaternion(),
			clampf(turn_speed * delta, 0.0, 1.0)
		)
	)


func probe_wall(direction: Vector3) -> Dictionary:
	var from: Vector3 = player.get_body_center()
	var query := PhysicsRayQueryParameters3D.create(
		from,
		from + direction * check_distance,
		player.collision_mask,
		[player.get_rid()]
	)
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return {}

	var collider: Object = hit["collider"]
	if collider is CharacterBody3D or collider is RigidBody3D:
		if player.has_pole and player.pole.is_pole_collider(collider):
			return {}

	var surface_normal: Vector3 = hit["normal"]
	var flat: Vector3 = surface_normal.slide(player.up_direction)

	if absf(surface_normal.dot(player.up_direction)) > 0.3 or flat.length_squared() < 0.0001:
		return {}

	hit["normal"] = flat.normalized()
	return hit


func measure_wall_gap(hit: Dictionary) -> float:
	var hit_position: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var distance: float = (player.get_body_center() - hit_position).dot(normal)
	return maxf(distance - player.get_capsule_radius() - run_wall_gap, 0.0)


func get_stick_speed() -> float:
	return STICK_SPEED + minf(gap * run_attach_gain, run_attach_max_speed)
