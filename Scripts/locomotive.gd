extends Node3D

var train_scene = preload("res://Prefabs/train_locomotive.tscn")

@export var number_of_trains := 6

# Distance between the front and back wheel of a carriage.
@export var wheelbase := 4.0

# Distance between the FRONT wheels of consecutive carriages.
# Increase this if the carriages overlap.
@export var carriage_spacing := -25

func _ready():
	for i in range(number_of_trains):
		var train_name := "train" if i == 0 else "train%d" % (i + 1)
		var train := get_node(train_name)

		var front_wheel = train.get_node("train_wheel_front")
		var back_wheel = train.get_node("train_wheel_back")

		var front_offset = -i * carriage_spacing
		var back_offset = front_offset - wheelbase

		front_wheel.set_meta("path_offset", front_offset)
		back_wheel.set_meta("path_offset", back_offset)
