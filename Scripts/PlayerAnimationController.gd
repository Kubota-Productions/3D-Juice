extends Node
class_name PlayerAnimationController

@export var player: Player
@export var character_model: Node3D

var animation_tree: AnimationTree
var animation_player: AnimationPlayer
var anim_playback: AnimationNodeStateMachinePlayback

var mesh_instances: Array[MeshInstance3D] = []


@export_group("Locomotion Blend")
@export var speed_blend_smoothing_time: float = 0.06

var smoothed_locomotion_speed: float = 0.0


@export_group("Wall Run Lean")
@export var wall_run_lean_angle_deg: float = 8.0
@export var wall_run_lean_smoothing_speed: float = 10.0

var current_wall_run_lean: float = 0.0


@export_group("Wall Run Animation")
@export var wall_run_speed_scale_min: float = 0.25
@export var wall_run_speed_scale_max: float = 1.25

var _wall_run_time_scale_params: Dictionary = {}
var _current_wall_run_state: String = ""


@export_group("Landing Anticipation")
@export var land_anim_duration: float = 0.25
@export var landing_predict_ray_length: float = 50.0
@export var ground_contact_offset: float = 0.0

var land_anim_active: bool = false
var landing_timer: float = 0.0


@export_group("Jump To Fall")
@export var fall_anticipation_time: float = 0.1


@export_group("Slide Exit Blending")
## Crossfade (seconds) when the slide hands off to walking, jogging or
## running. Written onto the tree's Slide -> BlendSpace1D transition at
## startup. Set to -1 to leave whatever the AnimationTree editor has.
@export var slide_to_locomotion_blend_time: float = 0.25
## Same, for the Slide -> CrouchBlend transition.
@export var slide_to_crouch_blend_time: float = 0.2


enum AnimState {
	IDLE,
	JOG,
	RUN,
	SLIDE,
	WALL_SLIDE,
	WALL_KICK,
	JUMP,
	DOUBLE_JUMP,
	TRIPLE_JUMP,
	JUMP_OUT_OF_SLIDE,
	FALL,
	LAND,
	LEDGE_HANG,
	LEDGE_CLIMB,
	CROUCH,
	WALL_RUN
}

const LOCOMOTION_BLEND_PARAM := "parameters/BlendSpace1D/blend_position"

const CROUCH_BLEND_PARAM := "parameters/CrouchBlend/blend_position"

const SLIDE_STATE := "Slide"
const LOCOMOTION_STATE := "BlendSpace1D"
const CROUCH_STATE := "CrouchBlend"
const WALL_RUN_LEFT_STATE := "WallRunLeft"
const WALL_RUN_RIGHT_STATE := "WallRunRight"
const WALL_RUN_TIME_SCALE_NODE := "TimeScale"

var current_anim_state := AnimState.IDLE
var was_on_floor := true

var was_sliding := false

var _warned_missing_states: Array[String] = []


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

	_setup_wall_run_time_scale()

	animation_tree.active = true

	anim_playback = animation_tree.get(
		"parameters/playback"
	)

	if not anim_playback:
		push_error(
			"PlayerAnimationController: 'parameters/playback' came back null -- "
			+ "Tree Root probably isn't an AnimationNodeStateMachine"
		)

	_apply_slide_blend_times()

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


func _travel_if_present(state_name: String) -> void:
	var machine := animation_tree.tree_root as AnimationNodeStateMachine

	if machine and not machine.has_node(state_name):
		if not _warned_missing_states.has(state_name):
			_warned_missing_states.append(state_name)
			push_warning(
				"PlayerAnimationController: no '%s' state in the AnimationTree state machine"
				% state_name
			)
		return

	anim_playback.travel(state_name)


## How long travel() crossfades between two states is the xfade_time on the
## transition between them, and it defaults to 0 -- a hard cut. Nothing in
## this script ever set it, which is why leaving the slide looked immediate.
## Set it here so it doesn't have to be dialled in by hand in the editor.
func _apply_slide_blend_times() -> void:
	var machine := animation_tree.tree_root as AnimationNodeStateMachine
	if not machine:
		return

	var found_locomotion := false
	var found_crouch := false

	for i in machine.get_transition_count():
		if machine.get_transition_from(i) != SLIDE_STATE:
			continue

		var to_state: StringName = machine.get_transition_to(i)
		var transition: AnimationNodeStateMachineTransition = machine.get_transition(i)

		if to_state == LOCOMOTION_STATE:
			found_locomotion = true
			if slide_to_locomotion_blend_time >= 0.0:
				transition.xfade_time = slide_to_locomotion_blend_time
		elif to_state == CROUCH_STATE:
			found_crouch = true
			if slide_to_crouch_blend_time >= 0.0:
				transition.xfade_time = slide_to_crouch_blend_time

	# Without a direct transition, travel() routes through whatever states
	# do connect, so the exit blends through them instead of straight across.
	if machine.has_node(LOCOMOTION_STATE) and not found_locomotion:
		push_warning(
			"PlayerAnimationController: no direct '%s' -> '%s' transition in the AnimationTree; "
			% [SLIDE_STATE, LOCOMOTION_STATE]
			+ "leaving the slide into walk/run won't blend cleanly."
		)

	if machine.has_node(CROUCH_STATE) and not found_crouch:
		push_warning(
			"PlayerAnimationController: no direct '%s' -> '%s' transition in the AnimationTree; "
			% [SLIDE_STATE, CROUCH_STATE]
			+ "leaving the slide into a crouch won't blend cleanly."
		)


