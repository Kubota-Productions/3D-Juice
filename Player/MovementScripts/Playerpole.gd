class_name PlayerPole
extends PlayerMovementModule

## Pole climbing.
##
## Tag any node as a pole by adding it to the "pole" group. The node needs a
## CollisionShape3D under it (cylinder / capsule is ideal) or, failing that, a
## mesh / CSG shape so the module can measure it. Poles are assumed to stand
## upright (rotating around Y is fine, tilting is not).
##
## Controls while on a pole:
##   forward / backwards  climb up / down
##   left / right         orbit around the pole
##   forward at the top   climb over the top and stand on it (scripted, like the ledge climb)
##   Jump                 kick off -- this goes through PlayerWallMovement.kick_off(),
##                        so it is the regular wall kick (launch, animation, facing)
##   Crouch / Slide       let go and drop
##
## The camera is carried round with the character while orbiting (see camera_follow
## and take_orbit_delta(), which camera_spring_arm.gd calls every frame).

@export_group("Grab")
@export var pole_group: StringName = &"pole"
## How close the capsule can be to the pole surface (metres) and still grab it.
@export var grab_distance: float = 0.35
## Walking into a pole on the ground grabs it. Turn off to only grab in midair.
@export var grab_from_ground: bool = true
## How directly the move input must point at the pole to count as "going for it".
@export_range(0.0, 1.0) var grab_input_dot: float = 0.5
## Midair, drifting toward a pole at this planar speed also grabs it (no input needed).
@export var grab_min_approach_speed: float = 2.0
@export var regrab_delay: float = 0.3

@export_group("Climbing")
@export var climb_speed: float = 2.5
@export var descend_speed: float = 4.0
## Constant slide speed with no input. 0 = hold position.
@export var idle_slide_speed: float = 0.0
@export var vertical_acceleration: float = 40.0
## Body-centre distance kept from the top / bottom end of the pole.
@export var top_margin: float = 0.25
@export var bottom_margin: float = 0.3

@export_group("Orbit")
@export var orbit_speed: float = 2.0
@export var acceleration: float = 50.0
## false: left / right always spins the same way round the pole (character's own
## right-hand side), so you can keep circling indefinitely.
## true: left / right follows the screen instead, scaled by how side-on the
## pole is to the camera. You stop at the left / right edge of the pole as seen
## by the camera and have to swing the camera to carry on.
@export var camera_relative_orbit: bool = false

@export_group("Top Climb")
## Climbing up to the top of the pole plays a climb-over and puts the character on top.
@export var climb_onto_top: bool = true
## Match this to the length of your PoleClimbTop animation.
@export var top_climb_time: float = 0.9
@export_range(0.05, 0.95) var top_climb_vertical_fraction: float = 0.65
## How far up the input has to be pushed, once at the top, to start the climb-over.
@export_range(0.0, 1.0) var top_climb_input_threshold: float = 0.5
## How close to the top (metres) counts as "at the top".
@export var top_trigger_tolerance: float = 0.05
@export var top_path_check_step: float = 0.3

@export_group("Camera")
## How much of the character's orbit the camera copies. 1 = the camera stays
## locked behind the character as they circle the pole, 0 = camera doesn't follow.
@export_range(0.0, 1.0) var camera_follow: float = 1.0

@export_group("Placement")
@export var hold_gap: float = 0.03
@export var attach_gain: float = 12.0
@export var attach_max_speed: float = 8.0
## If the capsule gets pushed this far past its hold distance, the grip is lost.
@export var break_distance: float = 1.0
@export var face_turn_speed: float = 16.0

@export_group("Let Go")
@export var drop_push: float = 1.5

## camera_relative_orbit: alignment with the camera at which orbit reaches full speed.
const CAMERA_ORBIT_FULL_ALIGNMENT := 0.5
const TOP_STAND_LIFT := 0.03
const TOP_CLEARANCE_LIFT := 0.04

## The pole owns the character (holding on, or climbing over the top).
var is_active := false
## Subset of is_active: the scripted climb-over is playing.
var is_topping_out := false
## True for the frame the player left the pole, so Crouch / Slide used to let go
## doesn't also trigger a dive or hover on that same frame.
var just_released := false
var lockout_timer: float = 0.0
var pole_node: Node3D = null
## Horizontal direction from the pole axis to the player.
var radial_out: Vector3 = Vector3.ZERO
## Character's right-hand direction while facing the pole.
var tangent: Vector3 = Vector3.ZERO

