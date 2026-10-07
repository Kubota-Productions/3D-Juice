extends Node
class_name TelekinesisController

# ============================================================
# REFERENCES
# ============================================================
var player: CharacterBody3D
var camera: Camera3D
var gravity_controller: GravityController

## Offset from the camera, in camera-local space.
## x = right, y = up, z = forward-distance.
@export_group("Hold Position")
@export var hold_offset: Vector3 = Vector3(0.6, 0.35, 1.4)

# ============================================================
# TARGETING
# ============================================================
@export_group("Targeting")
@export var reach: float = 8.0

## RigidBody3D nodes must be in this group to be grabbable.
@export var pickup_group: String = "telekinesis_target"

## Maximum number of objects that can be held at once.
@export var max_held_objects: int = 5

# ============================================================
# MULTI-OBJECT FORMATION
# ============================================================
@export_group("Object Formation")

## Distance between each held object.
@export var object_spacing: float = 0.8

## Objects are offset horizontally from the main hold point.
## Example with 5 objects:
##
##       Object 5
##    Object 4
##  Object 3
##    Object 2
##       Object 1
##
## This value controls how much the formation spreads vertically.
@export var formation_vertical_spacing: float = 0.35

## How much the formation is shifted backwards for each object.
## This prevents objects from occupying exactly the same depth.
@export var formation_depth_spacing: float = 0.15

# ============================================================
# HOLD BEHAVIOR
# ============================================================
@export_group("Hold")
@export var pull_in_time: float = 0.4
@export var pull_in_ease_power: float = 2.5
@export var hold_smoothing_time: float = 0.08
@export var max_hold_speed: float = 25.0
@export var hold_break_distance: float = 3.0
@export var pickup_snap_distance: float = 0.35
@export var rotation_freeze_time: float = 0.4
@export var hold_spin_speed_deg: float = 15.0

# ============================================================
# ARC (PULL-IN PATH)
# ============================================================
@export_group("Arc")
@export var arc_height: float = 1.5

# ============================================================
# IDLE BOB
# ============================================================
@export_group("Idle Bob")
@export var bob_fade_distance: float = 1.2
@export var bob_amplitude: float = 0.08
@export var bob_frequency: float = 0.7
var _bob_noise: FastNoiseLite = FastNoiseLite.new()

# ============================================================
# LAUNCH
# ============================================================
@export_group("Launch")

@export var launch_speed: float = 30.0

# ============================================================
# GRAVITY METER COST
# ============================================================
@export_group("Gravity Meter Cost")
@export var gravity_meter_cost: float = 20.0

# ============================================================
# PLATFORMS (tkplatform)
# ============================================================
@export_group("Platforms")

## Anything in this group can be raised with Telekinesis. Tag the
## AnimatableBody3D itself, with Sync To Physics turned on, so the
## player is carried along when it moves.
@export var platform_group: String = "tkplatform"

## How far the camera ray reaches when looking for a platform to raise.
@export var platform_reach: float = 20.0

## Rise speed (units/sec) while the button is held.
@export var platform_rise_speed: float = 3.0

## Seconds to ramp from standstill up to platform_rise_speed.
@export var platform_rise_ramp_time: float = 0.3

## Default maximum height above the platform's starting position.
## A platform can override this by giving the node a float metadata
## entry called "tk_max_rise".
@export var platform_max_rise: float = 8.0

## A locked platform starts sinking back to its starting height once
## the player is farther than this from it. Distance is measured to the
## nearest point of the platform's collision shapes (not its origin), so
## big platforms behave the same as small ones. Keep it larger than
## platform_reach. It never sinks while the player is standing on it.
@export var platform_return_distance: float = 30.0

## Speed (units/sec) a platform sinks back to its starting height.
@export var platform_return_speed: float = 2.0

## Seconds a sinking platform takes to ramp up to platform_return_speed.
@export var platform_return_ramp_time: float = 0.4

## Prints platform state changes (RISING / LOCKED / RETURNING / RESTING)
## to the Output panel. Handy for tracking down a platform that isn't
## behaving.
@export var debug_platforms: bool = false
@export var platform_safe_margin: float = 0.02

const MAX_PLATFORM_IGNORES := 8

# ============================================================
# HELD OBJECT DATA
# ============================================================
class HeldObjectData:
	var object: RigidBody3D
	var original_gravity_scale: float = 1.0
	var is_pulling_in: bool = true
	var elapsed: float = 0.0
	var confirmed: bool = false
	var reserved_amount: float = 0.0
	var pull_start_position: Vector3 = Vector3.ZERO
	var bob_noise_offset: float = 0.0

var held_objects: Array[HeldObjectData] = []

var is_button_held: bool = false


