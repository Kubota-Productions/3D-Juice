extends Area3D
class_name GravityPickup

signal collected

@export var pickup_id: StringName = &""
@export var pickup_effect: Node = null
@export var wait_for_effect: bool = false
@export var float_height: float = 0.25
@export var float_speed: float = 2.0
@export var rotation_speed: float = 2.0

var _collected := false
var _start_position: Vector3
var _float_time: float = 0.0

func _enter_tree() -> void:
	add_to_group("gravity_pickup")

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_start_position = position
	_float_time = randf_range(0.0, TAU)

func get_id() -> String:
	if pickup_id != &"":
		return String(pickup_id)
	return str(get_tree().current_scene.get_path_to(self))

func _process(delta: float) -> void:
	if _collected:
		return
	_float_time += delta * float_speed
	position.y = _start_position.y + sin(_float_time) * float_height
	rotate_y(rotation_speed * delta)

func _on_body_entered(body: Node3D) -> void:
	if _collected or not (body is Player):
		return
	_collected = true
	collected.emit()
	_play_effect_and_free()

func _play_effect_and_free() -> void:
	set_deferred("monitoring", false)

	if pickup_effect is AudioStreamPlayer3D and wait_for_effect:
		var sound: AudioStreamPlayer3D = pickup_effect
		remove_child(sound)
		get_tree().current_scene.add_child(sound)
		sound.global_position = global_position
		sound.play()
		sound.finished.connect(sound.queue_free)
	elif pickup_effect is GPUParticles3D:
		pickup_effect.emitting = true
	elif pickup_effect is AnimationPlayer:
		pickup_effect.play("pickup")

	queue_free()