var gravity_controller: GravityController

var _top_timer: float = 0.0
var _top_start: Vector3 = Vector3.ZERO
var _top_mid: Vector3 = Vector3.ZERO
var _top_stand: Vector3 = Vector3.ZERO
var _tracked_radial: Vector3 = Vector3.ZERO

var _target_planar: Vector3 = Vector3.ZERO
var _target_vertical: float = 0.0
var _local_cache: Dictionary = {}


func setup(target: Player) -> void:
	super(target)
	gravity_controller = player.get_node_or_null("GravityController") as GravityController


func cancel() -> void:
	is_active = false
	is_topping_out = false
	pole_node = null
	_tracked_radial = Vector3.ZERO


# --------------------------------------------------------------------------
# Per-frame update (called from Player._physics_process before other modules)
# --------------------------------------------------------------------------

func update(delta: float) -> void:
	just_released = false
	lockout_timer = maxf(lockout_timer - delta, 0.0)

	# The climb-over is driven from Player._physics_process via update_top_climb().
	if is_topping_out:
		return

	if not is_active:
		var target: Node3D = find_grab_target()
		if target == null:
			return
		begin(target)

	update_attached(delta)


func begin(node: Node3D) -> void:
	# Same idea as the ledge grab: cancel every other movement state first.
	player.hard_stop()
	player.jump_buffer_timer = 0.0

	pole_node = node
	is_active = true


func end(drop: bool = false) -> void:
	if not is_active:
		return

	is_active = false
	is_topping_out = false
	just_released = true
	pole_node = null
	_tracked_radial = Vector3.ZERO
	lockout_timer = regrab_delay

	# Leaving a pole in midair counts as having used the first jump.
	if not player.is_on_floor():
		player.jumps_used = maxi(player.jumps_used, 1)

	if drop:
		player.velocity = radial_out * drop_push
		player.coyote_timer = 0.0


func update_attached(delta: float) -> void:
	if not is_instance_valid(pole_node) or not pole_node.is_inside_tree() \
			or player.movement_locked or player.is_ots_mode:
		end()
		return

	var geo: Dictionary = measure(pole_node)
	if geo.is_empty():
		end()
		return

	var up: Vector3 = player.up_direction
	var center: Vector3 = geo["center"]
	var radius: float = geo["radius"]
	var half_height: float = geo["half_height"]

	var offset: Vector3 = (player.global_position - center).slide(up)
	var distance: float = offset.length()
	if distance > 0.0001:
		radial_out = offset / distance
	elif radial_out == Vector3.ZERO:
		radial_out = player.character_model.global_basis.z.slide(up).normalized()

	tangent = up.cross(radial_out)

	var hold_distance: float = radius + player.get_capsule_radius() + hold_gap
	if distance - hold_distance > break_distance:
		end()
		return

	if player.crouch_slide_pressed():
		end(true)
		return

	var climb_input: float = -player.move_input.y
	var orbit_input: float = player.move_input.x

	if camera_relative_orbit:
		var cam_right: Vector3 = player.aim_pivot.global_basis.x.slide(up)
		if cam_right.length_squared() > 0.0001:
			var alignment: float = cam_right.normalized().dot(tangent)
			orbit_input *= clampf(alignment / CAMERA_ORBIT_FULL_ALIGNMENT, -1.0, 1.0)

	# Vertical motion.
	var vertical: float
	if climb_input > 0.0:
		vertical = climb_input * climb_speed
	elif climb_input < 0.0:
		vertical = climb_input * descend_speed
	else:
		vertical = -idle_slide_speed

	var height: float = (player.get_body_center() - center).dot(up)
	var top_limit: float = half_height - top_margin
	var bottom_limit: float = -half_height + bottom_margin

	# Slid down to the floor, or off the bottom of the pole: let go.
	if vertical < 0.0 and (player.is_on_floor() or height <= bottom_limit):
		end()
		return

	# Reached the top while pushing up: climb over it and stand on top.
	if climb_onto_top \
			and climb_input >= top_climb_input_threshold \
			and height >= top_limit - top_trigger_tolerance \
			and begin_top_climb(geo):
		return

	# Can't climb past the top; ease back down if somehow above it.
	if height >= top_limit:
		vertical = minf(vertical, -(height - top_limit) * attach_gain)

	# Horizontal motion: orbit plus a pull toward the hold distance.
	var radial_speed: float = clampf(
		(hold_distance - distance) * attach_gain,
		-attach_max_speed,
		attach_max_speed
	)

	_target_planar = tangent * (orbit_input * orbit_speed) + radial_out * radial_speed
	_target_vertical = vertical


