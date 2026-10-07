extends Node
class_name TelekinesisController

var player: CharacterBody3D
var camera: Camera3D
var gravity_controller: GravityController

@export_group("Hold Position")
@export var hold_offset: Vector3 = Vector3(0.6, 0.35, 1.4)

@export_group("Targeting")
@export var reach: float = 8.0
@export var pickup_group: String = "telekinesis_target"
@export var max_held_objects: int = 5

@export_group("Object Formation")
@export var object_spacing: float = 0.8
@export var formation_vertical_spacing: float = 0.35
@export var formation_depth_spacing: float = 0.15

@export_group("Hold")
@export var pull_in_time: float = 0.4
@export var pull_in_ease_power: float = 2.5
@export var hold_smoothing_time: float = 0.08
@export var max_hold_speed: float = 25.0
@export var hold_break_distance: float = 3.0
@export var pickup_snap_distance: float = 0.35
@export var rotation_freeze_time: float = 0.4
@export var hold_spin_speed_deg: float = 15.0

@export_group("Arc")
@export var arc_height: float = 1.5

@export_group("Idle Bob")
@export var bob_fade_distance: float = 1.2
@export var bob_amplitude: float = 0.08
@export var bob_frequency: float = 0.7
var _bob_noise: FastNoiseLite = FastNoiseLite.new()

@export_group("Launch")
@export var launch_speed: float = 30.0

@export_group("Gravity Meter Cost")
@export var gravity_meter_cost: float = 20.0

@export_group("Platforms")
@export var platform_group: String = "tkplatform"
@export var platform_reach: float = 20.0
@export var platform_rise_speed: float = 3.0
@export var platform_rise_ramp_time: float = 0.3
@export var platform_max_rise: float = 8.0
@export var platform_return_distance: float = 30.0
@export var platform_return_speed: float = 2.0
@export var platform_return_ramp_time: float = 0.4
@export var debug_platforms: bool = false
@export var platform_safe_margin: float = 0.02

const MAX_PLATFORM_IGNORES := 8

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

enum PlatformState { RESTING, RISING, LOCKED, RETURNING, BOOSTED }

class PlatformData:
	var node: Node3D
	var home_y: float = 0.0
	var max_y: float = 0.0
	var state: int = 0
	var move_speed: float = 0.0
	var local_bounds: AABB = AABB()
	var sink_blocked: bool = false
	var body: AnimatableBody3D = null
	var settle_frames: int = 0
	var boost_speed: float = 0.0

var platforms: Dictionary = {}

var active_platform: PlatformData = null


func setup(owner: CharacterBody3D, cam: Camera3D) -> void:
	player = owner
	camera = cam
	gravity_controller = owner.get_node_or_null("GravityController")
	_bob_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_bob_noise.seed = randi()
	_bob_noise.frequency = 1.0

func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("Telekinesis"):
		is_button_held = true

		if _try_grab():
			return

		if _try_start_platform():
			return

		_launch_first_confirmed_object()

	elif event.is_action_released("Telekinesis"):
		is_button_held = false
		_cancel_unconfirmed_grab()
		_release_platform()

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
		return true  
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

	body.gravity_scale = 0.0

	body.angular_velocity = Vector3.ZERO

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

func update(delta: float) -> void:
	if not camera or not player:
		return

	_update_platforms(delta)

	if is_button_held and not _has_unconfirmed() and held_objects.size() < max_held_objects:
		_try_grab()

	if held_objects.is_empty():
		return

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