## Keeps both ground blend spaces positioned at the current speed. Called
## while sliding (when neither is the active state) so whichever one the slide
## hands off to is already at the right position when the crossfade begins.
func _push_blend_positions() -> void:
	animation_tree.set(LOCOMOTION_BLEND_PARAM, smoothed_locomotion_speed)
	animation_tree.set(CROUCH_BLEND_PARAM, smoothed_locomotion_speed)


func _setup_wall_run_time_scale() -> void:
	var machine := animation_tree.tree_root as AnimationNodeStateMachine
	if not machine:
		return

	for state_name in [WALL_RUN_LEFT_STATE, WALL_RUN_RIGHT_STATE]:
		_setup_state_time_scale(machine, state_name)


func _setup_state_time_scale(machine: AnimationNodeStateMachine, state_name: String) -> void:
	if not machine.has_node(state_name):
		return

	var state_node: AnimationNode = machine.get_node(state_name)
	var param: String = "parameters/%s/%s/scale" % [state_name, WALL_RUN_TIME_SCALE_NODE]

	if state_node is AnimationNodeBlendTree:
		var existing_tree := state_node as AnimationNodeBlendTree

		if existing_tree.has_node(WALL_RUN_TIME_SCALE_NODE):
			_wall_run_time_scale_params[state_name] = param
		else:
			push_warning(
				"PlayerAnimationController: '%s' is a blend tree with no '%s' node -- "
				% [state_name, WALL_RUN_TIME_SCALE_NODE]
				+ "add an AnimationNodeTimeScale with that name to control its speed."
			)
		return

	if not state_node is AnimationNodeAnimation:
		push_warning(
			"PlayerAnimationController: '%s' is a %s -- can't add speed control to it."
			% [state_name, state_node.get_class()]
		)
		return

	var blend_tree := AnimationNodeBlendTree.new()
	blend_tree.add_node("Animation", state_node, Vector2(-300.0, 0.0))
	blend_tree.add_node(WALL_RUN_TIME_SCALE_NODE, AnimationNodeTimeScale.new(), Vector2(0.0, 0.0))
	blend_tree.connect_node(WALL_RUN_TIME_SCALE_NODE, 0, "Animation")
	blend_tree.connect_node("output", 0, WALL_RUN_TIME_SCALE_NODE)

	machine.replace_node(state_name, blend_tree)

	_wall_run_time_scale_params[state_name] = param


func _get_wall_run_state_name() -> String:
	return WALL_RUN_RIGHT_STATE if player.wall_side > 0 else WALL_RUN_LEFT_STATE


func _get_wall_run_target_time_scale() -> float:
	var reference_speed: float = maxf(player.wall_run_speed, 0.001)

	return clampf(
		smoothed_locomotion_speed / reference_speed,
		wall_run_speed_scale_min,
		wall_run_speed_scale_max
	)


func _apply_wall_run_time_scale() -> void:
	var param: String = _wall_run_time_scale_params.get(_current_wall_run_state, "")
	if param.is_empty():
		return

	animation_tree.set(
		param,
		_get_wall_run_target_time_scale()
	)
func _find_first_of_type(root: Node, type_name: String) -> Node:
	for child in root.get_children():
		if child.is_class(type_name):
			return child

		var found := _find_first_of_type(child, type_name)

		if found:
			return found

	return null


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


func _is_still_rising() -> bool:
	match player.jump_phase:
		Player.JumpPhase.RISING:
			var until_fall: float = player.jump_phase_timer + maxf(player.jump_hang_time, 0.0)
			return until_fall > fall_anticipation_time
		Player.JumpPhase.HANGING:
			return player.jump_phase_timer > fall_anticipation_time

	return player.velocity.dot(player.up_direction) > 0.5


