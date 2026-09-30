extends Node
class_name GravityController

enum GravityState {
	GROUNDED,
	LEVITATING,
	SHIFTING,
	WALL
}

var spring_arm: SpringArm3D
var ground_ray_origin: Marker3D
@export var gravity_strength := 20

@export var shift_momentum_acceleration: float = 40.0  # units/sec^2, how fast velocity turns toward the shift direction
@export var levitate_deceleration: float = 15.0  # units/sec^2
var levitate_start_velocity: Vector3 = Vector3.ZERO
@export var shift_start_speed := 8.0
@export var shift_acceleration := 15.0
@export var max_shift_speed := 35.0
@export var max_shift_power: float = 100.0
@export var shift_drain_rate: float = 40.0   
@export var levitate_drain_rate: float = 25.0
@export var shift_regen_rate: float = 25.0  
@export var wall_drain_rate: float = 15.0
@export var power_sprint_drain_rate: float = 30.0
var shift_power: float = 100.0
@export var shift_regen_delay_after_empty: float = 3.0
var regen_delay_timer: float = 0.0

## Power locked away by external systems (e.g. currently-held
## telekinesis objects). shift_power itself is already reduced by
## this amount at the moment it's reserved -- this value only exists
## to cap how high regen (and refill_shift_power) can climb back to,
## so reserved chunks stay drained until explicitly released.
var reserved_power: float = 0.0

@export_group("Wall Walking")
@export var wall_follow_ray_length: float = 3.0
@export var wall_follow_smoothing_time: float = 0.15
@export var wall_follow_lose_surface_time: float = 0.15
@export var wall_attach_clearance: float = 0.05  


var wall_lose_surface_timer: float = 0.0

signal shift_power_changed(current: float, max: float)

var gravity_state := GravityState.GROUNDED

var gravity_direction := Vector3.DOWN
var shift_speed := 0.0

var player : Player
var camera: Camera3D

@export var floor_normal_buffer_deg: float = 5.0

@export var min_transition_interval: float = 0.12
var last_transition_time: float = 0.0
var last_levitate_time: float = 0.0
var last_shift_time: float = 0.0

func _ready():
	print(camera)

func setup(owner: Player, cam: Camera3D):
	player = owner
	camera = cam
	ground_ray_origin = player.get_node("GroundRayOrigin")
	spring_arm = player.get_node("SpringArm3D")
	shift_power = max_shift_power

func _try_transition() -> bool:
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - last_transition_time < min_transition_interval:
		return false
	last_transition_time = now
	return true

func check_shift_surface():
	var origin = ground_ray_origin.global_position
	var target = origin + gravity_direction * 2.0

	var query = PhysicsRayQueryParameters3D.create(origin, target)
	query.exclude = [player]
	var hit = player.get_world_3d().direct_space_state.intersect_ray(query)
	return hit
	
func apply_gravity(_delta):

	if gravity_state == GravityState.LEVITATING:
		return

	# Gravity was already the one acceleration-shaped thing in here --
	# now it goes through the accumulator like everything else.
	player.add_acceleration(gravity_direction * gravity_strength)

func _try_levitate_transition() -> bool:
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - last_levitate_time < min_transition_interval:
		return false
	last_levitate_time = now
	return true
	
func _try_shift_transition() -> bool:
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - last_shift_time < min_transition_interval:
		return false
	last_shift_time = now
	return true
	
func enter_levitating():
	if shift_power <= 0.0:
		return
	if not _try_levitate_transition():
		return
	gravity_state = GravityState.LEVITATING

func return_to_ground():
	gravity_direction = Vector3.DOWN
	player.up_direction = Vector3.UP
	gravity_state = GravityState.GROUNDED

	var forward: Vector3 = -player.global_basis.z
	forward = forward.slide(Vector3.UP)

	if forward.length_squared() > 0.001:
		forward = forward.normalized()
		player.global_basis = Basis.looking_at(forward, Vector3.UP)
	else:
		player.global_basis = Basis.IDENTITY

