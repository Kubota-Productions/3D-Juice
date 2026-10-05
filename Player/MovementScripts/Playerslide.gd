class_name PlayerSlide
extends PlayerMovementModule

@export_group("Slide")
@export var speed: float = 7.5
@export var end_speed: float = 3.0
@export var duration: float = 0.7
@export var acceleration: float = 40.0
@export var jump_speed: float = 10.0
@export var jump_height: float = 1.2
@export var jump_rise_time: float = 0.45
@export var jump_fall_time: float = 0.44
@export var jump_air_control: float = 0.1
@export var max_speed: float = 14.0
@export var slope_acceleration: float = 14.0
@export var slope_min_angle_deg: float = 8.0
@export var slope_full_angle_deg: float = 35.0
## While sliding, surfaces up to this steep still count as floor (the
## CharacterBody3D default of 45 degrees is what used to drop the player off
## steeper slopes). Never lowers the body's own floor_max_angle.
@export_range(0.0, 89.0) var floor_max_angle_deg: float = 75.0
## While sliding, how far the body will snap back down to the surface after
## a frame of moving off it. At speed on a downhill the ground drops away
## faster than the default snap (0.1) can follow, so the player went
## airborne. Never lowers the body's own floor_snap_length.
@export var floor_snap_length: float = 0.5
## How long the slide survives while airborne (bumps, crests, small drops)
## before it ends. Slide jumps stay available during this window.
@export var air_grace: float = 0.3
## Walking up a slope that's too steep to stand on (steeper than the body's
## normal floor limit, up to floor_max_angle_deg) puts you in a slide
## back down it.
@export var from_steep_slopes: bool = true

const JUMP_GRACE := 0.15
const MIN_SPEED := 1.0
## On surfaces steeper than the body's normal floor limit, the slide ends if
## it is heading up them (dot with the downhill direction below this value).
const STEEP_UPHILL_LIMIT := -0.2
## How directly the player has to be pushing up a too-steep slope (dot of
## the input with the uphill direction) before it counts as an attempt to climb it.
const STEEP_SLOPE_PUSH_THRESHOLD := 0.3
## Probing the real surface under a contact (see get_slope_surface_normal):
## how far each ray reaches either side of the surface, how far up the slope
## the second sample is taken, and how closely the two face normals have to
## agree (dot product) to count as one slope.
const SLOPE_PROBE_DEPTH := 0.1
const SLOPE_PROBE_SPACING := 0.15
const SLOPE_PROBE_MATCH := 0.95

var is_active := false
var from_dive := false
var timer: float = 0.0
var direction: Vector3 = Vector3.ZERO
var jump_grace_timer: float = 0.0
var current_speed: float = 0.0
var current_duration: float = 0.7
var elapsed: float = 0.0
var air_time: float = 0.0
var last_downhill: float = 0.0

## The body's own floor settings, cached in setup so the slide can raise
## them temporarily and put them back afterwards.
var default_floor_max_angle: float = 0.785398
var default_floor_snap_length: float = 0.1


func setup(target: Player) -> void:
	super(target)
	default_floor_max_angle = player.floor_max_angle
	default_floor_snap_length = player.floor_snap_length


func can_start() -> bool:
	return player.is_on_floor() and player.is_running and player.get_planar_speed() > player.walk_speed


func start() -> void:
	var heading: Vector3 = player.velocity.slide(player.up_direction)
	if heading.length_squared() < 0.0001:
		return

	begin(heading.normalized())


func begin(new_direction: Vector3) -> void:
	direction = new_direction
	is_active = true
	from_dive = false
	timer = 0.0
	current_speed = speed
	current_duration = duration
	elapsed = 0.0
	air_time = 0.0
	last_downhill = 0.0
	jump_grace_timer = 0.0
	player.landing_brake_timer = 0.0
	player.refresh_collision()


func end(allow_jump_grace: bool) -> void:
	is_active = false
	timer = 0.0
	jump_grace_timer = JUMP_GRACE if allow_jump_grace else 0.0
	player.refresh_collision()


func cancel() -> void:
	is_active = false
	timer = 0.0
	jump_grace_timer = 0.0
	player.refresh_collision()


func apply_floor_settings() -> void:
	if is_active:
		player.floor_max_angle = maxf(default_floor_max_angle, deg_to_rad(floor_max_angle_deg))
		player.floor_snap_length = maxf(default_floor_snap_length, floor_snap_length)
	else:
		player.floor_max_angle = default_floor_max_angle
		player.floor_snap_length = default_floor_snap_length


