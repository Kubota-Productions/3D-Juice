class_name Player
extends CharacterBody3D

@onready var character_model: Node3D = $CharacterModel
@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera_3d: Camera3D = $SpringArm3D/Cameraoffset/Camera3D
@onready var aim_pivot: Node3D = $"../AimPivot"
@onready var telekinesis_controller: TelekinesisController = $TelekinesisController
@onready var combat_controller: CombatController = $CombatController
@onready var interaction_highlight_controller: InteractionHighlightController = $InteractionHighlightController

@onready var player_collision_shape: CollisionShape3D = get_node_or_null("CollisionShape3D")
const NORMAL_COLLISION_Y := 0.672
const NORMAL_COLLISION_HEIGHT := 1.344
# The short collider is shared by the slide and the crouch.
const SLIDE_COLLISION_Y := 0.33
const SLIDE_COLLISION_HEIGHT := 0.672

## Full-height capsule used only to ask "would standing up here overlap
## anything?" -- the real collider is the short one while sliding.
var _stand_check_shape: CapsuleShape3D

## How much upward speed move_and_slide() is allowed to add on its own
## while airborne (see _limit_unearned_rise).
const MAX_UNEARNED_RISE_TOLERANCE := 0.25

@export var animation_controller: Node
var pending_acceleration: Vector3 = Vector3.ZERO
var _current_delta: float = 0.016
var movement_locked: bool = false


static func acceleration_toward(
	current: Vector3,
	target: Vector3,
	max_accel: float,
	delta: float
) -> Vector3:
	var needed: Vector3 = (target - current) / max(delta, 0.0001)

	if needed.length() > max_accel:
		return needed.normalized() * max_accel

	return needed


func add_acceleration(accel: Vector3) -> void:
	pending_acceleration += accel


func add_impulse(impulse: Vector3) -> void:
	pending_acceleration += impulse / max(_current_delta, 0.0001)


func _integrate_velocity(delta: float) -> void:
	velocity += pending_acceleration * delta
	pending_acceleration = Vector3.ZERO


func hard_stop() -> void:
	velocity = Vector3.ZERO
	pending_acceleration = Vector3.ZERO
	jump_phase = JumpPhase.NONE
	jump_phase_timer = 0.0
	_set_jump_profile()
	_cancel_slide()
	_end_crouch(false)
	_end_wall_movement(false)
	_wall_lockout_timer = 0.0
	_wall_kick_face_timer = 0.0
	_set_ledge_state(LedgeState.NONE)


@export var rotation_pivot: Node3D

@export var frame_anchor_height_offset: float = 0.3

var body_center_offset: Vector3 = Vector3.ZERO


func _resolve_body_center_offset() -> void:
	if not rotation_pivot:
		push_warning("Player: 'rotation_pivot' not assigned -- camera/aim anchor will use the body origin (feet).")
		body_center_offset = Vector3.ZERO
		return

	body_center_offset = global_basis.inverse() * (rotation_pivot.global_position - global_position)


func get_body_center() -> Vector3:
	return global_position + global_basis * body_center_offset


func get_camera_anchor() -> Vector3:
	return get_body_center() + up_direction * frame_anchor_height_offset


func set_body_center(world_center: Vector3) -> void:
	global_position = world_center - global_basis * body_center_offset


@export_group("Movement")
@export var walk_speed: float = 2.5
@export var run_speed: float = 5.0
@export var move_acceleration: float = 35.0
@export var move_deceleration: float = 45.0
@export var rotation_speed: float = 8.0
@export var landing_brake_acceleration: float = 60.0
@export var landing_brake_time: float = 0.3
@export var max_landing_speed: float = 8.0

var landing_brake_timer: float = 0.0
@export var run_ramp_time: float = 0.35


@export_group("Slide")
@export var slide_speed: float = 7.5
@export var slide_end_speed: float = 3.0
@export var slide_duration: float = 0.7
@export var slide_acceleration: float = 40.0
@export var slide_jump_speed: float = 10.0
@export var slide_jump_height: float = 1.2
@export var slide_jump_rise_time: float = 0.45
@export var slide_jump_fall_time: float = 0.44
@export var slide_jump_air_control: float = 0.1
@export var slide_max_speed: float = 14.0
@export var slide_slope_acceleration: float = 14.0
@export var slide_slope_min_angle_deg: float = 8.0
@export var slide_slope_full_angle_deg: float = 35.0
## While sliding, surfaces up to this steep still count as floor (the
## CharacterBody3D default of 45 degrees is what used to drop the player off
## steeper slopes). Never lowers the body's own floor_max_angle.
@export_range(0.0, 89.0) var slide_floor_max_angle_deg: float = 75.0
## While sliding, how far the body will snap back down to the surface after
## a frame of moving off it. At speed on a downhill the ground drops away
## faster than the default snap (0.1) can follow, so the player went
## airborne. Never lowers the body's own floor_snap_length.
@export var slide_floor_snap_length: float = 0.5
## How long the slide survives while airborne (bumps, crests, small drops)
## before it ends. Slide jumps stay available during this window.
@export var slide_air_grace: float = 0.3
## Walking up a slope that's too steep to stand on (steeper than the body's
## normal floor limit, up to slide_floor_max_angle_deg) puts you in a slide
## back down it.
@export var slide_from_steep_slopes: bool = true


@export_group("Crouch")
## Walking speed while crouched. Normal walking is walk_speed.
@export var crouch_speed: float = 1.75
## false: hold Crouch to stay crouched. true: tap Crouch to toggle.
@export var crouch_is_toggle: bool = false
## Jumping out of a crouch uses this profile instead of the normal jump.
## Keep the rise/fall times in proportion to the height, or the gravity
## gets very heavy/floaty (the defaults roughly match the normal jump's gravity).
@export var crouch_jump_height: float = 4.0
@export var crouch_jump_rise_time: float = 0.57
@export var crouch_jump_fall_time: float = 0.5
@export var crouch_jump_air_control: float = 0.45


@export_group("Wall Movement")
@export var wall_check_distance: float = 0.8
@export var wall_run_speed: float = 6.0
@export var wall_run_min_speed: float = 4.0
@export var wall_run_max_time: float = 1.6
@export var wall_run_arc_height: float = 0.6
@export_range(0.1, 0.9) var wall_run_apex_fraction: float = 0.4
@export var wall_slide_speed: float = 2.0
@export var wall_slide_turn_speed: float = 16.0
@export var wall_kick_turn_speed: float = 20.0
@export var wall_kick_face_time: float = 0.4
@export var wall_jump_away_speed: float = 6.5
@export var wall_jump_air_control: float = 0.2
@export var wall_regrab_delay: float = 0.25
@export_range(0, 10, 1, "or_greater") var max_wall_runs: int = 1
@export_range(0, 10, 1, "or_greater") var max_wall_slides: int = 1

const SLIDE_JUMP_GRACE := 0.15
const SLIDE_MIN_SPEED := 1.0
## On surfaces steeper than the body's normal floor limit, the slide ends if
## it is heading up them (dot with the downhill direction below this value).
const SLIDE_STEEP_UPHILL_LIMIT := -0.2
## How directly the player has to be pushing up a too-steep slope (dot of
## the input with the uphill direction) before it counts as an attempt to climb it.
const STEEP_SLOPE_PUSH_THRESHOLD := 0.3
## Lifts the standing-height overlap test slightly off the floor so the
## ground the player is already touching doesn't count as an obstruction.
const STAND_CHECK_LIFT := 0.04
## Releasing Crouch a moment before pressing jump still counts as a crouch jump.
const CROUCH_JUMP_GRACE := 0.1
const CROUCH_ACTION := &"Crouch"
const WALL_RUN_MAX_APPROACH := 0.64
const WALL_SLIDE_MIN_APPROACH := 0.3
const WALL_STICK_SPEED := 1.0
const WALL_RUN_ACCELERATION := 40.0
const WALL_VERTICAL_ACCELERATION := 30.0


