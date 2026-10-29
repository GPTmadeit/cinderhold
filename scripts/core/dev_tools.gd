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
var _host_wants := 0


class Bracket extends Node:
	var first := true
	func _physics_process(_dt: float) -> void:
		if first:
			set_meta("t0", Time.get_ticks_usec())
		else:
			var t0: int = get_parent().get_node("BracketFirst").get_meta("t0", 0)
			preload("res://scripts/core/prof.gd").add("ALL node callbacks", t0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if "--prof" in OS.get_cmdline_user_args():
		var a := Bracket.new()
		a.name = "BracketFirst"
		a.process_physics_priority = -100000
		add_child(a)
		var b := Bracket.new()
		b.first = false
		b.process_physics_priority = 100000
		add_child(b)
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shot")
	if i != -1 and i + 2 < args.size():
		shot_path = args[i + 1]
		delay = float(args[i + 2])
	i = args.find("--host")
	if i != -1:
		_host_wants = int(args[i + 1]) if i + 1 < args.size() else 2
		Net.roster_changed.connect(_maybe_autostart)
	i = args.find("--fps-log")
	if i != -1 and i + 1 < args.size():
		_fps_secs = float(args[i + 1])
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


## --host N: start the match as soon as N players are in the lobby.
func _maybe_autostart() -> void:
	if Net.is_host() and Net.players.size() >= _host_wants and not Net.in_game:
		print("DEV: %d players in lobby, starting" % Net.players.size())
		Net.start_game()


var _ui_done := false


## --ui <screen>: open a screen for screenshots (updates, settings, join, lobby, pause, gameover).
func _dev_ui() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--ui")
	if _ui_done or i == -1 or i + 1 >= args.size() or _t < 1.5:
		return
	if get_tree().root.get_node_or_null("LoadingScreen"):
		return   # wait until the scene has finished loading
	_ui_done = true
	var which := args[i + 1]
	var scene := get_tree().current_scene
	if scene.has_method("_show"):
		if which == "updates":
			scene._show("settings")
			scene._panels.settings.get_child(0).get_child(0).open_updates()
		else:
			scene._show(which)
	elif "hud" in scene and scene.hud:
		match which:
			"pause": scene.hud.set_paused(true)
			"gameover": scene.hud.game_over(7, [
				{"name": "Neo", "color": 0, "points": 8420, "kills": 61, "headshots": 23, "downs": 1, "revives": 2},
				{"name": "Mara", "color": 1, "points": 7310, "kills": 52, "headshots": 30, "downs": 2, "revives": 1}])


var _plog_t := 0.0
var _plog_sum := 0.0
var _plog_max := 0.0
var _plog_n := 0


## --perf: print physics-frame cost every 3 s in any scene.
func _perf_log(dt: float) -> void:
	if not "--perf" in OS.get_cmdline_user_args():
		return
	var ph := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_plog_sum += ph
	_plog_max = maxf(_plog_max, ph)
	_plog_n += 1
	_plog_t += dt
	if _plog_t >= 3.0:
		var scene := get_tree().current_scene
		var alive: int = scene.enemies.size() if scene and "enemies" in scene else 0
		print("PERFLOG physics avg %.2f ms max %.2f ms over %d frames, %d enemies" % [_plog_sum / _plog_n, _plog_max, _plog_n, alive])
		var prof: Dictionary = preload("res://scripts/core/prof.gd").take()
		if not prof.is_empty():
			var parts := []
			for k in prof:
				parts.append("%s %.2f" % [k, prof[k] / 1000.0 / maxi(_plog_n, 1)])
			print("  PROF ms/frame: ", ", ".join(parts))
		_plog_t = 0.0
		_plog_sum = 0.0
		_plog_max = 0.0
		_plog_n = 0


var _fx_t := 0.0


## --fx-demo: keep firing every hit effect in front of the camera (for screenshots).
func _fx_demo(dt: float) -> void:
	var game := get_tree().current_scene
	if not "--fx-demo" in OS.get_cmdline_user_args() or game == null or not "loaded" in game or not game.loaded:
		return
	if not has_meta("fx_demo"):
		set_meta("fx_demo", true)
		print("FXDEMO started at %.1f s" % _t)
	var cam := get_viewport().get_camera_3d()
	var fwd := -cam.global_basis.z
	var right := cam.global_basis.x
	var at := cam.global_position + fwd * 3.0
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + fwd * 6.0, 1))
	if not hit.is_empty():
		at = hit.position - fwd * 0.4
	game.fx_root.tracer(cam.global_position + right * 0.3 - Vector3.UP * 0.2, at + right * 2.0, false)
	game.fx_root.tracer(cam.global_position - right * 0.3 - Vector3.UP * 0.2, at - right * 2.0, true)
	_fx_t -= dt
	if _fx_t <= 0.0:
		_fx_t = 0.12
		game.fx_root.impact(at - right * 0.8, -fwd)
		game.fx_root.impact(at + right * 0.8, -fwd, true)
		game.fx_root.burst(at + Vector3.UP * 0.6, false)
		game.fx_root.burst(at - Vector3.UP * 0.4, true)