## True when the slide is heading up a surface that only counts as floor
## because of the slide's raised floor angle (i.e. steeper than the body's
## normal limit). Without this the slide would run up steep walls.
func is_climbing_steep_slope() -> bool:
	if not player.is_on_floor():
		return false

	var floor_normal: Vector3 = player.get_floor_normal()
	var angle: float = acos(clampf(floor_normal.dot(player.up_direction), -1.0, 1.0))
	if angle <= default_floor_max_angle:
		return false

	var downhill: Vector3 = floor_normal.slide(player.up_direction)
	if downhill.length_squared() < 0.0001:
		return false

	return direction.dot(downhill.normalized()) < STEEP_UPHILL_LIMIT


## Blocked by something while crouched under cover: hand steering back to the
## player so they can crawl back out instead of being stuck in the slide.
func steer_in_crawlspace() -> void:
	var input_direction: Vector3 = player.get_input_direction()
	if input_direction.length_squared() < 0.0001:
		return

	direction = input_direction
	elapsed = 0.0


## The slide ran its course. If the slide/crouch button is still held, drop
## straight into a crouch instead of standing up. (Jumping out of the slide,
## losing the ground, or entering OTS mode use end() directly and never
## crouch.) The crouch starts before the slide ends so the short collider
## never grows for a frame in between.
func finish(allow_jump_grace: bool) -> void:
	var stay_low: bool = (
		player.is_on_floor()
		and InputMap.has_action(Player.CROUCH_ACTION)
		and player.crouch_slide_held()
	)

	if stay_low:
		player.is_running = false
		player.run_timer = 0.0
		player.start_crouch()

	end(allow_jump_grace)


## The normal of the surface itself at a contact, or Vector3.ZERO if the
## contact isn't on a flat-enough face. When the capsule's rounded bottom
## presses on a corner (the edge of a flat ledge or step), the contact normal
## points from the corner toward the capsule and comes out angled even
## though neither face is. Ray-casting the face at the contact, and a little
## further up it, only agrees on a normal when there really is a slope there.
func get_slope_surface_normal(collision: KinematicCollision3D) -> Vector3:
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	if not space:
		return Vector3.ZERO

	var contact: Vector3 = collision.get_position()
	var contact_normal: Vector3 = collision.get_normal()

	var up_slope: Vector3 = player.up_direction.slide(contact_normal)
	if up_slope.length_squared() < 0.0001:
		return Vector3.ZERO
	up_slope = up_slope.normalized()

	var samples: Array[Vector3] = [contact, contact + up_slope * SLOPE_PROBE_SPACING]
	var face_normal: Vector3 = Vector3.ZERO

	for point in samples:
		var query := PhysicsRayQueryParameters3D.create(
			point + contact_normal * SLOPE_PROBE_DEPTH,
			point - contact_normal * SLOPE_PROBE_DEPTH,
			player.collision_mask,
			[player.get_rid()]
		)
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			return Vector3.ZERO

		var hit_normal: Vector3 = hit["normal"]
		if face_normal == Vector3.ZERO:
			face_normal = hit_normal
		elif hit_normal.dot(face_normal) < SLOPE_PROBE_MATCH:
			return Vector3.ZERO

	return face_normal


