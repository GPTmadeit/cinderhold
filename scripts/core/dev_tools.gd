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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
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
	_bot_tick_log(dt, game, p)


func _bot_tick_log(dt: float, game: Node, p: Node) -> void:
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
	print("BOT t=%.0f round=%d phase=%s alive=%d pts=%d kills=%d hs=%d hp=%.0f/%.0f down=%s weapon=%s%s %s/%s perks=%s doors=%s" % [
		_bot_t, game.round_num, game.phase, game.enemies.size(), game.points.get(p.peer_id, 0),
		s.get("kills", 0), s.get("headshots", 0), p.hp, p.max_hp, p.downed,
		w.get("id", "-"), "+" if w.get("upgraded", false) else "", w.get("mag", 0), w.get("reserve", 0),
		",".join(p.perks), ",".join(game.arena.doors.keys().filter(func(k): return game.arena.doors[k].open))])
