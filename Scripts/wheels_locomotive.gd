extends Node3D

@export var Speed = 3
@onready var pathFollow: PathFollow3D
@onready var direction: Vector3

var moving := false

# Called when the node enters the scene tree for the first time.
func _ready():
	add_to_group("train_wheels")
	var path3D = get_node("../../../Path3D")
	var curve3D = path3D.get_curve()
	var startingPoint = curve3D.get_point_position(0)
	position = startingPoint
	pathFollow = get_node("../../../Path3D/PathFollow3D")

func start_moving():
	moving = true

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta):
	var oldPosition = position
	var justSetToTrue = false
	var step = Speed * delta if moving else 0.0
	if get_parent().get_meta("path_follow_updated"):
		#print("De-offseting path follow")
		pathFollow.progress -= get_meta("path_offset")
	else:
		#print("------------------------")
		#print("Wheel movement loop start !")
		pathFollow.progress += step - get_meta("path_offset")
		get_parent().set_meta("path_follow_updated", true)
		
	position = pathFollow.position
	
	direction = (position - oldPosition).normalized()
	if direction.length_squared() > 0.0001:
		set_train_rotation(direction)
	
	pathFollow.progress += get_meta("path_offset")
	
	if get_parent().get_meta("path_follow_updated"):
		get_parent().set_meta("path_follow_updated", false)
	
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
