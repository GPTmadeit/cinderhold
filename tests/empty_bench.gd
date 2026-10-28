extends Node3D
func _ready() -> void:
	var c := Camera3D.new()
	add_child(c)
	var m := MeshInstance3D.new()
	m.mesh = BoxMesh.new()
	m.position = Vector3(0, 0, -3)
	add_child(m)
	add_child(DirectionalLight3D.new())
	add_child(preload("res://scripts/core/dev_tools.gd").new())
