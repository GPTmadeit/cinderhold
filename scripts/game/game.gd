extends Node3D
## Match controller. The host (or the solo player) is authoritative for
## rounds, enemies, points, purchases and power-ups. Each client owns its own
## player's movement, health and weapons and reports hits to the host.

const Prof := preload("res://scripts/core/prof.gd")
const ArenaScript := preload("res://scripts/world/arena.gd")
const PlayerScript := preload("res://scripts/player/player.gd")
const EnemyScript := preload("res://scripts/enemy/enemy.gd")
const HudScript := preload("res://scripts/ui/hud.gd")
const FxScript := preload("res://scripts/game/fx.gd")
const GrenadesScript := preload("res://scripts/game/grenades.gd")
const W := preload("res://scripts/game/weapons.gd")
const P := preload("res://scripts/game/perks.gd")
const M := preload("res://scripts/voxel/models.gd")
const LoadingScreen := preload("res://scripts/ui/loading_screen.gd")
const Diagnostics := preload("res://scripts/core/diagnostics.gd")

const SNAP_RATE := 15.0
const INTERMISSION := 10.0
const POWERUP_LIFE := 26.0
const POWERUP_KINDS := ["resupply", "double", "deadeye", "purge"]

var arena: Node3D
var players_root: Node3D
var enemies_root: Node3D
var fx_root: FxScript              # pooled hit effects; also holds power-ups
var live_grenades: GrenadesScript  # grenades in flight, simulated on every peer
var _next_grenade := 0
var hud: CanvasLayer
var local_player: CharacterBody3D

var round_num := 0
var phase := "loading"            # loading, intermission, active, over
var points := {}                  # peer -> int
var stats := {}                   # peer -> {kills, headshots, downs, revives, earned}
var enemies := {}                 # id -> enemy node
var powerups := {}                # id -> {kind, pos, node, life}
var double_t := 0.0
var deadeye_t := 0.0
var cache_state := {}             # {owner, weapon, until}
var forge_busy := false

# host only
var _rng := RandomNumberGenerator.new()
var _to_spawn := 0
var _spawn_cd := 0.0
var _phase_t := 0.0
var _snap_t := 0.0
var _next_enemy := 1
var _next_pu := 1
var _fields := {}                 # peer -> {cell, field}
var _field_t := 0.0
var _loaded := {}
var _drops_this_round := 0
var _kills_since_drop := 0
var _check_t := 0.0


func _ready() -> void:
	Diagnostics.ensure(get_tree())
	_rng.randomize()
	_load_t0 = Time.get_ticks_msec()
	var ls = LoadingScreen.open(get_tree(), "Preparing %s…" % ArenaScript.map_title(Net.match_map()))
	ls.set_note(ArenaScript.map_attribution(Net.match_map()))
	players_root = Node3D.new()
	players_root.name = "Players"
	add_child(players_root)
	enemies_root = Node3D.new()
	enemies_root.name = "Enemies"
	add_child(enemies_root)
	fx_root = FxScript.new()
	fx_root.name = "FX"
	add_child(fx_root)
	live_grenades = GrenadesScript.new()
	live_grenades.name = "Grenades"
	live_grenades.game = self
	add_child(live_grenades)
	arena = ArenaScript.new()
	arena.name = "Arena"
	add_child(arena)
	# solo matches roll their own vents; co-op uses the seed the host sent
	var vent_seed: int = randi() if Net.solo else Net.match_seed()
	await arena.build(false, func(f, stage): ls.set_progress(f * 0.62, stage), vent_seed, Net.match_map())
	arena.door_opened.connect(func(_l): _fields.clear())
	await _warm_models(ls)

	var ids := Net.players.keys()
	if ids.is_empty():
		Net.start_solo()
		ids = Net.players.keys()
	ids.sort()
	for i in ids.size():
		_spawn_player(ids[i], arena.player_spawns[i % arena.player_spawns.size()])
		points[ids[i]] = 500
		stats[ids[i]] = {"kills": 0, "headshots": 0, "downs": 0, "revives": 0, "earned": 500}

	hud = HudScript.new()
	hud.name = "HUD"
	add_child(hud)
	hud.bind(self, local_player)

	await _warm_shaders(ls)
	while not Sfx.is_ready():   # first launch: sounds may still be synthesising
		ls.set_progress(0.95 + 0.04 * Sfx.progress(), "Tuning the bells…")
		await get_tree().process_frame
	loaded = true
	ls.close()
	print("Cinderhold: match ready in %.1f s" % ((Time.get_ticks_msec() - _load_t0) / 1000.0))

	multiplayer.peer_disconnected.connect(_on_peer_left)
	Net.disconnected.connect(_on_host_lost)
	Sfx.music("game_music")
	if multiplayer.is_server():
		_loaded[1] = true
		_phase_t = 3.0
	else:
		_client_loaded.rpc_id(1)