func update(delta: float) -> void:

	if not animation_tree or not anim_playback:
		return

	var on_floor := player.is_on_floor()

	if player.is_ledge_climbing or player.is_ledge_hanging:

		var ledge_target: AnimState = (
			AnimState.LEDGE_CLIMB if player.is_ledge_climbing else AnimState.LEDGE_HANG
		)

		if current_anim_state != ledge_target:

			current_anim_state = ledge_target

			_travel_if_present(
				"LedgeClimb" if player.is_ledge_climbing else "LedgeHang"
			)

		was_on_floor = true
		was_sliding = false
		land_anim_active = false
		landing_timer = 0.0

		_update_locomotion_speed(delta)

		return

	if (
		not on_floor
		and not land_anim_active
		and not player.is_wall_sliding
		and not player.is_wall_running
		and not player.is_sliding
	):
		if _predict_landing_within(land_anim_duration):

			land_anim_active = true
			current_anim_state = AnimState.LAND
			landing_timer = land_anim_duration

			anim_playback.travel("Land")

	if !was_on_floor and on_floor and not land_anim_active and not player.is_sliding:

		land_anim_active = true
		current_anim_state = AnimState.LAND
		landing_timer = land_anim_duration

		anim_playback.travel("Land")

	was_on_floor = on_floor

	if landing_timer > 0.0:

		landing_timer -= delta

		if landing_timer <= 0.0:
			land_anim_active = false

		_update_locomotion_speed(delta)

		return

	land_anim_active = false

	if player.is_sliding:

		was_sliding = true

		if current_anim_state != AnimState.SLIDE:

			current_anim_state = AnimState.SLIDE

			anim_playback.travel(SLIDE_STATE)

		_update_locomotion_speed(delta)
		_push_blend_positions()

		return

	if !on_floor:

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

				return

		if player.is_wall_sliding:

			if current_anim_state != AnimState.WALL_SLIDE:

				current_anim_state = AnimState.WALL_SLIDE

				anim_playback.travel("WallSlide")

			_update_locomotion_speed(delta)

			return

		if player.is_wall_running:

			var wall_run_state: String = _get_wall_run_state_name()

			if current_anim_state != AnimState.WALL_RUN or _current_wall_run_state != wall_run_state:

				current_anim_state = AnimState.WALL_RUN
				_current_wall_run_state = wall_run_state

				_travel_if_present(wall_run_state)

			_update_locomotion_speed(delta)
			_apply_wall_run_time_scale()

			animation_tree.set(
				LOCOMOTION_BLEND_PARAM,
				smoothed_locomotion_speed
			)

			return

		var in_jump: bool = _is_still_rising()

		if in_jump:

			if (
				current_anim_state != AnimState.JUMP
				and current_anim_state != AnimState.DOUBLE_JUMP
				and current_anim_state != AnimState.TRIPLE_JUMP
				and current_anim_state != AnimState.JUMP_OUT_OF_SLIDE
				and current_anim_state != AnimState.WALL_KICK
			):

				current_anim_state = AnimState.JUMP

				anim_playback.travel("Jump")

		else:

			if current_anim_state != AnimState.FALL:

				current_anim_state = AnimState.FALL

				anim_playback.travel("Fall")

		_update_locomotion_speed(delta)

		return

	was_sliding = false

	if player.is_crouching:
		_update_locomotion_speed(delta)

		# Position the blend space before travelling into it so the
		# crossfade starts from the right pose.
		animation_tree.set(
			CROUCH_BLEND_PARAM,
			smoothed_locomotion_speed
		)

		if current_anim_state != AnimState.CROUCH:
			current_anim_state = AnimState.CROUCH
			_travel_if_present(CROUCH_STATE)

		return

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

	_update_locomotion_speed(delta)

	# Position the blend space before travelling into it so the crossfade
	# (out of the slide, crouch, a jump...) starts from the right pose.
	animation_tree.set(
		LOCOMOTION_BLEND_PARAM,
		smoothed_locomotion_speed
	)

	if not was_grounded_locomotion:

		anim_playback.travel(
			LOCOMOTION_STATE
		)


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


func play_double_jump() -> void:

	if not animation_tree or not anim_playback:
		return

	current_anim_state = AnimState.DOUBLE_JUMP

	was_sliding = false

	anim_playback.travel(
		"DoubleJump"
	)


func play_triple_jump() -> void:

	if not animation_tree or not anim_playback:
		return

	current_anim_state = AnimState.TRIPLE_JUMP

	was_sliding = false

	anim_playback.travel(
		"TripleJump"
	)


func play_wall_kick() -> void:

	if not animation_tree or not anim_playback:
		return

	current_anim_state = AnimState.WALL_KICK

	was_sliding = false
	land_anim_active = false
	landing_timer = 0.0

	_travel_if_present(
		"WallKick"
	)


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
