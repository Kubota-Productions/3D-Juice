extends CharacterBody3D
class_name Bike

signal mounted(rider: Player)
signal dismounted(rider: Player)

@export var bike_camera: Camera3D

enum DismountSide { LEFT, RIGHT }

@export_group("Dismount")
@export var left_dismount_point: Marker3D
@export var right_dismount_point: Marker3D
@export var preferred_side: DismountSide = DismountSide.LEFT
@export var require_ground_at_dismount: bool = true
@export var dismount_ground_check_depth: float = 1.0
@export var dismount_path_height: float = 0.8

@export_group("Movement")
@export var max_speed: float = 18.0
@export var max_reverse_speed: float = 4.0
@export var acceleration: float = 12.0
@export var brake_deceleration: float = 25.0
@export var coast_deceleration: float = 4.0
@export var grip: float = 8.0

@export_group("Steering")
@export var max_turn_rate_deg: float = 110.0
@export var high_speed_turn_multiplier: float = 1
@export var steer_full_speed: float = 3.0
@export var steer_smoothing_time: float = 0.1

@export_group("BikebaseLean")
@export var bikebase: Node3D
@export var lean_max_angle_deg: float = 20.0
@export var lean_smoothing_speed: float = 6.0
@export var lean_turn_rate_reference: float = 0.8
@export var lean_high_speed_multiplier: float = 1.2
@export var lean_speed_curve_power: float = 1.0
@export var lean_return_speed_multiplier: float = 2.0

@export_group("Wheel")
@export var wheel: Node3D
@export var wheel_radius: float = 0.5
@export var wheel_spin_axis: Vector3 = Vector3.RIGHT
@export var wheel_lean_max_angle_deg: float = 30.0
@export var wheel_lean_smoothing_speed: float = 6.0

@export_group("charactermodel")
@export var monoch: Node3D 


var _wheel_angle: float = 0.0
const STEER_RELEASE_THRESHOLD := 0.05

var _steer_input: float = 0.0
var _wheel_lean: float = 0.0
var _wheel_rest_in_bike: Basis = Basis.IDENTITY
var _bikebase_rest_in_bike: Basis = Basis.IDENTITY

const TURN_RATE_SMOOTHING := 10.0

var _instant_yaw_rate: float = 0.0
var _turn_rate: float = 0.0

@export_group("Camera")
@export var speed_fov_boost: float = 12.0
@export var fov_smoothing_time: float = 0.25
@export var camera_rig: BikeCameraRig

var _steer: float = 0.0
var _lean: float = 0.0
var _base_fov: float = 75.0

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var rider: Player = null

var is_ridden: bool:
	get:
		return rider != null


func _ready() -> void:
	floor_snap_length = 0.5
	if bike_camera:
		_base_fov = bike_camera.fov
	if wheel:
		_wheel_rest_in_bike = global_basis.orthonormalized().inverse() * wheel.global_basis
	if bikebase:
		_bikebase_rest_in_bike = global_basis.orthonormalized().inverse() * bikebase.global_basis

func interact(interactor: Node) -> void:
	if is_ridden:
		return
	var player := interactor as Player
	if player == null or not player.can_enter_vehicle():
		return

	mount(player)


func mount(player: Player) -> void:
	rider = player

	if monoch:
		monoch.visible = true

	player.enter_vehicle(self)

	if camera_rig:
		camera_rig.snap_to_bike()

	if bike_camera:
		bike_camera.make_current()

	mounted.emit(player)


func dismount() -> void:
	if rider == null:
		return

	var exit: Variant = _pick_dismount_position()
	if exit == null:
		return

	var player := rider
	rider = null

	player.exit_vehicle(exit as Vector3)

	if monoch:
		monoch.visible = false

	dismounted.emit(player)


func _pick_dismount_position() -> Variant:
	var points: Array[Marker3D] = [left_dismount_point, right_dismount_point]
	if preferred_side == DismountSide.RIGHT:
		points.reverse()

	for point in points:
		if point and _is_dismount_point_valid(point.global_position):
			return point.global_position

	return null