# ============================================================
# PLATFORM DATA
# ============================================================
## RESTING:   at its starting height, untouched.
## RISING:    the button is held and it's being raised.
## LOCKED:    released -- frozen exactly where it was.
## RETURNING: sinking back to its starting height.
enum PlatformState { RESTING, RISING, LOCKED, RETURNING }

class PlatformData:
	var node: Node3D
	var home_y: float = 0.0
	var max_y: float = 0.0
	var state: int = 0
	## Current speed of whatever movement the platform is doing (rising
	## or sinking). Reset to 0 on every state change.
	var move_speed: float = 0.0
	## Collision-shape bounds in the platform's own space. Used to
	## measure how far the player is from the platform itself.
	var local_bounds: AABB = AABB()
	var sink_blocked: bool = false
	
## Every platform that has been touched, keyed by instance id.
var platforms: Dictionary = {}

## The platform currently being raised (null when none).
var active_platform: PlatformData = null


func setup(owner: CharacterBody3D, cam: Camera3D) -> void:
	player = owner
	camera = cam
	gravity_controller = owner.get_node_or_null("GravityController")
	_bob_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_bob_noise.seed = randi()
	_bob_noise.frequency = 1.0


# ============================================================
# INPUT
# ============================================================
## Called from Player._unhandled_input.
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("Telekinesis"):
		is_button_held = true

		if _try_grab():
			return

		# Looking at a tkplatform (or standing on one) -- raise it, or
		# unlock it if it's locked, instead of launching.
		if _try_start_platform():
			return

		# Nothing new to grab right now -- fall back to launching
		# the oldest confirmed object.
		_launch_first_confirmed_object()

	elif event.is_action_released("Telekinesis"):
		is_button_held = false

		# Letting go before the current grab has arrived cancels it --
		# it never counts as picked up, and nothing is deducted.
		_cancel_unconfirmed_grab()

		# Whatever platform was being raised locks right where it is.
		_release_platform()


# ============================================================
# GRAB
# ============================================================
func _has_unconfirmed() -> bool:
	for data in held_objects:
		if not data.confirmed:
			return true
	return false


func _has_confirmed_objects() -> bool:
	for data in held_objects:
		if data.confirmed:
			return true
	return false


func _can_afford_pickup() -> bool:
	if not gravity_controller:
		return true  # not wired up -- don't block the ability entirely
	return gravity_controller.shift_power >= gravity_meter_cost


func _try_grab() -> bool:
	if not camera or not player:
		return false

	if _has_unconfirmed():
		return false

	if held_objects.size() >= max_held_objects:
		return false

	if not _can_afford_pickup():
		return false

	var from: Vector3 = camera.global_position
	var to: Vector3 = from + (-camera.global_transform.basis.z * reach)

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player]

	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)

	if not hit:
		return false

	var body := hit.collider as RigidBody3D

	if not body:
		return false

	if not body.is_in_group(pickup_group):
		return false

	# Prevent grabbing the same object twice.
	if _is_already_held(body):
		return false

	var data := HeldObjectData.new()

	data.object = body
	data.original_gravity_scale = body.gravity_scale
	data.is_pulling_in = true
	data.elapsed = 0.0
	data.confirmed = false
	data.reserved_amount = 0.0
	data.pull_start_position = body.global_position
	data.bob_noise_offset = randf_range(-1000.0, 1000.0)

	# Disable gravity while telekinetically holding it.
	body.gravity_scale = 0.0

	# Remove any existing spin.
	body.angular_velocity = Vector3.ZERO

	# Add to the END of the queue.
	held_objects.append(data)

	return true


func _is_already_held(body: RigidBody3D) -> bool:
	for data in held_objects:
		if data.object == body:
			return true

	return false


func _cancel_unconfirmed_grab() -> void:
	for i in range(held_objects.size() - 1, -1, -1):
		var data: HeldObjectData = held_objects[i]

		if data.confirmed:
			continue

		if is_instance_valid(data.object):
			data.object.gravity_scale = data.original_gravity_scale

		held_objects.remove_at(i)


# ============================================================
# UPDATE
# ============================================================
## Called from Player._physics_process, after move_and_slide().
func update(delta: float) -> void:
	if not camera or not player:
		return

	# Platforms go first: the early return below (nothing held) would
	# otherwise skip them.
	_update_platforms(delta)

	# Holding the button with nothing currently in flight means "keep
	# grabbing" -- this is what lets you sweep the reticle across
	# several objects in one continuous hold instead of needing a
	# fresh press per object.
	if is_button_held and not _has_unconfirmed() and held_objects.size() < max_held_objects:
		_try_grab()

	if held_objects.is_empty():
		return

	# Work backwards so removing invalid/broken objects during
	# this update does not cause array-index problems.
	for i in range(held_objects.size() - 1, -1, -1):
		var data: HeldObjectData = held_objects[i]

		if not is_instance_valid(data.object):
			if data.confirmed:
				_release_power(data)
			held_objects.remove_at(i)
			continue

		var should_remove: bool = _update_held_object(data, i, delta)

		if should_remove:
			held_objects.remove_at(i)


