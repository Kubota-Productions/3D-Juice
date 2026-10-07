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

const SLIDE_COLLISION_Y := 0.33
const SLIDE_COLLISION_HEIGHT := 0.672

var slam: PlayerSlam
var has_slam := false

var is_slamming: bool:
	get:
		return slam != null and slam.is_active
enum JumpKind { NORMAL, SLIDE, WALL, CROUCH, SLAM }

var _stand_check_shape: CapsuleShape3D

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


func get_predicted_velocity() -> Vector3:
	return velocity + pending_acceleration * _current_delta


func _integrate_velocity(delta: float) -> void:
	velocity += pending_acceleration * delta
	pending_acceleration = Vector3.ZERO


func hard_stop() -> void:
	velocity = Vector3.ZERO
	pending_acceleration = Vector3.ZERO
	jump_phase = JumpPhase.NONE
	jump_phase_timer = 0.0
	_set_jump_profile()
	slide.cancel()
	dive.cancel()
	slam.cancel()
	_end_crouch(false)
	wall.end_wall_movement(false)
	wall.lockout_timer = 0.0
	wall.kick_facing = false
	ledge.cancel()
	hover.cancel()


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


@export_group("Movement Modules")
@export var movement_modules: Array[PlayerMovementModule] = []

var slide: PlayerSlide
var dive: PlayerDive
var wall: PlayerWallMovement
var ledge: PlayerLedgeGrab
var hover: PlayerHover
var has_slide := false
var has_dive := false
var has_wall := false
var has_ledge := false
var has_hover := false

var is_sliding: bool:
	get:
		return slide != null and slide.is_active

var is_diving: bool:
	get:
		return dive != null and dive.is_active

var is_hovering: bool:
	get:
		return hover != null and hover.is_active

var is_wall_running: bool:
	get:
		return wall != null and wall.is_wall_running

var is_wall_sliding: bool:
	get:
		return wall != null and wall.is_wall_sliding

var is_wall_climbing: bool:
	get:
		return wall != null and wall.is_wall_climbing

var wall_side: int:
	get:
		return wall.side if wall != null else 0

var wall_run_speed: float:
	get:
		return wall.run_speed if wall != null else 0.0

var max_wall_moves: int:
	get:
		return wall.max_moves if wall != null else 0

var _wall_moves_used: int:
	get:
		return wall.moves_used if wall != null else 0

var is_ledge_hanging: bool:
	get:
		return ledge != null and ledge.is_hanging

var is_ledge_climbing: bool:
	get:
		return ledge != null and ledge.is_climbing


func _setup_modules() -> void:
	var live_modules: Array[PlayerMovementModule] = []

	for module in movement_modules:
		if module == null:
			continue

		var instance := module.duplicate() as PlayerMovementModule

		if instance is PlayerSlide and slide == null:
			slide = instance as PlayerSlide
		elif instance is PlayerDive and dive == null:
			dive = instance as PlayerDive
		elif instance is PlayerWallMovement and wall == null:
			wall = instance as PlayerWallMovement
		elif instance is PlayerLedgeGrab and ledge == null:
			ledge = instance as PlayerLedgeGrab
		elif instance is PlayerHover and hover == null:
			hover = instance as PlayerHover
		elif instance is PlayerSlam and slam == null:
			slam = instance as PlayerSlam
		else:
			push_warning("Player: ignoring '%s' in movement_modules (unknown type, or a second one of the same type)." % module.resource_path)
			continue

		live_modules.append(instance)

	has_slide = slide != null
	has_dive = dive != null
	has_wall = wall != null
	has_ledge = ledge != null
	has_hover = hover != null
	has_slam = slam != null
	

	if slide == null:
		slide = PlayerSlide.new()
		live_modules.append(slide)

	if dive == null:
		dive = PlayerDive.new()
		live_modules.append(dive)
	if hover == null:
		hover = PlayerHover.new()
		live_modules.append(hover)

	if wall == null:
		wall = PlayerWallMovement.new()
		live_modules.append(wall)

	if ledge == null:
		ledge = PlayerLedgeGrab.new()
		live_modules.append(ledge)
	if slam == null:
		slam = PlayerSlam.new()
		live_modules.append(slam)

	for module in live_modules:
		module.setup(self)
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

@export_group("Crouch")
@export var crouch_speed: float = 1.75
@export var crouch_is_toggle: bool = false
@export var crouch_jump_height: float = 4.0
@export var crouch_jump_rise_time: float = 0.57
@export var crouch_jump_fall_time: float = 0.5
@export var crouch_jump_air_control: float = 0.45

const STAND_CHECK_LIFT := 0.04
const CROUCH_JUMP_GRACE := 0.1
const CROUCH_ACTION := &"Crouch"


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

	_setup_modules()

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
		elif is_on_floor() and not slam.is_active and (not slide.is_active or can_stand_up()):
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

	ledge.tick(delta)
	dive.tick(delta)

	_read_input(delta)
	_update_ground_state(delta)

	if not ledge.is_active():
		if has_dive:
			dive.update(delta)
		if has_slam:
			slam.update(delta)
		if has_slide:
			slide.update(delta)
		_update_crouch(delta)
		if has_wall:
			wall.update(delta)
		if has_hover:
			hover.update(delta)
		if has_ledge:
			ledge.try_grab()

	if ledge.is_active():
		ledge.update(delta)
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
		if has_slide:
			slide.try_steep_slope_slide()

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


