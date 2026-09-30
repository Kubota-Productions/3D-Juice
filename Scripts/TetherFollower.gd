extends Node3D

@export var player: Node3D
@export var follow_speed: float = 8.0

# Floating motion
@export var float_amount := Vector3(0.0, 0.15, 0.0)
@export var float_speed: float = 2.0

# Immutable movement limits around the original position
const MAX_X_OFFSET := 1.0
const MAX_Y_OFFSET := 0.3
const MAX_Z_OFFSET := 1.0

var relative_transform: Transform3D
var float_time := 0.0


func _ready():
	if player:
		# Remember exact starting relationship to player
		relative_transform = player.global_transform.affine_inverse() * global_transform


func _physics_process(delta):
	if player == null:
		return

	float_time += delta

	# Original anchored position relative to player
	var target_transform = player.global_transform * relative_transform

	# Floating sine wave
	var float_offset = Vector3(
		sin(float_time * float_speed * 0.8) * float_amount.x,
		sin(float_time * float_speed) * float_amount.y,
		sin(float_time * float_speed * 1.2) * float_amount.z
	)

	# Apply floating offset in player's local space
	var target_position = target_transform.origin + (
		player.global_transform.basis * float_offset
	)

	# Smooth movement
	global_position = global_position.lerp(
		target_position,
		1.0 - exp(-follow_speed * delta)
	)


	# Convert current position into player local space
	var local_position = player.global_transform.affine_inverse() * global_position

	# Difference from the original anchor point
	var local_offset = local_position - relative_transform.origin

	# Clamp movement per axis
	local_offset.x = clamp(local_offset.x, -MAX_X_OFFSET, MAX_X_OFFSET)
	local_offset.y = clamp(local_offset.y, -MAX_Y_OFFSET, MAX_Y_OFFSET)
	local_offset.z = clamp(local_offset.z, -MAX_Z_OFFSET, MAX_Z_OFFSET)

	# Apply clamped position back to world space
	local_position = relative_transform.origin + local_offset
	global_position = player.global_transform * local_position


	# Keep original rotation relative to player
	var target_basis = target_transform.basis

	global_basis = global_basis.slerp(
		target_basis,
		1.0 - exp(-follow_speed * delta)
	)
