class_name Player
extends CharacterBody3D

# ============================================================
# REFERENCES
# ============================================================
@onready var character_model: Node3D = $CharacterModel
@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera_3d: Camera3D = $SpringArm3D/Cameraoffset/Camera3D
@onready var aim_pivot: Node3D = $"../AimPivot"
@onready var telekinesis_controller: TelekinesisController = $TelekinesisController
@onready var combat_controller: CombatController = $CombatController
@onready var interaction_highlight_controller: InteractionHighlightController = $InteractionHighlightController

# Player collision is compressed while sliding.
@onready var player_collision_shape: CollisionShape3D = get_node_or_null("CollisionShape3D")
const NORMAL_COLLISION_Y := 0.672
const NORMAL_COLLISION_HEIGHT := 1.344
const SLIDE_COLLISION_Y := 0.33
const SLIDE_COLLISION_HEIGHT := 0.672

@export var animation_controller: Node  # assign the AnimationController node in the editor
var pending_acceleration: Vector3 = Vector3.ZERO
var _current_delta: float = 0.016
var movement_locked: bool = false


## Returns the acceleration that moves `current` toward `target` as
## fast as `max_accel` allows, without ever overshooting it.
##
## This is the workhorse that replaces every lerp()/move_toward() that
## used to be applied straight to velocity. A naive
## "(target - current).normalized() * max_accel" would never settle --
## it applies full force right up to the target, blows past it, then
## applies full force back the other way, oscillating forever. So:
## first work out the acceleration that would land exactly on target
## this frame, and only clamp it when that exceeds max_accel. Far from
## the target that's a constant-force approach; close in it eases down
## and settles.
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


## Contribute an acceleration (units/sec^2) for this frame.
func add_acceleration(accel: Vector3) -> void:
	pending_acceleration += accel


## Contribute an instantaneous velocity change (units/sec) -- a jump,
## a launch pad, a knockback. Routed through the same accumulator (as
## accel = impulse/delta, which integrates back to exactly the
## impulse) so velocity still has a single mutation point. Impulses
## are deliberately still supported: a jump genuinely IS an impulse,
## and modelling one as a sustained force would make jump height
## depend on frame timing and be far harder to tune.
func add_impulse(impulse: Vector3) -> void:
	pending_acceleration += impulse / max(_current_delta, 0.0001)


func _integrate_velocity(delta: float) -> void:
	velocity += pending_acceleration * delta
	pending_acceleration = Vector3.ZERO


## Hard velocity reset. An intentional exception to the acceleration
## model, for events where the body is being repositioned/teleported
## rather than moving continuously (respawn, cutscene, capture) --
## carrying momentum across a teleport is wrong, not smooth. Also
## cancels any jump in progress so a half-finished rise/hang doesn't
## resume after the reset, and any slide or wall movement so it can't
## carry on afterwards.
func hard_stop() -> void:
	velocity = Vector3.ZERO
	pending_acceleration = Vector3.ZERO
	jump_phase = JumpPhase.NONE
	jump_phase_timer = 0.0
	_set_jump_profile()
	_cancel_slide()
	_end_wall_movement(false)
	_wall_lockout_timer = 0.0

# ============================================================
# BODY CENTRE  (camera / aim anchor)
# ============================================================
# A CharacterBody3D's origin is usually at the FEET, but the camera
# and aim pivot should follow the body's CENTRE. rotation_pivot marks
# that point. (The name is kept from when the body could flip around
# it, so the scene's existing assignment keeps working.)
# ============================================================
## Drag in a Node3D (e.g. a Marker3D) positioned at the visual/collision
## centre of the body. Its offset from the Player origin is measured
## once at _ready() and cached.
@export var rotation_pivot: Node3D

## Height of the camera/aim anchor above the body CENTRE (not the feet).
@export var frame_anchor_height_offset: float = 0.3

var body_center_offset: Vector3 = Vector3.ZERO


func _resolve_body_center_offset() -> void:
	if not rotation_pivot:
		push_warning("Player: 'rotation_pivot' not assigned -- camera/aim anchor will use the body origin (feet).")
		body_center_offset = Vector3.ZERO
		return

	# Local-space offset from the Player's origin to the pivot node.
	body_center_offset = global_basis.inverse() * (rotation_pivot.global_position - global_position)


## Current world-space position of the collision shape's centre.
func get_body_center() -> Vector3:
	return global_position + global_basis * body_center_offset


## The point the camera and aim pivot should track.
func get_camera_anchor() -> Vector3:
	return get_body_center() + up_direction * frame_anchor_height_offset


## Places the body so its CENTRE lands at `world_center`, for
## teleport-style repositions (respawn) that would otherwise bury the
## capsule by putting its origin at the target point.
func set_body_center(world_center: Vector3) -> void:
	global_position = world_center - global_basis * body_center_offset