func calculate_shift_direction() -> Vector3:

	var from = camera.global_position
	var to = from + (-camera.global_basis.z * 250)

	var query = PhysicsRayQueryParameters3D.create(from, to)

	query.exclude = [player]

	var hit = player.get_world_3d().direct_space_state.intersect_ray(query)

	if hit:

		return (hit.position - player.global_position).normalized()

	return (to - player.global_position).normalized()
	
func begin_shift():
	if not _try_shift_transition():
		return
	gravity_direction = calculate_shift_direction()
	shift_speed = shift_start_speed
	gravity_state = GravityState.SHIFTING
	
func update_shift(delta):

	shift_speed += shift_acceleration * delta

	shift_speed = min(
		shift_speed,
		max_shift_speed
	)

	var target_velocity: Vector3 = gravity_direction * shift_speed

	# Was move_toward() straight onto velocity. Same no-overshoot
	# behavior, but expressed as a force so it stacks with everything
	# else contributing this frame instead of overwriting it.
	player.add_acceleration(
		Player.acceleration_toward(
			player.velocity,
			target_velocity,
			shift_momentum_acceleration,
			delta
		)
	)
	
func update_levitating(delta: float) -> void:
	# Decelerate toward a dead stop -- as a braking force, so it eases
	# to rest rather than snapping the last fraction of velocity away.
	player.add_acceleration(
		Player.acceleration_toward(
			player.velocity,
			Vector3.ZERO,
			levitate_deceleration,
			delta
		)
	)

func update_shift_power(delta: float, is_power_sprinting: bool = false) -> void:
	var draining := gravity_state == GravityState.LEVITATING \
		or gravity_state == GravityState.SHIFTING \
		or gravity_state == GravityState.WALL

	if draining:
		var rate: float
		match gravity_state:
			GravityState.WALL:
				rate = wall_drain_rate
			GravityState.LEVITATING:
				rate = levitate_drain_rate
			_:
				rate = shift_drain_rate

		shift_power = max(shift_power - rate * delta, 0.0)

		if shift_power <= 0.0:
			regen_delay_timer = shift_regen_delay_after_empty
			return_to_ground()

	elif gravity_state == GravityState.GROUNDED and is_power_sprinting:
		shift_power = max(
			shift_power - power_sprint_drain_rate * delta,
			0.0
		)

		if shift_power <= 0.0:
			regen_delay_timer = shift_regen_delay_after_empty

	elif gravity_state == GravityState.GROUNDED:
		if regen_delay_timer > 0.0:
			regen_delay_timer -= delta
		elif player.is_on_floor():
			# Only recover power when actually grounded.
			var regen_ceiling: float = max_shift_power - reserved_power
			shift_power = min(
				shift_power + shift_regen_rate * delta,
				regen_ceiling
			)

	shift_power_changed.emit(shift_power, max_shift_power)

func update_wall_follow(delta: float) -> void:
	if gravity_state != GravityState.WALL:
		return

	var origin: Vector3 = ground_ray_origin.global_position
	var target: Vector3 = origin + gravity_direction * wall_follow_ray_length

	var query := PhysicsRayQueryParameters3D.create(origin, target)
	query.exclude = [player]
	query.hit_from_inside = true
	var hit = player.get_world_3d().direct_space_state.intersect_ray(query)

	if not hit or hit.normal.length_squared() < 0.0001:
		return  # no usable surface data this frame -- keep last known gravity_direction

	var new_normal: Vector3 = hit.normal

	if new_normal.angle_to(Vector3.UP) <= deg_to_rad(floor_normal_buffer_deg):
		return_to_ground()
		player.global_position = hit.position
		return

	var new_gravity_dir: Vector3 = -new_normal

	if new_gravity_dir.dot(gravity_direction) < 0.9999:
		var weight: float = 1.0 - exp(-delta / max(wall_follow_smoothing_time, 0.001))
		var full_rotation := Quaternion(gravity_direction, new_gravity_dir)
		var step_rotation := Quaternion.IDENTITY.slerp(full_rotation, weight)

		gravity_direction = (step_rotation * gravity_direction).normalized()
		player.up_direction = -gravity_direction

		# Not an acceleration -- the gravity frame itself is rotating,
		# so existing momentum gets reinterpreted in the new basis at
		# unchanged magnitude.
		player.rotate_velocity(step_rotation)

