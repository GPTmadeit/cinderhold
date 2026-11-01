extends Node
## Old patch files are cleared at startup, never the one in use:
## `godot --headless --path . res://tests/updater_prune.tscn` (isolated XDG_DATA_HOME)
func _ready() -> void:
	var dir := "user://updates"
	DirAccess.make_dir_recursive_absolute(dir)
	for f in ["cinderhold-0.2.0.pck", "cinderhold-0.3.0.pck", "cinderhold-0.3.1.pck"]:
		FileAccess.open(dir.path_join(f), FileAccess.WRITE).store_string("x")
	FileAccess.open(dir.path_join("patch.json"), FileAccess.WRITE).store_string(
		JSON.stringify({"version": "0.3.1", "engine": "4.7.2", "file": "cinderhold-0.3.1.pck"}))
	Settings.setup()
	Settings.data.updates.auto_check = false
	Updater.setup()
	var left := Array(DirAccess.get_files_at(dir))
	left.sort()
	var ok := left == ["cinderhold-0.3.1.pck", "patch.json"]
	print("%s updater prune: %s" % ["PASS" if ok else "FAIL", left])
	get_tree().quit(0 if ok else 1)