# ============================================================
# MOVEMENT
# ============================================================
@export_group("Movement")
@export var walk_speed: float = 2.5
@export var run_speed: float = 5.0
## NOTE: a REAL acceleration in units/sec^2, not the old lerp weight.
## The old value (10.0) was a blend factor and does not carry over --
## these will need retuning. As a starting point, reaching run_speed
## (5.0) in ~0.15s needs roughly 5/0.15 = 33 units/sec^2.
@export var move_acceleration: float = 35.0
## Separate, usually higher than move_acceleration so the character
## stops more crisply than it starts. Applied when there's no input.
@export var move_deceleration: float = 45.0
@export var rotation_speed: float = 8.0
## Braking acceleration applied after a hard landing. Replaces the old
## hard velocity clamp on the landing frame -- same intent, but bleeds
## the speed off over a few frames instead of snapping it.
@export var landing_brake_acceleration: float = 60.0
## Only speed carried in from a FALL gets braked, and only for this
## long after touchdown. Deliberately not a continuous grounded speed
## cap: ordinary locomotion is already limited by its own target
## speed, so a permanent cap here would just fight anything that
## exceeds max_landing_speed on purpose (slide jumps) and silently pin it.
@export var landing_brake_time: float = 0.3
@export var max_landing_speed: float = 8.0

var landing_brake_timer: float = 0.0
@export var run_ramp_time: float = 0.35

# ============================================================
# SLIDE
# ============================================================
@export_group("Slide")
## Right click (the "Slide" input action) while running to slide. The
## character keeps its heading, bursts up to slide_speed, then bleeds
## off to slide_end_speed over slide_duration. Jumping out of the slide
## (or within a moment after it ends) is a long, low jump.
@export var slide_speed: float = 7.5
## Speed the slide has bled down to by the time it ends.
@export var slide_end_speed: float = 3.0
## Seconds a slide lasts.
@export var slide_duration: float = 0.7
## How tightly the character tracks the slide's speed curve. High so
## the burst at the start is near-instant.
@export var slide_acceleration: float = 40.0
## Horizontal speed a slide jump launches at, along the slide's heading.
@export var slide_jump_speed: float = 10.0
## Slide jumps are lower and longer than normal jumps -- same
## height + time meaning as the Jumping group (hang time is shared).
@export var slide_jump_height: float = 1.2
@export var slide_jump_rise_time: float = 0.45
@export var slide_jump_fall_time: float = 0.44
## Air control during a slide jump. Kept low so the jump commits you
## to its line and the launch speed isn't steered away. 0 = none, 1 =
## as much as on the ground.
@export var slide_jump_air_control: float = 0.1

# ============================================================
# WALL MOVEMENT
# ============================================================
@export_group("Wall Movement")
## How far out from the body centre (metres) to look for a wall. Has to
## be longer than the capsule's radius or walls beside you won't be
## seen; a little longer than that gives some forgiveness.
@export var wall_check_distance: float = 0.8
## Speed along the wall during a wall run. If you arrive faster, you
## keep the faster speed.
@export var wall_run_speed: float = 6.0
## Horizontal speed needed to start a wall run.
@export var wall_run_min_speed: float = 4.0
## Total seconds of wall running per trip through the air. Refills on
## touching the ground.
@export var wall_run_max_time: float = 1.6
## How fast (units/sec) you sink while wall running. Small, so you
## stay roughly level with where you grabbed on.
@export var wall_run_sink_speed: float = 0.5
## Fall speed cap while sliding down a wall.
@export var wall_slide_speed: float = 2.0
## Speed pushed away from the wall by a wall jump. Speed along the wall
## is kept.
@export var wall_jump_away_speed: float = 6.5
## Air control for a wall jump. Low, so holding toward the wall doesn't
## pull you straight back into it.
@export var wall_jump_air_control: float = 0.2
## After a wall jump or a wall run ending, seconds before you can grab
## a wall again -- long enough to get clear of the one you just left.
@export var wall_regrab_delay: float = 0.25

const SLIDE_JUMP_GRACE := 0.15  # seconds after a slide ends that jumping still counts as a slide jump
const SLIDE_MIN_SPEED := 1.0  # below this a slide has hit something and ends
# sin(40 degrees). Approaching a wall more steeply than this is a wall
# slide rather than a wall run.
const WALL_RUN_MAX_APPROACH := 0.64
# How directly the input must point into a wall to slide down it.
const WALL_SLIDE_MIN_APPROACH := 0.3
const WALL_STICK_SPEED := 1.0  # small push into the wall while running so contact is kept
const WALL_RUN_ACCELERATION := 40.0
const WALL_VERTICAL_ACCELERATION := 30.0

# ============================================================
# RUN DUST
# ============================================================
@export_group("Run Dust")
@export var Particle_Controller: ParticleController

var move_input: Vector2 = Vector2.ZERO
var move_direction: Vector3 = Vector3.ZERO
var current_speed: float = 0.0
var is_running := false
## Power sprint is cut for now. Kept (always false) so other scripts
## that still read it don't break.
var is_power_sprinting := false
var run_timer := 0.0
var run_blend: float = 0.0

