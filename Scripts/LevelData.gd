class_name LevelData
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export_file("*.tscn") var scene_path: String = ""
@export var thumbnail: Texture2D
@export var unlock_requires: Array[StringName] = []
@export var par_time: float = 0.0
