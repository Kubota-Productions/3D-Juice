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

@export var shift_momentum_acceleration: float = 40.0  
@export var levitate_deceleration: float = 15.0  
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

	player.add_acceleration(
		Player.acceleration_toward(
			player.velocity,
			target_velocity,
			shift_momentum_acceleration,
			delta
		)
	)
	
func update_levitating(delta: float) -> void:
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
		return 

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

		player.rotate_velocity(step_rotation)

func reserve_power(amount: float) -> bool:
	if amount > shift_power:
		return false

	shift_power -= amount
	reserved_power += amount
	shift_power_changed.emit(shift_power, max_shift_power)
	return true

func release_reserved_power(amount: float) -> void:
	reserved_power = max(reserved_power - amount, 0.0)

func drain_power(amount: float) -> bool:
	if amount > shift_power:
		return false

	shift_power -= amount
	if shift_power <= 0.0:
		regen_delay_timer = shift_regen_delay_after_empty
	shift_power_changed.emit(shift_power, max_shift_power)
	return true

func refill_shift_power(amount: float = -1.0) -> void:
	var ceiling: float = max_shift_power - reserved_power

	if amount < 0.0:
		shift_power = ceiling
	else:
		shift_power = min(shift_power + amount, ceiling)

	regen_delay_timer = 0.0  
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
		return 

	if normal.angle_to(Vector3.UP) <= deg_to_rad(floor_normal_buffer_deg):
		return_to_ground()
		player.hard_stop()
		player.global_position = hit.position
		if spring_arm:
			spring_arm.rotation.y = 0.0
		return

	gravity_direction = -normal
	player.up_direction = normal
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