const RUN_THRESHOLD := 0.40

@export_group("Lean")
@export var lean_max_angle_deg: float = 20.0
@export var lean_smoothing_speed: float = 6.0
@export var lean_turn_rate_reference: float = 3.0  # turn_rate (rad/s) that maps to full lean
## Lean angle is multiplied by this at top speed, so the character
## banks harder the faster they're going rather than just reaching the
## same max angle sooner. 1.0 disables the effect.
@export var lean_high_speed_multiplier: float = 1.8
## Shapes how lean ramps in across the speed range. Above 1.0 keeps
## lean subtle at walking pace and saves most of it for genuinely
## fast movement; 1.0 is a straight linear ramp.
@export var lean_speed_curve_power: float = 1.5
## Speed that counts as "top speed" for lean. (This used to be the
## power sprint speed; kept at that value so lean while running feels
## the same as before.)
@export var lean_top_speed: float = 9.0
## Small extra lean used only while wall running. This is applied through
## the same lean system as normal movement so it never changes facing.
@export var wall_run_lean_angle_deg: float = 8.0

@export_group("Squash & Stretch")
## Maximum vertical stretch applied during fast movement / airborne motion.
@export var squash_stretch_max_stretch: float = 0.12
## Maximum vertical squash used on hard landings.
@export var squash_stretch_max_squash: float = 0.16
## Planar speed at which speed-based stretch starts contributing.
@export var squash_stretch_speed_start: float = 4.0
## Vertical speed needed for the airborne stretch to reach its maximum.
@export var squash_stretch_vertical_speed: float = 10.0
## How quickly squash/stretch follows its target.
@export var squash_stretch_smoothing: float = 12.0
## How much a slide compresses the body while it is on the ground.
@export var squash_stretch_slide_squash: float = 0.06

var model_yaw_basis: Basis = Basis.IDENTITY
var model_base_scale: Vector3 = Vector3.ONE
var current_lean: float = 0.0
var current_squash_stretch: float = 0.0

# ============================================================
# JUMPING
# ============================================================
# A jump is three timed phases, so it plays out the same way every time:
#
#   RISING   -- rise gravity pulls you up to the apex over exactly
#               jump_rise_time seconds.
#   HANGING  -- vertical velocity is held at zero for jump_hang_time.
#   falling  -- fall gravity takes over; dropping jump_height back to
#               takeoff level takes jump_fall_time seconds.
#
# Rise and fall use different gravity values, both DERIVED from
# height + time (h = 1/2 * g * t^2 -> g = 2h / t^2), so you tune the
# jump by how long it should take rather than by guessing at gravity.
# Physics runs at a fixed tick, so real timings land within a frame or
# two of the numbers below.
#
# There are three kinds of jump (JumpKind), each with its own shape,
# locked in at takeoff:
#   NORMAL -- ground, coyote and air jumps, using the settings below.
#   SLIDE  -- jumping out of a slide: lower, longer, and launched
#             along the slide (see "Slide").
#   WALL   -- jumping off a wall: a normal-height jump pushed away
#             from the wall (see "Wall Movement").
# ============================================================
@export_group("Jumping")
## Height of a jump in metres, measured from where you left the ground.
@export var jump_height: float = 2.0
## Seconds from takeoff to the top of the jump.
@export var jump_rise_time: float = 0.4
## Seconds spent floating at the top before you start to fall.
## 0 disables the hang.
@export var jump_hang_time: float = 0.1
## Seconds to fall from the top back down to takeoff height.
@export var jump_fall_time: float = 0.35
## Cap on downward speed so long falls don't accelerate forever.
## Set well above what any jump reaches (2 * height / fall_time) so it
## never affects jump timing.
@export var max_fall_speed: float = 30.0
## How much of your ground acceleration/deceleration you keep while
## airborne. 1.0 = same as on the ground, 0 = no steering at all.
## (This was hard-coded to 0.45 before.)
@export var jump_air_control: float = 0.45
@export var coyote_time: float = 0.15
@export var jump_buffer: float = 0.15
## Total jumps including the initial ground/coyote one. 3 = ground
## jump + double + triple. Kept at 3 so the play_triple_jump() branch
## in _handle_jump is actually reachable from the script default and
## not only when the inspector overrides it. Each jump's shape is
## locked in at its own takeoff (see _set_jump_profile).
@export var max_jumps: int = 3

enum JumpPhase { NONE, RISING, HANGING }
enum JumpKind { NORMAL, SLIDE, WALL }

var jump_phase: JumpPhase = JumpPhase.NONE
var jump_phase_timer: float = 0.0

# Shape of the jump currently in progress, set by _set_jump_profile().
# Between jumps these hold the normal values, which is also what
# walking off a ledge falls with.
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

# ============================================================
# OTS EXPLORE MODE
# ============================================================
@export_group("OTS Explore Mode")
var is_ots_mode: bool = false

