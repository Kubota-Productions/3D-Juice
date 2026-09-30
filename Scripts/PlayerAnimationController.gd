extends Node
class_name PlayerAnimationController

# ============================================================
# REFERENCES
# ============================================================
@export var player: Player
@export var character_model: Node3D

var animation_tree: AnimationTree
var animation_player: AnimationPlayer
var anim_playback: AnimationNodeStateMachinePlayback


# ============================================================
# CHARACTER MESHES (shader params get pushed to all of these)
# ============================================================
var mesh_instances: Array[MeshInstance3D] = []


# ============================================================
# FOOT IK
# ============================================================
@export_group("Foot IK")
@export var skeleton: Skeleton3D
@export var left_foot_bone: String = "LeftFoot"
@export var right_foot_bone: String = "RightFoot"
@export var left_target: Node3D
@export var right_target: Node3D
@export var foot_contact_threshold: float = 0.05
@export var ik_blend_speed: float = 12.0
@export var sole_offset: float = 0.03

var left_bone_idx: int = -1
var right_bone_idx: int = -1
var left_weight: float = 0.0
var right_weight: float = 0.0


# ============================================================
# LOCOMOTION BLEND
# ============================================================
@export_group("Locomotion Blend")
@export var speed_blend_smoothing_time: float = 0.06

var smoothed_locomotion_speed: float = 0.0


# ============================================================
# WALL RUN LEAN
# ============================================================
@export_group("Wall Run Lean")

@export var wall_run_lean_angle_deg: float = 8.0
@export var wall_run_lean_smoothing_speed: float = 10.0

var current_wall_run_lean: float = 0.0


# ============================================================
# LANDING ANTICIPATION
# ============================================================
@export_group("Landing Anticipation")

@export var land_anim_duration: float = 0.25
@export var landing_predict_ray_length: float = 50.0
@export var ground_contact_offset: float = 0.0

var land_anim_active: bool = false
var landing_timer: float = 0.0


# ============================================================
# STATE
# ============================================================
enum AnimState {
	IDLE,
	JOG,
	RUN,
	SLIDE,
	WALL_SLIDE,
	JUMP,
	DOUBLE_JUMP,
	TRIPLE_JUMP,
	JUMP_OUT_OF_SLIDE,
	FALL,
	LAND
}

const LOCOMOTION_BLEND_PARAM := "parameters/BlendSpace1D/blend_position"

var current_anim_state := AnimState.IDLE
var was_on_floor := true

# Tracks whether the player was sliding immediately before
# becoming airborne.
var was_sliding := false


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	if not player:
		push_error("PlayerAnimationController: 'player' not assigned")
		return

	if not character_model:
		push_error("PlayerAnimationController: 'character_model' not assigned")
		return

	animation_player = _find_first_of_type(
		character_model,
		"AnimationPlayer"
	) as AnimationPlayer

	animation_tree = _find_first_of_type(
		player,
		"AnimationTree"
	) as AnimationTree

	if not animation_player:
		push_error(
			"PlayerAnimationController: no AnimationPlayer found anywhere under %s"
			% character_model.name
		)

	if not animation_tree:
		push_error(
			"PlayerAnimationController: no AnimationTree found anywhere under %s"
			% player.name
		)
		return

	animation_tree.active = true

	anim_playback = animation_tree.get(
		"parameters/playback"
	)

	if not anim_playback:
		push_error(
			"PlayerAnimationController: 'parameters/playback' came back null -- "
			+ "Tree Root probably isn't an AnimationNodeStateMachine"
		)

	mesh_instances.clear()

	_find_all_of_type(
		character_model,
		"MeshInstance3D",
		mesh_instances
	)

	if mesh_instances.is_empty():
		push_error(
			"PlayerAnimationController: no MeshInstance3D found under %s "
			% character_model.name
			+ "-- lean/squash shader params won't apply"
		)

	if skeleton:
		left_bone_idx = skeleton.find_bone(left_foot_bone)
		right_bone_idx = skeleton.find_bone(right_foot_bone)

		if left_bone_idx == -1:
			push_error(
				"PlayerAnimationController: bone '%s' not found on skeleton"
				% left_foot_bone
			)

		if right_bone_idx == -1:
			push_error(
				"PlayerAnimationController: bone '%s' not found on skeleton"
				% right_foot_bone
			)
	else:
		push_error(
			"PlayerAnimationController: 'skeleton' not assigned -- foot IK disabled"
		)