# ============================================================
# UPDATE ONE HELD OBJECT
# ============================================================
## Returns true if this object should be removed from held_objects.
func _update_held_object(
	data: HeldObjectData,
	queue_index: int,
	delta: float
) -> bool:

	var body: RigidBody3D = data.object

	data.elapsed += delta

	# --------------------------------------------------------
	# FIND THIS OBJECT'S POSITION IN THE FORMATION
	# --------------------------------------------------------
	var true_target: Vector3 = _get_object_hold_position(queue_index)

	var true_distance: float = (
		true_target - body.global_position
	).length()

	# --------------------------------------------------------
	# PULL-IN STATE / CONFIRMATION
	# --------------------------------------------------------
	if data.is_pulling_in:
		if true_distance <= pickup_snap_distance:
			data.is_pulling_in = false

			if not data.confirmed:
				if is_button_held and _can_afford_pickup():
					# Arrived while still held, and can afford it --
					# this is the moment it actually counts as picked up.
					data.confirmed = true
					data.reserved_amount = gravity_meter_cost
					_reserve_power(data)
				else:
					# Button was released before it arrived, or the
					# player can no longer afford it -- the pickup
					# never completes.
					_drop_object(data)
					return true
	else:
		if true_distance > hold_break_distance:
			_drop_object(data)
			if data.confirmed:
				_release_power(data)
			return true

	# --------------------------------------------------------
	# PLAYER/CAMERA DIRECTIONS
	# --------------------------------------------------------
	var up: Vector3 = player.up_direction
	var right: Vector3 = player.global_basis.x
	var forward: Vector3 = -player.global_basis.z

	var steering_target: Vector3

	# --------------------------------------------------------
	# PULL-IN: eased (accelerating) path from the grab point to the
	# arc-bowed target, instead of letting velocity fall out of raw
	# distance-to-target (which is what caused the old "decelerates
	# into place" behavior -- that was an exponential-decay approach,
	# fastest at the start and slowest at the end).
	# --------------------------------------------------------
	if data.is_pulling_in:
		var t: float = clamp(
			data.elapsed / max(pull_in_time, 0.001),
			0.0,
			1.0
		)

		# Raw (non-eased) t for the arc's bell curve -- the bow's
		# timing is independent of how the straight-line progress
		# is paced.
		var arc_offset: float = sin(PI * t) * arc_height
		var path_target: Vector3 = true_target + up * arc_offset

		var eased_t: float = pow(t, max(pull_in_ease_power, 0.001))

		steering_target = data.pull_start_position.lerp(path_target, eased_t)
	else:
		steering_target = true_target

		# --------------------------------------------------------
	# IDLE BOB
	# --------------------------------------------------------
	#
	# Uses smooth simplex noise to create subtle, continuously
	# changing floating motion.
	#
	# The noise is sampled independently for each object so
	# multiple held objects don't move identically.
	#
	# Unlike the old implementation, we don't add a separate
	# velocity feed-forward term. The normal position tracker
	# follows the bob target, which gives the motion a much
	# smoother "floating in the air" feel.
	var bob_fade_raw: float = clamp(
		1.0 - (
			true_distance /
			max(bob_fade_distance, 0.001)
		),
		0.0,
		1.0
	)

	# Smoothstep fade.
	var bob_fade: float = (
		bob_fade_raw *
		bob_fade_raw *
		(3.0 - 2.0 * bob_fade_raw)
	)

	var bob_vector: Vector3 = Vector3.ZERO

	if bob_fade > 0.0:
		# Time moving through the noise field.
		var noise_t: float = data.elapsed * bob_frequency

		# Give every object its own area of the noise field.
		var object_offset: float = float(queue_index) * 37.17

		# Three independent noise samples.
		#
		# Vertical is strongest.
		# Horizontal is weaker.
		# Depth is weakest.
		var bob_vertical: float = _bob_noise.get_noise_2d(
			noise_t,
			object_offset
		)

		var bob_horizontal: float = _bob_noise.get_noise_2d(
			noise_t + 100.0,
			object_offset + 23.7
		)

		var bob_depth: float = _bob_noise.get_noise_2d(
			noise_t + 200.0,
			object_offset + 51.4
		)

		bob_vector = (
			up * bob_vertical +
			right * bob_horizontal * 0.4 +
			forward * bob_depth * 0.3
		) * bob_amplitude * bob_fade

	steering_target += bob_vector

	# --------------------------------------------------------
	# MOVEMENT
	# --------------------------------------------------------
	var to_target: Vector3 = steering_target - body.global_position
	var weight: float = 1.0 - exp(-delta / max(hold_smoothing_time, 0.001))
	var desired_velocity: Vector3 = to_target * weight / max(delta, 0.0001)

	if desired_velocity.length() > max_hold_speed:
		desired_velocity = desired_velocity.normalized() * max_hold_speed

	body.linear_velocity = desired_velocity

	# --------------------------------------------------------
	# ROTATION
	# --------------------------------------------------------
	if data.elapsed < rotation_freeze_time:
		# Hard-lock rotation during the initial pull.
		body.angular_velocity = Vector3.ZERO
	else:
		# Slowly spin around the player's current up direction.
		var target_angular_velocity: Vector3 = (
			up *
			deg_to_rad(hold_spin_speed_deg)
		)

		body.angular_velocity = body.angular_velocity.lerp(
			target_angular_velocity,
			weight
		)

	return false


