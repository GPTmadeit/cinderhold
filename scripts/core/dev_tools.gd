extends Node
## Developer helpers enabled by command-line flags after `--`:
##   --shot <png> <seconds>   save a screenshot and quit
##   --fps-log <seconds>      print average fps over the run, then quit

var shot_path := ""
var delay := 0.0
var _t := 0.0
var _frames := 0
var _fps_secs := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shot")
	if i != -1 and i + 2 < args.size():
		shot_path = args[i + 1]
		delay = float(args[i + 2])
	i = args.find("--fps-log")
	if i != -1 and i + 1 < args.size():
		_fps_secs = float(args[i + 1])


func _process(dt: float) -> void:
	_t += dt
	if _t > 3.0:
		_frames += 1
	if shot_path != "" and _t >= delay:
		get_viewport().get_texture().get_image().save_png(shot_path)
		print("shot saved ", shot_path)
		shot_path = ""
		get_tree().quit()
	if _fps_secs > 0.0 and _t >= _fps_secs:
		print("avg fps %.1f (quality %s)" % [_frames / (_t - 3.0), Settings.QUALITY_NAMES[Settings.quality()]])
		get_tree().quit()
