extends Node3D

@export var Speed = 20
@export var WaitAmount = 10
@onready var pathFollow: PathFollow3D
@onready var direction: Vector3

# Called when the node enters the scene tree for the first time.
func _ready():
	var path3D = get_node("../../Path3D")
	var curve3D = path3D.get_curve()
	var startingPoint = curve3D.get_point_position(0)
	position = startingPoint
	pathFollow = get_node("../../Path3D/PathFollow3D")

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta):
	var oldPosition = position
	var justSetToTrue = false
	if get_parent().get_meta("path_follow_updated"):
		print("De-offseting path follow")
		pathFollow.progress -= get_meta("path_offset")
		justSetToTrue = false
	else:
		print("wheels.gd: ------------------------")
		print("wheels.gd: Wheel movement loop start !")
		pathFollow.progress += Speed * delta
		get_parent().set_meta("path_follow_updated", true)
		justSetToTrue = true
		
	position = pathFollow.position
	
	direction = (position - oldPosition).normalized()
	set_train_rotation(direction)
	
	if get_parent().get_meta("path_follow_updated") && !justSetToTrue:
		print("wheels.gd: Re-offseting path follow")
		pathFollow.progress += get_meta("path_offset")
	
func set_train_rotation(normalized_vector: Vector3):
	# Make sure the vector is normalized
	normalized_vector = normalized_vector.normalized()
	
	# Get the rotation needed for the train to look at the vector
	var basis = Basis().looking_at(normalized_vector)  # Corrected method name
	
	basis.y = Vector3(0, 1, 0)
	basis.x = normalized_vector
	basis.z = basis.x.cross(basis.y).normalized()
	
	var transform = Transform3D(basis, position)
	
	# Convert the rotation to Euler angles
	set_transform(transform)
