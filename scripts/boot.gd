extends Node
## Entry point. Mounts a downloaded content patch (if one is newer than the
## built-in game), re-binds the autoload services to the patched scripts and
## then opens the main menu.

const PATCH_DIR := "user://updates"
const SERVICES := {
	"Settings": "res://scripts/core/settings.gd",
	"Net": "res://scripts/core/net.gd",
	"Sfx": "res://scripts/core/sfx.gd",
	"Updater": "res://scripts/core/updater.gd",
}


func _ready() -> void:
	var built_in: String = preload("res://scripts/core/version.gd").VERSION
	var patch := _read_patch()
	if not patch.is_empty() and _newer(str(patch.version), built_in) \
			and str(patch.get("engine", "")) == preload("res://scripts/core/version.gd").ENGINE:
		var pck := PATCH_DIR.path_join(str(patch.file))
		if FileAccess.file_exists(pck) and ProjectSettings.load_resource_pack(pck, true):
			print("Cinderhold: mounted patch ", patch.version)
			# Scripts loaded before the mount (this file's preloads, the
			# autoloads and their dependencies) are refreshed from the patch.
			# Cached scripts are not recompiled by a cache refresh, so the
			# services are compiled fresh from the patch (IGNORE_DEEP) and the
			# cache is refreshed for everything loaded later.
			ResourceLoader.load("res://scripts/core/version.gd", "", ResourceLoader.CACHE_MODE_REPLACE_DEEP)
			for service in SERVICES:
				var node := get_node("/root/" + service)
				node.set_script(ResourceLoader.load(SERVICES[service], "", ResourceLoader.CACHE_MODE_IGNORE_DEEP))
		else:
			push_warning("Cinderhold: patch %s could not be mounted" % patch.version)
	for service in SERVICES:
		get_node("/root/" + service).setup()
	var args := OS.get_cmdline_user_args()
	if "--print-version" in args:
		print("cinderhold version ", get_node("/root/Updater").current_version(), " built-in ", built_in)
		get_tree().quit()
		return
	_dev_flags(args)
	var host_i := args.find("--host")
	var join_i := args.find("--join")
	if host_i != -1:
		get_node("/root/Net").host()   # dev_tools starts the match once enough players join
	elif join_i != -1 and join_i + 1 < args.size():
		get_node("/root/Net").join(args[join_i + 1])
	if "--solo" in args:
		get_node("/root/Net").start_solo()
		get_tree().change_scene_to_file.call_deferred("res://scenes/game.tscn")
	else:
		get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


## Developer flags (after `--`): see scripts/core/dev_tools.gd.
func _dev_flags(args: PackedStringArray) -> void:
	var q := args.find("--quality")
	if q != -1 and q + 1 < args.size():
		get_node("/root/Settings").data.video.quality = int(args[q + 1])   # not saved
		get_node("/root/Settings").apply_video()
	if "--touch" in args:
		get_node("/root/Settings").data.gameplay.touch_controls = "on"   # not saved
	if "--fps-log" in args:
		# benchmark: don't let a hidden, throttled window idle the GPU
		get_node("/root/Settings").data.video.vsync = false
		get_node("/root/Settings").apply_video()
	if "--shot" in args or "--fps-log" in args or "--bot" in args or "--host" in args or "--ui" in args or "--perf" in args:
		# loaded at runtime so a broken dev script can never stop a normal launch
		var d: Node = load("res://scripts/core/dev_tools.gd").new()
		get_tree().root.add_child.call_deferred(d)


func _read_patch() -> Dictionary:
	var path := PATCH_DIR.path_join("patch.json")
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary and data.has("version") and data.has("file"):
		return data
	return {}


static func _newer(a: String, b: String) -> bool:
	var pa := a.trim_prefix("v").split(".")
	var pb := b.trim_prefix("v").split(".")
	for i in 3:
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false