@export_group("Ledge Grab")
@export var ledge_reach: float = 0.7
@export var ledge_wall_check_height: float = 0.9
@export var ledge_min_height: float = 1.0
@export var ledge_max_height: float = 1.8
@export var ledge_top_probe_depth: float = 0.15
@export var ledge_max_rise_speed: float = 3.0
@export var ledge_hang_drop: float = 1.5
@export var ledge_wall_gap: float = 0.05
@export var ledge_stand_inset: float = 0.15
@export var ledge_snap_time: float = 0.08
@export var ledge_min_hang_time: float = 0.15
@export var ledge_climb_time: float = 0.6
@export_range(0.05, 0.95) var ledge_climb_vertical_fraction: float = 0.65
@export var ledge_regrab_delay: float = 0.4
@export var ledge_drop_push: float = 1.5
@export_range(0.0, 1.0) var ledge_support_footprint: float = 0.9
@export var ledge_support_tolerance: float = 0.2
@export var ledge_path_check_step: float = 0.3

const LEDGE_MIN_TOP_NORMAL := 0.7
const LEDGE_STAND_LIFT := 0.03
const LEDGE_CLEARANCE_LIFT := 0.04


@export_group("Run Dust")
@export var Particle_Controller: ParticleController

var move_input: Vector2 = Vector2.ZERO
var move_direction: Vector3 = Vector3.ZERO
var current_speed: float = 0.0
var is_running := false
var is_power_sprinting := false
var run_timer := 0.0
var run_blend: float = 0.0

const RUN_THRESHOLD := 0.40

@export_group("Lean")
@export var lean_max_angle_deg: float = 20.0
@export var lean_smoothing_speed: float = 6.0
@export var lean_turn_rate_reference: float = 3.0
@export var lean_high_speed_multiplier: float = 1.8
@export var lean_speed_curve_power: float = 1.5
@export var lean_top_speed: float = 9.0
@export var wall_run_lean_angle_deg: float = 8.0

@export_group("Squash & Stretch")
@export var squash_stretch_max_stretch: float = 0.12
@export var squash_stretch_max_squash: float = 0.16
@export var squash_stretch_speed_start: float = 4.0
@export var squash_stretch_vertical_speed: float = 10.0
@export var squash_stretch_slide_squash: float = 0.06
@export var squash_landing_min_speed: float = 4.0
@export var squash_landing_full_speed: float = 14.0
@export var squash_stretch_stiffness: float = 250.0
@export var squash_stretch_damping: float = 15.0

var model_yaw_basis: Basis = Basis.IDENTITY
var model_base_scale: Vector3 = Vector3.ONE
var current_lean: float = 0.0
var current_squash_stretch: float = 0.0
var current_squash_stretch_velocity: float = 0.0
var _last_air_fall_speed: float = 0.0


@export_group("Jumping")
@export var jump_height: float = 2.0
@export var jump_rise_time: float = 0.4
@export var jump_hang_time: float = 0.1
@export var jump_fall_time: float = 0.35
@export var max_fall_speed: float = 30.0
@export var jump_air_control: float = 0.45
@export var coyote_time: float = 0.15
@export var jump_buffer: float = 0.15
@export var max_jumps: int = 3

enum JumpPhase { NONE, RISING, HANGING }
enum JumpKind { NORMAL, SLIDE, WALL, CROUCH }

var jump_phase: JumpPhase = JumpPhase.NONE
var jump_phase_timer: float = 0.0

var _active_jump_velocity: float = 0.0
var _active_rise_time: float = 0.0
var _active_hang_time: float = 0.0
var _active_rise_gravity: float = 0.0
var _active_fall_gravity: float = 0.0
var _active_air_control: float = 0.45

var jumps_used: int = 0
var coyote_timer := 0.0
var jump_buffer_timer := 0.0
var was_grounded_last_frame := true


@export_group("OTS Explore Mode")
var is_ots_mode: bool = false

var turn_rate: float = 0.0
var prev_model_forward: Vector3 = Vector3.FORWARD


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_default_floor_max_angle = floor_max_angle
	_default_floor_snap_length = floor_snap_length

	model_yaw_basis = character_model.global_basis
	model_base_scale = character_model.scale

	_resolve_body_center_offset()
	_set_jump_profile()

	if player_collision_shape and player_collision_shape.shape:
		player_collision_shape.shape = player_collision_shape.shape.duplicate()
		_set_short_collision(false)
		_build_stand_check_shape()

	if not InputMap.has_action(CROUCH_ACTION):
		push_warning("Player: no 'Crouch' action in the Input Map -- crouching is disabled.")

	telekinesis_controller.setup(self, camera_3d)
	combat_controller.setup(self, camera_3d)
	interaction_highlight_controller.setup(self, camera_3d)

	if Particle_Controller:
		Particle_Controller.setup(self)


func _unhandled_input(event: InputEvent) -> void:

	if event.is_action_pressed("ToggleOTS"):
		if is_ots_mode:
			is_ots_mode = false
		elif is_on_floor() and (not is_sliding or _can_stand_up()):
			is_ots_mode = true

	telekinesis_controller.handle_input(event)
	combat_controller.handle_input(event)

	if event is InputEventMouseMotion:

		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return

		if move_input == Vector2.ZERO and !spring_arm.camera_moved:

			var yaw_delta: float = -event.relative.x * spring_arm.mouse_sensitivity

			if abs(yaw_delta) > 0.01:
				spring_arm.camera_moved = true


func _physics_process(delta: float) -> void:

	_current_delta = delta

	spring_arm.update_look(delta)

	_ledge_lockout_timer = maxf(_ledge_lockout_timer - delta, 0.0)

	_read_input(delta)
	_update_ground_state(delta)

	if ledge_state == LedgeState.NONE:
		_update_slide(delta)
		_update_crouch(delta)
		_update_wall_movement(delta)
		_try_grab_ledge()

	if ledge_state != LedgeState.NONE:
		_update_ledge(delta)
	else:
		if is_ots_mode and not is_on_floor():
			is_ots_mode = false

		_handle_movement(delta)
		_handle_jump(delta)

		_apply_gravity(delta)

		_integrate_velocity(delta)

		var up_speed_before: float = velocity.dot(up_direction)
		move_and_slide()
		_limit_unearned_rise(up_speed_before)
		_try_steep_slope_slide()

	aim_pivot.global_position = get_body_center()
	spring_arm.update_pivot_position(delta)

	telekinesis_controller.update(delta)
	combat_controller.update(delta)
	interaction_highlight_controller.update(delta)

	if Particle_Controller:
		Particle_Controller.update(delta)

	if animation_controller:
		animation_controller.update(delta)


func _read_input(delta: float) -> void:

	if movement_locked:
		move_input = Vector2.ZERO
		run_timer = 0.0
		is_running = false
		jump_buffer_timer = 0.0
		return

	move_input.x = Input.get_axis("left", "right")
	move_input.y = Input.get_axis("forward", "backwards")

	if is_ots_mode:
		run_timer = 0.0
		is_running = false
		jump_buffer_timer = 0.0
		return

	if Input.is_action_pressed("Run") and move_input.length_squared() > 0.0 and not is_crouching:
		run_timer += delta

		if run_timer >= RUN_THRESHOLD:
			is_running = true
	else:
		run_timer = 0.0
		is_running = false

	if Input.is_action_just_pressed("Jump"):
		jump_buffer_timer = jump_buffer

	if jump_buffer_timer > 0.0:
		jump_buffer_timer -= delta