## True once the map, models and shaders are ready and the match can run.
var loaded := false
var _load_t0 := 0


## Build every enemy, survivor, weapon and power-up model now, behind the
## loading screen, so the first Runner or Brute of a match doesn't hitch.
func _warm_models(ls) -> void:
	var jobs: Array[Callable] = []
	for v in 5:
		jobs.append(func(): M.husk("husk", v))
		jobs.append(func(): M.husk("runner", v))
	jobs.append(func(): M.brute())
	for c in Settings.PLAYER_COLORS.size():
		jobs.append(func(): M.survivor(c))
	for id in W.DEFS:
		jobs.append(func(): M.gun(id))
		jobs.append(func(): M.gun(id, true))
	for k in POWERUP_KINDS:
		jobs.append(func(): M.powerup(k))
	jobs.append(func(): M.arms())
	jobs.append(func(): M.knife())
	jobs.append(func(): M.grenade())
	# in parallel on worker threads; models.gd caches each one
	var task := WorkerThreadPool.add_group_task(func(i): jobs[i].call(), jobs.size(), -1, true, "Cinderhold: models")
	while not WorkerThreadPool.is_group_task_completed(task):
		var done := WorkerThreadPool.get_group_processed_element_count(task)
		ls.set_progress(0.62 + 0.16 * done / jobs.size(), "Waking the Husks…")
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(task)


## Draw one of everything in front of the camera for a few frames while the
## loading screen covers it, so shader pipelines are compiled now instead of
## mid-fight the first time a Brute, a Cinderbolt or a power-up shows up.
## (Godot also keeps compiled shaders on disk, so later launches are quicker.)
func _warm_shaders(ls) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var stage := Node3D.new()
	add_child(stage)
	stage.global_transform = cam.global_transform * Transform3D(Basis(), Vector3(0, -0.2, -2.5))
	var meshes: Array = []
	for part in M.husk("husk", 0).values():
		meshes.append(part.mesh)
	meshes.append(M.brute().torso.mesh)
	meshes.append(M.survivor(0).torso.mesh)
	for id in W.DEFS:
		meshes.append(M.gun(id, true))
	for k in POWERUP_KINDS:
		meshes.append(M.powerup(k))
	var x := -1.2
	for m in meshes:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.position = Vector3(x, 0, 0)
		mi.scale = Vector3.ONE * 0.3
		stage.add_child(mi)
		x += 0.1
	# the red-dot reticle's shader, and the knife and grenade
	var dot := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.3, 0.3)
	var rm := ShaderMaterial.new()
	rm.shader = preload("res://shaders/red_dot.gdshader")
	q.material = rm
	dot.mesh = q
	stage.add_child(dot)
	for m in [M.knife(), M.grenade()]:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.position = Vector3(x, 0, 0)
		stage.add_child(mi)
		x += 0.1
	fx_root.warm(stage.global_position)
	arena._dust_burst(stage.global_position)
	for f in 4:
		ls.set_progress(0.78 + 0.17 * (f + 1) / 4.0, "Warming the shaders…")
		await get_tree().process_frame
	stage.queue_free()


func _spawn_player(peer: int, pos: Vector3) -> void:
	var p: CharacterBody3D = PlayerScript.new()
	p.name = str(peer)
	p.peer_id = peer
	p.set_multiplayer_authority(peer)
	p.position = pos + Vector3(0, 0.1, 0)
	p.game = self
	var info: Dictionary = Net.players.get(peer, {"name": "Survivor", "color": 0})
	p.display_name = str(info.name)
	p.color_idx = int(info.color)
	players_root.add_child(p)
	if peer == multiplayer.get_unique_id():
		local_player = p


func player_nodes() -> Array:
	return players_root.get_children()


func get_player(peer: int) -> Node:
	return players_root.get_node_or_null(str(peer))


func player_name(peer: int) -> String:
	var p := get_player(peer)
	return p.display_name if p else "Someone"