## Deducts `amount` from shift_power immediately and marks it as
## reserved, so update_shift_power()'s regen can't climb back past
## (max_shift_power - reserved_power) until release_reserved_power()
## is called with a matching amount. Returns false (and does nothing)
## if there isn't enough currently-available power to cover it.
func reserve_power(amount: float) -> bool:
	if amount > shift_power:
		return false

	shift_power -= amount
	reserved_power += amount
	shift_power_changed.emit(shift_power, max_shift_power)
	return true

## Lifts the regen ceiling back up by `amount` -- does NOT instantly
## refund shift_power, regen just gradually reclaims the freed headroom.
func release_reserved_power(amount: float) -> void:
	reserved_power = max(reserved_power - amount, 0.0)

## One-shot spend: deducts `amount` from shift_power if (and only if)
## there's enough available, same "can't afford it" semantics as
## reserve_power but with no lock/release bookkeeping -- for costs
## that are paid once and don't need to be given back later (e.g. an
## air jump), unlike a telekinesis hold which reserves power for as
## long as the object stays held. Returns false (and does nothing) if
## unaffordable, so callers can gate the action on the return value.
func drain_power(amount: float) -> bool:
	if amount > shift_power:
		return false

	shift_power -= amount
	if shift_power <= 0.0:
		regen_delay_timer = shift_regen_delay_after_empty
	shift_power_changed.emit(shift_power, max_shift_power)
	return true

func refill_shift_power(amount: float = -1.0) -> void:
	# amount < 0 means "fill completely"; otherwise add a partial amount.
	# Capped by reserved_power same as regen, for the same reason --
	# a refill pickup shouldn't be able to bypass a telekinesis lock.
	var ceiling: float = max_shift_power - reserved_power

	if amount < 0.0:
		shift_power = ceiling
	else:
		shift_power = min(shift_power + amount, ceiling)

	regen_delay_timer = 0.0  # a pickup should clear any regen delay too
	shift_power_changed.emit(shift_power, max_shift_power)

func detect_wall():

	if gravity_state != GravityState.SHIFTING:
		return

	var hit = check_shift_surface()

	if hit:

		attach_to_surface(hit)
			
func attach_to_surface(hit):
	var normal: Vector3 = hit.normal

	if normal.length_squared() < 0.0001:
		return  # degenerate normal (e.g. hit_from_inside on concave geometry) -- ignore, don't attach

	if normal.angle_to(Vector3.UP) <= deg_to_rad(floor_normal_buffer_deg):
		return_to_ground()
		# Intentional hard stop: the body is being snapped to the hit
		# position, so carrying momentum across that teleport is wrong.
		player.hard_stop()
		player.global_position = hit.position
		if spring_arm:
			spring_arm.rotation.y = 0.0
		return

	gravity_direction = -normal
	player.up_direction = normal
	# Same reasoning -- position is being snapped, so is velocity.
	player.hard_stop()
	player.global_position = hit.position + normal * wall_attach_clearance

	var forward: Vector3 = -player.global_basis.z
	forward = forward.slide(normal)
	if forward.length_squared() < 0.001:
		forward = player.global_basis.x.slide(normal)
	forward = forward.normalized()
	player.global_basis = Basis.looking_at(forward, normal)

	if spring_arm:
		spring_arm.rotation.y = 0.0
	gravity_state = GravityState.WALL
