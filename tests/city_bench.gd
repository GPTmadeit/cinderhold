extends Node
## Times Square build time and geometry: `godot --headless --path . res://tests/city_bench.tscn`
func _ready() -> void:
	Settings.setup()
	var a = preload("res://scripts/world/arena.gd").new()
	add_child(a)
	var t := Time.get_ticks_msec()
	await a.build(false, Callable(), 1, "times_square")
	print("city build ms=%d (first, includes meshing)" % (Time.get_ticks_msec() - t))
	var groups := {"street": [0, 0], "facades": [0, 0], "props": [0, 0]}
	var lights := 0
	for n in a.get_children():
		if n is OmniLight3D:
			lights += 1
		if not (n is MeshInstance3D and n.mesh):
			continue
		var g := "props"
		if n.mesh.get_surface_count() > 0 and n.mesh.surface_get_material(0) is ShaderMaterial:
			var sh: Shader = n.mesh.surface_get_material(0).shader
			if sh == preload("res://shaders/facade.gdshader"):
				g = "facades"
			elif n.get_parent() == a and n.position == Vector3.ZERO:
				g = "street"
		for s in n.mesh.get_surface_count():
			var arr: Array = n.mesh.surface_get_arrays(s)
			groups[g][0] += arr[Mesh.ARRAY_INDEX].size() / 3 if arr[Mesh.ARRAY_INDEX] else arr[Mesh.ARRAY_VERTEX].size() / 3
			groups[g][1] += 1
	for g in groups:
		print("%s tris=%d surfaces=%d" % [g, groups[g][0], groups[g][1]])
	print("lights=%d colliders=%d" % [lights, a._world_body.get_child_count()])
	var b = preload("res://scripts/world/arena.gd").new()
	add_child(b)
	t = Time.get_ticks_msec()
	await b.build(false, Callable(), 1, "times_square")
	print("city build ms=%d (second, meshes cached)" % (Time.get_ticks_msec() - t))
	get_tree().quit()