@rpc("any_peer", "reliable")
func _client_loaded() -> void:
	_loaded[multiplayer.get_remote_sender_id()] = true
	# late-loading clients need the current points
	_sync_points.rpc(points, stats)


# =========================================================================
# Host loop
# =========================================================================

func _physics_process(dt: float) -> void:
	var _pt := Time.get_ticks_usec()
	_physics_process_body(dt)
	if Prof.on:
		Prof.add("game", _pt)


func _physics_process_body(dt: float) -> void:
	if not loaded:
		return
	_tick_timers(dt)
	if not multiplayer.is_server():
		return
	match phase:
		"loading":
			_phase_t -= dt
			if _phase_t <= 0.0 and (_loaded.size() >= Net.players.size() or _phase_t < -15.0):
				_start_round(_dev_start_round())
		"intermission":
			_phase_t -= dt
			if _phase_t <= 0.0:
				_start_round(round_num + 1)
		"active":
			_spawn_tick(dt)
			if _to_spawn <= 0 and enemies.is_empty():
				_end_round()
	if phase == "over":
		return
	_field_t -= dt
	if _field_t <= 0.0:
		_field_t = 0.25
		_update_fields()
	_snap_t -= dt
	if _snap_t <= 0.0:
		_snap_t = 1.0 / SNAP_RATE
		_broadcast_snapshot()
	_check_powerup_pickups()
	_check_t -= dt
	if _check_t <= 0.0:
		_check_t = 0.5
		_check_game_over()
	if not cache_state.is_empty() and Time.get_ticks_msec() / 1000.0 > float(cache_state.until):
		cache_state = {}
		_cache_close.rpc()


func _tick_timers(dt: float) -> void:
	double_t = maxf(double_t - dt, 0.0)
	deadeye_t = maxf(deadeye_t - dt, 0.0)
	for id in powerups.keys():
		var pu: Dictionary = powerups[id]
		pu.life -= dt
		var n: Node3D = pu.node
		n.rotation.y += dt * 1.8
		n.position.y = 1.0 + sin(pu.life * 3.0) * 0.12
		n.visible = pu.life > 6.0 or fmod(pu.life, 0.4) > 0.15
		if pu.life <= 0.0 and multiplayer.is_server():
			_powerup_gone.rpc(id)


## Dev: `--start-round N` begins a match at round N (perf testing).
func _dev_start_round() -> int:
	var a := OS.get_cmdline_user_args()
	var i := a.find("--start-round")
	return maxi(int(a[i + 1]), 1) if i != -1 and i + 1 < a.size() else 1


func round_health(r: int) -> float:
	if r < 10:
		return 150.0 + 100.0 * (r - 1)
	return 1050.0 * pow(1.1, r - 9)


## Enemy speed: a multiplier that grows a little every round. The first
## step is +2%; each later step is a random 0.1–0.9 points bigger than the
## one before (never smaller), so the pace creeps up instead of jumping.
## Each kind also has a top speed (enemy.gd) a sprinting survivor can beat.
const SPEED_FIRST_STEP := 0.02
var speed_mult := 1.0
var _speed_step := 0.0
var _speed_round := 1


func _grow_speed(to_round: int) -> void:
	while _speed_round < to_round:
		_speed_round += 1
		_speed_step = SPEED_FIRST_STEP if _speed_step == 0.0 else _speed_step + _rng.randf_range(0.001, 0.009)
		speed_mult += _speed_step


func _start_round(r: int) -> void:
	_grow_speed(r)
	var n := maxi(Net.players.size(), 1)
	var count := int(round((4.0 + r * 2.4 + pow(r, 1.6)) * (1.0 + 0.55 * (n - 1))))
	_to_spawn = count
	_spawn_cd = 1.5
	_drops_this_round = 0
	_round_started.rpc(r)


@rpc("authority", "reliable", "call_local")
func _round_started(r: int) -> void:
	round_num = r
	phase = "active"
	Sfx.play("round_start", 2.0, 0.0)
	hud.round_banner(r, true)
	for p in player_nodes():
		if p.is_multiplayer_authority():
			p.on_round_start()


func _end_round() -> void:
	_phase_t = INTERMISSION
	_round_ended.rpc(round_num)


@rpc("authority", "reliable", "call_local")
func _round_ended(r: int) -> void:
	phase = "intermission"
	Sfx.play("round_end", 0.0, 0.0)
	hud.round_banner(r, false)


