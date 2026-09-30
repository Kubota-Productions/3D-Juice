extends Node
class_name InteractionHighlightController

# ============================================================
# REFERENCES
# ============================================================
var player: CharacterBody3D
var camera: Camera3D

# ============================================================
# TARGETING
# ============================================================
@export_group("Targeting")
@export var reach: float = 6.0
@export var target_group: String = "interactable"

# ============================================================
# HIGHLIGHT
# ============================================================
@export_group("Highlight")
@export var fade_time: float = 0.15

# ============================================================
# STATE
# ============================================================
class HighlightState:
	var materials: Array[ShaderMaterial] = []
	var amount: float = 0.0

var current_target: Node = null
var active_highlights: Dictionary = {}


func setup(owner: CharacterBody3D, cam: Camera3D) -> void:
	player = owner
	camera = cam

	# Make sure every existing highlight overlay starts disabled.
	_initialize_highlight_overlays()


# ============================================================
# INITIALIZE
# ============================================================
func _initialize_highlight_overlays() -> void:
	if not player:
		return

	# Find every node in the scene that belongs to the interactable group.
	var interactables := get_tree().get_nodes_in_group(target_group)

	for target in interactables:
		if not is_instance_valid(target):
			continue

		var materials: Array[ShaderMaterial] = []
		_collect_highlight_materials(target, materials)

		for mat in materials:
			mat.set_shader_parameter("highlight_amount", 0.0)

	print(
		"InteractionHighlightController: initialized ",
		interactables.size(),
		" interactable(s) with highlight overlays disabled."
	)


# ============================================================
# UPDATE
# ============================================================
func update(delta: float) -> void:
	if not camera or not player:
		return

	var new_target := _find_target()

	if new_target != current_target:
		if new_target and not active_highlights.has(new_target):
			var state := HighlightState.new()

			_collect_highlight_materials(new_target, state.materials)

			print(
				"InteractionHighlightController: target acquired -> ",
				new_target.name,
				" (",
				state.materials.size(),
				" overlay shader material(s) found)"
			)

			if state.materials.is_empty():
				push_warning(
					"InteractionHighlightController: '%s' is in group '%s' "
					+ "but no MeshInstance3D under it has a ShaderMaterial "
					+ "assigned as its Material Overlay."
					% [new_target.name, target_group]
				)

			active_highlights[new_target] = state

		elif not new_target and current_target:
			print(
				"InteractionHighlightController: target lost -> ",
				current_target.name
			)

		current_target = new_target

	var weight: float = 1.0 - exp(
		-delta / max(fade_time, 0.001)
	)

	for target in active_highlights.keys().duplicate():
		var state: HighlightState = active_highlights[target]

		var target_amount: float = (
			1.0 if target == current_target else 0.0
		)

		state.amount = lerp(
			state.amount,
			target_amount,
			weight
		)

		for mat in state.materials:
			mat.set_shader_parameter(
				"highlight_amount",
				state.amount
			)

		if target != current_target and state.amount < 0.01:
			for mat in state.materials:
				mat.set_shader_parameter(
					"highlight_amount",
					0.0
				)

			active_highlights.erase(target)


# ============================================================
# TARGET FINDING
# ============================================================
func _find_target() -> Node:
	var from: Vector3 = camera.global_position
	var to: Vector3 = (
		from
		+ (-camera.global_transform.basis.z * reach)
	)

	var query := PhysicsRayQueryParameters3D.create(
		from,
		to
	)

	query.exclude = [player]
	query.collide_with_areas = true

	var hit := (
		player
		.get_world_3d()
		.direct_space_state
		.intersect_ray(query)
	)

	if not hit:
		return null

	var node: Node = hit.collider as Node

	while node:
		if node.is_in_group(target_group):
			return node

		node = node.get_parent()

	return null


# ============================================================
# COLLECT OVERLAY MATERIALS
# ============================================================
func _collect_highlight_materials(
	node: Node,
	out_list: Array
) -> void:

	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var overlay := mesh_instance.material_overlay

		if overlay is ShaderMaterial:
			out_list.append(overlay)

	for child in node.get_children():
		_collect_highlight_materials(child, out_list)