func _process(dt: float) -> void:
	_t += dt
	_dev_ui()
	_perf_log(dt)
	_fx_demo(dt)
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


# =========================================================================
# --bot <seconds>: headless gameplay smoke test. Buys things, shoots enemies
# and logs what happens, then quits.
# =========================================================================

var _bot_secs := 0.0
var _bot_t := 0.0
var _bot_log_t := 0.0
var _bot_steps := {}
var _bot_fire_toggle := false
var bot_active := false
var _bot_move_t := 0.0
var _bot_dir := 1
var _win_phys_max := 0.0
var _win_proc_max := 0.0
var _win_phys_sum := 0.0
var _win_n := 0


func _enter_tree() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--bot")
	if i != -1 and i + 1 < args.size():
		_bot_secs = float(args[i + 1])
		bot_active = true


func _physics_process(dt: float) -> void:
	if not bot_active:
		return
	var game := get_tree().current_scene
	if game == null or not "local_player" in game or game.local_player == null:
		return
	var p = game.local_player
	_bot_t += dt
	# Solo: do everything. Co-op: the host hands out cash and opens doors, the
	# client exercises purchases over the network.
	var host: bool = multiplayer.is_server()
	var buyer: bool = Net.solo or not host
	if host:
		_bot_once(1.0, "cash", func():
			for peer in game.points.keys():
				game.add_points(peer, 30000))
		_bot_once(2.0, "doors", func():
			game.request("door", "A")
			game.request("door", "B"))
	if not buyer:
		_bot_aim_and_fire(game, p)
		_bot_tick_log(dt, game, p)
		return
	_bot_once(3.0, "wallbuy", func(): game.request("wallbuy", "warden", false))
	_bot_once(4.0, "perks", func():
		game.request("tonic", "ironhide", false)
		game.request("tonic", "quickhands", false))
	_bot_once(5.0, "cache", func():
		var owned := []
		for w in p.weapons:
			owned.append(w.id)
		game.request("cache", "cache", owned))
	_bot_once(10.0, "cache_take", func(): game.request("cache", "cache", []))
	_bot_once(12.0, "forge", func():
		var w: Dictionary = p.weapon()
		game.request("forge", "forge", [w.id, w.upgraded]))
	_bot_aim_and_fire(game, p)
	_bot_strafe(dt)
	_bot_tick_log(dt, game, p)


## --bot-move: strafe back and forth so the player keeps changing cells.
func _bot_strafe(dt: float) -> void:
	if not "--bot-move" in OS.get_cmdline_user_args():
		return
	_bot_move_t -= dt
	if _bot_move_t <= 0.0:
		_bot_move_t = 1.6
		_bot_dir = -_bot_dir
		Input.action_release("move_left")
		Input.action_release("move_right")
		Input.action_press("move_right" if _bot_dir > 0 else "move_left")


func _bot_tick_log(dt: float, game: Node, p: Node) -> void:
	var ph := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var pr := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_win_phys_max = maxf(_win_phys_max, ph)
	_win_proc_max = maxf(_win_proc_max, pr)
	_win_phys_sum += ph
	_win_n += 1
	_bot_log_t -= dt
	if _bot_log_t <= 0.0:
		_bot_log_t = 3.0
		_bot_report(game, p)
	if _bot_t >= _bot_secs:
		_bot_report(game, p)
		print("BOT DONE")
		get_tree().quit()


