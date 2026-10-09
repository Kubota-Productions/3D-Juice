extends Node
class_name GameController

var _bottles_collected: Array[String] = []
var _bottles_total: int = 0

func _ready() -> void:
	add_to_group("game_timer")
	_hook_bottles()

func _hook_bottles() -> void:
	# Wait a frame so every pickup in the scene is already in its group.
	await get_tree().process_frame
	for p in get_tree().get_nodes_in_group("gravity_pickup"):
		_bottles_total += 1
		p.collected.connect(_on_bottle_collected.bind(p))

func _on_bottle_collected(p: GravityPickup) -> void:
	var id: String = p.get_id()
	if not _bottles_collected.has(id):
		_bottles_collected.append(id)
		record_progress()

func record_progress() -> void:
	LevelManager.finish_level({
		"bottles": _bottles_collected,
		"bottles_total": _bottles_total,
	})
