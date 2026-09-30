extends Node
class_name CombatController

var player: CharacterBody3D
var camera: Camera3D

@export_group("Targeting")
@export var reach: float = 30.0
@export var target_group: String = "npc_heads"

@export_subgroup("Aim Assist")
@export var aim_assist_angle_deg: float = 3.0
@export var aim_assist_sticky_bonus_deg: float = 2.0

@export_group("Charge")
@export var charge_time: float = 0.8
@export var target_lose_grace_time: float = 0.15

@export_group("Gravity Meter Cost")
@export var power_drain_rate: float = 30.0
var gravity_controller: GravityController

var spring_arm: SpringArm3D

@export_group("Effects")
@export var explosion_effect: PackedScene = null

var is_button_held: bool = false
var current_target: Node3D = null
var charge_elapsed: float = 0.0
var lose_target_timer: float = 0.0
var power_reserved: bool = false

var focused_npc: Node = null


func setup(owner: CharacterBody3D, cam: Camera3D) -> void:
	player = owner
	camera = cam
	gravity_controller = owner.get_node_or_null("GravityController")
	spring_arm = owner.get_node_or_null("SpringArm3D")


func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("Combat"):
		if not _is_focused_view():
			print("CombatController: Combat pressed but NOT in focused view (is_ots_mode is false)")
			return
		print("CombatController: Combat pressed, focused view active -- charging")
		is_button_held = true

	elif event.is_action_released("Combat"):
		is_button_held = false
		_cancel_charge()


func _is_focused_view() -> bool:
	return player and "is_ots_mode" in player and player.is_ots_mode


func update(delta: float) -> void:
	if not camera or not player:
		return

	if not is_button_held or not _is_focused_view():
		_set_aiming(false)
		_cancel_charge()
		return

	_set_aiming(true)

	var target := _find_target()

	if target == null:
		if current_target != null and lose_target_timer == 0.0:
			print("CombatController: no target under reticle")
		lose_target_timer += delta
		if lose_target_timer > target_lose_grace_time:
			_cancel_charge()
		return

	lose_target_timer = 0.0

	if target != current_target:
		print("CombatController: target acquired -> ", target.name)
		_cancel_charge()
		current_target = target

	_set_focused_npc(_get_npc_from_head(current_target))

	_set_assist_target(current_target)

	if gravity_controller and not gravity_controller.drain_power(power_drain_rate * delta):
		print("CombatController: charge broken -- ran out of shift power")
		_cancel_charge()
		return

	charge_elapsed += delta

	if charge_elapsed >= charge_time:
		_pop_head(current_target)
		_cancel_charge()


func _find_target() -> Node3D:
	var from: Vector3 = camera.global_position
	var forward: Vector3 = -camera.global_transform.basis.z
	var to: Vector3 = from + forward * reach

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player]
	query.collide_with_areas = true

	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)

	if hit:
		var collider: Object = hit.collider
		if collider is Node and collider.is_in_group(target_group):
			return collider

	if aim_assist_angle_deg > 0.0:
		return _find_assisted_target(from, forward)

	return null


func _find_assisted_target(from: Vector3, forward: Vector3) -> Node3D:
	var best: Node3D = null
	var best_angle: float = INF

	for node in get_tree().get_nodes_in_group(target_group):
		if not (node is Node3D):
			continue

		var head: Node3D = node
		var to_head: Vector3 = head.global_position - from
		var distance: float = to_head.length()
		if distance < 0.01 or distance > reach:
			continue

		var angle_deg: float = rad_to_deg(forward.angle_to(to_head.normalized()))
		var allowed_angle: float = aim_assist_angle_deg
		if head == current_target:
			allowed_angle += aim_assist_sticky_bonus_deg

		if angle_deg > allowed_angle:
			continue

		var los_query := PhysicsRayQueryParameters3D.create(from, head.global_position)
		los_query.exclude = [player]
		los_query.collide_with_areas = true
		var los_hit := player.get_world_3d().direct_space_state.intersect_ray(los_query)
		if los_hit and los_hit.collider != head:
			continue

		if angle_deg < best_angle:
			best_angle = angle_deg
			best = head

	return best


func _set_aiming(value: bool) -> void:
	if spring_arm and "is_combat_aiming" in spring_arm:
		spring_arm.is_combat_aiming = value


func _set_assist_target(target: Node3D) -> void:
	if spring_arm and "combat_assist_target" in spring_arm:
		spring_arm.combat_assist_target = target


func _cancel_charge() -> void:
	current_target = null
	charge_elapsed = 0.0
	lose_target_timer = 0.0
	_set_focused_npc(null)
	_set_assist_target(null)


func _set_focused_npc(npc: Node) -> void:
	if npc == focused_npc:
		return

	if is_instance_valid(focused_npc) and focused_npc.has_method("set_focused"):
		focused_npc.set_focused(false)

	focused_npc = npc

	if is_instance_valid(focused_npc) and focused_npc.has_method("set_focused"):
		focused_npc.set_focused(true)


func _get_npc_from_head(head: Node) -> Node:
	var node := head
	while node and not node.has_method("set_focused"):
		node = node.get_parent()
	return node


func _pop_head(head: Node3D) -> void:
	if not is_instance_valid(head):
		return

	print("CombatController: head exploded")

	var pop_position: Vector3 = head.global_position

	if explosion_effect:
		var fx := explosion_effect.instantiate()
		player.get_tree().current_scene.add_child(fx)
		if fx is Node3D:
			fx.global_position = pop_position

	var npc := head
	while npc and not npc.has_method("explode_head"):
		npc = npc.get_parent()

	if npc and npc.has_method("explode_head"):
		npc.explode_head()
	else:
		head.queue_free()


func get_charge_ratio() -> float:
	return clamp(charge_elapsed / max(charge_time, 0.001), 0.0, 1.0)