func get_input_direction() -> Vector3:
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

		if not was_grounded_last_frame and not slide.is_active and not dive.is_active and planar_velocity.length() > max_landing_speed:
			landing_brake_timer = landing_brake_time

		if slide.is_active or dive.is_active:
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
		wall.kick_facing = false
		dive.on_grounded()
		hover.on_grounded()
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
			height = slide.jump_height
			rise_t = slide.jump_rise_time
			fall_t = slide.jump_fall_time
			air_control = slide.jump_air_control
		JumpKind.WALL:
			air_control = wall.jump_air_control
		JumpKind.CROUCH:
			height = crouch_jump_height
			rise_t = crouch_jump_rise_time
			fall_t = crouch_jump_fall_time
			air_control = crouch_jump_air_control
		JumpKind.SLAM:
			var profile: Dictionary = slam.get_launch_profile()
			height = profile["height"]
			rise_t = profile["rise_time"]
			fall_t = profile["fall_time"]
			air_control = slam.launch_air_control
			
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

	if wall.apply_gravity(delta):
		return

	if dive.apply_gravity(delta):
		return
	
	if hover.apply_gravity(delta):
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

func _limit_unearned_rise(up_speed_before: float) -> void:
	if is_on_floor():
		return

	var up_speed_after: float = velocity.dot(up_direction)
	var allowed: float = maxf(up_speed_before, 0.0)

	if up_speed_after > allowed + MAX_UNEARNED_RISE_TOLERANCE:
		velocity -= up_direction * (up_speed_after - allowed)


func _handle_jump(_delta: float) -> void:
	if slam.is_active:
		return

	if jump_buffer_timer <= 0.0:
		return

	if (slide.is_active or is_crouching) and not can_stand_up():
		return

	if wall.try_handle_jump():
		return

	if coyote_timer > 0.0:
		if slide.is_active or slide.jump_grace_timer > 0.0:
			start_jump(JumpKind.SLIDE, slide.get_jump_launch())
			dive.on_slide_jump()
			slide.end(false)
			_end_crouch(false)
		elif is_crouching or _crouch_jump_grace_timer > 0.0:
			start_jump(JumpKind.CROUCH)
			_end_crouch(false)
		else:
			start_jump()

		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jumps_used = 1

	elif jumps_used < max_jumps:
		start_jump()
		jump_buffer_timer = 0.0

		if animation_controller:
			match jumps_used:
				1:
					animation_controller.play_double_jump()
				2:
					animation_controller.play_triple_jump()

		jumps_used += 1


func start_jump(kind: JumpKind = JumpKind.NORMAL, planar_launch: Vector3 = Vector3.ZERO) -> void:
	dive.is_active = false

	_set_jump_profile(kind)

	if kind != JumpKind.WALL:
		wall.kick_facing = false

	var predicted_velocity: Vector3 = get_predicted_velocity()
	var impulse: Vector3 = -predicted_velocity.project(up_direction) + up_direction * _active_jump_velocity

	if kind == JumpKind.SLIDE or kind == JumpKind.WALL:
		impulse += planar_launch - velocity.slide(up_direction)

	add_impulse(impulse)
	jump_phase = JumpPhase.RISING
	jump_phase_timer = _active_rise_time

func refresh_collision() -> void:
	_set_short_collision(slide.is_active or is_crouching)
	slide.apply_floor_settings()


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

func can_stand_up() -> bool:
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


func get_capsule_radius() -> float:
	if player_collision_shape:
		var capsule := player_collision_shape.shape as CapsuleShape3D
		if capsule:
			return capsule.radius

	return 0.3

func crouch_slide_pressed() -> bool:
	if Input.is_action_just_pressed("Slide"):
		return true

	return InputMap.has_action(CROUCH_ACTION) and Input.is_action_just_pressed(CROUCH_ACTION)


func crouch_slide_held() -> bool:
	if Input.is_action_pressed("Slide"):
		return true

	return InputMap.has_action(CROUCH_ACTION) and Input.is_action_pressed(CROUCH_ACTION)


var is_crouching := false
var _crouch_jump_grace_timer: float = 0.0

func _can_start_crouch() -> bool:
	return is_on_floor() and not slide.is_active and not movement_locked and not slide.can_start()


func start_crouch() -> void:
	is_crouching = true
	_crouch_jump_grace_timer = 0.0
	refresh_collision()


func _end_crouch(allow_jump_grace: bool) -> void:
	is_crouching = false
	_crouch_jump_grace_timer = CROUCH_JUMP_GRACE if allow_jump_grace else 0.0
	refresh_collision()