# ============================================================
# FIND NODE
# ============================================================
func _find_first_of_type(root: Node, type_name: String) -> Node:
	for child in root.get_children():
		if child.is_class(type_name):
			return child

		var found := _find_first_of_type(child, type_name)

		if found:
			return found

	return null


# ============================================================
# FIND ALL NODES
# ============================================================
func _find_all_of_type(
	root: Node,
	type_name: String,
	out_list: Array
) -> void:
	for child in root.get_children():
		if child.is_class(type_name):
			out_list.append(child)

		_find_all_of_type(
			child,
			type_name,
			out_list
		)


# ============================================================
# DEBUG TREE
# ============================================================
func _debug_print_tree(
	root: Node,
	indent: String = ""
) -> void:
	print(
		indent,
		root.name,
		"  [",
		root.get_class(),
		"]"
	)

	for child in root.get_children():
		_debug_print_tree(
			child,
			indent + "  "
		)


# ============================================================
# LANDING PREDICTION
# ============================================================
func _predict_landing_within(
	lead_time: float
) -> bool:

	if not player:
		return false

	var down: Vector3 = -player.up_direction

	var fall_speed: float = player.velocity.dot(down)

	if fall_speed <= 0.0:
		return false

	var origin: Vector3 = player.global_position
	var target: Vector3 = (
		origin
		+ down * landing_predict_ray_length
	)

	var query := PhysicsRayQueryParameters3D.create(
		origin,
		target
	)

	query.exclude = [player]

	var hit := player.get_world_3d().direct_space_state.intersect_ray(
		query
	)

	if not hit:
		return false

	var raw_distance: float = (
		hit.position - origin
	).length()

	var distance: float = (
		raw_distance
		- ground_contact_offset
	)

	if distance <= 0.0:
		return true

	var time_to_land: float

	if fall_speed >= player.max_fall_speed:
		time_to_land = distance / fall_speed
	else:
		var a: float = maxf(
			player.get_fall_gravity(),
			0.001
		)

		var discriminant: float = (
			fall_speed * fall_speed
			+ 2.0 * a * distance
		)

		if discriminant < 0.0:
			return false

		time_to_land = (
			-fall_speed
			+ sqrt(discriminant)
		) / a

	return time_to_land <= lead_time


