extends Node
class_name ParticleController

# ============================================================
# REFERENCES
# ============================================================

var player: Player

## GPUParticles3D emitting the dust.
## Parent this to the character/feet so it inherits the player's
## gravity-aligned rotation.
@export var particles: GPUParticles3D


# ============================================================
# SPEED RESPONSE
# ============================================================

@export_group("Speed Response")

## Below this planar speed, no dust.
@export var min_speed: float = 3.0

## Speed at which the effect reaches full intensity.
@export var max_speed: float = 9.0

## Controls how quickly emission ramps up with speed.
@export var response_curve_power: float = 1.4

## Smooths emission intensity changes.
@export var intensity_smoothing_time: float = 0.12


# ============================================================
# SCALING
# ============================================================

@export_group("Scaling")

## Fraction of the authored particle amount used at minimum intensity.
@export var min_amount_ratio: float = 0.15

## Fraction of the authored particle amount used at full intensity.
@export var max_amount_ratio: float = 1.0

## Particle size multiplier at minimum intensity.
@export var min_scale_multiplier: float = 0.6

## Particle size multiplier at maximum intensity.
@export var max_scale_multiplier: float = 1.6

## Initial velocity multiplier at minimum speed.
@export var min_velocity_multiplier: float = 0.6

## Initial velocity multiplier at maximum speed.
@export var max_velocity_multiplier: float = 1.8


# ============================================================
# VELOCITY RESPONSE
# ============================================================

@export_group("Velocity Response")

## Independent speed range for initial velocity.
@export var velocity_min_speed: float = 3.0

@export var velocity_max_speed: float = 9.0

## Controls the velocity response curve.
@export var velocity_response_curve_power: float = 1.0

## Smoothing for velocity changes.
@export var velocity_smoothing_time: float = 0.08


# ============================================================
# RUNTIME STATE
# ============================================================

var current_velocity_factor: float = 0.0
var current_intensity: float = 0.0

var _process_material: ParticleProcessMaterial

var _base_scale_min: float = 1.0
var _base_scale_max: float = 1.0

var _base_velocity_min: float = 0.0
var _base_velocity_max: float = 0.0


# ============================================================
# SETUP
# ============================================================

func setup(owner: Player) -> void:
	player = owner

	if not particles:
		push_warning(
			"ParticleController: no GPUParticles3D assigned -- run dust disabled."
		)
		return

	var source_material := particles.process_material as ParticleProcessMaterial

	if source_material:
		# Duplicate the material so runtime changes only affect
		# this particle system.
		_process_material = source_material.duplicate() as ParticleProcessMaterial
		particles.process_material = _process_material

		# --------------------------------------------------------
		# Cache the ORIGINAL authored values.
		# --------------------------------------------------------

		_base_scale_min = _process_material.scale_min
		_base_scale_max = _process_material.scale_max

		# Cache min/max independently.
		#
		# Both will later receive the SAME velocity multiplier,
		# preserving the authored min/max relationship.
		_base_velocity_min = _process_material.initial_velocity_min
		_base_velocity_max = _process_material.initial_velocity_max

		# IMPORTANT:
		# Do not modify direction here.
		#
		# The ParticleProcessMaterial's Direction should be set
		# in the inspector, normally:
		#
		# Direction = (0, 1, 0)
		#
		# Because the GPUParticles3D follows the Player's
		# gravity-aligned rotation, local +Y becomes the direction
		# away from the floor/wall/etc.

	particles.emitting = false


# ============================================================
# UPDATE
# ============================================================

func update(delta: float) -> void:
	if not player or not particles:
		return

	# ------------------------------------------------------------
	# EMISSION INTENSITY
	# ------------------------------------------------------------

	var target_intensity: float = _compute_target_intensity()

	var intensity_weight := 1.0 - exp(
		-delta / max(intensity_smoothing_time, 0.001)
	)

	current_intensity = lerpf(
		current_intensity,
		target_intensity,
		intensity_weight
	)


	# ------------------------------------------------------------
	# INITIAL VELOCITY
	#
	# This is deliberately independent from emission intensity.
	# It controls how hard each particle is kicked.
	# ------------------------------------------------------------

	var target_velocity_factor: float = _compute_velocity_factor()

	var velocity_weight := 1.0 - exp(
		-delta / max(velocity_smoothing_time, 0.001)
	)

	current_velocity_factor = lerpf(
		current_velocity_factor,
		target_velocity_factor,
		velocity_weight
	)


	# ------------------------------------------------------------
	# SCALE INITIAL VELOCITY
	# ------------------------------------------------------------

	if _process_material:
		var velocity_multiplier := lerpf(
			min_velocity_multiplier,
			max_velocity_multiplier,
			current_velocity_factor
		)

		# Both min and max receive the SAME multiplier.
		#
		# Example:
		# authored: 1.0 - 3.0
		# multiplier: 1.5
		# result: 1.5 - 4.5
		#
		# Direction is NOT changed here.
		_process_material.initial_velocity_min = (
			_base_velocity_min * velocity_multiplier
		)

		_process_material.initial_velocity_max = (
			_base_velocity_max * velocity_multiplier
		)


	# ------------------------------------------------------------
	# STOP EMISSION WHEN INTENSITY IS VERY LOW
	# ------------------------------------------------------------

	if current_intensity <= 0.01:
		particles.emitting = false
		return

	particles.emitting = true


	# ------------------------------------------------------------
	# AMOUNT
	# ------------------------------------------------------------

	particles.amount_ratio = lerpf(
		min_amount_ratio,
		max_amount_ratio,
		current_intensity
	)


	# ------------------------------------------------------------
	# PARTICLE SCALE
	# ------------------------------------------------------------

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


# ============================================================
# EMISSION INTENSITY
# ============================================================

## Returns 0 when stationary/airborne and 1 at max_speed.
##
## Dust requires ground contact because it represents the player
## kicking/scuffing the surface.
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


# ============================================================
# VELOCITY RESPONSE
# ============================================================

## Determines how strongly each particle is initially kicked.
##
## This does NOT affect direction.
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


# ============================================================
# CLEAR
# ============================================================

## Stops emission immediately.
## Useful for respawns, cutscenes, teleports, etc.
func clear() -> void:
	current_intensity = 0.0
	current_velocity_factor = 0.0

	if particles:
		particles.emitting = false