func _max_alive() -> int:
	return mini(22 + 3 * (Net.players.size() - 1), 32)


func _spawn_tick(dt: float) -> void:
	if _to_spawn <= 0:
		return
	_spawn_cd -= dt
	if _spawn_cd > 0.0 or enemies.size() >= _max_alive():
		return
	_spawn_cd = maxf(2.0 - round_num * 0.12, 0.35) * _rng.randf_range(0.6, 1.3)
	var vent := _pick_vent()
	if vent.is_empty():
		return
	var kind := "husk"
	var brutes := 0
	for e in enemies.values():
		if e.kind == "brute":
			brutes += 1
	if round_num >= 6 and brutes < 1 + round_num / 10 and _rng.randf() < 0.035 + 0.004 * round_num:
		kind = "brute"
	elif _rng.randf() < clampf((round_num - 3) * 0.04, 0.0, 0.35):
		kind = "runner"   # a growing minority, never the bulk of a wave
	var hp := round_health(round_num)
	match kind:
		"runner": hp *= 0.8
		"brute": hp = hp * 4.5 + 1200.0
	var pos: Vector3 = vent.pos + Vector3(_rng.randf_range(-0.3, 0.3), 0, _rng.randf_range(-0.3, 0.3))
	_to_spawn -= 1
	_spawn_enemy.rpc(_next_enemy, kind, _rng.randi_range(0, 4), pos, hp, speed_mult)
	_next_enemy += 1


func _pick_vent() -> Dictionary:
	var vents: Array = arena.active_vents()
	if vents.is_empty():
		return {}
	var good := []
	for v in vents:
		var nearest := INF
		for p in player_nodes():
			if p.alive():
				nearest = minf(nearest, p.global_position.distance_to(v.pos))
		if nearest > 5.0 and nearest < 26.0:
			good.append(v)
	if good.is_empty():
		good = vents
	return good[_rng.randi() % good.size()]


@rpc("authority", "reliable", "call_local")
func _spawn_enemy(id: int, kind: String, variant: int, pos: Vector3, hp: float, speed: float) -> void:
	var _pt := Time.get_ticks_usec()
	var e: CharacterBody3D = EnemyScript.new()
	e.name = "E%d" % id
	enemies_root.add_child(e)
	e.setup(self, id, kind, variant, pos, hp, speed)
	enemies[id] = e
	Sfx.play_at("spawn", pos, -4.0)
	if Prof.on:
		Prof.add("spawn", _pt)


func _update_fields() -> void:
	for p in player_nodes():
		var peer: int = p.peer_id
		if not p.targetable():
			_fields.erase(peer)
			continue
		var cell: Vector2i = arena.cell_of(p.global_position)
		if _fields.has(peer) and _fields[peer].cell == cell:
			continue
		_fields[peer] = {"cell": cell, "field": arena.flow_field(cell)}


## For an enemy at `pos`: the closest targetable player and its flow field.
func choose_target(pos: Vector3) -> Dictionary:
	var best := {}
	var best_d := INF
	for peer in _fields:
		var p := get_player(peer)
		if p == null or not p.targetable():
			continue
		var d: float = arena.field_distance(_fields[peer].field, pos)
		if d < best_d:
			best_d = d
			best = {"player": p, "field": _fields[peer].field, "dist": d}
	return best


func _broadcast_snapshot() -> void:
	if enemies.is_empty():
		return
	var data := PackedFloat32Array()
	for id in enemies:
		var e = enemies[id]
		if e.dying:
			continue
		data.append_array([id, e.global_position.x, e.global_position.y, e.global_position.z, e.rotation.y, e.anim, e.move_speed])
	_snapshot.rpc(data)


@rpc("authority", "unreliable_ordered", "call_remote")
func _snapshot(data: PackedFloat32Array) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for i in range(0, data.size(), 7):
		var e = enemies.get(int(data[i]))
		if e:
			e.push_snapshot(now, Vector3(data[i + 1], data[i + 2], data[i + 3]), data[i + 4], int(data[i + 5]), data[i + 6])


# =========================================================================
# Damage and points
# =========================================================================

## Called by the local player with the hits it saw. hits: [[enemy_id, damage, head, melee], …]
func report_hits(hits: Array) -> void:
	_hits.rpc_id(1, hits)


@rpc("any_peer", "reliable", "call_local")
func _hits(hits: Array) -> void:
	if not multiplayer.is_server():
		return
	_apply_hits(_sender(), hits)


