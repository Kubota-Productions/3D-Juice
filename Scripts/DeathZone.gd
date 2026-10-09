extends Area3D

func _on_body_entered(body: Node3D) -> void:
	if body.name == "Player":
		get_tree().call_group("game_timer", "record_progress")
		get_tree().call_deferred("reload_current_scene")