func _get_input_direction() -> Vector3:
	if move_input.length_squared() == 0.0:
		return Vector3.ZERO

	var up := up_direction

	var camera_forward: Vector3 = aim_pivot.global_basis.z
	camera_forward = camera_forward.slide(up)
	if camera_forward.length_squared() > 0.001:
		camera_forward = camera_forward.normalized()

	var camera_right: Vector3 = aim_pivot.global_basis.x
	camera_right = camera_right.slide(up)
	if camera_right.length_squared() > 0.001:
		camera_right = camera_right.normalized()

	return (camera_forward * move_input.y + camera_right * move_input.x).normalized()


func _update_ground_state(delta: float) -> void:

	if is_on_floor():
		var planar_velocity: Vector3 = velocity.slide(up_direction)

		if not was_grounded_last_frame:
			_trigger_landing_squash(_last_air_fall_speed)
		_last_air_fall_speed = 0.0

		if not was_grounded_last_frame and not is_sliding and planar_velocity.length() > max_landing_speed:
			landing_brake_timer = landing_brake_time

		# A slide re-touching the ground at speed is not a hard landing; the
		# brake would drag it down to max_landing_speed.
		if is_sliding:
			landing_brake_timer = 0.0
		elif landing_brake_timer > 0.0:
			landing_brake_timer -= delta

			if planar_velocity.length() > max_landing_speed:
				var capped: Vector3 = planar_velocity.normalized() * max_landing_speed
				add_acceleration(
					acceleration_toward(planar_velocity, capped, landing_brake_acceleration, delta)
				)

		coyote_timer = coyote_time
		jumps_used = 0
		jump_phase = JumpPhase.NONE
		_wall_kick_face_timer = 0.0
		_set_jump_profile()
	else:
		coyote_timer -= delta
		landing_brake_timer = 0.0
		_last_air_fall_speed = maxf(-velocity.dot(up_direction), 0.0)

	was_grounded_last_frame = is_on_floor()


func _trigger_landing_squash(impact_speed: float) -> void:
	var span: float = maxf(squash_landing_full_speed - squash_landing_min_speed, 0.001)
	var strength: float = clampf((impact_speed - squash_landing_min_speed) / span, 0.0, 1.0)

	if strength <= 0.0:
		return

	current_squash_stretch = minf(current_squash_stretch, -strength * squash_stretch_max_squash)
	current_squash_stretch_velocity = 0.0


func _set_jump_profile(kind: JumpKind = JumpKind.NORMAL) -> void:
	var height: float = jump_height
	var rise_t: float = jump_rise_time
	var fall_t: float = jump_fall_time
	var air_control: float = jump_air_control

	match kind:
		JumpKind.SLIDE:
			height = slide_jump_height
			rise_t = slide_jump_rise_time
			fall_t = slide_jump_fall_time
			air_control = slide_jump_air_control
		JumpKind.WALL:
			air_control = wall_jump_air_control
		JumpKind.CROUCH:
			height = crouch_jump_height
			rise_t = crouch_jump_rise_time
			fall_t = crouch_jump_fall_time
			air_control = crouch_jump_air_control

	rise_t = maxf(rise_t, 0.01)
	fall_t = maxf(fall_t, 0.01)

	_active_rise_time = rise_t
	_active_hang_time = maxf(jump_hang_time, 0.0)
	_active_jump_velocity = 2.0 * height / rise_t
	_active_rise_gravity = 2.0 * height / (rise_t * rise_t)
	_active_fall_gravity = 2.0 * height / (fall_t * fall_t)
	_active_air_control = air_control


func get_fall_gravity() -> float:
	return _active_fall_gravity


func _apply_gravity(delta: float) -> void:

	if wall_state == WallState.RUNNING:
		add_acceleration(acceleration_toward(
			(velocity + pending_acceleration * delta).project(up_direction),
			up_direction * _get_wall_run_vertical_speed(),
			WALL_VERTICAL_ACCELERATION,
			delta
		))
		return

	if wall_state == WallState.SLIDING:
		add_acceleration(acceleration_toward(
			velocity.project(up_direction),
			-up_direction * wall_slide_speed,
			WALL_VERTICAL_ACCELERATION,
			delta
		))
		return

	if jump_phase == JumpPhase.RISING and is_on_ceiling():
		jump_phase = JumpPhase.NONE

	if jump_phase == JumpPhase.RISING:
		add_acceleration(-up_direction * _active_rise_gravity)

		jump_phase_timer -= delta
		if jump_phase_timer <= 0.0:
			if _active_hang_time > 0.0:
				jump_phase = JumpPhase.HANGING
				jump_phase_timer = _active_hang_time
			else:
				jump_phase = JumpPhase.NONE
		return

	if jump_phase == JumpPhase.HANGING:
		add_acceleration(-velocity.project(up_direction) / maxf(delta, 0.0001))

		jump_phase_timer -= delta
		if jump_phase_timer <= 0.0:
			jump_phase = JumpPhase.NONE
		return

	if velocity.dot(up_direction) > -max_fall_speed:
		add_acceleration(-up_direction * get_fall_gravity())


## Safety net for collision response. move_and_slide() can redirect
## horizontal speed upward when the capsule catches a corner/edge or a steep
## face while airborne (which is how a slide at speed can turn into
## free height). Nothing the player does intentionally adds upward speed
## *during* move_and_slide -- jumps, wall-run arcs, etc. are all applied
## before it -- so any upward speed that appears while airborne beyond what
## went in is removed. Grounded frames are skipped so ramps still carry you up.
func _limit_unearned_rise(up_speed_before: float) -> void:
	if is_on_floor():
		return

	var up_speed_after: float = velocity.dot(up_direction)
	var allowed: float = maxf(up_speed_before, 0.0)

	if up_speed_after > allowed + MAX_UNEARNED_RISE_TOLERANCE:
		velocity -= up_direction * (up_speed_after - allowed)


func _handle_jump(_delta: float) -> void:

	if jump_buffer_timer <= 0.0:
		return

	# No headroom to stand up means no room to jump out of the crouch/slide
	# either (the collider would grow inside the ceiling mid-air). The
	# buffered press stays alive, so the jump still fires if they clear the
	# cover in time.
	if (is_sliding or is_crouching) and not _can_stand_up():
		return

	if wall_state != WallState.NONE:
		_start_wall_jump()
		return

	if coyote_timer > 0.0:
		if is_sliding or _slide_jump_grace_timer > 0.0:
			_start_jump(JumpKind.SLIDE, _slide_direction * maxf(slide_jump_speed, _slide_speed))
			_end_slide(false)
			_end_crouch(false)
		elif is_crouching or _crouch_jump_grace_timer > 0.0:
			_start_jump(JumpKind.CROUCH)
			_end_crouch(false)
		else:
			_start_jump()

		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jumps_used = 1

	elif jumps_used < max_jumps:
		_start_jump()
		jump_buffer_timer = 0.0

		if animation_controller:
			match jumps_used:
				1:
					animation_controller.play_double_jump()
				2:
					animation_controller.play_triple_jump()

		jumps_used += 1