# ============================================================
# FORMATION POSITION
# ============================================================
func _get_object_hold_position(queue_index: int) -> Vector3:
	if not camera or not player:
		return Vector3.ZERO

	var up: Vector3 = player.up_direction
	var camera_forward: Vector3 = -camera.global_transform.basis.z

	# --------------------------------------------------------
	# BASE HOLD POSITION
	# --------------------------------------------------------
	var base_position: Vector3 = (
		camera.global_position
		+ camera.global_transform.basis.x * hold_offset.x
		+ camera.global_transform.basis.y * hold_offset.y
		- camera.global_transform.basis.z * hold_offset.z
	)

	# --------------------------------------------------------
	# FORMATION
	# --------------------------------------------------------
	#
	# We center the objects around the base position.
	#
	# For example, with 5 objects:
	#
	# index 0 = -2
	# index 1 = -1
	# index 2 =  0
	# index 3 = +1
	# index 4 = +2
	#
	# This means the first object is still the first one
	# launched, but the objects visually spread around the
	# hold position.
	var count: int = held_objects.size()

	var centered_index: float = (
		float(queue_index) -
		float(count - 1) * 0.5
	)

	var vertical_offset: float = (
		centered_index *
		formation_vertical_spacing
	)

	var depth_offset: float = (
		float(queue_index) *
		formation_depth_spacing
	)

	# Put each object at a slightly different position.
	#
	# vertical_offset:
	#     spreads the objects vertically.
	#
	# depth_offset:
	#     separates them in depth so physics bodies don't
	#     constantly overlap.
	return (
		base_position
		+ up * vertical_offset
		+ camera_forward * depth_offset
	)


# ============================================================
# LAUNCH FIRST CONFIRMED OBJECT
# ============================================================
## Launches the confirmed object that has been held the longest.
## Skips over an unconfirmed (still mid-pull-in) entry if present --
## that one hasn't "counted" as picked up yet and can't be launched.
func _launch_first_confirmed_object() -> void:
	for i in range(held_objects.size()):
		var data: HeldObjectData = held_objects[i]

		if not data.confirmed:
			continue

		held_objects.remove_at(i)

		if is_instance_valid(data.object):
			var body: RigidBody3D = data.object

			var direction: Vector3 = (
				-camera.global_transform.basis.z
			)

			# Restore the object's original gravity.
			body.gravity_scale = data.original_gravity_scale

			# Launch straight along the camera's forward direction.
			body.linear_velocity = (
				direction.normalized() *
				launch_speed
			)

		_release_power(data)
		return


# ============================================================
# DROP OBJECT
# ============================================================
func _drop_object(data: HeldObjectData) -> void:
	if not is_instance_valid(data.object):
		return

	data.object.gravity_scale = data.original_gravity_scale

	# Give it no artificial telekinesis velocity.
	#
	# If you want the object to retain its last velocity when
	# dropped, remove this line.
	data.object.linear_velocity = Vector3.ZERO


# ============================================================
# GRAVITY METER
# ============================================================
func _reserve_power(data: HeldObjectData) -> void:
	if not gravity_controller:
		return
	gravity_controller.reserve_power(data.reserved_amount)


func _release_power(data: HeldObjectData) -> void:
	if not gravity_controller:
		return
	gravity_controller.release_reserved_power(data.reserved_amount)


