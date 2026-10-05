class_name PlayerLedgeGrab
extends PlayerMovementModule

enum LedgeState { NONE, HANGING, CLIMBING }

@export_group("Ledge Grab")
@export var reach: float = 0.7
@export var wall_check_height: float = 0.9
@export var min_height: float = 1.0
@export var max_height: float = 1.8
@export var top_probe_depth: float = 0.15
@export var max_rise_speed: float = 3.0
@export var hang_drop: float = 1.5
@export var wall_gap: float = 0.05
@export var stand_inset: float = 0.15
@export var snap_time: float = 0.08
@export var min_hang_time: float = 0.15
@export var climb_time: float = 0.6
@export_range(0.05, 0.95) var climb_vertical_fraction: float = 0.65
@export var regrab_delay: float = 0.4
@export var drop_push: float = 1.5
@export_range(0.0, 1.0) var support_footprint: float = 0.9
@export var support_tolerance: float = 0.2
@export var path_check_step: float = 0.3

const MIN_TOP_NORMAL := 0.7
const STAND_LIFT := 0.03
const CLEARANCE_LIFT := 0.04

var state: LedgeState = LedgeState.NONE
var is_hanging := false
var is_climbing := false
var ledge_normal: Vector3 = Vector3.ZERO
var hang_position: Vector3 = Vector3.ZERO
var stand_position: Vector3 = Vector3.ZERO
var climb_start: Vector3 = Vector3.ZERO
var timer: float = 0.0
var lockout_timer: float = 0.0


func is_active() -> bool:
	return state != LedgeState.NONE


func cancel() -> void:
	set_state(LedgeState.NONE)


func set_state(new_state: LedgeState) -> void:
	state = new_state
	is_hanging = new_state == LedgeState.HANGING
	is_climbing = new_state == LedgeState.CLIMBING


func tick(delta: float) -> void:
	lockout_timer = maxf(lockout_timer - delta, 0.0)


func ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, player.collision_mask, [player.get_rid()])
	var hit: Dictionary = space.intersect_ray(query)

	if hit.is_empty():
		return {}

	var collider: Object = hit["collider"]
	if collider is CharacterBody3D or collider is RigidBody3D:
		return {}

	return hit


func position_clear(space: PhysicsDirectSpaceState3D, feet_position: Vector3) -> bool:
	if not player.player_collision_shape or not player.player_collision_shape.shape:
		return true

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = player.player_collision_shape.shape
	query.transform = Transform3D(
		player.global_basis.orthonormalized(),
		feet_position + player.up_direction * (Player.NORMAL_COLLISION_Y + CLEARANCE_LIFT)
	)
	query.collision_mask = player.collision_mask
	query.exclude = [player.get_rid()]

	return space.intersect_shape(query, 1).is_empty()


func stand_supported(
	space: PhysicsDirectSpaceState3D,
	target_stand_position: Vector3,
	wall_normal: Vector3
) -> bool:
	var support_reach: float = player.get_capsule_radius() * support_footprint
	var tangent: Vector3 = wall_normal.cross(player.up_direction).normalized()
	var expected_floor: Vector3 = target_stand_position - player.up_direction * STAND_LIFT

	var offsets: Array[Vector3] = [
		Vector3.ZERO,
		tangent * support_reach,
		-tangent * support_reach,
		wall_normal * support_reach,
		-wall_normal * support_reach
	]

	for offset in offsets:
		var probe: Vector3 = expected_floor + offset
		var hit: Dictionary = ray(
			space,
			probe + player.up_direction * support_tolerance,
			probe - player.up_direction * support_tolerance
		)

		if hit.is_empty():
			return false

		var hit_normal: Vector3 = hit["normal"]
		if hit_normal.dot(player.up_direction) < MIN_TOP_NORMAL:
			return false

	return true


func segment_clear(
	space: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3
) -> bool:
	var step: float = maxf(path_check_step, 0.05)
	var steps: int = maxi(ceili(from.distance_to(to) / step), 1)

	for i in range(1, steps):
		var feet_position: Vector3 = from.lerp(to, float(i) / float(steps))
		if not position_clear(space, feet_position):
			return false

	return true


func path_clear(
	space: PhysicsDirectSpaceState3D,
	from_hang_position: Vector3,
	to_stand_position: Vector3
) -> bool:
	var rise: float = (to_stand_position - from_hang_position).dot(player.up_direction)
	var mid: Vector3 = from_hang_position + player.up_direction * rise

	if not position_clear(space, mid):
		return false

	return (
		segment_clear(space, from_hang_position, mid)
		and segment_clear(space, mid, to_stand_position)
	)