func _start_jump(kind: JumpKind = JumpKind.NORMAL, planar_launch: Vector3 = Vector3.ZERO) -> void:
	_set_jump_profile(kind)

	if kind != JumpKind.WALL:
		_wall_kick_face_timer = 0.0

	# Other systems can already have queued vertical acceleration this frame
	# (e.g. the wall-run entry impulse, which fires in the same frame as a
	# buffered wall jump). Cancelling only the *current* velocity meant that
	# vertical speed got cancelled twice, so the jump launched with the old
	# fall speed added on top -- a big free boost. Cancel the velocity as it
	# will be once the queued acceleration is integrated instead.
	var predicted_velocity: Vector3 = velocity + pending_acceleration * _current_delta
	var impulse: Vector3 = -predicted_velocity.project(up_direction) + up_direction * _active_jump_velocity

	if kind == JumpKind.SLIDE or kind == JumpKind.WALL:
		impulse += planar_launch - velocity.slide(up_direction)

	add_impulse(impulse)
	jump_phase = JumpPhase.RISING
	jump_phase_timer = _active_rise_time


var is_sliding := false
var slide_timer: float = 0.0
var _slide_direction: Vector3 = Vector3.ZERO
var _slide_jump_grace_timer: float = 0.0
var _slide_speed: float = 0.0
var _slide_elapsed: float = 0.0
var _slide_air_time: float = 0.0
var _slide_last_downhill: float = 0.0

## The body's own floor settings, cached in _ready so the slide can raise
## them temporarily and put them back afterwards.
var _default_floor_max_angle: float = 0.785398
var _default_floor_snap_length: float = 0.1


func _can_start_slide() -> bool:
	return is_on_floor() and is_running and get_planar_speed() > walk_speed


func _start_slide() -> void:
	var heading: Vector3 = velocity.slide(up_direction)
	if heading.length_squared() < 0.0001:
		return

	_begin_slide(heading.normalized())


func _begin_slide(direction: Vector3) -> void:
	_slide_direction = direction
	is_sliding = true
	slide_timer = 0.0
	_slide_speed = slide_speed
	_slide_elapsed = 0.0
	_slide_air_time = 0.0
	_slide_last_downhill = 0.0
	_slide_jump_grace_timer = 0.0
	landing_brake_timer = 0.0
	_refresh_collision()


func _end_slide(allow_jump_grace: bool) -> void:
	is_sliding = false
	slide_timer = 0.0
	_slide_jump_grace_timer = SLIDE_JUMP_GRACE if allow_jump_grace else 0.0
	_refresh_collision()


func _cancel_slide() -> void:
	is_sliding = false
	slide_timer = 0.0
	_slide_jump_grace_timer = 0.0
	_refresh_collision()


## The short collider is used whenever the player is sliding OR crouching.
## Also swaps the body's floor settings, which only the slide changes.
func _refresh_collision() -> void:
	_set_short_collision(is_sliding or is_crouching)
	_apply_slide_floor_settings()


func _apply_slide_floor_settings() -> void:
	if is_sliding:
		floor_max_angle = maxf(_default_floor_max_angle, deg_to_rad(slide_floor_max_angle_deg))
		floor_snap_length = maxf(_default_floor_snap_length, slide_floor_snap_length)
	else:
		floor_max_angle = _default_floor_max_angle
		floor_snap_length = _default_floor_snap_length


## True when the slide is heading up a surface that only counts as floor
## because of the slide's raised floor angle (i.e. steeper than the body's
## normal limit). Without this the slide would run up steep walls.
func _slide_climbing_steep_slope() -> bool:
	if not is_on_floor():
		return false

	var floor_normal: Vector3 = get_floor_normal()
	var angle: float = acos(clampf(floor_normal.dot(up_direction), -1.0, 1.0))
	if angle <= _default_floor_max_angle:
		return false

	var downhill: Vector3 = floor_normal.slide(up_direction)
	if downhill.length_squared() < 0.0001:
		return false

	return _slide_direction.dot(downhill.normalized()) < SLIDE_STEEP_UPHILL_LIMIT


func _set_short_collision(short: bool) -> void:
	if not player_collision_shape:
		return

	var capsule := player_collision_shape.shape as CapsuleShape3D
	if not capsule:
		push_warning("Player: CollisionShape3D must use a CapsuleShape3D for slide collision resizing.")
		return

	player_collision_shape.position.y = SLIDE_COLLISION_Y if short else NORMAL_COLLISION_Y
	capsule.height = SLIDE_COLLISION_HEIGHT if short else NORMAL_COLLISION_HEIGHT


func _build_stand_check_shape() -> void:
	var capsule := player_collision_shape.shape as CapsuleShape3D
	if not capsule:
		return

	_stand_check_shape = capsule.duplicate() as CapsuleShape3D
	_stand_check_shape.height = NORMAL_COLLISION_HEIGHT


## True if the full-height collider would fit at the player's current
## position. Used so the slide never ends (and the collider never grows)
## while there's geometry overhead for it to grow into.
func _can_stand_up() -> bool:
	if not _stand_check_shape:
		return true

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if not space:
		return true

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _stand_check_shape
	query.transform = Transform3D(
		global_basis.orthonormalized(),
		global_position + up_direction * (NORMAL_COLLISION_Y + STAND_CHECK_LIFT)
	)
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]

	return space.intersect_shape(query, 1).is_empty()


## Blocked by something while crouched under cover: hand steering back to the
## player so they can crawl back out instead of being stuck in the slide.
func _steer_slide_in_crawlspace() -> void:
	var input_direction: Vector3 = _get_input_direction()
	if input_direction.length_squared() < 0.0001:
		return

	_slide_direction = input_direction
	_slide_elapsed = 0.0


## Slide and Crouch are treated as one pair of buttons: either one starts a
## slide when you're at slide speed, and either one holds the crouch.
func _crouch_slide_pressed() -> bool:
	if Input.is_action_just_pressed("Slide"):
		return true

	return InputMap.has_action(CROUCH_ACTION) and Input.is_action_just_pressed(CROUCH_ACTION)


func _crouch_slide_held() -> bool:
	if Input.is_action_pressed("Slide"):
		return true

	return InputMap.has_action(CROUCH_ACTION) and Input.is_action_pressed(CROUCH_ACTION)


## The slide ran its course. If the slide/crouch button is still held, drop
## straight into a crouch instead of standing up. (Jumping out of the slide,
## losing the ground, or entering OTS mode use _end_slide() directly and never
## crouch.) The crouch starts before the slide ends so the short collider
## never grows for a frame in between.
func _finish_slide(allow_jump_grace: bool) -> void:
	var stay_low: bool = (
		is_on_floor()
		and InputMap.has_action(CROUCH_ACTION)
		and _crouch_slide_held()
	)

	if stay_low:
		is_running = false
		run_timer = 0.0
		_start_crouch()

	_end_slide(allow_jump_grace)


## Attempting to walk up a slope too steep to stand on (steeper than the
## body's normal floor limit, but within what the slide can grip) puts the
## player into a slide back down it.
func _try_steep_slope_slide() -> void:
	if not slide_from_steep_slopes:
		return

	if is_sliding or movement_locked or is_ots_mode or wall_state != WallState.NONE:
		return

	if jump_phase == JumpPhase.RISING:
		return

	var input_direction: Vector3 = _get_input_direction()
	if input_direction.length_squared() < 0.0001:
		return

	var steepest_walkable: float = _default_floor_max_angle
	var steepest_gripped: float = deg_to_rad(slide_floor_max_angle_deg)

	for i in get_slide_collision_count():
		var collision: KinematicCollision3D = get_slide_collision(i)
		var normal: Vector3 = collision.get_normal()
		var angle: float = acos(clampf(normal.dot(up_direction), -1.0, 1.0))

		if angle <= steepest_walkable or angle > steepest_gripped:
			continue

		# The contact has to be down at the feet (walking into or standing on
		# the slope), not the upper body brushing it mid-jump.
		var contact_height: float = (collision.get_position() - global_position).dot(up_direction)
		if contact_height > NORMAL_COLLISION_HEIGHT * 0.5:
			continue

		var downhill: Vector3 = normal.slide(up_direction)
		if downhill.length_squared() < 0.0001:
			continue
		downhill = downhill.normalized()

		# Only when pushing up the slope, not along or away from it.
		if input_direction.dot(downhill) > -STEEP_SLOPE_PUSH_THRESHOLD:
			continue

		_begin_slide(downhill)
		return