## Host: apply [[enemy_id, damage, head, melee], ...] dealt by `peer`.
func _apply_hits(peer: int, hits: Array) -> void:
	if not stats.has(peer):
		return
	for h in hits:
		var e = enemies.get(int(h[0]))
		if e == null or e.dying:
			continue
		var head: bool = h[2]
		var melee: bool = h[3]
		var dmg: float = h[1]
		if deadeye_t > 0.0:
			dmg = e.hp + 1.0
			head = true
		e.hp -= dmg
		e.on_hurt(peer)
		if e.hp <= 0.0:
			var reward := 130 if melee else (100 if head else 60)
			add_points(peer, reward)
			stats[peer].kills += 1
			if head:
				stats[peer].headshots += 1
			_kill_enemy(e, head, peer)
		else:
			add_points(peer, 10)


func _kill_enemy(e: Node, head: bool, killer: int) -> void:
	var pos: Vector3 = e.global_position
	enemies.erase(e.enemy_id)
	_enemy_died.rpc(e.enemy_id, head, killer)
	_maybe_drop(pos)


@rpc("authority", "reliable", "call_local")
func _enemy_died(id: int, head: bool, killer: int) -> void:
	var e = enemies.get(id)
	if e == null:
		e = enemies_root.get_node_or_null("E%d" % id)
	enemies.erase(id)
	if e:
		e.die(head)
	if killer == multiplayer.get_unique_id() and hud:
		hud.kill_confirmed(head)


func add_points(peer: int, amount: int) -> void:
	if double_t > 0.0 and amount > 0:
		amount *= 2
	points[peer] = int(points.get(peer, 0)) + amount
	if amount > 0 and stats.has(peer):
		stats[peer].earned += amount
	_sync_points.rpc(points, stats)


@rpc("authority", "reliable", "call_local")
func _sync_points(p: Dictionary, s: Dictionary) -> void:
	var me := multiplayer.get_unique_id()
	var before := int(points.get(me, 0))
	points = p
	if not multiplayer.is_server():
		stats = s
	var delta := int(points.get(me, 0)) - before
	if delta != 0 and hud and phase != "loading":
		hud.points_popup(delta)


## The local player threw a grenade: every peer simulates it from here.
func throw_grenade(origin: Vector3, vel: Vector3) -> void:
	_next_grenade += 1
	_grenade_thrown.rpc(multiplayer.get_unique_id() * 1000 + _next_grenade % 1000, origin, vel)


@rpc("any_peer", "reliable", "call_local")
func _grenade_thrown(id: int, origin: Vector3, vel: Vector3) -> void:
	var peer := _sender()
	if vel.length() > 30.0:
		return
	live_grenades.spawn(id, peer, origin, vel)
	var p := get_player(peer)
	if p and not p.is_local():
		p.on_remote_throw()


## Host: a grenade went off. Enemies in the radius with nothing solid in the
## way take damage that falls off with distance; survivors are never hurt.
func grenade_blast(pos: Vector3, peer: int, radius: float) -> void:
	var full := 400.0 + round_health(round_num) * 0.9
	var space := get_world_3d().direct_space_state
	var hits := []
	for e in enemies.values():
		if e.dying:
			continue
		var chest: Vector3 = e.global_position + Vector3.UP * 0.9
		var d := chest.distance_to(pos)
		if d > radius:
			continue
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.2, chest, 1)).is_empty():
			continue   # behind a wall or a door
		hits.append([e.enemy_id, full * lerpf(1.0, 0.3, d / radius), false, false])
	if Settings.bot_driving():
		print("GRENADE blast at %s hit %d enemies" % [pos.snappedf(0.1), hits.size()])
	if not hits.is_empty():
		_apply_hits(peer, hits)


func _sender() -> int:
	var s := multiplayer.get_remote_sender_id()
	return s if s != 0 else multiplayer.get_unique_id()


## Host → owning client: an enemy landed a blow.
func damage_player(p: Node, amount: float, from: Vector3) -> void:
	p.hurt.rpc_id(p.peer_id, amount, from)


# =========================================================================
# Purchases and interactions
# =========================================================================

func request(kind: String, key: String, extra = null) -> void:
	_request.rpc_id(1, kind, key, extra)


