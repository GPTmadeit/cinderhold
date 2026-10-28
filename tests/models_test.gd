extends SceneTree
const M := preload("res://scripts/voxel/models.gd")
func _init() -> void:
	var t := Time.get_ticks_msec()
	var total := 0
	for k in ["husk", "runner"]:
		for v in 5:
			for p in M.husk(k, v).values(): total += p.mesh.get_faces().size() / 3
	for p in M.brute().values(): total += p.mesh.get_faces().size() / 3
	for c in 4:
		for p in M.survivor(c).values(): total += p.mesh.get_faces().size() / 3
	for g in ["tinder", "kestrel", "warden", "breacher", "maul", "longshot", "cinderbolt"]:
		for up in [false, true]: total += M.gun(g, up).get_faces().size() / 3
	var meshes := [M.crate(), M.barrel(), M.brazier(), M.lantern_post(), M.tonic_machine(Color.RED), M.forge(), M.vent(), M.door(2.0, 3.0), M.plaque()]
	for k in ["resupply", "double", "deadeye", "purge"]: meshes.append(M.powerup(k))
	meshes.append(M.cache_chest().base); meshes.append(M.cache_chest().lid)
	for m in M.arms().values(): meshes.append(m)
	for m in meshes: total += m.get_faces().size() / 3
	print("OK triangles=", total, " ms=", Time.get_ticks_msec() - t)
	quit()