func _update_held_object(
	data: HeldObjectData,
	queue_index: int,
	delta: float
) -> bool:

	var body: RigidBody3D = data.object

	data.elapsed += delta

	var true_target: Vector3 = _get_object_hold_position(queue_index)

	var true_distance: float = (
		true_target - body.global_position
	).length()

	if data.is_pulling_in:
		if true_distance <= pickup_snap_distance:
			data.is_pulling_in = false

			if not data.confirmed:
				if is_button_held and _can_afford_pickup():
					data.confirmed = true
					data.reserved_amount = gravity_meter_cost
					_reserve_power(data)
				else:
					_drop_object(data)
					return true
	else:
		if true_distance > hold_break_distance:
			_drop_object(data)
			if data.confirmed:
				_release_power(data)
			return true

	var up: Vector3 = player.up_direction
	var right: Vector3 = player.global_basis.x
	var forward: Vector3 = -player.global_basis.z

	var steering_target: Vector3

	if data.is_pulling_in:
		var t: float = clamp(
			data.elapsed / max(pull_in_time, 0.001),
			0.0,
			1.0
		)


		var arc_offset: float = sin(PI * t) * arc_height
		var path_target: Vector3 = true_target + up * arc_offset

		var eased_t: float = pow(t, max(pull_in_ease_power, 0.001))

		steering_target = data.pull_start_position.lerp(path_target, eased_t)
	else:
		steering_target = true_target
	var bob_fade_raw: float = clamp(
		1.0 - (
			true_distance /
			max(bob_fade_distance, 0.001)
		),
		0.0,
		1.0
	)

	var bob_fade: float = (
		bob_fade_raw *
		bob_fade_raw *
		(3.0 - 2.0 * bob_fade_raw)
	)

	var bob_vector: Vector3 = Vector3.ZERO

	if bob_fade > 0.0:
		var noise_t: float = data.elapsed * bob_frequency

		var object_offset: float = float(queue_index) * 37.17

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

	var to_target: Vector3 = steering_target - body.global_position
	var weight: float = 1.0 - exp(-delta / max(hold_smoothing_time, 0.001))
	var desired_velocity: Vector3 = to_target * weight / max(delta, 0.0001)

	if desired_velocity.length() > max_hold_speed:
		desired_velocity = desired_velocity.normalized() * max_hold_speed

	body.linear_velocity = desired_velocity

	if data.elapsed < rotation_freeze_time:
		body.angular_velocity = Vector3.ZERO
	else:
		var target_angular_velocity: Vector3 = (
			up *
			deg_to_rad(hold_spin_speed_deg)
		)

		body.angular_velocity = body.angular_velocity.lerp(
			target_angular_velocity,
			weight
		)

	return false

func _get_object_hold_position(queue_index: int) -> Vector3:
	if not camera or not player:
		return Vector3.ZERO

	var up: Vector3 = player.up_direction
	var camera_forward: Vector3 = -camera.global_transform.basis.z

	var base_position: Vector3 = (
		camera.global_position
		+ camera.global_transform.basis.x * hold_offset.x
		+ camera.global_transform.basis.y * hold_offset.y
		- camera.global_transform.basis.z * hold_offset.z
	)

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

	return (
		base_position
		+ up * vertical_offset
		+ camera_forward * depth_offset
	)

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

			body.gravity_scale = data.original_gravity_scale

			body.linear_velocity = (
				direction.normalized() *
				launch_speed
			)

		_release_power(data)
		return

func _drop_object(data: HeldObjectData) -> void:
	if not is_instance_valid(data.object):
		return

	data.object.gravity_scale = data.original_gravity_scale

	data.object.linear_velocity = Vector3.ZERO

func _reserve_power(data: HeldObjectData) -> void:
	if not gravity_controller:
		return
	gravity_controller.reserve_power(data.reserved_amount)


func _release_power(data: HeldObjectData) -> void:
	if not gravity_controller:
		return
	gravity_controller.release_reserved_power(data.reserved_amount)

func _try_start_platform() -> bool:
	var node: Node3D = _find_platform_under_reticle()
	if node == null and not _has_confirmed_objects():
		var underfoot: Node3D = _get_platform_underfoot()
		var underfoot_data: PlatformData = _get_platform_data(underfoot)

		if underfoot != null and (underfoot_data == null or underfoot_data.state != PlatformState.LOCKED):
			node = underfoot

	if node == null:
		return false

	var data: PlatformData = _get_platform_data(node)

	if data != null and data.state == PlatformState.LOCKED:
		_set_platform_state(data, PlatformState.RETURNING)
		return true

	_begin_raising(node)
	return true

func _ensure_platform_data(node: Node3D) -> PlatformData:
	var data: PlatformData = _get_platform_data(node)
	if data != null:
		return data

	data = PlatformData.new()
	data.node = node
	data.home_y = node.global_position.y

	_setup_platform_physics(data)
	data.local_bounds = _compute_local_bounds(node)

	if debug_platforms:
		print("TelekinesisController: platform '", node.name, "' bounds: ", data.local_bounds)

	var max_rise: float = maxf(float(node.get_meta("tk_max_rise", platform_max_rise)), 0.0)
	data.max_y = data.home_y + max_rise

	platforms[node.get_instance_id()] = data
	_disable_builtin_platform_carry(data.body)
	return data
func slam_boost_platform(speed_multiplier: float) -> bool:
	var node: Node3D = _get_platform_underfoot()
	if node == null:
		return false

	var data: PlatformData = _ensure_platform_data(node)
	data.boost_speed = platform_rise_speed * maxf(speed_multiplier, 0.0)
	_set_platform_state(data, PlatformState.BOOSTED)
	return true

