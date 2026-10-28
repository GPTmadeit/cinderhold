extends Node
func _ready() -> void:
	var a = preload("res://scripts/world/arena.gd").new()
	add_child(a)
	var t := Time.get_ticks_msec()
	a.build()
	var ms := Time.get_ticks_msec() - t
	var tris := 0
	var lights := 0
	var per := {}
	for n in a.get_children():
		if n is MeshInstance3D and n.mesh:
			var c: int = n.mesh.get_faces().size() / 3
			tris += c
			var k := String(n.name).get_slice("_", 0).rstrip("0123456789@")
			per[k] = per.get(k, 0) + c
		if n is OmniLight3D:
			lights += 1
	print("arena build ms=", ms, " triangles=", tris, " omni=", lights)
	print(per)
	var meshes := {}
	for n in a.get_children():
		if n is MeshInstance3D and n.mesh and not String(n.name).begins_with("Chunk"):
			var key := "%s" % n.mesh.get_rid()
			if not meshes.has(key):
				meshes[key] = [n.mesh.get_faces().size() / 3, 0, n.position.snappedf(1)]
			meshes[key][1] += 1
	var rows := meshes.values()
	rows.sort_custom(func(x, y): return x[0] * x[1] > y[0] * y[1])
	for r in rows.slice(0, 12):
		print("tris %d x%d at %s" % r)
	get_tree().quit()