func _is_dismount_point_valid(point: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var mask: int = rider.get_active_collision_mask()
	var excluded: Array[RID] = [get_rid(), rider.get_rid()]

	# 1. No wall between the bike and the point.
	var chest: Vector3 = Vector3.UP * dismount_path_height
	var path := PhysicsRayQueryParameters3D.create(
		global_position + chest, point + chest, mask, excluded
	)
	if not space.intersect_ray(path).is_empty():
		return false

	# 2. The standing capsule fits there.
	if not rider.is_standing_spot_clear(point, [get_rid()]):
		return false

	# 3. There's floor to land on.
	if require_ground_at_dismount:
		var ground := PhysicsRayQueryParameters3D.create(
			point + Vector3.UP * 0.5,
			point + Vector3.DOWN * dismount_ground_check_depth,
			mask,
			excluded
		)
		if space.intersect_ray(ground).is_empty():
			return false

	return true


func _unhandled_input(event: InputEvent) -> void:
	if is_ridden and event.is_action_pressed("Interact"):
		dismount()
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	var throttle: float = 0.0
	var steer_input: float = 0.0
	var parked: bool = not is_ridden or rider.movement_locked

	if not parked:
		throttle = Input.get_axis("backwards", "forward")
		steer_input = Input.get_axis("right", "left")

	_steer_input = steer_input

	var steer_weight: float = 1.0 - exp(-delta / maxf(steer_smoothing_time, 0.001))
	_steer = lerpf(_steer, steer_input, steer_weight)

	var vertical: float = 0.0
	if is_on_floor():
		_drive(throttle, parked, delta)
	else:
		_instant_yaw_rate = 0.0
		vertical = velocity.y - gravity * delta

	velocity.y = vertical
	move_and_slide()

	_update_visuals(delta)

	if rider:
		rider.global_position = global_position


func _drive(throttle: float, parked: bool, delta: float) -> void:
	var forward: Vector3 = -global_basis.z
	var speed_along: float = velocity.dot(forward)

	var speed_ratio: float = clampf(absf(speed_along) / maxf(max_speed, 0.001), 0.0, 1.0)
	var steer_strength: float = clampf(absf(speed_along) / maxf(steer_full_speed, 0.001), 0.0, 1.0)
	var turn_rate: float = (
		deg_to_rad(max_turn_rate_deg)
		* lerpf(1.0, high_speed_turn_multiplier, speed_ratio)
		* steer_strength
	)
	_instant_yaw_rate = _steer * turn_rate * signf(speed_along)
	rotate_y(_instant_yaw_rate * delta)

	forward = -global_basis.z
	var right: Vector3 = global_basis.x
	speed_along = velocity.dot(forward)
	var speed_side: float = velocity.dot(right)

	speed_along = _update_forward_speed(speed_along, throttle, parked, delta)
	speed_side *= exp(-grip * delta)

	var planar: Vector3 = forward * speed_along + right * speed_side
	velocity.x = planar.x
	velocity.z = planar.z

func _update_forward_speed(current: float, throttle: float, parked: bool, delta: float) -> float:
	if throttle > 0.0:
		var rate: float = brake_deceleration if current < 0.0 else acceleration
		return move_toward(current, max_speed * throttle, rate * delta)

	if throttle < 0.0:
		var rate: float = brake_deceleration if current > 0.0 else acceleration
		return move_toward(current, max_reverse_speed * throttle, rate * delta)

	var decel: float = brake_deceleration if parked else coast_deceleration
	return move_toward(current, 0.0, decel * delta)

func _update_visuals(delta: float) -> void:
	_update_lean(delta)
	_update_wheel(delta)
	if bike_camera and is_ridden:
		var speed_ratio: float = clampf(get_planar_speed() / maxf(max_speed, 0.001), 0.0, 1.0)
		var fov_weight: float = 1.0 - exp(-delta / maxf(fov_smoothing_time, 0.001))
		var target_fov: float = _base_fov + speed_fov_boost * speed_ratio
		bike_camera.fov = lerpf(bike_camera.fov, target_fov, fov_weight)

func _update_lean(delta: float) -> void:
	_turn_rate = lerpf(_turn_rate, _instant_yaw_rate, 1.0 - exp(-TURN_RATE_SMOOTHING * delta))

	var speed_fraction: float = clampf(get_planar_speed() / maxf(max_speed, 0.001), 0.0, 1.0)
	var shaped_fraction: float = pow(speed_fraction, maxf(lean_speed_curve_power, 0.001))
	var released: bool = absf(_steer_input) < STEER_RELEASE_THRESHOLD

	var lean_amount: float = 0.0
	if is_on_floor() and not released:
		lean_amount = clampf(_turn_rate / lean_turn_rate_reference, -1.0, 1.0) * shaped_fraction

	_lean = _step_lean(_lean, lean_amount, lean_max_angle_deg, lean_smoothing_speed, shaped_fraction, released, delta)
	_wheel_lean = _step_lean(_wheel_lean, lean_amount, wheel_lean_max_angle_deg, wheel_lean_smoothing_speed, shaped_fraction, released, delta)
	if bikebase:
		bikebase.global_basis = (
			global_basis.orthonormalized()
			* Basis(Vector3.BACK, _lean)
			* _bikebase_rest_in_bike
		)

func _step_lean(
	current: float,
	amount: float,
	base_angle_deg: float,
	smoothing_speed: float,
	shaped_fraction: float,
	released: bool,
	delta: float
) -> float:
	var max_angle: float = deg_to_rad(base_angle_deg) * lerpf(1.0, lean_high_speed_multiplier, shaped_fraction)
	var rate: float = smoothing_speed * (lean_return_speed_multiplier if released else 1.0)
	var max_step: float = deg_to_rad(base_angle_deg) * rate * delta
	return move_toward(current, amount * max_angle, max_step)


func _update_wheel(delta: float) -> void:
	if wheel == null:
		return

	var forward_speed: float = velocity.dot(-global_basis.z)
	var spin: float = forward_speed / maxf(wheel_radius, 0.001) * delta
	_wheel_angle = fposmod(_wheel_angle - spin, TAU)

	wheel.global_basis = (
		global_basis.orthonormalized()
		* Basis(Vector3.BACK, _wheel_lean)
		* _wheel_rest_in_bike
		* Basis(wheel_spin_axis.normalized(), _wheel_angle)
	)

func get_planar_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()