@rpc("any_peer", "reliable", "call_local")
func _request(kind: String, key: String, extra) -> void:
	if not multiplayer.is_server() or phase == "over":
		return
	var peer := _sender()
	var cash := int(points.get(peer, 0))
	match kind:
		"door":
			var d: Dictionary = arena.doors.get(key, {})
			if d.is_empty() or d.open:
				return
			if cash < d.cost:
				_deny.rpc_id(peer, "Not enough points.")
				return
			add_points(peer, -d.cost)
			_door_opened.rpc(key, peer)
		"wallbuy":
			if not W.DEFS.has(key) or arena.find_interactable("wallbuy", key).is_empty():
				return   # only weapons hanging on a wall can be bought
			var wd := W.get_def(key)
			var owned: bool = extra == true
			var price: int = wd.ammo_cost if owned else wd.cost
			if cash < price:
				_deny.rpc_id(peer, "Not enough points.")
				return
			add_points(peer, -price)
			_give_weapon.rpc_id(peer, key, false, owned)
		"tonic":
			var pd: Dictionary = P.PERKS.get(key, {})
			if pd.is_empty() or extra == true:
				return
			if cash < pd.cost:
				_deny.rpc_id(peer, "Not enough points.")
				return
			add_points(peer, -pd.cost)
			_give_perk.rpc_id(peer, key)
			_fx_sound.rpc("drink", arena.find_interactable("tonic", key).pos)
		"forge":
			if forge_busy:
				_deny.rpc_id(peer, "The forge is already burning.")
				return
			if extra == null or not (extra is Array) or extra[1]:
				_deny.rpc_id(peer, "That weapon can't be reforged again.")
				return
			if cash < 5000:
				_deny.rpc_id(peer, "Not enough points.")
				return
			add_points(peer, -5000)
			forge_busy = true
			_forge_start.rpc(peer, str(extra[0]))
			await get_tree().create_timer(3.6).timeout
			forge_busy = false
			_forge_done.rpc()
			if get_player(peer):
				_give_weapon.rpc_id(peer, str(extra[0]), true, false)
		"cache":
			if not cache_state.is_empty():
				if int(cache_state.owner) == peer and cache_state.get("ready", false):
					var wid: String = cache_state.weapon
					cache_state = {}
					_cache_close.rpc()
					_give_weapon.rpc_id(peer, wid, false, false)
				return
			if cash < 950:
				_deny.rpc_id(peer, "Not enough points.")
				return
			add_points(peer, -950)
			var exclude: Array = extra if extra is Array else []
			var wid := W.roll_cache(exclude, _rng)
			cache_state = {"owner": peer, "weapon": wid, "until": Time.get_ticks_msec() / 1000.0 + 14.0, "ready": false}
			_cache_roll.rpc(peer, wid)
			await get_tree().create_timer(3.8).timeout
			if not cache_state.is_empty() and int(cache_state.owner) == peer:
				cache_state.ready = true
		"revive":
			# is_downed(): on the host, a remote player's own `downed` flag is
			# never set; their state arrives in the network flags instead.
			var target := get_player(int(key))
			var reviver := get_player(peer)
			if target and target != reviver and target.is_downed() and reviver and reviver.targetable() \
					and reviver.global_position.distance_to(target.global_position) < 3.5:
				stats[peer].revives += 1
				add_points(peer, 100)
				_revived.rpc(int(key), peer)


@rpc("authority", "reliable", "call_local")
func _deny(reason: String) -> void:
	Sfx.play("deny")
	hud.toast(reason, Color("ff8a7a"))


@rpc("authority", "reliable", "call_local")
func _door_opened(letter: String, peer: int) -> void:
	arena.open_door(letter)
	hud.toast("%s opened the %s" % [player_name(peer), arena.map.DOORS[letter].name], Color("ffd9a8"))


@rpc("authority", "reliable", "call_local")
func _give_weapon(id: String, upgraded: bool, ammo_only: bool) -> void:
	Sfx.play("buy")
	local_player.receive_weapon(id, upgraded, ammo_only)


@rpc("authority", "reliable", "call_local")
func _give_perk(key: String) -> void:
	local_player.receive_perk(key)


@rpc("authority", "reliable", "call_local")
func _fx_sound(sound: String, pos: Vector3) -> void:
	Sfx.play_at(sound, pos, 2.0)