# ============================================================
# PLATFORMS
# ============================================================
## Called on a Telekinesis press that didn't grab anything. Picks the
## platform under the reticle (or, failing that, the one the player is
## standing on) and acts on its current state:
##   LOCKED    -> unlock it; it sinks back to its starting height.
##   otherwise -> start raising it from wherever it currently is.
## Returns true if a platform took the press.
func _try_start_platform() -> bool:
	var node: Node3D = _find_platform_under_reticle()

	# Not aiming at one: fall back to the platform underfoot -- but only
	# when there's no held object waiting to be launched, and never to
	# unlock a locked platform the player merely happens to be standing on.
	if node == null and not _has_confirmed_objects():
		var underfoot: Node3D = _get_platform_underfoot()
		var underfoot_data: PlatformData = _get_platform_data(underfoot)

		if underfoot != null and (underfoot_data == null or underfoot_data.state != PlatformState.LOCKED):
			node = underfoot

	if node == null:
		return false

	var data: PlatformData = _get_platform_data(node)

	# Using Telekinesis on a locked platform lets go of it.
	if data != null and data.state == PlatformState.LOCKED:
		_set_platform_state(data, PlatformState.RETURNING)
		return true

	_begin_raising(node)
	return true


func _begin_raising(node: Node3D) -> void:
	var data: PlatformData = _get_platform_data(node)

	if data == null:
		data = PlatformData.new()
		data.node = node
		data.home_y = node.global_position.y
		data.local_bounds = _compute_local_bounds(node)
		if debug_platforms:
			print("TelekinesisController: platform '", node.name, "' bounds: ", data.local_bounds)

		var max_rise: float = maxf(float(node.get_meta("tk_max_rise", platform_max_rise)), 0.0)
		data.max_y = data.home_y + max_rise

		platforms[node.get_instance_id()] = data
		_warn_if_not_animatable(node)
		_disable_builtin_platform_carry(node)

	# Only one platform is ever being raised at a time.
	if active_platform != null and active_platform != data:
		_set_platform_state(active_platform, PlatformState.LOCKED)

	_set_platform_state(data, PlatformState.RISING)
	active_platform = data


## Button released: the platform being raised freezes exactly where it is.
func _release_platform() -> void:
	if active_platform == null:
		return

	_set_platform_state(active_platform, PlatformState.LOCKED)

## How far the platform can drop before it would touch the top of the
## player's head. Returns INF when the player isn't underneath it (not
## overlapping it horizontally, or already level with / above its
## underside, e.g. standing on it).
## How far the platform can drop before it would touch the top of the
## player's head. Fires rays straight up from the player's body and
## finds this platform's real underside, so it doesn't depend on any
## precomputed bounds. Returns INF when the platform isn't above them.
func _drop_clearance_above_player(data: PlatformData) -> float:
	if not player:
		return INF

	var shape_node := player.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null:
		return INF

	var capsule := shape_node.shape as CapsuleShape3D
	if capsule == null:
		return INF

	var center: Vector3 = shape_node.global_position
	var head_y: float = center.y + capsule.height * 0.5
	var ring: float = capsule.radius * 0.9
	var reach: float = maxf(data.node.global_position.y - center.y, 0.0) + 5.0
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state

	# One ray up the middle plus a ring around the capsule's width.
	var offsets: Array[Vector3] = [Vector3.ZERO]
	for i in range(8):
		var angle: float = TAU * float(i) / 8.0
		offsets.append(Vector3(cos(angle), 0.0, sin(angle)) * ring)

	var clearance: float = INF

	for offset in offsets:
		var from: Vector3 = center + offset
		var to: Vector3 = from + Vector3.UP * reach
		var exclude: Array[RID] = [player.get_rid()]

		# Look past anything that isn't this platform (props, NPCs).
		for attempt in range(4):
			var query := PhysicsRayQueryParameters3D.create(from, to)
			query.exclude = exclude

			var hit: Dictionary = space.intersect_ray(query)
			if hit.is_empty():
				break

			if _platform_from_collider(hit["collider"]) == data.node:
				var hit_position: Vector3 = hit["position"]
				clearance = minf(clearance, maxf(hit_position.y - head_y, 0.0))
				break

			exclude.append(hit["rid"])

	if is_inf(clearance):
		return INF

	return maxf(clearance - platform_safe_margin, 0.0)

## Every state change goes through here so the bookkeeping can't drift.
func _set_platform_state(data: PlatformData, new_state: int) -> void:
	if data.state == new_state:
		return

	if debug_platforms:
		print(
			"TelekinesisController: platform '", data.node.name, "' ",
			PlatformState.keys()[data.state], " -> ", PlatformState.keys()[new_state]
		)

	data.state = new_state
	data.move_speed = 0.0

	# A platform that isn't rising can't be the one being held.
	if new_state != PlatformState.RISING and active_platform == data:
		active_platform = null


func _get_platform_data(node: Node3D) -> PlatformData:
	if node == null:
		return null

	return platforms.get(node.get_instance_id())