func try_grab() -> bool:
	if state != LedgeState.NONE or lockout_timer > 0.0:
		return false

	if player.is_on_floor() or player.movement_locked or player.is_ots_mode:
		return false

	if player.slide.is_active or player.dive.is_active:
		return false

	if player.wall.state == PlayerWallMovement.WallState.RUNNING:
		return false

	if player.velocity.dot(player.up_direction) > max_rise_speed:
		return false

	var direction: Vector3 = player.get_input_direction()
	if direction.length_squared() < 0.0001:
		direction = player.velocity.slide(player.up_direction)
		if direction.length() < 1.0:
			return false
		direction = direction.normalized()

	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var chest: Vector3 = player.global_position + player.up_direction * wall_check_height

	var wall_hit: Dictionary = ray(space, chest, chest + direction * reach)
	if wall_hit.is_empty():
		return false

	var surface_normal: Vector3 = wall_hit["normal"]
	if absf(surface_normal.dot(player.up_direction)) > 0.3:
		return false

	var wall_normal: Vector3 = surface_normal.slide(player.up_direction)
	if wall_normal.length_squared() < 0.0001:
		return false
	wall_normal = wall_normal.normalized()

	if direction.dot(-wall_normal) < 0.5:
		return false

	var wall_position: Vector3 = wall_hit["position"]
	var probe_point: Vector3 = wall_position - wall_normal * top_probe_depth
	var top_from: Vector3 = probe_point + player.up_direction * (max_height - wall_check_height)
	var top_to: Vector3 = probe_point + player.up_direction * (min_height - wall_check_height)

	var top_hit: Dictionary = ray(space, top_from, top_to)
	if top_hit.is_empty():
		return false

	var top_normal: Vector3 = top_hit["normal"]
	if top_normal.dot(player.up_direction) < MIN_TOP_NORMAL:
		return false

	var top_position: Vector3 = top_hit["position"]
	var top_offset: float = (top_position - wall_position).dot(player.up_direction)
	var edge_point: Vector3 = wall_position + player.up_direction * top_offset
	var radius: float = player.get_capsule_radius()

	var new_hang_position: Vector3 = (
		edge_point
		+ wall_normal * (radius + wall_gap)
		- player.up_direction * hang_drop
	)
	var new_stand_position: Vector3 = (
		edge_point
		- wall_normal * (radius + stand_inset)
		+ player.up_direction * STAND_LIFT
	)

	if not stand_supported(space, new_stand_position, wall_normal):
		return false

	if not position_clear(space, new_hang_position):
		return false

	if not position_clear(space, new_stand_position):
		return false

	if not path_clear(space, new_hang_position, new_stand_position):
		return false

	player.hard_stop()

	ledge_normal = wall_normal
	hang_position = new_hang_position
	stand_position = new_stand_position
	timer = 0.0
	player.jump_buffer_timer = 0.0
	player.coyote_timer = 0.0
	set_state(LedgeState.HANGING)
	return true


func update(delta: float) -> void:
	player.velocity = Vector3.ZERO
	player.pending_acceleration = Vector3.ZERO
	timer += delta

	if player.movement_locked:
		release()
		return

	var face_basis := Basis.looking_at(-ledge_normal, player.up_direction)
	player.model_yaw_basis = Basis(
		player.model_yaw_basis
		.get_rotation_quaternion()
		.slerp(face_basis.get_rotation_quaternion(), clampf(player.rotation_speed * 2.0 * delta, 0.0, 1.0))
	)

	if state == LedgeState.HANGING:
		var weight: float = 1.0 - exp(-delta / maxf(snap_time, 0.001))
		player.global_position = player.global_position.lerp(hang_position, weight)

		if timer >= min_hang_time:
			if player.jump_buffer_timer > 0.0:
				player.jump_buffer_timer = 0.0
				timer = 0.0
				climb_start = player.global_position
				set_state(LedgeState.CLIMBING)
			elif player.get_input_direction().dot(ledge_normal) > 0.5:
				release()
	elif state == LedgeState.CLIMBING:
		update_climb()

	player.update_turn_rate(delta)
	player.apply_lean(delta)


func update_climb() -> void:
	var t: float = clampf(timer / maxf(climb_time, 0.01), 0.0, 1.0)
	var rise: float = (stand_position - climb_start).dot(player.up_direction)
	var mid: Vector3 = climb_start + player.up_direction * rise

	if t < climb_vertical_fraction:
		var vertical_t: float = t / climb_vertical_fraction
		player.global_position = climb_start.lerp(mid, smoothstep(0.0, 1.0, vertical_t))
	else:
		var horizontal_t: float = (t - climb_vertical_fraction) / maxf(1.0 - climb_vertical_fraction, 0.001)
		player.global_position = mid.lerp(stand_position, smoothstep(0.0, 1.0, horizontal_t))

	if t >= 1.0:
		finish_climb()


func finish_climb() -> void:
	player.global_position = stand_position
	set_state(LedgeState.NONE)
	lockout_timer = regrab_delay
	player.coyote_timer = player.coyote_time
	player.jumps_used = 0
	player.velocity = -player.up_direction * 2.0
	player.move_and_slide()


func release() -> void:
	set_state(LedgeState.NONE)
	lockout_timer = regrab_delay
	player.coyote_timer = 0.0
	player.jumps_used = 1
	player.velocity = ledge_normal * drop_push