func _update_platform_boosted(data: PlatformData, underfoot: Node3D, delta: float) -> void:
	data.move_speed = data.boost_speed

	var step: float = data.move_speed * delta
	var remaining: float = data.max_y - data.node.global_position.y

	var hit_top: bool = step >= remaining
	if hit_top:
		step = maxf(remaining, 0.0)

	var allowed: float = _allowed_platform_rise(data, step, underfoot == data.node)
	var blocked: bool = allowed < step - 0.0001

	_move_platform(data, allowed, underfoot)

	if hit_top or blocked:
		_set_platform_state(data, PlatformState.LOCKED)

func _begin_raising(node: Node3D) -> void:
	var data: PlatformData = _ensure_platform_data(node)

	if active_platform != null and active_platform != data:
		_set_platform_state(active_platform, PlatformState.LOCKED)

	_set_platform_state(data, PlatformState.RISING)
	active_platform = data

func _setup_platform_physics(data: PlatformData) -> void:
	var root: Node3D = data.node

	var body: AnimatableBody3D = root as AnimatableBody3D
	if body == null:
		body = _find_animatable(root)

	if body == null:
		body = AnimatableBody3D.new()
		body.name = "TKPlatformBody"
		root.add_child(body)

	body.sync_to_physics = true

	if body != root:
		body.top_level = true

	data.body = body
	data.settle_frames = 2

	var existing: Array[CollisionShape3D] = []
	_collect_collision_shapes(body, existing)
	if not existing.is_empty():
		return

	var csg: CSGShape3D = _find_csg(root)
	if csg == null:
		push_warning(
			"TelekinesisController: platform '%s' has no CollisionShape3D under its body and no CSG shape to build one from -- it can't be blocked by anything." % root.name
		)
		return

	var local_box: AABB
	if csg is CSGBox3D:
		var box_size: Vector3 = (csg as CSGBox3D).size
		local_box = AABB(-box_size * 0.5, box_size)
	else:
		local_box = csg.get_aabb()

	if local_box.size.length_squared() < 0.0001:
		push_warning(
			"TelekinesisController: platform '%s': couldn't work out the CSG's size to build a collision shape." % root.name
		)
		return

	var csg_xform: Transform3D = csg.global_transform

	if body != root:
		body.global_transform = Transform3D(
			root.global_transform.basis.orthonormalized(),
			root.global_transform.origin
		)

	var box := BoxShape3D.new()
	box.size = local_box.size * csg_xform.basis.get_scale().abs()

	var shape_node := CollisionShape3D.new()
	shape_node.name = "TKPlatformShape"
	shape_node.shape = box
	body.add_child(shape_node)
	shape_node.global_transform = Transform3D(
		csg_xform.basis.orthonormalized(),
		csg_xform * local_box.get_center()
	)

	body.collision_layer = csg.collision_layer
	body.collision_mask = csg.collision_mask

	csg.use_collision = false


func _find_csg(node: Node) -> CSGShape3D:
	if node is CSGShape3D:
		return node as CSGShape3D

	for child in node.get_children():
		var found: CSGShape3D = _find_csg(child)
		if found:
			return found

	return null


func _find_animatable(node: Node) -> AnimatableBody3D:
	for child in node.get_children():
		if child is AnimatableBody3D:
			return child as AnimatableBody3D

		var found: AnimatableBody3D = _find_animatable(child)
		if found:
			return found

	return null
func _release_platform() -> void:
	if active_platform == null:
		return

	_set_platform_state(active_platform, PlatformState.LOCKED)

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

	var offsets: Array[Vector3] = [Vector3.ZERO]
	for i in range(8):
		var angle: float = TAU * float(i) / 8.0
		offsets.append(Vector3(cos(angle), 0.0, sin(angle)) * ring)

	var clearance: float = INF

	for offset in offsets:
		var from: Vector3 = center + offset
		var to: Vector3 = from + Vector3.UP * reach
		var exclude: Array[RID] = [player.get_rid()]

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

	if new_state != PlatformState.RISING and active_platform == data:
		active_platform = null


func _get_platform_data(node: Node3D) -> PlatformData:
	if node == null:
		return null

	return platforms.get(node.get_instance_id())