func _update_platforms(delta: float) -> void:
	if platforms.is_empty():
		return

	# Release is checked against the live input state as well as the
	# event-driven flag, so a release event that never arrives (focus
	# loss, another node eating it) can't leave a platform rising.
	if active_platform != null and (not is_button_held or not Input.is_action_pressed("Telekinesis")):
		_release_platform()

	var underfoot: Node3D = _get_platform_underfoot()

	# keys() hands back a copy, so erasing inside the loop is safe.
	for id in platforms.keys():
		var data: PlatformData = platforms[id]

		if not is_instance_valid(data.node):
			if data == active_platform:
				active_platform = null
			platforms.erase(id)
			continue

		match data.state:
			PlatformState.RISING:
				if data == active_platform:
					_update_platform_rising(data, underfoot, delta)
				else:
					_set_platform_state(data, PlatformState.LOCKED)
			PlatformState.LOCKED:
				_update_platform_locked(data, underfoot)
			PlatformState.RETURNING:
				_update_platform_returning(data, underfoot, delta)


func _update_platform_rising(data: PlatformData, underfoot: Node3D, delta: float) -> void:
	var accel: float = platform_rise_speed / maxf(platform_rise_ramp_time, 0.001)
	data.move_speed = move_toward(data.move_speed, platform_rise_speed, accel * delta)

	var step: float = data.move_speed * delta
	var remaining: float = data.max_y - data.node.global_position.y

	var hit_top: bool = step >= remaining
	if hit_top:
		step = maxf(remaining, 0.0)

	var allowed: float = _allowed_platform_rise(data, step, underfoot == data.node)
	var blocked: bool = allowed < step - 0.0001

	_move_platform(data, allowed, underfoot)

	# Max height or a ceiling/collider: stop and lock right there.
	if hit_top or blocked:
		_set_platform_state(data, PlatformState.LOCKED)


func _update_platform_locked(data: PlatformData, underfoot: Node3D) -> void:
	# Never sink out from under someone who's standing on it.
	if underfoot == data.node:
		return

	if _distance_to_platform(data) > platform_return_distance:
		_set_platform_state(data, PlatformState.RETURNING)

func _update_platform_returning(data: PlatformData, underfoot: Node3D, delta: float) -> void:
	var accel: float = platform_return_speed / maxf(platform_return_ramp_time, 0.001)
	data.move_speed = move_toward(data.move_speed, platform_return_speed, accel * delta)

	var current_y: float = data.node.global_position.y
	var target_y: float = move_toward(current_y, data.home_y, data.move_speed * delta)
	var dy: float = target_y - current_y

	if dy < 0.0:
		var wanted: float = dy

		dy = maxf(dy, -_drop_clearance_above_player(data))
		dy *= _sweep_shapes(_platform_shapes(data), Vector3(0.0, dy, 0.0), [], true, true)
		var blocked: bool = dy > wanted + 0.0001

		if debug_platforms and blocked != data.sink_blocked:
			print(
				"TelekinesisController: platform '", data.node.name, "' sinking ",
				"BLOCKED" if blocked else "clear"
			)
		data.sink_blocked = blocked

	_move_platform(data, dy, underfoot)

	if is_equal_approx(data.node.global_position.y, data.home_y):
		_set_platform_state(data, PlatformState.RESTING)


## Platforms only ever move on the world Y axis.
func _set_platform_y(node: Node3D, y: float) -> void:
	var p: Vector3 = node.global_position
	p.y = y
	node.global_position = p

## Moves the platform by dy and, if the player is standing on it, moves
## the player by exactly the same amount. Doing it here, in the same
## frame, avoids the lag/jitter of waiting for move_and_slide() to pick
## up the platform's velocity.
func _move_platform(data: PlatformData, dy: float, underfoot: Node3D) -> void:
	if is_zero_approx(dy):
		return

	_set_platform_y(data.node, data.node.global_position.y + dy)

	if underfoot == data.node and player:
		player.global_position += Vector3(0.0, dy, 0.0)


## How far (0..step) the platform can rise this frame. Sweeps the
## platform's collision shapes against the world, and also the rider's
## capsule so a ceiling can't squash them into the platform.
func _allowed_platform_rise(data: PlatformData, step: float, has_rider: bool) -> float:
	if step <= 0.0:
		return 0.0

	var platform_shapes: Array[CollisionShape3D] = _platform_shapes(data)
	var allowed: float = step * _sweep_shapes(
		platform_shapes, Vector3(0.0, step, 0.0), [], true, true
	)

	if has_rider and allowed > 0.0:
		var rider_shape := player.get_node_or_null("CollisionShape3D") as CollisionShape3D

		if rider_shape:
			var rider_shapes: Array[CollisionShape3D] = [rider_shape]

			# The platform under their feet must not count as a blocker.
			var platform_rids: Array[RID] = []
			for shape_node in platform_shapes:
				var body := shape_node.get_parent() as CollisionObject3D
				if body:
					platform_rids.append(body.get_rid())

			allowed *= _sweep_shapes(
				rider_shapes, Vector3(0.0, allowed, 0.0), platform_rids, true, true
			)

	return allowed

