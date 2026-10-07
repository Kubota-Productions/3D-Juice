class_name PlayerSlide
extends PlayerMovementModule

@export_group("Slide")
@export var speed: float = 7.5
@export var end_speed: float = 3.0
@export var duration: float = 0.7
@export var acceleration: float = 40.0
@export var jump_speed: float = 10.0
@export var jump_height: float = 1.2
@export var jump_rise_time: float = 0.45
@export var jump_fall_time: float = 0.44
@export var jump_air_control: float = 0.1
@export var max_speed: float = 14.0
@export var slope_acceleration: float = 14.0
@export var slope_min_angle_deg: float = 8.0
@export var slope_full_angle_deg: float = 35.0
@export_range(0.0, 89.0) var floor_max_angle_deg: float = 75.0
@export var floor_snap_length: float = 0.5
@export var air_grace: float = 0.3
@export var from_steep_slopes: bool = true

const JUMP_GRACE := 0.15
const MIN_SPEED := 1.0
const STEEP_UPHILL_LIMIT := -0.2
const STEEP_SLOPE_PUSH_THRESHOLD := 0.3
const STEEP_SLOPE_CLEARANCE := 0.25
const SLOPE_PROBE_DEPTH := 0.1
const SLOPE_PROBE_SPACING := 0.15
const SLOPE_PROBE_MATCH := 0.95

var is_active := false
var from_dive := false
var timer: float = 0.0
var direction: Vector3 = Vector3.ZERO
var jump_grace_timer: float = 0.0
var current_speed: float = 0.0
var current_duration: float = 0.7
var elapsed: float = 0.0
var air_time: float = 0.0
var last_downhill: float = 0.0

var default_floor_max_angle: float = 0.785398
var default_floor_snap_length: float = 0.1


func setup(target: Player) -> void:
	super(target)
	default_floor_max_angle = player.floor_max_angle
	default_floor_snap_length = player.floor_snap_length


func can_start() -> bool:
	return player.is_on_floor() and player.is_running and player.get_planar_speed() > player.walk_speed


func start() -> void:
	var heading: Vector3 = player.velocity.slide(player.up_direction)
	if heading.length_squared() < 0.0001:
		return

	begin(heading.normalized())


func begin(new_direction: Vector3) -> void:
	direction = new_direction
	is_active = true
	from_dive = false
	timer = 0.0
	current_speed = speed
	current_duration = duration
	elapsed = 0.0
	air_time = 0.0
	last_downhill = 0.0
	jump_grace_timer = 0.0
	player.landing_brake_timer = 0.0
	player.refresh_collision()


func end(allow_jump_grace: bool) -> void:
	is_active = false
	timer = 0.0
	jump_grace_timer = JUMP_GRACE if allow_jump_grace else 0.0
	player.refresh_collision()


func cancel() -> void:
	is_active = false
	timer = 0.0
	jump_grace_timer = 0.0
	player.refresh_collision()


func apply_floor_settings() -> void:
	if is_active:
		player.floor_max_angle = maxf(default_floor_max_angle, deg_to_rad(floor_max_angle_deg))
		player.floor_snap_length = maxf(default_floor_snap_length, floor_snap_length)
	else:
		player.floor_max_angle = default_floor_max_angle
		player.floor_snap_length = default_floor_snap_length

func is_climbing_steep_slope() -> bool:
	if not player.is_on_floor():
		return false

	var floor_normal: Vector3 = player.get_floor_normal()
	var angle: float = acos(clampf(floor_normal.dot(player.up_direction), -1.0, 1.0))
	if angle <= default_floor_max_angle:
		return false

	var downhill: Vector3 = floor_normal.slide(player.up_direction)
	if downhill.length_squared() < 0.0001:
		return false

	return direction.dot(downhill.normalized()) < STEEP_UPHILL_LIMIT

func steer_in_crawlspace() -> void:
	var input_direction: Vector3 = player.get_input_direction()
	if input_direction.length_squared() < 0.0001:
		return

	direction = input_direction
	elapsed = 0.0

func finish(allow_jump_grace: bool) -> void:
	var stay_low: bool = (
		player.is_on_floor()
		and InputMap.has_action(Player.CROUCH_ACTION)
		and player.crouch_slide_held()
	)

	if stay_low:
		player.is_running = false
		player.run_timer = 0.0
		player.start_crouch()

	end(allow_jump_grace)

func get_slope_surface_normal(collision: KinematicCollision3D) -> Vector3:
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	if not space:
		return Vector3.ZERO

	var contact: Vector3 = collision.get_position()
	var contact_normal: Vector3 = collision.get_normal()

	var up_slope: Vector3 = player.up_direction.slide(contact_normal)
	if up_slope.length_squared() < 0.0001:
		return Vector3.ZERO
	up_slope = up_slope.normalized()

	var samples: Array[Vector3] = [contact, contact + up_slope * SLOPE_PROBE_SPACING]
	var face_normal: Vector3 = Vector3.ZERO

	for point in samples:
		var query := PhysicsRayQueryParameters3D.create(
			point + contact_normal * SLOPE_PROBE_DEPTH,
			point - contact_normal * SLOPE_PROBE_DEPTH,
			player.collision_mask,
			[player.get_rid()]
		)
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			return Vector3.ZERO

		var hit_normal: Vector3 = hit["normal"]
		if face_normal == Vector3.ZERO:
			face_normal = hit_normal
		elif hit_normal.dot(face_normal) < SLOPE_PROBE_MATCH:
			return Vector3.ZERO

	return face_normal


