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
## the player is farther than this from it (measured from the
## platform's origin, so keep it larger than the platform itself and
## larger than platform_reach). It never sinks while the player is
## standing on it.
@export var platform_return_distance: float = 30.0

## Speed (units/sec) a platform sinks back to its starting height.
@export var platform_return_speed: float = 2.0


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
	var rise_velocity: float = 0.0

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

		# Looking at a tkplatform (or standing on one) -- raise it
		# instead of launching.
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
## Called on a Telekinesis press that didn't grab anything. Raises the
## platform under the reticle, or failing that the one the player is
## standing on. Returns true if a platform was picked.
func _try_start_platform() -> bool:
	var node: Node3D = _find_platform_under_reticle()

	# Not aiming at one: fall back to the platform underfoot -- but only
	# when there's no held object waiting to be launched, so this
	# shortcut can never steal a launch.
	if node == null and not _has_confirmed_objects():
		node = _get_platform_underfoot()

	if node == null:
		return false

	_begin_raising(node)
	return true


func _begin_raising(node: Node3D) -> void:
	var id: int = node.get_instance_id()
	var data: PlatformData = platforms.get(id)

	if data == null:
		data = PlatformData.new()
		data.node = node
		data.home_y = node.global_position.y

		var max_rise: float = maxf(float(node.get_meta("tk_max_rise", platform_max_rise)), 0.0)
		data.max_y = data.home_y + max_rise

		platforms[id] = data
		_warn_if_not_animatable(node)

	# Works from wherever it currently is -- a locked or returning
	# platform just carries on rising from its present height.
	data.state = PlatformState.RISING
	data.rise_velocity = 0.0
	active_platform = data


## Button released: the platform being raised freezes exactly where it is.
func _release_platform() -> void:
	if active_platform == null:
		return

	_lock_platform(active_platform)


func _lock_platform(data: PlatformData) -> void:
	data.state = PlatformState.LOCKED
	data.rise_velocity = 0.0

	if active_platform == data:
		active_platform = null


func _update_platforms(delta: float) -> void:
	if platforms.is_empty():
		return

	# Safety net: if the button somehow isn't held any more, nothing
	# should still be rising.
	if active_platform != null and not is_button_held:
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
				_update_platform_rising(data, delta)
			PlatformState.LOCKED:
				_update_platform_locked(data, underfoot)
			PlatformState.RETURNING:
				_update_platform_returning(data, delta)


func _update_platform_rising(data: PlatformData, delta: float) -> void:
	# Ease up to full speed rather than starting at it.
	var accel: float = platform_rise_speed / maxf(platform_rise_ramp_time, 0.001)
	data.rise_velocity = move_toward(data.rise_velocity, platform_rise_speed, accel * delta)

	var new_y: float = data.node.global_position.y + data.rise_velocity * delta

	# Hit the top: stop there and lock.
	if new_y >= data.max_y:
		_set_platform_y(data.node, data.max_y)
		_lock_platform(data)
		return

	_set_platform_y(data.node, new_y)


func _update_platform_locked(data: PlatformData, underfoot: Node3D) -> void:
	# Never sink out from under someone who's standing on it.
	if underfoot == data.node:
		return

	var distance: float = player.global_position.distance_to(data.node.global_position)

	if distance > platform_return_distance:
		data.state = PlatformState.RETURNING


func _update_platform_returning(data: PlatformData, delta: float) -> void:
	var new_y: float = move_toward(
		data.node.global_position.y,
		data.home_y,
		platform_return_speed * delta
	)

	_set_platform_y(data.node, new_y)

	if is_equal_approx(new_y, data.home_y):
		data.state = PlatformState.RESTING


## Platforms only ever move on the world Y axis.
func _set_platform_y(node: Node3D, y: float) -> void:
	var p: Vector3 = node.global_position
	p.y = y
	node.global_position = p


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