func _platform_shapes(data: PlatformData) -> Array[CollisionShape3D]:
	var shapes: Array[CollisionShape3D] = []
	_collect_collision_shapes(data.node, shapes)
	return shapes


## Sweeps each shape along `motion` and returns the fraction (0..1) of the
## motion that's free of obstacles. Uses the shape's owning body for the
## collision mask and excludes that body from the query. Characters and/or
## rigid bodies can be ignored (props and NPCs resting on the platform);
## they're identified at the contact point and excluded before retrying.
func _sweep_shapes(
	shape_nodes: Array[CollisionShape3D],
	motion: Vector3,
	extra_exclude: Array[RID] = [],
	ignore_characters: bool = false,
	ignore_rigid_bodies: bool = false
) -> float:
	if motion.is_zero_approx() or not player:
		return 1.0

	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var best: float = 1.0

	for shape_node in shape_nodes:
		if shape_node.disabled or shape_node.shape == null:
			continue

		# Concave (trimesh) shapes can't be swept through the world.
		if shape_node.shape is ConcavePolygonShape3D:
			continue

		var excluded: Array[RID] = extra_exclude.duplicate()
		var mask: int = 0xFFFFFFFF

		var owner_body := shape_node.get_parent() as CollisionObject3D
		if owner_body:
			excluded.append(owner_body.get_rid())
			mask = owner_body.collision_mask

		var resolved: bool = false

		for attempt in range(MAX_PLATFORM_IGNORES + 1):
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape_node.shape
			query.transform = shape_node.global_transform
			query.motion = motion
			query.collision_mask = mask
			query.exclude = excluded

			var fractions: PackedFloat32Array = space.cast_motion(query)

			# Nothing in the way.
			if fractions.size() < 2 or fractions[0] >= 1.0:
				resolved = true
				break

			var safe: float = fractions[0]
			var unsafe: float = fractions[1]

			# Who is at the point of contact?
			var probe := PhysicsShapeQueryParameters3D.new()
			probe.shape = shape_node.shape
			probe.transform = Transform3D(
				query.transform.basis,
				query.transform.origin + motion * unsafe
			)
			probe.collision_mask = mask
			probe.exclude = excluded
			probe.margin = platform_safe_margin

			var overlaps: Array[Dictionary] = space.intersect_shape(probe, 8)
			var blocking: bool = overlaps.is_empty()
			var to_ignore: Array[RID] = []

			for overlap in overlaps:
				var collider: Object = overlap["collider"]
				var ignorable: bool = (
					(ignore_characters and collider is CharacterBody3D)
					or (ignore_rigid_bodies and collider is RigidBody3D)
				)

				if ignorable:
					to_ignore.append(overlap["rid"])
				else:
					blocking = true

			if blocking:
				best = minf(best, safe)
				resolved = true
				break

			excluded.append_array(to_ignore)

		# Ran out of retries (a pile of props): be conservative.
		if not resolved:
			best = 0.0

		if best <= 0.0:
			return 0.0

	return best

## Wraps PhysicsBody3D.test_move(). Returns the part of `motion` the body
## can travel before hitting something. Characters and/or rigid bodies can
## be ignored (the player and NPCs standing on a platform, crates on it,
## etc.); they're added as temporary collision exceptions and removed again.
func _allowed_motion(
	body: PhysicsBody3D,
	motion: Vector3,
	ignore_characters: bool,
	ignore_rigid_bodies: bool
) -> Vector3:
	if body == null or motion.is_zero_approx():
		return motion

	# The platform's own mask may not include the player's layer, which
	# would make the player invisible to test_move(). Always include it
	# (and restore the mask afterwards).
	var original_mask: int = body.collision_mask
	if player and body != player:
		body.collision_mask |= player.collision_layer

	var ignored: Array[PhysicsBody3D] = []
	var result := Vector3.ZERO

	for i in range(MAX_PLATFORM_IGNORES + 1):
		var collision := KinematicCollision3D.new()

		if not body.test_move(body.global_transform, motion, collision, platform_safe_margin):
			result = motion
			break

		var collider := collision.get_collider() as PhysicsBody3D
		var skip: bool = collider != null and (
			(ignore_characters and collider is CharacterBody3D)
			or (ignore_rigid_bodies and collider is RigidBody3D)
		)

		if not skip:
			result = collision.get_travel()
			break

		body.add_collision_exception_with(collider)
		ignored.append(collider)

	for other in ignored:
		if is_instance_valid(other):
			body.remove_collision_exception_with(other)

	body.collision_mask = original_mask

	# Never move backwards or further than asked.
	if result.dot(motion) <= 0.0:
		return Vector3.ZERO

	return result.limit_length(motion.length())


