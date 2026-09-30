extends Node3D

@onready var front_wheel: Node3D = $"../train_wheel_front"
@onready var back_wheel: Node3D = $"../train_wheel_back"

func _physics_process(_delta):
	position = front_wheel.position.lerp(back_wheel.position, 0.5)

	var direction := (front_wheel.position - back_wheel.position).normalized()

	if direction.length_squared() > 0.0001:
		set_train_rotation(direction)


func set_train_rotation(direction: Vector3):
	var basis := Basis()
	basis.x = direction
	basis.y = Vector3.UP
	basis.z = basis.x.cross(basis.y).normalized()
	basis.y = basis.z.cross(basis.x).normalized()

	transform.basis = basis

func _on_area_3d_body_entered(body: Node3D) -> void:
	if body is Player:
		get_tree().call_group("train_wheels", "start_moving")
		get_tree().call_group("game_timer", "escape")