# --------------------------------------------------------------------------
# Climbing over the top (modelled on PlayerLedgeGrab's climb)
# --------------------------------------------------------------------------

func begin_top_climb(geo: Dictionary) -> bool:
	var up: Vector3 = player.up_direction
	var center: Vector3 = geo["center"]
	var top_point: Vector3 = center + up * float(geo["half_height"])

	var start: Vector3 = player.global_position
	var stand: Vector3 = top_point + up * TOP_STAND_LIFT

	var rise: float = (stand - start).dot(up)
	if rise <= 0.0:
		return false

	var mid: Vector3 = start + up * rise
	if not top_path_clear(start, mid, stand):
		return false

	_top_start = start
	_top_mid = mid
	_top_stand = stand
	_top_timer = 0.0
	is_topping_out = true

	player.velocity = Vector3.ZERO
	player.pending_acceleration = Vector3.ZERO
	return true


## Called from Player._physics_process instead of the normal movement pipeline
## while is_topping_out (same slot as PlayerLedgeGrab.update).
func update_top_climb(delta: float) -> void:
	player.velocity = Vector3.ZERO
	player.pending_acceleration = Vector3.ZERO
	_top_timer += delta

	var t: float = clampf(_top_timer / maxf(top_climb_time, 0.01), 0.0, 1.0)

	if t < top_climb_vertical_fraction:
		var vertical_t: float = t / top_climb_vertical_fraction
		player.global_position = _top_start.lerp(_top_mid, smoothstep(0.0, 1.0, vertical_t))
	else:
		var horizontal_t: float = (t - top_climb_vertical_fraction) \
			/ maxf(1.0 - top_climb_vertical_fraction, 0.001)
		player.global_position = _top_mid.lerp(_top_stand, smoothstep(0.0, 1.0, horizontal_t))

	player.wall.face_wall(delta, radial_out, face_turn_speed)
	player.update_turn_rate(delta)
	player.apply_lean(delta)

	if t >= 1.0:
		finish_top_climb()


func finish_top_climb() -> void:
	player.global_position = _top_stand

	is_active = false
	is_topping_out = false
	pole_node = null
	_tracked_radial = Vector3.ZERO
	lockout_timer = regrab_delay

	player.coyote_timer = player.coyote_time
	player.jumps_used = 0
	player.velocity = -player.up_direction * 2.0
	player.move_and_slide()