func _update_slide(delta: float) -> void:

	_slide_jump_grace_timer = maxf(_slide_jump_grace_timer - delta, 0.0)

	if is_sliding:
		_slide_elapsed += delta

		if is_on_floor():
			_slide_air_time = 0.0
		else:
			_slide_air_time += delta

		# The old check used the 0.15s coyote timer, which a fast downhill
		# slide easily outlasts. The slide now gets its own, longer grace.
		var lost_ground: bool = _slide_air_time > slide_air_grace
		var blocked: bool = (
			(_slide_elapsed > 0.1 and get_planar_speed() < SLIDE_MIN_SPEED)
			or _slide_climbing_steep_slope()
		)

		# Airborne too long (or locked): there's no floor to clip through, so just end it.
		if movement_locked or lost_ground:
			_end_slide(false)
			return

		# Still inside the air grace: keep the slide jump available (the
		# jump logic keys off the coyote timer), without extending it
		# past the end of the grace.
		if not is_on_floor():
			coyote_timer = maxf(coyote_timer, delta)

		# Anything else that would end the slide only does so if the player
		# fits at full height. Otherwise they stay crouched and keep sliding
		# until the cover ends, instead of the collider growing into it.
		if is_ots_mode or blocked:
			if _can_stand_up():
				if blocked and not is_ots_mode:
					_finish_slide(false)
				else:
					_end_slide(false)
				return

			if blocked:
				_steer_slide_in_crawlspace()

		var downhill: float = _get_slide_downhill_factor()

		# Airborne for a frame or two on a slope: keep the last downhill
		# boost instead of treating it as flat ground (which would bleed
		# speed and run down the slide timer).
		if is_on_floor():
			_slide_last_downhill = downhill
		else:
			downhill = _slide_last_downhill

		if downhill > 0.0:
			_slide_speed = move_toward(
				_slide_speed,
				slide_max_speed,
				slide_slope_acceleration * downhill * delta
			)
		else:
			var remaining: float = maxf(slide_duration - slide_timer, 0.001)
			_slide_speed = lerpf(
				_slide_speed,
				slide_end_speed,
				clampf(delta / remaining, 0.0, 1.0)
			)
			slide_timer += delta

			# Out of time, but only stand up once there's room. Until then the
			# slide carries on at slide_end_speed.
			if slide_timer >= slide_duration and _can_stand_up():
				_finish_slide(true)
		return

	if _crouch_slide_pressed() and _can_start_slide():
		_start_slide()


func _get_slide_speed() -> float:
	return _slide_speed


func _get_slide_downhill_factor() -> float:
	if not is_on_floor():
		return 0.0

	var floor_normal: Vector3 = get_floor_normal()
	var angle: float = acos(clampf(floor_normal.dot(up_direction), -1.0, 1.0))

	if angle < deg_to_rad(slide_slope_min_angle_deg):
		return 0.0

	var downhill: Vector3 = floor_normal.slide(up_direction)
	if downhill.length_squared() < 0.0001:
		return 0.0

	var alignment: float = _slide_direction.dot(downhill.normalized())
	if alignment <= 0.0:
		return 0.0

	var steepness: float = clampf(
		angle / maxf(deg_to_rad(slide_slope_full_angle_deg), 0.001),
		0.0,
		1.0
	)
	return steepness * alignment


var is_crouching := false
var _crouch_jump_grace_timer: float = 0.0


## Crouch unless you're at the speed where the same button would start a slide.
func _can_start_crouch() -> bool:
	return is_on_floor() and not is_sliding and not movement_locked and not _can_start_slide()


func _start_crouch() -> void:
	is_crouching = true
	_crouch_jump_grace_timer = 0.0
	_refresh_collision()


func _end_crouch(allow_jump_grace: bool) -> void:
	is_crouching = false
	_crouch_jump_grace_timer = CROUCH_JUMP_GRACE if allow_jump_grace else 0.0
	_refresh_collision()


func _update_crouch(delta: float) -> void:
	_crouch_jump_grace_timer = maxf(_crouch_jump_grace_timer - delta, 0.0)

	if not InputMap.has_action(CROUCH_ACTION):
		return

	var start_requested: bool
	var stop_requested: bool

	if crouch_is_toggle:
		var pressed: bool = _crouch_slide_pressed()
		start_requested = pressed
		stop_requested = pressed
	else:
		var held: bool = _crouch_slide_held()
		start_requested = held
		stop_requested = not held

	if is_crouching:
		var lost_ground: bool = not is_on_floor() and coyote_timer <= 0.0

		# Airborne (or locked): no floor to clip through, so just stand.
		if movement_locked or lost_ground:
			_end_crouch(false)
			return

		# Only stand up if the full-height collider fits; otherwise stay
		# crouched until the cover ends.
		if stop_requested and _can_stand_up():
			_end_crouch(true)
		return

	if start_requested and _can_start_crouch():
		_start_crouch()


enum WallState { NONE, RUNNING, SLIDING }

var wall_state: WallState = WallState.NONE
var is_wall_running := false
var is_wall_sliding := false
var wall_side: int = 0
var _wall_normal: Vector3 = Vector3.ZERO
var _wall_run_direction: Vector3 = Vector3.ZERO
var _wall_run_speed: float = 0.0
var _wall_run_time_left: float = 0.0
var _wall_run_elapsed: float = 0.0
var _wall_lockout_timer: float = 0.0
var _wall_runs_used: int = 0
var _wall_slides_used: int = 0
var _wall_kick_face_timer: float = 0.0
var _wall_kick_normal: Vector3 = Vector3.ZERO


func _update_wall_movement(delta: float) -> void:

	_wall_lockout_timer = maxf(_wall_lockout_timer - delta, 0.0)
	_wall_kick_face_timer = maxf(_wall_kick_face_timer - delta, 0.0)

	if is_on_floor() or movement_locked or is_ots_mode:
		_end_wall_movement(false)
		if is_on_floor():
			_wall_run_time_left = wall_run_max_time
			_wall_runs_used = 0
			_wall_slides_used = 0
		return

	match wall_state:
		WallState.RUNNING:
			_update_wall_run(delta)
		WallState.SLIDING:
			_update_wall_slide()
		WallState.NONE:
			if _wall_lockout_timer <= 0.0 and not _try_start_wall_run():
				_try_start_wall_slide()


func _get_wall_run_vertical_speed() -> float:
	var total: float = maxf(wall_run_max_time, 0.01)
	var apex_time: float = maxf(total * wall_run_apex_fraction, 0.01)
	var t: float = clampf(_wall_run_elapsed, 0.0, total)
	var rise_speed: float = 2.0 * wall_run_arc_height / apex_time
	var arc_gravity: float = 2.0 * wall_run_arc_height / (apex_time * apex_time)
	return rise_speed - arc_gravity * t