func _bot_once(at: float, key: String, cb: Callable) -> void:
	if _bot_t >= at and not _bot_steps.has(key):
		_bot_steps[key] = true
		print("BOT step ", key)
		cb.call()


func _bot_aim_and_fire(game: Node, p: Node) -> void:
	var cam: Camera3D = p.camera
	var space: PhysicsDirectSpaceState3D = p.get_world_3d().direct_space_state
	var best = null
	var best_d := INF
	for e in game.enemies.values():
		if e.dying or e._rise < 1.0:
			continue
		var head: Vector3 = e.global_position + Vector3.UP * (e._stats.height - 0.25)
		var d := cam.global_position.distance_to(head)
		if d > 40.0 or d >= best_d:
			continue
		var q := PhysicsRayQueryParameters3D.create(cam.global_position, head, 1)
		if not space.intersect_ray(q).is_empty():
			continue
		best = head
		best_d = d
	if best == null:
		Input.action_release("fire")
		return
	var to: Vector3 = best - cam.global_position
	p.yaw = atan2(-to.x, -to.z)
	p.pitch = atan2(to.y, Vector2(to.x, to.z).length())
	# tap the trigger so semi-automatic weapons fire too
	_bot_fire_toggle = not _bot_fire_toggle
	if _bot_fire_toggle:
		Input.action_press("fire")
	else:
		Input.action_release("fire")
	var w: Dictionary = p.weapon()
	if not w.is_empty() and w.mag == 0 and w.reserve == 0:
		game.request("wallbuy", w.id, true)


func _bot_report(game: Node, p: Node) -> void:
	var w: Dictionary = p.weapon()
	var s: Dictionary = game.stats.get(p.peer_id, {})
	var others := []
	for o in game.player_nodes():
		if o != p:
			others.append("%s@(%.1f,%.1f)" % [o.display_name, o.global_position.x, o.global_position.z])
	print("BOT[%s] others=%s" % ["host" if multiplayer.is_server() else "client", ",".join(others)])
	print("PERF round=%d alive=%d nodes=%d objects=%d physics avg %.2f ms max %.2f ms | process max %.2f ms" % [
		game.round_num, game.enemies.size(), Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_COUNT), _win_phys_sum / maxi(_win_n, 1), _win_phys_max, _win_proc_max])
	print("MEM rss %s | static %.1f MB | video %.1f MB (textures %.1f, buffers %.1f) | resources %d orphan nodes %d" % [
		preload("res://scripts/core/diagnostics.gd").rss(), Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)])
	print("PIPELINES compiled: canvas %d mesh %d surface %d draw %d specialization %d" % [
		Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS),
		Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH),
		Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE),
		Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW),
		Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION)])
	var prof: Dictionary = preload("res://scripts/core/prof.gd").take()
	if not prof.is_empty():
		var parts := []
		for k in prof:
			parts.append("%s %.2f" % [k, prof[k] / 1000.0 / maxi(_win_n, 1)])
		print("PROF ms/frame: ", ", ".join(parts))
		print("PHYS active=%d pairs=%d islands=%d | audio3d playing=%d" % [
			Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
			Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
			Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT),
			get_tree().root.find_children("*", "AudioStreamPlayer3D", true, false).filter(func(a): return a.playing).size()])
	_win_phys_max = 0.0
	_win_proc_max = 0.0
	_win_phys_sum = 0.0
	_win_n = 0
	print("BOT t=%.0f round=%d phase=%s alive=%d pts=%d kills=%d hs=%d hp=%.0f/%.0f down=%s weapon=%s%s %s/%s perks=%s doors=%s" % [
		_bot_t, game.round_num, game.phase, game.enemies.size(), game.points.get(p.peer_id, 0),
		s.get("kills", 0), s.get("headshots", 0), p.hp, p.max_hp, p.downed,
		w.get("id", "-"), "+" if w.get("upgraded", false) else "", w.get("mag", 0), w.get("reserve", 0),
		",".join(p.perks), ",".join(game.arena.doors.keys().filter(func(k): return game.arena.doors[k].open))])