## The controller now carries the player itself (see _move_platform).
## Without this, CharacterBody3D's built-in platform following would
## carry them a second time. Only affects this platform's collision layer.
func _disable_builtin_platform_carry(node: Node3D) -> void:
	var collision_object := node as CollisionObject3D

	if collision_object and player:
		player.platform_floor_layers &= ~collision_object.collision_layer

## Distance from the player to the nearest point of the platform's
## collision bounds (0 if the player is inside them).
func _distance_to_platform(data: PlatformData) -> float:
	var world_box: AABB = (data.node.global_transform * data.local_bounds).abs()
	var p: Vector3 = player.global_position
	var closest: Vector3 = p.clamp(world_box.position, world_box.end)
	return p.distance_to(closest)


## Bounding box of every CollisionShape3D under the platform, in the
## platform's own space. Falls back to a point at its origin if it has none.
func _compute_local_bounds(root: Node3D) -> AABB:
	var shapes: Array[CollisionShape3D] = []
	_collect_collision_shapes(root, shapes)

	var to_local: Transform3D = root.global_transform.affine_inverse()
	var bounds := AABB()
	var has_bounds: bool = false

	for shape_node in shapes:
		if shape_node.shape == null:
			continue

		var shape_box: AABB = to_local * shape_node.global_transform * shape_node.shape.get_debug_mesh().get_aabb()

		if has_bounds:
			bounds = bounds.merge(shape_box)
		else:
			bounds = shape_box
			has_bounds = true

	return bounds


func _collect_collision_shapes(node: Node, out: Array[CollisionShape3D]) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			out.append(child)

		_collect_collision_shapes(child, out)


## Camera ray against the world. Held telekinesis objects are skipped so
## they can't block the view of a platform.
func _find_platform_under_reticle() -> Node3D:
	if not camera or not player:
		return null

	var from: Vector3 = camera.global_position
	var to: Vector3 = from + (-camera.global_transform.basis.z * platform_reach)

	var excluded: Array[RID] = [player.get_rid()]
	for data in held_objects:
		if is_instance_valid(data.object):
			excluded.append(data.object.get_rid())

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = excluded

	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return null

	return _platform_from_collider(hit["collider"])


## The tkplatform the player is standing on, if any. Uses the collisions
## from this frame's move_and_slide().
func _get_platform_underfoot() -> Node3D:
	if not player:
		return null

	for i in range(player.get_slide_collision_count()):
		var collision: KinematicCollision3D = player.get_slide_collision(i)

		# Only surfaces that are actually floor, not a wall brushing past.
		if collision.get_normal().dot(player.up_direction) < 0.7:
			continue

		var node: Node3D = _platform_from_collider(collision.get_collider())

		if node:
			return node

	return null


## Walks up from a collider to the first node tagged as a platform.
func _platform_from_collider(collider: Object) -> Node3D:
	var node := collider as Node

	while node:
		if node.is_in_group(platform_group) and node is Node3D:
			return node as Node3D

		node = node.get_parent()

	return null


func _warn_if_not_animatable(node: Node3D) -> void:
	var body := node as AnimatableBody3D

	if body == null:
		push_warning(
			"TelekinesisController: '%s' is in group '%s' but isn't an AnimatableBody3D -- the player won't be carried smoothly. Tag the AnimatableBody3D itself." % [node.name, platform_group]
		)
	elif not body.sync_to_physics:
		push_warning(
			"TelekinesisController: '%s' has Sync To Physics turned off -- the player won't ride it properly. Turn it on in the Inspector." % node.name
		)


# ============================================================
# UTILITY
# ============================================================
## Returns the number of currently held objects (including an
## unconfirmed one currently mid-pull-in, if any).
func get_held_object_count() -> int:
	return held_objects.size()


## Returns true if at least one object is being held.
func has_held_objects() -> bool:
	return not held_objects.is_empty()


## Returns true while a platform is being raised.
func has_active_platform() -> bool:
	return active_platform != null


## Removes every currently held object, restores gravity, and
## releases any reserved gravity meter power.
func clear_held_objects() -> void:
	for data in held_objects:
		if is_instance_valid(data.object):
			data.object.gravity_scale = data.original_gravity_scale
		if data.confirmed:
			_release_power(data)

	held_objects.clear()