func try_steep_slope_slide() -> void:
	if not from_steep_slopes:
		return

	if is_active or player.dive.is_active or player.movement_locked or player.is_ots_mode:
		return

	if player.wall.state != PlayerWallMovement.WallState.NONE:
		return

	if player.jump_phase == Player.JumpPhase.RISING:
		return

	var input_direction: Vector3 = player.get_input_direction()
	var needs_push: bool = player.is_on_floor()
	if needs_push and input_direction.length_squared() < 0.0001:
		return

	var steepest_walkable: float = default_floor_max_angle
	var steepest_gripped: float = deg_to_rad(floor_max_angle_deg)

	for i in player.get_slide_collision_count():
		var collision: KinematicCollision3D = player.get_slide_collision(i)
		var contact_normal: Vector3 = collision.get_normal()
		var contact_angle: float = acos(clampf(contact_normal.dot(player.up_direction), -1.0, 1.0))

		if contact_angle <= steepest_walkable or contact_angle > steepest_gripped:
			continue

		var normal: Vector3 = get_slope_surface_normal(collision)
		if normal == Vector3.ZERO:
			continue

		var angle: float = acos(clampf(normal.dot(player.up_direction), -1.0, 1.0))
		if angle <= steepest_walkable or angle > steepest_gripped:
			continue

		var contact_height: float = (collision.get_position() - player.global_position).dot(player.up_direction)
		if contact_height > Player.NORMAL_COLLISION_HEIGHT * 0.5:
			continue

		var downhill: Vector3 = normal.slide(player.up_direction)
		if downhill.length_squared() < 0.0001:
			continue
		downhill = downhill.normalized()

		if needs_push and input_direction.dot(downhill) > -STEEP_SLOPE_PUSH_THRESHOLD:
			continue

		if player.test_move(player.global_transform, downhill * STEEP_SLOPE_CLEARANCE):
			continue

		begin(downhill)
		return


func update(delta: float) -> void:

	jump_grace_timer = maxf(jump_grace_timer - delta, 0.0)

	if is_active:
		elapsed += delta

		if player.is_on_floor():
			air_time = 0.0
		else:
			air_time += delta

		var lost_ground: bool = air_time > air_grace
		var blocked: bool = (
			(elapsed > 0.1 and player.get_planar_speed() < MIN_SPEED)
			or is_climbing_steep_slope()
		)
		if player.movement_locked or lost_ground:
			end(false)
			return

		if not player.is_on_floor():
			player.coyote_timer = maxf(player.coyote_timer, delta)

		if player.is_ots_mode or blocked:
			if player.can_stand_up():
				if blocked and not player.is_ots_mode:
					finish(false)
				else:
					end(false)
				return

			if blocked:
				steer_in_crawlspace()

		var downhill: float = get_downhill_factor()

		if player.is_on_floor():
			last_downhill = downhill
		else:
			downhill = last_downhill

		if downhill > 0.0:
			current_speed = move_toward(
				current_speed,
				max_speed,
				slope_acceleration * downhill * delta
			)
		else:
			var remaining: float = maxf(current_duration - timer, 0.001)
			current_speed = lerpf(
				current_speed,
				end_speed,
				clampf(delta / remaining, 0.0, 1.0)
			)
			timer += delta

			if timer >= current_duration and player.can_stand_up():
				finish(true)
		return

	if player.crouch_slide_pressed() and can_start():
		start()


func get_speed() -> float:
	return current_speed


func get_jump_launch() -> Vector3:
	return direction * maxf(jump_speed, current_speed)


func get_target_motion() -> Dictionary:
	return {
		"target_velocity": direction * current_speed,
		"target_forward": direction
	}


func get_downhill_factor() -> float:
	if not player.is_on_floor():
		return 0.0

	var floor_normal: Vector3 = player.get_floor_normal()
	var angle: float = acos(clampf(floor_normal.dot(player.up_direction), -1.0, 1.0))

	if angle < deg_to_rad(slope_min_angle_deg):
		return 0.0

	var downhill: Vector3 = floor_normal.slide(player.up_direction)
	if downhill.length_squared() < 0.0001:
		return 0.0

	var alignment: float = direction.dot(downhill.normalized())
	if alignment <= 0.0:
		return 0.0

	var steepness: float = clampf(
		angle / maxf(deg_to_rad(slope_full_angle_deg), 0.001),
		0.0,
		1.0
	)
	return steepness * alignment
