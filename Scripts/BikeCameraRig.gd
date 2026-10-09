extends SpringArm3D
class_name BikeCameraRig

@export var bike: Bike
@export var camera: Camera3D

@export_group("Look")
@export var mouse_sensitivity: float = 0.005
@export var min_pitch_deg: float = -60.0
@export var max_pitch_deg: float = 40.0
@export var default_pitch_deg: float = -12.0

@export_group("Follow")
@export var pivot_offset: Vector3 = Vector3(0.0, 1.2, 0.0)
@export var position_smoothing_time: float = 0.03

@export_group("Auto Recenter")
@export var auto_recenter: bool = true
@export var recenter_delay: float = 1.0
@export var recenter_min_speed: float = 3.0
@export var recenter_smoothing_time: float = 0.6

var yaw: float = 0.0
var pitch: float = 0.0

var _yaw_input: float = 0.0
var _pitch_input: float = 0.0
var _idle_time: float = 999.0
var _smoothed_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	top_level = true

	if bike == null:
		bike = get_parent() as Bike
	if bike:
		add_excluded_object(bike.get_rid())

	snap_to_bike()

func snap_to_bike() -> void:
	if bike == null:
		return

	yaw = bike.global_rotation.y
	pitch = deg_to_rad(default_pitch_deg)
	_yaw_input = 0.0
	_pitch_input = 0.0
	_idle_time = 999.0

	_smoothed_position = bike.global_position + pivot_offset
	global_position = _smoothed_position
	global_basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))


func _unhandled_input(event: InputEvent) -> void:
	if bike == null or not bike.is_ridden:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw_input -= event.relative.x * mouse_sensitivity
		_pitch_input -= event.relative.y * mouse_sensitivity
		_idle_time = 0.0


func _physics_process(delta: float) -> void:
	if bike == null or not bike.is_ridden:
		return

	_idle_time += delta

	yaw += _yaw_input
	pitch = clampf(pitch + _pitch_input, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
	_yaw_input = 0.0
	_pitch_input = 0.0

	if auto_recenter and _idle_time >= recenter_delay:
		var forward_speed: float = bike.velocity.dot(-bike.global_basis.z)
		if forward_speed > recenter_min_speed:
			var recenter_weight: float = 1.0 - exp(-delta / maxf(recenter_smoothing_time, 0.001))
			yaw = lerp_angle(yaw, bike.global_rotation.y, recenter_weight)

	var follow_weight: float = 1.0 - exp(-delta / maxf(position_smoothing_time, 0.001))
	_smoothed_position = _smoothed_position.lerp(bike.global_position + pivot_offset, follow_weight)

	global_position = _smoothed_position
	global_basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))