# ============================================================
# TURN RATE  (feeds the lean)
# ============================================================
var turn_rate: float = 0.0
var prev_model_forward: Vector3 = Vector3.FORWARD

# ============================================================
# LIFECYCLE
# ============================================================
func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	model_yaw_basis = character_model.global_basis
	model_base_scale = character_model.scale

	_resolve_body_center_offset()
	_set_jump_profile()

	if player_collision_shape and player_collision_shape.shape:
		player_collision_shape.shape = player_collision_shape.shape.duplicate()
		_set_slide_collision(false)

	telekinesis_controller.setup(self, camera_3d)
	combat_controller.setup(self, camera_3d)
	interaction_highlight_controller.setup(self, camera_3d)

	if Particle_Controller:
		Particle_Controller.setup(self)


func _unhandled_input(event: InputEvent) -> void:

	if event.is_action_pressed("ToggleOTS"):
		if is_ots_mode:
			is_ots_mode = false
		elif is_on_floor():
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

	# update_look has to stay here -- _get_target_motion reads
	# aim_pivot.global_basis, so the arm's ORIENTATION must be current
	# before movement runs. The aim pivot's POSITION is updated after
	# move_and_slide instead (see below), so the camera isn't reading a
	# pre-move transform for position and a post-move one for rotation.
	spring_arm.update_look(delta)

	_read_input(delta)
	_update_ground_state(delta)
	_update_slide(delta)
	_update_wall_movement(delta)

	if is_ots_mode and not is_on_floor():
		is_ots_mode = false

	_handle_movement(delta)
	_handle_jump(delta)

	# Deliberately AFTER _handle_jump: a jump replaces vertical velocity
	# outright, and if gravity were queued first it would be applied on
	# top of the jump on the takeoff frame and shave a little off it.
	_apply_gravity(delta)

	_integrate_velocity(delta)
	move_and_slide()

	aim_pivot.global_position = get_body_center()
	spring_arm.update_pivot_position(delta)

	telekinesis_controller.update(delta)
	combat_controller.update(delta)
	interaction_highlight_controller.update(delta)

	if Particle_Controller:
		Particle_Controller.update(delta)

	# Animation reads fully-updated physics state for this frame.
	if animation_controller:
		animation_controller.update(delta)


# ============================================================
# INPUT HANDLING
# ============================================================
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

	if Input.is_action_pressed("Run") and move_input.length_squared() > 0.0:
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


## The world-space direction the movement input points, on the ground
## plane relative to the camera. Zero when there's no input.
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


# ============================================================
# GROUND STATE
# ============================================================
func _update_ground_state(delta: float) -> void:

	if is_on_floor():
		var planar_velocity: Vector3 = velocity.slide(up_direction)

		# Arm the brake only on the frame we actually touch down, and
		# only if we arrived faster than the limit. Running this check
		# every grounded frame instead would cap ALL ground movement at
		# max_landing_speed.
		if not was_grounded_last_frame and planar_velocity.length() > max_landing_speed:
			landing_brake_timer = landing_brake_time

		if landing_brake_timer > 0.0:
			landing_brake_timer -= delta

			if planar_velocity.length() > max_landing_speed:
				var capped: Vector3 = planar_velocity.normalized() * max_landing_speed
				add_acceleration(
					acceleration_toward(planar_velocity, capped, landing_brake_acceleration, delta)
				)

		coyote_timer = coyote_time
		jumps_used = 0
		jump_phase = JumpPhase.NONE
		# Back to the normal profile once landed, so walking off a ledge
		# later falls with normal gravity rather than a stale slide or
		# wall jump's.
		_set_jump_profile()
	else:
		coyote_timer -= delta
		landing_brake_timer = 0.0

	was_grounded_last_frame = is_on_floor()


# ============================================================
# GRAVITY
# ============================================================
## Locks in the shape of a jump. `kind` picks which set of settings is
## used (see JumpKind): NORMAL uses the Jumping group, SLIDE the slide
## jump's own height / times / air control, WALL a normal jump with the
## wall jump's air control.
##
## Everything is derived from height + time so the timings stay exact:
##   gravity = 2h / t^2        takeoff speed = 2h / t
## It's a snapshot taken at takeoff rather than a live read, so nothing
## can change gravity halfway through the jump.
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

	rise_t = maxf(rise_t, 0.01)
	fall_t = maxf(fall_t, 0.01)

	_active_rise_time = rise_t
	_active_hang_time = maxf(jump_hang_time, 0.0)
	_active_jump_velocity = 2.0 * height / rise_t
	_active_rise_gravity = 2.0 * height / (rise_t * rise_t)
	_active_fall_gravity = 2.0 * height / (fall_t * fall_t)
	_active_air_control = air_control


## Fall gravity for the jump in progress (normal gravity when not
## jumping). Public so the animation controller can use it to predict
## landings -- it stays accurate for slide and wall jumps too.
func get_fall_gravity() -> float:
	return _active_fall_gravity