func _try_start_wall_run() -> bool:
	if not is_running or _wall_runs_used >= max_wall_runs:
		return false

	var planar: Vector3 = velocity.slide(up_direction)
	if planar.length() < wall_run_min_speed:
		return false

	var heading: Vector3 = planar.normalized()
	var right: Vector3 = heading.cross(up_direction)
	var center: Vector3 = get_body_center()

	var best: Dictionary = {}
	var best_distance: float = INF
	var candidates: Array[Dictionary] = [_probe_wall(right), _probe_wall(-right)]

	for hit in candidates:
		if hit.is_empty():
			continue

		var normal: Vector3 = hit["normal"]
		if absf(heading.dot(normal)) > WALL_RUN_MAX_APPROACH:
			continue

		var distance: float = center.distance_to(hit["position"])
		if distance < best_distance:
			best = hit
			best_distance = distance

	if best.is_empty():
		return false

	var wall_normal: Vector3 = best["normal"]
	var along: Vector3 = heading.slide(wall_normal)
	if along.length_squared() < 0.0001:
		return false

	_set_wall_state(WallState.RUNNING)
	_wall_run_elapsed = 0.0

	var entry_up_speed: float = velocity.dot(up_direction)
	var arc_start_speed: float = _get_wall_run_vertical_speed()
	if entry_up_speed < arc_start_speed:
		add_impulse(up_direction * (arc_start_speed - entry_up_speed))

	_wall_runs_used += 1
	_wall_run_time_left = wall_run_max_time
	_wall_normal = wall_normal
	_wall_run_direction = along.normalized()
	_wall_run_speed = maxf(wall_run_speed, planar.length())
	_update_wall_side()

	jump_phase = JumpPhase.NONE
	jump_phase_timer = 0.0
	return true


func _try_start_wall_slide() -> void:
	if _wall_slides_used >= max_wall_slides:
		return

	if velocity.dot(up_direction) > 0.5:
		return

	var input_dir: Vector3 = _get_input_direction()
	if input_dir.length_squared() == 0.0:
		return

	var hit: Dictionary = _probe_wall(input_dir)
	if hit.is_empty():
		return

	var normal: Vector3 = hit["normal"]
	if -input_dir.dot(normal) < WALL_SLIDE_MIN_APPROACH:
		return

	_set_wall_state(WallState.SLIDING)
	_wall_slides_used += 1
	_wall_normal = normal
	jump_phase = JumpPhase.NONE
	jump_phase_timer = 0.0


func _update_wall_run(delta: float) -> void:
	_wall_run_elapsed += delta
	_wall_run_time_left -= delta

	var hit: Dictionary = _probe_wall(-_wall_normal)

	var keep_going: bool = (
		is_running
		and _wall_run_time_left > 0.0
		and not hit.is_empty()
		and get_planar_speed() >= wall_run_min_speed * 0.5
	)
	if not keep_going:
		_end_wall_movement(true)
		return

	_wall_normal = hit["normal"]

	var along: Vector3 = _wall_run_direction.slide(_wall_normal)
	if along.length_squared() < 0.0001:
		_end_wall_movement(true)
		return

	_wall_run_direction = along.normalized()
	_update_wall_side()


func _update_wall_slide() -> void:
	var hit: Dictionary = _probe_wall(-_wall_normal)
	var pressing_in: bool = _get_input_direction().dot(-_wall_normal) > WALL_SLIDE_MIN_APPROACH

	if hit.is_empty() or not pressing_in:
		_end_wall_movement(false)
		return

	_wall_normal = hit["normal"]


func _start_wall_jump() -> void:
	var normal: Vector3 = _wall_normal

	var along: Vector3 = velocity.slide(up_direction).slide(normal)
	_start_jump(JumpKind.WALL, along + normal * wall_jump_away_speed)

	_end_wall_movement(true)
	jump_buffer_timer = 0.0
	jumps_used = 1

	_wall_kick_normal = normal
	_wall_kick_face_timer = wall_kick_face_time

	if animation_controller:
		animation_controller.play_wall_kick()


func _end_wall_movement(with_regrab_delay: bool) -> void:
	if wall_state == WallState.NONE:
		return

	_set_wall_state(WallState.NONE)
	wall_side = 0

	if with_regrab_delay:
		_wall_lockout_timer = wall_regrab_delay


func _set_wall_state(state: WallState) -> void:
	if state != WallState.NONE:
		_wall_kick_face_timer = 0.0

	wall_state = state
	is_wall_running = state == WallState.RUNNING
	is_wall_sliding = state == WallState.SLIDING


func _update_wall_side() -> void:
	var right: Vector3 = _wall_run_direction.cross(up_direction)
	wall_side = 1 if right.dot(-_wall_normal) > 0.0 else -1


func _face_wall(delta: float, normal: Vector3, turn_speed: float) -> void:
	var toward_wall: Vector3 = (-normal).slide(up_direction)
	if toward_wall.length_squared() < 0.0001:
		return

	var target_basis := Basis.looking_at(toward_wall.normalized(), up_direction)
	model_yaw_basis = Basis(
		model_yaw_basis
		.get_rotation_quaternion()
		.slerp(
			target_basis.get_rotation_quaternion(),
			clampf(turn_speed * delta, 0.0, 1.0)
		)
	)


func _probe_wall(direction: Vector3) -> Dictionary:
	var from: Vector3 = get_body_center()
	var query := PhysicsRayQueryParameters3D.create(
		from,
		from + direction * wall_check_distance,
		collision_mask,
		[get_rid()]
	)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return {}

	var collider: Object = hit["collider"]
	if collider is CharacterBody3D or collider is RigidBody3D:
		return {}

	var surface_normal: Vector3 = hit["normal"]
	var flat: Vector3 = surface_normal.slide(up_direction)

	if absf(surface_normal.dot(up_direction)) > 0.3 or flat.length_squared() < 0.0001:
		return {}

	hit["normal"] = flat.normalized()
	return hit


enum LedgeState { NONE, HANGING, CLIMBING }

var ledge_state: LedgeState = LedgeState.NONE
var is_ledge_hanging := false
var is_ledge_climbing := false
var _ledge_normal: Vector3 = Vector3.ZERO
var _ledge_hang_position: Vector3 = Vector3.ZERO
var _ledge_stand_position: Vector3 = Vector3.ZERO
var _ledge_climb_start: Vector3 = Vector3.ZERO
var _ledge_timer: float = 0.0
var _ledge_lockout_timer: float = 0.0


func _set_ledge_state(state: LedgeState) -> void:
	ledge_state = state
	is_ledge_hanging = state == LedgeState.HANGING
	is_ledge_climbing = state == LedgeState.CLIMBING


func _get_capsule_radius() -> float:
	if player_collision_shape:
		var capsule := player_collision_shape.shape as CapsuleShape3D
		if capsule:
			return capsule.radius

	return 0.3


func _ledge_ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, [get_rid()])
	var hit: Dictionary = space.intersect_ray(query)

	if hit.is_empty():
		return {}

	var collider: Object = hit["collider"]
	if collider is CharacterBody3D or collider is RigidBody3D:
		return {}

	return hit


func _ledge_position_clear(space: PhysicsDirectSpaceState3D, feet_position: Vector3) -> bool:
	if not player_collision_shape or not player_collision_shape.shape:
		return true

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = player_collision_shape.shape
	query.transform = Transform3D(
		global_basis.orthonormalized(),
		feet_position + up_direction * (NORMAL_COLLISION_Y + LEDGE_CLEARANCE_LIFT)
	)
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]

	return space.intersect_shape(query, 1).is_empty()


func _ledge_stand_supported(
	space: PhysicsDirectSpaceState3D,
	stand_position: Vector3,
	wall_normal: Vector3
) -> bool:
	var reach: float = _get_capsule_radius() * ledge_support_footprint
	var tangent: Vector3 = wall_normal.cross(up_direction).normalized()
	var expected_floor: Vector3 = stand_position - up_direction * LEDGE_STAND_LIFT

	var offsets: Array[Vector3] = [
		Vector3.ZERO,
		tangent * reach,
		-tangent * reach,
		wall_normal * reach,
		-wall_normal * reach
	]

	for offset in offsets:
		var probe: Vector3 = expected_floor + offset
		var hit: Dictionary = _ledge_ray(
			space,
			probe + up_direction * ledge_support_tolerance,
			probe - up_direction * ledge_support_tolerance
		)

		if hit.is_empty():
			return false

		var hit_normal: Vector3 = hit["normal"]
		if hit_normal.dot(up_direction) < LEDGE_MIN_TOP_NORMAL:
			return false

	return true


