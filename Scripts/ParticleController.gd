extends Node
class_name ParticleController

var player: Player

@export var particles: GPUParticles3D

@export_group("Speed Response")
@export var min_speed: float = 3.0
@export var max_speed: float = 9.0
@export var response_curve_power: float = 1.4
@export var intensity_smoothing_time: float = 0.12

@export_group("Scaling")
@export var min_amount_ratio: float = 0.15
@export var max_amount_ratio: float = 1.0
@export var min_scale_multiplier: float = 0.6
@export var max_scale_multiplier: float = 1.6
@export var min_velocity_multiplier: float = 0.6
@export var max_velocity_multiplier: float = 1.8

@export_group("Velocity Response")
@export var velocity_min_speed: float = 3.0
@export var velocity_max_speed: float = 9.0
@export var velocity_response_curve_power: float = 1.0
@export var velocity_smoothing_time: float = 0.08

var current_velocity_factor: float = 0.0
var current_intensity: float = 0.0

var _process_material: ParticleProcessMaterial

var _base_scale_min: float = 1.0
var _base_scale_max: float = 1.0

var _base_velocity_min: float = 0.0
var _base_velocity_max: float = 0.0

func setup(owner: Player) -> void:
	player = owner

	if not particles:
		push_warning(
			"ParticleController: no GPUParticles3D assigned -- run dust disabled."
		)
		return

	var source_material := particles.process_material as ParticleProcessMaterial

	if source_material:
		_process_material = source_material.duplicate() as ParticleProcessMaterial
		particles.process_material = _process_material

		_base_scale_min = _process_material.scale_min
		_base_scale_max = _process_material.scale_max

		_base_velocity_min = _process_material.initial_velocity_min
		_base_velocity_max = _process_material.initial_velocity_max

	particles.emitting = false

func update(delta: float) -> void:
	if not player or not particles:
		return

	var target_intensity: float = _compute_target_intensity()

	var intensity_weight := 1.0 - exp(
		-delta / max(intensity_smoothing_time, 0.001)
	)

	current_intensity = lerpf(
		current_intensity,
		target_intensity,
		intensity_weight
	)

	var target_velocity_factor: float = _compute_velocity_factor()

	var velocity_weight := 1.0 - exp(
		-delta / max(velocity_smoothing_time, 0.001)
	)

	current_velocity_factor = lerpf(
		current_velocity_factor,
		target_velocity_factor,
		velocity_weight
	)

	if _process_material:
		var velocity_multiplier := lerpf(
			min_velocity_multiplier,
			max_velocity_multiplier,
			current_velocity_factor
		)

		_process_material.initial_velocity_min = (
			_base_velocity_min * velocity_multiplier
		)

		_process_material.initial_velocity_max = (
			_base_velocity_max * velocity_multiplier
		)

	if current_intensity <= 0.01:
		particles.emitting = false
		return

	particles.emitting = true

	particles.amount_ratio = lerpf(
		min_amount_ratio,
		max_amount_ratio,
		current_intensity
	)

	if _process_material:
		var scale_multiplier := lerpf(
			min_scale_multiplier,
			max_scale_multiplier,
			current_intensity
		)

		_process_material.scale_min = (
			_base_scale_min * scale_multiplier
		)

		_process_material.scale_max = (
			_base_scale_max * scale_multiplier
		)

func _compute_target_intensity() -> float:
	if not player.is_on_floor():
		return 0.0

	var speed: float = player.get_planar_speed()

	var span: float = max(
		max_speed - min_speed,
		0.001
	)

	var raw: float = clampf(
		(speed - min_speed) / span,
		0.0,
		1.0
	)

	return pow(
		raw,
		max(response_curve_power, 0.001)
	)

func _compute_velocity_factor() -> float:
	var speed: float = player.get_planar_speed()

	var span: float = max(
		velocity_max_speed - velocity_min_speed,
		0.001
	)

	var raw: float = clampf(
		(speed - velocity_min_speed) / span,
		0.0,
		1.0
	)

	return pow(
		raw,
		max(velocity_response_curve_power, 0.001)
	)

func clear() -> void:
	current_intensity = 0.0
	current_velocity_factor = 0.0

	if particles:
		particles.emitting = false
