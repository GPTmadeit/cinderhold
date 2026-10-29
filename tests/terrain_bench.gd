extends Node
## Terrain build time and geometry: `godot --headless --path . res://tests/terrain_bench.tscn`
func _ready() -> void:
	var a = preload("res://scripts/world/arena.gd").new()
	add_child(a)
	a.H = a.LAYOUT.size()
	a.W = a.LAYOUT[0].length()
	a.walk.resize(a.W * a.H)
	a._world_body = StaticBody3D.new()
	a.add_child(a._world_body)
	var t := Time.get_ticks_msec()
	await a._build_terrain()
	var ms := Time.get_ticks_msec() - t
	var tris := 0
	var verts := 0
	var chunks := 0
	for n in a.get_children():
		if n is MeshInstance3D and n.mesh:
			chunks += 1
			for s in n.mesh.get_surface_count():
				var arr: Array = n.mesh.surface_get_arrays(s)
				verts += arr[Mesh.ARRAY_VERTEX].size()
				tris += arr[Mesh.ARRAY_INDEX].size() / 3
	print("terrain ms=%d tris=%d verts=%d chunks=%d" % [ms, tris, verts, chunks])
	t = Time.get_ticks_msec()
	var M = preload("res://scripts/voxel/models.gd")
	var mt := 0
	for v in 5:
		for k in ["husk", "runner"]:
			for p in M.husk(k, v).values():
				mt += p.mesh.get_faces().size() / 3
	for p in M.brute().values():
		mt += p.mesh.get_faces().size() / 3
	print("characters ms=%d tris=%d (10 husks + brute)" % [Time.get_ticks_msec() - t, mt])
	get_tree().quit()
