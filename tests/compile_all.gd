extends Node
func _ready() -> void:
	var bad := 0
	for f in _walk("res://scripts"):
		var s = ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE)
		if s == null or not s.can_instantiate():
			print("FAIL ", f)
			bad += 1
	print("compile check done, failures=", bad)
	get_tree().quit(1 if bad else 0)
func _walk(dir: String) -> Array:
	var out := []
	var d := DirAccess.open(dir)
	for sub in d.get_directories():
		out.append_array(_walk(dir.path_join(sub)))
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	return out
