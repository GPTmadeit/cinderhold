extends Node
## Developer helpers enabled by command-line flags after `--`:
##   --shot <png> <seconds>   save a screenshot and quit
##   --fps-log <seconds>      print average fps over the run, then quit

var shot_path := ""
var delay := 0.0
var _t := 0.0
var _frames := 0
var _fps_secs := 0.0
var _gpu_ms := 0.0
var _cpu_ms := 0.0
var _samples := 0


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
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _process(dt: float) -> void:
	_t += dt
	if _t > 3.0:
		_frames += 1
		if _fps_secs > 0.0:
			var vp := get_viewport().get_viewport_rid()
			_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(vp)
			_cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
			_samples += 1
	if shot_path != "" and _t >= delay:
		get_viewport().get_texture().get_image().save_png(shot_path)
		print("shot saved ", shot_path)
		shot_path = ""
		get_tree().quit()
	if _fps_secs > 0.0 and _t >= _fps_secs:
		# Render frames back to back without presenting: a hidden window is
		# throttled by the compositor, so presented fps says nothing.
		var vp := get_viewport().get_viewport_rid()
		for w in 10:
			RenderingServer.force_draw(false)
		RenderingServer.force_sync()
		var t0 := Time.get_ticks_usec()
		var n := 60
		for k in n:
			RenderingServer.force_draw(false)
		RenderingServer.force_sync()
		var per := (Time.get_ticks_usec() - t0) / 1000.0 / n
		print("offscreen render: %.1f ms/frame => %.0f fps" % [per, 1000.0 / per])
		var g := _gpu_ms / maxi(_samples, 1)
		var c := _cpu_ms / maxi(_samples, 1)
		print("avg fps %.1f presented | gpu %.1f ms, render cpu %.1f ms => ~%.0f fps possible (quality %s, %d enemies)" % [
			_frames / (_t - 3.0), g, c, 1000.0 / maxf(g, 0.001), Settings.QUALITY_NAMES[Settings.quality()],
			get_tree().get_nodes_in_group("enemies").size()])
		print("frame: %d primitives, %d draw calls, %d objects" % [
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)])
		get_tree().quit()