func _apply_gravity(delta: float) -> void:

	# Wall running and sliding take over the vertical axis. Expressed as
	# an acceleration toward a target vertical velocity, so velocity
	# still has a single mutation point.
	if wall_state == WallState.RUNNING:
		add_acceleration(acceleration_toward(
			velocity.project(up_direction),
			-up_direction * wall_run_sink_speed,
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

	# Hit a ceiling on the way up: skip the hang and just start falling.
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
		# Hold vertical velocity at zero. Expressed as an acceleration
		# that cancels it this frame, so velocity still has a single
		# mutation point. Horizontal movement is untouched.
		add_acceleration(-velocity.project(up_direction) / maxf(delta, 0.0001))

		jump_phase_timer -= delta
		if jump_phase_timer <= 0.0:
			jump_phase = JumpPhase.NONE
		return

	# Everything else -- falling after a jump, walking off a ledge, or
	# standing on the ground (constant gravity keeps floor contact
	# stable). Capped so long drops don't accelerate forever.
	if velocity.dot(up_direction) > -max_fall_speed:
		add_acceleration(-up_direction * get_fall_gravity())


# ============================================================
# JUMP
# ============================================================
func _handle_jump(_delta: float) -> void:

	if jump_buffer_timer <= 0.0:
		return

	# On a wall (sliding or running): jump away from it.
	if wall_state != WallState.NONE:
		_start_wall_jump()
		return

	if coyote_timer > 0.0:
		# Out of a slide (or a moment after one ends): a long jump.
		if is_sliding or _slide_jump_grace_timer > 0.0:
			_start_jump(JumpKind.SLIDE, _slide_direction * slide_jump_speed)
			_end_slide(false)
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


## Every jump -- ground, coyote, air, slide or wall -- goes through
## here. `kind` picks the jump's shape (see _set_jump_profile).
## Whatever vertical motion exists (rising, falling, standing) is
## cancelled first, so a jump taken while falling feels the same as one
## taken from the ground.
##
## SLIDE and WALL jumps also set the horizontal launch outright:
## `planar_launch` is the horizontal velocity the character should have
## right after takeoff. It's ignored for NORMAL jumps, which keep the
## momentum they already have.
func _start_jump(kind: JumpKind = JumpKind.NORMAL, planar_launch: Vector3 = Vector3.ZERO) -> void:
	_set_jump_profile(kind)

	var impulse: Vector3 = -velocity.project(up_direction) + up_direction * _active_jump_velocity

	if kind != JumpKind.NORMAL:
		impulse += planar_launch - velocity.slide(up_direction)

	add_impulse(impulse)
	jump_phase = JumpPhase.RISING
	jump_phase_timer = _active_rise_time


# ============================================================
# SLIDE
# ============================================================
# Right click (the "Slide" input action) while running starts a slide
# on the ground. The character keeps its heading -- steering is locked
# for the duration -- and its speed follows a curve from slide_speed
# down to slide_end_speed over slide_duration.
#
# It ends when the time is up, the character leaves the ground, runs
# into something, or movement is locked. Jumping during it (or within
# SLIDE_JUMP_GRACE after a timed-out slide) is a slide jump instead of a
# normal jump: lower, longer, launched at slide_jump_speed.
# ============================================================
var is_sliding := false
var slide_timer: float = 0.0  # seconds into the current slide
var _slide_direction: Vector3 = Vector3.ZERO
var _slide_jump_grace_timer: float = 0.0


func _can_start_slide() -> bool:
	# is_running is already false while movement is locked or in OTS
	# mode. The speed check stops a slide from a running-on-the-spot
	# against a wall.
	return is_on_floor() and is_running and get_planar_speed() > walk_speed


func _start_slide() -> void:
	var heading: Vector3 = velocity.slide(up_direction)
	if heading.length_squared() < 0.0001:
		return

	_slide_direction = heading.normalized()
	is_sliding = true
	slide_timer = 0.0
	_slide_jump_grace_timer = 0.0
	_set_slide_collision(true)


## Ends the slide. `allow_jump_grace` is for a slide that simply ran
## out of time -- a jump pressed a hair late still counts as a slide
## jump. Every other way of ending gets no grace.
func _end_slide(allow_jump_grace: bool) -> void:
	is_sliding = false
	slide_timer = 0.0
	_slide_jump_grace_timer = SLIDE_JUMP_GRACE if allow_jump_grace else 0.0
	_set_slide_collision(false)


## Ends the slide and forgets it completely (resets, captures).
func _cancel_slide() -> void:
	is_sliding = false
	slide_timer = 0.0
	_slide_jump_grace_timer = 0.0
	_set_slide_collision(false)


func _set_slide_collision(sliding: bool) -> void:
	if not player_collision_shape:
		return

	var capsule := player_collision_shape.shape as CapsuleShape3D
	if not capsule:
		push_warning("Player: CollisionShape3D must use a CapsuleShape3D for slide collision resizing.")
		return

	player_collision_shape.position.y = SLIDE_COLLISION_Y if sliding else NORMAL_COLLISION_Y
	capsule.height = SLIDE_COLLISION_HEIGHT if sliding else NORMAL_COLLISION_HEIGHT


func _update_slide(delta: float) -> void:

	_slide_jump_grace_timer = maxf(_slide_jump_grace_timer - delta, 0.0)

	if is_sliding:
		slide_timer += delta

		# Left the ground for longer than the coyote window (a ledge).
		var lost_ground: bool = not is_on_floor() and coyote_timer <= 0.0
		# Ran into something and stopped.
		var blocked: bool = slide_timer > 0.1 and get_planar_speed() < SLIDE_MIN_SPEED

		if movement_locked or is_ots_mode or lost_ground or blocked:
			_end_slide(false)
		elif slide_timer >= slide_duration:
			_end_slide(true)
		return

	if Input.is_action_just_pressed("Slide") and _can_start_slide():
		_start_slide()


## Where the slide's speed curve is right now.
func _get_slide_speed() -> float:
	var t: float = clampf(slide_timer / maxf(slide_duration, 0.01), 0.0, 1.0)
	return lerpf(slide_speed, slide_end_speed, t)


# ============================================================
# WALL MOVEMENT
# ============================================================
# All of this happens in the air, and finds walls by casting short rays
# out from the body centre (see wall_check_distance).
#
# WALL RUN   -- in the air, running (Run held, moving at least
#               wall_run_min_speed) with a wall beside you and
#               travelling roughly ALONG it (within ~40 degrees).
#               You're carried along the wall at wall_run_speed, held
#               at almost constant height, for up to wall_run_max_time
#               per trip through the air. Ends on running out of time,
#               the wall ending, releasing Run, or landing.
# WALL SLIDE -- in the air, coming down (not rising), with the
#               movement input pushing into a wall -- i.e. jumping
#               into it. Fall speed is capped at wall_slide_speed.
#               Ends when you stop pushing into the wall, the wall
#               ends, or you land.
# WALL JUMP  -- jump while wall running or sliding: you're pushed away
#               from the wall (keeping any speed along it) with a
#               normal-height jump.
#
# After a wall jump or a wall run ending you can't grab a wall again
# for wall_regrab_delay, so you get clear of the one you just left.
# ============================================================
enum WallState { NONE, RUNNING, SLIDING }

var wall_state: WallState = WallState.NONE
var is_wall_running := false
var is_wall_sliding := false
## Which side the wall is on while wall running: 1 = right, -1 = left,
## 0 otherwise. Public so an animation can pick the matching clip.
var wall_side: int = 0
var _wall_normal: Vector3 = Vector3.ZERO  # horizontal, points away from the wall
var _wall_run_direction: Vector3 = Vector3.ZERO
var _wall_run_speed: float = 0.0
var _wall_run_time_left: float = 0.0
var _wall_lockout_timer: float = 0.0
## One wall interaction (run OR slide) is allowed per airborne trip.
var _wall_move_used: bool = false


func _update_wall_movement(delta: float) -> void:

	_wall_lockout_timer = maxf(_wall_lockout_timer - delta, 0.0)

	# Wall movement only exists in the air. Touching down ends it and
	# refills the wall run time.
	if is_on_floor() or movement_locked or is_ots_mode:
		_end_wall_movement(false)
		if is_on_floor():
			_wall_run_time_left = wall_run_max_time
			_wall_move_used = false
		return

	match wall_state:
		WallState.RUNNING:
			_update_wall_run(delta)
		WallState.SLIDING:
			_update_wall_slide()
		WallState.NONE:
			if not _wall_move_used and _wall_lockout_timer <= 0.0 and not _try_start_wall_run():
				_try_start_wall_slide()


func _try_start_wall_run() -> bool:
	if not is_running or _wall_run_time_left <= 0.0:
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

		# Heading mostly INTO the wall (or steeply away from it) isn't a
		# run. Into is a wall slide; away is just moving away.
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
	_wall_move_used = true
	_wall_normal = wall_normal
	_wall_run_direction = along.normalized()
	_wall_run_speed = maxf(wall_run_speed, planar.length())
	_update_wall_side()

	# Whatever the jump was doing, the wall takes over the vertical axis.
	jump_phase = JumpPhase.NONE
	jump_phase_timer = 0.0
	return true


func _try_start_wall_slide() -> void:
	# Let a rising jump finish first; the slide takes over once you're
	# coming down (or hanging at the top).
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
	_wall_move_used = true
	_wall_normal = normal
	jump_phase = JumpPhase.NONE
	jump_phase_timer = 0.0


func _update_wall_run(delta: float) -> void:
	_wall_run_time_left -= delta

	# Look at the wall again every frame, so a curved wall is followed
	# and a wall that ends lets go.
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

	# Let go by releasing the input, or when the wall runs out.
	if hit.is_empty() or not pressing_in:
		_end_wall_movement(false)
		return

	_wall_normal = hit["normal"]


func _start_wall_jump() -> void:
	var normal: Vector3 = _wall_normal

	# Keep whatever speed there is along the wall (a wall run's speed;
	# next to nothing from a slide) and add a push away from it.
	var along: Vector3 = velocity.slide(up_direction).slide(normal)
	_start_jump(JumpKind.WALL, along + normal * wall_jump_away_speed)

	_end_wall_movement(true)
	jump_buffer_timer = 0.0
	jumps_used = 1


## Ends wall running / sliding. `with_regrab_delay` also blocks grabbing
## a wall again for wall_regrab_delay. Safe to call anytime.
func _end_wall_movement(with_regrab_delay: bool) -> void:
	if wall_state == WallState.NONE:
		return

	_set_wall_state(WallState.NONE)
	wall_side = 0

	if with_regrab_delay:
		_wall_lockout_timer = wall_regrab_delay


func _set_wall_state(state: WallState) -> void:
	wall_state = state
	is_wall_running = state == WallState.RUNNING
	is_wall_sliding = state == WallState.SLIDING


func _update_wall_side() -> void:
	var right: Vector3 = _wall_run_direction.cross(up_direction)
	wall_side = 1 if right.dot(-_wall_normal) > 0.0 else -1


## Casts a ray from the body centre along `direction` (horizontal, unit
## length) for wall_check_distance. Returns the hit -- with "normal"
## flattened to horizontal -- or an empty Dictionary if there's no wall
## there. Only near-vertical surfaces count, and moving bodies (NPCs,
## physics objects) are ignored.
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

	# A wall's normal is close to horizontal; floors, ramps and ceilings
	# aren't walls.
	if absf(surface_normal.dot(up_direction)) > 0.3 or flat.length_squared() < 0.0001:
		return {}

	hit["normal"] = flat.normalized()
	return hit


# ============================================================
# MODEL ORIENTATION
# ============================================================
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


# ============================================================
# TARGET MOTION
# ============================================================
## Speed the character is trying to reach: walk -> run normally, the
## slide's curve while sliding, the wall run speed while wall running.
## Shared by _get_target_motion and current_speed so the two can't
## disagree.
func _get_target_speed() -> float:
	if is_sliding:
		return _get_slide_speed()

	if is_wall_running:
		return _wall_run_speed

	return lerpf(walk_speed, run_speed, run_blend)


func _get_target_motion() -> Dictionary:
	var up := up_direction

	# Sliding and wall running steer themselves: the input is ignored
	# for the direction of travel.
	if is_sliding:
		return {
			"target_velocity": _slide_direction * _get_target_speed(),
			"target_forward": _slide_direction
		}

	if is_wall_running:
		return {
			# The small push into the wall keeps contact so the wall
			# check keeps finding it.
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


# ============================================================
# MOVEMENT
# ============================================================
func _handle_movement(delta: float) -> void:

	# Sliding and wall running move the character with no input needed,
	# so they count as "moving" for the blend, the acceleration choice
	# and turning the model to face the way it's going.
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

	# Air control comes from the jump in progress (normal, slide or
	# wall), locked in at takeoff like the rest of the jump's shape.
	# Walking off a ledge uses the normal value.
	var air_factor: float = _active_air_control if !is_on_floor() else 1.0

	# Both sides projected onto the horizontal plane, so the movement
	# acceleration only ever acts horizontally and never fights gravity
	# or a jump along the up axis.
	var current_planar_velocity: Vector3 = velocity.slide(up_direction)
	var target_planar_velocity: Vector3 = target_velocity.slide(up_direction)

	# A slide and a wall run track their own speed with their own
	# acceleration, rather than the ordinary ground/air one.
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

	# Runs every frame, regardless of move_input.
	_update_model_orientation(delta)

	if is_moving_input:
		move_direction = target["target_forward"]
		current_speed = _get_target_speed()

		# While sliding down a wall, keep the model facing the direction
		# it was already facing. The movement input points into the wall,
		# but using that as the model's target forward would turn the
		# character toward the wall. All other movement keeps the existing
		# facing behaviour.
		if not is_wall_sliding:
			var up := up_direction
			var target_forward := move_direction.slide(up).normalized()

			if target_forward.length_squared() > 0.001:
				var target_basis := Basis.looking_at(target_forward, up)
				model_yaw_basis = Basis(
					model_yaw_basis
					.get_rotation_quaternion()
					.slerp(target_basis.get_rotation_quaternion(), rotation_speed * delta)
				)

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

	# Normalized against TOP speed, not run_speed -- against run_speed
	# this saturated at 1.0 the moment you started running, so lean at
	# run speed and lean at anything faster looked identical.
	var top_speed: float = maxf(maxf(lean_top_speed, run_speed), 0.001)
	var speed_fraction: float = clampf(get_planar_speed() / top_speed, 0.0, 1.0)
	var shaped_fraction: float = pow(speed_fraction, max(lean_speed_curve_power, 0.001))

	# Faster travel both reaches the lean sooner AND raises the ceiling
	# on how far it can bank.
	var max_angle: float = deg_to_rad(lean_max_angle_deg) * lerpf(1.0, lean_high_speed_multiplier, shaped_fraction)

	if is_on_floor():
		var normalized_turn := clampf(turn_rate / lean_turn_rate_reference, -1.0, 1.0)
		target_lean = normalized_turn * max_angle * shaped_fraction

	# Wall running adds only a small roll offset to the existing lean.
	# wall_side == 1 means the wall is on the player's right, so lean
	# left; wall_side == -1 means the wall is on the player's left, so
	# lean right. When wall running ends this contributes zero, so the
	# normal lean smoothly takes over again.
	if is_wall_running and wall_side != 0:
		target_lean += deg_to_rad(wall_run_lean_angle_deg) * float(wall_side)

	# Stepped against the BASE angle, not the speed-scaled one --
	# otherwise lean_smoothing_speed silently means "faster response at
	# high speed" rather than a fixed rate.
	var max_step := deg_to_rad(lean_max_angle_deg) * lean_smoothing_speed * delta
	current_lean = move_toward(current_lean, target_lean, max_step)

	# Squash & stretch is kept in this same transform path as the lean so
	# there is still only one system writing the model's basis. Positive
	# values stretch vertically; negative values squash it. The horizontal
	# axes compensate so the character keeps roughly the same volume.
	var target_squash_stretch := 0.0
	var planar_speed := get_planar_speed()
	var speed_fraction1 := clampf(
		(planar_speed - squash_stretch_speed_start) / maxf(lean_top_speed - squash_stretch_speed_start, 0.001),
		0.0,
		1.0
	)

	# Fast movement gives a subtle lengthening even when grounded.
	target_squash_stretch += speed_fraction1 * squash_stretch_max_stretch * 0.35

	# Jumping / falling provides the more noticeable airborne stretch.
	if not is_on_floor():
		var vertical_speed := absf(velocity.dot(up_direction))
		var air_fraction := clampf(vertical_speed / maxf(squash_stretch_vertical_speed, 0.001), 0.0, 1.0)
		target_squash_stretch = maxf(target_squash_stretch, air_fraction * squash_stretch_max_stretch)

	# Slides sit low to the ground, so give them a small persistent squash.
	if is_sliding:
		target_squash_stretch = minf(target_squash_stretch, -squash_stretch_slide_squash)

	# A landing brake is armed on the first frame after a hard touchdown.
	# Use it as the landing squash cue without adding a second landing-state
	# system. Stronger incoming speed produces a stronger, capped squash.
	if is_on_floor() and landing_brake_timer > 0.0:
		var landing_speed := get_planar_speed()
		var landing_fraction := clampf(landing_speed / maxf(max_landing_speed, 0.001), 0.0, 1.0)
		target_squash_stretch = minf(
			target_squash_stretch,
			-landing_fraction * squash_stretch_max_squash
		)

	var squash_weight := 1.0 - exp(-maxf(squash_stretch_smoothing, 0.001) * delta)
	current_squash_stretch = lerpf(current_squash_stretch, target_squash_stretch, squash_weight)

	var vertical_scale := 1.0 + current_squash_stretch
	var horizontal_scale := 1.0 / sqrt(maxf(vertical_scale, 0.001))
	var final_basis := model_yaw_basis.rotated(model_yaw_basis.z, current_lean)
	final_basis = final_basis.scaled(Vector3(
		model_base_scale.x * horizontal_scale,
		model_base_scale.y * vertical_scale,
		model_base_scale.z * horizontal_scale
	))
	character_model.global_basis = final_basis


# ============================================================
# HELPERS
# ============================================================
func is_moving() -> bool:
	return move_input.length_squared() > 0.001


## Actual current speed across the ground plane, with motion along the
## up axis (falling, jumping) excluded. This is what locomotion
## animations should blend on -- it's what the feet are really doing.
func get_planar_speed() -> float:
	return velocity.slide(up_direction).length()


func force_idle() -> void:
	# Intentional hard stop -- this is a "reset the character" call
	# (respawn/cutscene), not continuous motion. Everything with
	# carry-over state gets cleared, or a respawn mid-slide resumes at
	# slide speed with a banked model and a live landing brake.
	# (hard_stop also cancels any slide or wall movement.)
	hard_stop()
	move_input = Vector2.ZERO
	run_timer = 0.0
	is_running = false
	run_blend = 0.0
	current_speed = 0.0
	current_lean = 0.0
	current_squash_stretch = 0.0
	turn_rate = 0.0
	landing_brake_timer = 0.0

	if Particle_Controller:
		Particle_Controller.clear()

	if animation_controller:
		animation_controller.force_idle()


func stop_horizontal_velocity() -> void:
	# Intentional hard stop on the planar axes only, preserving motion
	# along the up axis. Kept as an explicit, separate call rather than
	# something the movement code does implicitly.
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

		# Also cancels any slide or wall movement.
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