@rpc("authority", "reliable", "call_local")
func _forge_start(peer: int, wid: String) -> void:
	var it: Dictionary = arena.find_interactable("forge", "forge")
	Sfx.play_at("forge", it.pos, 4.0)
	if peer == multiplayer.get_unique_id():
		local_player.surrender_weapon_to_forge(wid)
	hud.toast("%s feeds the %s to the forge…" % [player_name(peer), W.get_def(wid).name], Color("ffb070"))
	var node: Node3D = it.node
	var g := MeshInstance3D.new()
	g.name = "ForgeGun"
	g.mesh = M.gun(wid, true)
	g.position = Vector3(0, 0.62, -0.75)
	g.rotation.y = PI * 0.5
	node.add_child(g)


@rpc("authority", "reliable", "call_local")
func _forge_done() -> void:
	var node: Node3D = arena.find_interactable("forge", "forge").node
	Sfx.play_at("forge_done", node.global_position + Vector3.UP, 2.0)
	var g := node.get_node_or_null("ForgeGun")
	if g:
		g.queue_free()


@rpc("authority", "reliable", "call_local")
func _cache_roll(peer: int, final_id: String) -> void:
	var it: Dictionary = arena.find_interactable("cache", "cache")
	var node: Node3D = it.node
	Sfx.play_at("cache", it.pos, 3.0)
	var lid: Node3D = node.get_node("Lid")
	create_tween().tween_property(lid, "rotation:x", deg_to_rad(-105), 0.6).set_trans(Tween.TRANS_BACK)
	var display: Node3D = node.get_node("Display")
	for c in display.get_children():
		c.queue_free()
	var mi := MeshInstance3D.new()
	display.add_child(mi)
	var ids := W.CACHE_POOL.keys()
	var t := 0.0
	var step := 0.08
	while t < 3.6:
		mi.mesh = M.gun(ids[randi() % ids.size()])
		await get_tree().create_timer(step).timeout
		if not is_instance_valid(mi):
			return
		t += step
		step *= 1.09
		mi.rotation.y += 0.6
	mi.mesh = M.gun(final_id)
	mi.rotation.y = PI * 0.5
	create_tween().tween_property(mi, "position:y", 0.35, 0.4)
	_client_cache_offer = final_id
	_client_cache_owner = peer
	if peer == multiplayer.get_unique_id():
		hud.toast("The cache offers the %s. Take it!" % W.get_def(final_id).name, Color("d8b8ff"))


@rpc("authority", "reliable", "call_local")
func _cache_close() -> void:
	var node: Node3D = arena.find_interactable("cache", "cache").node
	create_tween().tween_property(node.get_node("Lid"), "rotation:x", 0.0, 0.5)
	for c in node.get_node("Display").get_children():
		c.queue_free()
	cache_state = {}
	_client_cache_offer = ""
	_client_cache_owner = 0


## The weapon the open cache is offering `peer`, or "" (every peer tracks this).
func cache_offer_for(peer: int) -> String:
	return _client_cache_offer if _client_cache_owner == peer else ""


var _client_cache_offer := ""
var _client_cache_owner := 0


@rpc("authority", "reliable", "call_local")
func _revived(target: int, reviver: int) -> void:
	var p := get_player(target)
	if p and p.is_multiplayer_authority():
		p.revive()
	if Settings.bot_driving():
		print("REVIVED %s by %s" % [player_name(target), player_name(reviver)])
	Sfx.play("revive", -2.0)
	hud.toast("%s revived %s" % [player_name(reviver), player_name(target)], Color("b8f0a8"))


## Owner-side notification that this player went down (for stats).
@rpc("any_peer", "reliable", "call_local")
func _player_downed() -> void:
	if multiplayer.is_server():
		var peer := _sender()
		if stats.has(peer):
			stats[peer].downs += 1
	_announce_down.rpc(_sender())


@rpc("authority", "reliable", "call_local")
func _announce_down(peer: int) -> void:
	if peer != multiplayer.get_unique_id():
		hud.toast("%s is down! Revive them!" % player_name(peer), Color("ff6a5a"))


func notify_downed() -> void:
	_player_downed.rpc_id(1)


# =========================================================================
# Power-ups
# =========================================================================

func _maybe_drop(pos: Vector3) -> void:
	_kills_since_drop += 1
	if _drops_this_round >= 4:
		return
	var chance := 0.02 + 0.006 * _kills_since_drop
	if _rng.randf() < chance:
		_kills_since_drop = 0
		_drops_this_round += 1
		var kind: String = POWERUP_KINDS[_rng.randi() % POWERUP_KINDS.size()]
		_powerup_spawn.rpc(_next_pu, kind, Vector3(pos.x, 0, pos.z))
		_next_pu += 1