func _ledge_segment_clear(
	space: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3
) -> bool:
	var step: float = maxf(ledge_path_check_step, 0.05)
	var steps: int = maxi(ceili(from.distance_to(to) / step), 1)

	for i in range(1, steps):
		var feet_position: Vector3 = from.lerp(to, float(i) / float(steps))
		if not _ledge_position_clear(space, feet_position):
			return false

	return true


func _ledge_path_clear(
	space: PhysicsDirectSpaceState3D,
	hang_position: Vector3,
	stand_position: Vector3
) -> bool:
	var rise: float = (stand_position - hang_position).dot(up_direction)
	var mid: Vector3 = hang_position + up_direction * rise

	if not _ledge_position_clear(space, mid):
		return false

	return (
		_ledge_segment_clear(space, hang_position, mid)
		and _ledge_segment_clear(space, mid, stand_position)
	)


func _try_grab_ledge() -> bool:
	if ledge_state != LedgeState.NONE or _ledge_lockout_timer > 0.0:
		return false

	if is_on_floor() or movement_locked or is_ots_mode or is_sliding:
		return false

	if wall_state == WallState.RUNNING:
		return false

	if velocity.dot(up_direction) > ledge_max_rise_speed:
		return false

	var direction: Vector3 = _get_input_direction()
	if direction.length_squared() < 0.0001:
		direction = velocity.slide(up_direction)
		if direction.length() < 1.0:
			return false
		direction = direction.normalized()

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var chest: Vector3 = global_position + up_direction * ledge_wall_check_height

	var wall_hit: Dictionary = _ledge_ray(space, chest, chest + direction * ledge_reach)
	if wall_hit.is_empty():
		return false

	var surface_normal: Vector3 = wall_hit["normal"]
	if absf(surface_normal.dot(up_direction)) > 0.3:
		return false

	var wall_normal: Vector3 = surface_normal.slide(up_direction)
	if wall_normal.length_squared() < 0.0001:
		return false
	wall_normal = wall_normal.normalized()

	if direction.dot(-wall_normal) < 0.5:
		return false

	var wall_position: Vector3 = wall_hit["position"]
	var probe_point: Vector3 = wall_position - wall_normal * ledge_top_probe_depth
	var top_from: Vector3 = probe_point + up_direction * (ledge_max_height - ledge_wall_check_height)
	var top_to: Vector3 = probe_point + up_direction * (ledge_min_height - ledge_wall_check_height)

	var top_hit: Dictionary = _ledge_ray(space, top_from, top_to)
	if top_hit.is_empty():
		return false

	var top_normal: Vector3 = top_hit["normal"]
	if top_normal.dot(up_direction) < LEDGE_MIN_TOP_NORMAL:
		return false

	var top_position: Vector3 = top_hit["position"]
	var top_offset: float = (top_position - wall_position).dot(up_direction)
	var edge_point: Vector3 = wall_position + up_direction * top_offset
	var radius: float = _get_capsule_radius()

	var hang_position: Vector3 = (
		edge_point
		+ wall_normal * (radius + ledge_wall_gap)
		- up_direction * ledge_hang_drop
	)
	var stand_position: Vector3 = (
		edge_point
		- wall_normal * (radius + ledge_stand_inset)
		+ up_direction * LEDGE_STAND_LIFT
	)

	if not _ledge_stand_supported(space, stand_position, wall_normal):
		return false

	if not _ledge_position_clear(space, hang_position):
		return false

	if not _ledge_position_clear(space, stand_position):
		return false

	if not _ledge_path_clear(space, hang_position, stand_position):
		return false

	hard_stop()

	_ledge_normal = wall_normal
	_ledge_hang_position = hang_position
	_ledge_stand_position = stand_position
	_ledge_timer = 0.0
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	_set_ledge_state(LedgeState.HANGING)
	return true


func _update_ledge(delta: float) -> void:
	velocity = Vector3.ZERO
	pending_acceleration = Vector3.ZERO
	_ledge_timer += delta

	if movement_locked:
		_release_ledge()
		return

	var face_basis := Basis.looking_at(-_ledge_normal, up_direction)
	model_yaw_basis = Basis(
		model_yaw_basis
		.get_rotation_quaternion()
		.slerp(face_basis.get_rotation_quaternion(), clampf(rotation_speed * 2.0 * delta, 0.0, 1.0))
	)

	if ledge_state == LedgeState.HANGING:
		var weight: float = 1.0 - exp(-delta / maxf(ledge_snap_time, 0.001))
		global_position = global_position.lerp(_ledge_hang_position, weight)

		if _ledge_timer >= ledge_min_hang_time:
			if jump_buffer_timer > 0.0:
				jump_buffer_timer = 0.0
				_ledge_timer = 0.0
				_ledge_climb_start = global_position
				_set_ledge_state(LedgeState.CLIMBING)
			elif _get_input_direction().dot(_ledge_normal) > 0.5:
				_release_ledge()
	elif ledge_state == LedgeState.CLIMBING:
		_update_ledge_climb()

	_update_turn_rate(delta)
	_apply_lean(delta)


func _update_ledge_climb() -> void:
	var t: float = clampf(_ledge_timer / maxf(ledge_climb_time, 0.01), 0.0, 1.0)
	var rise: float = (_ledge_stand_position - _ledge_climb_start).dot(up_direction)
	var mid: Vector3 = _ledge_climb_start + up_direction * rise

	if t < ledge_climb_vertical_fraction:
		var vertical_t: float = t / ledge_climb_vertical_fraction
		global_position = _ledge_climb_start.lerp(mid, smoothstep(0.0, 1.0, vertical_t))
	else:
		var horizontal_t: float = (t - ledge_climb_vertical_fraction) / maxf(1.0 - ledge_climb_vertical_fraction, 0.001)
		global_position = mid.lerp(_ledge_stand_position, smoothstep(0.0, 1.0, horizontal_t))

	if t >= 1.0:
		_finish_ledge_climb()


func _finish_ledge_climb() -> void:
	global_position = _ledge_stand_position
	_set_ledge_state(LedgeState.NONE)
	_ledge_lockout_timer = ledge_regrab_delay
	coyote_timer = coyote_time
	jumps_used = 0
	velocity = -up_direction * 2.0
	move_and_slide()


func _release_ledge() -> void:
	_set_ledge_state(LedgeState.NONE)
	_ledge_lockout_timer = ledge_regrab_delay
	coyote_timer = 0.0
	jumps_used = 1
	velocity = _ledge_normal * ledge_drop_push


func _update_model_orientation(delta: float) -> void:

	var up := up_direction

	var current_forward: Vector3 = -model_yaw_basis.z
	var realigned_forward: Vector3 = current_forward.slide(up)
	if realigned_forward.length_squared() < 0.0001:
		realigned_forward = model_yaw_basis.x.slide(up)
	if realigned_forward.length_squared() < 0.0001:
		return
	realigned_forward = realigned_forward.normalized()

	var realigned_basis := Basis.looking_at(realigned_forward, up)
	model_yaw_basis = Basis(
		model_yaw_basis.get_rotation_quaternion().slerp(
			realigned_basis.get_rotation_quaternion(),
			rotation_speed * delta
		)
	)