func _update_platforms(delta: float) -> void:
	if platforms.is_empty():
		return

	if active_platform != null and (not is_button_held or not Input.is_action_pressed("Telekinesis")):
		_release_platform()

	var underfoot: Node3D = _get_platform_underfoot()

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
			PlatformState.BOOSTED:
				_update_platform_boosted(data, underfoot, delta)


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

	if hit_top or blocked:
		_set_platform_state(data, PlatformState.LOCKED)
	if data.settle_frames > 0:
		data.settle_frames -= 1
		return


func _update_platform_locked(data: PlatformData, underfoot: Node3D) -> void:
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

		var near_home: bool = current_y - data.home_y <= platform_safe_margin * 2.0
		if not near_home:
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

func _set_platform_y(node: Node3D, y: float) -> void:
	var p: Vector3 = node.global_position
	p.y = y
	node.global_position = p

func _move_platform(data: PlatformData, dy: float, underfoot: Node3D) -> void:
	if is_zero_approx(dy):
		return

	_set_platform_y(data.node, data.node.global_position.y + dy)

	if data.body != null and data.body != data.node:
		_set_platform_y(data.body, data.body.global_position.y + dy)

	if underfoot == data.node and player:
		player.global_position += Vector3(0.0, dy, 0.0)

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
	_collect_collision_shapes(data.body if data.body != null else data.node, shapes)
	return shapes

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

		if shape_node.shape is ConcavePolygonShape3D:
			continue

		var excluded: Array[RID] = extra_exclude.duplicate()
		var mask: int = 0xFFFFFFFF

		var owner_body := shape_node.get_parent() as CollisionObject3D
		if owner_body:
			excluded.append(owner_body.get_rid())
			mask = owner_body.collision_mask
		if ignore_characters or ignore_rigid_bodies:
			var touching := PhysicsShapeQueryParameters3D.new()
			touching.shape = shape_node.shape
			touching.transform = shape_node.global_transform
			touching.collision_mask = mask
			touching.exclude = excluded
			touching.margin = platform_safe_margin

			for overlap in space.intersect_shape(touching, 16):
				var touching_collider: Object = overlap["collider"]
				if (
					(ignore_characters and touching_collider is CharacterBody3D)
					or (ignore_rigid_bodies and touching_collider is RigidBody3D)
				):
					excluded.append(overlap["rid"])

		var resolved: bool = false

		for attempt in range(MAX_PLATFORM_IGNORES + 1):
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape_node.shape
			query.transform = shape_node.global_transform
			query.motion = motion
			query.collision_mask = mask
			query.exclude = excluded

			var fractions: PackedFloat32Array = space.cast_motion(query)

			if fractions.size() < 2 or fractions[0] >= 1.0:
				resolved = true
				break

			var safe: float = fractions[0]
			var unsafe: float = fractions[1]

			var probe := PhysicsShapeQueryParameters3D.new()
			probe.shape = shape_node.shape
			probe.transform = Transform3D(
				query.transform.basis,
				query.transform.origin + motion * unsafe
			)
			probe.collision_mask = mask
			probe.exclude = excluded

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

		if not resolved:
			best = 0.0

		if best <= 0.0:
			return 0.0

	return best

func _disable_builtin_platform_carry(body: CollisionObject3D) -> void:
	if body and player:
		player.platform_floor_layers &= ~body.collision_layer

func _distance_to_platform(data: PlatformData) -> float:
	var world_box: AABB = (data.node.global_transform * data.local_bounds).abs()
	var p: Vector3 = player.global_position
	var closest: Vector3 = p.clamp(world_box.position, world_box.end)
	return p.distance_to(closest)

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

func _get_platform_underfoot() -> Node3D:
	if not player:
		return null

	for i in range(player.get_slide_collision_count()):
		var collision: KinematicCollision3D = player.get_slide_collision(i)

		if collision.get_normal().dot(player.up_direction) < 0.7:
			continue

		var node: Node3D = _platform_from_collider(collision.get_collider())

		if node:
			return node

	return null

func _platform_from_collider(collider: Object) -> Node3D:
	var node := collider as Node

	while node:
		if node.is_in_group(platform_group) and node is Node3D:
			return node as Node3D

		node = node.get_parent()

	return null

func get_held_object_count() -> int:
	return held_objects.size()

func has_held_objects() -> bool:
	return not held_objects.is_empty()

func has_active_platform() -> bool:
	return active_platform != null

func clear_held_objects() -> void:
	for data in held_objects:
		if is_instance_valid(data.object):
			data.object.gravity_scale = data.original_gravity_scale
		if data.confirmed:
			_release_power(data)

	held_objects.clear()