## Attempting to walk up a slope too steep to stand on (steeper than the
## body's normal floor limit, but within what the slide can grip) puts the
## player into a slide back down it.
func try_steep_slope_slide() -> void:
	if not from_steep_slopes:
		return

	if is_active or player.dive.is_active or player.movement_locked or player.is_ots_mode:
		return

	if player.wall.state != PlayerWallMovement.WallState.NONE:
		return

	if player.jump_phase == Player.JumpPhase.RISING:
		return

	var input_direction: Vector3 = player.get_input_direction()
	if input_direction.length_squared() < 0.0001:
		return

	var steepest_walkable: float = default_floor_max_angle
	var steepest_gripped: float = deg_to_rad(floor_max_angle_deg)

	for i in player.get_slide_collision_count():
		var collision: KinematicCollision3D = player.get_slide_collision(i)
		var contact_normal: Vector3 = collision.get_normal()
		var contact_angle: float = acos(clampf(contact_normal.dot(player.up_direction), -1.0, 1.0))

		if contact_angle <= steepest_walkable or contact_angle > steepest_gripped:
			continue

		# Make sure it's an actual slope and not the edge of a flat ledge
		# or step (see get_slope_surface_normal).
		var normal: Vector3 = get_slope_surface_normal(collision)
		if normal == Vector3.ZERO:
			continue

		var angle: float = acos(clampf(normal.dot(player.up_direction), -1.0, 1.0))
		if angle <= steepest_walkable or angle > steepest_gripped:
			continue

		# The contact has to be down at the feet (walking into or standing on
		# the slope), not the upper body brushing it mid-jump.
		var contact_height: float = (collision.get_position() - player.global_position).dot(player.up_direction)
		if contact_height > Player.NORMAL_COLLISION_HEIGHT * 0.5:
			continue

		var downhill: Vector3 = normal.slide(player.up_direction)
		if downhill.length_squared() < 0.0001:
			continue
		downhill = downhill.normalized()

		# Only when pushing up the slope, not along or away from it.
		if input_direction.dot(downhill) > -STEEP_SLOPE_PUSH_THRESHOLD:
			continue

		begin(downhill)
		return


func update(delta: float) -> void:

	jump_grace_timer = maxf(jump_grace_timer - delta, 0.0)

	if is_active:
		elapsed += delta

		if player.is_on_floor():
			air_time = 0.0
		else:
			air_time += delta

		# The old check used the 0.15s coyote timer, which a fast downhill
		# slide easily outlasts. The slide now gets its own, longer grace.
		var lost_ground: bool = air_time > air_grace
		var blocked: bool = (
			(elapsed > 0.1 and player.get_planar_speed() < MIN_SPEED)
			or is_climbing_steep_slope()
		)

		# Airborne too long (or locked): there's no floor to clip through, so just end it.
		if player.movement_locked or lost_ground:
			end(false)
			return

		# Still inside the air grace: keep the slide jump available (the
		# jump logic keys off the coyote timer), without extending it
		# past the end of the grace.
		if not player.is_on_floor():
			player.coyote_timer = maxf(player.coyote_timer, delta)

		# Anything else that would end the slide only does so if the player
		# fits at full height. Otherwise they stay crouched and keep sliding
		# until the cover ends, instead of the collider growing into it.
		if player.is_ots_mode or blocked:
			if player.can_stand_up():
				if blocked and not player.is_ots_mode:
					finish(false)
				else:
					end(false)
				return

			if blocked:
				steer_in_crawlspace()

		var downhill: float = get_downhill_factor()

		# Airborne for a frame or two on a slope: keep the last downhill
		# boost instead of treating it as flat ground (which would bleed
		# speed and run down the slide timer).
		if player.is_on_floor():
			last_downhill = downhill
		else:
			downhill = last_downhill

		if downhill > 0.0:
			current_speed = move_toward(
				current_speed,
				max_speed,
				slope_acceleration * downhill * delta
			)
		else:
			var remaining: float = maxf(current_duration - timer, 0.001)
			current_speed = lerpf(
				current_speed,
				end_speed,
				clampf(delta / remaining, 0.0, 1.0)
			)
			timer += delta

			# Out of time, but only stand up once there's room. Until then the
			# slide carries on at end_speed.
			if timer >= current_duration and player.can_stand_up():
				finish(true)
		return

	if player.crouch_slide_pressed() and can_start():
		start()


func get_speed() -> float:
	return current_speed


func get_jump_launch() -> Vector3:
	return direction * maxf(jump_speed, current_speed)


func get_target_motion() -> Dictionary:
	return {
		"target_velocity": direction * current_speed,
		"target_forward": direction
	}


func get_downhill_factor() -> float:
	if not player.is_on_floor():
		return 0.0

	var floor_normal: Vector3 = player.get_floor_normal()
	var angle: float = acos(clampf(floor_normal.dot(player.up_direction), -1.0, 1.0))

	if angle < deg_to_rad(slope_min_angle_deg):
		return 0.0

	var downhill: Vector3 = floor_normal.slide(player.up_direction)
	if downhill.length_squared() < 0.0001:
		return 0.0

	var alignment: float = direction.dot(downhill.normalized())
	if alignment <= 0.0:
		return 0.0

	var steepness: float = clampf(
		angle / maxf(deg_to_rad(slope_full_angle_deg), 0.001),
		0.0,
		1.0
	)
	return steepness * alignment