func top_path_clear(start: Vector3, mid: Vector3, stand: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	if space == null:
		return true

	# The pole itself is allowed to overlap the path -- the player slides along it.
	var excluded: Array[RID] = [player.get_rid()]
	collect_body_rids(pole_node, excluded)

	if not position_clear(space, mid, excluded) or not position_clear(space, stand, excluded):
		return false

	return segment_clear(space, start, mid, excluded) and segment_clear(space, mid, stand, excluded)


func position_clear(space: PhysicsDirectSpaceState3D, feet_position: Vector3, excluded: Array[RID]) -> bool:
	if not player.player_collision_shape or not player.player_collision_shape.shape:
		return true

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = player.player_collision_shape.shape
	query.transform = Transform3D(
		player.global_basis.orthonormalized(),
		feet_position + player.up_direction * (Player.NORMAL_COLLISION_Y + TOP_CLEARANCE_LIFT)
	)
	query.collision_mask = player.collision_mask
	query.exclude = excluded

	return space.intersect_shape(query, 1).is_empty()


func segment_clear(
	space: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	excluded: Array[RID]
) -> bool:
	var step: float = maxf(top_path_check_step, 0.05)
	var steps: int = maxi(ceili(from.distance_to(to) / step), 1)

	for i in range(1, steps):
		if not position_clear(space, from.lerp(to, float(i) / float(steps)), excluded):
			return false

	return true


func collect_body_rids(node: Node, out: Array[RID]) -> void:
	if node is CollisionObject3D:
		out.append((node as CollisionObject3D).get_rid())

	for child in node.get_children():
		collect_body_rids(child, out)


# --------------------------------------------------------------------------
# Camera
# --------------------------------------------------------------------------

## Signed angle (radians, about the player's up axis) the character has orbited
## around the pole since the last call, scaled by camera_follow. camera_spring_arm.gd
## calls this every frame and rotates its yaw by the result, so the camera swings
## round with the character instead of staying put.
func take_orbit_delta() -> float:
	if not is_active or is_topping_out or camera_follow <= 0.0 or not is_instance_valid(pole_node):
		_tracked_radial = Vector3.ZERO
		return 0.0

	var geo: Dictionary = measure(pole_node)
	if geo.is_empty():
		return 0.0

	var up: Vector3 = player.up_direction
	var center: Vector3 = geo["center"]
	var radial: Vector3 = (player.global_position - center).slide(up)
	if radial.length_squared() < 0.0001:
		return 0.0
	radial = radial.normalized()

	var angle: float = 0.0
	if _tracked_radial != Vector3.ZERO:
		angle = _tracked_radial.signed_angle_to(radial, up)

	_tracked_radial = radial
	return angle * camera_follow


# --------------------------------------------------------------------------
# Hooks used by Player.gd
# --------------------------------------------------------------------------

func get_acceleration() -> float:
	return acceleration


func get_target_motion() -> Dictionary:
	return {
		"target_velocity": _target_planar,
		"target_forward": -radial_out
	}


## Vertical motion along the pole; same pattern as the wall run / climb.
func apply_gravity(delta: float) -> bool:
	if not is_active:
		return false

	var up: Vector3 = player.up_direction
	var projected: Vector3 = player.velocity + player.pending_acceleration * delta

	player.add_acceleration(Player.acceleration_toward(
		projected.project(up),
		up * _target_vertical,
		vertical_acceleration,
		delta
	))
	return true


func update_facing(delta: float) -> void:
	if not is_active or radial_out == Vector3.ZERO:
		return

	player.wall.face_wall(delta, radial_out, face_turn_speed)


## Jump while on a pole = the regular wall kick, with the pole's outward
## direction standing in for the wall normal.
func try_handle_jump() -> bool:
	if not is_active or is_topping_out:
		return false

	var normal: Vector3 = radial_out
	end()
	player.wall.kick_off(normal)
	player.coyote_timer = 0.0
	return true


## 0..1, how much the player is moving on the pole (drives the animation speed).
func get_motion_ratio() -> float:
	if not is_active:
		return 0.0

	var up: Vector3 = player.up_direction
	var vertical: float = absf(player.velocity.dot(up)) / maxf(climb_speed, 0.001)
	var around: float = absf(player.velocity.slide(up).dot(tangent)) / maxf(orbit_speed, 0.001)
	return clampf(maxf(vertical, around), 0.0, 1.0)


## Used by PlayerWallMovement.probe_wall() so poles aren't treated as walls.
func is_pole_collider(collider: Object) -> bool:
	var node := collider as Node

	while node:
		if node.is_in_group(pole_group):
			return true
		node = node.get_parent()

	return false


# --------------------------------------------------------------------------
# Grabbing
# --------------------------------------------------------------------------

func can_grab() -> bool:
	if lockout_timer > 0.0 or player.movement_locked or player.is_ots_mode:
		return false

	if player.slide.is_active or player.dive.is_active \
			or player.slam.is_active or player.ledge.is_active():
		return false

	if player.wall.state != PlayerWallMovement.WallState.NONE:
		return false

	if player.is_crouching and not player.can_stand_up():
		return false

	if gravity_controller \
			and gravity_controller.gravity_state != GravityController.GravityState.GROUNDED:
		return false

	return true


func is_approaching(to_pole: Vector3) -> bool:
	var on_floor: bool = player.is_on_floor()
	if on_floor and not grab_from_ground:
		return false

	if player.get_input_direction().dot(to_pole) > grab_input_dot:
		return true

	if on_floor:
		return false

	return player.velocity.slide(player.up_direction).dot(to_pole) > grab_min_approach_speed


func find_grab_target() -> Node3D:
	if not can_grab():
		return null

	var up: Vector3 = player.up_direction
	var body_center: Vector3 = player.get_body_center()
	var capsule_radius: float = player.get_capsule_radius()

	var best: Node3D = null
	var best_gap: float = INF

	for node in player.get_tree().get_nodes_in_group(pole_group):
		var candidate := node as Node3D
		if candidate == null or not candidate.is_inside_tree():
			continue

		var geo: Dictionary = measure(candidate)
		if geo.is_empty():
			continue

		var center: Vector3 = geo["center"]
		var half_height: float = geo["half_height"]
		if absf((body_center - center).dot(up)) > half_height:
			continue

		var offset: Vector3 = (player.global_position - center).slide(up)
		var distance: float = offset.length()
		if distance < 0.0001:
			continue

		var gap: float = distance - float(geo["radius"]) - capsule_radius
		if gap > grab_distance or gap >= best_gap:
			continue

		if not is_approaching(-offset / distance):
			continue

		best = candidate
		best_gap = gap

	return best


# --------------------------------------------------------------------------
# Measuring poles
# --------------------------------------------------------------------------

## World-space centre / radius / half height of a pole. The shape is measured
## once (in the pole's local space) and re-projected every call, so poles that
## are moved or yawed at runtime keep working.
func measure(node: Node3D) -> Dictionary:
	if not node.is_inside_tree():
		return {}

	var id: int = node.get_instance_id()
	if not _local_cache.has(id):
		_local_cache[id] = measure_local(node)

	var local: Dictionary = _local_cache[id]
	if local.is_empty():
		return {}

	var xf: Transform3D = node.global_transform
	var node_scale: Vector3 = xf.basis.get_scale()
	var local_center: Vector3 = local["center"]

	return {
		"center": xf * local_center,
		"radius": float(local["radius"]) * maxf(absf(node_scale.x), absf(node_scale.z)),
		"half_height": float(local["half_height"]) * absf(node_scale.y)
	}


func measure_local(root: Node3D) -> Dictionary:
	var to_local: Transform3D = root.global_transform.affine_inverse()
	var bounds := AABB()
	var has_bounds := false
	var radius: float = 0.0

	var shapes: Array[CollisionShape3D] = []
	collect_collision_shapes(root, shapes)

	for shape_node in shapes:
		if shape_node.disabled or shape_node.shape == null:
			continue

		var box: AABB = (
			to_local * shape_node.global_transform * shape_node.shape.get_debug_mesh().get_aabb()
		).abs()

		var is_round: bool = (
			shape_node.shape is CylinderShape3D
			or shape_node.shape is CapsuleShape3D
			or shape_node.shape is SphereShape3D
		)
		radius = maxf(radius, planar_radius(box, is_round))
		bounds = bounds.merge(box) if has_bounds else box
		has_bounds = true

	if not has_bounds:
		var visual: GeometryInstance3D = find_geometry(root)
		if visual == null:
			push_warning(
				"PlayerPole: '%s' is in group '%s' but has no CollisionShape3D or mesh/CSG shape to measure -- it can't be grabbed."
				% [root.name, pole_group]
			)
			return {}

		var visual_box: AABB = (to_local * visual.global_transform * visual.get_aabb()).abs()
		bounds = visual_box
		radius = planar_radius(visual_box, true)

	return {
		"center": bounds.get_center(),
		"radius": radius,
		"half_height": bounds.size.y * 0.5
	}


## Cylinders / capsules / spheres use their real radius. Anything else (boxes,
## convex hulls) uses the circle that encloses the footprint so the capsule can
## swing round the corners without catching.
func planar_radius(box: AABB, is_round: bool) -> float:
	var half_x: float = box.size.x * 0.5
	var half_z: float = box.size.z * 0.5

	if is_round:
		return maxf(half_x, half_z)

	return Vector2(half_x, half_z).length()


func collect_collision_shapes(node: Node, out: Array[CollisionShape3D]) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			out.append(child)

		collect_collision_shapes(child, out)


func find_geometry(node: Node) -> GeometryInstance3D:
	if node is GeometryInstance3D:
		return node as GeometryInstance3D

	for child in node.get_children():
		var found: GeometryInstance3D = find_geometry(child)
		if found:
			return found

	return null