func _get_target_speed() -> float:
	if is_sliding:
		return _get_slide_speed()

	if is_wall_running:
		return _wall_run_speed

	if is_crouching:
		return crouch_speed

	return lerpf(walk_speed, run_speed, run_blend)


func _get_target_motion() -> Dictionary:
	var up := up_direction

	if is_sliding:
		return {
			"target_velocity": _slide_direction * _get_target_speed(),
			"target_forward": _slide_direction
		}

	if is_wall_running:
		return {
			"target_velocity": _wall_run_direction * _get_target_speed() - _wall_normal * WALL_STICK_SPEED,
			"target_forward": _wall_run_direction
		}

	if move_input.length_squared() == 0.0:
		return {
			"target_velocity": Vector3.ZERO,
			"target_forward": (-character_model.global_basis.z).slide(up).normalized()
		}

	var dir := _get_input_direction()
	var spd := _get_target_speed()

	return {
		"target_velocity": dir * spd,
		"target_forward": dir
	}


func _handle_movement(delta: float) -> void:

	var is_moving_input: bool = (
		move_input.length_squared() > 0.0 or is_sliding or is_wall_running
	)

	if is_moving_input:
		var run_target: float = 1.0 if is_running else 0.0
		var run_blend_speed: float = 1.0 - exp(-delta / max(run_ramp_time, 0.001))
		run_blend = move_toward(run_blend, run_target, run_blend_speed)
	else:
		run_blend = 0.0

	var target := _get_target_motion()
	var target_velocity: Vector3 = target["target_velocity"]

	var air_factor: float = _active_air_control if !is_on_floor() else 1.0

	var current_planar_velocity: Vector3 = velocity.slide(up_direction)
	var target_planar_velocity: Vector3 = target_velocity.slide(up_direction)

	var max_accel: float
	if is_sliding:
		max_accel = slide_acceleration
	elif is_wall_running:
		max_accel = WALL_RUN_ACCELERATION
	else:
		max_accel = (move_acceleration if is_moving_input else move_deceleration) * air_factor

	add_acceleration(
		acceleration_toward(current_planar_velocity, target_planar_velocity, max_accel, delta)
	)

	_update_model_orientation(delta)

	if is_moving_input:
		move_direction = target["target_forward"]
		current_speed = _get_target_speed()

		if not is_wall_sliding and _wall_kick_face_timer <= 0.0:
			var up := up_direction
			var target_forward := move_direction.slide(up).normalized()

			if target_forward.length_squared() > 0.001:
				var target_basis := Basis.looking_at(target_forward, up)
				model_yaw_basis = Basis(
					model_yaw_basis
					.get_rotation_quaternion()
					.slerp(target_basis.get_rotation_quaternion(), rotation_speed * delta)
				)

	if is_wall_sliding:
		_face_wall(delta, _wall_normal, wall_slide_turn_speed)
	elif _wall_kick_face_timer > 0.0:
		_face_wall(delta, _wall_kick_normal, wall_kick_turn_speed)

	_update_turn_rate(delta)
	_apply_lean(delta)


func _update_turn_rate(delta: float) -> void:
	var up := up_direction
	var forward := (-model_yaw_basis.z).slide(up).normalized()

	if prev_model_forward.length_squared() > 0.0001 and forward.length_squared() > 0.0001:
		var cross := prev_model_forward.cross(forward)
		var signed_angle := atan2(cross.dot(up), prev_model_forward.dot(forward))
		var instant_rate: float = signed_angle / max(delta, 0.0001)
		turn_rate = lerp(turn_rate, instant_rate, 1.0 - exp(-10.0 * delta))

	prev_model_forward = forward


func _apply_lean(delta: float) -> void:
	var target_lean := 0.0

	var top_speed: float = maxf(maxf(lean_top_speed, run_speed), 0.001)
	var speed_fraction: float = clampf(get_planar_speed() / top_speed, 0.0, 1.0)
	var shaped_fraction: float = pow(speed_fraction, max(lean_speed_curve_power, 0.001))

	var max_angle: float = deg_to_rad(lean_max_angle_deg) * lerpf(1.0, lean_high_speed_multiplier, shaped_fraction)

	if is_on_floor():
		var normalized_turn := clampf(turn_rate / lean_turn_rate_reference, -1.0, 1.0)
		target_lean = normalized_turn * max_angle * shaped_fraction

	if is_wall_running and wall_side != 0:
		target_lean += deg_to_rad(wall_run_lean_angle_deg) * float(wall_side)

	var max_step := deg_to_rad(lean_max_angle_deg) * lean_smoothing_speed * delta
	current_lean = move_toward(current_lean, target_lean, max_step)

	var target_squash_stretch := 0.0
	var planar_speed := get_planar_speed()
	var speed_fraction1 := clampf(
		(planar_speed - squash_stretch_speed_start) / maxf(lean_top_speed - squash_stretch_speed_start, 0.001),
		0.0,
		1.0
	)

	target_squash_stretch += speed_fraction1 * squash_stretch_max_stretch * 0.35

	if not is_on_floor():
		var vertical_speed := absf(velocity.dot(up_direction))
		var air_fraction := clampf(vertical_speed / maxf(squash_stretch_vertical_speed, 0.001), 0.0, 1.0)
		target_squash_stretch = maxf(target_squash_stretch, air_fraction * squash_stretch_max_stretch)

	if is_sliding:
		target_squash_stretch = minf(target_squash_stretch, -squash_stretch_slide_squash)

	var spring_accel: float = (
		(target_squash_stretch - current_squash_stretch) * squash_stretch_stiffness
		- current_squash_stretch_velocity * squash_stretch_damping
	)
	current_squash_stretch_velocity += spring_accel * delta
	current_squash_stretch = clampf(
		current_squash_stretch + current_squash_stretch_velocity * delta,
		-0.5,
		0.5
	)

	var vertical_scale := 1.0 + current_squash_stretch
	var horizontal_scale := 1.0 / sqrt(maxf(vertical_scale, 0.001))
	var final_basis := model_yaw_basis.rotated(model_yaw_basis.z, current_lean)
	final_basis = final_basis.scaled(Vector3(
		model_base_scale.x * horizontal_scale,
		model_base_scale.y * vertical_scale,
		model_base_scale.z * horizontal_scale
	))
	character_model.global_basis = final_basis


func is_moving() -> bool:
	return move_input.length_squared() > 0.001


func get_planar_speed() -> float:
	return velocity.slide(up_direction).length()


func force_idle() -> void:
	hard_stop()
	move_input = Vector2.ZERO
	run_timer = 0.0
	is_running = false
	run_blend = 0.0
	current_speed = 0.0
	current_lean = 0.0
	current_squash_stretch = 0.0
	current_squash_stretch_velocity = 0.0
	_last_air_fall_speed = 0.0
	turn_rate = 0.0
	landing_brake_timer = 0.0

	if Particle_Controller:
		Particle_Controller.clear()

	if animation_controller:
		animation_controller.force_idle()


func stop_horizontal_velocity() -> void:
	velocity -= velocity.slide(up_direction)


func launch(direction: Vector3, force: float) -> void:
	add_impulse(direction.normalized() * force)


func set_running(enabled: bool) -> void:
	is_running = enabled
	if !enabled:
		run_timer = 0.0


func set_captured(locked: bool) -> void:
	movement_locked = locked
	if locked:
		move_input = Vector2.ZERO
		is_running = false
		run_timer = 0.0
		jump_buffer_timer = 0.0

		hard_stop()


func remove_for_escape() -> void:
	set_physics_process(false)
	set_process_unhandled_input(false)
	spring_arm.set_process_unhandled_input(false)
	hard_stop()
	visible = false
	if character_model:
		character_model.visible = false
	collision_layer = 0
	collision_mask = 0