# ============================================================
# MAIN ANIMATION UPDATE
# ============================================================
func update(delta: float) -> void:

	if not animation_tree or not anim_playback:
		return

	var on_floor := player.is_on_floor()


	# --------------------------------------------------------
	# PREEMPTIVE LANDING
	# --------------------------------------------------------
	if not on_floor and not land_anim_active:
		if _predict_landing_within(land_anim_duration):

			land_anim_active = true
			current_anim_state = AnimState.LAND
			landing_timer = land_anim_duration

			anim_playback.travel("Land")


	# --------------------------------------------------------
	# REACTIVE LANDING
	# --------------------------------------------------------
	if !was_on_floor and on_floor and not land_anim_active:

		land_anim_active = true
		current_anim_state = AnimState.LAND
		landing_timer = land_anim_duration

		anim_playback.travel("Land")


	was_on_floor = on_floor


	# --------------------------------------------------------
	# LANDING ANIMATION ACTIVE
	# --------------------------------------------------------
	if landing_timer > 0.0:

		landing_timer -= delta

		if landing_timer <= 0.0:
			land_anim_active = false

		_update_locomotion_speed(delta)
		_update_foot_ik(delta)

		return


	land_anim_active = false


	# --------------------------------------------------------
	# SLIDE
	#
	# Remember that the player is sliding so that if they jump
	# during/at the end of the slide we can play
	# JumpOutOfSlide.
	# --------------------------------------------------------
	if player.is_sliding:

		was_sliding = true

		if current_anim_state != AnimState.SLIDE:

			current_anim_state = AnimState.SLIDE

			anim_playback.travel("Slide")

		_update_locomotion_speed(delta)
		_update_foot_ik(delta)

		return


	# ========================================================
	# AIRBORNE
	# ========================================================
	if !on_floor:

		# ----------------------------------------------------
		# JUMP OUT OF SLIDE
		#
		# This must happen before the normal jump check.
		#
		# If the player was sliding and is now airborne while
		# moving upward, play JumpOutOfSlide instead of Jump.
		# ----------------------------------------------------
		if was_sliding:

			var jumping_up: bool = (
				player.velocity.dot(
					player.up_direction
				) > 0.0
			)

			if jumping_up:

				if current_anim_state != AnimState.JUMP_OUT_OF_SLIDE:

					current_anim_state = AnimState.JUMP_OUT_OF_SLIDE

					anim_playback.travel(
						"JumpOutOfSlide"
					)

				was_sliding = false

				_update_locomotion_speed(delta)
				_update_foot_ik(delta)

				return

		# ----------------------------------------------------
		# WALL SLIDE
		# ----------------------------------------------------
		if player.is_wall_sliding:

			if current_anim_state != AnimState.WALL_SLIDE:

				current_anim_state = AnimState.WALL_SLIDE

				anim_playback.travel("WallSlide")

			_update_locomotion_speed(delta)
			_update_foot_ik(delta)

			return


		# ----------------------------------------------------
		# WALL RUN
		# ----------------------------------------------------
		if player.is_wall_running:

			if current_anim_state != AnimState.RUN:

				current_anim_state = AnimState.RUN

				anim_playback.travel(
					"BlendSpace1D"
				)

			_update_locomotion_speed(delta)

			animation_tree.set(
				LOCOMOTION_BLEND_PARAM,
				smoothed_locomotion_speed
			)

			_update_foot_ik(delta)

			return


		# ----------------------------------------------------
		# JUMP
		# ----------------------------------------------------
		var in_jump: bool = (
			player.jump_phase != Player.JumpPhase.NONE
			or player.velocity.dot(
				player.up_direction
			) > 0.0
		)

		if in_jump:

			if (
				current_anim_state != AnimState.JUMP
				and current_anim_state != AnimState.DOUBLE_JUMP
				and current_anim_state != AnimState.TRIPLE_JUMP
				and current_anim_state != AnimState.JUMP_OUT_OF_SLIDE
			):

				current_anim_state = AnimState.JUMP

				anim_playback.travel("Jump")

		# ----------------------------------------------------
		# FALL
		# ----------------------------------------------------
		else:

			if current_anim_state != AnimState.FALL:

				current_anim_state = AnimState.FALL

				anim_playback.travel("Fall")


		_update_locomotion_speed(delta)
		_update_foot_ik(delta)

		return


	# ========================================================
	# GROUNDED LOCOMOTION
	# ========================================================

	# If we are grounded and no longer sliding, clear the
	# previous-slide flag.
	was_sliding = false

	var was_grounded_locomotion := current_anim_state in [
		AnimState.IDLE,
		AnimState.JOG,
		AnimState.RUN
	]


	if player.move_input.length_squared() == 0.0:

		current_anim_state = AnimState.IDLE

	elif player.is_running:

		current_anim_state = AnimState.RUN

	else:

		current_anim_state = AnimState.JOG


	# Only travel into BlendSpace when entering normal
	# grounded locomotion.
	if not was_grounded_locomotion:

		anim_playback.travel(
			"BlendSpace1D"
		)


	_update_locomotion_speed(delta)

	animation_tree.set(
		LOCOMOTION_BLEND_PARAM,
		smoothed_locomotion_speed
	)

	_update_foot_ik(delta)