@rpc("authority", "reliable", "call_local")
func _powerup_spawn(id: int, kind: String, pos: Vector3) -> void:
	var root := Node3D.new()
	root.position = pos + Vector3(0, 1.0, 0)
	var mi := MeshInstance3D.new()
	mi.mesh = M.powerup(kind)
	mi.position.y = -0.2
	root.add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color("7ff0a0") if kind != "deadeye" else Color("ff5a4a")
	l.light_energy = 1.6
	l.omni_range = 4.0
	root.add_child(l)
	fx_root.add_child(root)
	powerups[id] = {"kind": kind, "pos": pos, "node": root, "life": POWERUP_LIFE}
	Sfx.play_at("powerup_spawn", root.position, 2.0)


func _check_powerup_pickups() -> void:
	for id in powerups.keys():
		var pu: Dictionary = powerups[id]
		for p in player_nodes():
			if p.alive() and not p.is_downed() and Vector2(p.global_position.x, p.global_position.z).distance_to(Vector2(pu.pos.x, pu.pos.z)) < 1.2:
				_powerup_taken.rpc(id, pu.kind, p.peer_id)
				if pu.kind == "purge":
					_do_purge.call_deferred()
				break


@rpc("authority", "reliable", "call_local")
func _powerup_gone(id: int) -> void:
	if powerups.has(id):
		powerups[id].node.queue_free()
		powerups.erase(id)


@rpc("authority", "reliable", "call_local")
func _powerup_taken(id: int, kind: String, peer: int) -> void:
	_powerup_gone(id)
	Sfx.play("powerup", 0.0, 0.0)
	match kind:
		"resupply":
			local_player.refill_ammo()
			hud.big_message("RESUPPLY", Color("9fe07a"))
		"double":
			double_t = 30.0
			hud.big_message("DOUBLE POINTS", Color("ffcf4d"))
		"deadeye":
			deadeye_t = 30.0
			hud.big_message("DEADEYE", Color("ff5a4a"))
		"purge":
			hud.big_message("PURGE", Color("ff9a3a"))
			hud.flash(Color(1.0, 0.6, 0.3, 0.7))
			Sfx.play("explode", 2.0, 0.0)
	hud.toast("%s grabbed %s" % [player_name(peer), kind.capitalize()], Color("e0f0c0"))


func _do_purge() -> void:
	for id in enemies.keys():
		var e = enemies[id]
		if e and not e.dying:
			_kill_enemy(e, false, 0)
	for peer in points:
		add_points(peer, 400)


# =========================================================================
# Game over, disconnects
# =========================================================================

func _check_game_over() -> void:
	if phase == "loading" or phase == "over":
		return
	for p in player_nodes():
		if p.alive() and not p.is_downed():
			return
	if player_nodes().is_empty():
		return
	var summary := []
	for p in player_nodes():
		var s: Dictionary = stats.get(p.peer_id, {})
		summary.append({"name": p.display_name, "color": p.color_idx, "points": int(stats.get(p.peer_id, {}).get("earned", 0)),
			"kills": int(s.get("kills", 0)), "headshots": int(s.get("headshots", 0)),
			"downs": int(s.get("downs", 0)), "revives": int(s.get("revives", 0))})
	_game_over.rpc(round_num, summary)


@rpc("authority", "reliable", "call_local")
func _game_over(r: int, summary: Array) -> void:
	phase = "over"
	Sfx.music("menu_music")
	Sfx.play("downed", 0.0, 0.0)
	if local_player:
		local_player.set_physics_process(false)
		local_player.set_process(false)
	hud.game_over(r, summary)


func _on_peer_left(peer: int) -> void:
	var p := get_player(peer)
	if p:
		hud.toast("%s left the game" % p.display_name, Color("c0c0c0"))
		p.queue_free()
	_fields.erase(peer)


func _on_host_lost(reason: String) -> void:
	if not is_inside_tree():
		return
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Net.last_message = reason
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


## Leave the match from the pause or game-over menu.
func leave() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if Net.solo or not multiplayer.is_server():
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	else:
		Net.return_to_lobby()


func play_again() -> void:
	get_tree().paused = false
	if Net.solo:
		get_tree().reload_current_scene()
	else:
		Net.return_to_lobby()