func _update_crouch(delta: float) -> void:
	_crouch_jump_grace_timer = maxf(_crouch_jump_grace_timer - delta, 0.0)

	if not InputMap.has_action(CROUCH_ACTION):
		return

	var start_requested: bool
	var stop_requested: bool

	if crouch_is_toggle:
		var pressed: bool = crouch_slide_pressed()
		start_requested = pressed
		stop_requested = pressed
	else:
		var held: bool = crouch_slide_held()
		start_requested = held
		stop_requested = not held

	if is_crouching:
		var lost_ground: bool = not is_on_floor() and coyote_timer <= 0.0
		
		if movement_locked or lost_ground:
			_end_crouch(false)
			return

		if stop_requested and can_stand_up():
			_end_crouch(true)
		return

	if start_requested and _can_start_crouch():
		start_crouch()


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
	if slide.is_active:
		return slide.get_speed()

	if dive.is_active:
		return dive.current_speed

	if wall.is_wall_running:
		return wall.current_run_speed

	if hover.is_active:
		return hover.current_speed
	if is_crouching:
		return crouch_speed

	return lerpf(walk_speed, run_speed, run_blend)


func _get_target_motion() -> Dictionary:
	var up := up_direction

	if slide.is_active:
		return slide.get_target_motion()

	if slam.is_active:
		return slam.get_target_motion()
	
	if dive.is_active:
		return dive.get_target_motion()

	var wall_motion: Dictionary = wall.get_target_motion()
	if not wall_motion.is_empty():
		return wall_motion
	if hover.is_active:
		return hover.get_target_motion()

	if move_input.length_squared() == 0.0:
		return {
			"target_velocity": Vector3.ZERO,
			"target_forward": (-character_model.global_basis.z).slide(up).normalized()
		}

	var dir := get_input_direction()
	var spd := _get_target_speed()

	return {
		"target_velocity": dir * spd,
		"target_forward": dir
	}


func _handle_movement(delta: float) -> void:

	var is_moving_input: bool = (
		move_input.length_squared() > 0.0 or slide.is_active or wall.is_wall_running or dive.is_active or hover.is_active
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
	if slide.is_active:
		max_accel = slide.acceleration
	elif slam.is_active:
		max_accel = slam.horizontal_deceleration
	elif wall.is_wall_running or wall.is_wall_climbing:
		max_accel = PlayerWallMovement.RUN_ACCELERATION
	elif dive.is_active:
		max_accel = dive.acceleration
	elif hover.is_active:
		max_accel = hover.get_acceleration()
	else:
		max_accel = (move_acceleration if is_moving_input else move_deceleration) * air_factor

	add_acceleration(
		acceleration_toward(current_planar_velocity, target_planar_velocity, max_accel, delta)
	)

	_update_model_orientation(delta)

	if is_moving_input:
		move_direction = target["target_forward"]
		current_speed = _get_target_speed()

		if not wall.is_wall_sliding and not wall.is_wall_climbing and not wall.kick_facing:
			var up := up_direction
			var target_forward := move_direction.slide(up).normalized()

			if target_forward.length_squared() > 0.001:
				var target_basis := Basis.looking_at(target_forward, up)
				var turn_speed: float = rotation_speed
				if hover.is_active:
					turn_speed *= hover.get_rotation_multiplier()
				model_yaw_basis = Basis(
					model_yaw_basis
					.get_rotation_quaternion()
					.slerp(target_basis.get_rotation_quaternion(), turn_speed * delta)
				)

	wall.update_facing(delta)

	update_turn_rate(delta)
	apply_lean(delta)


func update_turn_rate(delta: float) -> void:
	var up := up_direction
	var forward := (-model_yaw_basis.z).slide(up).normalized()

	if prev_model_forward.length_squared() > 0.0001 and forward.length_squared() > 0.0001:
		var cross := prev_model_forward.cross(forward)
		var signed_angle := atan2(cross.dot(up), prev_model_forward.dot(forward))
		var instant_rate: float = signed_angle / max(delta, 0.0001)
		turn_rate = lerp(turn_rate, instant_rate, 1.0 - exp(-10.0 * delta))

	prev_model_forward = forward


func apply_lean(delta: float) -> void:
	var target_lean := 0.0

	var top_speed: float = maxf(maxf(lean_top_speed, run_speed), 0.001)
	var speed_fraction: float = clampf(get_planar_speed() / top_speed, 0.0, 1.0)
	var shaped_fraction: float = pow(speed_fraction, max(lean_speed_curve_power, 0.001))

	var max_angle: float = deg_to_rad(lean_max_angle_deg) * lerpf(1.0, lean_high_speed_multiplier, shaped_fraction)

	if is_on_floor():
		var normalized_turn := clampf(turn_rate / lean_turn_rate_reference, -1.0, 1.0)
		target_lean = normalized_turn * max_angle * shaped_fraction

	if wall.is_wall_running and wall.side != 0:
		target_lean += deg_to_rad(wall_run_lean_angle_deg) * float(wall.side)

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

	if slide.is_active:
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