# ============================================================
# LOCOMOTION SPEED
# ============================================================
func _update_locomotion_speed(delta: float) -> void:

	var actual_speed: float = (
		player.get_planar_speed()
	)

	var weight: float = (
		1.0
		- exp(
			-delta
			/ max(
				speed_blend_smoothing_time,
				0.001
			)
		)
	)

	smoothed_locomotion_speed = lerpf(
		smoothed_locomotion_speed,
		actual_speed,
		weight
	)


# ============================================================
# DOUBLE JUMP
# ============================================================
func play_double_jump() -> void:

	if not animation_tree or not anim_playback:
		return

	current_anim_state = AnimState.DOUBLE_JUMP

	# A double jump is no longer a slide jump.
	was_sliding = false

	anim_playback.travel(
		"DoubleJump"
	)


# ============================================================
# TRIPLE JUMP
# ============================================================
func play_triple_jump() -> void:

	if not animation_tree or not anim_playback:
		return

	current_anim_state = AnimState.TRIPLE_JUMP

	# A triple jump is no longer a slide jump.
	was_sliding = false

	anim_playback.travel(
		"TripleJump"
	)


# ============================================================
# FOOT IK
# ============================================================
func _update_foot_ik(delta: float) -> void:

	if (
		not skeleton
		or left_bone_idx == -1
		or right_bone_idx == -1
	):
		return


	if not player.is_on_floor():

		left_weight = move_toward(
			left_weight,
			0.0,
			ik_blend_speed * delta
		)

		right_weight = move_toward(
			right_weight,
			0.0,
			ik_blend_speed * delta
		)

		return


	_solve_foot(
		left_bone_idx,
		left_target,
		delta,
		true
	)

	_solve_foot(
		right_bone_idx,
		right_target,
		delta,
		false
	)


# ============================================================
# SOLVE FOOT
# ============================================================
func _solve_foot(
	bone_idx: int,
	target: Node3D,
	delta: float,
	is_left: bool
) -> void:

	if not target:
		return


	var down: Vector3 = -player.up_direction

	var foot_global: Vector3 = (
		skeleton.global_transform
		* skeleton.get_bone_global_pose(
			bone_idx
		).origin
	)


	var origin := (
		foot_global
		- down * 0.3
	)

	var dest := (
		foot_global
		+ down * 0.3
	)


	var query := PhysicsRayQueryParameters3D.create(
		origin,
		dest
	)

	query.exclude = [player]


	var hit := (
		player
		.get_world_3d()
		.direct_space_state
		.intersect_ray(query)
	)


	if not hit:
		return


	var target_position: Vector3 = (
		hit.position
		- down * sole_offset
	)


	var height_above_ground: float = (
		foot_global - hit.position
	).length()


	var contact_target: float = (
		1.0
		if height_above_ground < foot_contact_threshold
		else 0.0
	)


	if is_left:

		left_weight = move_toward(
			left_weight,
			contact_target,
			ik_blend_speed * delta
		)

		target.global_position = (
			target.global_position.lerp(
				target_position,
				left_weight
			)
		)

	else:

		right_weight = move_toward(
			right_weight,
			contact_target,
			ik_blend_speed * delta
		)

		target.global_position = (
			target.global_position.lerp(
				target_position,
				right_weight
			)
		)


# ============================================================
# FORCE IDLE
# ============================================================
func force_idle() -> void:

	current_anim_state = AnimState.IDLE

	smoothed_locomotion_speed = 0.0

	current_wall_run_lean = 0.0

	was_sliding = false

	if animation_tree and anim_playback:

		anim_playback.travel(
			"BlendSpace1D"
		)

		animation_tree.set(
			LOCOMOTION_BLEND_PARAM,
			0.0
		)
